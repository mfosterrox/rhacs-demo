#!/bin/bash

# Script: 01-check-env.sh
# Description: Check prerequisites for RHACS virtual machine vulnerability management

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
print_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
print_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
readonly CNV_NAMESPACE="openshift-cnv"

# Track overall status
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

#================================================================
# Check feature flag on Central
#================================================================
check_central_feature_flag() {
    print_step "1. Checking Central deployment for ROX_VIRTUAL_MACHINES feature flag"
    
    local central_env=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    
    if [ "${central_env}" = "true" ]; then
        print_pass "✓ Central has ROX_VIRTUAL_MACHINES=true"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        print_fail "✗ Central missing ROX_VIRTUAL_MACHINES=true environment variable"
        print_info "  Current value: ${central_env:-not set}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
}

#================================================================
# Check feature flag on Sensor
#================================================================
check_sensor_feature_flag() {
    print_step "2. Checking Sensor deployment for ROX_VIRTUAL_MACHINES feature flag"
    
    local sensor_env=$(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    
    if [ "${sensor_env}" = "true" ]; then
        print_pass "✓ Sensor has ROX_VIRTUAL_MACHINES=true"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        print_fail "✗ Sensor missing ROX_VIRTUAL_MACHINES=true environment variable"
        print_info "  Current value: ${sensor_env:-not set}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
}

#================================================================
# Check feature flag on Collector compliance container
#================================================================
check_collector_feature_flag() {
    print_step "3. Checking Collector daemonset compliance container for ROX_VIRTUAL_MACHINES"
    
    # Check if compliance container exists
    local has_compliance=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].name}' 2>/dev/null || echo "")
    
    if [ -z "${has_compliance}" ]; then
        print_fail "✗ Collector daemonset has no 'compliance' container"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
    
    local compliance_env=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    
    if [ "${compliance_env}" = "true" ]; then
        print_pass "✓ Collector compliance container has ROX_VIRTUAL_MACHINES=true"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        print_fail "✗ Collector compliance container missing ROX_VIRTUAL_MACHINES=true"
        print_info "  Current value: ${compliance_env:-not set}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
}

