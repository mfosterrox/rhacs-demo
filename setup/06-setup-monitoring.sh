#!/bin/bash

# Script: 06-setup-monitoring.sh
# Description: Configure RHACS monitoring with certificate-based authentication
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
readonly MONITORING_NAMESPACE="${RHACS_NAMESPACE}"
readonly CERT_SECRET_NAME="stackrox-prometheus-tls"
readonly PROMETHEUS_CN="stackrox-monitoring-prometheus.${MONITORING_NAMESPACE}.svc"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MANIFESTS_DIR="${SCRIPT_DIR}/../monitoring/manifests"

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
    
    if ! command_exists openssl; then
        missing_deps+=("openssl")
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
    
    print_info "✓ All prerequisites are installed"
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
    
    print_info "✓ RHACS is installed and ready"
    return 0
}

# Get Central URL
get_central_url() {
    local url
    url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "${url}" ]; then
        print_error "Could not determine Central URL" >&2
        return 1
    fi
    
    echo "https://${url}"
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
    if oc get secret "${CERT_SECRET_NAME}" -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
        print_info "Certificate secret '${CERT_SECRET_NAME}' already exists"
        return 0
    fi
    
    # Check if cert-manager is available
    if check_cert_manager; then
        print_info "Using cert-manager to generate certificate..."
        
        # Create Certificate resource
        cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: stackrox-prometheus-cert
  namespace: ${MONITORING_NAMESPACE}
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
        
        # Create self-signed Issuer
        cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: stackrox-prometheus-issuer
  namespace: ${MONITORING_NAMESPACE}
spec:
  selfSigned: {}
EOF
        
        print_info "Waiting for certificate to be ready..."
        local max_wait=60
        local waited=0
        while [ ${waited} -lt ${max_wait} ]; do
            if oc get secret "${CERT_SECRET_NAME}" -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1; then
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
        
        # Create temporary directory for certificate generation
        local temp_dir=$(mktemp -d)
        trap "rm -rf ${temp_dir}" EXIT
        
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
        
        # Create TLS secret in the monitoring namespace
        print_info "Creating TLS secret in namespace '${MONITORING_NAMESPACE}'..."
        oc create secret tls "${CERT_SECRET_NAME}" \
            --cert=tls.crt \
            --key=tls.key \
            -n "${MONITORING_NAMESPACE}" >/dev/null 2>&1
        
        print_info "✓ TLS certificate generated successfully"
        print_info "  Secret: ${CERT_SECRET_NAME}"
        print_info "  Common Name: ${PROMETHEUS_CN}"
        print_info "  Validity: 365 days"
        
        return 0
    fi
}

