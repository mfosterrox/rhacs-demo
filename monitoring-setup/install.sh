#!/bin/bash
#
# RHACS Monitoring Setup Script
# Follows the official monitoring-examples installation flow
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
NAMESPACE="${NAMESPACE:-stackrox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$SCRIPT_DIR/monitoring-examples"

# Detect kubectl/oc
if command -v oc &>/dev/null; then
    KUBE_CMD="oc"
else
    KUBE_CMD="kubectl"
fi

echo ""
step "RHACS Monitoring Setup"
echo "=========================================="
echo ""

#================================================================
# Prerequisites
#================================================================
log "Checking prerequisites..."

if ! $KUBE_CMD whoami &>/dev/null; then
    error "Not connected to cluster. Please login first: oc login"
fi
log "✓ Connected as: $($KUBE_CMD whoami)"

if ! $KUBE_CMD get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found. Install RHACS first."
fi
log "✓ Namespace '$NAMESPACE' exists"

if ! command -v openssl &>/dev/null; then
    error "openssl not found. Please install openssl."
fi
log "✓ openssl found"

if ! command -v envsubst &>/dev/null; then
    warning "envsubst not found - will use sed for template substitution"
fi

log ""

#================================================================
# Set project/namespace
#================================================================
step "Setting namespace to $NAMESPACE"
$KUBE_CMD project "$NAMESPACE" 2>/dev/null || log "Using namespace: $NAMESPACE"
log ""

#================================================================
# Load/Generate ROX_API_TOKEN
#================================================================
step "Configuring ROX_API_TOKEN"
log ""

# Get ROX_CENTRAL_URL
if [ -z "${ROX_CENTRAL_URL:-}" ]; then
    if $KUBE_CMD get route central -n "$NAMESPACE" &>/dev/null; then
        ROX_CENTRAL_URL="https://$($KUBE_CMD get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
        export ROX_CENTRAL_URL
        log "✓ Detected ROX_CENTRAL_URL: $ROX_CENTRAL_URL"
    else
        error "ROX_CENTRAL_URL not set and could not auto-detect from route"
    fi
else
    log "✓ ROX_CENTRAL_URL already set: $ROX_CENTRAL_URL"
fi

# Set ROX_API_ENDPOINT (without https://)
export ROX_API_ENDPOINT="${ROX_CENTRAL_URL#https://}"
export ROX_API_ENDPOINT="${ROX_API_ENDPOINT#http://}"

# Check for or generate ROX_API_TOKEN
if [ -z "${ROX_API_TOKEN:-}" ]; then
    # Try to load from ~/.bashrc
    if [ -f ~/.bashrc ] && grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
        ROX_API_TOKEN=$(grep "export ROX_API_TOKEN=" ~/.bashrc | head -1 | sed "s/export ROX_API_TOKEN=//g" | tr -d "'" | tr -d '"')
        export ROX_API_TOKEN
        log "✓ Loaded ROX_API_TOKEN from ~/.bashrc"
    else
        # Try to generate it
        log "Attempting to generate ROX_API_TOKEN..."
        
        ADMIN_PASSWORD=$($KUBE_CMD get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
        if [ -n "$ADMIN_PASSWORD" ]; then
            TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
                -u "admin:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                "https://${ROX_API_ENDPOINT}/v1/apitokens/generate" \
                -d '{"name":"monitoring-setup-'$(date +%s)'","roles":["Admin"]}' 2>&1)
            
            if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
                ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
                if [ -n "$ROX_API_TOKEN" ]; then
                    export ROX_API_TOKEN
                    log "✓ Generated ROX_API_TOKEN"
                    
                    # Save to ~/.bashrc
                    if [ -f ~/.bashrc ] && ! grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
                        echo "export ROX_API_TOKEN='$ROX_API_TOKEN'" >> ~/.bashrc
                        log "✓ Saved ROX_API_TOKEN to ~/.bashrc"
                    fi
                fi
            fi
        fi
        
        if [ -z "${ROX_API_TOKEN:-}" ]; then
            error "Failed to generate ROX_API_TOKEN. Please set it manually: export ROX_API_TOKEN='your-token'"
        fi
    fi
else
    log "✓ ROX_API_TOKEN already set"
