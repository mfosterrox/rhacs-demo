#!/bin/bash
#
# RHACS Monitoring Authentication Troubleshooting Script
#

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
step "RHACS Monitoring Authentication Troubleshooting"
echo "================================================="
echo ""

# Check required variables
if [ -z "${ROX_CENTRAL_URL:-}" ]; then
  error "ROX_CENTRAL_URL is not set"
  exit 1
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
  error "ROX_API_TOKEN is not set"
  exit 1
fi

# Check certificates exist
if [ ! -f "ca.crt" ] || [ ! -f "client.crt" ] || [ ! -f "client.key" ]; then
  error "Certificates not found. Run ./install.sh first"
  exit 1
fi

echo "1. Checking auth provider..."
ROX_ENDPOINT="${ROX_CENTRAL_URL#https://}"

# Try with :443 port if not already present
if [[ ! "$ROX_ENDPOINT" =~ :[0-9]+$ ]]; then
  ROX_ENDPOINT_WITH_PORT="${ROX_ENDPOINT}:443"
else
  ROX_ENDPOINT_WITH_PORT="$ROX_ENDPOINT"
fi

AUTH_PROVIDERS=$(roxctl -e "$ROX_ENDPOINT_WITH_PORT" central userpki list --insecure-skip-tls-verify 2>&1)
ROXCTL_EXIT_CODE=$?

if [ $ROXCTL_EXIT_CODE -ne 0 ]; then
  error "Failed to list auth providers (roxctl exit code: $ROXCTL_EXIT_CODE)"
  echo "Output: $AUTH_PROVIDERS"
  exit 1
fi

if echo "$AUTH_PROVIDERS" | grep -q "Provider: Monitoring"; then
  log "✓ Auth provider 'Monitoring' found"
  echo "$AUTH_PROVIDERS" | grep -A7 "Provider: Monitoring"
else
  error "Auth provider 'Monitoring' not found"
  echo "Available providers:"
  echo "$AUTH_PROVIDERS"
  exit 1
fi

echo ""
echo "2. Testing client certificate authentication..."
CLIENT_CERT_INFO=$(openssl x509 -in client.crt -noout -subject -dates)
echo "Client certificate:"
echo "$CLIENT_CERT_INFO"

echo ""
echo "Testing authentication..."
AUTH_RESPONSE=$(curl -k -s --cert client.crt --key client.key "$ROX_CENTRAL_URL/v1/auth/status")

if echo "$AUTH_RESPONSE" | grep -q '"userId"'; then
  log "✓ Authentication successful!"
  echo "$AUTH_RESPONSE" | jq '.' 2>/dev/null || echo "$AUTH_RESPONSE"
elif echo "$AUTH_RESPONSE" | grep -q "credentials not found"; then
  error "Authentication failed: credentials not found"
  echo ""
  warn "This usually means:"
  warn "1. The group mapping is missing or incorrect"
  warn "2. The client certificate CN doesn't match expected format"
  warn "3. There's a delay in auth provider/group propagation"
  echo ""
  step "Trying alternative group configuration..."
  
  # Try creating a group with specific key/value for the CN
  CLIENT_CN=$(openssl x509 -in client.crt -noout -subject | sed 's/.*CN = //')
  echo "Client CN: $CLIENT_CN"
  
  GROUP_PAYLOAD_WITH_CN="{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"name\",\"value\":\"$CLIENT_CN\"},\"roleName\":\"Admin\"}"
  
  echo "Creating group with CN mapping..."
  GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_URL/v1/groups" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$GROUP_PAYLOAD_WITH_CN")
  
  HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)
  RESPONSE_BODY=$(echo "$GROUP_RESPONSE" | head -n -1)
  
  if [ "$HTTP_CODE" = "200" ]; then
    log "✓ CN-specific group created"
    echo ""
    warn "Wait 10-30 seconds for changes to propagate, then test again:"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/v1/auth/status"
  fi
else
  error "Unexpected response: $AUTH_RESPONSE"
fi

echo ""
echo "================================================="
echo "Troubleshooting complete"
echo "================================================="