# Configure RHACS User Certificate auth provider
configure_rhacs_auth_provider() {
    print_step "Configuring RHACS User Certificate authentication..." >&2
    
    if [ -z "${ROX_PASSWORD:-}" ]; then
        print_error "ROX_PASSWORD is not set" >&2
        print_error "Please provide the password as an argument to install.sh" >&2
        return 1
    fi
    
    local central_url=$(get_central_url)
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL" >&2
        return 1
    fi
    
    print_info "Central URL: ${central_url}" >&2
    
    # Extract the certificate from the secret
    local cert_pem
    cert_pem=$(oc get secret "${CERT_SECRET_NAME}" -n "${MONITORING_NAMESPACE}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)
    
    if [ -z "${cert_pem}" ]; then
        print_error "Could not extract certificate from secret" >&2
        print_error "Secret: ${CERT_SECRET_NAME} in namespace ${MONITORING_NAMESPACE}" >&2
        return 1
    fi
    
    # Check if auth provider already exists
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    
    print_info "Checking for existing User Certificate auth provider..." >&2
    
    local existing_providers
    existing_providers=$(curl -k -s -u "admin:${ROX_PASSWORD}" \
        "https://${api_host}/v1/authProviders" 2>&1 || echo "")
    
    local provider_id=$(echo "${existing_providers}" | jq -r '.authProviders[] | select(.name == "Prometheus User Certificate") | .id' 2>/dev/null || echo "")
    
    if [ -n "${provider_id}" ] && [ "${provider_id}" != "null" ]; then
        print_info "User Certificate auth provider already exists (ID: ${provider_id})" >&2
        print_info "Skipping auth provider creation" >&2
        return 0
    fi
    
    # Create auth provider JSON payload using jq to properly escape the certificate
    local temp_file=$(mktemp)
    jq -n \
        --arg name "Prometheus User Certificate" \
        --arg type "userpki" \
        --arg endpoint "${central_url}" \
        --arg cert "${cert_pem}" \
        '{
          name: $name,
          type: $type,
          uiEndpoint: $endpoint,
          enabled: true,
          config: {
            keys: [$cert]
          }
        }' > "${temp_file}"
    
    # Validate JSON
    if ! jq . "${temp_file}" >/dev/null 2>&1; then
        print_error "Generated invalid JSON payload" >&2
        print_error "Debug: Check certificate format" >&2
        rm -f "${temp_file}"
        return 1
    fi
    
    print_info "Creating User Certificate auth provider..." >&2
    
    local response
    response=$(curl -k -s -w "\n%{http_code}" \
        -X POST \
        -u "admin:${ROX_PASSWORD}" \
        -H "Content-Type: application/json" \
        --data @"${temp_file}" \
        "https://${api_host}/v1/authProviders" 2>&1)
    
    rm -f "${temp_file}"
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
        print_error "Failed to create auth provider (HTTP ${http_code})" >&2
        print_error "URL: https://${api_host}/v1/authProviders" >&2
        print_error "Response: ${body:0:500}" >&2
        return 1
    fi
    
    print_info "✓ User Certificate auth provider created successfully" >&2
    
    return 0
}

# Apply declarative configuration for Prometheus permissions
apply_declarative_configuration() {
    print_step "Applying declarative configuration for Prometheus permissions..."
    
    if [ ! -f "${MANIFESTS_DIR}/declarative-configuration-configmap.yaml" ]; then
        print_error "Declarative configuration manifest not found"
        print_error "Expected: ${MANIFESTS_DIR}/declarative-configuration-configmap.yaml"
        return 1
    fi
    
    # Check if already exists
    if oc get configmap stackrox-prometheus-declarative-configuration -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        print_info "Declarative configuration already exists, updating..."
    fi
    
    oc apply -f "${MANIFESTS_DIR}/declarative-configuration-configmap.yaml" >/dev/null 2>&1
    
    print_info "✓ Declarative configuration applied"
    print_info "  ConfigMap: stackrox-prometheus-declarative-configuration"
    
    # Add declarative configuration to Central if not already present
    local current_config
    current_config=$(oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].spec.central.declarativeConfiguration}' 2>/dev/null || echo "")
    
    if echo "${current_config}" | grep -q "stackrox-prometheus-declarative-configuration"; then
        print_info "✓ Declarative configuration already referenced in Central CR"
    else
        print_info "Adding declarative configuration to Central CR..."
        oc patch central -n "${RHACS_NAMESPACE}" --type=merge -p '{
          "spec": {
            "central": {
              "declarativeConfiguration": {
                "configMaps": ["stackrox-prometheus-declarative-configuration"]
              }
            }
          }
        }' >/dev/null 2>&1 || print_warn "Could not patch Central CR (may require manual configuration)"
        
        print_info "✓ Declarative configuration added to Central CR"
        print_info "  Note: Central may restart to apply configuration"
    fi
    
    return 0
}

