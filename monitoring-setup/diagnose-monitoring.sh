#!/bin/bash

# Script: diagnose-monitoring.sh
# Description: Diagnose RHACS monitoring issues

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Print functions
print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

echo "========================================================================"
echo "RHACS Monitoring Diagnostics"
echo "========================================================================"
echo ""

#================================================================
# Step 1: Check MonitoringStack exists
#================================================================
print_step "1. Checking MonitoringStack"
echo "----------------------------------------------------------------"

if oc get monitoringstack sample-stackrox-monitoring-stack -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "MonitoringStack exists"
    oc get monitoringstack sample-stackrox-monitoring-stack -n ${RHACS_NAMESPACE}
else
    print_fail "MonitoringStack not found"
    echo "Create it with: bash 04-deploy-monitoring-stack.sh"
    exit 1
fi

echo ""

#================================================================
# Step 2: Check Prometheus pods
#================================================================
print_step "2. Checking Prometheus pods"
echo "----------------------------------------------------------------"

PROM_PODS=$(oc get pods -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=prometheus --no-headers 2>/dev/null || echo "")

if [ -z "${PROM_PODS}" ]; then
    print_fail "No Prometheus pods found"
    echo "Expected: Prometheus pod created by MonitoringStack"
else
    print_pass "Prometheus pods found:"
    oc get pods -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=prometheus
fi

echo ""

#================================================================
# Step 3: Check service account and token
#================================================================
print_step "3. Checking service account and token"
echo "----------------------------------------------------------------"

if oc get sa sample-stackrox-prometheus -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "ServiceAccount exists"
else
    print_fail "ServiceAccount not found"
fi

if oc get secret sample-stackrox-prometheus-tls -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "TLS secret exists"
    
    # Check if token has data
    TOKEN=$(oc get secret sample-stackrox-prometheus-tls -n ${RHACS_NAMESPACE} -o jsonpath='{.data.token}' 2>/dev/null || echo "")
    if [ -n "${TOKEN}" ]; then
        print_pass "TLS secret has token data"
    else
        print_fail "TLS secret token is empty"
    fi
else
    print_fail "TLS secret not found"
fi

echo ""

#================================================================
# Step 4: Check RHACS Central is accessible
#================================================================
print_step "4. Checking RHACS Central service"
echo "----------------------------------------------------------------"

if oc get svc central -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "Central service exists"
    CENTRAL_IP=$(oc get svc central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.clusterIP}')
    echo "  ClusterIP: ${CENTRAL_IP}"
else
    print_fail "Central service not found"
fi

if oc get deployment central -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    CENTRAL_READY=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [ "${CENTRAL_READY}" -gt 0 ]; then
        print_pass "Central deployment is ready (${CENTRAL_READY} replicas)"
    else
        print_fail "Central deployment has 0 ready replicas"
    fi
else
    print_fail "Central deployment not found"
fi

echo ""

#================================================================
# Step 5: Test metrics endpoint with token
#================================================================
print_step "5. Testing RHACS metrics endpoint"
echo "----------------------------------------------------------------"

if [ -n "${TOKEN:-}" ]; then
    DECODED_TOKEN=$(echo "${TOKEN}" | base64 -d)
    CENTRAL_URL="https://central.${RHACS_NAMESPACE}.svc.cluster.local:443"
    
    print_info "Testing: ${CENTRAL_URL}/metrics"
    
    # Create a test pod to check connectivity
    print_info "Creating test pod to check metrics endpoint..."
    
    cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: metrics-test
  namespace: ${RHACS_NAMESPACE}
spec:
  containers:
  - name: curl
    image: registry.access.redhat.com/ubi9/ubi-minimal:latest
    command: ['sleep', '3600']
  restartPolicy: Never