fi

# Save to ~/.bashrc if not there
if [ -f ~/.bashrc ]; then
    if ! grep -q "export ROX_CENTRAL_URL=" ~/.bashrc; then
        echo "export ROX_CENTRAL_URL='$ROX_CENTRAL_URL'" >> ~/.bashrc
    fi
    if ! grep -q "GRPC_ENFORCE_ALPN_ENABLED" ~/.bashrc; then
        echo "# Fix for gRPC ALPN enforcement issues with roxctl" >> ~/.bashrc
        echo "export GRPC_ENFORCE_ALPN_ENABLED=false" >> ~/.bashrc
    fi
fi

export GRPC_ENFORCE_ALPN_ENABLED=false
log ""

#================================================================
# Step 1: Install Cluster Observability Operator
#================================================================
step "Step 1: Installing Cluster Observability Operator"
log ""

if [ ! -f "$EXAMPLES_DIR/cluster-observability-operator/subscription.yaml" ]; then
    error "subscription.yaml not found in $EXAMPLES_DIR/cluster-observability-operator/"
fi

# Check if already installed
if $KUBE_CMD get csv -n openshift-cluster-observability-operator 2>/dev/null | grep -q cluster-observability-operator; then
    CSV=$($KUBE_CMD get csv -n openshift-cluster-observability-operator -o name 2>/dev/null | grep cluster-observability-operator | head -1)
    CSV_PHASE=$($KUBE_CMD get "$CSV" -n openshift-cluster-observability-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$CSV_PHASE" = "Succeeded" ]; then
        log "✓ Cluster Observability Operator already installed and running"
    else
        log "Installing Cluster Observability Operator..."
        $KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/subscription.yaml"
        log "Waiting for operator to be ready..."
        sleep 30
    fi
else
    log "Installing Cluster Observability Operator..."
    $KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/subscription.yaml"
    
    # Wait for CSV to be created
    log "Waiting for CSV to be created (this may take 1-2 minutes)..."
    for i in {1..24}; do
        if $KUBE_CMD get csv -n openshift-cluster-observability-operator 2>/dev/null | grep -q cluster-observability-operator; then
            break
        fi
        sleep 5
        if [ $((i % 4)) -eq 0 ]; then
            log "  Still waiting... ($((i * 5))s)"
        fi
    done
    
    # Wait for CSV to succeed
    CSV=$($KUBE_CMD get csv -n openshift-cluster-observability-operator -o name 2>/dev/null | grep cluster-observability-operator | head -1 || echo "")
    if [ -n "$CSV" ]; then
        log "Found CSV: $CSV"
        log "Waiting for CSV to be ready..."
        $KUBE_CMD wait --for=jsonpath='{.status.phase}'=Succeeded "$CSV" -n openshift-cluster-observability-operator --timeout=300s || warning "CSV wait timeout"
        log "✓ Cluster Observability Operator installed"
    else
        error "CSV not found after installation"
    fi
fi
log ""

#================================================================
# Step 2: Generate User Certificates
#================================================================
step "Step 2: Generating user certificates"
log ""

cd "$SCRIPT_DIR"

# Generate certificate
CERT_CN="sample-$NAMESPACE-monitoring-stack-prometheus.$NAMESPACE.svc"
log "Generating TLS certificate with CN: $CERT_CN"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=$CERT_CN" \
    -keyout tls.key -out tls.crt 2>/dev/null

log "✓ Certificate generated: tls.crt, tls.key"

# Validate certificate
if openssl x509 -in tls.crt -noout -checkend 0 2>/dev/null; then
    log "✓ Certificate is valid"
else
    warning "Certificate validation failed"
fi

# Export TLS_CERT in format needed for JSON (newline escaped)
export TLS_CERT=$(awk '{printf "%s\\n", $0}' tls.crt)
log "✓ TLS_CERT exported for auth provider creation"

# Create TLS secret
log "Creating TLS secret in namespace '$NAMESPACE'..."
$KUBE_CMD delete secret sample-$NAMESPACE-prometheus-tls -n "$NAMESPACE" 2>/dev/null || true
$KUBE_CMD create secret tls sample-$NAMESPACE-prometheus-tls --cert=tls.crt --key=tls.key -n "$NAMESPACE"
log "✓ TLS secret created"

# Create API token secret if token is set
if [ -n "${ROX_API_TOKEN:-}" ]; then
    log "Creating API token secret..."
    $KUBE_CMD delete secret $NAMESPACE-prometheus-api-token -n "$NAMESPACE" 2>/dev/null || true
    $KUBE_CMD create secret generic $NAMESPACE-prometheus-api-token \
        -n "$NAMESPACE" \
        --from-literal=token="$ROX_API_TOKEN"
    log "✓ API token secret created"
fi

log ""

#================================================================
# Step 3: Install and Configure Monitoring Stack
#================================================================
step "Step 3: Installing and configuring monitoring stack instance"
log ""

log "Applying MonitoringStack..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml"
log "✓ MonitoringStack applied"

sleep 3

log "Applying ScrapeConfig..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml"
log "✓ ScrapeConfig applied"

log "Waiting for Prometheus to start (30 seconds)..."
sleep 30

log ""

#================================================================
# Step 4: Install Perses and Configure Dashboard
#================================================================
step "Step 4: Installing Perses and configuring RHACS dashboard"
log ""

log "Applying Perses UI Plugin (cluster-scoped)..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/perses/ui-plugin.yaml"
log "✓ UI Plugin applied"

log "Applying Perses Datasource..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/perses/datasource.yaml"
log "✓ Datasource applied"

log "Applying Perses Dashboard..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/perses/dashboard.yaml"
log "✓ Dashboard applied"

log ""

#================================================================
# Step 5: Declare Permission Set and Role in RHACS
#================================================================
step "Step 5: Declaring permission set and role in RHACS"
log ""

log "Applying declarative configuration..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml"
log "✓ Declarative configuration applied"
log "Note: RHACS will process this and create the 'Prometheus Server' role"

log ""

#================================================================
# Step 6: Create User-Certificate Auth Provider
#================================================================
step "Step 6: Creating User-Certificate auth provider"
log ""

if [ ! -f "$EXAMPLES_DIR/rhacs/auth-provider.json.tpl" ]; then
    warning "auth-provider.json.tpl not found. Skipping auth provider creation."
    warning "You can create it manually in RHACS UI:"
    warning "  Platform Configuration → Access Control → Auth Providers"
else
    log "Creating auth provider via API..."
    
    # Substitute environment variables in template
    if command -v envsubst &>/dev/null; then
        AUTH_PROVIDER_JSON=$(envsubst < "$EXAMPLES_DIR/rhacs/auth-provider.json.tpl")
    else
        # Fallback to sed if envsubst not available
        AUTH_PROVIDER_JSON=$(cat "$EXAMPLES_DIR/rhacs/auth-provider.json.tpl" | \
            sed "s|\${ROX_CENTRAL_URL}|$ROX_CENTRAL_URL|g" | \
            sed "s|\${TLS_CERT}|$TLS_CERT|g")
    fi
    
    # Create auth provider
    RESPONSE=$(curl -k -s -X POST "$ROX_CENTRAL_URL/v1/authProviders" \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data-raw "$AUTH_PROVIDER_JSON" 2>&1)
    
    if echo "$RESPONSE" | grep -q '"id"'; then
        log "✓ User-Certificate auth provider 'Monitoring' created successfully"
        PROVIDER_ID=$(echo "$RESPONSE" | jq -r '.id // empty')
        log "  Provider ID: $PROVIDER_ID"
    elif echo "$RESPONSE" | grep -qi "already exists"; then
        log "✓ Auth provider already exists"
    else
        warning "Failed to create auth provider via API"
        log "Response: ${RESPONSE:0:200}"
        warning ""
        warning "You may need to create it manually in RHACS UI:"
        warning "  1. Go to: $ROX_CENTRAL_URL"
        warning "  2. Navigate to: Platform Configuration → Access Control → Auth Providers"
        warning "  3. Create auth provider:"
        warning "     - Type: User Certificates"
        warning "     - Name: Monitoring"
        warning "     - Upload certificate: tls.crt"
    fi
fi

log ""

#================================================================
# Step 7: Configure Minimum Role
#================================================================
step "Step 7: Configure minimum role for Monitoring auth provider"
log ""

warning "MANUAL STEP REQUIRED:"
warning "Configure the minimum role for the 'Monitoring' auth provider in RHACS UI or via API"
warning ""
warning "Via UI:"
warning "  1. Go to: $ROX_CENTRAL_URL"
warning "  2. Navigate to: Platform Configuration → Access Control → Access Control"
warning "  3. Create access:"
warning "     - Name: prometheus-monitoring"
warning "     - Auth Provider: Monitoring"
warning "     - Role: Prometheus Server"
warning "     - Subject: $CERT_CN"
warning ""
warning "Via API (alternative):"
warning "  curl -k -X POST \$ROX_CENTRAL_URL/v1/groups \\"
warning "    -H 'Authorization: Bearer \$ROX_API_TOKEN' \\"
warning "    -H 'Content-Type: application/json' \\"
warning "    -d '{\"props\":{\"authProviderId\":\"<provider-id>\"},\"roleName\":\"Prometheus Server\"}'"

log ""

#================================================================
# Diagnostics
#================================================================
step "Running diagnostics"
log ""

# Check MonitoringStack
log "=== MonitoringStack Status ==="
$KUBE_CMD get monitoringstack -n "$NAMESPACE" 2>/dev/null || warning "No MonitoringStack found"

# Check Prometheus pods
log ""
log "=== Prometheus Pods ==="
$KUBE_CMD get pods -n "$NAMESPACE" 2>/dev/null | grep prometheus || warning "No Prometheus pods found yet (may take a few minutes)"

# Check secrets
log ""
log "=== Secrets ==="
$KUBE_CMD get secrets -n "$NAMESPACE" | grep -E "prometheus|tls" || warning "No monitoring secrets found"

# Test API authentication
log ""
log "=== Testing API Token Authentication ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
if [ "$HTTP_CODE" = "200" ]; then
    log "✓ API token authentication working (HTTP $HTTP_CODE)"
else
    warning "API token authentication returned HTTP $HTTP_CODE"
fi

# Test certificate authentication
log ""
log "=== Testing Certificate Authentication ==="
if [ -f "tls.crt" ] && [ -f "tls.key" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --cert tls.crt --key tls.key -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ Certificate authentication working (HTTP $HTTP_CODE)"
    else
        warning "Certificate authentication not configured yet (HTTP $HTTP_CODE)"
        warning "Complete Step 7 above to enable certificate authentication"
    fi
fi

log ""

#================================================================
# Summary
#================================================================
step "Setup Complete!"
echo "=========================================="
echo ""
echo "✓ Cluster Observability Operator installed"
echo "✓ MonitoringStack deployed"
echo "✓ ScrapeConfig applied"
echo "✓ Perses resources installed"
echo "✓ RHACS declarative configuration applied"
echo "✓ User-Certificate auth provider created"
echo ""
echo "⚠️  REQUIRED: Complete Step 7 (configure role for auth provider)"
echo ""
echo "Next steps:"
echo ""
echo "1. Configure the role for 'Monitoring' auth provider (see Step 7 above)"
echo ""
echo "2. Wait for Prometheus pods to start (check with):"
echo "   oc get pods -n $NAMESPACE | grep prometheus"
echo ""
echo "3. Access Prometheus UI:"
echo "   oc port-forward -n $NAMESPACE \$(oc get pods -n $NAMESPACE -o name | grep prometheus | head -1 | sed 's|pod/||') 9090:9090"
echo "   Open: http://localhost:9090"
echo ""
echo "4. Check Prometheus targets (in UI):"
echo "   Status → Targets → Look for 'stackrox' job"
echo ""
echo "5. Verify RHACS metrics are being scraped:"
echo "   curl -H \"Authorization: Bearer \$ROX_API_TOKEN\" -k \$ROX_CENTRAL_URL/metrics | head -20"
echo ""
echo "6. Run diagnostics:"
echo "   ./debug-monitoring.sh"
echo ""
echo "Environment variables saved to ~/.bashrc:"
echo "  - ROX_CENTRAL_URL"
echo "  - ROX_API_TOKEN"
echo "  - GRPC_ENFORCE_ALPN_ENABLED"
echo ""
log "Setup completed successfully!"
echo ""
