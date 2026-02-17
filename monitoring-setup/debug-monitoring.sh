#!/bin/bash
#
# RHACS Monitoring Debug Script
# Validates certificates, checks monitoring stack status, and diagnoses issues
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
step() { echo -e "${BLUE}[====]${NC} $1"; }

NAMESPACE="${NAMESPACE:-stackrox}"
KUBE_CMD="oc"

if ! command -v oc &>/dev/null; then
    KUBE_CMD="kubectl"
fi

echo ""
step "RHACS Monitoring Stack Diagnostics"
echo "=========================================="
echo ""

#================================================================
# 1. Environment Variables Check
#================================================================
step "1. Environment Variables"
echo ""

if [ -n "${ROX_CENTRAL_URL:-}" ]; then
    log "✓ ROX_CENTRAL_URL: $ROX_CENTRAL_URL"
else
    error "✗ ROX_CENTRAL_URL not set"
fi

if [ -n "${ROX_API_TOKEN:-}" ]; then
    log "✓ ROX_API_TOKEN: ${ROX_API_TOKEN:0:30}... (${#ROX_API_TOKEN} chars)"
else
    error "✗ ROX_API_TOKEN not set"
fi

if [ -n "${GRPC_ENFORCE_ALPN_ENABLED:-}" ]; then
    log "✓ GRPC_ENFORCE_ALPN_ENABLED: $GRPC_ENFORCE_ALPN_ENABLED"
else
    warning "✗ GRPC_ENFORCE_ALPN_ENABLED not set (needed for roxctl)"
    log "  Setting it now: export GRPC_ENFORCE_ALPN_ENABLED=false"
    export GRPC_ENFORCE_ALPN_ENABLED=false
fi

#================================================================
# 2. Certificate Validation
#================================================================
echo ""
step "2. Certificate Validation"
echo ""

if [ -f "tls.crt" ]; then
    log "✓ Certificate file exists: tls.crt"
    
    # Check if certificate is valid (not expired)
    log "Checking certificate validity..."
    CERT_NOT_BEFORE=$(openssl x509 -in tls.crt -noout -startdate | cut -d= -f2)
    CERT_NOT_AFTER=$(openssl x509 -in tls.crt -noout -enddate | cut -d= -f2)
    CERT_CN=$(openssl x509 -in tls.crt -noout -subject | sed -n 's/.*CN=\([^,]*\).*/\1/p')
    CERT_ISSUER=$(openssl x509 -in tls.crt -noout -issuer | sed -n 's/.*CN=\([^,]*\).*/\1/p')
    
    log "  Subject (CN): $CERT_CN"
    log "  Issuer: $CERT_ISSUER"
    log "  Valid From: $CERT_NOT_BEFORE"
    log "  Valid Until: $CERT_NOT_AFTER"
    
    # Check if certificate is currently valid
    if openssl x509 -in tls.crt -noout -checkend 0 2>/dev/null; then
        log "  ✓ Certificate is currently valid"
    else
        error "  ✗ Certificate has expired!"
    fi
    
    # Show certificate details
    log ""
    log "Certificate details:"
    openssl x509 -in tls.crt -text -noout | grep -A3 "Subject:\|Issuer:\|Validity"
    
else
    error "✗ Certificate file not found: tls.crt"
    warning "Generate with: openssl req -x509 -newkey rsa:2048 -nodes -days 365 \\"
    warning "  -subj \"/CN=sample-$NAMESPACE-monitoring-stack-prometheus.$NAMESPACE.svc\" \\"
    warning "  -keyout tls.key -out tls.crt"
fi

if [ -f "tls.key" ]; then
    log "✓ Private key file exists: tls.key"
else
    error "✗ Private key file not found: tls.key"
fi

#================================================================
# 3. RHACS API Connectivity
#================================================================
echo ""
step "3. RHACS API Connectivity"
echo ""

