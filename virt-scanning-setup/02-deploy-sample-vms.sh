#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Deploy RHEL webserver VM from template with Red Hat subscription registration
# Requires: RH_USERNAME/RH_PASSWORD for subscription, or --skip-subscription
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
VM_DEPLOY_TEMPLATE="${SCRIPT_DIR}/vm-templates/rhel-webserver-vm-deploy.yaml"
VM_NAMESPACE="${VM_NAMESPACE:-default}"
VM_NAME="${VM_NAME:-rhel-webserver}"
SKIP_SUBSCRIPTION="${SKIP_SUBSCRIPTION:-false}"

# Parse args for credentials
while [[ $# -gt 0 ]]; do
    case $1 in
        --username)
            RH_USERNAME="$2"
            shift 2
            ;;
        --password)
            RH_PASSWORD="$2"
            shift 2
            ;;
        --skip-subscription)
            SKIP_SUBSCRIPTION=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--username USER] [--password PASS] [--skip-subscription]"
            echo ""
            echo "Deploys RHEL webserver VM with cloud-init (httpd, SSH password auth)."
            echo ""
            echo "Options:"
            echo "  --username USER     Red Hat subscription username (or set RH_USERNAME)"
            echo "  --password PASS     Red Hat subscription password (or set RH_PASSWORD)"
            echo "  --skip-subscription Skip subscription registration (manual registration required)"
            echo ""
            echo "Examples:"
            echo "  RH_USERNAME=user@example.com RH_PASSWORD=secret $0"
            echo "  $0 --username user@example.com --password secret"
            echo "  $0 --skip-subscription"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster"
    exit 1
fi

if [ ! -f "${VM_TEMPLATE}" ] || [ ! -f "${VM_DEPLOY_TEMPLATE}" ]; then
    print_error "VM templates not found in ${SCRIPT_DIR}/vm-templates/"
    exit 1
fi

# Require subscription credentials unless --skip-subscription
if [ "${SKIP_SUBSCRIPTION}" != "true" ]; then
    RH_USERNAME="${RH_USERNAME:-}"
    RH_PASSWORD="${RH_PASSWORD:-}"
    if [ -z "${RH_USERNAME}" ] || [ -z "${RH_PASSWORD}" ]; then
        print_error "Red Hat subscription credentials required for auto-registration"
        echo ""
        print_info "Provide credentials via:"
        echo "  RH_USERNAME=user@example.com RH_PASSWORD=secret $0"
        echo "  $0 --username user@example.com --password secret"
        echo ""
        print_info "Or skip subscription (manual registration in VM):"
        echo "  $0 --skip-subscription"
        exit 1
    fi
fi

print_info "VM: ${VM_NAME} in namespace ${VM_NAMESPACE}"
[ "${SKIP_SUBSCRIPTION}" = "true" ] && print_warn "Subscription: skipped (manual registration required)"
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

# Extract cloud-init userData from VM template
print_step "Preparing cloud-init..."
CLOUD_INIT_CONTENT=$(awk '
    /userData: \|-/ { in_block=1; next }
    in_block && /^[ ]{0,12}[^ ]/ { exit }
    in_block { gsub(/^              /, ""); print }
' "${VM_TEMPLATE}")

# Remove rh_subscription block if skipping
if [ "${SKIP_SUBSCRIPTION}" = "true" ]; then
    CLOUD_INIT_CONTENT=$(echo "${CLOUD_INIT_CONTENT}" | sed '/^rh_subscription:/,/^packages:/{
        /^rh_subscription:/d
        /^  username:/d
        /^  password:/d
    }')
fi

# Substitute credentials
if [ "${SKIP_SUBSCRIPTION}" != "true" ]; then
    CLOUD_INIT_CONTENT=$(echo "${CLOUD_INIT_CONTENT}" | \
        sed "s|<YOUR_REDHAT_USERNAME>|${RH_USERNAME}|g" | \
        sed "s|<YOUR_REDHAT_PASSWORD>|${RH_PASSWORD}|g")
fi

# Create cloud-init secret
CLOUD_INIT_SECRET="${VM_NAME}-cloud-init"
print_step "Creating cloud-init secret ${CLOUD_INIT_SECRET}..."
echo "${CLOUD_INIT_CONTENT}" | oc create secret generic "${CLOUD_INIT_SECRET}" -n "${VM_NAMESPACE}" \
    --from-file=userdata=/dev/stdin --dry-run=client -o yaml | oc apply -f -

# Apply VM with secret reference
print_step "Creating VM ${VM_NAME}..."
sed -e "s/CLOUD_INIT_SECRET_NAME/${CLOUD_INIT_SECRET}/g" \
    -e "s/namespace: default/namespace: ${VM_NAMESPACE}/g" \
    "${VM_DEPLOY_TEMPLATE}" | oc apply -f -

print_info "✓ VM ${VM_NAME} created and starting"
echo ""
print_info "Cloud-init will:"
print_info "  • Set hostname: rhel-web-01"
print_info "  • Create user: cloud-user / redhat"
print_info "  • Enable SSH password auth"
[ "${SKIP_SUBSCRIPTION}" != "true" ] && print_info "  • Register with Red Hat subscription"
print_info "  • Install httpd, firewalld, curl, vim, git"
print_info "  • Create test page at /var/www/html/index.html"
echo ""
print_info "Connect: virtctl console ${VM_NAME} -n ${VM_NAMESPACE}"
print_info "Login: cloud-user / redhat"
echo ""
