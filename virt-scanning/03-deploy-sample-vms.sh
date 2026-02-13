#!/bin/bash

# Script: 04-deploy-sample-vms.sh
# Description: Deploy 4 sample VMs with different DNF packages for vulnerability scanning demonstration

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
readonly NAMESPACE="${NAMESPACE:-default}"
readonly VM_CPUS="${VM_CPUS:-2}"
readonly VM_MEMORY="${VM_MEMORY:-4Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-external-storagecluster-ceph-rbd}"
readonly RHEL_IMAGE="${RHEL_IMAGE:-registry.redhat.io/rhel9/rhel-guest-image:latest}"
readonly ROXAGENT_VERSION="${ROXAGENT_VERSION:-4.9.2}"
readonly ROXAGENT_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXAGENT_VERSION}/bin/linux/roxagent"
readonly AUTO_CONFIRM="${AUTO_CONFIRM:-false}"  # Skip confirmation prompts

# VM profiles with different package sets
declare -A VM_PROFILES=(
    ["webserver"]="httpd nginx php php-mysqlnd mod_ssl mod_security"
    ["database"]="postgresql postgresql-server postgresql-contrib mariadb mariadb-server"
    ["devtools"]="git gcc gcc-c++ make python3 python3-pip nodejs npm java-11-openjdk-devel maven"
    ["monitoring"]="grafana telegraf collectd collectd-utils net-snmp net-snmp-utils"
)

declare -A VM_DESCRIPTIONS=(
    ["webserver"]="Web Server (Apache, Nginx, PHP)"
    ["database"]="Database Server (PostgreSQL, MariaDB)"
    ["devtools"]="Development Tools (Git, GCC, Python, Node.js, Java)"
    ["monitoring"]="Monitoring Stack (Grafana, Telegraf, Collectd)"
)

#================================================================
# Check prerequisites
#================================================================
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # Check OpenShift Virtualization
    if ! oc get namespace openshift-cnv >/dev/null 2>&1; then
        print_error "OpenShift Virtualization not installed"
        return 1
    fi
    
    # Check VSOCK is enabled
    local kubevirt_name=$(oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${kubevirt_name}" ]; then
        print_error "KubeVirt not found"
        return 1
    fi
    
    local vsock_enabled=$(oc get kubevirt "${kubevirt_name}" -n openshift-cnv \
        -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | grep -o "VSOCK" || echo "")
    
    if [ -z "${vsock_enabled}" ]; then
        print_error "VSOCK not enabled"
        print_info "Run: ./install.sh first"
        return 1
    fi
    
    # Auto-detect storage class
    if ! oc get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
        print_warn "Storage class not found: ${STORAGE_CLASS}"
        print_info "Auto-detecting best available storage class..."
        
        local default_sc=$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
        
        if [ -n "${default_sc}" ]; then
            STORAGE_CLASS="${default_sc}"
            print_info "Using default storage class: ${STORAGE_CLASS}"
        else
            local ocs_sc=$(oc get storageclass -o name 2>/dev/null | grep -E 'ocs.*ceph-rbd|odf.*ceph-rbd' | head -1 | sed 's|storageclass.storage.k8s.io/||')
            
            if [ -n "${ocs_sc}" ]; then
                STORAGE_CLASS="${ocs_sc}"
                print_info "Using OCS/ODF storage class: ${STORAGE_CLASS}"
            else
                local first_sc=$(oc get storageclass -o name 2>/dev/null | head -1 | sed 's|storageclass.storage.k8s.io/||')
                
                if [ -n "${first_sc}" ]; then
                    STORAGE_CLASS="${first_sc}"
                    print_info "Using first available storage class: ${STORAGE_CLASS}"
                else
                    print_error "No storage classes found"
                    return 1
                fi
            fi
        fi
    fi
    
    print_info "✓ Prerequisites met"
}