if [ -n "${ROX_CENTRAL_URL:-}" ] && [ -n "${ROX_API_TOKEN:-}" ]; then
    log "Testing: curl -H 'Authorization: Bearer \$ROX_API_TOKEN' -k \$ROX_CENTRAL_URL/v1/auth/status"
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
    
    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ API token authentication WORKING (HTTP $HTTP_CODE)"
        AUTH_RESPONSE=$(curl -s -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
        USER_ID=$(echo "$AUTH_RESPONSE" | grep -o '"userId":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        ROLES=$(echo "$AUTH_RESPONSE" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4 || echo "unknown")
        log "  User ID: $USER_ID"
        log "  Role: $ROLES"
    else
        error "✗ API token authentication FAILED (HTTP $HTTP_CODE)"
    fi
    
    # Test metrics endpoint
    log ""
    log "Testing metrics endpoint..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/metrics" 2>&1)
    
    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ Metrics endpoint accessible (HTTP $HTTP_CODE)"
        METRIC_COUNT=$(curl -s -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/metrics" 2>&1 | grep -c "^rox_" || echo "0")
        log "  Found $METRIC_COUNT RHACS metrics"
    else
        error "✗ Metrics endpoint not accessible (HTTP $HTTP_CODE)"
    fi
fi

# Test certificate authentication
if [ -f "tls.crt" ] && [ -f "tls.key" ] && [ -n "${ROX_CENTRAL_URL:-}" ]; then
    echo ""
    log "Testing certificate authentication..."
    log "Testing: curl --cert tls.crt --key tls.key -k \$ROX_CENTRAL_URL/v1/auth/status"
    
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --cert tls.crt --key tls.key -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
    
    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ Certificate authentication WORKING (HTTP $HTTP_CODE)"
        CERT_AUTH_RESPONSE=$(curl -s --cert tls.crt --key tls.key -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
        USER_ID=$(echo "$CERT_AUTH_RESPONSE" | grep -o '"userId":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
        log "  User ID: $USER_ID"
    else
        warning "✗ Certificate authentication NOT CONFIGURED (HTTP $HTTP_CODE)"
        warning "  This is optional - API token auth is sufficient"
    fi
fi

#================================================================
# 4. Kubernetes Secrets
#================================================================
echo ""
step "4. Kubernetes Secrets in namespace '$NAMESPACE'"
echo ""

# Check TLS secret
if $KUBE_CMD get secret sample-$NAMESPACE-prometheus-tls -n "$NAMESPACE" &>/dev/null; then
    log "✓ TLS secret exists: sample-$NAMESPACE-prometheus-tls"
    $KUBE_CMD get secret sample-$NAMESPACE-prometheus-tls -n "$NAMESPACE" -o jsonpath='{.data}' | jq 'keys'
else
    error "✗ TLS secret not found: sample-$NAMESPACE-prometheus-tls"
fi

# Check API token secret
if $KUBE_CMD get secret $NAMESPACE-prometheus-api-token -n "$NAMESPACE" &>/dev/null; then
    log "✓ API token secret exists: $NAMESPACE-prometheus-api-token"
else
    warning "✗ API token secret not found: $NAMESPACE-prometheus-api-token"
fi

# Check service-ca secret (needed for TLS)
if $KUBE_CMD get secret service-ca -n "$NAMESPACE" &>/dev/null; then
    log "✓ Service CA secret exists: service-ca"
else
    warning "✗ Service CA secret not found: service-ca"
    warning "  This is needed for Prometheus to trust RHACS Central"
fi

#================================================================
# 5. Cluster Observability Operator
#================================================================
echo ""
step "5. Cluster Observability Operator Status"
echo ""

if $KUBE_CMD get namespace openshift-cluster-observability-operator &>/dev/null; then
    log "✓ Operator namespace exists"
    
    # Check CSV
    CSV=$($KUBE_CMD get csv -n openshift-cluster-observability-operator -o name 2>/dev/null | grep cluster-observability-operator | head -1 || echo "")
    if [ -n "$CSV" ]; then
        CSV_NAME=$(echo "$CSV" | sed 's|clusterserviceversion.operators.coreos.com/||')
        CSV_PHASE=$($KUBE_CMD get "$CSV" -n openshift-cluster-observability-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        log "✓ CSV: $CSV_NAME"
        log "  Phase: $CSV_PHASE"
    else
        error "✗ CSV not found"
    fi
    
    # Check operator pods
    OPERATOR_PODS=$($KUBE_CMD get pods -n openshift-cluster-observability-operator -o name 2>/dev/null | wc -l)
    log "  Operator pods: $OPERATOR_PODS"
else
    error "✗ Cluster Observability Operator not installed"
fi

#================================================================
# 6. MonitoringStack Status
#================================================================
echo ""
step "6. MonitoringStack Status in namespace '$NAMESPACE'"
echo ""

if $KUBE_CMD get monitoringstack -n "$NAMESPACE" &>/dev/null; then
    STACK_COUNT=$($KUBE_CMD get monitoringstack -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    log "✓ MonitoringStack resources: $STACK_COUNT"
    
    $KUBE_CMD get monitoringstack -n "$NAMESPACE" -o custom-columns=NAME:.metadata.name,PHASE:.status.conditions[0].type,STATUS:.status.conditions[0].status 2>/dev/null || true
    
    # Check conditions
    echo ""
    log "MonitoringStack conditions:"
    $KUBE_CMD get monitoringstack -n "$NAMESPACE" -o json 2>/dev/null | \
        jq -r '.items[] | .metadata.name as $name | .status.conditions[]? | "  [\($name)] \(.type): \(.status) - \(.message // "N/A")"' || \
        warning "Could not get conditions"
else
    error "✗ No MonitoringStack found in namespace '$NAMESPACE'"
fi

#================================================================
# 7. Prometheus Pods
#================================================================
echo ""
step "7. Prometheus Pods in namespace '$NAMESPACE'"
echo ""

# MonitoringStack creates pods with name pattern: <stack-name>-prometheus-<num>
PROM_PODS=$($KUBE_CMD get pods -n "$NAMESPACE" 2>/dev/null | grep prometheus || echo "")
if [ -n "$PROM_PODS" ]; then
    log "✓ Prometheus pods found:"
    $KUBE_CMD get pods -n "$NAMESPACE" 2>/dev/null | grep prometheus
    
    # Get first prometheus pod name
    POD_NAME=$($KUBE_CMD get pods -n "$NAMESPACE" -o name 2>/dev/null | grep prometheus | head -1 | sed 's|pod/||')
    
    if [ -n "$POD_NAME" ]; then
        echo ""
        log "Prometheus pod: $POD_NAME"
        POD_STATUS=$($KUBE_CMD get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
        log "  Status: $POD_STATUS"
        
        if [ "$POD_STATUS" != "Running" ]; then
            warning "  Pod is not Running!"
            $KUBE_CMD describe pod "$POD_NAME" -n "$NAMESPACE" | tail -20
        fi
        
        echo ""
        log "Checking Prometheus pod logs for errors..."
        $KUBE_CMD logs -n "$NAMESPACE" "$POD_NAME" --tail=50 2>&1 | grep -E "error|Error|ERROR|warn|Warn|WARN|failed|Failed" || log "  No errors found in recent logs"
    fi
else
    error "✗ No Prometheus pods found in namespace '$NAMESPACE'"
    warning "  Checking all pods in namespace:"
    $KUBE_CMD get pods -n "$NAMESPACE" 2>/dev/null || echo "  No pods found"
fi

#================================================================
# 8. ScrapeConfig Status
#================================================================
echo ""
step "8. ScrapeConfig Status in namespace '$NAMESPACE'"
echo ""

if $KUBE_CMD get scrapeconfig -n "$NAMESPACE" &>/dev/null; then
    SCRAPE_COUNT=$($KUBE_CMD get scrapeconfig -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    log "✓ ScrapeConfig resources: $SCRAPE_COUNT"
    $KUBE_CMD get scrapeconfig -n "$NAMESPACE" 2>/dev/null
    
    echo ""
    log "ScrapeConfig details:"
    for sc in $($KUBE_CMD get scrapeconfig -n "$NAMESPACE" -o name 2>/dev/null); do
        SC_NAME=$(echo "$sc" | sed 's|scrapeconfig.monitoring.rhobs/||')
        log "  Config: $SC_NAME"
        
        # Show targets
        TARGETS=$($KUBE_CMD get "$sc" -n "$NAMESPACE" -o jsonpath='{.spec.staticConfigs[*].targets[*]}' 2>/dev/null || echo "")
        log "    Targets: $TARGETS"
        
        # Show TLS config
        TLS_CERT_SECRET=$($KUBE_CMD get "$sc" -n "$NAMESPACE" -o jsonpath='{.spec.tlsConfig.cert.secret.name}' 2>/dev/null || echo "")
        if [ -n "$TLS_CERT_SECRET" ]; then
            log "    TLS Cert Secret: $TLS_CERT_SECRET"
        fi
        
        # Show auth config
        AUTH_TYPE=$($KUBE_CMD get "$sc" -n "$NAMESPACE" -o jsonpath='{.spec.authorization.type}' 2>/dev/null || echo "")
        if [ -n "$AUTH_TYPE" ]; then
            log "    Auth Type: $AUTH_TYPE"
        fi
    done
else
    error "✗ No ScrapeConfig found in namespace '$NAMESPACE'"
fi

#================================================================
# 9. Prometheus Service and Endpoints
#================================================================
echo ""
step "9. Prometheus Service and Endpoints"
echo ""

# MonitoringStack creates services with name pattern: <stack-name>-prometheus
PROM_SERVICES=$($KUBE_CMD get svc -n "$NAMESPACE" 2>/dev/null | grep prometheus || echo "")
if [ -n "$PROM_SERVICES" ]; then
    log "✓ Prometheus services found:"
    $KUBE_CMD get svc -n "$NAMESPACE" 2>/dev/null | grep prometheus
    
    # Get service name for port-forward instructions
    PROM_SVC=$($KUBE_CMD get svc -n "$NAMESPACE" -o name 2>/dev/null | grep prometheus | head -1 | sed 's|service/||')
    if [ -n "$PROM_SVC" ]; then
        log ""
        log "To access Prometheus UI, run:"
        log "  $KUBE_CMD port-forward -n $NAMESPACE svc/$PROM_SVC 9090:9090"
        log "  Then open: http://localhost:9090"
    fi
else
    error "✗ No Prometheus services found"
    warning "  Checking all services in namespace:"
    $KUBE_CMD get svc -n "$NAMESPACE" 2>/dev/null || echo "  No services found"
fi

#================================================================
# 10. Check Prometheus Targets via API
#================================================================
echo ""
step "10. Prometheus Targets (if Prometheus is accessible)"
echo ""

# Find Prometheus pod (MonitoringStack naming)
PROM_POD=$($KUBE_CMD get pods -n "$NAMESPACE" -o name 2>/dev/null | grep prometheus | head -1 | sed 's|pod/||' || echo "")
if [ -n "$PROM_POD" ]; then
    log "Querying Prometheus targets via port-forward..."
    
    # Start port-forward in background
    $KUBE_CMD port-forward -n "$NAMESPACE" "$PROM_POD" 9090:9090 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3
    
    # Query targets
    if curl -s http://localhost:9090/api/v1/targets 2>/dev/null | jq . >/dev/null 2>&1; then
        log "✓ Prometheus API accessible"
        
        # Show active targets
        TARGETS=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
            jq -r '.data.activeTargets[] | "  [\(.labels.job)] \(.health) - \(.scrapeUrl) - Last: \(.lastScrape)"' || echo "")
        
        if [ -n "$TARGETS" ]; then
            log "Active scrape targets:"
            echo "$TARGETS"
        else
            warning "No active targets found"
        fi
        
        # Check for RHACS/stackrox targets specifically
        RHACS_TARGETS=$(curl -s http://localhost:9090/api/v1/targets 2>/dev/null | \
            jq -r '.data.activeTargets[] | select(.labels.job | contains("stackrox") or contains("rhacs") or contains("central")) | .labels.job' || echo "")
        
        if [ -n "$RHACS_TARGETS" ]; then
            log ""
            log "✓ Found RHACS-related targets:"
            echo "$RHACS_TARGETS" | while read target; do
                log "  - $target"
            done
        else
            warning "✗ No RHACS/stackrox targets found in Prometheus"
        fi
        
        # Check if RHACS metrics are being collected
        log ""
        log "Checking for RHACS metrics in Prometheus..."
        METRICS=$(curl -s "http://localhost:9090/api/v1/label/__name__/values" 2>/dev/null | \
            jq -r '.data[] | select(startswith("rox_"))' | head -10 || echo "")
        
        if [ -n "$METRICS" ]; then
            log "✓ RHACS metrics found in Prometheus:"
            echo "$METRICS" | while read metric; do
                log "  - $metric"
            done
        else
            error "✗ No RHACS metrics found in Prometheus"
            warning "  This means Prometheus is not successfully scraping RHACS"
        fi
    else
        warning "Could not access Prometheus API"
    fi
    
    # Kill port-forward
    kill $PF_PID 2>/dev/null || true
    wait $PF_PID 2>/dev/null || true
else
    warning "No Prometheus pod found to query"
fi

#================================================================
# 11. Perses Resources
#================================================================
echo ""
step "11. Perses Resources in namespace '$NAMESPACE'"
echo ""

if $KUBE_CMD get persesdatasource -n "$NAMESPACE" &>/dev/null 2>&1; then
    DS_COUNT=$($KUBE_CMD get persesdatasource -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    log "✓ Perses Datasources: $DS_COUNT"
    $KUBE_CMD get persesdatasource -n "$NAMESPACE" 2>/dev/null || true
else
    warning "✗ No Perses Datasources found (CRD may not be installed)"
fi

if $KUBE_CMD get persesdashboard -n "$NAMESPACE" &>/dev/null 2>&1; then
    DB_COUNT=$($KUBE_CMD get persesdashboard -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    log "✓ Perses Dashboards: $DB_COUNT"
    $KUBE_CMD get persesdashboard -n "$NAMESPACE" 2>/dev/null || true
else
    warning "✗ No Perses Dashboards found (CRD may not be installed)"
fi

# Check UI Plugin (cluster-scoped)
if $KUBE_CMD get uiplugin monitoring &>/dev/null 2>&1; then
    log "✓ Perses UI Plugin: monitoring"
    UI_STATUS=$($KUBE_CMD get uiplugin monitoring -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
    log "  Status: $UI_STATUS"
else
    warning "✗ Perses UI Plugin not found (should be cluster-scoped resource 'monitoring')"
fi

#================================================================
# 12. Prometheus Configuration
#================================================================
echo ""
step "12. Prometheus Configuration"
echo ""

if $KUBE_CMD get prometheus -n "$NAMESPACE" &>/dev/null 2>&1; then
    PROM_COUNT=$($KUBE_CMD get prometheus -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
    log "✓ Prometheus resources: $PROM_COUNT"
    $KUBE_CMD get prometheus -n "$NAMESPACE" 2>/dev/null || true
    
    # Check Prometheus configuration
    for prom in $($KUBE_CMD get prometheus -n "$NAMESPACE" -o name 2>/dev/null); do
        PROM_NAME=$(echo "$prom" | sed 's|prometheus.monitoring.coreos.com/||')
        log ""
        log "Prometheus config: $PROM_NAME"
        
        REPLICAS=$($KUBE_CMD get "$prom" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "?")
        RETENTION=$($KUBE_CMD get "$prom" -n "$NAMESPACE" -o jsonpath='{.spec.retention}' 2>/dev/null || echo "?")
        log "  Replicas: $REPLICAS"
        log "  Retention: $RETENTION"
    done
else
    warning "✗ No Prometheus resources found"
fi

#================================================================
# 13. Common Issues and Fixes
#================================================================
echo ""
step "13. Common Issues Detected"
echo ""

ISSUES_FOUND=false

# Issue: Prometheus not running
if [ -z "$PROM_PODS" ]; then
    error "✗ ISSUE: Prometheus pods not running"
    log "  Fix: Check MonitoringStack status and operator logs:"
    log "    $KUBE_CMD describe monitoringstack -n $NAMESPACE"
    log "    $KUBE_CMD logs -n openshift-cluster-observability-operator deployment/cluster-observability-operator"
    ISSUES_FOUND=true
fi

# Issue: No RHACS metrics in Prometheus
if [ -n "$PROM_POD" ] && [ -z "${METRICS:-}" ]; then
    error "✗ ISSUE: No RHACS metrics in Prometheus"
    log "  Possible causes:"
    log "    1. Scrape target not configured correctly"
    log "    2. Authentication failing (check secrets)"
    log "    3. Network connectivity issues"
    log "    4. RHACS Central not exposing metrics"
    log ""
    log "  Fix: Check Prometheus targets for errors:"
    log "    $KUBE_CMD port-forward -n $NAMESPACE pod/$PROM_POD 9090:9090"
    log "    Open: http://localhost:9090/targets"
    ISSUES_FOUND=true
fi

# Issue: Certificate auth not working
if [ "$HTTP_CODE" != "200" ] && [ -f "tls.crt" ]; then
    warning "✗ ISSUE: Certificate authentication not configured"
    log "  This is optional (API token auth is working)"
    log "  To enable certificate auth:"
    log "    1. Create UserPKI auth provider in RHACS UI"
    log "    2. Or use roxctl:"
    log "       export GRPC_ENFORCE_ALPN_ENABLED=false"
    log "       roxctl -e \${ROX_CENTRAL_URL#https://}:443 central userpki create Prometheus \\"
    log "         -c tls.crt -r Admin --insecure-skip-tls-verify"
fi

if [ "$ISSUES_FOUND" = false ]; then
    log "✓ No critical issues detected"
fi

#================================================================
# Summary
#================================================================
echo ""
step "Diagnostic Summary"
echo "=========================================="
echo ""

echo "To view Prometheus UI:"
echo "  $KUBE_CMD port-forward -n $NAMESPACE svc/$PROM_SVC 9090:9090"
echo "  Open: http://localhost:9090"
echo ""
echo "To check Prometheus targets:"
echo "  Open Prometheus UI → Status → Targets"
echo "  Look for 'stackrox' or 'rhacs' job"
echo ""
echo "To view Prometheus logs:"
echo "  $KUBE_CMD logs -n $NAMESPACE -l app.kubernetes.io/name=prometheus -f"
echo ""
echo "To query RHACS metrics:"
echo "  curl -H \"Authorization: Bearer \$ROX_API_TOKEN\" -k \$ROX_CENTRAL_URL/metrics | head -20"
echo ""

if [ -f ~/.bashrc ] && grep -q "GRPC_ENFORCE_ALPN_ENABLED" ~/.bashrc; then
    log "✓ gRPC ALPN fix is configured in ~/.bashrc"
else
    warning "✗ gRPC ALPN fix not in ~/.bashrc"
    warning "  Add it with: echo 'export GRPC_ENFORCE_ALPN_ENABLED=false' >> ~/.bashrc"
fi

echo ""
log "Diagnostics complete!"
echo ""
