#!/bin/bash
#
# Configure RHACS Central with Passthrough Route and Custom TLS Certificate
#
# This script:
# 1. Verifies Red Hat cert-manager Operator is installed (prerequisite)
# 2. Creates a Let's Encrypt ClusterIssuer
# 3. Generates a custom TLS certificate for Central via cert-manager
# 4. Configures Central to use the custom certificate
# 5. Changes the Central route from reencrypt/edge to passthrough termination
#
# Prerequisites:
# - OpenShift cluster with cluster-admin access
# - RHACS Central already installed
# - Red Hat cert-manager Operator for OpenShift (must be pre-installed)
# - Environment variables: RHACS_NAMESPACE, RHACS_ROUTE_NAME (optional)
#
# Usage:
#   ./07-configure-custom-tls.sh --email your@email.com [--staging]
#
# Options:
#   --email      Email address for Let's Encrypt registration (REQUIRED)
#   --staging    Use Let's Encrypt staging environment (for testing)
#
# Examples:
#   ./07-configure-custom-tls.sh --email admin@example.com
#   ./07-configure-custom-tls.sh --email admin@example.com --staging
#

set -euo pipefail

# Trap to show error location
trap 'echo "Error at line $LINENO"' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
RHACS_ROUTE_NAME="${RHACS_ROUTE_NAME:-central}"
CERT_MANAGER_NAMESPACE="cert-manager-operator"
CERT_MANAGER_OPERATOR_NAMESPACE="cert-manager-operator"
LETSENCRYPT_STAGING=false
LETSENCRYPT_EMAIL=""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#================================================================
# Utility Functions
#================================================================

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
    echo "================================================================"
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        print_error "$1 is not installed or not in PATH"
        return 1
    fi
    return 0
}

check_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-}
    
    if [ -n "${namespace}" ]; then
        oc get "${resource_type}" "${resource_name}" -n "${namespace}" &>/dev/null
    else
        oc get "${resource_type}" "${resource_name}" &>/dev/null
    fi
}

wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-300}
    
    print_info "Waiting for ${resource_type}/${resource_name} in namespace ${namespace}..."
    
    if oc wait "${resource_type}/${resource_name}" \
        -n "${namespace}" \
        --for=condition=Ready \
        --timeout="${timeout}s" 2>/dev/null; then
        return 0
    else
        # Fallback: check if resource exists
        if check_resource_exists "${resource_type}" "${resource_name}" "${namespace}"; then
            print_warn "Resource exists but may not have a Ready condition"
            return 0
        fi
        return 1
    fi
}

#================================================================
# Parse Arguments
#================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --staging)
                LETSENCRYPT_STAGING=true
                shift
                ;;
            --email)
                LETSENCRYPT_EMAIL="$2"
                shift 2
                ;;
            -h|--help)
                cat << EOF
Usage: $0 [OPTIONS]

Configure RHACS Central with passthrough route and custom TLS certificate.

Options:
  --staging           Use Let's Encrypt staging environment (for testing)
  --email EMAIL       Email address for Let's Encrypt registration (REQUIRED)
  -h, --help          Show this help message

Environment Variables:
  RHACS_NAMESPACE     RHACS namespace (default: stackrox)
  RHACS_ROUTE_NAME    Central route name (default: central)

Examples:
  $0 --email admin@example.com
  $0 --email admin@example.com --staging

EOF
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Validate required parameters
    if [ -z "${LETSENCRYPT_EMAIL}" ]; then
        print_error "Email address is required for Let's Encrypt registration"
        echo "Use: $0 --email your@email.com"
        exit 1
    fi
}

#================================================================
# Pre-flight Checks
#================================================================

