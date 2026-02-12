#!/bin/bash

# Script: 06-install-monitoring-operators.sh
# Description: Install ALL required monitoring operators for RHACS monitoring
# Usage: ./06-install-monitoring-operators.sh

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
readonly CLUSTER_OBSERVABILITY_NAMESPACE="openshift-cluster-observability-operator"
readonly PERSES_NAMESPACE="perses-system"

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
    
    print_error "Prometheus Operator pods not ready within ${max_wait}s"
    return 1
}

# Install Cluster Observability Operator
install_cluster_observability_operator() {
    print_step "Installing Cluster Observability Operator..."
    
    # Check if already installed
    if oc get csv -n "${CLUSTER_OBSERVABILITY_NAMESPACE}" 2>/dev/null | grep -q "cluster-observability-operator"; then
        print_info "✓ Cluster Observability Operator already installed"
        return 0
    fi
    
    # Create namespace
    print_info "Creating namespace ${CLUSTER_OBSERVABILITY_NAMESPACE}..."
    oc create namespace "${CLUSTER_OBSERVABILITY_NAMESPACE}" --dry-run=client -o yaml | oc apply -f - || {
        print_error "Failed to create namespace"
        return 1
    }
    
    # Create OperatorGroup
    print_info "Creating OperatorGroup..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: ${CLUSTER_OBSERVABILITY_NAMESPACE}
spec:
  targetNamespaces: []
EOF
    
    if [ $? -ne 0 ]; then
        print_error "Failed to create OperatorGroup"
        return 1
    fi
    
    # Create Subscription
    print_info "Creating Subscription..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: ${CLUSTER_OBSERVABILITY_NAMESPACE}
spec:
  channel: development
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    
    if [ $? -ne 0 ]; then
        print_error "Failed to create Subscription"
        return 1
    fi
    
    print_info "✓ Subscription created, waiting for operator installation..."
    
    # Wait for CSV to be created and reach Succeeded phase
    local max_wait=300
    local waited=0
    
    while [ ${waited} -lt ${max_wait} ]; do
        local csv_phase=$(oc get csv -n "${CLUSTER_OBSERVABILITY_NAMESPACE}" -o jsonpath='{.items[?(@.metadata.name=~"cluster-observability-operator.*")].status.phase}' 2>/dev/null || echo "")
        
        if [ "${csv_phase}" = "Succeeded" ]; then
            print_info "✓ Cluster Observability Operator installed successfully"
            
            # Wait for operator pods
            sleep 10
            local pod_count=$(oc get pods -n "${CLUSTER_OBSERVABILITY_NAMESPACE}" --field-selector=status.phase=Running 2>/dev/null | grep -c "Running" || echo "0")
            print_info "✓ Operator pods running: ${pod_count}"
            return 0
        fi
        
        if [ $((waited % 30)) -eq 0 ]; then
            print_info "Waiting for operator installation... (${waited}s/${max_wait}s) [Phase: ${csv_phase:-pending}]"
        fi
        
        sleep 10
        waited=$((waited + 10))
    done
    
    print_error "Cluster Observability Operator installation timed out"
    return 1
}

