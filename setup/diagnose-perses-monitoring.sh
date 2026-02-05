#!/bin/bash
# Perses Monitoring Diagnostic Script
# Tests RHACS Central API authentication using TLS certificates from Kubernetes secret

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[DIAGNOSE]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[DIAGNOSE]${NC} $1"
}

error() {
    echo -e "${RED}[DIAGNOSE] ERROR:${NC} $1" >&2
    exit 1
}

info() {
    echo -e "${BLUE}[DIAGNOSE]${NC} $1"
}

# Set namespace (default to stackrox)
NAMESPACE="${NAMESPACE:-stackrox}"
SECRET_NAME="sample-rhacs-operator-prometheus-tls"
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log "========================================================="
log "Perses Monitoring Diagnostic Script"
log "========================================================="
log ""

# Check prerequisites
log "Checking prerequisites..."

if ! command -v oc &>/dev/null; then
    error "oc command not found. Please install OpenShift CLI."
fi
log "✓ oc CLI found"

if ! command -v curl &>/dev/null; then
    error "curl command not found. Please install curl."
fi
log "✓ curl found"

if ! oc whoami &>/dev/null; then
    error "Not logged into OpenShift. Please run: oc login"
fi
log "✓ OpenShift CLI connected as: $(oc whoami)"

log ""

# Step 1: Check if namespace exists
log "Step 1: Checking namespace..."
if ! oc get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found."
fi
log "✓ Namespace '$NAMESPACE' exists"
log ""

# Step 2: Extract TLS certificate and key from secret
log "Step 2: Extracting TLS certificate and key from secret..."
if ! oc get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    error "Secret '$SECRET_NAME' not found in namespace '$NAMESPACE'."
fi
log "✓ Secret '$SECRET_NAME' found"

# Extract certificate
CERT_B64=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.crt}' 2>/dev/null || echo "")
if [ -z "$CERT_B64" ]; then
    error "Failed to extract tls.crt from secret '$SECRET_NAME'"
fi
echo "$CERT_B64" | base64 -d > "$TEMP_DIR/tls.crt"
log "✓ Certificate extracted to temporary file"

# Extract private key
KEY_B64=$(oc get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.tls\.key}' 2>/dev/null || echo "")
if [ -z "$KEY_B64" ]; then
    error "Failed to extract tls.key from secret '$SECRET_NAME'"
fi
echo "$KEY_B64" | base64 -d > "$TEMP_DIR/tls.key"
log "✓ Private key extracted to temporary file"

# Verify certificate details
CERT_CN=$(openssl x509 -in "$TEMP_DIR/tls.crt" -noout -subject 2>/dev/null | sed -n 's/.*CN=\([^,]*\).*/\1/p' || echo "")
CERT_EXPIRY=$(openssl x509 -in "$TEMP_DIR/tls.crt" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
log "  Certificate CN: $CERT_CN"
log "  Certificate expires: $CERT_EXPIRY"
log ""

# Step 3: Get Central API endpoint
log "Step 3: Getting Central API endpoint..."
CENTRAL_ROUTE=$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found in namespace '$NAMESPACE'"
fi

# Determine if route uses TLS
CENTRAL_SCHEME="https"
API_ENDPOINT="${CENTRAL_SCHEME}://${CENTRAL_ROUTE}"
log "✓ Central route found: $CENTRAL_ROUTE"
log "  API endpoint: $API_ENDPOINT"
log ""

# Step 4: Test API authentication
log "Step 4: Testing API authentication..."
log "  Testing endpoint: ${API_ENDPOINT}/v1/auth/status"
log ""

set +e
AUTH_RESPONSE=$(curl -s -w "\n%{http_code}" \
    --cert "$TEMP_DIR/tls.crt" \
    --key "$TEMP_DIR/tls.key" \
    -k \
    --connect-timeout 10 \
    --max-time 30 \
    "${API_ENDPOINT}/v1/auth/status" 2>&1)
CURL_EXIT_CODE=$?
set -e

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$AUTH_RESPONSE" | tail -n1)
# Extract response body (all but last line)
RESPONSE_BODY=$(echo "$AUTH_RESPONSE" | sed '$d')

log "  curl exit code: $CURL_EXIT_CODE"
log "  HTTP status code: $HTTP_CODE"
log ""

if [ $CURL_EXIT_CODE -ne 0 ]; then
    error "curl failed with exit code $CURL_EXIT_CODE. Check network connectivity and certificate validity."
fi

# Check HTTP status code
if [ "$HTTP_CODE" = "200" ]; then
    log "✓ Authentication successful!"
    log ""
    log "Response body:"
    if command -v jq &>/dev/null && echo "$RESPONSE_BODY" | jq . &>/dev/null; then
        echo "$RESPONSE_BODY" | jq .
    else
        echo "$RESPONSE_BODY"
    fi
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    error "Authentication failed (HTTP $HTTP_CODE). The certificate may not be registered as a UserPKI auth provider in RHACS."
elif [ "$HTTP_CODE" = "404" ]; then
    warning "Endpoint not found (HTTP 404). Check if the API path is correct."
    info "Response: $RESPONSE_BODY"
else
    warning "Unexpected HTTP status code: $HTTP_CODE"
    info "Response: $RESPONSE_BODY"
fi

log ""
log "========================================================="
log "Diagnostic complete"
log "========================================================="

# Additional diagnostics
log ""
log "Additional diagnostic information:"
log ""

# Check if UserPKI auth provider exists
log "Checking for UserPKI auth provider 'Prometheus'..."
if command -v roxctl &>/dev/null; then
    # Try to get ROX_API_TOKEN from environment or ~/.bashrc
    ROX_API_TOKEN=""
    if [ -f ~/.bashrc ] && grep -q "^export ROX_API_TOKEN=" ~/.bashrc; then
        ROX_API_TOKEN=$(grep "^export ROX_API_TOKEN=" ~/.bashrc | head -1 | sed -E 's/^export ROX_API_TOKEN=["'\'']?//; s/["'\'']?$//')
    fi
    
    if [ -n "$ROX_API_TOKEN" ]; then
        export ROX_API_TOKEN
        export GRPC_ENFORCE_ALPN_ENABLED=false
        set +e
        AUTH_PROVIDERS=$(roxctl -e "$API_ENDPOINT" central userpki list --insecure-skip-tls-verify 2>&1)
        set -e
        if echo "$AUTH_PROVIDERS" | grep -q "Prometheus"; then
            log "✓ UserPKI auth provider 'Prometheus' found"
        else
            warning "UserPKI auth provider 'Prometheus' not found"
            info "You may need to create it using:"
            info "  roxctl -e $API_ENDPOINT central userpki create Prometheus -c $TEMP_DIR/tls.crt -r Admin --insecure-skip-tls-verify"
        fi
    else
        warning "ROX_API_TOKEN not found. Cannot check UserPKI auth providers."
        info "Set ROX_API_TOKEN or run: ./install.sh -p YOUR_PASSWORD"
    fi
else
    warning "roxctl not found. Cannot check UserPKI auth providers."
fi

log ""
log "Certificate and key files are available at:"
log "  Certificate: $TEMP_DIR/tls.crt"
log "  Private key: $TEMP_DIR/tls.key"
log ""
log "To test manually, run:"
log "  curl https://$CENTRAL_ROUTE/v1/auth/status --cert $TEMP_DIR/tls.crt --key $TEMP_DIR/tls.key -k"
log ""