preflight_checks() {
    print_step "Running pre-flight checks"
    
    # Check required commands
    check_command "oc" || exit 1
    check_command "kubectl" || exit 1
    check_command "curl" || exit 1
    
    # Check cluster connectivity
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift cluster"
        print_info "Please run: oc login"
        exit 1
    fi
    
    print_info "✓ Logged into cluster as: $(oc whoami)"
    
    # Check cluster-admin permissions
    if ! oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
        print_error "Insufficient permissions. This script requires cluster-admin access"
        exit 1
    fi
    print_info "✓ User has cluster-admin permissions"
    
    # Check if RHACS namespace exists
    if ! check_resource_exists "namespace" "${RHACS_NAMESPACE}"; then
        print_error "RHACS namespace '${RHACS_NAMESPACE}' does not exist"
        exit 1
    fi
    print_info "✓ RHACS namespace '${RHACS_NAMESPACE}' exists"
    
    # Check if Central is deployed
    if ! check_resource_exists "deployment" "central" "${RHACS_NAMESPACE}"; then
        print_error "RHACS Central deployment not found in namespace '${RHACS_NAMESPACE}'"
        print_info "Please install RHACS Central first"
        exit 1
    fi
    print_info "✓ RHACS Central deployment exists"
    
    # Check if route exists
    if ! check_resource_exists "route" "${RHACS_ROUTE_NAME}" "${RHACS_NAMESPACE}"; then
        print_error "Route '${RHACS_ROUTE_NAME}' not found in namespace '${RHACS_NAMESPACE}'"
        exit 1
    fi
    print_info "✓ Route '${RHACS_ROUTE_NAME}' exists"
    
    echo ""
}

#================================================================
# Verify Red Hat cert-manager Operator is Installed
#================================================================

