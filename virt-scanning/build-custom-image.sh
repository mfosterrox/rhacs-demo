#!/bin/bash

# Script: build-custom-image.sh
# Description: Build a custom RHEL image with roxagent pre-installed
# This script helps create a custom RHEL VM image for RHACS vulnerability scanning

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
readonly WORK_DIR="${WORK_DIR:-./image-build}"
readonly OUTPUT_IMAGE="${OUTPUT_IMAGE:-rhel9-roxagent.qcow2}"

#================================================================
# Display build options
#================================================================
display_options() {
    print_step "RHEL Image Build Options for RHACS roxagent"
    echo ""
    
    cat <<'EOF'
There are several ways to create a RHEL image with roxagent:

1. Cloud-init (Recommended for RHACM)
   ✓ Use standard RHEL image + cloud-init configuration
   ✓ No custom image building required
   ✓ Easy to update roxagent version
   ✓ Works with RHACM VM templates
   ✓ Use: cloud-init-roxagent.yaml and vm-template-rhacm.yaml

2. Image Builder / Composer (Best for production)
   ✓ Official Red Hat tool for custom images
   ✓ Fully supported, reproducible builds
   ✓ Can include roxagent, configs, and systemd services
   ✓ Requires Image Builder service (RHEL 8+)
   
3. Manual QCOW2 Customization (Advanced)
   ✓ Modify existing RHEL QCOW2 image directly
   ✓ Use virt-customize or guestfish
   ✓ Full control over image contents
   ✓ Requires libguestfs-tools

4. Container-based Build (Modern approach)
   ✓ Build bootable container with roxagent
   ✓ Use bootc/buildah
   ✓ Cloud-native workflow

EOF
    
    echo ""
    print_info "This script will guide you through option 3 (Manual QCOW2 Customization)"
    echo ""
}

#================================================================
# Check prerequisites
#================================================================
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v virt-customize >/dev/null 2>&1; then
        missing_tools+=("virt-customize (libguestfs-tools)")
    fi
    
    if ! command -v qemu-img >/dev/null 2>&1; then
        missing_tools+=("qemu-img (qemu-utils)")
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_tools+=("curl")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools:"
        for tool in "${missing_tools[@]}"; do
            print_error "  - ${tool}"
        done
        echo ""
        print_info "Install on RHEL/Fedora:"
        print_info "  sudo dnf install libguestfs-tools qemu-img curl"
        echo ""
        print_info "Install on Ubuntu/Debian:"
        print_info "  sudo apt install libguestfs-tools qemu-utils curl"
        return 1
    fi
    
    print_info "✓ All prerequisites met"
}

#================================================================
# Download base RHEL image
#================================================================
download_base_image() {
    print_step "Setting up base RHEL image..."
    
    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"
    
    print_warn "You need a RHEL base image (QCOW2 format)"
    echo ""
    print_info "Options to obtain base image:"
    print_info "  1. Download from Red Hat Customer Portal (requires subscription)"
    print_info "     https://access.redhat.com/downloads/content/rhel"
    print_info ""
    print_info "  2. Export from OpenShift Virtualization:"
    print_info "     virtctl image-export <pvc-name> --output-format=raw > rhel9.raw"
    print_info "     qemu-img convert -f raw -O qcow2 rhel9.raw rhel9.qcow2"
    print_info ""
    print_info "  3. Use RHEL Cloud Image (KVM guest image)"
    echo ""
    
    read -p "Enter path to RHEL base image (QCOW2): " base_image
    
    if [ ! -f "${base_image}" ]; then
        print_error "Image file not found: ${base_image}"
        return 1
    fi
    
    print_info "Creating working copy..."
    cp "${base_image}" "rhel-base.qcow2"
    
    print_info "✓ Base image ready: rhel-base.qcow2"
}

#================================================================
# Download roxagent
#================================================================
download_roxagent() {
    print_step "Downloading roxagent binary..."
    
    print_info "Downloading from: ${ROXAGENT_URL}"
    
    if ! curl -L -f -o roxagent "${ROXAGENT_URL}"; then
        print_error "Failed to download roxagent"
        print_info "Verify the version exists: ${ROXAGENT_VERSION}"
        return 1
    fi
    
    chmod +x roxagent
    
    print_info "✓ roxagent downloaded successfully"
}

