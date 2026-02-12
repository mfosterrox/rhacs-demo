#!/bin/bash

# Script: 03-deploy-monitoring-stack.sh
# Description: Deploy Prometheus authentication and MonitoringStack

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
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
# Deploy Prometheus Authentication
#================================================================
deploy_prometheus_auth() {
    print_step "Deploying Prometheus Authentication"
    echo "================================================================"
    
    print_info "Creating ServiceAccount and token..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/service-account.yaml
    
    print_info "Configuring RHACS RBAC for Prometheus..."
    oc apply -f ${MONITORING_DIR}/rhacs/declarative-configuration-configmap.yaml
    
    # Wait for token to be populated
    print_info "Waiting for service account token..."
    local max_wait=60
    local waited=0
    
    while [ ${waited} -lt ${max_wait} ]; do
        local token=$(oc get secret sample-stackrox-prometheus-token -n ${RHACS_NAMESPACE} -o jsonpath='{.data.token}' 2>/dev/null || echo "")
        if [ -n "${token}" ]; then
            print_info "✓ Service account token ready"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    print_info "✓ Prometheus authentication configured"
}

#================================================================
# Deploy MonitoringStack
#================================================================
deploy_monitoring_stack() {
    print_step "Deploying MonitoringStack"
    echo "================================================================"
    
    print_info "Creating MonitoringStack..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/monitoring-stack.yaml
    
    print_info "Creating ScrapeConfig..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/scrape-config.yaml
    
    print_info "✓ MonitoringStack deployed"
    print_info ""
    print_info "Resources created:"
    print_info "  • ServiceAccount: sample-stackrox-prometheus"
    print_info "  • Secret: sample-stackrox-prometheus-token"
    print_info "  • ConfigMap: RHACS RBAC configuration"
    print_info "  • MonitoringStack: sample-stackrox-monitoring-stack"
    print_info "  • ScrapeConfig: sample-stackrox-scrape-config"
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
    
    # Execute setup steps
    deploy_prometheus_auth
    echo ""
    
    deploy_monitoring_stack
    
    # Wait for resources to stabilize
    print_info ""
    print_info "Waiting for resources to stabilize..."
    sleep 10
    
    # Verify MonitoringStack was created
    if oc get monitoringstack sample-stackrox-monitoring-stack -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_info "✓ MonitoringStack created successfully"
    else
        print_warn "⊘ MonitoringStack not found - may still be creating"
    fi
}

# Run main function
main "$@"