# Install Perses Operator
install_perses_operator() {
    print_step "Installing Perses Operator..."
    
    # Check if already installed
    if oc get namespace "${PERSES_NAMESPACE}" >/dev/null 2>&1; then
        if oc get deployment perses-operator -n "${PERSES_NAMESPACE}" >/dev/null 2>&1; then
            print_info "✓ Perses Operator already installed"
            return 0
        fi
    fi
    
    print_info "Downloading and installing Perses Operator from GitHub..."
    
    # Install Perses Operator from official releases
    local perses_version="v0.8.0"
    local install_url="https://github.com/perses/perses-operator/releases/download/${perses_version}/install.yaml"
    
    if ! curl -fsSL "${install_url}" | oc apply -f -; then
        print_error "Failed to install Perses Operator"
        print_error "URL: ${install_url}"
        return 1
    fi
    
    print_info "✓ Perses Operator manifests applied"
    
    # Wait for namespace to be created
    local max_wait=60
    local waited=0
    while [ ${waited} -lt ${max_wait} ]; do
        if oc get namespace "${PERSES_NAMESPACE}" >/dev/null 2>&1; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    # Wait for operator deployment to be ready
    print_info "Waiting for Perses Operator deployment..."
    max_wait=180
    waited=0
    
    while [ ${waited} -lt ${max_wait} ]; do
        local deployment_ready=$(oc get deployment perses-operator -n "${PERSES_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
        
        if [ "${deployment_ready}" = "True" ]; then
            print_info "✓ Perses Operator is running"
            return 0
        fi
        
        if [ $((waited % 30)) -eq 0 ]; then
            print_info "Waiting for Perses Operator... (${waited}s/${max_wait}s)"
        fi
        
        sleep 10
        waited=$((waited + 10))
    done
    
    print_error "Perses Operator deployment not ready within ${max_wait}s"
    return 1
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
        
        if oc get namespace "${PROMETHEUS_NAMESPACE}" >/dev/null 2>&1; then
            local pod_count=$(oc get pods -n "${PROMETHEUS_NAMESPACE}" -l app.kubernetes.io/name=prometheus-operator 2>/dev/null | grep -c "Running" || echo "0")
            if [ "${pod_count}" -gt 0 ]; then
                print_info "  ✓ Operator running (${pod_count} pods in ${PROMETHEUS_NAMESPACE})"
            else
                print_error "  ✗ Operator pods not running"
            fi
        else
            print_error "  ✗ Namespace ${PROMETHEUS_NAMESPACE} not created"
        fi
    else
        print_error "  ✗ CRDs not available"
    fi
    
    print_info ""
    print_info "Cluster Observability Operator:"
    if oc api-resources --api-group=monitoring.rhobs 2>/dev/null | grep -q "monitoringstacks"; then
        print_info "  ✓ CRDs available"
        
        if oc get namespace "${CLUSTER_OBSERVABILITY_NAMESPACE}" >/dev/null 2>&1; then
            local pod_count=$(oc get pods -n "${CLUSTER_OBSERVABILITY_NAMESPACE}" 2>/dev/null | grep -c "Running" || echo "0")
            print_info "  ✓ Operator running (${pod_count} pods in ${CLUSTER_OBSERVABILITY_NAMESPACE})"
        fi
    else
        print_error "  ✗ CRDs not available"
    fi
    
    print_info ""
    print_info "Perses Operator:"
    if oc api-resources --api-group=perses.dev 2>/dev/null | grep -q "persesdashboards"; then
        print_info "  ✓ CRDs available"
        
        if oc get namespace "${PERSES_NAMESPACE}" >/dev/null 2>&1; then
            local deployment_ready=$(oc get deployment perses-operator -n "${PERSES_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
            if [ "${deployment_ready}" = "True" ]; then
                print_info "  ✓ Operator running in ${PERSES_NAMESPACE}"
            else
                print_error "  ✗ Operator not ready"
            fi
        fi
    else
        print_error "  ✗ CRDs not available"
    fi
    
    print_info ""
}

# Main function
main() {
    print_info "=========================================="
    print_info "Monitoring Operators Installation"
    print_info "=========================================="
    print_info ""
    print_info "Installing ALL required operators for RHACS monitoring:"
    print_info "  1. Prometheus Operator (via user workload monitoring)"
    print_info "  2. Cluster Observability Operator"
    print_info "  3. Perses Operator"
    print_info ""
    
    # Check prerequisites
    if ! check_prerequisites; then
        print_error "Prerequisites check failed"
        exit 1
    fi
    
    print_info ""
    
    # Check Prometheus Operator
    if check_prometheus_operator; then
        print_info "✓ Prometheus Operator CRDs are available"
    else
        print_error "Prometheus Operator CRDs not found"
        print_error "This is unusual for OpenShift 4.x clusters"
        exit 1
    fi
    
    print_info ""
    
    # 1. Enable user workload monitoring (enables Prometheus Operator for user namespaces)
    print_info "[1/3] Prometheus Operator"
    if ! enable_user_workload_monitoring; then
        print_error "Failed to enable user workload monitoring"
        exit 1
    fi
    
    if ! wait_for_prometheus_operator; then
        print_error "Prometheus Operator not ready"
        exit 1
    fi
    
    print_info ""
    
    # 2. Install Cluster Observability Operator
    print_info "[2/3] Cluster Observability Operator"
    if ! install_cluster_observability_operator; then
        print_error "Failed to install Cluster Observability Operator"
        exit 1
    fi
    
    print_info ""
    
    # 3. Install Perses Operator
    print_info "[3/3] Perses Operator"
    if ! install_perses_operator; then
        print_error "Failed to install Perses Operator"
        exit 1
    fi
    
    print_info ""
    
    # Display operator information
    display_operator_info
    
    print_info "=========================================="
    print_info "✓ ALL Monitoring Operators Installed"
    print_info "=========================================="
    print_info ""
    print_info "Operators installed:"
    print_info "  ✓ Prometheus Operator (${PROMETHEUS_NAMESPACE})"
    print_info "  ✓ Cluster Observability Operator (${CLUSTER_OBSERVABILITY_NAMESPACE})"
    print_info "  ✓ Perses Operator (${PERSES_NAMESPACE})"
    print_info ""
    print_info "Next step:"
    print_info "  - Run script 07 to apply monitoring manifests"
    print_info ""
}

# Run main function
main "$@"
