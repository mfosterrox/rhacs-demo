#!/bin/bash
#
# RHACS Monitoring Reset Script
# Removes all monitoring resources created by install.sh
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
error() { echo -e "${RED}[ERROR]${NC} $1"; }
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
step "RHACS Monitoring Cleanup"
echo "=========================================="
echo "This will remove all monitoring resources from namespace: $NAMESPACE"
echo "=========================================="
echo ""

# Confirm with user
read -p "Are you sure you want to proceed? (yes/no): " -r
echo
if [[ ! $REPLY =~ ^[Yy]es$ ]]; then
    log "Cleanup cancelled."
    exit 0
fi

echo ""

#================================================================
# 1. Remove Perses Resources
#================================================================
step "Step 1: Removing Perses resources"
echo ""

# Perses Dashboard
if $KUBE_CMD get persesdashboard rhacs-central-dashboard -n "$NAMESPACE" &>/dev/null; then
    log "Deleting Perses Dashboard..."
    $KUBE_CMD delete persesdashboard rhacs-central-dashboard -n "$NAMESPACE" || warning "Failed to delete dashboard"
    log "✓ Perses Dashboard deleted"
else
    log "✓ Perses Dashboard not found (already removed or never created)"
fi

# Perses Datasource
if $KUBE_CMD get persesdatasource prometheus -n "$NAMESPACE" &>/dev/null; then
    log "Deleting Perses Datasource..."
    $KUBE_CMD delete persesdatasource prometheus -n "$NAMESPACE" || warning "Failed to delete datasource"
    log "✓ Perses Datasource deleted"
else
    log "✓ Perses Datasource not found (already removed or never created)"
fi

# Perses UI Plugin (cluster-scoped)
if $KUBE_CMD get console.openshift.io plugin perses-plugin &>/dev/null 2>&1; then
    log "Deleting Perses UI Plugin (cluster-scoped)..."
    $KUBE_CMD delete -f "$EXAMPLES_DIR/perses/ui-plugin.yaml" 2>/dev/null || warning "Failed to delete UI plugin"
    log "✓ Perses UI Plugin deleted"
else
    log "✓ Perses UI Plugin not found (already removed or never created)"
fi

echo ""

#================================================================
# 2. Remove ScrapeConfig
#================================================================
step "Step 2: Removing ScrapeConfig"
echo ""

if $KUBE_CMD get scrapeconfig -n "$NAMESPACE" &>/dev/null 2>&1; then
    SCRAPE_CONFIGS=$($KUBE_CMD get scrapeconfig -n "$NAMESPACE" -o name 2>/dev/null || echo "")
    if [ -n "$SCRAPE_CONFIGS" ]; then
        log "Deleting ScrapeConfigs..."
        echo "$SCRAPE_CONFIGS" | while read -r sc; do
            log "  Deleting $sc"
            $KUBE_CMD delete "$sc" -n "$NAMESPACE" || warning "Failed to delete $sc"
        done
        log "✓ ScrapeConfigs deleted"
    else
        log "✓ No ScrapeConfigs found"
    fi
else
    log "✓ ScrapeConfig CRD not found (Cluster Observability Operator may not be installed)"
fi

echo ""

#================================================================
# 3. Remove MonitoringStack
#================================================================
step "Step 3: Removing MonitoringStack"
echo ""

if $KUBE_CMD get monitoringstack -n "$NAMESPACE" &>/dev/null 2>&1; then
    STACKS=$($KUBE_CMD get monitoringstack -n "$NAMESPACE" -o name 2>/dev/null || echo "")
    if [ -n "$STACKS" ]; then
        log "Deleting MonitoringStack instances..."
        echo "$STACKS" | while read -r stack; do
            log "  Deleting $stack"
            $KUBE_CMD delete "$stack" -n "$NAMESPACE" || warning "Failed to delete $stack"
        done
        log "Waiting for Prometheus pods to terminate..."
        sleep 10
        log "✓ MonitoringStack deleted"
    else
        log "✓ No MonitoringStack instances found"
    fi
else
    log "✓ MonitoringStack CRD not found (Cluster Observability Operator may not be installed)"
fi

echo ""

#================================================================
# 4. Remove Secrets
#================================================================
step "Step 4: Removing monitoring secrets"
echo ""

# TLS secret
SECRET_NAME="sample-$NAMESPACE-prometheus-tls"
if $KUBE_CMD get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Deleting TLS secret: $SECRET_NAME"
    $KUBE_CMD delete secret "$SECRET_NAME" -n "$NAMESPACE" || warning "Failed to delete secret"
    log "✓ TLS secret deleted"
else
    log "✓ TLS secret not found (already removed or never created)"
fi

