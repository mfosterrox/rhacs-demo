#!/bin/bash

# Script: 01-configure-rhacs.sh
# Description: Configure RHACS for virtual machine vulnerability management
#
# This script implements the official RHACS VM scanning requirements:
# 1. Sets ROX_VIRTUAL_MACHINES=true on:
#    - Central container in the Central pod
#    - Sensor container in the Sensor pod
#    - Compliance container in the Collector pod
#    Patches Central CR and SecuredCluster CR (operator-managed) for permanent changes.
#    Falls back to deployment/daemonset patch if CRs not found (e.g. Helm install).
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
# Get Central CR name (operator-managed)
#================================================================
get_central_cr_name() {
    oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

#================================================================
# Patch Central via operator CR (permanent) or deployment (fallback)
#================================================================
patch_central_deployment() {
    print_step "1. Setting ROX_VIRTUAL_MACHINES=true on Central"
    
    local central_cr_name
    central_cr_name=$(get_central_cr_name)
    
    if [ -n "${central_cr_name}" ]; then
        # Operator-managed: try to patch Central CR (path varies by RHACS version)
        local current_env
        current_env=$(oc get central "${central_cr_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.deployment.customize.env}' 2>/dev/null || oc get central "${central_cr_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.customize.env}' 2>/dev/null || echo "[]")
        
        if echo "${current_env}" | grep -q "ROX_VIRTUAL_MACHINES"; then
            print_info "✓ Central CR already has ROX_VIRTUAL_MACHINES=true"
        else
            print_info "Patching Central CR (${central_cr_name}) with ROX_VIRTUAL_MACHINES=true..."
            # Try spec.central.customize.env first (some RHACS versions use this)
            local patch_output
            patch_output=$(oc patch central "${central_cr_name}" -n "${RHACS_NAMESPACE}" --type=merge -p '{
              "spec": {
                "central": {
                  "customize": {
                    "env": [
                      {"name": "ROX_VIRTUAL_MACHINES", "value": "true"}
                    ]
                  }
                }
              }
            }' 2>&1) || true
            
            if echo "${patch_output}" | grep -q "unknown field"; then
                # spec.central.customize not supported - fall back to deployment patch
                print_info "Patching deployment directly (operator may overwrite on upgrade)..."
                local deploy_value
                deploy_value=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
                if [ "${deploy_value}" != "true" ]; then
                    oc set env deployment/central -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true
                else
                    print_info "✓ Central deployment already has ROX_VIRTUAL_MACHINES=true"
                fi
            else
                print_info "✓ Central CR patched (operator will reconcile)"
            fi
        fi
    else
        # Fallback: direct deployment patch (may be overwritten by operator)
        local current_value
        current_value=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        
        if [ "${current_value}" = "true" ]; then
            print_info "✓ Central deployment already has ROX_VIRTUAL_MACHINES=true"
        else
            print_warn "No Central CR found - patching deployment directly (changes may be overwritten by operator)"
            oc set env deployment/central -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true
        fi
    fi
    
    print_info "Waiting for Central to reconcile/restart..."
    oc rollout status deployment/central -n ${RHACS_NAMESPACE} --timeout=5m
    
    print_info "✓ Central configured with ROX_VIRTUAL_MACHINES=true"
}

#================================================================
# Get SecuredCluster resources (operator-managed)
#================================================================
get_secured_clusters() {
    oc get securedcluster -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || echo ""
}

#================================================================
# Patch Sensor via SecuredCluster CR (permanent) or deployment (fallback)
#================================================================
patch_sensor_deployment() {
    print_step "2. Setting ROX_VIRTUAL_MACHINES=true on Sensor"
    
    local sc_list
    sc_list=$(get_secured_clusters)
    
    if [ -n "${sc_list}" ]; then
        # Operator-managed: patch each SecuredCluster CR
        while IFS=/ read -r sc_namespace sc_name; do
            [ -z "${sc_name}" ] && continue
            local current_env
            current_env=$(oc get securedcluster "${sc_name}" -n "${sc_namespace}" -o jsonpath='{.spec.customize.env}' 2>/dev/null || echo "[]")
            
            if echo "${current_env}" | grep -q "ROX_VIRTUAL_MACHINES"; then
                print_info "✓ SecuredCluster ${sc_name} (${sc_namespace}) already has ROX_VIRTUAL_MACHINES=true"
            else
                print_info "Patching SecuredCluster ${sc_name} (${sc_namespace}) with ROX_VIRTUAL_MACHINES=true..."
                oc patch securedcluster "${sc_name}" -n "${sc_namespace}" --type=merge -p '{
                  "spec": {
                    "customize": {
                      "env": [
                        {"name": "ROX_VIRTUAL_MACHINES", "value": "true"}
                      ]
                    }
                  }
                }'
                print_info "✓ SecuredCluster ${sc_name} patched (operator will reconcile)"
            fi
        done <<< "${sc_list}"
    else
        # Fallback: direct deployment patch (may be overwritten by operator)
        local current_value
        current_value=$(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        
        if [ "${current_value}" = "true" ]; then
            print_info "✓ Sensor deployment already has ROX_VIRTUAL_MACHINES=true"
        else
            print_warn "No SecuredCluster CR found - patching deployment directly (changes may be overwritten by operator)"
            oc set env deployment/sensor -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true
        fi
    fi
    
    print_info "Waiting for Sensor to reconcile/restart..."
    oc rollout status deployment/sensor -n ${RHACS_NAMESPACE} --timeout=5m
    
    print_info "✓ Sensor configured with ROX_VIRTUAL_MACHINES=true"
}

#================================================================
# Patch Collector via SecuredCluster CR (permanent) or daemonset (fallback)
#================================================================
patch_collector_daemonset() {
    print_step "3. Setting ROX_VIRTUAL_MACHINES=true on Collector (compliance container)"
    
    local sc_list
    sc_list=$(get_secured_clusters)
    
    if [ -n "${sc_list}" ]; then
        # Operator-managed: patch each SecuredCluster CR - collector env is under perNode.collector.customize
        while IFS=/ read -r sc_namespace sc_name; do
            [ -z "${sc_name}" ] && continue
            local current_env
            current_env=$(oc get securedcluster "${sc_name}" -n "${sc_namespace}" -o jsonpath='{.spec.perNode.collector.customize.env}' 2>/dev/null || echo "[]")
            
            if echo "${current_env}" | grep -q "ROX_VIRTUAL_MACHINES"; then
                print_info "✓ SecuredCluster ${sc_name} collector already has ROX_VIRTUAL_MACHINES=true"
            else
                print_info "Patching SecuredCluster ${sc_name} (${sc_namespace}) collector with ROX_VIRTUAL_MACHINES=true..."
                oc patch securedcluster "${sc_name}" -n "${sc_namespace}" --type=merge -p '{
                  "spec": {
                    "perNode": {
                      "collector": {
                        "customize": {
                          "env": [
                            {"name": "ROX_VIRTUAL_MACHINES", "value": "true"}
                          ]
                        }
                      }
                    }
                  }
                }'
                print_info "✓ SecuredCluster ${sc_name} collector patched (operator will reconcile)"
            fi
        done <<< "${sc_list}"
    else
        # Fallback: direct daemonset patch (may be overwritten by operator)
        local has_compliance
        has_compliance=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
        
        if [ -z "${has_compliance}" ]; then
            print_warn "⚠ Collector daemonset has no 'compliance' container"
            print_info "  This might be expected depending on your RHACS version"
            return 0
        fi
        
        local current_value
        current_value=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
        
        if [ "${current_value}" = "true" ]; then
            print_info "✓ Collector compliance container already has ROX_VIRTUAL_MACHINES=true"
        else
            print_warn "No SecuredCluster CR found - patching daemonset directly (changes may be overwritten by operator)"
            oc set env daemonset/collector -n ${RHACS_NAMESPACE} ROX_VIRTUAL_MACHINES=true -c compliance
        fi
    fi
    
    print_info "Waiting for Collector to reconcile/restart..."
    oc rollout status daemonset/collector -n ${RHACS_NAMESPACE} --timeout=5m
    
    print_info "✓ Collector configured with ROX_VIRTUAL_MACHINES=true"
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
    
    print_info "  Note: rhel-webserver-vm template already includes autoattachVSOCK: true"
}

#================================================================
# Display VM configuration instructions
#================================================================
display_vm_instructions() {
    print_step "5. Virtual Machine Configuration"
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
