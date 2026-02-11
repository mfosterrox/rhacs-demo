#!/bin/bash

# Script: 06-setup-monitoring.sh
# Description: Configure RHACS monitoring with certificates and deploy monitoring manifests
# Usage: ./06-setup-monitoring.sh

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly MONITORING_DIR="${PROJECT_ROOT}/monitoring"

# Trap errors
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_number=$2
    print_error "Error occurred in script at line ${line_number} (exit code: ${exit_code})"
    exit "${exit_code}"
}

# Print functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    local missing_deps=()
    
    if ! command_exists oc; then
        missing_deps+=("oc (OpenShift CLI)")
    fi
    
    if ! command_exists jq; then
        missing_deps+=("jq")
    fi
    
    if ! command_exists curl; then
        missing_deps+=("curl")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Missing required dependencies:"
        for dep in "${missing_deps[@]}"; do
            print_error "  - ${dep}"
        done
        return 1
    fi
    
    # Check cluster connection
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster. Please login first."
        return 1
    fi
    
    print_info "✓ All prerequisites are installed"
    print_info "✓ Connected to cluster as: $(oc whoami)"
    return 0
}

# Check if RHACS is installed
check_rhacs_installed() {
    print_step "Checking RHACS installation..."
    
    if ! oc get namespace "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_error "RHACS namespace '${RHACS_NAMESPACE}' not found"
        return 1
    fi
    
    if ! oc get deployment central -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_error "RHACS Central deployment not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    
    local central_ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
    if [ "${central_ready}" != "True" ]; then
        print_error "RHACS Central is not ready"
        return 1
    fi
    
    print_info "✓ RHACS is installed and ready in namespace '${RHACS_NAMESPACE}'"
    return 0
}

# Get Central URL
get_central_url() {
    local url
    url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "${url}" ]; then
        return 1
    fi
    
    echo "https://${url}"
    return 0
}

