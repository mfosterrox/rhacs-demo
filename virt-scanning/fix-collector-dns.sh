#!/bin/bash

# Script: fix-collector-dns.sh
# Description: Fix Collector DNS resolution when hostNetwork is enabled

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
print_info "  Fix Collector DNS Resolution"
print_info "============================================"
echo ""

print_info "When hostNetwork: true is enabled for VSOCK access,"
print_info "Collector loses ability to resolve Kubernetes service names."
print_info "This fix adds dnsPolicy: ClusterFirstWithHostNet"
echo ""

# Check current DNS policy
print_info "Checking current Collector DNS policy..."
CURRENT_DNS=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.dnsPolicy}' 2>/dev/null || echo "None")
CURRENT_HOSTNET=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")

echo "  Current hostNetwork: ${CURRENT_HOSTNET}"
echo "  Current dnsPolicy: ${CURRENT_DNS}"
echo ""

if [ "${CURRENT_DNS}" == "ClusterFirstWithHostNet" ]; then
    print_info "✓ Collector already has correct DNS policy"
    print_info "Restarting Collector to apply changes..."
    oc rollout restart daemonset/collector -n ${RHACS_NAMESPACE}
else
    print_info "Applying hostNetwork + DNS policy fix..."
    
    oc patch daemonset collector -n ${RHACS_NAMESPACE} --type='json' -p='[
      {
        "op": "replace",
        "path": "/spec/template/spec/hostNetwork",
        "value": true
      },
      {
        "op": "add",
        "path": "/spec/template/spec/dnsPolicy",
        "value": "ClusterFirstWithHostNet"
      }
    ]'
    
    print_info "✓ Patches applied"
fi

echo ""
print_info "Waiting for Collector pods to restart..."
oc rollout status daemonset/collector -n ${RHACS_NAMESPACE} --timeout=5m

echo ""
print_info "============================================"
print_info "  Verifying Fix"
print_info "============================================"
echo ""

# Wait for collector to stabilize
sleep 15

print_info "Checking for DNS resolution errors..."
echo ""

DNS_ERRORS=$(oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --since=2m 2>/dev/null | grep -c "no such host" || echo "0")

if [ "${DNS_ERRORS}" -eq "0" ]; then
    print_info "✓ No DNS resolution errors found!"
else
    print_warn "⚠ Still seeing DNS errors (${DNS_ERRORS} occurrences)"
    print_info "This may take a moment to clear. Check logs:"
    oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --tail=20 | grep -iE "sensor|error"
fi

echo ""
print_info "Checking VM relay status..."
oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --tail=30 | grep -i "virtual machine relay"

echo ""
print_info "============================================"
print_info "  Next Steps"
print_info "============================================"
echo ""
echo "1. Wait 5 minutes for Collector to stabilize"
echo "2. Check for roxagent connections:"
echo "   $ oc logs -n stackrox -l app=collector -c compliance --since=10m | grep roxagent"
echo ""
echo "3. VMs should start reporting within 5-10 minutes"
echo "4. Check RHACS UI: Platform Configuration → Virtual Machines"
echo ""
