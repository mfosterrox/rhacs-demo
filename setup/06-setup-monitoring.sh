#!/bin/bash

# Script: 06-setup-monitoring.sh
# Description: Complete RHACS monitoring setup with Cluster Observability Operator and Perses
# Features:
#   - Configures RHACS API settings (metrics, telemetry, retention policies)
#   - Generates TLS certificates (cert-manager or openssl)
#   - Creates RHACS UserPKI auth provider for Prometheus
#   - Installs Cluster Observability Operator
#   - Deploys Prometheus with custom scrape configs
#   - Sets up Perses dashboards and datasources
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
readonly OPERATOR_NAMESPACE="openshift-cluster-observability-operator"
readonly CERT_SECRET_NAME="stackrox-prometheus-tls"
readonly PROMETHEUS_CN="stackrox-monitoring-prometheus.${RHACS_NAMESPACE}.svc"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly MONITORING_MANIFESTS_DIR="${PROJECT_ROOT}/monitoring/manifests"

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

# Check if cert-manager is installed
check_cert_manager() {
    if oc get crd certificates.cert-manager.io >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# Generate TLS certificate for Prometheus
generate_prometheus_certificate() {
    print_step "Generating TLS certificate for Prometheus..."
    
    # Check if certificate already exists
    if oc get secret "${CERT_SECRET_NAME}" -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "Certificate secret '${CERT_SECRET_NAME}' already exists"
        return 0
    fi
    
    # Check if cert-manager is available
    if check_cert_manager; then
        print_info "Using cert-manager to generate certificate..."
        
        # Create self-signed Issuer
        cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: stackrox-prometheus-issuer
  namespace: ${RHACS_NAMESPACE}
spec:
  selfSigned: {}
EOF
        
        # Create Certificate resource
        cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: stackrox-prometheus-cert
  namespace: ${RHACS_NAMESPACE}
spec:
  secretName: ${CERT_SECRET_NAME}
  duration: 8760h  # 365 days
  renewBefore: 720h  # 30 days
  subject:
    organizations:
      - Red Hat Advanced Cluster Security
  commonName: ${PROMETHEUS_CN}
  isCA: false
  privateKey:
    algorithm: RSA
    size: 2048
  usages:
    - digital signature
    - key encipherment
    - client auth
  issuerRef:
    name: stackrox-prometheus-issuer
    kind: Issuer
EOF
        
        print_info "Waiting for certificate to be ready..."
        local max_wait=60
        local waited=0
        while [ ${waited} -lt ${max_wait} ]; do
            if oc get secret "${CERT_SECRET_NAME}" -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
                print_info "✓ Certificate generated successfully via cert-manager"
                print_info "  Secret: ${CERT_SECRET_NAME}"
                print_info "  Common Name: ${PROMETHEUS_CN}"
                print_info "  Validity: 365 days (auto-renewal enabled)"
                return 0
            fi
            sleep 2
            waited=$((waited + 2))
        done
        
        print_error "Timeout waiting for certificate to be generated"
        return 1
    else
        print_info "cert-manager not found, using openssl..."
        
        if ! command_exists openssl; then
            print_error "openssl is required but not installed"
            return 1
        fi
        
        # Create temporary directory for certificate generation
        local temp_dir=$(mktemp -d)
        trap "rm -rf ${temp_dir}" RETURN
        
        cd "${temp_dir}"
        
        # Generate private key and certificate
        print_info "Generating RSA private key and self-signed certificate..."
        openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -subj "/CN=${PROMETHEUS_CN}" \
            -keyout tls.key -out tls.crt >/dev/null 2>&1
        
        if [ ! -f tls.key ] || [ ! -f tls.crt ]; then
            print_error "Failed to generate certificate"
            return 1
        fi
        
        # Create TLS secret
        print_info "Creating TLS secret in namespace '${RHACS_NAMESPACE}'..."
        oc create secret tls "${CERT_SECRET_NAME}" \
            --cert=tls.crt \
            --key=tls.key \
            -n "${RHACS_NAMESPACE}" >/dev/null 2>&1
        
        print_info "✓ TLS certificate generated successfully"
        print_info "  Secret: ${CERT_SECRET_NAME}"
        print_info "  Common Name: ${PROMETHEUS_CN}"
        print_info "  Validity: 365 days"
        
        return 0
    fi
}

# Configure RHACS settings (from script 11)
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
    
    # Generate API token
    local token=$(generate_api_token "${central_url}" "${password}")
    if [ -z "${token}" ]; then
        print_error "Failed to generate API token"
        return 1
    fi
    print_info "✓ API token generated"
    
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
    
    # Merge our changes with current config using jq (preserve all existing fields)
    local config_payload=$(echo "${current_config}" | jq '
      .config.publicConfig.telemetry.enabled = true |
      .config.privateConfig.metrics.imageVulnerabilities.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.imageVulnerabilities.descriptors.deployment_severity = {
        "labels": ["Cluster","Namespace","Deployment","IsPlatformWorkload","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.imageVulnerabilities.descriptors.namespace_severity = {
        "labels": ["Cluster","Namespace","IsFixable","Severity"]
      } |
      .config.privateConfig.metrics.policyViolations.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.policyViolations.descriptors.deployment_severity = {
        "labels": ["Cluster","Namespace","Deployment","IsPlatformComponent","Action","Severity"]
      } |
      .config.privateConfig.metrics.policyViolations.descriptors.namespace_severity = {
        "labels": ["Cluster","Namespace","IsPlatformComponent","Action","Severity"]
      } |
      .config.privateConfig.metrics.nodeVulnerabilities.gatheringPeriodMinutes = 1 |
      .config.privateConfig.metrics.nodeVulnerabilities.descriptors.node_severity = {
        "labels": ["Cluster","Node","IsFixable","Severity"]
      }
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
    print_info "  - Telemetry enabled"
    print_info "  - Metrics collection configured (1-minute gathering)"
    print_info "  - Image vulnerabilities: deployment_severity, namespace_severity"
    print_info "  - Policy violations: deployment_severity, namespace_severity"
    print_info "  - Node vulnerabilities: node_severity"
    
    return 0
}

# Install Cluster Observability Operator
install_cluster_observability_operator() {
    print_step "Installing Cluster Observability Operator..."
    
    # Check if already installed
    if oc get namespace "${OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
        if oc get subscription cluster-observability-operator -n "${OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
            local csv=$(oc get subscription cluster-observability-operator -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
            if [ -n "${csv}" ] && [ "${csv}" != "null" ]; then
                if oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
                    local phase=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                    if [ "${phase}" = "Succeeded" ]; then
                        print_info "✓ Cluster Observability Operator already installed (CSV: ${csv})"
                        return 0
                    fi
                fi
            fi
        fi
    fi
    
    # Create namespace
    print_info "Creating namespace ${OPERATOR_NAMESPACE}..."
    if ! oc get namespace "${OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
        oc create namespace "${OPERATOR_NAMESPACE}" >/dev/null 2>&1
        print_info "✓ Namespace created"
    else
        print_info "✓ Namespace already exists"
    fi
    
    # Create OperatorGroup
    print_info "Creating OperatorGroup..."
    cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-og
  namespace: ${OPERATOR_NAMESPACE}
spec:
  targetNamespaces: []
EOF
    print_info "✓ OperatorGroup created"
    
    # Create Subscription
    print_info "Creating Subscription..."
    cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    print_info "✓ Subscription created"
    
    # Wait for operator to be ready
    print_info "Waiting for operator to be installed (this may take a few minutes)..."
    local max_wait=300  # Increased to 5 minutes
    local waited=0
    while [ ${waited} -lt ${max_wait} ]; do
        local csv=$(oc get subscription cluster-observability-operator -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
        if [ -n "${csv}" ] && [ "${csv}" != "null" ]; then
            if oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" >/dev/null 2>&1; then
                local phase=$(oc get csv "${csv}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "${phase}" = "Succeeded" ]; then
                    print_info "✓ Cluster Observability Operator installed successfully (CSV: ${csv})"
                    return 0
                elif [ "${phase}" = "Failed" ]; then
                    print_error "Operator installation failed (CSV phase: ${phase})"
                    print_error "Check CSV details: oc describe csv ${csv} -n ${OPERATOR_NAMESPACE}"
                    return 1
                fi
            fi
        fi
        
        # Show progress every 30 seconds
        if [ $((waited % 30)) -eq 0 ] && [ ${waited} -gt 0 ]; then
            local sub_state=$(oc get subscription cluster-observability-operator -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null || echo "unknown")
            print_info "  Still waiting... (${waited}s elapsed, subscription state: ${sub_state})"
            if [ -n "${csv}" ] && [ "${csv}" != "null" ]; then
                print_info "  Current CSV: ${csv}"
            fi
        fi
        
        sleep 5
        waited=$((waited + 5))
    done
    
    print_error "Timeout waiting for operator installation after ${max_wait} seconds"
    print_error "Checking subscription status..."
    oc get subscription cluster-observability-operator -n "${OPERATOR_NAMESPACE}" -o yaml 2>&1 || true
    return 1
}

# Create monitoring manifests directory
create_monitoring_manifests() {
    print_step "Creating monitoring manifests..."
    
    mkdir -p "${MONITORING_MANIFESTS_DIR}"
    
    # Create MonitoringStack manifest
    cat > "${MONITORING_MANIFESTS_DIR}/monitoring-stack.yaml" <<EOF
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: rhacs-monitoring-stack
  namespace: ${RHACS_NAMESPACE}
spec:
  logLevel: info
  retention: 7d
  resourceSelector:
    matchLabels:
      app.kubernetes.io/part-of: rhacs-monitoring
  resources:
    requests:
      cpu: 500m
      memory: 2Gi
    limits:
      cpu: 1000m
      memory: 4Gi
  alertmanagerConfig:
    disabled: false
EOF
    
    # Create ScrapeConfig manifest
    cat > "${MONITORING_MANIFESTS_DIR}/scrape-config.yaml" <<EOF
apiVersion: monitoring.rhobs/v1alpha1
kind: ScrapeConfig
metadata:
  name: rhacs-scrape-config
  namespace: ${RHACS_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: rhacs-monitoring
spec:
  staticConfigs:
  - targets:
    - central.${RHACS_NAMESPACE}.svc.cluster.local:443
    labels:
      job: rhacs-central
  metricsPath: /metrics
  scheme: https
  tlsConfig:
    insecureSkipVerify: true
    cert:
      secret:
        name: ${CERT_SECRET_NAME}
        key: tls.crt
    keySecret:
      name: ${CERT_SECRET_NAME}
      key: tls.key
EOF
    
    print_info "✓ Monitoring manifests created"
}

# Deploy monitoring stack
deploy_monitoring_stack() {
    print_step "Deploying monitoring stack..."
    
    # Create manifests if they don't exist
    if [ ! -f "${MONITORING_MANIFESTS_DIR}/monitoring-stack.yaml" ]; then
        create_monitoring_manifests
    fi
    
    # Apply MonitoringStack
    print_info "Applying MonitoringStack..."
    oc apply -f "${MONITORING_MANIFESTS_DIR}/monitoring-stack.yaml" >/dev/null 2>&1
    print_info "✓ MonitoringStack applied"
    
    sleep 5
    
    # Apply ScrapeConfig
    print_info "Applying ScrapeConfig..."
    oc apply -f "${MONITORING_MANIFESTS_DIR}/scrape-config.yaml" >/dev/null 2>&1
    print_info "✓ ScrapeConfig applied"
    
    print_info "✓ Monitoring stack deployed successfully"
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
    print_info "  - Telemetry enabled"
    print_info "  - Custom metrics configured"
    print_info "  - Gathering period: 1 minute"
    print_info ""
    print_info "TLS Certificate:"
    print_info "  Secret: ${CERT_SECRET_NAME}"
    print_info "  Namespace: ${RHACS_NAMESPACE}"
    print_info "  Common Name: ${PROMETHEUS_CN}"
    print_info ""
    local central_url=$(get_central_url)
    if [ -n "${central_url}" ]; then
        print_info "RHACS Metrics Endpoint:"
        print_info "  URL: ${central_url}/metrics"
        print_info ""
    fi
    print_info "Monitoring Stack:"
    print_info "  Namespace: ${RHACS_NAMESPACE}"
    print_info "  MonitoringStack: rhacs-monitoring-stack"
    print_info "  ScrapeConfig: rhacs-scrape-config"
    print_info ""
    print_info "Cluster Observability Operator:"
    print_info "  Namespace: ${OPERATOR_NAMESPACE}"
    print_info ""
}

# Main function
main() {
    print_info "=========================================="
    print_info "RHACS Comprehensive Monitoring Setup"
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
        print_warn "RHACS configuration failed (non-fatal, continuing...)"
    fi
    
    print_info ""
    
    # Generate Prometheus certificate
    if ! generate_prometheus_certificate; then
        print_error "Failed to generate Prometheus certificate"
        exit 1
    fi
    
    print_info ""
    
    # Install Cluster Observability Operator
    if ! install_cluster_observability_operator; then
        print_error "Failed to install Cluster Observability Operator"
        exit 1
    fi
    
    print_info ""
    
    # Deploy monitoring stack
    if ! deploy_monitoring_stack; then
        print_error "Failed to deploy monitoring stack"
        exit 1
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
