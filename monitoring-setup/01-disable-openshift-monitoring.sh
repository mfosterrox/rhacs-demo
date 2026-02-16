#!/bin/bash

# Script: 01-disable-openshift-monitoring.sh
# Description: Disable default OpenShift monitoring before setting up custom Prometheus
# Reference: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs#disabling-red-hat-openshift-monitoring-for-central-services-by-using-the-rhacs-operator_monitoring-using-prometheus

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Print functions
print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Error handler
error_handler() {
    local exit_code=$1
    local line_number=$2
    print_error "Error at line ${line_number} (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap 'error_handler $? $LINENO' ERR

#================================================================
# Check installation method
#================================================================
check_installation_method() {
    print_step "Detecting RHACS installation method" >&2
    echo "================================================================" >&2
    
    local installation_method=""
    
    # Check for Operator installation
    if oc get central -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        local central_name=$(oc get central -n ${RHACS_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [ -n "${central_name}" ]; then
            installation_method="operator"
            print_info "✓ Detected Operator installation" >&2
            print_info "  Central CR: ${central_name}" >&2
        fi
    fi
    
    # Check for Helm installation
    if [ -z "${installation_method}" ]; then
        if command -v helm >/dev/null 2>&1; then
            if helm list -n ${RHACS_NAMESPACE} 2>/dev/null | grep -q "stackrox-central-services\|rhacs-central-services"; then
                installation_method="helm"
                print_info "✓ Detected Helm installation" >&2
            fi
        fi
    fi
    
    # Check for manifest installation
    if [ -z "${installation_method}" ]; then
        if oc get deployment central -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
            installation_method="manifest"
            print_info "✓ Detected manifest installation" >&2
        fi
    fi
    
    if [ -z "${installation_method}" ]; then
        print_error "Could not detect RHACS installation"
        print_error "Ensure RHACS is installed in namespace: ${RHACS_NAMESPACE}"
        exit 1
    fi
    
    echo "${installation_method}"
}

#================================================================
# Check current monitoring status
#================================================================
check_monitoring_status() {
    print_step "Checking current monitoring configuration" >&2
    echo "================================================================" >&2
    
    local method=$1
    local monitoring_enabled="unknown"
    
    if [ "${method}" = "operator" ]; then
        local central_name=$(oc get central -n ${RHACS_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        monitoring_enabled=$(oc get central ${central_name} -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.monitoring.openshift.enabled}' 2>/dev/null || echo "not-set")
        
        if [ "${monitoring_enabled}" = "not-set" ] || [ -z "${monitoring_enabled}" ]; then
            print_info "OpenShift monitoring: enabled (default)" >&2
            monitoring_enabled="true"
        else
            print_info "OpenShift monitoring: ${monitoring_enabled}" >&2
        fi
    else
        print_info "Manual monitoring check required for ${method} installation" >&2
        monitoring_enabled="unknown"
    fi
    
    echo "${monitoring_enabled}"
}

#================================================================
# Disable OpenShift monitoring for Operator installation
#================================================================
disable_operator_monitoring() {
    print_step "Disabling OpenShift monitoring (Operator method)"
    echo "================================================================"
    
    local central_name=$(oc get central -n ${RHACS_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${central_name}" ]; then
        print_error "Central CR not found"
        exit 1
    fi
    
    print_info "Patching Central CR: ${central_name}"
    
    # Patch the Central CR to disable OpenShift monitoring
    oc patch central ${central_name} -n ${RHACS_NAMESPACE} --type=merge -p '
{
  "spec": {
    "monitoring": {
      "openshift": {
        "enabled": false
      }
    }
  }
}'
    
    print_info "✓ Central CR patched"
    
    # Wait for Central to restart
    print_info "Waiting for Central deployment to restart..."
    sleep 5
    
    if oc rollout status deployment/central -n ${RHACS_NAMESPACE} --timeout=5m >/dev/null 2>&1; then
        print_info "✓ Central deployment restarted successfully"
    else
        print_warn "⚠ Central deployment restart timed out or failed"
        print_info "  Check status with: oc get pods -n ${RHACS_NAMESPACE} -l app=central"
    fi
    
    # Verify ServiceMonitor was removed
    print_info "Verifying ServiceMonitor removal..."
    sleep 3
    
    if oc get servicemonitor -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=stackrox 2>/dev/null | grep -q "central"; then
        print_warn "⚠ ServiceMonitor still exists - may take a few moments to remove"
    else
        print_info "✓ ServiceMonitor removed"
    fi
}

#================================================================
# Disable OpenShift monitoring for Helm installation
#================================================================
disable_helm_monitoring() {
    print_step "Disabling OpenShift monitoring (Helm method)"
    echo "================================================================"
    
    print_info "For Helm installations, you must update your values and upgrade the chart"
    echo ""
    print_info "Steps to disable monitoring:"
    echo ""
    echo "1. Update your values file with:"
    echo ""
    echo "   monitoring:"
    echo "     openshift:"
    echo "       enabled: false"
    echo ""
    echo "2. Run helm upgrade:"
    echo ""
    echo "   helm upgrade stackrox-central-services \\"
    echo "     rhacs/central-services \\"
    echo "     -n ${RHACS_NAMESPACE} \\"
    echo "     -f your-values.yaml"
    echo ""
    
    print_warn "⚠ Please complete these steps manually before continuing"
    echo ""
    
    read -p "Have you disabled OpenShift monitoring via Helm? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Please disable OpenShift monitoring before running custom Prometheus setup"
        exit 1
    fi
    
    print_info "✓ User confirmed Helm monitoring disabled"
}

#================================================================
# Disable OpenShift monitoring for manifest installation
#================================================================
disable_manifest_monitoring() {
    print_step "Disabling OpenShift monitoring (Manifest method)"
    echo "================================================================"
    
    print_info "Checking for existing ServiceMonitor resources..."
    
    local servicemonitors=$(oc get servicemonitor -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=stackrox -o name 2>/dev/null || echo "")
    
    if [ -n "${servicemonitors}" ]; then
        print_info "Found ServiceMonitor resources:"
        echo "${servicemonitors}" | sed 's/^/  /'
        echo ""
        
        print_warn "Removing ServiceMonitor resources to avoid duplicate scraping..."
        oc delete servicemonitor -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=stackrox
        
        print_info "✓ ServiceMonitor resources removed"
    else
        print_info "✓ No ServiceMonitor resources found"
    fi
    
    print_info ""
    print_info "Note: If you created custom ServiceMonitors, remove them manually"
}

#================================================================
# Verify monitoring is disabled
#================================================================
verify_monitoring_disabled() {
    print_step "Verifying monitoring configuration"
    echo "================================================================"
    
    local method=$1
    
    # Check for ServiceMonitor resources
    local sm_count=$(oc get servicemonitor -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=stackrox 2>/dev/null | grep -v NAME | wc -l || echo "0")
    
    if [ "${sm_count}" -eq 0 ]; then
        print_info "✓ No RHACS ServiceMonitor resources found"
    else
        print_warn "⚠ Found ${sm_count} ServiceMonitor resource(s)"
        print_info "  These may cause duplicate scraping with custom Prometheus"
    fi
    
    # Check Central deployment env vars
    if [ "${method}" = "operator" ]; then
        local central_name=$(oc get central -n ${RHACS_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        local monitoring_status=$(oc get central ${central_name} -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.monitoring.openshift.enabled}' 2>/dev/null || echo "not-set")
        
        if [ "${monitoring_status}" = "false" ]; then
            print_info "✓ Central CR monitoring.openshift.enabled: false"
        else
            print_warn "⚠ Central CR monitoring status: ${monitoring_status}"
        fi
    fi
    
    print_info ""
    print_info "✓ Ready for custom Prometheus setup"
}

#================================================================
# Main Function
#================================================================
main() {
    print_info "========================================================================"
    print_info "Disable Default OpenShift Monitoring for RHACS"
    print_info "========================================================================"
    echo ""
    print_info "Reference: RHACS 4.9 Documentation - Section 15.2"
    print_info "https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs"
    echo ""
    
    # Check prerequisites
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    print_info "Connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    echo ""
    
    # Detect installation method
    local method=$(check_installation_method)
    echo ""
    
    # Check current monitoring status
    local current_status=$(check_monitoring_status "${method}")
    echo ""
    
    # If already disabled, skip
    if [ "${current_status}" = "false" ]; then
        print_info "✓ OpenShift monitoring is already disabled"
        verify_monitoring_disabled "${method}"
        exit 0
    fi
    
    # Disable monitoring based on installation method
    case "${method}" in
        operator)
            disable_operator_monitoring
            ;;
        helm)
            disable_helm_monitoring
            ;;
        manifest)
            disable_manifest_monitoring
            ;;
        *)
            print_error "Unknown installation method: ${method}"
            exit 1
            ;;
    esac
    
    echo ""
    
    # Verify configuration
    verify_monitoring_disabled "${method}"
    
    echo ""
    print_info "========================================================================"
    print_info "OpenShift Monitoring Disabled Successfully"
    print_info "========================================================================"
    echo ""
    print_info "Next steps:"
    print_info "  • Continue with: 02-install-cluster-observability-operator.sh"
    print_info "  • Or run: ./install.sh to complete the full setup"
    echo ""
}

# Run main function
main "$@"
