#!/bin/bash
#
# RHACS Monitoring Setup - Monitoring Stack Installation
# Installs Cluster Observability Operator, monitoring stack, and Perses dashboards
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

step "Monitoring Stack Installation"
echo "=========================================="
echo ""

# Ensure we're in the stackrox namespace
log "Switching to stackrox namespace..."
oc project stackrox

# Per RHACS 4.10 docs 15.2.1: Disable OpenShift monitoring when using custom Prometheus
# https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.10/html/configuring/monitor-acs
CENTRAL_CR=$(oc get central -n stackrox -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$CENTRAL_CR" ]; then
  log "Disabling OpenShift monitoring on Central (required for custom Prometheus)..."
  if oc patch central "$CENTRAL_CR" -n stackrox --type=merge -p='{"spec":{"monitoring":{"openshift":{"enabled":false}}}}' 2>/dev/null; then
    log "✓ OpenShift monitoring disabled"
  elif oc patch central "$CENTRAL_CR" -n stackrox --type=merge -p='{"spec":{"central":{"monitoring":{"openshift":{"enabled":false}}}}}' 2>/dev/null; then
    log "✓ OpenShift monitoring disabled"
  else
    warn "Could not patch Central CR - ensure monitoring.openshift.enabled: false is set manually"
  fi
else
  warn "Central CR not found - skip disabling OpenShift monitoring (Helm/other install)"
fi

echo ""
log "Installing Cluster Observability Operator..."
oc apply -f monitoring-examples/cluster-observability-operator/subscription.yaml
log "✓ Cluster Observability Operator subscription created"

echo ""
log "Installing and configuring monitoring stack instance..."
MONITORING_STACK_YAML="monitoring-examples/cluster-observability-operator/monitoring-stack.yaml"
max_wait=300
elapsed=0
while [ $elapsed -lt $max_wait ]; do
  if out=$(oc apply -f "$MONITORING_STACK_YAML" 2>&1); then
    echo "$out"
    log "✓ MonitoringStack created"
    break
  fi
  if echo "$out" | grep -qE "no matches for kind \"MonitoringStack\"|ensure CRDs are installed first"; then
    log "  Waiting for operator CRDs... (${elapsed}s/${max_wait}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  else
    echo "$out" >&2
    exit 1
  fi
done
if [ $elapsed -ge $max_wait ]; then
  error "MonitoringStack apply failed after ${max_wait}s - operator may not be ready"
  exit 1
fi

oc apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml
log "✓ ScrapeConfig created"

echo ""
log "Installing Prometheus Operator resources (for clusters with Prometheus Operator)..."
if oc get crd prometheuses.monitoring.coreos.com &>/dev/null; then
  oc apply -f monitoring-examples/prometheus-operator/
  log "✓ Prometheus Operator resources applied"
else
  log "Prometheus Operator CRD not found - skipping"
fi

echo ""
log "Installing Perses and configuring the RHACS dashboard..."
oc apply -f monitoring-examples/perses/ui-plugin.yaml
log "✓ Perses UI Plugin created"

oc apply -f monitoring-examples/perses/datasource.yaml
log "✓ Perses Datasource created"

oc apply -f monitoring-examples/perses/dashboard.yaml
log "✓ Perses Dashboard created"

echo ""
log "✓ Monitoring stack installation complete"
echo ""
