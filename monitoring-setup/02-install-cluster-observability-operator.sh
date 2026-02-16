#!/bin/bash

# Script: 01-install-cluster-observability-operator.sh
# Description: Install Cluster Observability Operator (includes Perses)

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly COO_NAMESPACE="openshift-cluster-observability-operator"

# Print functions
print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Error handler
error_handler() {
    local exit_code=$1
    local line_number=$2
    print_error "Error at line ${line_number} (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap 'error_handler $? $LINENO' ERR

#================================================================
# Main Function
#================================================================
main() {
    print_step "Installing Cluster Observability Operator (includes Perses)"
    echo "================================================================"
    
    # Check prerequisites
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    # Check if already installed
    if oc get csv -n ${COO_NAMESPACE} 2>/dev/null | grep -q "cluster-observability-operator.*Succeeded"; then
        print_info "✓ Cluster Observability Operator already installed"
        return 0
    fi
    
    # Create namespace
    print_info "Creating namespace ${COO_NAMESPACE}..."
    oc create namespace ${COO_NAMESPACE} --dry-run=client -o yaml | oc apply -f -
    
    # Create OperatorGroup
    print_info "Creating OperatorGroup..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: ${COO_NAMESPACE}
spec:
  targetNamespaces: []
EOF
    
    # Create Subscription
    print_info "Creating Subscription..."
    
    # Detect available channel
    local available_channel=$(oc get packagemanifest cluster-observability-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}' 2>/dev/null || echo "stable")
    print_info "Using channel: ${available_channel}"
    
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: ${COO_NAMESPACE}
spec:
  channel: ${available_channel}
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    
    # Wait for operator pods to be ready
    print_info "Waiting for operator pods to be ready (this may take 2-3 minutes)..."
    local max_wait=180
    local waited=0
    local required_pods=4  # observability-operator, perses-operator, prometheus-operator, webhook
    
    while [ ${waited} -lt ${max_wait} ]; do
        local running_pods=$(oc get pods -n ${COO_NAMESPACE} --no-headers 2>/dev/null | grep -c "Running" || echo "0")
        local ready_pods=$(oc get pods -n ${COO_NAMESPACE} --field-selector=status.phase=Running --no-headers 2>/dev/null | awk '{split($2,a,"/"); if(a[1]==a[2]) print $0}' | wc -l | tr -d ' ')
        
        if [ "${ready_pods}" -ge ${required_pods} ]; then
            print_info "✓ Cluster Observability Operator installed successfully"
            print_info "  ${ready_pods} operator pods running and ready"
            
            # List the pods
            print_info ""
            print_info "Operator pods:"
            oc get pods -n ${COO_NAMESPACE} --no-headers 2>/dev/null | awk '{print "  • " $1 " (" $3 ")"}' || true
            
            sleep 5  # Give it a moment to stabilize
            return 0
        fi
        
        if [ $((waited % 30)) -eq 0 ]; then
            print_info "Still waiting... (${waited}s/${max_wait}s) [${ready_pods}/${required_pods} pods ready]"
        fi
        
        sleep 10
        waited=$((waited + 10))
    done
    
    print_error "Operator installation timed out"
    print_error "Only ${ready_pods}/${required_pods} pods ready"
    print_info ""
    print_info "Current pod status:"
    oc get pods -n ${COO_NAMESPACE} 2>/dev/null || true
    exit 1
}

# Run main function
main "$@"