# Configure RHACS custom metrics
configure_custom_metrics() {
    print_step "Configuring RHACS custom metrics..."
    
    if [ -z "${ROX_PASSWORD:-}" ]; then
        print_error "ROX_PASSWORD is not set"
        return 1
    fi
    
    local central_url=$(get_central_url)
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        return 1
    fi
    
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    
    print_info "Configuring custom metrics for image vulnerabilities..."
    
    # Get current configuration
    local current_config
    current_config=$(curl -k -s -u "admin:${ROX_PASSWORD}" \
        "https://${api_host}/v1/config" 2>&1 || echo "")
    
    if [ -z "${current_config}" ]; then
        print_error "Failed to retrieve current configuration"
        return 1
    fi
    
    # Check if custom metrics are already configured
    local existing_metrics
    existing_metrics=$(echo "${current_config}" | jq -r '.privateConfig.metrics.imageVulnerabilities' 2>/dev/null || echo "null")
    
    if [ "${existing_metrics}" != "null" ]; then
        print_info "Custom metrics already configured"
        return 0
    fi
    
    # Create updated configuration with custom metrics
    local temp_file=$(mktemp)
    echo "${current_config}" | jq '.privateConfig.metrics.imageVulnerabilities = {
      gatheringPeriodMinutes: 10,
      descriptors: {
        deployment_severity: {
          labels: ["Cluster", "Namespace", "Deployment", "IsPlatformWorkload", "IsFixable", "Severity"]
        },
        namespace_severity: {
          labels: ["Cluster", "Namespace", "Severity"]
        }
      }
    } | { config: . }' > "${temp_file}"
    
    # Validate JSON
    if ! jq . "${temp_file}" >/dev/null 2>&1; then
        print_error "Generated invalid JSON payload"
        rm -f "${temp_file}"
        return 1
    fi
    
    # Apply configuration
    local response
    response=$(curl -k -s -w "\n%{http_code}" \
        -X PUT \
        -u "admin:${ROX_PASSWORD}" \
        -H "Content-Type: application/json" \
        --data @"${temp_file}" \
        "https://${api_host}/v1/config" 2>&1)
    
    rm -f "${temp_file}"
    
    local http_code=$(echo "${response}" | tail -n1)
    
    if [ "${http_code}" != "200" ] && [ "${http_code}" != "204" ]; then
        print_error "Failed to configure custom metrics (HTTP ${http_code})"
        return 1
    fi
    
    print_info "✓ Custom metrics configured successfully"
    print_info "  Gathering period: 10 minutes"
    print_info "  Metrics: deployment_severity, namespace_severity"
    
    return 0
}

# Display monitoring access information
display_monitoring_info() {
    print_info ""
    print_info "=========================================="
    print_info "Monitoring Configuration Summary"
    print_info "=========================================="
    print_info ""
    print_info "TLS Certificate:"
    print_info "  Secret: ${CERT_SECRET_NAME}"
    print_info "  Namespace: ${MONITORING_NAMESPACE}"
    print_info "  Common Name: ${PROMETHEUS_CN}"
    print_info ""
    print_info "RHACS Metrics Endpoint:"
    local central_url=$(get_central_url)
    print_info "  URL: ${central_url}/metrics"
    print_info ""
    print_info "Authentication:"
    print_info "  Type: User Certificate (TLS)"
    print_info "  Certificate Secret: ${CERT_SECRET_NAME}"
    print_info ""
    print_info "Permissions:"
    print_info "  Role: Prometheus Server"
    print_info "  Access: Read-only metrics access"
    print_info ""
    print_info "Test access with:"
    print_info "  oc exec -n ${MONITORING_NAMESPACE} <prometheus-pod> -- \\"
    print_info "    curl --cert /etc/prometheus/secrets/${CERT_SECRET_NAME}/tls.crt \\"
    print_info "         --key /etc/prometheus/secrets/${CERT_SECRET_NAME}/tls.key \\"
    print_info "         ${central_url}/metrics"
    print_info ""
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
    
    # Generate Prometheus certificate
    if ! generate_prometheus_certificate; then
        print_error "Failed to generate Prometheus certificate"
        exit 1
    fi
    
    print_info ""
    
    # Configure RHACS auth provider
    if ! configure_rhacs_auth_provider; then
        print_error "Failed to configure RHACS auth provider"
        exit 1
    fi
    
    print_info ""
    
    # Apply declarative configuration
    if ! apply_declarative_configuration; then
        print_error "Failed to apply declarative configuration"
        exit 1
    fi
    
    print_info ""
    
    # Configure custom metrics
    if ! configure_custom_metrics; then
        print_warn "Failed to configure custom metrics (optional)"
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