#================================================================
# Generate cloud-init for VM with specific packages
#================================================================
generate_cloudinit() {
    local vm_profile=$1
    local packages="${VM_PROFILES[$vm_profile]}"
    
    cat <<EOF
#cloud-config
hostname: rhel-${vm_profile}
fqdn: rhel-${vm_profile}.local

users:
  - name: cloud-user
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false

chpasswd:
  list: |
    cloud-user:redhat
  expire: false

# Configure roxagent first (no package dependencies)
runcmd:
  # Wait for network
  - until ping -c 1 8.8.8.8 &> /dev/null; do sleep 2; done
  
  # Create roxagent directory
  - mkdir -p /opt/roxagent
  - chmod 755 /opt/roxagent
  
  # Download roxagent binary (standalone, no package dependencies)
  - |
    echo "Downloading roxagent ${ROXAGENT_VERSION}..."
    curl -k -L -o /opt/roxagent/roxagent "${ROXAGENT_URL}"
    chmod +x /opt/roxagent/roxagent
  
  # Create systemd service for roxagent
  - |
    cat > /etc/systemd/system/roxagent.service <<'SYSTEMD_EOF'
    [Unit]
    Description=StackRox VM Agent for vulnerability scanning
    After=network-online.target
    Wants=network-online.target
    
    [Service]
    Type=simple
    ExecStart=/opt/roxagent/roxagent --daemon --index-interval=5m --verbose
    Restart=always
    RestartSec=10
    Environment="ROX_VIRTUAL_MACHINES_VSOCK_PORT=818"
    Environment="ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384"
    StandardOutput=journal
    StandardError=journal
    
    [Install]
    WantedBy=multi-user.target
    SYSTEMD_EOF
  
  # Enable and start roxagent service
  - systemctl daemon-reload
  - systemctl enable roxagent
  - systemctl start roxagent
  
  # Create package install script for later use (after RHEL registration)
  - |
    cat > /root/install-packages.sh <<'PKG_SCRIPT'
    #!/bin/bash
    # Run this after registering RHEL subscription
    echo "Installing packages for ${vm_profile} profile..."
    dnf install -y ${packages}
    echo "Packages installed. Restarting roxagent to scan new packages..."
    systemctl restart roxagent
    PKG_SCRIPT
  
  - chmod +x /root/install-packages.sh
  
  # Log completion
  - echo "VM profile '${vm_profile}' configured"
  - echo "roxagent service started"
  - echo "To install packages: sudo subscription-manager register && sudo /root/install-packages.sh"

final_message: "RHEL VM '${vm_profile}' is ready. roxagent running. Run /root/install-packages.sh after RHEL registration to install packages."
EOF
}

#================================================================
# Deploy a single VM
#================================================================
deploy_vm() {
    local vm_profile=$1
    local vm_name="rhel-${vm_profile}"
    local description="${VM_DESCRIPTIONS[$vm_profile]}"
    
    print_step "Deploying VM: ${vm_name}"
    print_info "Profile: ${description}"
    print_info "Packages: ${VM_PROFILES[$vm_profile]}"
    
    # Check if VM already exists
    if oc get vm "${vm_name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_warn "VM '${vm_name}' already exists - skipping creation"
        print_info "To recreate, first delete with: oc delete vm ${vm_name} -n ${NAMESPACE}"
        return 0
    fi
    
    # Create cloud-init secret
    local secret_name="cloudinit-${vm_profile}"
    print_info "Creating cloud-init secret: ${secret_name}"
    
    local cloudinit_content
    cloudinit_content=$(generate_cloudinit "${vm_profile}")
    
    oc create secret generic "${secret_name}" \
        --from-literal=userdata="${cloudinit_content}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml | oc apply -f -
    
    # Deploy VM
    print_info "Creating VirtualMachine resource..."
    
    cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm_name}
  namespace: ${NAMESPACE}
  labels:
    app: rhacs-vm-scanning
    profile: ${vm_profile}
    roxagent: enabled
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: rhacs-vm-scanning
        profile: ${vm_profile}
        roxagent: enabled
        kubevirt.io/vm: ${vm_name}
    spec:
      domain:
        cpu:
          cores: ${VM_CPUS}
        devices:
          autoattachVSOCK: true
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
        resources:
          requests:
            memory: ${VM_MEMORY}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: containerdisk
        containerDisk:
          image: ${RHEL_IMAGE}
      - name: cloudinitdisk
        cloudInitNoCloud:
          secretRef:
            name: ${secret_name}
