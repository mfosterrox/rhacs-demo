#!/bin/bash

# Script: 04-deploy-perses-dashboard.sh
# Description: Deploy Perses dashboard and verify installation

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
readonly COO_NAMESPACE="openshift-cluster-observability-operator"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MONITORING_DIR="${SCRIPT_DIR}/monitoring"

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
# Deploy Perses Dashboard
#================================================================
deploy_perses_dashboard() {
    print_step "Deploying Perses Dashboard"
    echo "================================================================"
    
    print_info "Creating Perses datasource..."
    oc apply -f ${MONITORING_DIR}/perses/datasource.yaml
    
    print_info "Creating Perses dashboard..."
    oc apply -f ${MONITORING_DIR}/perses/dashboard.yaml
    
    print_info "Enabling Perses UI plugin..."
    oc apply -f ${MONITORING_DIR}/perses/ui-plugin.yaml
    
    print_info "✓ Perses dashboard deployed"
}

#================================================================
# Verify Installation
#================================================================
verify_installation() {
    print_step "Verifying Installation"
    echo "================================================================"
    
    local all_good=true
    
    # Check Cluster Observability Operator
    if oc get csv -n ${COO_NAMESPACE} 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"; then
        print_info "✓ Cluster Observability Operator: Running"
    else
        print_warn "⊘ Cluster Observability Operator: Not ready"
        all_good=false
    fi
    
    # Check MonitoringStack
    if oc get monitoringstack sample-stackrox-monitoring-stack -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_info "✓ MonitoringStack: Created"
    else
        print_warn "⊘ MonitoringStack: Not found"
        all_good=false
    fi
    
    # Check ScrapeConfig
    if oc get scrapeconfig sample-stackrox-scrape-config -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_info "✓ ScrapeConfig: Created"
    else
        print_warn "⊘ ScrapeConfig: Not found"
        all_good=false
    fi
    
    # Check Perses Dashboard
    if oc get persesdashboard sample-stackrox-dashboard -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_info "✓ Perses Dashboard: Created"
    else
        print_warn "⊘ Perses Dashboard: Not found"
        all_good=false
    fi
    
    # Check Perses Datasource
    if oc get persesdatasource sample-stackrox-datasource -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_info "✓ Perses Datasource: Created"
    else
        print_warn "⊘ Perses Datasource: Not found"
        all_good=false
    fi
    
    # Check UI Plugin
    if oc get uiplugin monitoring >/dev/null 2>&1; then
        print_info "✓ UI Plugin: Enabled"
    else
        print_warn "⊘ UI Plugin: Not found"
        all_good=false
    fi
    
    if [ "${all_good}" = true ]; then
        return 0
    else
        return 1
    fi
}

#================================================================
# Display Access Information
#================================================================
display_access_info() {
    print_step "Access Information"
    echo "================================================================"
    
    local console_url=$(oc get route console -n openshift-console -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    
    echo ""
    print_info "🎉 RHACS Dashboard Setup Complete!"
    echo ""
    print_info "Access the dashboard:"
    echo ""
    print_info "  1. OpenShift Console: ${console_url}"
    print_info "  2. Navigate to: Observe → Dashboards"
    print_info "  3. Look for: 'Advanced Cluster Security / Overview'"
    echo ""
    print_info "The dashboard includes:"
    print_info "  • Total policy violations"
    print_info "  • Total policies enabled"
    print_info "  • Policy violations by severity"
    print_info "  • Total vulnerabilities"
    print_info "  • Fixable vulnerabilities"
    print_info "  • Cluster health status"
    print_info "  • Certificate expiry monitoring"
    echo ""
    print_info "Metrics are gathered every 1 minute for real-time monitoring."
    echo ""
}

#================================================================
# Main Function
#================================================================
main() {
    # Check prerequisites
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    if [ ! -d "${MONITORING_DIR}" ]; then
        print_error "Monitoring directory not found: ${MONITORING_DIR}"
        exit 1
    fi
    
    # Deploy dashboard
    deploy_perses_dashboard
    echo ""
    
    # Wait for resources to be created
    print_info "Waiting for resources to stabilize..."
    sleep 10
    
    # Verify installation
    verify_installation
    echo ""
    
    # Display access information
    display_access_info
}

# Run main function
main "$@"
