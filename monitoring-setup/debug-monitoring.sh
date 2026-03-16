#!/bin/bash
#
# RHACS Monitoring Debug Script
# Diagnoses why the Perses dashboard shows "No data" by testing connectivity
# at each step of the pipeline: RHACS Central -> Prometheus -> Perses
#
# Usage:
#   cd monitoring-setup
#   export ROX_CENTRAL_URL="https://central-stackrox.apps.cluster.example.com"
#   ./debug-monitoring.sh
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
ok() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
step "RHACS Monitoring Debug"
echo "=========================================="
echo ""

# Load ROX_CENTRAL_URL from ~/.bashrc if not set
if [ -z "${ROX_CENTRAL_URL:-}" ] && [ -f ~/.bashrc ]; then
  line=$(grep -E "^(export[[:space:]]+)?ROX_CENTRAL_URL=" ~/.bashrc 2>/dev/null | head -1)
  [ -n "$line" ] && eval "$line"
fi

if [ -z "${ROX_CENTRAL_URL:-}" ]; then
  error "ROX_CENTRAL_URL is not set"
  echo "  export ROX_CENTRAL_URL='https://central-stackrox.apps.cluster.example.com'"
  exit 1
fi

# Strip https:// for internal endpoint
ROX_ENDPOINT="${ROX_CENTRAL_URL#https://}"
ROX_ENDPOINT="${ROX_ENDPOINT#http://}"
[[ "$ROX_ENDPOINT" =~ :[0-9]+$ ]] || ROX_ENDPOINT="${ROX_ENDPOINT}:443"

# Internal cluster URL (Prometheus scrapes this)
CENTRAL_INTERNAL="central.stackrox.svc.cluster.local:443"

echo ""

#=============================================================================
# Step 1: Test RHACS metrics endpoint from local machine (client cert)
#=============================================================================
step "1. Test RHACS metrics endpoint (client certificate)"
echo ""

if [ ! -f "client.crt" ] || [ ! -f "client.key" ]; then
  fail "Certificates not found (client.crt, client.key)"
  echo "  Run: ./01-setup-certificates.sh"
else
  ok "Certificates found"

  echo ""
  log "Testing /v1/auth/status (client cert auth)..."
  AUTH_RESP=$(curl -k -s -w "\n%{http_code}" --cert client.crt --key client.key "$ROX_CENTRAL_URL/v1/auth/status")
  AUTH_HTTP=$(echo "$AUTH_RESP" | tail -1)
  AUTH_BODY=$(echo "$AUTH_RESP" | head -n -1)

  if [ "$AUTH_HTTP" = "200" ] && echo "$AUTH_BODY" | grep -q '"userId"'; then
    ok "Auth status: authenticated"
  elif echo "$AUTH_BODY" | grep -q "credentials not found"; then
    fail "Auth status: credentials not found (group mapping may be missing)"
    echo "  Run: ./troubleshoot-auth.sh"
  else
    fail "Auth status failed (HTTP $AUTH_HTTP)"
    echo "  Response: $AUTH_BODY"
  fi

  echo ""
  log "Testing /metrics endpoint (client cert)..."
  METRICS_RESP=$(curl -k -s -w "\n%{http_code}" --cert client.crt --key client.key "$ROX_CENTRAL_URL/metrics" | head -50)
  METRICS_HTTP=$(echo "$METRICS_RESP" | tail -1)
  METRICS_BODY=$(echo "$METRICS_RESP" | head -n -1)

  if [ "$METRICS_HTTP" = "200" ]; then
    if echo "$METRICS_BODY" | grep -qE "^(rox_|# )"; then
      ok "Metrics endpoint: returning data"
      echo "  Sample metrics:"
      echo "$METRICS_BODY" | grep -E "^rox_" | head -5 | sed 's/^/    /'
    elif echo "$METRICS_BODY" | grep -q "access for this user is not authorized"; then
      fail "Metrics endpoint: access denied (no valid role)"
      echo "  Ensure the group has 'Prometheus Server' role"
    else
      echo "  Response (first 500 chars):"
      echo "$METRICS_BODY" | head -20 | sed 's/^/    /'
    fi
  else
    fail "Metrics endpoint failed (HTTP $METRICS_HTTP)"
  fi
