#!/bin/bash
#
# Manual UserPKI Auth Provider Creation for RHACS Monitoring
#
# This script helps create a User Certificate auth provider in RHACS
# for Prometheus to authenticate and scrape metrics.
#

set -euo pipefail

# Fix for gRPC ALPN enforcement issues (https://github.com/grpc/grpc-go/issues/7769)
export GRPC_ENFORCE_ALPN_ENABLED=false

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
NAMESPACE="${NAMESPACE:-stackrox}"
CERT_FILE="${CERT_FILE:-tls.crt}"
KEY_FILE="${KEY_FILE:-tls.key}"
AUTH_PROVIDER_NAME="Prometheus"
ROLE="Admin"

echo ""
step "RHACS UserPKI Auth Provider Setup"
echo "=========================================="
echo ""

# Check prerequisites
log "Checking prerequisites..."

# Check if we're in the right directory or find the cert
if [ ! -f "$CERT_FILE" ]; then
    if [ -f "monitoring-setup/$CERT_FILE" ]; then
        cd monitoring-setup
    elif [ -f "../$CERT_FILE" ]; then
        cd ..
    else
        error "Certificate file '$CERT_FILE' not found"
        error "Please run this script from the monitoring-setup directory or ensure tls.crt exists"
        exit 1
    fi
fi

log "✓ Found certificate: $CERT_FILE"

# Get certificate CN
CERT_CN=$(openssl x509 -in "$CERT_FILE" -noout -subject | sed -n 's/.*CN=\([^,]*\).*/\1/p')
log "Certificate CN: $CERT_CN"

# Check roxctl
if ! command -v roxctl &>/dev/null; then
    error "roxctl not found in PATH"
    error "Install it with: curl -L -o ~/.local/bin/roxctl https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
    error "Then run: chmod +x ~/.local/bin/roxctl && export PATH=\"\$HOME/.local/bin:\$PATH\""
    exit 1
fi
log "✓ roxctl found: $(which roxctl)"

# Get environment variables
if [ -z "${ROX_API_TOKEN:-}" ]; then
    if [ -f ~/.bashrc ] && grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
        ROX_API_TOKEN=$(grep "export ROX_API_TOKEN=" ~/.bashrc | head -1 | sed "s/export ROX_API_TOKEN=//g" | tr -d "'" | tr -d '"')
        export ROX_API_TOKEN
        log "✓ Loaded ROX_API_TOKEN from ~/.bashrc"
    else
        error "ROX_API_TOKEN not set"
        error "Please set it: export ROX_API_TOKEN='your-token-here'"
        exit 1
    fi
fi

if [ -z "${ROX_CENTRAL_URL:-}" ]; then
    if command -v oc &>/dev/null && oc get route central -n "$NAMESPACE" &>/dev/null; then
        ROX_CENTRAL_URL="https://$(oc get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
        export ROX_CENTRAL_URL
        log "✓ Detected ROX_CENTRAL_URL: $ROX_CENTRAL_URL"
    else
        error "ROX_CENTRAL_URL not set and could not auto-detect"
        error "Please set it: export ROX_CENTRAL_URL='https://your-central-url'"
        exit 1
    fi
fi

# Normalize endpoint for roxctl
ROX_ENDPOINT="${ROX_CENTRAL_URL#https://}"
ROX_ENDPOINT="${ROX_ENDPOINT#http://}"
if [[ ! "$ROX_ENDPOINT" =~ :[0-9]+$ ]]; then
    ROX_ENDPOINT="${ROX_ENDPOINT}:443"
fi

log "✓ ROX_ENDPOINT: $ROX_ENDPOINT"

echo ""
step "Testing roxctl connectivity..."

# Verify GRPC fix is set
if [ "${GRPC_ENFORCE_ALPN_ENABLED:-}" != "false" ]; then
    warning "GRPC_ENFORCE_ALPN_ENABLED is not set to 'false'"
    log "Setting it now..."
    export GRPC_ENFORCE_ALPN_ENABLED=false
fi
log "GRPC_ENFORCE_ALPN_ENABLED = $GRPC_ENFORCE_ALPN_ENABLED"

# Test connection with detailed output
log "Testing: roxctl -e $ROX_ENDPOINT central whoami --insecure-skip-tls-verify"
log "This should complete in 1-2 seconds..."

WHOAMI_OUTPUT=$(roxctl -e "$ROX_ENDPOINT" central whoami --insecure-skip-tls-verify 2>&1)
WHOAMI_EXIT_CODE=$?

