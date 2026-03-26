#!/bin/bash
#
# RHACS Monitoring Setup - Monitoring Stack Installation
# Installs Cluster Observability Operator, monitoring stack, and Perses dashboards
#
# After MonitoringStack + ScrapeConfig apply, verifies:
#   - both CRs exist (ScrapeConfig re-applied once if missing)
#   - Prometheus StatefulSet <MonitoringStack.name>-prometheus exists and rollout completes
#   - on failure, re-applies stack + scrape YAML once then waits again (mitigates first-run races)
#
# Optional env:
#   RHACS_NS / MONITORING_STACK_NAME / SCRAPE_CONFIG_NAME / PROMETHEUS_STS_NAME — override defaults if you renamed CRs
#   COO_PROMETHEUS_WAIT_SEC — max seconds to wait for operator to create Prometheus STS (default 300)
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

RHACS_NS="${RHACS_NS:-stackrox}"
MONITORING_STACK_NAME="${MONITORING_STACK_NAME:-sample-stackrox-monitoring-stack}"
SCRAPE_CONFIG_NAME="${SCRAPE_CONFIG_NAME:-sample-stackrox-scrape-config}"
# COO creates Prometheus as StatefulSet named <MonitoringStack.metadata.name>-prometheus
PROMETHEUS_STS_NAME="${PROMETHEUS_STS_NAME:-${MONITORING_STACK_NAME}-prometheus}"
MONITORING_STACK_YAML="monitoring-examples/cluster-observability-operator/monitoring-stack.yaml"
SCRAPE_CONFIG_YAML="monitoring-examples/cluster-observability-operator/scrape-config.yaml"

# Wait for operator to create the Prometheus StatefulSet, then wait for rollout.
# Optional second attempt: re-apply stack + scrape YAML if the first wait times out (first-run races).
wait_for_coo_prometheus_ready() {
  local attempt_label="$1"
  local max_wait="${COO_PROMETHEUS_WAIT_SEC:-300}"
  local elapsed=0
  local step_wait=10

  while [ "${elapsed}" -lt "${max_wait}" ]; do
    if oc get "statefulset/${PROMETHEUS_STS_NAME}" -n "${RHACS_NS}" &>/dev/null; then
      log "✓ Prometheus StatefulSet ${PROMETHEUS_STS_NAME} exists (${attempt_label})"
      if oc rollout status "statefulset/${PROMETHEUS_STS_NAME}" -n "${RHACS_NS}" --timeout=240s; then
        log "✓ Prometheus rollout complete (${PROMETHEUS_STS_NAME})"
        return 0
      fi
      warn "rollout status failed for ${PROMETHEUS_STS_NAME} — will not retry rollout here"
      return 1
    fi
    log "  Waiting for operator to create ${PROMETHEUS_STS_NAME}... (${elapsed}s/${max_wait}s)"
    sleep "${step_wait}"
    elapsed=$((elapsed + step_wait))
  done
  return 1
}

verify_scrape_config_present() {
  if oc get scrapeconfig "${SCRAPE_CONFIG_NAME}" -n "${RHACS_NS}" &>/dev/null; then
    log "✓ ScrapeConfig ${SCRAPE_CONFIG_NAME} present in ${RHACS_NS}"
    return 0
  fi
  return 1
}

verify_monitoring_stack_cr() {
  if oc get monitoringstack "${MONITORING_STACK_NAME}" -n "${RHACS_NS}" &>/dev/null; then
    log "✓ MonitoringStack CR ${MONITORING_STACK_NAME} present in ${RHACS_NS}"
    return 0
  fi
  return 1
}

# After applies: confirm CRs exist, Prometheus is ready; optionally re-apply once on failure.
verify_and_finalize_coo_stack() {
  echo ""
  step "Verifying Cluster Observability stack (MonitoringStack / ScrapeConfig / Prometheus)"
  echo ""

  if ! verify_monitoring_stack_cr; then
    error "MonitoringStack CR missing — apply may have failed silently"
    return 1
  fi

  if ! verify_scrape_config_present; then
    warn "ScrapeConfig not found — re-applying ${SCRAPE_CONFIG_YAML}..."
    oc apply -f "${SCRAPE_CONFIG_YAML}"
    sleep 5
    if ! verify_scrape_config_present; then
      error "ScrapeConfig ${SCRAPE_CONFIG_NAME} still missing after re-apply"
      return 1
    fi
  fi

  if wait_for_coo_prometheus_ready "attempt 1"; then
    return 0
  fi

  warn "Prometheus StatefulSet not ready on first wait — re-applying stack + scrape, then retrying..."
  oc apply -f "${MONITORING_STACK_YAML}"
  oc apply -f "${SCRAPE_CONFIG_YAML}"
  sleep 15

  if wait_for_coo_prometheus_ready "attempt 2 (after re-apply)"; then
    return 0
  fi

  error "Prometheus (${PROMETHEUS_STS_NAME}) did not become ready — check: oc describe monitoringstack ${MONITORING_STACK_NAME} -n ${RHACS_NS}; oc get pods -n ${RHACS_NS} -l app.kubernetes.io/name=prometheus"
  return 1
}

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
max_wait=300
elapsed=0
while [ $elapsed -lt $max_wait ]; do
  if out=$(oc apply -f "$MONITORING_STACK_YAML" 2>&1); then
    echo "$out"
    log "✓ MonitoringStack applied"
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

if out=$(oc apply -f "$SCRAPE_CONFIG_YAML" 2>&1); then
  echo "$out"
  log "✓ ScrapeConfig applied"
else
  echo "$out" >&2
  error "ScrapeConfig apply failed"
  exit 1
fi

if ! verify_and_finalize_coo_stack; then
  exit 1
fi

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

# Perses operator conversion webhook may not be ready on first run - retry if creation fails
log "Creating Perses Dashboard..."
DASHBOARD_YAML="monitoring-examples/perses/dashboard.yaml"
max_retries=4
retry_delay=30
for attempt in $(seq 1 $max_retries); do
  if out=$(oc apply -f "$DASHBOARD_YAML" 2>&1); then
    echo "$out"
    log "✓ Perses Dashboard created"
    break
  fi
  echo "$out" >&2
  if [ $attempt -lt $max_retries ] && echo "$out" | grep -qE "perses-operator-conversion-webhook|conversion webhook.*failed"; then
    warn "Perses operator webhook not ready yet - waiting ${retry_delay}s before retry (attempt $attempt/$max_retries)..."
    sleep $retry_delay
  else
    error "Perses Dashboard creation failed"
    exit 1
  fi
done

echo ""
log "✓ Monitoring stack installation complete"
echo ""