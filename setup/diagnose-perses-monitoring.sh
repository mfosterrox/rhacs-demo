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
    AUTH_SUCCESS=true
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    warning "Authentication failed (HTTP $HTTP_CODE). The certificate may not be registered as a UserPKI auth provider in RHACS."
    log ""
    log "Response body:"
    echo "$RESPONSE_BODY"
    log ""
    AUTH_SUCCESS=false
elif [ "$HTTP_CODE" = "404" ]; then
    warning "Endpoint not found (HTTP 404). Check if the API path is correct."
    info "Response: $RESPONSE_BODY"
    AUTH_SUCCESS=false
else
    warning "Unexpected HTTP status code: $HTTP_CODE"
    info "Response: $RESPONSE_BODY"
    AUTH_SUCCESS=false
fi

log ""
log "========================================================="
if [ "${AUTH_SUCCESS:-false}" = "true" ]; then
    log "Diagnostic complete - Authentication successful!"
else
    log "Diagnostic complete - Issues found"
fi
log "========================================================="

# Additional diagnostics
log ""
log "========================================================="
log "Additional diagnostic information:"
log "========================================================="
log ""

# Check if UserPKI auth provider exists
log "Step 5: Checking for UserPKI auth provider 'Prometheus'..."

# Try to get ROX_API_TOKEN from environment or ~/.bashrc
ROX_API_TOKEN=""
if [ -f ~/.bashrc ] && grep -q "^export ROX_API_TOKEN=" ~/.bashrc; then
    ROX_API_TOKEN=$(grep "^export ROX_API_TOKEN=" ~/.bashrc | head -1 | sed -E 's/^export ROX_API_TOKEN=["'\'']?//; s/["'\'']?$//')
fi

# Also check environment
if [ -z "$ROX_API_TOKEN" ] && [ -n "${ROX_API_TOKEN:-}" ]; then
    ROX_API_TOKEN="$ROX_API_TOKEN"
fi

if [ -z "$ROX_API_TOKEN" ]; then
    warning "ROX_API_TOKEN not found in ~/.bashrc or environment."
    log "Attempting to generate API token..."
    
    # Get ADMIN_PASSWORD
    ADMIN_PASSWORD=""
    if [ -f ~/.bashrc ] && grep -q "^export ACS_PASSWORD=" ~/.bashrc; then
        ADMIN_PASSWORD=$(grep "^export ACS_PASSWORD=" ~/.bashrc | head -1 | sed -E 's/^export ACS_PASSWORD=["'\'']?//; s/["'\'']?$//')
    fi
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
        if [ -z "$ADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.htpasswd}' 2>/dev/null || echo "")
        fi
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
        fi
    fi
    
    if [ -n "$ADMIN_PASSWORD" ]; then
        ROX_ENDPOINT_FOR_API="${CENTRAL_ROUTE}"
        set +e
        TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
            -u "admin:${ADMIN_PASSWORD}" \
            -H "Content-Type: application/json" \
            "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
            -d '{"name":"diagnose-script-token","roles":["Admin"]}' 2>&1)
        set -e
        
        if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
            ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
        fi
        
        if [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ]; then
            log "✓ API token generated successfully"
        fi
    fi
fi

if [ -n "$ROX_API_TOKEN" ] && command -v roxctl &>/dev/null; then
    export ROX_API_TOKEN
    export GRPC_ENFORCE_ALPN_ENABLED=false
    set +e
    AUTH_PROVIDERS=$(roxctl -e "$API_ENDPOINT" central userpki list --insecure-skip-tls-verify 2>&1)
    ROXCTL_EXIT=$?
    set -e
    
    if [ $ROXCTL_EXIT -eq 0 ]; then
        if echo "$AUTH_PROVIDERS" | grep -qi "Prometheus"; then
            log "✓ UserPKI auth provider 'Prometheus' found"
            log ""
            log "List of UserPKI auth providers:"
            echo "$AUTH_PROVIDERS"
        else
            warning "UserPKI auth provider 'Prometheus' NOT found"
            log ""
            log "Current UserPKI auth providers:"
            echo "$AUTH_PROVIDERS"
            log ""
            warning "You need to create the UserPKI auth provider."
            log ""
            log "To create it, run:"
            log "  export ROX_API_TOKEN=\"\$ROX_API_TOKEN\""
            log "  export GRPC_ENFORCE_ALPN_ENABLED=false"
            log "  roxctl -e $API_ENDPOINT central userpki create Prometheus \\"
            log "    -c $TEMP_DIR/tls.crt \\"
            log "    -r Admin \\"
            log "    --insecure-skip-tls-verify"
            log ""
            log "Or run the setup script:"
            log "  ./setup/setup-perses-monitoring.sh"
        fi
    else
        warning "Failed to list UserPKI auth providers (roxctl exit code: $ROXCTL_EXIT)"
        info "roxctl output: $AUTH_PROVIDERS"
    fi
elif [ -z "$ROX_API_TOKEN" ]; then
    warning "ROX_API_TOKEN not available. Cannot check UserPKI auth providers."
    log ""
    log "To get an API token, run:"
    log "  ./setup/install.sh -p YOUR_PASSWORD"
    log ""
    log "Or manually create the UserPKI auth provider using:"
    log "  roxctl -e $API_ENDPOINT central userpki create Prometheus \\"
    log "    -c $TEMP_DIR/tls.crt \\"
    log "    -r Admin \\"
    log "    --insecure-skip-tls-verify"
elif ! command -v roxctl &>/dev/null; then
    warning "roxctl not found. Cannot check UserPKI auth providers."
    log ""
    log "Install roxctl or run the setup script:"
    log "  ./setup/setup-perses-monitoring.sh"
fi

log ""
log "Certificate and key files are available at:"
log "  Certificate: $TEMP_DIR/tls.crt"
log "  Private key: $TEMP_DIR/tls.key"
log ""
log "To test manually, run:"
log "  curl https://$CENTRAL_ROUTE/v1/auth/status --cert $TEMP_DIR/tls.crt --key $TEMP_DIR/tls.key -k"
log ""