#================================================================
# Create systemd service file
#================================================================
create_systemd_service() {
    print_step "Creating systemd service file..."
    
    cat > roxagent.service <<'EOF'
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

# Environment variables for roxagent
Environment="ROX_VIRTUAL_MACHINES_VSOCK_PORT=818"
Environment="ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384"

[Install]
WantedBy=multi-user.target
EOF
    
    print_info "✓ Systemd service file created"
}

#================================================================
# Customize image
#================================================================
customize_image() {
    print_step "Customizing RHEL image with roxagent..."
    
    print_info "This may take several minutes..."
    
    # Customize the image
    virt-customize -a rhel-base.qcow2 \
        --mkdir /opt/roxagent \
        --copy-in roxagent:/opt/roxagent/ \
        --chmod 0755:/opt/roxagent/roxagent \
        --copy-in roxagent.service:/etc/systemd/system/ \
        --run-command "systemctl enable roxagent.service" \
        --run-command "mkdir -p /etc/profile.d" \
        --write "/etc/profile.d/roxagent.sh:export ROX_VIRTUAL_MACHINES_VSOCK_PORT=818\nexport ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384" \
        --run-command "echo 'RHACS roxagent VM - systemctl status roxagent' > /etc/motd" \
        --selinux-relabel
    
    print_info "✓ Image customization complete"
}

#================================================================
# Finalize image
#================================================================
finalize_image() {
    print_step "Finalizing custom image..."
    
    # Compress the image
    print_info "Compressing image..."
    qemu-img convert -c -O qcow2 rhel-base.qcow2 "../${OUTPUT_IMAGE}"
    
    # Get image info
    local size=$(qemu-img info "../${OUTPUT_IMAGE}" | grep "virtual size" | awk '{print $3, $4}')
    
    cd ..
    
    print_info "✓ Custom image created: ${OUTPUT_IMAGE}"
    print_info "  Size: ${size}"
    print_info "  Location: $(pwd)/${OUTPUT_IMAGE}"
}

#================================================================
# Display upload instructions
#================================================================
display_upload_instructions() {
    print_step "Next Steps: Upload to OpenShift Virtualization"
    echo ""
    
    cat <<EOF
To use this image with OpenShift Virtualization:

1. Upload to OpenShift using virtctl:
   
   virtctl image-upload dv rhel9-roxagent \\
     --size=30Gi \\
     --image-path=${OUTPUT_IMAGE} \\
     --storage-class=ocs-storagecluster-ceph-rbd \\
     --namespace=default

2. Or create a DataVolume with HTTP source:
   
   # First, upload image to web server
   # Then create DataVolume:
   
   cat <<YAML | oc apply -f -
   apiVersion: cdi.kubevirt.io/v1beta1
   kind: DataVolume
   metadata:
     name: rhel9-roxagent
   spec:
     source:
       http:
         url: "https://your-server.com/${OUTPUT_IMAGE}"
     pvc:
       accessModes:
         - ReadWriteOnce
       resources:
         requests:
           storage: 30Gi
   YAML

3. Create VM using the uploaded image:
   
   Use the vm-template-rhacm.yaml and modify the volume source:
   
   volumes:
     - name: rootdisk
       persistentVolumeClaim:
         claimName: rhel9-roxagent

4. Deploy via RHACM:
   
   - Import the VM template into RHACM
   - Use placement policies to deploy to target clusters
   - Ensure vsock is enabled (autoattachVSOCK: true)

EOF
    
    echo ""
    print_info "Image ready for deployment!"
}

#================================================================
# Main function
#================================================================
main() {
    print_info "=========================================="
    print_info "RHEL Custom Image Builder for RHACS"
    print_info "=========================================="
    echo ""
    
    display_options
    
    read -p "Continue with manual QCOW2 customization? (y/n): " answer
    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        print_info "Aborted. Consider using cloud-init method instead."
        exit 0
    fi
    
    echo ""
    
    check_prerequisites || exit 1
    echo ""
    
    download_base_image || exit 1
    echo ""
    
    download_roxagent || exit 1
    echo ""
    
    create_systemd_service
    echo ""
    
    customize_image || exit 1
    echo ""
    
    finalize_image
    echo ""
    
    display_upload_instructions
    
    print_info "=========================================="
    print_info "Build Complete!"
    print_info "=========================================="
}

# Run main function
main "$@"
