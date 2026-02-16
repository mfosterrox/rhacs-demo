#!/bin/bash
#
# RHACS Monitoring Setup Script
# This script configures monitoring for Red Hat Advanced Cluster Security
#

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-stackrox}"
MONITORING_EXAMPLES_DIR="$(dirname "$0")/monitoring-examples"
TLS_SECRET_NAME="sample-stackrox-prometheus-tls"
API_TOKEN_SECRET_NAME="stackrox-prometheus-api-token"

# Functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if kubectl is installed
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed. Please install kubectl."
        exit 1
    fi
    
    # Check if openssl is installed
    if ! command -v openssl &> /dev/null; then
        log_error "openssl is not installed. Please install openssl."
        exit 1
    fi
    
    # Check if namespace exists
    if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
        log_error "Namespace '$NAMESPACE' does not exist. Please install RHACS first."
        exit 1
    fi
    
    log_info "Prerequisites check passed."
}

get_rox_central_url() {
    log_info "Getting ROX Central URL..."
    
    # Try to get the route (OpenShift)
    if kubectl get route central -n "$NAMESPACE" &> /dev/null; then
        ROX_CENTRAL_URL="https://$(kubectl get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
    # Try to get the ingress
    elif kubectl get ingress central -n "$NAMESPACE" &> /dev/null; then
        ROX_CENTRAL_URL="https://$(kubectl get ingress central -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')"
    # Fallback to service
    else
        ROX_CENTRAL_URL="https://central.$NAMESPACE.svc.cluster.local:443"
    fi
    
    log_info "ROX Central URL: $ROX_CENTRAL_URL"
    export ROX_CENTRAL_URL
}

create_api_token_secret() {
    log_info "Creating API token secret for Prometheus..."
    
    # Check if ROX_API_TOKEN is set
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        log_warn "ROX_API_TOKEN is not set."
        log_warn "Please create an API token in RHACS with the 'Prometheus Server' role."
        log_warn "Then run: export ROX_API_TOKEN='your-token-here'"
        log_warn "Skipping API token secret creation."
        return 0
    fi
    
    # Check if secret already exists
    if kubectl get secret "$API_TOKEN_SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret '$API_TOKEN_SECRET_NAME' already exists. Deleting..."
        kubectl delete secret "$API_TOKEN_SECRET_NAME" -n "$NAMESPACE"
    fi
    
    # Create the secret
    kubectl create secret generic "$API_TOKEN_SECRET_NAME" \
        -n "$NAMESPACE" \
        --from-literal=token="$ROX_API_TOKEN"
    
    log_info "API token secret created successfully."
}

generate_tls_certificates() {
    log_info "Generating TLS certificates for testing..."
    
    # Create temporary directory for certificates
    CERT_DIR=$(mktemp -d)
    cd "$CERT_DIR"
    
    # Generate a private key and certificate
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=sample-stackrox-monitoring-stack-prometheus.stackrox.svc" \
        -keyout tls.key -out tls.crt
    
    log_info "TLS certificates generated in: $CERT_DIR"
    
    # Check if TLS secret already exists
    if kubectl get secret "$TLS_SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret '$TLS_SECRET_NAME' already exists. Deleting..."
        kubectl delete secret "$TLS_SECRET_NAME" -n "$NAMESPACE"
    fi
    
    # Create TLS secret in the namespace
    kubectl create secret tls "$TLS_SECRET_NAME" \
        -n "$NAMESPACE" \
        --cert=tls.crt \
        --key=tls.key
    
    log_info "TLS secret created successfully."
    
    # Save certificates to monitoring-examples directory for testing
    cp tls.crt tls.key "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/"
    log_info "Certificates copied to: $MONITORING_EXAMPLES_DIR/cluster-observability-operator/"
    
    # Return to original directory
    cd - > /dev/null
    
    # Export paths for diagnostics
    export TLS_CERT="$MONITORING_EXAMPLES_DIR/cluster-observability-operator/tls.crt"
    export TLS_KEY="$MONITORING_EXAMPLES_DIR/cluster-observability-operator/tls.key"
}

apply_rhacs_configuration() {
    log_info "Applying RHACS declarative configuration..."
    
    if [ ! -f "$MONITORING_EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml" ]; then
        log_error "Declarative configuration file not found."
        exit 1
    fi
    
    kubectl apply -f "$MONITORING_EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml"
    
    log_info "RHACS configuration applied successfully."
    log_warn "Note: You need to configure the role and user in RHACS UI or via API."
    log_warn "See: $MONITORING_EXAMPLES_DIR/rhacs/README.md"
}

apply_monitoring_stack() {
    log_info "Applying Cluster Observability Operator monitoring stack..."
    
    # Check if Cluster Observability Operator is installed
    if ! kubectl get crd monitoringstacks.monitoring.rhobs &> /dev/null; then
        log_warn "Cluster Observability Operator is not installed."
        log_warn "Please install the operator first."
        log_warn "Skipping monitoring stack creation."
        return 0
    fi
    
    if [ ! -f "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml" ]; then
        log_error "Monitoring stack configuration file not found."
        exit 1
    fi
    
    kubectl apply -f "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml"
    
    log_info "Monitoring stack applied successfully."
}

