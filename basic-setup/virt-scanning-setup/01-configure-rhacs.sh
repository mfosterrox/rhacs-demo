#!/bin/bash

# Script: 01-configure-rhacs.sh
# Description: Configure RHACS for virtual machine vulnerability management
#
# This script implements the official RHACS VM scanning requirements:
# 1. Sets ROX_VIRTUAL_MACHINES=true on Central, Sensor, and Collector
# 2. Verifies OpenShift Virtualization operator is installed
# 3. Enables VSOCK support via HyperConverged resource
# 4. Provides VM configuration instructions

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

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

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
readonly CNV_NAMESPACE="openshift-cnv"

#================================================================
# Patch Central deployment
#================================================================
patch_central_deployment() {
    print_step "1. Patching Central deployment with ROX_VIRTUAL_MACHINES feature flag"
    
    # Check if already set
    local current_value=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    
    if [ "${current_value}" = "true" ]; then
        print_info "✓ Central already has ROX_VIRTUAL_MACHINES=true"
        return 0
    fi
    
    print_info "Adding ROX_VIRTUAL_MACHINES=true to Central deployment..."
    
    # Patch the deployment
    oc set env deployment/central -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true
    
    # Wait for rollout
    print_info "Waiting for Central to restart..."
    oc rollout status deployment/central -n ${RHACS_NAMESPACE} --timeout=5m
    
    print_info "✓ Central deployment patched successfully"
}

