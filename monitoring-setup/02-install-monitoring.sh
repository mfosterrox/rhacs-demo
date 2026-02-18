#!/bin/bash
#
# RHACS Monitoring Setup - Monitoring Stack Installation
# Installs Cluster Observability Operator, monitoring stack, and Perses dashboards
#

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
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

echo ""
log "Installing Cluster Observability Operator..."
oc apply -f monitoring-examples/cluster-observability-operator/subscription.yaml
log "✓ Cluster Observability Operator subscription created"

echo ""
log "Installing and configuring monitoring stack instance..."
oc apply -f monitoring-examples/cluster-observability-operator/monitoring-stack.yaml
log "✓ MonitoringStack created"

oc apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml
log "✓ ScrapeConfig created"

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