fi

echo ""

#=============================================================================
# Step 2: Check Prometheus scrape config and in-cluster connectivity
#=============================================================================
step "2. Prometheus scrape configuration"
echo ""

if oc get scrapeconfig sample-stackrox-scrape-config -n stackrox &>/dev/null; then
  ok "ScrapeConfig exists"
  log "  Target: $CENTRAL_INTERNAL"
  log "  Secret: sample-stackrox-prometheus-tls"
else
  fail "ScrapeConfig not found"
  echo "  Run: ./02-install-monitoring.sh"
fi

log "  To test from inside cluster (like Prometheus does):"
echo "    oc run curl-test --rm -it --image=curlimages/curl -n stackrox -- wget -qO- https://central.stackrox.svc.cluster.local:443/"
echo ""

#=============================================================================
# Step 3: Check Prometheus targets and scrape status
#=============================================================================
step "3. Prometheus scrape targets"
echo ""

PROM_SVC="sample-stackrox-monitoring-stack-prometheus"
if oc get svc -n stackrox "$PROM_SVC" &>/dev/null; then
  ok "Prometheus service exists: $PROM_SVC"

  log "Port-forwarding to Prometheus (run in another terminal to query):"
  echo "  oc port-forward -n stackrox svc/$PROM_SVC 9090:9090"
  echo ""
  log "Then check targets:"
  echo "  curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job | contains(\"stackrox\")) | {job, health, lastError}'"
  echo ""
  log "Or open: http://localhost:9090/targets"
else
  fail "Prometheus service not found: $PROM_SVC"
  echo "  Available services:"
  oc get svc -n stackrox | grep -E "prometheus|monitoring" || echo "  (none)"
fi

echo ""

#=============================================================================
# Step 4: Verify TLS secret for Prometheus
#=============================================================================
step "4. Prometheus TLS secret (for scrape)"
echo ""

if oc get secret sample-stackrox-prometheus-tls -n stackrox &>/dev/null; then
  ok "Secret sample-stackrox-prometheus-tls exists"
  CERT_SUBJECT=$(oc get secret sample-stackrox-prometheus-tls -n stackrox -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null | openssl x509 -noout -subject 2>/dev/null) || true
  [ -n "$CERT_SUBJECT" ] && echo "  Subject: $CERT_SUBJECT"
else
  fail "Secret sample-stackrox-prometheus-tls not found"
  echo "  Run: ./01-setup-certificates.sh"
fi

echo ""

#=============================================================================
# Step 5: RHACS metrics configuration (policy violations, vulns disabled by default)
#=============================================================================
step "5. RHACS metrics configuration"
echo ""
log "Policy violations, image/vuln metrics are disabled by default in RHACS."
log "Enable in: Platform Configuration → System Configuration → Prometheus metrics"
echo "  Or via API:"
echo "  curl -k -H \"Authorization: Bearer \$ROX_API_TOKEN\" \\"
echo "    \"\$ROX_CENTRAL_URL/v1/config\" | jq '.privateConfig.metrics'"
echo ""

#=============================================================================
# Step 6: Quick manual test commands
#=============================================================================
step "6. Manual test commands"
echo ""
echo "  # Test auth (from monitoring-setup directory):"
echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/v1/auth/status"
echo ""
echo "  # Test metrics endpoint (same as Prometheus scrape):"
echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/metrics | head -20"
echo ""
echo "  # Port-forward Prometheus and check targets:"
echo "  oc port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090"
echo "  # Then: http://localhost:9090/targets"
echo ""
echo "  # Check Perses datasource URL (should match Prometheus service):"
echo "  oc get persesdatasource -n stackrox -o yaml | grep -A2 url"
echo ""

step "Debug complete"
echo ""
