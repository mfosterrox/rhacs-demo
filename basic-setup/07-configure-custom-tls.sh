#!/bin/bash
#
# Configure RHACS Central with Passthrough Route and Custom TLS Certificate
#
# This script:
# 1. Changes the Central route from reencrypt/edge to passthrough
# 2. Installs and configures cert-manager (if not present)
# 3. Creates a Let's Encrypt ClusterIssuer
# 4. Generates a custom TLS certificate for Central
# 5. Configures Central to use the custom certificate
#
# Prerequisites:
# - OpenShift cluster with cluster-admin access
# - RHACS Central already installed
# - Environment variables: RHACS_NAMESPACE, RHACS_ROUTE_NAME (optional)
#
# Usage:
#   ./07-configure-custom-tls.sh [--staging] [--email your@email.com]
#
# Options:
#   --staging    Use Let's Encrypt staging environment (for testing)
#   --email      Email address for Let's Encrypt registration (required)
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
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.14.4}"
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
# Install cert-manager
#================================================================

install_cert_manager() {
    print_step "Installing cert-manager"
    
    # Check if cert-manager is already installed
    if check_resource_exists "namespace" "cert-manager" && \
       check_resource_exists "deployment" "cert-manager" "cert-manager"; then
        print_info "✓ cert-manager is already installed"
        
        # Verify cert-manager is ready
        if oc get deployment cert-manager -n cert-manager -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' | grep -q "True"; then
            print_info "✓ cert-manager is ready"
            return 0
        fi
    fi
    
    print_info "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    
    # Install cert-manager using kubectl
    kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
    
    print_info "Waiting for cert-manager to be ready..."
    sleep 10
    
    # Wait for cert-manager deployments
    local deployments=("cert-manager" "cert-manager-cainjector" "cert-manager-webhook")
    for deploy in "${deployments[@]}"; do
        if ! oc wait deployment/"${deploy}" \
            -n cert-manager \
            --for=condition=Available \
            --timeout=300s; then
            print_error "Failed to wait for ${deploy} to be ready"
            return 1
        fi
        print_info "✓ ${deploy} is ready"
    done
    
    print_info "✓ cert-manager installation complete"
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
  - ClusterIssuer: ${ISSUER_NAME}
  - Email: ${LETSENCRYPT_EMAIL}
  - Certificate: central-tls-cert

Next Steps:
  1. Verify Central is accessible: ${route_url}
  2. Check certificate in browser (should show valid certificate)
  3. Monitor certificate renewal: oc get certificate -n ${RHACS_NAMESPACE}
  
Troubleshooting Commands:
  # Check certificate status
  oc describe certificate central-tls-cert -n ${RHACS_NAMESPACE}
  
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
    
    # Install cert-manager
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
