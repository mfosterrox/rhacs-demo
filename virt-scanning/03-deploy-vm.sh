#!/bin/bash

# Script: 03-deploy-vm.sh
# Description: Deploy RHEL VMs with roxagent for RHACS vulnerability scanning

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
readonly VM_NAME="${VM_NAME:-rhel-roxagent-vm}"
readonly VM_CPUS="${VM_CPUS:-2}"
readonly VM_MEMORY="${VM_MEMORY:-4Gi}"
readonly VM_DISK_SIZE="${VM_DISK_SIZE:-30Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}"  # Not readonly - may be set by user input
readonly RHEL_IMAGE="${RHEL_IMAGE:-registry.redhat.io/rhel9/rhel-guest-image:latest}"

#================================================================
# Check prerequisites
#================================================================
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # Check cloud-init secret exists
    if ! oc get secret rhel-roxagent-cloudinit -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_error "Cloud-init secret not found"
        print_info "Run: ./02-build-vm-image.sh first"
        return 1
    fi
    
    # Check OpenShift Virtualization
    if ! oc get namespace openshift-cnv >/dev/null 2>&1; then
        print_error "OpenShift Virtualization not installed"
        return 1
    fi
    
    # Auto-detect best storage class if default not available
    if ! oc get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
        print_warn "Default storage class not found: ${STORAGE_CLASS}"
        print_info "Auto-detecting best available storage class..."
        
        # Try to find default storage class
        local default_sc=$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
        
        if [ -n "${default_sc}" ]; then
            STORAGE_CLASS="${default_sc}"
            print_info "Using default storage class: ${STORAGE_CLASS}"
        else
            # Look for common OCS/ODF storage classes
            local ocs_sc=$(oc get storageclass -o name 2>/dev/null | grep -E 'ocs.*ceph-rbd|odf.*ceph-rbd' | head -1 | sed 's|storageclass.storage.k8s.io/||')
            
            if [ -n "${ocs_sc}" ]; then
                STORAGE_CLASS="${ocs_sc}"
                print_info "Using OCS/ODF storage class: ${STORAGE_CLASS}"
            else
                # Fall back to first available RWO storage class
                local first_sc=$(oc get storageclass -o name 2>/dev/null | head -1 | sed 's|storageclass.storage.k8s.io/||')
                
                if [ -n "${first_sc}" ]; then
                    STORAGE_CLASS="${first_sc}"
                    print_info "Using first available storage class: ${STORAGE_CLASS}"
                else
                    print_error "No storage classes found in cluster"
                    return 1
                fi
            fi
        fi
    fi
    
    print_info "✓ Prerequisites met"
}

#================================================================
# Check for existing VMs and clean up if needed
#================================================================
cleanup_existing_resources() {
    print_step "Checking for existing resources..."
    
    # Check if old DataVolume exists and clean it up
    if oc get datavolume rhel9-roxagent-base -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_warn "Found existing DataVolume, cleaning up..."
        oc delete datavolume rhel9-roxagent-base -n "${NAMESPACE}" --wait=false
    fi
    
    print_info "✓ Resource check complete"
}

#================================================================
# Deploy Virtual Machine
#================================================================
deploy_vm() {
    print_step "Deploying Virtual Machine: ${VM_NAME}"
    
    # Check if VM already exists
    if oc get vm "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_warn "VM already exists: ${VM_NAME}"
        read -p "Delete and recreate? (y/n): " answer
        if [[ "${answer}" =~ ^[Yy] ]]; then
            oc delete vm "${VM_NAME}" -n "${NAMESPACE}"
            # Wait for deletion
            while oc get vm "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; do
                print_info "Waiting for VM deletion..."
                sleep 2
            done
        else
            print_info "Skipping VM creation"
            return 0
        fi
    fi
    
    print_info "Creating VM with:"
    print_info "  Name: ${VM_NAME}"
    print_info "  CPUs: ${VM_CPUS}"
    print_info "  Memory: ${VM_MEMORY}"
    print_info "  Image: ${RHEL_IMAGE}"
    print_info "  vsock: enabled"
    print_info "  Storage: containerDisk (ephemeral)"
    
    cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: rhacs-scanning
    os: rhel9
    roxagent: enabled
  annotations:
    description: "RHEL VM with RHACS roxagent for vulnerability scanning"
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
        app: rhacs-scanning
        roxagent: enabled
    spec:
      domain:
        cpu:
          cores: ${VM_CPUS}
        devices:
          # CRITICAL: Enable vsock for RHACS communication
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
        machine:
          type: q35
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
              name: rhel-roxagent-cloudinit
EOF
    
    print_info "✓ VM created"
    
    # Wait for VM to start
    print_info "Waiting for VM to start..."
    sleep 5
    
    # Check VMI status
    local timeout=60
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        local phase=$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
        
        if [ "${phase}" = "Running" ]; then
            print_info "✓ VM is running"
            break
        fi
        
        echo -ne "\r  Status: ${phase} (${elapsed}s/${timeout}s)"
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""
    
    if [ $elapsed -ge $timeout ]; then
        print_warn "VM did not reach Running state within timeout"
        print_info "Check status with: oc get vmi ${VM_NAME} -n ${NAMESPACE}"
    fi
}

