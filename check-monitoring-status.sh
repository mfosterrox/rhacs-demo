#!/bin/bash

# Script: check-monitoring-status.sh
# Description: Check the status of RHACS monitoring setup
# Usage: ./check-monitoring-status.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_section() {
    echo ""
    echo -e "${BLUE}$1${NC}"
    echo "----------------------------------------"
}

print_success() {
    echo -e "  ${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "  ${YELLOW}⊘${NC} $1"
}

print_error() {
    echo -e "  ${RED}✗${NC} $1"
}

print_info() {
    echo -e "  ${GREEN}[INFO]${NC} $1"
}

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

print_header "RHACS Monitoring Status Check"
echo ""

# Check cluster connection
if ! oc whoami &>/dev/null; then
    echo -e "${RED}✗ Not connected to OpenShift cluster${NC}"
    echo "Please login to your cluster first: oc login ..."
    exit 1
fi

echo -e "${GREEN}✓ Connected to cluster as: $(oc whoami)${NC}"
echo ""

# Check RHACS namespace
print_section "1. RHACS Installation"
if oc get namespace "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "RHACS namespace exists: ${RHACS_NAMESPACE}"
    
    if oc get deployment central -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
        local status=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "Unknown")
        if [ "${status}" = "True" ]; then
            print_success "RHACS Central is running"
        else
            print_warning "RHACS Central status: ${status}"
        fi
    else
        print_error "RHACS Central deployment not found"
    fi
else
    print_error "RHACS namespace not found: ${RHACS_NAMESPACE}"
fi

# Check Prometheus Operator
print_section "2. Prometheus Operator"
if oc api-resources --api-group=monitoring.coreos.com 2>/dev/null | grep -q "prometheuses"; then
    print_success "Prometheus Operator CRDs available"
    
    # Check user workload monitoring
    local uwm_enabled=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c "enableUserWorkload: true" || echo "0")
    if [ "${uwm_enabled}" -gt 0 ]; then
        print_success "User workload monitoring is enabled"
    else
        print_warning "User workload monitoring not enabled"
        print_info "Run: bash setup/06-install-monitoring-operators.sh"
    fi
    
    # Check for Prometheus pods
    if oc get namespace openshift-user-workload-monitoring >/dev/null 2>&1; then
        local pod_count=$(oc get pods -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus-operator 2>/dev/null | grep -c "Running" || echo "0")
        if [ "${pod_count}" -gt 0 ]; then
            print_success "Prometheus Operator pods running (${pod_count})"
        else
            print_warning "Prometheus Operator pods not running yet"
        fi
    else
        print_warning "Namespace openshift-user-workload-monitoring not found"
    fi
else
    print_error "Prometheus Operator CRDs not found"
fi

# Check Cluster Observability Operator
print_section "3. Cluster Observability Operator (Optional)"
if oc api-resources --api-group=monitoring.rhobs 2>/dev/null | grep -q "monitoringstacks"; then
    print_success "Cluster Observability Operator CRDs available"
    
    if oc get namespace openshift-cluster-observability-operator >/dev/null 2>&1; then
        local pod_count=$(oc get pods -n openshift-cluster-observability-operator 2>/dev/null | grep -c "Running" || echo "0")
        print_info "Operator pods running: ${pod_count}"
    fi
else
    print_warning "Not installed (optional)"
    print_info "To install: See MONITORING_SETUP.md"
fi

# Check Perses
print_section "4. Perses (Optional)"
if oc api-resources --api-group=perses.dev 2>/dev/null | grep -q "persesdashboards"; then
    print_success "Perses CRDs available"
else
    print_warning "Not installed (optional)"
    print_info "To install: See MONITORING_SETUP.md"
fi

# Check RHACS monitoring resources
print_section "5. RHACS Monitoring Resources"

# ServiceAccount
if oc get serviceaccount sample-stackrox-prometheus -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "ServiceAccount: sample-stackrox-prometheus"
else
    print_error "ServiceAccount not found"
    print_info "Run: bash setup/07-setup-monitoring.sh"
fi

