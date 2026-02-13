
#!/bin/bash

# Script: 02-build-vm-image.sh
# Description: Automated VM image preparation with roxagent for RHACS scanning

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Configuration
readonly ROXAGENT_VERSION="${ROXAGENT_VERSION:-4.9.2}"
readonly ROXAGENT_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXAGENT_VERSION}/bin/linux/roxagent"
readonly NAMESPACE="${NAMESPACE:-default}"
IMAGE_METHOD="${IMAGE_METHOD:-cloud-init}"  # Default to cloud-init (recommended)

#================================================================
# Display method selection
#================================================================
select_build_method() {
    # If IMAGE_METHOD is already set (e.g., via environment variable), use it
    if [ "${IMAGE_METHOD}" == "cloud-init" ] || [ "${IMAGE_METHOD}" == "custom" ]; then
        print_info "Using image preparation method: ${IMAGE_METHOD}"
        return 0
    fi
    
    print_step "VM Image Preparation Method Selection"
    echo ""
    
    cat <<'EOF'
Choose how to prepare RHEL VMs with roxagent:

1. Cloud-init (Recommended - No image building)
   ✓ Uses standard RHEL image + cloud-init
   ✓ roxagent installed on first boot
   ✓ Fastest, easiest method
   ✓ Easy to update roxagent version

2. Custom QCOW2 Image (Advanced)
   ✓ roxagent pre-installed in image
   ✓ No internet required at boot
   ✓ Requires libguestfs-tools
   ✓ Takes longer to build

EOF
    
    read -p "Select method (1=cloud-init, 2=custom): " choice
    case "$choice" in
        1) IMAGE_METHOD="cloud-init" ;;
        2) IMAGE_METHOD="custom" ;;
        *) 
            print_error "Invalid choice"
            exit 1
            ;;
    esac
    
    print_info "Selected method: ${IMAGE_METHOD}"
}

#================================================================
# Prepare cloud-init based VM template
#================================================================
prepare_cloudinit_template() {
    print_step "Preparing cloud-init based VM template"
    
    # Create namespace if it doesn't exist
    if ! oc get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        print_info "Creating namespace: ${NAMESPACE}"
        oc create namespace "${NAMESPACE}"
    fi
    
    # Check if secret already exists
    if oc get secret rhel-roxagent-cloudinit -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_warn "Cloud-init secret already exists, updating..."
        oc delete secret rhel-roxagent-cloudinit -n "${NAMESPACE}"
    fi
    
    # Create cloud-init secret with roxagent configuration
    print_info "Creating cloud-init configuration secret..."
    
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: rhel-roxagent-cloudinit
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  userdata: |
    #cloud-config
    hostname: rhel-roxagent-vm
    
    users:
      - default
      - name: rhacs
        groups: sudo
        shell: /bin/bash
        sudo: ['ALL=(ALL) NOPASSWD:ALL']
        lock_passwd: false
        plain_text_passwd: redhat
    
    chpasswd:
      list: |
        rhacs:redhat
        cloud-user:redhat
      expire: false
    
    packages:
      - curl
      - wget
      - systemd
    
    runcmd:
      # Download roxagent binary
      - mkdir -p /opt/roxagent
      - curl -L -o /opt/roxagent/roxagent ${ROXAGENT_URL}
      - chmod +x /opt/roxagent/roxagent
      
      # Create systemd service
      - |
        cat > /etc/systemd/system/roxagent.service <<'EOFS'
        [Unit]
        Description=RHACS Virtual Machine Vulnerability Agent
        After=network-online.target
        Wants=network-online.target
        
        [Service]
        Type=simple
        ExecStart=/opt/roxagent/roxagent --daemon --index-interval=5m --verbose
        Restart=always
        RestartSec=10
        User=root
        StandardOutput=journal
        StandardError=journal
        Environment="ROX_VIRTUAL_MACHINES_VSOCK_PORT=818"
        Environment="ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384"
        
        [Install]
        WantedBy=multi-user.target
        EOFS
      
      # Enable and start service
      - systemctl daemon-reload
      - systemctl enable roxagent.service
      - systemctl start roxagent.service
    
    write_files:
      - path: /etc/profile.d/roxagent.sh
        permissions: '0644'
        content: |
          export ROX_VIRTUAL_MACHINES_VSOCK_PORT=818
          export ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384
      
      - path: /usr/local/bin/roxagent-scan
        permissions: '0755'
        content: |
          #!/bin/bash
          /opt/roxagent/roxagent --verbose
    
    final_message: "RHACS roxagent VM ready!"
EOF
    
    print_info "✓ Cloud-init secret created: rhel-roxagent-cloudinit"
    echo ""
    print_info "Next step: Run ./03-deploy-vm.sh to deploy VMs"
    echo ""
    print_info "What cloud-init will do on VM first boot:"
    print_info "  1. Download roxagent from: ${ROXAGENT_URL}"
    print_info "  2. Create systemd service for daemon mode"
    print_info "  3. Configure environment variables"
    print_info "  4. Start roxagent service automatically"
}

#================================================================
# Build custom QCOW2 image
#================================================================
build_custom_image() {
    print_step "Building custom QCOW2 image with roxagent"
    
    # Check prerequisites
    local missing_tools=()
    
    if ! command -v virt-customize >/dev/null 2>&1; then
        missing_tools+=("virt-customize (libguestfs-tools)")
    fi
    
    if ! command -v qemu-img >/dev/null 2>&1; then
        missing_tools+=("qemu-img (qemu-utils)")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools for custom image building:"
        for tool in "${missing_tools[@]}"; do
            print_error "  - ${tool}"
        done
        echo ""
        print_info "Install on RHEL/Fedora: sudo dnf install libguestfs-tools qemu-img"
        print_info "Install on Ubuntu: sudo apt install libguestfs-tools qemu-utils"
        echo ""
        print_warn "Falling back to cloud-init method..."
        IMAGE_METHOD="cloud-init"
        prepare_cloudinit_template
        return 0
    fi
    
    print_warn "Custom image building requires:"
    print_warn "  1. A base RHEL QCOW2 image"
    print_warn "  2. Significant time (10-15 minutes)"
    print_warn "  3. Manual upload to OpenShift"
    echo ""
    print_info "For automated deployment, use cloud-init method instead"
    echo ""
    
    read -p "Continue with custom image build? (y/n): " answer
    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        print_info "Switching to cloud-init method..."
        IMAGE_METHOD="cloud-init"
        prepare_cloudinit_template
        return 0
    fi
    
    # Run the detailed build script
    if [ -f "./build-custom-image.sh" ]; then
        print_info "Launching custom image builder..."
        ./build-custom-image.sh
    else
        print_error "build-custom-image.sh not found"
        print_info "Use cloud-init method instead"
        exit 1
    fi
}

#================================================================
# Main function
#================================================================
main() {
    print_info "=========================================="
    print_info "RHACS VM Image Preparation"
    print_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    print_info "Connected to: $(oc whoami --show-server 2>/dev/null || echo 'OpenShift')"
    echo ""
    
    # Select build method
    select_build_method
    echo ""
    
    # Execute based on method
    case "${IMAGE_METHOD}" in
        cloud-init)
            prepare_cloudinit_template
            ;;
        custom)
            build_custom_image
            ;;
        *)
            print_error "Unknown method: ${IMAGE_METHOD}"
            exit 1
            ;;
    esac
    
    print_info "=========================================="
    print_info "Image Preparation Complete"
    print_info "=========================================="
}

# Run main function
main "$@"
