#!/bin/bash
#
# RHACS Monitoring Setup - Main Installation Script
# Orchestrates the complete monitoring setup by calling individual setup scripts
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

# Get the script directory and ensure we're in it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

#================================================================
# Utility Functions
#================================================================

# Strip https:// from ROX_CENTRAL_URL for roxctl -e flag
# roxctl expects host:port format and defaults to https
#
# Usage:
#   ROX_ENDPOINT=$(get_rox_endpoint)
#   roxctl -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" central userpki list ...
#
# Example:
#   If ROX_CENTRAL_URL="https://central-stackrox.apps.cluster.com"
#   Then get_rox_endpoint returns "central-stackrox.apps.cluster.com"
get_rox_endpoint() {
    local url="${ROX_CENTRAL_URL:-}"
    # Remove https:// prefix if present
    echo "${url#https://}"
}

#================================================================
# Pre-flight Checks
#================================================================

echo ""
echo "=============================================="
echo "  RHACS Monitoring Setup"
echo "=============================================="
echo ""

log "Starting installation..."
echo ""

# Check required environment variables
MISSING_VARS=0

if [ -z "${ROX_CENTRAL_URL:-}" ]; then
  error "ROX_CENTRAL_URL is not set"
  MISSING_VARS=$((MISSING_VARS + 1))
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
  error "ROX_API_TOKEN is not set"
  MISSING_VARS=$((MISSING_VARS + 1))
fi

if [ $MISSING_VARS -gt 0 ]; then
  echo ""
  error "Missing required environment variables. Please set them and try again."
  echo ""
  echo "Example:"
  echo "  export ROX_CENTRAL_URL='https://central-stackrox.apps.cluster.com'"
  echo "  export ROX_API_TOKEN='your-api-token'"
  echo ""
  exit 1
fi

log "✓ Required environment variables are set"
echo ""

#================================================================
# Step 1: Setup Certificates
#================================================================

step "Step 1 of 3: Setting up certificates"
echo ""

if [ ! -x "$SCRIPT_DIR/01-setup-certificates.sh" ]; then
  chmod +x "$SCRIPT_DIR/01-setup-certificates.sh"
fi

if "$SCRIPT_DIR/01-setup-certificates.sh"; then
  log "✓ Certificate setup complete"
else
  error "Certificate setup failed"
  exit 1
fi

# Load certificate environment
if [ -f "$SCRIPT_DIR/.env.certs" ]; then
  source "$SCRIPT_DIR/.env.certs"
fi

#================================================================
# Step 2: Install Monitoring Stack
#================================================================

step "Step 2 of 3: Installing monitoring stack"
echo ""

if [ ! -x "$SCRIPT_DIR/02-install-monitoring.sh" ]; then
  chmod +x "$SCRIPT_DIR/02-install-monitoring.sh"
fi

if "$SCRIPT_DIR/02-install-monitoring.sh"; then
  log "✓ Monitoring stack installation complete"
else
  error "Monitoring stack installation failed"
  exit 1
fi

#================================================================
# Step 3: Configure RHACS Authentication
#================================================================

step "Step 3 of 3: Configuring RHACS authentication"
echo ""

if [ ! -x "$SCRIPT_DIR/03-configure-rhacs-auth.sh" ]; then
  chmod +x "$SCRIPT_DIR/03-configure-rhacs-auth.sh"
fi

if "$SCRIPT_DIR/03-configure-rhacs-auth.sh"; then
  log "✓ RHACS authentication configuration complete"
else
  error "RHACS authentication configuration failed"
  exit 1
fi

#================================================================
# Verification
#================================================================

echo ""
echo "============================================"
echo "Verifying Configuration"
echo "============================================"
echo ""

# Give auth system time to propagate changes
log "Waiting for auth configuration to propagate (10 seconds)..."
sleep 10

# Extract auth provider ID (set by 03-configure-rhacs-auth.sh)
if [ -z "${AUTH_PROVIDER_ID:-}" ]; then
  # Try to get it from the API
  if command -v jq &>/dev/null; then
    AUTH_PROVIDER_ID=$(curl -k -s "$ROX_CENTRAL_URL/v1/authProviders" \
      -H "Authorization: Bearer $ROX_API_TOKEN" | \
      jq -r '.authProviders[]? | select(.name=="Monitoring") | .id' 2>/dev/null)
  else
    AUTH_PROVIDER_ID=$(curl -k -s "$ROX_CENTRAL_URL/v1/authProviders" \
      -H "Authorization: Bearer $ROX_API_TOKEN" | \
      grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
  fi
fi

# Verify the group was created
log "Checking groups for auth provider..."
GROUPS_LIST=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_URL/v1/groups" | grep -A5 "$AUTH_PROVIDER_ID" || echo "")

if [ -n "$GROUPS_LIST" ]; then
  log "✓ Group mapping found for Monitoring auth provider"
  
  # Test client certificate authentication
  echo ""
  log "Testing client certificate authentication..."
  AUTH_TEST=$(curl -k -s --cert client.crt --key client.key "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
  
  if echo "$AUTH_TEST" | grep -q '"userId"'; then
    log "✓ Client certificate authentication successful!"
  elif echo "$AUTH_TEST" | grep -q "credentials not found"; then
    warn "Authentication failed: credentials not found"
    echo ""
    warn "This may take 10-30 seconds to propagate. Wait a moment and try:"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/v1/auth/status"
    echo ""
    warn "If it continues to fail, run the troubleshooting script:"
    echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
  else
    warn "Unexpected response: $AUTH_TEST"
  fi
else
  warn "No group mapping found - authentication may fail!"
  echo ""
  warn "Run the troubleshooting script to diagnose and fix:"
  echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
fi

#================================================================
# Installation Complete
#================================================================

echo ""
echo "============================================"
echo "Installation Complete!"
echo "============================================"
echo ""
echo "Certificates created in: $SCRIPT_DIR/"
echo "  - ca.crt / ca.key          (CA certificate - configured in auth provider)"
echo "  - client.crt / client.key  (Client certificate - use for API calls)"
echo ""
echo "Test authentication:"
echo "  cd $SCRIPT_DIR && curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/metrics"
echo ""
echo "If authentication fails with 'credentials not found', run:"
echo "  ./troubleshoot-auth.sh"
echo ""
echo "Verify configuration with roxctl:"
echo "  ROX_ENDPOINT=\${ROX_CENTRAL_URL#https://}"
echo "  roxctl -e \"\$ROX_ENDPOINT\" central userpki list --insecure-skip-tls-verify"
echo "  roxctl -e \"\$ROX_ENDPOINT\" central group list --insecure-skip-tls-verify"
echo ""
echo "Note: Auth changes may take 10-30 seconds to propagate."
echo ""

# Clean up temporary environment file
rm -f "$SCRIPT_DIR/.env.certs"
