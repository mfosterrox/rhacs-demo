#!/bin/bash

# Script: 05a-install-monitoring-operators.sh
# Description: Install monitoring operators (Prometheus Operator for RHACS metrics collection)
# Usage: ./05a-install-monitoring-operators.sh

set -euo pipefail

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Configuration
readonly PROMETHEUS_NAMESPACE="openshift-user-workload-monitoring"
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Trap errors
trap 'error_handler $? $LINENO' ERR

error_handler() {
    local exit_code=$1
    local line_number=$2
    print_error "Error occurred in script at line ${line_number} (exit code: ${exit_code})"
    exit "${exit_code}"
}

# Print functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    if ! command_exists oc; then
        print_error "oc (OpenShift CLI) not found"
        return 1
    fi
    
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster. Please login first."
        return 1
    fi
    
    print_info "✓ Connected to cluster as: $(oc whoami)"
    return 0
}

# Check if Prometheus Operator is available
check_prometheus_operator() {
    print_step "Checking Prometheus Operator availability..."
    
    # Check if Prometheus Operator CRDs exist (comes with OpenShift by default)
    if oc api-resources --api-group=monitoring.coreos.com 2>/dev/null | grep -q "prometheuses"; then
        print_info "✓ Prometheus Operator CRDs are available"
        return 0
    else
        print_warn "Prometheus Operator CRDs not found"
        return 1
    fi
}

# Enable user workload monitoring
enable_user_workload_monitoring() {
    print_step "Enabling user workload monitoring..."
    
    # Check if already enabled
    local uwm_enabled=$(oc get configmap cluster-monitoring-config -n openshift-monitoring -o jsonpath='{.data.config\.yaml}' 2>/dev/null | grep -c "enableUserWorkload: true" || echo "0")
    
    if [ "${uwm_enabled}" -gt 0 ]; then
        print_info "✓ User workload monitoring is already enabled"
        return 0
    fi
    
    print_info "Enabling user workload monitoring in cluster-monitoring-config..."
    
    # Create or update the cluster-monitoring-config ConfigMap
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    
    if [ $? -eq 0 ]; then
        print_info "✓ User workload monitoring enabled"
        
        # Wait for user workload monitoring namespace to be created
        print_info "Waiting for ${PROMETHEUS_NAMESPACE} namespace to be created..."
        local max_wait=120
        local waited=0
        while [ ${waited} -lt ${max_wait} ]; do
            if oc get namespace "${PROMETHEUS_NAMESPACE}" >/dev/null 2>&1; then
                print_info "✓ ${PROMETHEUS_NAMESPACE} namespace is ready"
                return 0
            fi
            sleep 5
            waited=$((waited + 5))
        done
        
        print_warn "Namespace ${PROMETHEUS_NAMESPACE} not created within ${max_wait}s"
        print_info "This is expected - the namespace will be created by the cluster monitoring operator"
    else
        print_error "Failed to enable user workload monitoring"
        return 1
    fi
    
    return 0
}

# Wait for Prometheus Operator pods to be ready
wait_for_prometheus_operator() {
    print_step "Waiting for Prometheus Operator to be ready..."
    
    local max_wait=180
    local waited=0
    
    # Wait for prometheus-operator pod in openshift-user-workload-monitoring
    while [ ${waited} -lt ${max_wait} ]; do
        if oc get namespace "${PROMETHEUS_NAMESPACE}" >/dev/null 2>&1; then
            local pod_count=$(oc get pods -n "${PROMETHEUS_NAMESPACE}" -l app.kubernetes.io/name=prometheus-operator --field-selector=status.phase=Running 2>/dev/null | grep -c "Running" || echo "0")
            
            if [ "${pod_count}" -gt 0 ]; then
                print_info "✓ Prometheus Operator is running in ${PROMETHEUS_NAMESPACE}"
                return 0
            fi
        fi
        
        if [ $((waited % 30)) -eq 0 ]; then
            print_info "Waiting for Prometheus Operator pods... (${waited}s/${max_wait}s)"
        fi
        
        sleep 5
        waited=$((waited + 5))
    done
    
    print_warn "Prometheus Operator pods not ready within ${max_wait}s"
    print_warn "The operator may still be deploying - continuing anyway"
    return 0
}

# Display monitoring operator information
display_operator_info() {
    print_info ""
    print_info "=========================================="
    print_info "Monitoring Operator Status"
    print_info "=========================================="
    print_info ""
    
    print_info "Prometheus Operator:"
    if oc api-resources --api-group=monitoring.coreos.com 2>/dev/null | grep -q "prometheuses"; then
        print_info "  ✓ CRDs available"
        
        # Check for operator pods
        if oc get namespace "${PROMETHEUS_NAMESPACE}" >/dev/null 2>&1; then
            local pod_count=$(oc get pods -n "${PROMETHEUS_NAMESPACE}" -l app.kubernetes.io/name=prometheus-operator 2>/dev/null | grep -c "Running" || echo "0")
            if [ "${pod_count}" -gt 0 ]; then
                print_info "  ✓ Operator running (${pod_count} pods in ${PROMETHEUS_NAMESPACE})"
            else
                print_warn "  ⊘ Operator pods not running yet"
            fi
        else
            print_warn "  ⊘ Namespace ${PROMETHEUS_NAMESPACE} not yet created"
        fi
    else
        print_warn "  ⊘ CRDs not available"
    fi
    
    print_info ""
    print_info "Notes:"
    print_info "  - Prometheus Operator is part of OpenShift monitoring"
    print_info "  - User workload monitoring has been enabled"
    print_info "  - This allows creating Prometheus instances in user namespaces"
    print_info ""
}

# Main function
main() {
    print_info "=========================================="
    print_info "Monitoring Operators Installation"
    print_info "=========================================="
    print_info ""
    
    # Check prerequisites
    if ! check_prerequisites; then
        print_error "Prerequisites check failed"
        exit 1
    fi
    
    print_info ""
    
    # Check Prometheus Operator
    if check_prometheus_operator; then
        print_info "✓ Prometheus Operator is available"
    else
        print_warn "Prometheus Operator CRDs not found"
        print_warn "This is unusual for OpenShift 4.x clusters"
    fi
    
    print_info ""
    
    # Enable user workload monitoring (enables Prometheus Operator for user namespaces)
    if ! enable_user_workload_monitoring; then
        print_error "Failed to enable user workload monitoring"
        exit 1
    fi
    
    print_info ""
    
    # Wait for operator to be ready
    wait_for_prometheus_operator || true
    
    # Display operator information
    display_operator_info
    
    print_info "=========================================="
    print_info "Monitoring Operators Setup Complete"
    print_info "=========================================="
    print_info ""
    print_info "Next steps:"
    print_info "  - The monitoring manifests will be applied in the next step"
    print_info "  - Prometheus instances can now be created in user namespaces"
    print_info ""
}

# Run main function
main "$@"