install_cert_manager() {
    print_step "Verifying Red Hat cert-manager Operator for OpenShift"
    
    # Check if cert-manager operator namespace exists
    if ! check_resource_exists "namespace" "${CERT_MANAGER_OPERATOR_NAMESPACE}"; then
        print_error "cert-manager operator namespace '${CERT_MANAGER_OPERATOR_NAMESPACE}' not found"
        print_error ""
        print_error "PREREQUISITE NOT MET: Red Hat cert-manager Operator is not installed"
        print_error ""
        print_error "Please install the Red Hat cert-manager Operator first:"
        print_error "1. Open OpenShift Console → OperatorHub"
        print_error "2. Search for 'cert-manager Operator for Red Hat OpenShift'"
        print_error "3. Install from Red Hat operators"
        print_error "4. Use namespace: cert-manager-operator"
        print_error "5. Select channel: stable-v1.18"
        print_error ""
        print_error "Or install via CLI:"
        print_error "  oc create namespace cert-manager-operator"
        print_error "  oc apply -f - <<EOF"
        print_error "apiVersion: operators.coreos.com/v1"
        print_error "kind: OperatorGroup"
        print_error "metadata:"
        print_error "  name: cert-manager-operator"
        print_error "  namespace: cert-manager-operator"
        print_error "spec:"
        print_error "  targetNamespaces:"
        print_error "  - cert-manager-operator"
        print_error "---"
        print_error "apiVersion: operators.coreos.com/v1alpha1"
        print_error "kind: Subscription"
        print_error "metadata:"
        print_error "  name: cert-manager"
        print_error "  namespace: cert-manager-operator"
        print_error "spec:"
        print_error "  channel: stable-v1.18"
        print_error "  installPlanApproval: Automatic"
        print_error "  name: cert-manager"
        print_error "  source: redhat-operators"
        print_error "  sourceNamespace: openshift-marketplace"
        print_error "EOF"
        exit 1
    fi
    
    print_info "✓ cert-manager-operator namespace exists"
    
    # Check if cert-manager operator is installed (check for the actual pods/deployments)
    # This is more reliable than checking subscription which may have different names
    local operator_pod=$(oc get pods -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" -l app.kubernetes.io/name=cert-manager-operator -o name 2>/dev/null | head -1)
    
    if [ -z "${operator_pod}" ]; then
        # Try alternative label
        operator_pod=$(oc get pods -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep -i "cert-manager-operator-controller" | head -1)
    fi
    
    if [ -z "${operator_pod}" ]; then
        print_error "cert-manager operator pod not found in namespace '${CERT_MANAGER_OPERATOR_NAMESPACE}'"
        print_error ""
        print_error "PREREQUISITE NOT MET: cert-manager operator is not running"
        print_error ""
        print_error "Please install the Red Hat cert-manager Operator first:"
        print_error "1. Open OpenShift Console → OperatorHub"
        print_error "2. Search for 'cert-manager Operator for Red Hat OpenShift'"
        print_error "3. Install from Red Hat operators"
        print_error "4. Use namespace: cert-manager-operator"
        print_error "5. Select channel: stable-v1.18"
        exit 1
    fi
    
    print_info "✓ cert-manager operator pod found: ${operator_pod#*/}"
    
    # Check if operator pod is running
    local pod_status=$(oc get "${operator_pod}" -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "${pod_status}" != "Running" ]; then
        print_error "cert-manager operator pod is not running. Current status: ${pod_status}"
        print_error "Please check operator installation"
        exit 1
    fi
    
    print_info "✓ cert-manager operator is running"
    
    # Try to get CSV info for additional details (optional, don't fail if not found)
    local csv=$(oc get csv -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep -i cert-manager | head -1)
    if [ -n "${csv}" ]; then
        local csv_name=$(basename "${csv}")
        local phase=$(oc get "${csv}" -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [ "${phase}" = "Succeeded" ]; then
            print_info "✓ cert-manager CSV: ${csv_name} (${phase})"
        else
            print_warn "cert-manager CSV status: ${csv_name} (${phase})"
        fi
    fi
    
    # Verify cert-manager components exist and are ready
    print_info "Verifying cert-manager components..."
    
    # Check for deployments (names may vary by installation method)
    local component_count=0
    local ready_count=0
    
    # Try standard names first
    local possible_deployments=(
        "cert-manager"
        "cert-manager-controller-manager"
        "cert-manager-cainjector"
        "cert-manager-webhook"
    )
    
    for deploy in "${possible_deployments[@]}"; do
        if oc get deployment "${deploy}" -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" &>/dev/null; then
            component_count=$((component_count + 1))
            local available=$(oc get deployment "${deploy}" -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
            if [ "${available}" = "True" ]; then
                print_info "✓ ${deploy} is ready"
                ready_count=$((ready_count + 1))
            else
                print_warn "${deploy} is not fully available yet"
            fi
        fi
    done
    
    # If no standard deployments found, list what's actually there
    if [ ${component_count} -eq 0 ]; then
        print_info "Checking for cert-manager pods in namespace..."
        local pod_count=$(oc get pods -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "${pod_count}" -gt 0 ]; then
            print_info "✓ Found ${pod_count} pod(s) in cert-manager-operator namespace"
            oc get pods -n "${CERT_MANAGER_OPERATOR_NAMESPACE}" --no-headers 2>/dev/null | while read line; do
                print_info "  - $(echo $line | awk '{print $1}')"
            done
        else
            print_error "No cert-manager pods found"
            exit 1
        fi
    elif [ ${ready_count} -lt ${component_count} ]; then
        print_warn "Some cert-manager components (${ready_count}/${component_count}) are not fully ready"
        print_info "Current pods in ${CERT_MANAGER_OPERATOR_NAMESPACE}:"
        oc get pods -n "${CERT_MANAGER_OPERATOR_NAMESPACE}"
    else
        print_info "✓ All cert-manager components (${ready_count}/${component_count}) are ready"
    fi
    
    print_info "✓ Red Hat cert-manager Operator verification complete"
    echo ""
}

#================================================================
# Create Let's Encrypt ClusterIssuer
#================================================================

create_letsencrypt_issuer() {
    print_step "Creating Let's Encrypt ClusterIssuer"
    
    local issuer_name="letsencrypt-prod"
    local acme_server="https://acme-v02.api.letsencrypt.org/directory"
    
    if [ "${LETSENCRYPT_STAGING}" = true ]; then
        issuer_name="letsencrypt-staging"
        acme_server="https://acme-staging-v02.api.letsencrypt.org/directory"
        print_warn "Using Let's Encrypt STAGING environment (certificates will not be trusted)"
    fi
    
    print_info "Creating ClusterIssuer: ${issuer_name}"
    
    # Create ClusterIssuer
    cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${issuer_name}
spec:
  acme:
    # ACME server URL
    server: ${acme_server}
    # Email address for ACME registration
    email: ${LETSENCRYPT_EMAIL}
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: ${issuer_name}-account-key
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: openshift-default
EOF
    
    if [ $? -eq 0 ]; then
        print_info "✓ ClusterIssuer '${issuer_name}' created"
    else
        print_error "Failed to create ClusterIssuer"
        return 1
    fi
    
    # Store issuer name for later use
    ISSUER_NAME="${issuer_name}"
    echo ""
}

#================================================================
# Get Route Hostname
#================================================================

get_route_hostname() {
    local hostname=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
    
    if [ -z "${hostname}" ]; then
        print_error "Failed to get route hostname"
        return 1
    fi
    
    echo "${hostname}"
}

#================================================================
# Create Certificate Request
#================================================================

create_certificate() {
    print_step "Creating Certificate for Central"
    
    local hostname=$(get_route_hostname)
    if [ -z "${hostname}" ]; then
        print_error "Failed to get route hostname"
        return 1
    fi
    
    print_info "Creating certificate for hostname: ${hostname}"
    
    local cert_name="central-tls-cert"
    local secret_name="central-tls"
    
    # Create Certificate resource
    cat <<EOF | oc apply -n "${RHACS_NAMESPACE}" -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${cert_name}
  namespace: ${RHACS_NAMESPACE}
spec:
  # Secret where the certificate will be stored
  secretName: ${secret_name}
  
  # Duration and renewal
  duration: 2160h  # 90 days
  renewBefore: 360h  # 15 days before expiry
  
  # Subject
  subject:
    organizations:
      - "RHACS"
  
  # Common name and SANs
  commonName: ${hostname}
  dnsNames:
    - ${hostname}
  
  # Issuer reference
  issuerRef:
    name: ${ISSUER_NAME}
    kind: ClusterIssuer
    group: cert-manager.io
  
  # Private key
  privateKey:
    algorithm: RSA
    size: 2048
  
  # Usages
  usages:
    - server auth
    - client auth
EOF
    
    if [ $? -ne 0 ]; then
        print_error "Failed to create Certificate"
        return 1
    fi
    
    print_info "✓ Certificate '${cert_name}' created"
    
    # Wait for certificate to be ready
    print_info "Waiting for certificate to be issued (this may take a few minutes)..."
    
    local max_wait=600  # 10 minutes
    local elapsed=0
    local interval=10
    
    while [ ${elapsed} -lt ${max_wait} ]; do
        local ready=$(oc get certificate "${cert_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [ "${ready}" = "True" ]; then
            print_info "✓ Certificate issued successfully"
            
            # Verify secret was created
            if check_resource_exists "secret" "${secret_name}" "${RHACS_NAMESPACE}"; then
                print_info "✓ TLS secret '${secret_name}' created"
                return 0
            else
                print_error "Certificate ready but secret not found"
                return 1
            fi
        fi
        
        # Show certificate status
        local reason=$(oc get certificate "${cert_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || echo "Unknown")
        local message=$(oc get certificate "${cert_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
        
        print_info "Certificate status: ${reason} - ${message}"
        
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done
    
    print_error "Certificate issuance timed out after ${max_wait} seconds"
    print_info "Check certificate status with: oc describe certificate ${cert_name} -n ${RHACS_NAMESPACE}"
    return 1
}

#================================================================
# Configure Central to Use Custom Certificate
#================================================================

configure_central_tls() {
    print_step "Configuring Central to use custom certificate"
    
    local secret_name="central-tls"
    
    # Check if Central CR exists (Operator-based installation)
    if check_resource_exists "central" "stackrox-central-services" "${RHACS_NAMESPACE}" 2>/dev/null; then
        print_info "Found Central CR, configuring via Operator..."
        
        # Patch Central CR to use custom TLS
        oc patch central stackrox-central-services -n "${RHACS_NAMESPACE}" --type=merge -p '{
            "spec": {
                "central": {
                    "exposure": {
                        "route": {
                            "enabled": true
                        }
                    },
                    "defaultTLSSecret": {
                        "name": "'"${secret_name}"'"
                    }
                }
            }
        }'
        
        if [ $? -eq 0 ]; then
            print_info "✓ Central CR updated with custom TLS configuration"
        else
            print_error "Failed to update Central CR"
            return 1
        fi
    else
        print_info "Central CR not found, assuming Helm installation..."
        print_warn "For Helm installations, you need to manually update values.yaml:"
        cat <<EOF

Add the following to your Helm values.yaml:

central:
  defaultTLS:
    cert: # Leave empty to reference secret
    key:  # Leave empty to reference secret
  # Or reference the secret directly:
  defaultTLSSecret:
    name: ${secret_name}

Then upgrade the Helm release:
  helm upgrade -n ${RHACS_NAMESPACE} stackrox-central-services rhacs/central-services -f values.yaml

EOF
    fi
    
    echo ""
}

#================================================================
# Update Route to Passthrough
#================================================================

update_route_to_passthrough() {
    print_step "Updating route to passthrough termination"
    
    # Get current route configuration
    local current_termination=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    print_info "Current route termination: ${current_termination:-None}"
    
    if [ "${current_termination}" = "passthrough" ]; then
        print_info "✓ Route already configured with passthrough termination"
        return 0
    fi
    
    print_info "Updating route to passthrough termination..."
    
    # Patch route to use passthrough
    oc patch route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" --type=json -p='[
        {
            "op": "replace",
            "path": "/spec/tls",
            "value": {
                "termination": "passthrough",
                "insecureEdgeTerminationPolicy": "Redirect"
            }
        },
        {
            "op": "replace",
            "path": "/spec/port",
            "value": {
                "targetPort": "https"
            }
        }
    ]'
    
    if [ $? -eq 0 ]; then
        print_info "✓ Route updated to passthrough termination"
        
        # Verify route configuration
        local new_termination=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.tls.termination}')
        print_info "New route termination: ${new_termination}"
        
        # Display route details
        local route_host=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.host}')
        print_info "Route URL: https://${route_host}"
    else
        print_error "Failed to update route"
        return 1
    fi
    
    echo ""
}

#================================================================
# Restart Central
#================================================================

restart_central() {
    print_step "Restarting Central to apply TLS changes"
    
    print_info "Rolling out Central deployment..."
    
    oc rollout restart deployment/central -n "${RHACS_NAMESPACE}"
    
    if [ $? -eq 0 ]; then
        print_info "✓ Central restart initiated"
        
        # Wait for rollout to complete
        print_info "Waiting for Central to be ready..."
        if oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=300s; then
            print_info "✓ Central is ready"
        else
            print_warn "Central restart timed out, but may still be in progress"
        fi
    else
        print_error "Failed to restart Central"
        return 1
    fi
    
    echo ""
}

#================================================================
# Verify TLS Configuration
#================================================================

verify_tls_configuration() {
    print_step "Verifying TLS configuration"
    
    local route_host=$(get_route_hostname)
    local route_url="https://${route_host}"
    
    print_info "Testing TLS connection to: ${route_url}"
    
    # Wait a bit for the service to stabilize
    sleep 10
    
    # Test TLS connection
    if curl -v -k --max-time 10 "${route_url}" 2>&1 | grep -q "SSL connection using"; then
        print_info "✓ TLS connection successful"
        
        # Show certificate details
        print_info "Certificate details:"
        echo | openssl s_client -connect "${route_host}:443" -servername "${route_host}" 2>/dev/null | \
            openssl x509 -noout -subject -issuer -dates 2>/dev/null || print_warn "Could not retrieve certificate details"
    else
        print_warn "TLS connection test failed (service may still be initializing)"
        print_info "You can manually verify with: curl -v ${route_url}"
    fi
    
    echo ""
}

#================================================================
# Display Summary
#================================================================

display_summary() {
    print_step "Configuration Summary"
    
    local route_host=$(get_route_hostname)
    local route_url="https://${route_host}"
    
    cat <<EOF
${GREEN}✓ Custom TLS configuration complete!${NC}

Route Configuration:
  - Name: ${RHACS_ROUTE_NAME}
  - Namespace: ${RHACS_NAMESPACE}
  - Hostname: ${route_host}
  - URL: ${route_url}
  - Termination: passthrough
  - TLS Secret: central-tls

cert-manager Configuration:
  - Operator: Red Hat cert-manager Operator for OpenShift
  - Namespace: ${CERT_MANAGER_OPERATOR_NAMESPACE}
  - ClusterIssuer: ${ISSUER_NAME}
  - Email: ${LETSENCRYPT_EMAIL}
  - Certificate: central-tls-cert

Next Steps:
  1. Verify Central is accessible: ${route_url}
  2. Check certificate in browser (should show valid certificate)
  3. Monitor certificate renewal: oc get certificate -n ${RHACS_NAMESPACE}
  
Troubleshooting Commands:
  # Check cert-manager operator status
  oc get csv -n ${CERT_MANAGER_OPERATOR_NAMESPACE}
  oc get pods -n ${CERT_MANAGER_OPERATOR_NAMESPACE}
  
  # Check certificate status
  oc describe certificate central-tls-cert -n ${RHACS_NAMESPACE}
  oc get certificaterequest -n ${RHACS_NAMESPACE}
  oc get order -n ${RHACS_NAMESPACE}
  oc get challenge -n ${RHACS_NAMESPACE}
  
  # Check certificate secret
  oc get secret central-tls -n ${RHACS_NAMESPACE}
  
  # Check Central logs
  oc logs deployment/central -n ${RHACS_NAMESPACE}
  
  # Check route
  oc get route ${RHACS_ROUTE_NAME} -n ${RHACS_NAMESPACE} -o yaml
  
  # Test TLS connection
  curl -v ${route_url}
  openssl s_client -connect ${route_host}:443 -servername ${route_host}

Certificate Renewal:
  - Certificates are automatically renewed by cert-manager
  - Renewal occurs 15 days before expiry
  - Check renewal status: oc get certificate -n ${RHACS_NAMESPACE} -w

EOF
}

#================================================================
# Main Execution
#================================================================

main() {
    echo ""
    echo "================================================================"
    echo "RHACS Central Custom TLS Configuration"
    echo "================================================================"
    echo ""
    
    # Parse command line arguments
    parse_arguments "$@"
    
    # Run pre-flight checks
    preflight_checks
    
    # Verify cert-manager is installed (prerequisite)
    install_cert_manager || exit 1
    
    # Create Let's Encrypt ClusterIssuer
    create_letsencrypt_issuer || exit 1
    
    # Create Certificate for Central
    create_certificate || exit 1
    
    # Configure Central to use custom certificate
    configure_central_tls
    
    # Update route to passthrough
    update_route_to_passthrough || exit 1
    
    # Restart Central to apply changes
    restart_central
    
    # Verify TLS configuration
    verify_tls_configuration
    
    # Display summary
    display_summary
    
    echo ""
    print_info "Configuration complete!"
    echo ""
}

# Execute main function
main "$@"
