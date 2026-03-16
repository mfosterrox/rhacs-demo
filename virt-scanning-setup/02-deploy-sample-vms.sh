#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Apply rhel-webserver-vm.yaml with username/password substituted
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
    print_step "Red Hat subscription credentials (to entitle the VM)"
    read -r -p "Red Hat username: " SUBSCRIPTION_USERNAME
    [ -z "${SUBSCRIPTION_USERNAME}" ] && { print_error "Username is required"; exit 1; }
fi
if [ -z "${SUBSCRIPTION_PASSWORD:-}" ]; then
    read -r -s -p "Red Hat password: " SUBSCRIPTION_PASSWORD
    echo ""
    [ -z "${SUBSCRIPTION_PASSWORD}" ] && { print_error "Password is required"; exit 1; }
fi
export SUBSCRIPTION_USERNAME SUBSCRIPTION_PASSWORD

# Substitute credentials and apply VM template
print_step "Applying rhel-webserver-vm.yaml..."
envsubst '$SUBSCRIPTION_USERNAME $SUBSCRIPTION_PASSWORD' < "${VM_TEMPLATE}" | oc apply -f -

print_info "✓ VM rhel-webserver applied"
echo ""
print_info "Connect: virtctl console rhel-webserver -n default"
print_info "Login: cloud-user / redhat"
echo ""