#================================================================
# Display access information
#================================================================
display_access_info() {
    print_step "VM Access Information"
    echo ""
    
    print_info "VM Details:"
    print_info "  Name: ${VM_NAME}"
    print_info "  Namespace: ${NAMESPACE}"
    echo ""
    
    print_info "Access VM console:"
    print_info "  virtctl console ${VM_NAME} -n ${NAMESPACE}"
    echo ""
    
    print_info "SSH access (if configured):"
    print_info "  virtctl ssh ${VM_NAME} -n ${NAMESPACE}"
    echo ""
    
    print_info "Check roxagent status (inside VM):"
    cat <<'EOF'
  virtctl console <vm-name>
  # Then inside VM:
  systemctl status roxagent
  journalctl -u roxagent -f
EOF
    echo ""
    
    print_info "VM will download and configure roxagent on first boot"
    print_info "This may take 2-3 minutes depending on network speed"
}

#================================================================
# Verify deployment
#================================================================
verify_deployment() {
    print_step "Verifying deployment..."
    echo ""
    
    # Check VM
    if oc get vm "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_info "✓ VM exists: ${VM_NAME}"
    else
        print_error "✗ VM not found: ${VM_NAME}"
        return 1
    fi
    
    # Check VMI
    if oc get vmi "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        local phase=$(oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        print_info "✓ VMI status: ${phase}"
    else
        print_warn "⚠ VMI not yet created"
    fi
    
    # Check vsock configuration
    local vsock=$(oc get vm "${VM_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}' 2>/dev/null || echo "false")
    if [ "${vsock}" = "true" ]; then
        print_info "✓ vsock enabled"
    else
        print_error "✗ vsock NOT enabled"
    fi
    
    # Check cloud-init
    if oc get vmi "${VM_NAME}" -n "${NAMESPACE}" -o yaml 2>/dev/null | grep -q "cloudinitdisk"; then
        print_info "✓ Cloud-init configured"
    else
        print_warn "⚠ Cloud-init configuration not verified"
    fi
    
    echo ""
    print_info "Run: ../01-check-env.sh to verify full RHACS integration"
}

#================================================================
# Main function
#================================================================
main() {
    print_info "=========================================="
    print_info "RHACS VM Deployment"
    print_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    print_info "Connected to: $(oc whoami --show-server 2>/dev/null || echo 'OpenShift')"
    echo ""
    
    check_prerequisites || exit 1
    echo ""
    
    # Clean up any existing resources
    cleanup_existing_resources
    echo ""
    
    # Deploy VM
    deploy_vm
    echo ""
    
    verify_deployment
    echo ""
    
    display_access_info
    
    print_info "=========================================="
    print_info "VM Deployment Complete"
    print_info "=========================================="
    echo ""
    print_info "Next steps:"
    print_info "  1. Wait 2-3 minutes for cloud-init to complete"
    print_info "  2. Access VM: virtctl console ${VM_NAME} -n ${NAMESPACE}"
    print_info "  3. Verify roxagent: systemctl status roxagent"
    print_info "  4. Check RHACS integration: ./01-check-env.sh"
}

# Run main function
main "$@"
