#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Deploy RHEL webserver VM with cloud-init (httpd, SSH password auth)
# Requires: 01-configure-rhacs.sh run first (RHACS + VSOCK)

set -euo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_NAMESPACE="${VM_NAMESPACE:-default}"
VM_NAME="${VM_NAME:-rhel-webserver}"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init/rhel-web-01-cloud-init.yaml"

# RHEL DataSource: rhel9 preferred, fallback to rhel8
get_rhel_datasource() {
    if oc get datasource rhel9 -n openshift-virtualization-os-images &>/dev/null; then
        echo "rhel9"
    elif oc get datasource rhel8 -n openshift-virtualization-os-images &>/dev/null; then
        echo "rhel8"
    else
        echo ""
    fi
}

# Ensure cloud-init file exists
if [ ! -f "${CLOUD_INIT_FILE}" ]; then
    print_error "Cloud-init file not found: ${CLOUD_INIT_FILE}"
    exit 1
fi

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster"
    exit 1
fi

RHEL_SOURCE=$(get_rhel_datasource)
if [ -z "${RHEL_SOURCE}" ]; then
    print_error "No RHEL DataSource found in openshift-virtualization-os-images"
    print_info "Ensure OpenShift Virtualization is installed and a RHEL boot source is configured"
    exit 1
fi

print_info "Using RHEL DataSource: ${RHEL_SOURCE}"
print_info "VM: ${VM_NAME} in namespace ${VM_NAMESPACE}"
echo ""

# Ensure namespace exists
if ! oc get namespace "${VM_NAMESPACE}" &>/dev/null; then
    print_info "Creating namespace ${VM_NAMESPACE}..."
    oc create namespace "${VM_NAMESPACE}"
fi

# Delete existing VM if present (for idempotent redeploy)
if oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" &>/dev/null; then
    print_warn "VM ${VM_NAME} already exists. Deleting for fresh deploy..."
    oc delete vm "${VM_NAME}" -n "${VM_NAMESPACE}" --wait=false || true
    print_info "Waiting for cleanup..."
    sleep 10
fi

# Create Secret for cloud-init (userData exceeds 2048 byte inline limit)
CLOUD_INIT_SECRET="${VM_NAME}-cloud-init"
print_step "Creating cloud-init secret ${CLOUD_INIT_SECRET}..."
oc create secret generic "${CLOUD_INIT_SECRET}" -n "${VM_NAMESPACE}" \
    --from-file=userdata="${CLOUD_INIT_FILE}" \
    --dry-run=client -o yaml | oc apply -f -

print_step "Creating VM ${VM_NAME} with cloud-init..."

# Create VM with userDataSecretRef (required when cloud-init > 2048 bytes)
oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${VM_NAMESPACE}
  labels:
    app: ${VM_NAME}
spec:
  running: true
  dataVolumeTemplates:
    - apiVersion: cdi.kubevirt.io/v1beta1
      kind: DataVolume
      metadata:
        name: ${VM_NAME}
      spec:
        sourceRef:
          kind: DataSource
          name: ${RHEL_SOURCE}
          namespace: openshift-virtualization-os-images
        storage:
          resources:
            requests:
              storage: 30Gi
  template:
    metadata:
      labels:
        kubevirt.io/domain: ${VM_NAME}
    spec:
      domain:
        cpu:
          cores: 2
          sockets: 1
          threads: 1
        memory:
          guest: 4Gi
        devices:
          autoattachVSOCK: true
          disks:
            - disk:
                bus: virtio
              name: rootdisk
            - disk:
                bus: virtio
              name: cloudinitdisk
          interfaces:
            - masquerade: {}
              name: default
          rng: {}
        machine:
          type: q35
      networks:
        - name: default
          pod: {}
      volumes:
        - dataVolume:
            name: ${VM_NAME}
          name: rootdisk
        - cloudInitNoCloud:
            userDataSecretRef:
              name: ${CLOUD_INIT_SECRET}
            networkData: |
              version: 2
              ethernets:
                enp1s0:
                  dhcp4: true
          name: cloudinitdisk
EOF

print_info "✓ VM ${VM_NAME} created and starting"
echo ""
print_info "Cloud-init will:"
print_info "  • Set hostname: rhel-web-01"
print_info "  • Create user: cloud-user / redhat"
print_info "  • Enable SSH password auth"
print_info "  • Install and start httpd + firewalld"
print_info "  • Create test page at /var/www/html/index.html"
echo ""
print_info "Connect via console: virtctl console ${VM_NAME} -n ${VM_NAMESPACE}"
print_info "Login: cloud-user / redhat"
echo ""