apply_scrape_config() {
    log_info "Applying scrape configuration..."
    
    if [ ! -f "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml" ]; then
        log_error "Scrape configuration file not found."
        exit 1
    fi
    
    kubectl apply -f "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml"
    
    log_info "Scrape configuration applied successfully."
}

run_diagnostics() {
    log_info "Running diagnostics..."
    
    echo ""
    log_info "=== Namespace Resources ==="
    kubectl get all -n "$NAMESPACE" | grep -E "(prometheus|monitoring|alertmanager)" || log_warn "No monitoring resources found"
    
    echo ""
    log_info "=== Secrets ==="
    kubectl get secrets -n "$NAMESPACE" | grep -E "(prometheus|tls|token)" || log_warn "No monitoring secrets found"
    
    echo ""
    log_info "=== MonitoringStack Status ==="
    kubectl get monitoringstack -n "$NAMESPACE" 2>/dev/null || log_warn "No MonitoringStack found"
    
    echo ""
    log_info "=== ScrapeConfig Status ==="
    kubectl get scrapeconfig -n "$NAMESPACE" 2>/dev/null || log_warn "No ScrapeConfig found"
    
    echo ""
    log_info "=== Testing TLS Certificate Access ==="
    
    if [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
        log_info "Testing access with: curl --cert $TLS_CERT --key $TLS_KEY $ROX_CENTRAL_URL/v1/auth/status"
        
        # Test the access
        if curl --cert "$TLS_CERT" --key "$TLS_KEY" -k -s "$ROX_CENTRAL_URL/v1/auth/status" > /dev/null 2>&1; then
            log_info "✓ TLS certificate authentication successful!"
            curl --cert "$TLS_CERT" --key "$TLS_KEY" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>/dev/null | head -20
        else
            log_error "✗ TLS certificate authentication failed."
            log_warn "Make sure to configure User Certificates auth provider in RHACS."
            log_warn "Add the certificate in RHACS: Platform Configuration -> Access Control -> Auth Providers"
        fi
    else
        log_warn "TLS certificates not found. Skipping access test."
    fi
    
    echo ""
    if [ -n "${ROX_API_TOKEN:-}" ]; then
        log_info "=== Testing API Token Access ==="
        log_info "Testing access with: curl -H 'Authorization: Bearer \$ROX_API_TOKEN' $ROX_CENTRAL_URL/v1/auth/status"
        
        if curl -H "Authorization: Bearer $ROX_API_TOKEN" -k -s "$ROX_CENTRAL_URL/v1/auth/status" > /dev/null 2>&1; then
            log_info "✓ API token authentication successful!"
            curl -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>/dev/null | head -20
        else
            log_error "✗ API token authentication failed."
            log_warn "Make sure the API token has the 'Prometheus Server' role."
        fi
    else
        log_warn "ROX_API_TOKEN not set. Skipping API token test."
    fi
}

print_next_steps() {
    echo ""
    log_info "=== Setup Complete ==="
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Configure User Certificates auth provider in RHACS:"
    echo "   - Go to Platform Configuration -> Access Control -> Auth Providers"
    echo "   - Add a new User Certificates provider"
    echo "   - Upload the certificate: $TLS_CERT"
    echo "   - Assign the 'Prometheus Server' role"
    echo ""
    echo "2. Test the access manually:"
    echo "   export ROX_CENTRAL_URL='$ROX_CENTRAL_URL'"
    echo "   curl --cert $TLS_CERT --key $TLS_KEY -k \$ROX_CENTRAL_URL/v1/auth/status"
    echo ""
    echo "3. If using API token, create one in RHACS:"
    echo "   - Go to Platform Configuration -> Integrations -> API Token"
    echo "   - Create a new token with 'Prometheus Server' role"
    echo "   - Set the token: export ROX_API_TOKEN='your-token-here'"
    echo "   - Re-run this script to create the secret"
    echo ""
    echo "4. Configure custom metrics (optional):"
    echo "   curl -H \"Authorization: Bearer \$ROX_API_TOKEN\" -k \$ROX_CENTRAL_URL/v1/config | jq '.privateConfig.metrics'"
    echo ""
    echo "5. Access Prometheus UI:"
    echo "   kubectl port-forward -n $NAMESPACE svc/sample-stackrox-monitoring-stack-prometheus 9090:9090"
    echo "   Open: http://localhost:9090"
    echo ""
}

# Main execution
main() {
    log_info "Starting RHACS Monitoring Setup..."
    echo ""
    
    check_prerequisites
    get_rox_central_url
    create_api_token_secret
    generate_tls_certificates
    apply_rhacs_configuration
    apply_monitoring_stack
    apply_scrape_config
    run_diagnostics
    print_next_steps
    
    log_info "Setup completed successfully!"
}

# Run main function
main "$@"
