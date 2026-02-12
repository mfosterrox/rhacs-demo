#!/bin/bash

# Script: 02-configure-rhacs-metrics.sh
# Description: Configure RHACS for Prometheus metrics scraping

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
# Main Function
#================================================================
main() {
    print_step "Configuring RHACS Metrics"
    echo "================================================================"
    
    # Check prerequisites
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq not found"
        exit 1
    fi
    
    # Get Central URL
    local central_url=$(oc get route central -n ${RHACS_NAMESPACE} -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        exit 1
    fi
    
    print_info "Central URL: ${central_url}"
    
    # Check for API token
    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN environment variable is not set"
        print_error "Please set ROX_API_TOKEN before running this script"
        exit 1
    fi
    
    print_info "✓ Using API token from environment"
    
    # Get current configuration
    local api_host="${central_url#https://}"
    print_info "Fetching current RHACS configuration..."
    
    local current_config=$(curl -k -s \
        -H "Authorization: Bearer ${token}" \
        "https://${api_host}/v1/config" 2>&1)
    
    # Configure RHACS metrics
    print_info "Configuring RHACS metrics collection..."
    
    local config_payload=$(echo "${current_config}" | jq '
      .config.publicConfig.telemetry.enabled = true |
      .config.privateConfig.metrics.imageVulnerabilities.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.imageVulnerabilities.descriptors.cve_severity = {
        "labels": ["Cluster","CVE","IsPlatformWorkload","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.imageVulnerabilities.descriptors.deployment_severity = {
        "labels": ["Cluster","Namespace","Deployment","IsPlatformWorkload","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.imageVulnerabilities.descriptors.namespace_severity = {
        "labels": ["Cluster","Namespace","IsPlatformWorkload","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.policyViolations.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.policyViolations.descriptors.deployment_severity = {
        "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"]
      } |
      .config.privateConfig.metrics.policyViolations.descriptors.namespace_severity = {
        "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"]
      } |
      .config.privateConfig.metrics.nodeVulnerabilities.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.component_severity = {
        "labels": ["Cluster","Node","Component","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.cve_severity = {
        "labels": ["Cluster","CVE","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.node_severity = {
        "labels": ["Cluster","Node","IsFixable","Severity"]
      }
    ')
    
    # Apply configuration
    curl -k -s -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data "${config_payload}" \
        "https://${api_host}/v1/config" >/dev/null
    
    print_info "✓ RHACS metrics configured (1-minute gathering period)"
    print_info ""
    print_info "Metrics configured:"
    print_info "  • Image vulnerabilities (by CVE, deployment, namespace)"
    print_info "  • Policy violations (by deployment, namespace)"
    print_info "  • Node vulnerabilities (by component, CVE, node)"
    print_info "  • Gathering period: 1 minute"
}

# Run main function
main "$@"
