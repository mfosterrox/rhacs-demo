#!/bin/bash

# Script: advanced-setup/install.sh
# Description: Advanced RHACS monitoring setup with OpenShift console dashboards
#              Installs Cluster Observability Operator and Perses dashboards
# Usage: ./advanced-setup/install.sh or cd advanced-setup && ./install.sh

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
# STEP 1: Install Cluster Observability Operator
#================================================================
install_cluster_observability_operator() {
    print_step "1. Installing Cluster Observability Operator (includes Perses)"
    echo "================================================================"
    
    # Check if already installed
    if oc get csv -n ${COO_NAMESPACE} 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"; then
        print_info "✓ Cluster Observability Operator already installed"
        return 0
    fi
    
    # Create namespace
    print_info "Creating namespace ${COO_NAMESPACE}..."
    oc create namespace ${COO_NAMESPACE} --dry-run=client -o yaml | oc apply -f -
    
    # Create OperatorGroup
    print_info "Creating OperatorGroup..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: ${COO_NAMESPACE}
spec:
  targetNamespaces: []
EOF
    
    # Create Subscription
    print_info "Creating Subscription..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: ${COO_NAMESPACE}
spec:
  channel: development
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    
    # Wait for CSV
    print_info "Waiting for operator installation (this may take 2-3 minutes)..."
    local max_wait=300
    local waited=0
    
    while [ ${waited} -lt ${max_wait} ]; do
        local csv_phase=$(oc get csv -n ${COO_NAMESPACE} -o jsonpath='{.items[?(@.metadata.name=~"cluster-observability-operator.*")].status.phase}' 2>/dev/null || echo "")
        
        if [ "${csv_phase}" = "Succeeded" ]; then
            print_info "✓ Cluster Observability Operator installed successfully"
            sleep 10  # Give it a moment to stabilize
            return 0
        fi
        
        if [ $((waited % 30)) -eq 0 ]; then
            print_info "Still waiting... (${waited}s/${max_wait}s) [Phase: ${csv_phase:-pending}]"
        fi
        
        sleep 10
        waited=$((waited + 10))
    done
    
    print_error "Operator installation timed out"
    return 1
}

#================================================================
# STEP 2: Configure RHACS for Prometheus Scraping
#================================================================
configure_rhacs_metrics() {
    print_step "2. Configuring RHACS Metrics"
    echo "================================================================"
    
    local central_url=$(oc get route central -n ${RHACS_NAMESPACE} -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        return 1
    fi
    
    print_info "Central URL: ${central_url}"
    
    # Get password
    local password="${ROX_PASSWORD:-}"
    if [ -z "${password}" ]; then
        password=$(oc get secret central-htpasswd -n ${RHACS_NAMESPACE} -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    
    if [ -z "${password}" ]; then
        print_error "Could not determine admin password. Set ROX_PASSWORD environment variable."
        return 1
    fi
    
    # Generate API token
    local api_host="${central_url#https://}"
    print_info "Generating API token..."
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"dashboard-setup-'$(date +%s)'","roles":["Admin"]}' 2>&1 || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        print_error "Failed to generate API token (HTTP ${http_code})"
        return 1
    fi
    
    local token=$(echo "${body}" | jq -r '.token' 2>/dev/null || echo "")
    if [ -z "${token}" ] || [ "${token}" = "null" ]; then
        print_error "Could not extract token from response"
        return 1
    fi
    
    print_info "✓ API token generated"
    
    # Configure RHACS metrics
    print_info "Configuring RHACS metrics collection..."
    
    local current_config=$(curl -k -s \
        -H "Authorization: Bearer ${token}" \
        "https://${api_host}/v1/config" 2>&1)
    
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
    
    curl -k -s -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data "${config_payload}" \
        "https://${api_host}/v1/config" >/dev/null
    
    print_info "✓ RHACS metrics configured (1-minute gathering period)"
}

#================================================================
# STEP 3: Deploy Prometheus Authentication
#================================================================
deploy_prometheus_auth() {
    print_step "3. Deploying Prometheus Authentication"
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
# STEP 4: Deploy MonitoringStack
#================================================================
deploy_monitoring_stack() {
    print_step "4. Deploying MonitoringStack"
    echo "================================================================"
    
    print_info "Creating MonitoringStack..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/monitoring-stack.yaml
    
    print_info "Creating ScrapeConfig..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/scrape-config.yaml
    
    print_info "✓ MonitoringStack deployed"
}

#================================================================
# STEP 5: Deploy Perses Dashboard
#================================================================
deploy_perses_dashboard() {
    print_step "5. Deploying Perses Dashboard"
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
# STEP 6: Verify Installation
#================================================================
verify_installation() {
    print_step "6. Verifying Installation"
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
# STEP 7: Display Access Information
#================================================================
display_access_info() {
    print_step "7. Access Information"
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
# Main Execution
#================================================================
main() {
    echo ""
    print_info "========================================================================"
    print_info "RHACS Advanced Monitoring Setup"
    print_info "========================================================================"
    echo ""
    print_info "This script installs advanced monitoring and dashboards:"
    print_info "  1. Cluster Observability Operator (includes Perses)"
    print_info "  2. RHACS metrics configuration"
    print_info "  3. Prometheus authentication (ServiceAccount + token)"
    print_info "  4. MonitoringStack for metrics collection"
    print_info "  5. Perses dashboards in OpenShift console"
    print_info "  6. UI plugin for console integration"
    echo ""
    
    # Check prerequisites
    if ! command -v oc >/dev/null 2>&1; then
        print_error "oc CLI not found"
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq not found"
        exit 1
    fi
    
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    if [ ! -d "${MONITORING_DIR}" ]; then
        print_error "Monitoring directory not found: ${MONITORING_DIR}"
        exit 1
    fi
    
    echo ""
    
    # Execute setup steps
    install_cluster_observability_operator
    echo ""
    
    configure_rhacs_metrics
    echo ""
    
    deploy_prometheus_auth
    echo ""
    
    deploy_monitoring_stack
    echo ""
    
    # Wait a moment for resources to be created
    print_info "Waiting for resources to stabilize..."
    sleep 15
    
    deploy_perses_dashboard
    echo ""
    
    verify_installation
    echo ""
    
    display_access_info
    
    print_info "========================================================================"
    print_info "Advanced Setup Complete!"
    print_info "========================================================================"
    echo ""
    print_info "Resources created:"
    print_info "  ✓ Cluster Observability Operator"
    print_info "  ✓ MonitoringStack (Prometheus with RHACS scraping)"
    print_info "  ✓ Perses Dashboard"
    print_info "  ✓ Perses Datasource"
    print_info "  ✓ UI Plugin (console integration)"
    echo ""
}

# Run main function
main "$@"