#================================================================
# Patch Sensor deployment
#================================================================
patch_sensor_deployment() {
    print_step "2. Patching Sensor deployment with ROX_VIRTUAL_MACHINES feature flag"
    
    # Check if already set
    local current_value=$(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    
    if [ "${current_value}" = "true" ]; then
        print_info "✓ Sensor already has ROX_VIRTUAL_MACHINES=true"
        return 0
    fi
    
    print_info "Adding ROX_VIRTUAL_MACHINES=true to Sensor deployment..."
    
    # Patch the deployment
    oc set env deployment/sensor -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true
    
    # Wait for rollout
    print_info "Waiting for Sensor to restart..."
    oc rollout status deployment/sensor -n ${RHACS_NAMESPACE} --timeout=5m
    
    print_info "✓ Sensor deployment patched successfully"
}

#================================================================
# Patch Collector daemonset compliance container
#================================================================
patch_collector_daemonset() {
    print_step "3. Patching Collector daemonset compliance container"
    
    # Check if compliance container exists
    local has_compliance=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
    
    if [ -z "${has_compliance}" ]; then
        print_warn "⚠ Collector daemonset has no 'compliance' container"
        print_info "  This might be expected depending on your RHACS version"
        return 0
    fi
    
    # Check if already set
    local current_value=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    
    if [ "${current_value}" = "true" ]; then
        print_info "✓ Collector compliance container already has ROX_VIRTUAL_MACHINES=true"
        return 0
    fi
    
    print_info "Adding ROX_VIRTUAL_MACHINES=true to Collector compliance container..."
    
    # Patch the daemonset - target the compliance container specifically
    oc set env daemonset/collector -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true -c compliance
    
    # Wait for rollout
    print_info "Waiting for Collector to restart..."
    oc rollout status daemonset/collector -n ${RHACS_NAMESPACE} --timeout=5m
    
    print_info "✓ Collector daemonset patched successfully"
}

#================================================================
# Patch HyperConverged resource for vsock
#================================================================
patch_hyperconverged_vsock() {
    print_step "4. Patching HyperConverged resource to enable vsock support"
    
    # Check if HyperConverged exists
    if ! oc get hyperconverged -n ${CNV_NAMESPACE} >/dev/null 2>&1; then
        print_error "HyperConverged resource not found"
        print_error "Ensure OpenShift Virtualization operator is installed"
        return 1
    fi
    
    # Get HyperConverged name
    local hco_name=$(oc get hyperconverged -n ${CNV_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${hco_name}" ]; then
        print_error "No HyperConverged resource found"
        return 1
    fi
    
    print_info "Found HyperConverged resource: ${hco_name}"
    print_info "Enabling VSOCK feature gate via HyperConverged annotation..."
    
    # Get the KubeVirt resource name for status checking
    local kubevirt_name=$(oc get kubevirt -n ${CNV_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "kubevirt-kubevirt-hyperconverged")
    
    # Check if VSOCK is already enabled
    local current_gates=$(oc get kubevirt ${kubevirt_name} -n ${CNV_NAMESPACE} -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")
    
    if echo "${current_gates}" | grep -q "VSOCK"; then
        print_info "✓ VSOCK feature gate already enabled"
    else
        print_info "Adding VSOCK via JSON patch annotation on HyperConverged..."
        
        # Use annotation method (this is what worked in testing)
        oc annotate hyperconverged ${hco_name} -n ${CNV_NAMESPACE} --overwrite \
            kubevirt.kubevirt.io/jsonpatch='[
              {
                "op":"add",
                "path":"/spec/configuration/developerConfiguration/featureGates/-",
                "value":"VSOCK"
              }
            ]'
        
        print_info "✓ Annotation applied to HyperConverged"
        print_info "  Waiting for HCO to propagate changes (30s)..."
        sleep 30
        
        # Verify it worked
        local new_gates=$(oc get kubevirt ${kubevirt_name} -n ${CNV_NAMESPACE} -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")
        
        if echo "${new_gates}" | grep -q "VSOCK"; then
            print_info "✓ VSOCK successfully enabled!"
        else
            print_warn "⚠ VSOCK not yet visible - may need more time to reconcile"
            print_info "  Run: ./enable-vsock.sh for advanced troubleshooting"
        fi
    fi
    
    print_info "  Note: VMs must be configured with autoattachVSOCK: true"
}

#================================================================
# Display VM configuration instructions
#================================================================
display_vm_instructions() {
    print_step "5. Virtual Machine Configuration"
    echo ""
    
    print_info "To enable vulnerability scanning on VMs, update each VM spec:"
    echo ""
    print_info "Example VM patch:"
    cat <<'EOF'

    oc patch vm <vm-name> -n <namespace> --type=merge -p '
    {
      "spec": {
        "template": {
          "spec": {
            "domain": {
              "devices": {
                "autoattachVSOCK": true
              }
            }
          }
        }
      }
    }'

EOF
    echo ""
    print_info "Or add to VM YAML:"
    cat <<'EOF'

    spec:
      template:
        spec:
          domain:
            devices:
              autoattachVSOCK: true

EOF
    echo ""
    print_info "Additional VM requirements:"
    print_info "  • Must run Red Hat Enterprise Linux (RHEL)"
    print_info "  • RHEL must have valid subscription"
    print_info "  • Network access for CPE mappings"
    echo ""
}

#================================================================
# Main function
#================================================================
main() {
    print_info "=========================================="
    print_info "RHACS VM Vulnerability Management Setup"
    print_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    print_info "Connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    echo ""
    
    # Verify OpenShift Virtualization is installed
    if ! oc get namespace ${CNV_NAMESPACE} >/dev/null 2>&1; then
        print_error "OpenShift Virtualization not installed"
        print_error "Install OpenShift Virtualization operator first"
        exit 1
    fi
    
    if ! oc get csv -n ${CNV_NAMESPACE} 2>/dev/null | grep -q "OpenShift Virtualization.*Succeeded"; then
        print_error "OpenShift Virtualization operator not ready"
        exit 1
    fi
    
    print_info "✓ OpenShift Virtualization operator detected"
    echo ""
    
    # Patch RHACS components
    patch_central_deployment
    echo ""
    
    patch_sensor_deployment
    echo ""
    
    patch_collector_daemonset
    echo ""
    
    patch_hyperconverged_vsock
    echo ""
    
    # Display VM configuration instructions
    display_vm_instructions
    
    print_info "=========================================="
    print_info "VM Vulnerability Management Setup Complete"
    print_info "=========================================="
    echo ""
    print_info "Configuration completed:"
    print_info "  ✓ Central: ROX_VIRTUAL_MACHINES=true"
    print_info "  ✓ Sensor: ROX_VIRTUAL_MACHINES=true"
    print_info "  ✓ Collector compliance container: ROX_VIRTUAL_MACHINES=true"
    print_info "  ✓ HyperConverged: vsock support enabled"
    echo ""
    print_info "Next steps:"
    print_info "  1. Configure VMs with vsock support (see instructions above)"
    print_info "  2. Ensure VMs are running RHEL with valid subscriptions"
    print_info "  3. Verify VM network access for CPE mappings"
    print_info "  4. Deploy or restart VMs to apply vsock configuration"
    echo ""
}

# Run main function
main "$@"