log "Exit code: $WHOAMI_EXIT_CODE"
log "Output preview: ${WHOAMI_OUTPUT:0:200}"

if [ $WHOAMI_EXIT_CODE -eq 0 ] && echo "$WHOAMI_OUTPUT" | grep -q "name"; then
    log "✓ Successfully connected to RHACS Central"
    echo "$WHOAMI_OUTPUT" | grep "name" | head -1
else
    error "Failed to connect to RHACS Central"
    error "Exit code: $WHOAMI_EXIT_CODE"
    error "Full output:"
    echo "$WHOAMI_OUTPUT"
    error ""
    error "Troubleshooting:"
    error "1. Verify ROX_API_TOKEN is set and valid:"
    error "   echo \"\${ROX_API_TOKEN:0:30}...\""
    error ""
    error "2. Test API token with curl:"
    error "   curl -H \"Authorization: Bearer \$ROX_API_TOKEN\" -k \$ROX_CENTRAL_URL/v1/auth/status"
    error ""
    error "3. Verify GRPC fix is applied:"
    error "   echo \$GRPC_GO_REQUIRE_HANDSHAKE_ON"
    error ""
    exit 1
fi

echo ""
step "Checking existing auth providers..."

# List existing auth providers
EXISTING_PROVIDERS=$(roxctl -e "$ROX_ENDPOINT" central userpki list --insecure-skip-tls-verify 2>&1 || echo "")
if echo "$EXISTING_PROVIDERS" | grep -q "$AUTH_PROVIDER_NAME"; then
    warning "Auth provider '$AUTH_PROVIDER_NAME' already exists"
    echo ""
    read -p "Delete and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Deleting existing auth provider..."
        printf 'y\n' | timeout 30 roxctl -e "$ROX_ENDPOINT" \
            central userpki delete "$AUTH_PROVIDER_NAME" \
            --insecure-skip-tls-verify 2>&1 || true
        sleep 2
        log "✓ Deleted"
    else
        log "Keeping existing auth provider"
        exit 0
    fi
fi

echo ""
step "Creating UserPKI auth provider '$AUTH_PROVIDER_NAME'..."

# Create the auth provider
OUTPUT=$(roxctl -e "$ROX_ENDPOINT" \
    central userpki create "$AUTH_PROVIDER_NAME" \
    -c "$CERT_FILE" \
    -r "$ROLE" \
    --insecure-skip-tls-verify 2>&1)

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    log "✓ UserPKI auth provider created successfully!"
    echo "$OUTPUT"
else
    error "Failed to create auth provider"
    echo "$OUTPUT"
    echo ""
    error "Try creating it manually via the RHACS UI:"
    error "1. Go to: $ROX_CENTRAL_URL"
    error "2. Navigate to: Platform Configuration → Access Control → Auth Providers"
    error "3. Click 'Create auth provider'"
    error "4. Select type: User Certificates"
    error "5. Name: $AUTH_PROVIDER_NAME"
    error "6. Upload certificate: $CERT_FILE"
    error "7. Click Save and Enable"
    exit 1
fi

echo ""
step "Testing certificate authentication..."

# Test the certificate
CERT_TEST=$(curl --cert "$CERT_FILE" --key "$KEY_FILE" -k -s "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)

if echo "$CERT_TEST" | grep -q '"userId"'; then
    log "✓ Certificate authentication SUCCESSFUL!"
    echo "$CERT_TEST" | head -5
else
    warning "Certificate authentication not yet working"
    echo "$CERT_TEST"
    echo ""
    warning "You may need to:"
    warning "1. Wait a few seconds for the auth provider to become active"
    warning "2. Create a user/service account in RHACS with:"
    warning "   - Auth Provider: $AUTH_PROVIDER_NAME"
    warning "   - Role: $ROLE"
    warning "   - Subject (CN): $CERT_CN"
    warning ""
    warning "Then test again with:"
    warning "  curl --cert $CERT_FILE --key $KEY_FILE -k $ROX_CENTRAL_URL/v1/auth/status"
fi

echo ""
step "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Verify auth provider in RHACS UI:"
echo "   ${ROX_CENTRAL_URL}/#/platform-configuration/access-control/auth-providers"
echo ""
echo "2. Test certificate authentication:"
echo "   curl --cert $CERT_FILE --key $KEY_FILE -k $ROX_CENTRAL_URL/v1/auth/status"
echo ""
echo "3. Test metrics access:"
echo "   curl --cert $CERT_FILE --key $KEY_FILE -k $ROX_CENTRAL_URL/metrics | head -20"
echo ""