#================================================================
# Check OpenShift Virtualization operator
#================================================================
check_virtualization_operator() {
    print_step "4. Checking OpenShift Virtualization operator installation"
    
    # Check if CNV namespace exists
    if ! oc get namespace ${CNV_NAMESPACE} >/dev/null 2>&1; then
        print_fail "✗ OpenShift Virtualization namespace not found: ${CNV_NAMESPACE}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
    
    # Check for CSV
    local csv_phase=$(oc get csv -n ${CNV_NAMESPACE} -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Virtualization")].status.phase}' 2>/dev/null || echo "")
    
    if [ "${csv_phase}" = "Succeeded" ]; then
        local csv_version=$(oc get csv -n ${CNV_NAMESPACE} -o jsonpath='{.items[?(@.spec.displayName=="OpenShift Virtualization")].spec.version}' 2>/dev/null)
        print_pass "✓ OpenShift Virtualization operator installed (version: ${csv_version})"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        print_fail "✗ OpenShift Virtualization operator not ready"
        print_info "  Phase: ${csv_phase:-not found}"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
}

#================================================================
# Check HyperConverged resource vsock support
#================================================================
check_hyperconverged_vsock() {
    print_step "5. Checking HyperConverged resource for vsock support"
    
    # Check if HyperConverged resource exists
    if ! oc get hyperconverged -n ${CNV_NAMESPACE} >/dev/null 2>&1; then
        print_fail "✗ HyperConverged resource not found"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
    
    # Get HyperConverged name
    local hco_name=$(oc get hyperconverged -n ${CNV_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${hco_name}" ]; then
        print_fail "✗ No HyperConverged resource found"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
        return 1
    fi
    
    # Check vsock support
    local vsock_enabled=$(oc get hyperconverged ${hco_name} -n ${CNV_NAMESPACE} -o jsonpath='{.spec.featureGates.enableCommonBootImageImport}' 2>/dev/null || echo "")
    
    # Note: vsock support might be under different fields, check common ones
    local has_vsock="false"
    
    # Check if any VMs or the HCO mentions vsock
    if oc get hyperconverged ${hco_name} -n ${CNV_NAMESPACE} -o yaml 2>/dev/null | grep -qi "vsock"; then
        has_vsock="true"
    fi
    
    if [ "${has_vsock}" = "true" ]; then
        print_pass "✓ HyperConverged resource has vsock support enabled"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
        return 0
    else
        print_warn "⚠ Could not verify vsock support in HyperConverged resource"
        print_info "  Resource: ${hco_name}"
        print_info "  Manual verification recommended"
        CHECKS_WARNED=$((CHECKS_WARNED + 1))
        return 0
    fi
}

#================================================================
# Check for virtual machines with vsock
#================================================================
check_vm_vsock_support() {
    print_step "6. Checking virtual machines for vsock support"
    
    # Get all VMs
    local vm_count=$(oc get vm -A --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "${vm_count}" -eq 0 ]; then
        print_warn "⚠ No virtual machines found in the cluster"
        CHECKS_WARNED=$((CHECKS_WARNED + 1))
        return 0
    fi
    
    print_info "Found ${vm_count} virtual machine(s)"
    
    # Check each VM for vsock support
    local vms_with_vsock=0
    local vms_without_vsock=0
    
    while IFS= read -r line; do
        local namespace=$(echo "${line}" | awk '{print $1}')
        local name=$(echo "${line}" | awk '{print $2}')
        
        local has_vsock=$(oc get vm ${name} -n ${namespace} -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}' 2>/dev/null || echo "")
        
        if [ "${has_vsock}" = "true" ]; then
            print_info "  ✓ ${namespace}/${name} - vsock enabled"
            vms_with_vsock=$((vms_with_vsock + 1))
        else
            print_warn "  ✗ ${namespace}/${name} - vsock not enabled"
            vms_without_vsock=$((vms_without_vsock + 1))
        fi
    done < <(oc get vm -A --no-headers 2>/dev/null || true)
    
    if [ ${vms_with_vsock} -gt 0 ]; then
        print_pass "✓ ${vms_with_vsock} VM(s) have vsock support"
        if [ ${vms_without_vsock} -gt 0 ]; then
            print_warn "⚠ ${vms_without_vsock} VM(s) need vsock configuration"
            CHECKS_WARNED=$((CHECKS_WARNED + 1))
        else
            CHECKS_PASSED=$((CHECKS_PASSED + 1))
        fi
    else
        print_fail "✗ No VMs have vsock support configured"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
    
    return 0
}

#================================================================
# Check for RHEL VMs
#================================================================
check_rhel_vms() {
    print_step "7. Checking for RHEL-based virtual machines"
    
    local vm_count=$(oc get vm -A --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [ "${vm_count}" -eq 0 ]; then
        print_warn "⚠ No virtual machines found to check"
        CHECKS_WARNED=$((CHECKS_WARNED + 1))
        return 0
    fi
    
    print_info "Checking ${vm_count} VM(s) for RHEL OS..."
    
    # Check VM labels/annotations for OS info
    local rhel_vms=0
    
    while IFS= read -r line; do
        local namespace=$(echo "${line}" | awk '{print $1}')
        local name=$(echo "${line}" | awk '{print $2}')
        
        # Check labels for OS info
        local labels=$(oc get vm ${name} -n ${namespace} -o jsonpath='{.metadata.labels}' 2>/dev/null || echo "")
        
        if echo "${labels}" | grep -qi "rhel\|red.hat"; then
            print_info "  ✓ ${namespace}/${name} - appears to be RHEL"
            rhel_vms=$((rhel_vms + 1))
        else
            print_info "  ? ${namespace}/${name} - OS unknown (check manually)"
        fi
    done < <(oc get vm -A --no-headers 2>/dev/null || true)
    
    if [ ${rhel_vms} -gt 0 ]; then
        print_pass "✓ Found ${rhel_vms} RHEL-based VM(s)"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        print_warn "⚠ Could not verify RHEL VMs (manual check recommended)"
        CHECKS_WARNED=$((CHECKS_WARNED + 1))
    fi
    
    return 0
}

#================================================================
# Check network connectivity for VMs
#================================================================
check_vm_network_access() {
    print_step "8. Checking virtual machine network access"
    
    # This is a warning-only check as we can't easily verify from outside the VM
    print_warn "⚠ Manual verification required for VM network access"
    print_info "  VMs must have network access to download:"
    print_info "  - Repository-to-CPE mappings"
    print_info "  - RHEL subscription validation"
    print_info ""
    print_info "  To verify, access each VM and test:"
    print_info "    curl -I https://access.redhat.com"
    
    CHECKS_WARNED=$((CHECKS_WARNED + 1))
    return 0
}

#================================================================
# Check for metal nodes (recommended)
#================================================================
check_metal_nodes() {
    print_step "9. Checking for metal nodes (recommended for VM hosting)"
    
    # Check node labels for metal/baremetal
    local metal_nodes=$(oc get nodes -l 'node-role.kubernetes.io/worker' -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.metal}{"\n"}{end}' 2>/dev/null | grep -c "true" || echo "0")
    
    # Also check for baremetal provider
    local baremetal_nodes=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}' 2>/dev/null | grep -c "baremetalmachine" || echo "0")
    
    local total_metal=$((metal_nodes + baremetal_nodes))
    
    if [ ${total_metal} -gt 0 ]; then
        print_pass "✓ Found ${total_metal} metal/baremetal node(s)"
        print_info "  Metal nodes provide optimal VM performance"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        print_warn "⚠ No metal nodes detected"
        print_info "  VMs will run on available nodes but performance may vary"
        CHECKS_WARNED=$((CHECKS_WARNED + 1))
    fi
    
    return 0
}

#================================================================
# Summary report
#================================================================
print_summary() {
    echo ""
    print_step "==============================================="
    print_step "Virtual Machine Vulnerability Management Check"
    print_step "==============================================="
    echo ""
    
    print_info "Results:"
    print_pass "  Passed: ${CHECKS_PASSED}"
    
    if [ ${CHECKS_WARNED} -gt 0 ]; then
        print_warn "  Warnings: ${CHECKS_WARNED}"
    fi
    
    if [ ${CHECKS_FAILED} -gt 0 ]; then
        print_fail "  Failed: ${CHECKS_FAILED}"
    fi
    
    echo ""
    
    if [ ${CHECKS_FAILED} -eq 0 ]; then
        print_pass "✓ Environment is ready for virtual machine vulnerability scanning"
        echo ""
        print_info "Next steps:"
        print_info "  1. Ensure VMs have vsock enabled: spec.domain.devices.autoattachVSOCK: true"
        print_info "  2. Verify VMs are running RHEL with valid subscriptions"
        print_info "  3. Confirm VMs have network access for CPE mappings"
        echo ""
        return 0
    else
        print_fail "✗ Environment has ${CHECKS_FAILED} critical issue(s)"
        echo ""
        print_info "Required fixes:"
        print_info "  Run: ./install.sh to configure feature flags and prerequisites"
        echo ""
        return 1
    fi
}

#================================================================
# Main function
#================================================================
main() {
    print_info "=========================================="
    print_info "RHACS VM Vulnerability Management"
    print_info "Prerequisites Check"
    print_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    echo ""
    
    # Run all checks
    check_central_feature_flag || true
    echo ""
    
    check_sensor_feature_flag || true
    echo ""
    
    check_collector_feature_flag || true
    echo ""
    
    check_virtualization_operator || true
    echo ""
    
    check_hyperconverged_vsock || true
    echo ""
    
    check_vm_vsock_support || true
    echo ""
    
    check_rhel_vms || true
    echo ""
    
    check_vm_network_access || true
    echo ""
    
    check_metal_nodes || true
    
    # Print summary
    print_summary
}

# Run main function
main "$@"
