#!/bin/bash
#
# RHACS Monitoring Setup - RHACS Authentication Configuration
# Configures declarative configuration and creates auth provider with groups
#

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

step "RHACS Authentication Configuration"
echo "=========================================="
echo ""

# Check required environment variables
if [ -z "${ROX_CENTRAL_URL:-}" ]; then
  error "ROX_CENTRAL_URL is not set"
  exit 1
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
  error "ROX_API_TOKEN is not set"
  exit 1
fi

# Load TLS_CERT from certificate generation script
if [ -f "$SCRIPT_DIR/.env.certs" ]; then
  source "$SCRIPT_DIR/.env.certs"
else
  warn ".env.certs not found, loading TLS_CERT from ca.crt..."
  if [ -f "$SCRIPT_DIR/ca.crt" ]; then
    export TLS_CERT=$(awk '{printf "%s\\n", $0}' ca.crt)
  else
    error "ca.crt not found. Run 01-setup-certificates.sh first."
    exit 1
  fi
fi

log "Declaring a permission set and a role in RHACS..."

# First, create the declarative configuration ConfigMap
oc apply -f monitoring-examples/rhacs/declarative-configuration-configmap.yaml
log "✓ Declarative configuration ConfigMap created"

echo ""
log "Checking if declarative configuration is enabled on Central..."
if oc get deployment central -n stackrox -o yaml | grep -q "declarative-config"; then
  log "✓ Declarative configuration is already enabled"
else
  warn "Declarative configuration mount not found on Central deployment"
  log "Enabling declarative configuration on Central..."
  
  # Check if Central is managed by operator or deployed directly
  if oc get central stackrox-central-services -n stackrox &>/dev/null; then
    log "Using RHACS Operator to enable declarative configuration..."
    oc patch central stackrox-central-services -n stackrox --type=merge -p='
spec:
  central:
    declarativeConfiguration:
      configMaps:
      - name: sample-stackrox-prometheus-declarative-configuration
'
    log "Waiting for Central to update..."
    sleep 10
  else
    log "Directly patching Central deployment..."
    # For non-operator deployments, manually add volume and mount
    oc set volume deployment/central -n stackrox \
      --add --name=declarative-config \
      --type=configmap \
      --configmap-name=sample-stackrox-prometheus-declarative-configuration \
      --mount-path=/run/secrets/stackrox.io/declarative-config \
      --read-only=true
  fi
  
  log "Waiting for Central to restart..."
  oc rollout status deployment/central -n stackrox --timeout=300s
  log "✓ Declarative configuration enabled"
fi

echo ""
log "Checking for existing 'Monitoring' auth provider..."

# Get all auth providers and extract the ID for "Monitoring"
if command -v jq &>/dev/null; then
  EXISTING_AUTH_ID=$(curl -k -s "$ROX_CENTRAL_URL/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" | \
    jq -r '.authProviders[]? | select(.name=="Monitoring") | .id' 2>/dev/null)
else
  EXISTING_AUTH_ID=$(curl -k -s "$ROX_CENTRAL_URL/v1/authProviders" \
    -H "Authorization: Bearer $ROX_API_TOKEN" | \
    grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
fi

# Delete if exists
if [ -n "$EXISTING_AUTH_ID" ] && [ "$EXISTING_AUTH_ID" != "null" ]; then
  log "Deleting existing 'Monitoring' auth provider (ID: $EXISTING_AUTH_ID)..."
  curl -k -s -X DELETE "$ROX_CENTRAL_URL/v1/authProviders/$EXISTING_AUTH_ID" \
    -H "Authorization: Bearer $ROX_API_TOKEN" > /dev/null
  log "✓ Deleted existing auth provider"
  sleep 2
fi

echo ""
log "Creating User-Certificate auth provider..."
AUTH_PROVIDER_RESPONSE=$(curl -k -s -X POST "$ROX_CENTRAL_URL/v1/authProviders" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-raw "$(envsubst < monitoring-examples/rhacs/auth-provider.json.tpl)")

# Extract the auth provider ID from the response (try multiple patterns)
export AUTH_PROVIDER_ID=$(echo "$AUTH_PROVIDER_RESPONSE" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')

# If grep/sed didn't work, try jq if available
if [ -z "$AUTH_PROVIDER_ID" ] && command -v jq &>/dev/null; then
  export AUTH_PROVIDER_ID=$(echo "$AUTH_PROVIDER_RESPONSE" | jq -r '.id // empty' 2>/dev/null)
fi

if [ -n "$AUTH_PROVIDER_ID" ]; then
  log "✓ Auth provider created with ID: $AUTH_PROVIDER_ID"
  
  # Create group mapping
  log "Creating Admin group mapping..."
  GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_URL/v1/groups" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$(envsubst < monitoring-examples/rhacs/admin-group.json.tpl)")
  
  HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)
  RESPONSE_BODY=$(echo "$GROUP_RESPONSE" | head -n -1)
  
  if [ "$HTTP_CODE" = "200" ] && echo "$RESPONSE_BODY" | grep -q '"props"'; then
    log "✓ Admin role assigned (HTTP $HTTP_CODE)"
    warn "Auth changes may take 10-30 seconds to propagate"
  elif [ "$HTTP_CODE" = "409" ]; then
    log "✓ Group already exists for Monitoring auth provider"
  else
    warn "Group creation may have failed (HTTP $HTTP_CODE)"
    warn "Run troubleshoot-auth.sh if authentication doesn't work"
  fi
else
  error "Failed to extract auth provider ID"
  error "You may need to configure the group manually"
  exit 1
fi

echo ""
log "✓ RHACS authentication configuration complete"
echo ""
