#!/bin/bash

# Script: fix-collector-vsock.sh
# Description: Quick fix to enable hostNetwork on Collector for VSOCK support

set -euo pipefail

# Color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

RHACS_NAMESPACE="stackrox"

echo ""
print_info "============================================"
print_info "  Fix Collector VSOCK Error"
print_info "============================================"
echo ""

print_info "The error 'cannot assign requested address' occurs because"
print_info "the Collector needs hostNetwork: true to access VSOCK devices."
echo ""

# Check current state
print_info "Checking current Collector hostNetwork setting..."
CURRENT_HOSTNETWORK=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")
echo "  Current hostNetwork: ${CURRENT_HOSTNETWORK}"
echo ""

if [ "${CURRENT_HOSTNETWORK}" == "true" ]; then
    print_info "✓ Collector already has hostNetwork enabled"
    print_info "Restarting Collector to clear the error..."
    oc rollout restart daemonset/collector -n ${RHACS_NAMESPACE}
else
    print_info "Enabling hostNetwork on Collector daemonset..."
    
    oc patch daemonset collector -n ${RHACS_NAMESPACE} --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/hostNetwork",
        "value": true
      }
    ]'
    
    print_info "✓ Patch applied"
fi

echo ""
print_info "Waiting for Collector pods to restart..."
oc rollout status daemonset/collector -n ${RHACS_NAMESPACE} --timeout=5m

echo ""
print_info "============================================"
print_info "  Verifying Fix"
print_info "============================================"
echo ""

# Wait a moment for collector to start
sleep 10

print_info "Checking Collector logs for VSOCK errors..."
echo ""

VSOCK_ERRORS=$(oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --tail=50 2>/dev/null | grep -c "cannot assign requested address" || echo "0")

if [ "${VSOCK_ERRORS}" -eq "0" ]; then
    print_info "✓ No VSOCK binding errors found!"
    print_info ""
    print_info "Checking for successful VSOCK relay startup..."
    oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --tail=20 | grep -i "virtual machine relay"
else
    print_warn "⚠ Still seeing VSOCK errors. Checking logs..."
    oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --tail=30 | grep -iE "vsock|virtual|error"
fi

echo ""
print_info "============================================"
print_info "  Next Steps"
print_info "============================================"
echo ""
echo "1. Wait 5-10 minutes for VMs to complete cloud-init and start roxagent"
echo "2. Check RHACS UI: Platform Configuration → Virtual Machines"
echo "3. If still showing 'Not available', check inside a VM:"
echo "   # Install virtctl first if needed"
echo "   # Then: virtctl console rhel-webserver -n default"
echo "   # Inside VM: sudo systemctl status roxagent"
echo ""