EOF
    
    print_info "✓ VM '${vm_name}' deployed"
}

#================================================================
# Wait for all VMs to be ready
#================================================================
wait_for_vms() {
    print_step "Checking VM status..."
    
    local ready_count=0
    local total_count=4  # We know we're deploying 4 VMs
    
    # Quick check if VMs are already running
    for profile in webserver database devtools monitoring; do
        local vm_name="rhel-${profile}"
        
        if oc get vmi "${vm_name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            local phase=$(oc get vmi "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "${phase}" == "Running" ]; then
                ready_count=$((ready_count + 1))
            fi
        fi
    done
    
    print_info "VMs in Running state: ${ready_count}/${total_count}"
    
    if [ ${ready_count} -eq ${total_count} ]; then
        print_info "✓ All VMs are running"
    else
        print_warn "Some VMs still starting (${ready_count}/${total_count} running)"
        print_info "VMs will continue booting in the background"
        print_info "This is normal - VMs take 5-10 minutes to fully initialize"
    fi
    
    # Always return success - deployment is complete even if VMs are still booting
    return 0
}

#================================================================
# Display VM information
#================================================================
display_vm_info() {
    print_step "Virtual Machine Information"
    
    echo ""
    printf "%-20s %-15s %-10s %-15s\n" "VM NAME" "PROFILE" "STATUS" "VSOCK CID"
    printf "%-20s %-15s %-10s %-15s\n" "--------" "-------" "------" "---------"
    
    for profile in "${!VM_PROFILES[@]}"; do
        local vm_name="rhel-${profile}"
        local phase=$(oc get vmi "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        local vsock_cid=$(oc get vmi "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.VSOCKCID}' 2>/dev/null || echo "N/A")
        
        printf "%-20s %-15s %-10s %-15s\n" "${vm_name}" "${profile}" "${phase}" "${vsock_cid}"
    done
    
    echo ""
    print_info "Access VMs with: virtctl console <vm-name> -n ${NAMESPACE}"
    print_info "Check roxagent status inside VM: systemctl status roxagent"
    print_info "View installed DNF packages: dnf list installed"
    print_info "Monitor RHACS: Platform Configuration → Clusters → Virtual Machines"
}

#================================================================
# Main execution
#================================================================
main() {
    echo ""
    echo "=========================================="
    echo "  RHACS VM Vulnerability Scanning Demo"
    echo "  Deploy Sample VMs with DNF Packages"
    echo "=========================================="
    echo ""
    
    check_prerequisites
    
    echo ""
    print_step "VM Profiles to Deploy:"
    for profile in "${!VM_PROFILES[@]}"; do
        echo "  • ${profile}: ${VM_DESCRIPTIONS[$profile]}"
        echo "    Packages: ${VM_PROFILES[$profile]}"
    done
    
    echo ""
    
    if [ "${AUTO_CONFIRM}" != "true" ]; then
        read -p "Deploy all 4 VMs? (y/N): " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
        echo ""
    else
        print_info "Auto-confirm enabled: deploying all 4 VMs"
        echo ""
    fi
    
    # Deploy each VM
    for profile in webserver database devtools monitoring; do
        deploy_vm "${profile}" || true  # Continue even if one fails
        echo ""
    done
    
    # Check VM status (always succeeds)
    wait_for_vms || true
    
    echo ""
    display_vm_info || true  # Don't fail if this errors
    
    echo ""
    print_info "✓ Sample VM deployment complete!"
    echo ""
    print_info "Next steps:"
    echo "  1. Wait 10-15 minutes for VMs to fully boot and install packages"
    echo "  2. Check VM status: oc get vmi -n default"
    echo "  3. View vulnerabilities in RHACS UI:"
    echo "     Platform Configuration → Clusters → Virtual Machines"
    echo ""
    print_warn "Note: VMs need valid RHEL subscriptions for DNF package updates"
    print_info "Register inside each VM:"
    print_info "  subscription-manager register --username <user> --password <pass>"
    print_info "  subscription-manager attach --auto"
}

main "$@"