# API token secret
TOKEN_SECRET_NAME="$NAMESPACE-prometheus-api-token"
if $KUBE_CMD get secret "$TOKEN_SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
    log "Deleting API token secret: $TOKEN_SECRET_NAME"
    $KUBE_CMD delete secret "$TOKEN_SECRET_NAME" -n "$NAMESPACE" || warning "Failed to delete secret"
    log "✓ API token secret deleted"
else
    log "✓ API token secret not found (already removed or never created)"
fi

echo ""

#================================================================
# 5. Remove RHACS Declarative Configuration
#================================================================
step "Step 5: Removing RHACS declarative configuration"
echo ""

if $KUBE_CMD get configmap stackrox-declarative-configuration -n "$NAMESPACE" &>/dev/null; then
    log "Deleting declarative configuration ConfigMap..."
    $KUBE_CMD delete configmap stackrox-declarative-configuration -n "$NAMESPACE" || warning "Failed to delete ConfigMap"
    log "✓ Declarative configuration deleted"
else
    log "✓ Declarative configuration ConfigMap not found (already removed or never created)"
fi

echo ""

#================================================================
# 6. Remove Auth Provider (optional, requires API access)
#================================================================
step "Step 6: Removing User-Certificate auth provider"
echo ""

if [ -n "${ROX_CENTRAL_URL:-}" ] && [ -n "${ROX_API_TOKEN:-}" ]; then
    log "Searching for 'Monitoring' auth provider..."
    
    # Get list of auth providers
    AUTH_PROVIDERS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
        "$ROX_CENTRAL_URL/v1/authProviders" 2>/dev/null || echo "")
    
    if echo "$AUTH_PROVIDERS" | grep -q '"name":"Monitoring"'; then
        PROVIDER_ID=$(echo "$AUTH_PROVIDERS" | jq -r '.authProviders[] | select(.name=="Monitoring") | .id' 2>/dev/null || echo "")
        
        if [ -n "$PROVIDER_ID" ]; then
            log "Found auth provider 'Monitoring' (ID: $PROVIDER_ID)"
            log "Deleting auth provider..."
            
            DELETE_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X DELETE \
                -H "Authorization: Bearer $ROX_API_TOKEN" \
                "$ROX_CENTRAL_URL/v1/authProviders/$PROVIDER_ID" 2>&1)
            
            HTTP_CODE=$(echo "$DELETE_RESPONSE" | tail -1)
            if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
                log "✓ Auth provider deleted"
            else
                warning "Failed to delete auth provider (HTTP $HTTP_CODE)"
                warning "You may need to delete it manually in RHACS UI:"
                warning "  Platform Configuration → Access Control → Auth Providers"
            fi
        else
            log "✓ Auth provider 'Monitoring' not found"
        fi
    else
        log "✓ Auth provider 'Monitoring' not found"
    fi
else
    warning "ROX_CENTRAL_URL or ROX_API_TOKEN not set"
    warning "Skipping auth provider deletion"
    warning "You may need to delete it manually in RHACS UI:"
    warning "  Platform Configuration → Access Control → Auth Providers → Delete 'Monitoring'"
fi

echo ""

#================================================================
# 7. Clean up local files
#================================================================
step "Step 7: Cleaning up local certificate files"
echo ""

cd "$SCRIPT_DIR"

if [ -f "tls.crt" ]; then
    log "Removing tls.crt..."
    rm -f tls.crt
    log "✓ tls.crt removed"
else
    log "✓ tls.crt not found"
fi

if [ -f "tls.key" ]; then
    log "Removing tls.key..."
    rm -f tls.key
    log "✓ tls.key removed"
else
    log "✓ tls.key not found"
fi

echo ""

#================================================================
# 8. Optional: Remove Cluster Observability Operator
#================================================================
step "Step 8: Cluster Observability Operator (optional)"
echo ""

warning "The Cluster Observability Operator is still installed."
warning "This is intentional as it may be used by other monitoring stacks."
echo ""
warning "To COMPLETELY remove the operator (if you're sure), run:"
echo ""
echo "  oc delete -f $EXAMPLES_DIR/cluster-observability-operator/subscription.yaml"
echo "  oc delete namespace openshift-cluster-observability-operator"
echo ""
log "Operator will continue running but will not manage any resources in $NAMESPACE"

echo ""

#================================================================
# Summary
#================================================================
step "Cleanup Complete!"
echo "=========================================="
echo ""
echo "✓ Perses resources removed"
echo "✓ ScrapeConfig removed"
echo "✓ MonitoringStack removed"
echo "✓ Secrets removed"
echo "✓ Declarative configuration removed"
echo "✓ Local certificate files removed"
echo ""
echo "⚠️  Cluster Observability Operator still installed (see above to remove)"
echo ""
echo "Namespace '$NAMESPACE' is now clean of monitoring resources."
echo ""
echo "To reinstall monitoring, run:"
echo "  cd $SCRIPT_DIR"
echo "  ./install.sh"
echo ""
log "Reset completed successfully!"
echo ""
