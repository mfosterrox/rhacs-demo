#!/bin/bash

# Script: 01-configure-rhacs.sh
# Description: Configure OpenShift Virtualization for RHACS VM vulnerability scanning
#
# ROX_VIRTUAL_MACHINES=true is now set in basic-setup/01-verify-rhacs-install.sh as part of
# the version update (single restart). This script only:
# 1. Verifies OpenShift Virtualization operator is installed
# 2. Enables VSOCK support via HyperConverged resource
# 3. Provides VM configuration instructions

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
readonly CNV_NAMESPACE="openshift-cnv"
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

#================================================================
# Apply ROX_VIRTUAL_MACHINES to missing components (fallback when basic-setup not run)
#================================================================
apply_rhacs_vm_configuration() {
    print_step "Applying ROX_VIRTUAL_MACHINES=true to missing components..."
    
    local sc_list
    sc_list=$(oc get securedcluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
    
    if [ -n "${sc_list}" ]; then
        while IFS=/ read -r sc_namespace sc_name; do
            [ -z "${sc_name}" ] && continue
            local sensor_env
            sensor_env=$(oc get securedcluster "${sc_name}" -n "${sc_namespace}" -o jsonpath='{.spec.customize.env}' 2>/dev/null || echo "[]")
            if ! echo "${sensor_env}" | grep -q "ROX_VIRTUAL_MACHINES"; then
                print_info "Patching SecuredCluster ${sc_name} (Sensor)..."
                oc patch securedcluster "${sc_name}" -n "${sc_namespace}" --type=merge -p '{"spec":{"customize":{"env":[{"name":"ROX_VIRTUAL_MACHINES","value":"true"}]}}}' 2>/dev/null || \
                oc set env deployment/sensor -n "${sc_namespace}" ROX_VIRTUAL_MACHINES=true 2>/dev/null || true
            fi
            local collector_env
            collector_env=$(oc get securedcluster "${sc_name}" -n "${sc_namespace}" -o jsonpath='{.spec.perNode.collector.customize.env}' 2>/dev/null || echo "[]")
            if ! echo "${collector_env}" | grep -q "ROX_VIRTUAL_MACHINES"; then
                print_info "Patching SecuredCluster ${sc_name} (Collector)..."
                oc patch securedcluster "${sc_name}" -n "${sc_namespace}" --type=merge -p '{"spec":{"perNode":{"collector":{"customize":{"env":[{"name":"ROX_VIRTUAL_MACHINES","value":"true"}]}}}}}' 2>/dev/null || true
            fi
            local has_compliance
            has_compliance=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
            if [ -n "${has_compliance}" ]; then
                local compliance_val
                compliance_val=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
                if [ "${compliance_val}" != "true" ]; then
                    print_info "Patching Collector compliance container..."
                    oc set env daemonset/collector -n "${sc_namespace}" ROX_VIRTUAL_MACHINES=true -c compliance 2>/dev/null || true
                fi
            fi
        done <<< "${sc_list}"
    else
        oc set env deployment/sensor -n "${RHACS_NAMESPACE}" ROX_VIRTUAL_MACHINES=true 2>/dev/null || true
        local has_compliance
        has_compliance=$(oc get daemonset collector -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
        [ -n "${has_compliance}" ] && oc set env daemonset/collector -n "${RHACS_NAMESPACE}" ROX_VIRTUAL_MACHINES=true -c compliance 2>/dev/null || true
    fi
    
    # Central (if not in SecuredCluster flow)
    local central_cr
    central_cr=$(oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${central_cr}" ]; then
        local central_env
        central_env=$(oc get central "${central_cr}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.customize.env}' 2>/dev/null || echo "[]")
        if ! echo "${central_env}" | grep -q "ROX_VIRTUAL_MACHINES"; then
            print_info "Patching Central..."
            oc patch central "${central_cr}" -n "${RHACS_NAMESPACE}" --type=merge -p '{"spec":{"central":{"customize":{"env":[{"name":"ROX_VIRTUAL_MACHINES","value":"true"}]}}}}' 2>/dev/null || \
            oc set env deployment/central -n "${RHACS_NAMESPACE}" ROX_VIRTUAL_MACHINES=true 2>/dev/null || true
        fi
    else
        local central_val
        central_val=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="central")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        [ "${central_val}" != "true" ] && oc set env deployment/central -n "${RHACS_NAMESPACE}" ROX_VIRTUAL_MACHINES=true 2>/dev/null || true
    fi
    
    print_info "Waiting for operator to reconcile (45s)..."
    sleep 45
}

#================================================================
# Verify ROX_VIRTUAL_MACHINES is configured (set by basic-setup)
#================================================================
verify_rhacs_vm_configuration() {
    print_step "Verifying RHACS VM configuration (ROX_VIRTUAL_MACHINES=true)"
    
    local missing=()
    
    local central_val
    central_val=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="central")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    if [ "${central_val}" != "true" ]; then
        missing+=("Central")
    fi
    
    # Find Sensor namespace and check ROX_VIRTUAL_MACHINES
    local sensor_ns="${RHACS_NAMESPACE}"
    local sc_ns
    sc_ns=$(oc get securedcluster -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
    [ -n "${sc_ns}" ] && sensor_ns="${sc_ns}"
    local sensor_val
    sensor_val=$(oc get deployment sensor -n "${sensor_ns}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="sensor")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    if [ "${sensor_val}" != "true" ]; then
        missing+=("Sensor")
    fi
    
    local collector_val
    collector_val=$(oc get daemonset collector -n "${sensor_ns}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    if [ -z "${collector_val}" ] || [ "${collector_val}" != "true" ]; then
        local has_compliance
        has_compliance=$(oc get daemonset collector -n "${sensor_ns}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
        if [ -n "${has_compliance}" ]; then
            missing+=("Collector compliance container")
        fi
    fi
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_warn "RHACS VM configuration incomplete. Missing ROX_VIRTUAL_MACHINES=true on: ${missing[*]}"
        echo ""
        print_info "Applying configuration to missing components..."
        apply_rhacs_vm_configuration
        echo ""
        print_info "Re-verifying..."
        missing=()
        central_val=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="central")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        [ "${central_val}" != "true" ] && missing+=("Central")
        sensor_ns="${RHACS_NAMESPACE}"
        sc_ns=$(oc get securedcluster -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
        [ -n "${sc_ns}" ] && sensor_ns="${sc_ns}"
        sensor_val=$(oc get deployment sensor -n "${sensor_ns}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="sensor")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        [ "${sensor_val}" != "true" ] && missing+=("Sensor")
        collector_val=$(oc get daemonset collector -n "${sensor_ns}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        has_compliance=$(oc get daemonset collector -n "${sensor_ns}" -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
        if [ -n "${has_compliance}" ] && { [ -z "${collector_val}" ] || [ "${collector_val}" != "true" ]; }; then
            missing+=("Collector compliance container")
        fi
        if [ ${#missing[@]} -gt 0 ]; then
            print_error "Configuration applied but still missing: ${missing[*]}"
            print_info "Run basic-setup: cd ~/rhacs-demo && ./basic-setup/install.sh"
            exit 1
        fi
        print_info "✓ Configuration applied successfully"
        return
    fi
    
    print_info "✓ Central, Sensor, Collector compliance container have ROX_VIRTUAL_MACHINES=true"
}

#================================================================
# Patch HyperConverged resource for vsock
#================================================================
patch_hyperconverged_vsock() {
    print_step "1. Patching HyperConverged resource to enable vsock support"
    
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
    
    print_info "  Note: rhel-webserver-vm template already includes autoattachVSOCK: true"
}

#================================================================
# Display VM configuration instructions
#================================================================
display_vm_instructions() {
    print_step "2. Virtual Machine Configuration"
    echo ""
    
    print_info "VM requirements for vulnerability scanning:"
    print_info "  • Must run Red Hat Enterprise Linux (RHEL)"
    print_info "  • RHEL must have valid subscription"
    print_info "  • Network access for CPE mappings"
    print_info "  • autoattachVSOCK: true (included in rhel-webserver-vm template)"
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
    
    # Verify ROX_VIRTUAL_MACHINES is configured (basic-setup does this as part of version update)
    verify_rhacs_vm_configuration
    echo ""
    
    # Verify OpenShift Virtualization is installed
    if ! oc get namespace ${CNV_NAMESPACE} >/dev/null 2>&1; then
        print_error "OpenShift Virtualization not installed"
        print_error "Install OpenShift Virtualization operator first"
        exit 1
    fi
    
    # Check for OpenShift Virtualization (kubevirt-hyperconverged) CSV in Succeeded phase
    if ! oc get csv -n ${CNV_NAMESPACE} 2>/dev/null | grep -E "kubevirt-hyperconverged|OpenShift Virtualization" | grep -q Succeeded; then
        print_error "OpenShift Virtualization operator not ready"
        exit 1
    fi
    
    print_info "✓ OpenShift Virtualization operator detected"
    echo ""
    
    # Enable VSOCK (ROX_VIRTUAL_MACHINES is set in basic-setup)
    patch_hyperconverged_vsock
    echo ""
    
    # Display VM configuration instructions
    display_vm_instructions
    
    print_info "=========================================="
    print_info "VM Vulnerability Management Setup Complete"
    print_info "=========================================="
    echo ""
    print_info "Configuration completed:"
    print_info "  ✓ HyperConverged: vsock support enabled"
    print_info "  (ROX_VIRTUAL_MACHINES=true set in basic-setup)"
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
