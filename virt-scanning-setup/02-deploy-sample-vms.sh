#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Apply rhel-webserver-vm.yaml (creates secret for cloud-init, deploys VM)
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
VM_TEMPLATE="${SCRIPT_DIR}/vm-templates/rhel-webserver-vm.yaml"
VM_NAMESPACE="${VM_NAMESPACE:-default}"
VM_NAME="${VM_NAME:-rhel-webserver}"

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster"
    exit 1
fi

if [ ! -f "${VM_TEMPLATE}" ]; then
    print_error "VM template not found: ${VM_TEMPLATE}"
    exit 1
fi

# Prompt for Red Hat subscription credentials (for VM entitlement)
if [ -z "${SUBSCRIPTION_USERNAME:-}" ]; then
    echo ""
    print_step "Red Hat subscription credentials (to entitle the VM for vulnerability scanning)"
    print_info "Credentials are used only at deploy time and are not stored in any file."
    read -r -p "Red Hat username: " SUBSCRIPTION_USERNAME
    [ -z "${SUBSCRIPTION_USERNAME}" ] && { print_error "Username is required"; exit 1; }
fi
if [ -z "${SUBSCRIPTION_PASSWORD:-}" ]; then
    read -r -s -p "Red Hat password: " SUBSCRIPTION_PASSWORD
    echo ""
    [ -z "${SUBSCRIPTION_PASSWORD}" ] && { print_error "Password is required"; exit 1; }
fi
export SUBSCRIPTION_USERNAME SUBSCRIPTION_PASSWORD

print_info "VM: ${VM_NAME} in namespace ${VM_NAMESPACE}"
echo ""

# Ensure namespace exists
if ! oc get namespace "${VM_NAMESPACE}" &>/dev/null; then
    print_info "Creating namespace ${VM_NAMESPACE}..."
    oc create namespace "${VM_NAMESPACE}"
fi

# Delete existing VM if present
if oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" &>/dev/null; then
    print_warn "VM ${VM_NAME} already exists. Deleting for fresh deploy..."
    oc delete vm "${VM_NAME}" -n "${VM_NAMESPACE}" --wait=false || true
    print_info "Waiting for cleanup..."
    sleep 10
fi

# Extract cloud-init userData from VM template and substitute credentials
print_step "Preparing cloud-init..."
CLOUD_INIT_CONTENT=$(awk '
    /userData: \|-/ { in_block=1; next }
    in_block && /^[ ]{0,12}[^ ]/ { exit }
    in_block { gsub(/^              /, ""); print }
' "${VM_TEMPLATE}" | envsubst '$SUBSCRIPTION_USERNAME $SUBSCRIPTION_PASSWORD')

# Create cloud-init secret (userData exceeds 2048 byte inline limit)
CLOUD_INIT_SECRET="${VM_NAME}-cloud-init"
print_step "Creating cloud-init secret ${CLOUD_INIT_SECRET}..."
echo "${CLOUD_INIT_CONTENT}" | oc create secret generic "${CLOUD_INIT_SECRET}" -n "${VM_NAMESPACE}" \
    --from-file=userdata=/dev/stdin --dry-run=client -o yaml | oc apply -f -

# Replace inline userData with userDataSecretRef + networkData, swap namespace, apply
print_step "Creating VM ${VM_NAME}..."
awk -v secret="${CLOUD_INIT_SECRET}" '
    /cloudInitNoCloud:/ { in_cloud=1; print; next }
    in_cloud && /userData: \|-/ {
        print "            userDataSecretRef:"
        print "              name: " secret
        print "            networkData: |"
        print "              version: 2"
        print "              ethernets:"
        print "                enp1s0:"
        print "                  dhcp4: true"
        in_block=1
        next
    }
    in_block && /^[ ]{0,12}[^ ]/ { in_block=0; in_cloud=0 }
    in_block { next }
    { print }
' "${VM_TEMPLATE}" | sed "s/namespace: default/namespace: ${VM_NAMESPACE}/g" | oc apply -f -

print_info "✓ VM ${VM_NAME} created and starting"
echo ""
print_info "Connect: virtctl console ${VM_NAME} -n ${VM_NAMESPACE}"
print_info "Login: cloud-user / redhat"
echo ""