# Token Secret
if oc get secret sample-stackrox-prometheus-token -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "Token secret: sample-stackrox-prometheus-token"
    
    # Check if token is populated
    local token=$(oc get secret sample-stackrox-prometheus-token -n "${RHACS_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null || echo "")
    if [ -n "${token}" ]; then
        print_success "Token is populated"
    else
        print_warning "Token not yet populated (may need time)"
    fi
else
    print_error "Token secret not found"
fi

# Declarative Config
if oc get configmap sample-stackrox-prometheus-declarative-configuration -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "Declarative configuration: sample-stackrox-prometheus-declarative-configuration"
else
    print_warning "Declarative configuration not found"
fi

# Prometheus instance
if oc get prometheus sample-stackrox-prometheus-server -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "Prometheus instance: sample-stackrox-prometheus-server"
    
    # Check Prometheus pods
    local prom_pods=$(oc get pods -n "${RHACS_NAMESPACE}" -l app.kubernetes.io/name=prometheus 2>/dev/null | grep -c "Running" || echo "0")
    if [ "${prom_pods}" -gt 0 ]; then
        print_success "Prometheus pods running (${prom_pods})"
    else
        print_warning "Prometheus pods not running yet"
    fi
else
    print_warning "Prometheus instance not found"
    print_info "Requires Prometheus Operator to be installed"
fi

# MonitoringStack (Cluster Observability Operator)
if oc get monitoringstack sample-stackrox-monitoring-stack -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "MonitoringStack: sample-stackrox-monitoring-stack"
else
    print_warning "MonitoringStack not found (requires Cluster Observability Operator)"
fi

# ScrapeConfig (Cluster Observability Operator)
if oc get scrapeconfig sample-stackrox-scrape-config -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "ScrapeConfig: sample-stackrox-scrape-config"
else
    print_warning "ScrapeConfig not found (requires Cluster Observability Operator)"
fi

# Perses Dashboard
if oc get persesdashboard sample-stackrox-dashboard -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    print_success "PersesDashboard: sample-stackrox-dashboard"
else
    print_warning "PersesDashboard not found (requires Perses)"
fi

# Check RHACS metrics endpoint
print_section "6. RHACS Metrics Endpoint"

local central_url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
if [ -n "${central_url}" ]; then
    print_info "Central URL: ${central_url}"
    
    # Try to access metrics with ServiceAccount token
    local sa_token=$(oc get secret sample-stackrox-prometheus-token -n "${RHACS_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    if [ -n "${sa_token}" ]; then
        local metrics_status=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${sa_token}" "${central_url}/metrics" --max-time 10 || echo "000")
        if [ "${metrics_status}" = "200" ]; then
            print_success "Metrics endpoint accessible (HTTP ${metrics_status})"
            
            # Count metrics
            local metric_count=$(curl -k -s -H "Authorization: Bearer ${sa_token}" "${central_url}/metrics" --max-time 10 | grep -c "^rox_" || echo "0")
            print_info "Found ${metric_count} RHACS metrics"
        else
            print_warning "Metrics endpoint returned HTTP ${metrics_status}"
        fi
    else
        print_warning "Cannot test metrics endpoint (token not available)"
    fi
else
    print_error "Central URL not found"
fi

# Summary
print_section "Summary"
echo ""

local prometheus_ready=false
local monitoring_stack_ready=false

if oc api-resources --api-group=monitoring.coreos.com 2>/dev/null | grep -q "prometheuses" && \
   oc get prometheus sample-stackrox-prometheus-server -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    prometheus_ready=true
fi

if oc api-resources --api-group=monitoring.rhobs 2>/dev/null | grep -q "monitoringstacks" && \
   oc get monitoringstack sample-stackrox-monitoring-stack -n "${RHACS_NAMESPACE}" >/dev/null 2>&1; then
    monitoring_stack_ready=true
fi

if [ "${prometheus_ready}" = true ] || [ "${monitoring_stack_ready}" = true ]; then
    echo -e "${GREEN}✓ RHACS monitoring is configured and operational${NC}"
    echo ""
    echo "Access Prometheus:"
    echo "  oc port-forward -n ${RHACS_NAMESPACE} svc/sample-stackrox-prometheus-server 9090:9090"
    echo "  open http://localhost:9090"
else
    echo -e "${YELLOW}⊘ RHACS monitoring is partially configured${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Run: bash setup/06-install-monitoring-operators.sh"
    echo "  2. Run: bash setup/07-setup-monitoring.sh"
    echo "  3. See: MONITORING_SETUP.md for detailed troubleshooting"
fi

echo ""