# Get admin password
get_admin_password() {
    local password
    
    # Try central-htpasswd secret
    password=$(oc get secret central-htpasswd -n "${RHACS_NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    
    if [ -z "${password}" ]; then
        # Try admin-password secret
        password=$(oc get secret admin-password -n "${RHACS_NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
    
    if [ -z "${password}" ]; then
        # Try using ROX_PASSWORD environment variable
        password="${ROX_PASSWORD:-}"
    fi
    
    echo "${password}"
}

# Generate API token
generate_api_token() {
    local central_url=$1
    local password=$2
    
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"monitoring-setup-token-'$(date +%s)'","roles":["Admin"]}' 2>&1 || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    
    local token=$(echo "${body}" | jq -r '.token' 2>/dev/null || echo "")
    if [ -z "${token}" ] || [ "${token}" = "null" ]; then
        return 1
    fi
    
    echo "${token}"
    return 0
}

# Wait for service account token to be populated
wait_for_service_account_token() {
    print_step "Waiting for service account token..."
    
    local max_wait=60
    local waited=0
    
    while [ ${waited} -lt ${max_wait} ]; do
        local token=$(oc get secret sample-stackrox-prometheus-token -n "${RHACS_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null || echo "")
        
        if [ -n "${token}" ] && [ "${token}" != "" ]; then
            print_info "✓ Service account token is ready"
            return 0
        fi
        
        sleep 2
        waited=$((waited + 2))
    done
    
    print_error "Timeout waiting for service account token"
    return 1
}

# Configure RHACS settings
configure_rhacs_settings() {
    print_step "Configuring RHACS API settings..."
    
    local central_url=$(get_central_url)
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        return 1
    fi
    
    local password=$(get_admin_password)
    if [ -z "${password}" ]; then
        print_error "Could not determine admin password"
        print_error "Please set ROX_PASSWORD environment variable or pass as argument to install.sh"
        return 1
    fi
    
    print_info "Central URL: ${central_url}"
    
    # Use provided API token or generate new one
    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_info "Generating API token..."
        token=$(generate_api_token "${central_url}" "${password}")
        if [ -z "${token}" ]; then
            print_error "Failed to generate API token"
            return 1
        fi
        print_info "✓ API token generated"
    else
        print_info "✓ Using API token from environment"
    fi
    
    # Get current configuration first
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    
    print_info "Getting current RHACS configuration..."
    local current_config=$(curl -k -s \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/config" 2>&1)
    
    if ! echo "${current_config}" | jq . >/dev/null 2>&1; then
        print_warn "Could not retrieve current configuration, skipping update"
        return 0  # Non-fatal
    fi
    
    # Merge comprehensive configuration (preserve all existing fields, update what we need)
    local config_payload=$(echo "${current_config}" | jq '
      # Public config
      .config.publicConfig.telemetry.enabled = true |
      
      # Private config - Alert retention
      .config.privateConfig.alertConfig.resolvedDeployRetentionDurationDays = 7 |
      .config.privateConfig.alertConfig.deletedRuntimeRetentionDurationDays = 7 |
      .config.privateConfig.alertConfig.allRuntimeRetentionDurationDays = 30 |
      .config.privateConfig.alertConfig.attemptedDeployRetentionDurationDays = 7 |
      .config.privateConfig.alertConfig.attemptedRuntimeRetentionDurationDays = 7 |
      
      # Image retention
      .config.privateConfig.imageRetentionDurationDays = 7 |
      .config.privateConfig.expiredVulnReqRetentionDurationDays = 90 |
      
      # Report retention
      .config.privateConfig.reportRetentionConfig.historyRetentionDurationDays = 7 |
      .config.privateConfig.reportRetentionConfig.downloadableReportRetentionDays = 7 |
      .config.privateConfig.reportRetentionConfig.downloadableReportGlobalRetentionBytes = 524288000 |
      
      # Vulnerability exception config (ensure it exists)
      .config.privateConfig.vulnerabilityExceptionConfig = (
        .config.privateConfig.vulnerabilityExceptionConfig // {
          "expiryOptions": {
            "dayOptions": [
              { "numDays": 14, "enabled": true },
              { "numDays": 30, "enabled": true },
              { "numDays": 60, "enabled": true },
              { "numDays": 90, "enabled": true }
            ],
            "fixableCveOptions": { "allFixable": true, "anyFixable": true },
            "customDate": false,
            "indefinite": false
          }
        }
      ) |
      
      # Administration events
      .config.privateConfig.administrationEventsConfig.retentionDurationDays = 4 |
      
      # Metrics - Image Vulnerabilities
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
      
      # Metrics - Policy Violations
      .config.privateConfig.metrics.policyViolations.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.policyViolations.descriptors.deployment_severity = {
        "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"]
      } |
      .config.privateConfig.metrics.policyViolations.descriptors.namespace_severity = {
        "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"]
      } |
      
      # Metrics - Node Vulnerabilities
      .config.privateConfig.metrics.nodeVulnerabilities.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.component_severity = {
        "labels": ["Cluster","Node","Component","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.cve_severity = {
        "labels": ["Cluster","CVE","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.node_severity = {
        "labels": ["Cluster","Node","IsFixable","Severity"]
      } |
      
      # Platform component config (Red Hat layered products)
      .config.platformComponentConfig.rules = [
        {
          "name": "red hat layered products",
          "namespaceRule": {
            "regex": "^aap$|^ack-system$|^aws-load-balancer-operator$|^cert-manager-operator$|^cert-utils-operator$|^costmanagement-metrics-operator$|^external-dns-operator$|^metallb-system$|^mtr$|^multicluster-engine$|^multicluster-global-hub$|^node-observability-operator$|^open-cluster-management$|^openshift-adp$|^openshift-apiserver-operator$|^openshift-authentication$|^openshift-authentication-operator$|^openshift-builds$|^openshift-cloud-controller-manager$|^openshift-cloud-controller-manager-operator$|^openshift-cloud-credential-operator$|^openshift-cloud-network-config-controller$|^openshift-cluster-csi-drivers$|^openshift-cluster-machine-approver$|^openshift-cluster-node-tuning-operator$|^openshift-cluster-observability-operator$|^openshift-cluster-samples-operator$|^openshift-cluster-storage-operator$|^openshift-cluster-version$|^openshift-cnv$|^openshift-compliance$|^openshift-config$|^openshift-config-managed$|^openshift-config-operator$|^openshift-console$|^openshift-console-operator$|^openshift-console-user-settings$|^openshift-controller-manager$|^openshift-controller-manager-operator$|^openshift-dbaas-operator$|^openshift-distributed-tracing$|^openshift-dns$|^openshift-dns-operator$|^openshift-dpu-network-operator$|^openshift-dr-system$|^openshift-etcd$|^openshift-etcd-operator$|^openshift-file-integrity$|^openshift-gitops-operator$|^openshift-host-network$|^openshift-image-registry$|^openshift-infra$|^openshift-ingress$|^openshift-ingress-canary$|^openshift-ingress-node-firewall$|^openshift-ingress-operator$|^openshift-insights$|^openshift-keda$|^openshift-kmm$|^openshift-kmm-hub$|^openshift-kni-infra$|^openshift-kube-apiserver$|^openshift-kube-apiserver-operator$|^openshift-kube-controller-manager$|^openshift-kube-controller-manager-operator$|^openshift-kube-scheduler$|^openshift-kube-scheduler-operator$|^openshift-kube-storage-version-migrator$|^openshift-kube-storage-version-migrator-operator$|^openshift-lifecycle-agent$|^openshift-local-storage$|^openshift-logging$|^openshift-machine-api$|^openshift-machine-config-operator$|^openshift-marketplace$|^openshift-migration$|^openshift-monitoring$|^openshift-mta$|^openshift-mtv$|^openshift-multus$|^openshift-netobserv-operator$|^openshift-network-diagnostics$|^openshift-network-node-identity$|^openshift-network-operator$|^openshift-nfd$|^openshift-nmstate$|^openshift-node$|^openshift-nutanix-infra$|^openshift-oauth-apiserver$|^openshift-openstack-infra$|^openshift-opentelemetry-operator$|^openshift-operator-lifecycle-manager$|^openshift-operators$|^openshift-operators-redhat$|^openshift-ovirt-infra$|^openshift-ovn-kubernetes$|^openshift-ptp$|^openshift-route-controller-manager$|^openshift-sandboxed-containers-operator$|^openshift-security-profiles$|^openshift-serverless$|^openshift-serverless-logic$|^openshift-service-ca$|^openshift-service-ca-operator$|^openshift-sriov-network-operator$|^openshift-storage$|^openshift-tempo-operator$|^openshift-update-service$|^openshift-user-workload-monitoring$|^openshift-vertical-pod-autoscaler$|^openshift-vsphere-infra$|^openshift-windows-machine-config-operator$|^openshift-workload-availability$|^redhat-ods-operator$|^rhacs-operator$|^rhdh-operator$|^service-telemetry$|^stackrox$|^submariner-operator$|^tssc-acs$|^openshift-devspaces$"
          }
        },
        {
          "name": "system rule",
          "namespaceRule": {
            "regex": "^openshift$|^openshift-apiserver$|^openshift-operators$|^kube-.*"
          }
        }
      ] |
      .config.platformComponentConfig.needsReevaluation = false
    ')
    
    # Update RHACS configuration
    print_info "Updating RHACS configuration..."
    local response=$(curl -k -s -w "\n%{http_code}" \
        -X PUT \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data "${config_payload}" \
        "https://${api_host}/v1/config" 2>&1)
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ] && [ "${http_code}" != "204" ]; then
        print_warn "Failed to update RHACS configuration (HTTP ${http_code})"
        print_warn "Response: ${body:0:200}"
        return 0  # Non-fatal
    fi
    
    print_info "✓ RHACS configuration updated successfully"
    print_info "  - Telemetry: Enabled"
    print_info "  - Metrics gathering: 1 minute"
    print_info "  - Image vulnerabilities: cve_severity, deployment_severity, namespace_severity"
    print_info "  - Policy violations: deployment_severity, namespace_severity"
    print_info "  - Node vulnerabilities: component_severity, cve_severity, node_severity"
    print_info "  - Retention policies: 7-day alerts, 30-day runtime, 90-day vuln requests"
    print_info "  - Platform components: Red Hat layered products recognized"
    
    return 0
}

# Apply monitoring manifests
apply_monitoring_manifests() {
    print_step "Applying monitoring manifests..."
    
    # Check if monitoring directory exists
    if [ ! -d "${MONITORING_DIR}" ]; then
        print_error "Monitoring directory not found: ${MONITORING_DIR}"
        return 1
    fi
    
    print_info "Monitoring directory: ${MONITORING_DIR}"
    
    # Apply all manifests recursively
    print_info "Applying manifests with: oc apply -f ${MONITORING_DIR}/ --recursive"
    
    local output
    output=$(oc apply -f "${MONITORING_DIR}/" --recursive 2>&1)
    local exit_code=$?
    
    if [ ${exit_code} -eq 0 ]; then
        print_info "✓ Monitoring manifests applied successfully"
        # Show what was created/updated
        echo "${output}" | while read -r line; do
            if [ -n "${line}" ]; then
                print_info "  ${line}"
            fi
        done
    else
        print_error "Failed to apply monitoring manifests"
        print_error "${output}"
        return 1
    fi
    
    return 0
}

# Display monitoring access information
display_monitoring_info() {
    print_info ""
    print_info "=========================================="
    print_info "Monitoring Configuration Summary"
    print_info "=========================================="
    print_info ""
    print_info "RHACS Configuration:"
    print_info "  - Telemetry: Enabled"
    print_info "  - Metrics: 1-minute gathering period"
    print_info "  - Image vulnerabilities: 3 metrics (cve, deployment, namespace)"
    print_info "  - Policy violations: 2 metrics (deployment, namespace)"
    print_info "  - Node vulnerabilities: 3 metrics (component, cve, node)"
    print_info "  - Retention: 7d alerts, 30d runtime, 90d vulnerabilities"
    print_info "  - Platform components: Red Hat products recognized"
    print_info ""
    print_info "Service Account Authentication:"
    print_info "  ServiceAccount: sample-stackrox-prometheus"
    print_info "  Token Secret: sample-stackrox-prometheus-token"
    print_info "  Namespace: ${RHACS_NAMESPACE}"
    print_info ""
    local central_url=$(get_central_url)
    if [ -n "${central_url}" ]; then
        print_info "RHACS Metrics Endpoint:"
        print_info "  URL: ${central_url}/metrics"
        print_info ""
    fi
    
    # Check what monitoring resources were deployed
    print_info "Deployed Monitoring Resources:"
    
    # Check for service account
    if oc get serviceaccount sample-stackrox-prometheus -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "  ✓ ServiceAccount: sample-stackrox-prometheus"
    fi
    
    # Check for token secret
    if oc get secret sample-stackrox-prometheus-token -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "  ✓ Secret: sample-stackrox-prometheus-token"
    fi
    
    # Check for declarative configuration
    if oc get configmap sample-stackrox-prometheus-declarative-configuration -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "  ✓ ConfigMap: sample-stackrox-prometheus-declarative-configuration"
    fi
    
    # Check for MonitoringStack
    if oc get monitoringstack sample-stackrox-monitoring-stack -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "  ✓ MonitoringStack: sample-stackrox-monitoring-stack"
    fi
    
    # Check for ScrapeConfig
    if oc get scrapeconfig sample-stackrox-scrape-config -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "  ✓ ScrapeConfig: sample-stackrox-scrape-config"
    fi
    
    print_info ""
    
    # Check if Cluster Observability Operator is installed
    if oc get namespace openshift-cluster-observability-operator >/dev/null 2>&1; then
        local pod_count=$(oc get pods -n openshift-cluster-observability-operator 2>/dev/null | grep -c Running || echo "0")
        if [ "${pod_count}" -gt 0 ]; then
            print_info "Cluster Observability Operator:"
            print_info "  Namespace: openshift-cluster-observability-operator"
            print_info "  Status: Running (${pod_count} pods)"
            print_info ""
        fi
    fi
}

# Main function
main() {
    print_info "=========================================="
    print_info "RHACS Monitoring Setup"
    print_info "=========================================="
    print_info ""
    
    # Check prerequisites
    if ! check_prerequisites; then
        print_error "Prerequisites check failed"
        exit 1
    fi
    
    print_info ""
    
    # Check RHACS installation
    if ! check_rhacs_installed; then
        print_error "RHACS is not installed or not ready"
        exit 1
    fi
    
    print_info ""
    
    # Configure RHACS settings
    if ! configure_rhacs_settings; then
        print_warn "RHACS configuration failed (continuing without it)"
    fi
    
    print_info ""
    
    # Apply all monitoring manifests
    if ! apply_monitoring_manifests; then
        print_error "Failed to apply monitoring manifests"
        exit 1
    fi
    
    print_info ""
    
    # Wait for service account token
    if ! wait_for_service_account_token; then
        print_warn "Service account token not ready yet (may take a few moments)"
    fi
    
    # Display monitoring information
    display_monitoring_info
    
    print_info "=========================================="
    print_info "Monitoring Setup Complete"
    print_info "=========================================="
    print_info ""
}

# Run main function
main "$@"