EOF
    
    sleep 5
    
    # Wait for pod to be ready
    oc wait --for=condition=Ready pod/metrics-test -n ${RHACS_NAMESPACE} --timeout=30s >/dev/null 2>&1 || true
    
    # Test the metrics endpoint
    METRICS_TEST=$(oc exec -n ${RHACS_NAMESPACE} metrics-test -- curl -k -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${DECODED_TOKEN}" "${CENTRAL_URL}/metrics" 2>/dev/null || echo "000")
    
    if [ "${METRICS_TEST}" = "200" ]; then
        print_pass "Metrics endpoint accessible (HTTP ${METRICS_TEST})"
        
        # Get sample metrics
        print_info "Sample metrics:"
        oc exec -n ${RHACS_NAMESPACE} metrics-test -- curl -k -s -H "Authorization: Bearer ${DECODED_TOKEN}" "${CENTRAL_URL}/metrics" 2>/dev/null | grep "rox_central" | head -5
    else
        print_fail "Metrics endpoint returned HTTP ${METRICS_TEST}"
    fi
    
    # Cleanup test pod
    oc delete pod metrics-test -n ${RHACS_NAMESPACE} --ignore-not-found=true >/dev/null 2>&1 &
else
    print_warn "Skipping - no token available"
fi

echo ""

#================================================================
# Step 6: Check ScrapeConfig
#================================================================
print_step "6. Checking ScrapeConfig"
echo "----------------------------------------------------------------"

if oc get scrapeconfig sample-stackrox-scrape-config -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "ScrapeConfig exists"
    echo ""
    echo "ScrapeConfig details:"
    oc get scrapeconfig sample-stackrox-scrape-config -n ${RHACS_NAMESPACE} -o yaml | grep -A 10 "spec:"
else
    print_fail "ScrapeConfig not found"
fi

echo ""

#================================================================
# Step 7: Check Prometheus configuration
#================================================================
print_step "7. Checking Prometheus configuration"
echo "----------------------------------------------------------------"

PROM_POD=$(oc get pods -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "${PROM_POD}" ]; then
    print_info "Prometheus pod: ${PROM_POD}"
    
    # Check if Prometheus can see the target
    print_info "Checking Prometheus targets..."
    
    # Port-forward in background
    oc port-forward -n ${RHACS_NAMESPACE} ${PROM_POD} 9090:9090 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3
    
    # Query targets
    TARGETS=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null | jq -r '.data.activeTargets[] | select(.labels.job=="sample-stackrox-metrics") | .health' 2>/dev/null || echo "")
    
    if [ "${TARGETS}" = "up" ]; then
        print_pass "Prometheus target is UP"
    elif [ "${TARGETS}" = "down" ]; then
        print_fail "Prometheus target is DOWN"
        curl -s http://localhost:9090/api/v1/targets 2>/dev/null | jq '.data.activeTargets[] | select(.labels.job=="sample-stackrox-metrics")' 2>/dev/null || true
    else
        print_warn "Could not check target status (may need port-forward)"
    fi
    
    # Check for RHACS metrics
    print_info "Checking for RHACS metrics in Prometheus..."
    METRIC_COUNT=$(curl -s http://localhost:9090/api/v1/label/__name__/values 2>/dev/null | jq -r '.data[] | select(startswith("rox_central"))' 2>/dev/null | wc -l | tr -d ' ')
    
    if [ "${METRIC_COUNT}" -gt 0 ]; then
        print_pass "Found ${METRIC_COUNT} RHACS metrics in Prometheus"
        echo "  Sample metrics:"
        curl -s http://localhost:9090/api/v1/label/__name__/values 2>/dev/null | jq -r '.data[] | select(startswith("rox_central"))' 2>/dev/null | head -5 | sed 's/^/    /'
    else
        print_fail "No RHACS metrics found in Prometheus"
    fi
    
    # Kill port-forward
    kill ${PF_PID} 2>/dev/null || true
else
    print_warn "No Prometheus pod found to check"
fi

echo ""

#================================================================
# Step 8: Check RHACS metrics configuration
#================================================================
print_step "8. Checking RHACS metrics configuration"
echo "----------------------------------------------------------------"

print_info "Checking if RHACS metrics are configured..."

if [ -z "${ROX_API_TOKEN:-}" ]; then
    print_warn "ROX_API_TOKEN not set - skipping RHACS config check"
    echo "  Export ROX_API_TOKEN to check RHACS metrics configuration"
else
    CENTRAL_ROUTE=$(oc get route central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${CENTRAL_ROUTE}" ]; then
        METRICS_CONFIG=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "https://${CENTRAL_ROUTE}/v1/config" 2>/dev/null | jq -r '.privateConfig.metrics.imageVulnerabilities.gatheringPeriodMinutes' 2>/dev/null || echo "")
        
        if [ -n "${METRICS_CONFIG}" ] && [ "${METRICS_CONFIG}" != "null" ]; then
            print_pass "RHACS metrics are configured (gathering period: ${METRICS_CONFIG} minutes)"
        else
            print_fail "RHACS metrics may not be configured"
            echo "  Run: bash 03-configure-rhacs-metrics.sh"
        fi
    fi
fi

echo ""

#================================================================
# Step 9: Check Perses resources
#================================================================
print_step "9. Checking Perses dashboard resources"
echo "----------------------------------------------------------------"

if oc get persesdashboard sample-stackrox-dashboard -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "Perses dashboard exists"
else
    print_fail "Perses dashboard not found"
fi

if oc get persesdatasource sample-stackrox-datasource -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
    print_pass "Perses datasource exists"
    echo ""
    echo "Datasource configuration:"
    oc get persesdatasource sample-stackrox-datasource -n ${RHACS_NAMESPACE} -o yaml | grep -A 5 "url:"
else
    print_fail "Perses datasource not found"
fi

echo ""

#================================================================
# Summary
#================================================================
print_step "Summary & Next Steps"
echo "----------------------------------------------------------------"

echo ""
echo "Quick checks you can run:"
echo ""
echo "1. Check Prometheus targets:"
echo "   oc port-forward -n ${RHACS_NAMESPACE} \$(oc get pods -n ${RHACS_NAMESPACE} -l app.kubernetes.io/name=prometheus -o name | head -1) 9090:9090"
echo "   # Open http://localhost:9090/targets"
echo ""
echo "2. Query metrics directly:"
echo "   # In browser: http://localhost:9090/graph"
echo "   # Query: rox_central_cfg_total_policies"
echo ""
echo "3. Check RHACS metrics endpoint:"
echo "   SA_TOKEN=\$(oc get secret sample-stackrox-prometheus-tls -n ${RHACS_NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)"
echo "   oc run test --rm -i --restart=Never --image=registry.access.redhat.com/ubi9/ubi-minimal -- \\"
echo "     curl -k -H \"Authorization: Bearer \${SA_TOKEN}\" https://central.${RHACS_NAMESPACE}.svc:443/metrics | head -20"
echo ""
echo "4. Check MonitoringStack status:"
echo "   oc get monitoringstack -n ${RHACS_NAMESPACE} -o yaml"
echo ""

echo "========================================================================"
