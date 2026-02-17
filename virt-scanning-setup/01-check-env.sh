#!/bin/bash

# Script: virt-scanning/01-check-env.sh
# Description: Verify RHACS VM vulnerability scanning environment

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
FAILED_CHECKS=0

#================================================================
# Check cluster connectivity
#================================================================
check_cluster_connectivity() {
    print_step "Checking cluster connectivity"
    
    if ! oc whoami &>/dev/null; then
        print_fail "Not connected to OpenShift cluster"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
    
    local cluster_url=$(oc whoami --show-server 2>/dev/null || echo 'unknown')
    print_pass "Connected to: ${cluster_url}"
}

#================================================================
# Check OpenShift Virtualization
#================================================================
check_virtualization() {
    print_step "Checking OpenShift Virtualization"
    
    if ! oc get namespace ${CNV_NAMESPACE} >/dev/null 2>&1; then
        print_fail "OpenShift Virtualization namespace not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
    
    if ! oc get csv -n ${CNV_NAMESPACE} 2>/dev/null | grep -q "OpenShift Virtualization.*Succeeded"; then
        print_fail "OpenShift Virtualization operator not ready"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
    
    print_pass "OpenShift Virtualization operator is running"
}

#================================================================
# Check VSOCK feature gate
#================================================================
check_vsock() {
    print_step "Checking VSOCK feature gate"
    
    local kubevirt_name=$(oc get kubevirt -n ${CNV_NAMESPACE} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${kubevirt_name}" ]; then
        print_fail "KubeVirt resource not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        return 1
    fi
    
    local feature_gates=$(oc get kubevirt ${kubevirt_name} -n ${CNV_NAMESPACE} -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")
    
    if echo "${feature_gates}" | grep -q "VSOCK"; then
        print_pass "VSOCK feature gate is enabled"
    else
        print_fail "VSOCK feature gate is NOT enabled"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

#================================================================
# Check RHACS components
#================================================================
check_rhacs_components() {
    print_step "Checking RHACS components"
    
    # Check Central
    if ! oc get deployment central -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_fail "Central deployment not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    else
        local central_ready=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "${central_ready}" -gt 0 ]; then
            print_pass "Central is running (${central_ready} replicas)"
        else
            print_fail "Central is not ready"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    fi
    
    # Check Sensor
    if ! oc get deployment sensor -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_fail "Sensor deployment not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    else
        local sensor_ready=$(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        if [ "${sensor_ready}" -gt 0 ]; then
            print_pass "Sensor is running (${sensor_ready} replicas)"
        else
            print_fail "Sensor is not ready"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    fi
    
    # Check Collector
    if ! oc get daemonset collector -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_fail "Collector daemonset not found"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    else
        local collector_desired=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
        local collector_ready=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
        if [ "${collector_ready}" -eq "${collector_desired}" ] && [ "${collector_ready}" -gt 0 ]; then
            print_pass "Collector is running (${collector_ready}/${collector_desired} pods ready)"
        else
            print_fail "Collector is not ready (${collector_ready}/${collector_desired} pods ready)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
    fi
}

#================================================================
# Check ROX_VIRTUAL_MACHINES feature flags
#================================================================
check_feature_flags() {
    print_step "Checking ROX_VIRTUAL_MACHINES feature flags"
    
    # Check Central
    local central_flag=$(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    if [ "${central_flag}" = "true" ]; then
        print_pass "Central: ROX_VIRTUAL_MACHINES=true"
    else
        print_fail "Central: ROX_VIRTUAL_MACHINES not set or not true"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    
    # Check Sensor
    local sensor_flag=$(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    if [ "${sensor_flag}" = "true" ]; then
        print_pass "Sensor: ROX_VIRTUAL_MACHINES=true"
    else
        print_fail "Sensor: ROX_VIRTUAL_MACHINES not set or not true"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    
    # Check Collector compliance container
    local collector_flag=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "")
    if [ "${collector_flag}" = "true" ]; then
        print_pass "Collector compliance: ROX_VIRTUAL_MACHINES=true"
    else
        print_fail "Collector compliance: ROX_VIRTUAL_MACHINES not set or not true"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

#================================================================
# Check collector networking configuration
#================================================================
check_collector_networking() {
    print_step "Checking collector networking configuration"
    
    # Check hostNetwork
    local host_network=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")
    if [ "${host_network}" = "true" ]; then
        print_pass "Collector hostNetwork: true"
    else
        print_fail "Collector hostNetwork: ${host_network} (should be true for VSOCK)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
    
    # Check DNS policy
    local dns_policy=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.dnsPolicy}' 2>/dev/null || echo "")
    if [ "${dns_policy}" = "ClusterFirstWithHostNet" ]; then
        print_pass "Collector dnsPolicy: ClusterFirstWithHostNet"
    else
        print_fail "Collector dnsPolicy: ${dns_policy} (should be ClusterFirstWithHostNet)"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

#================================================================
# Check sensor hostPort configuration
#================================================================
check_sensor_hostport() {
    print_step "Checking sensor hostPort configuration"
    
    local host_port=$(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="api")].hostPort}' 2>/dev/null || echo "")
    
    if [ -n "${host_port}" ]; then
        print_pass "Sensor hostPort configured: ${host_port}"
    else
        print_warn "Sensor hostPort not configured (may cause connectivity issues)"
        print_info "  Run ./01-configure-rhacs.sh to fix this"
    fi
    
    # Check collector sensor endpoint configuration
    local grpc_server=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="GRPC_SERVER")].value}' 2>/dev/null || echo "")
    local host_network=$(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")
    
    if [[ "${grpc_server}" == localhost:* ]]; then
        print_pass "Collector configured to use sensor via localhost: ${grpc_server}"
    elif [ "${host_network}" = "true" ] && [[ "${grpc_server}" != localhost:* ]]; then
        print_warn "Collector uses hostNetwork but GRPC_SERVER is not localhost"
        print_info "  Current: ${grpc_server}"
        print_info "  This may cause connectivity issues. Run ./01-configure-rhacs.sh to fix"
    fi
}

#================================================================
# Check collector logs for connectivity issues
#================================================================
check_collector_logs() {
    print_step "Checking collector logs for connectivity issues"
    
    local collector_pod=$(oc get pods -n ${RHACS_NAMESPACE} -l app=collector -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -z "${collector_pod}" ]; then
        print_warn "No collector pod found to check logs"
        return 0
    fi
    
    print_info "Checking logs from: ${collector_pod}"
    
    # Check for VSOCK connections
    if oc logs ${collector_pod} -n ${RHACS_NAMESPACE} -c compliance --tail=100 2>/dev/null | grep -q "Handling vsock connection"; then
        print_pass "VSOCK connections detected in collector logs"
    else
        print_info "No VSOCK connections in logs yet (VMs may not be deployed)"
    fi
    
    # Check for connection errors
    if oc logs ${collector_pod} -n ${RHACS_NAMESPACE} -c compliance --tail=100 2>/dev/null | grep -q "i/o timeout\|connection refused\|Error sending index report to sensor"; then
        print_fail "Connection errors detected in collector logs"
        print_info "  Sample errors:"
        oc logs ${collector_pod} -n ${RHACS_NAMESPACE} -c compliance --tail=100 2>/dev/null | grep -E "i/o timeout|connection refused|Error sending index report" | head -3 | sed 's/^/    /'
        print_info "  Run ./01-configure-rhacs.sh to fix networking"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    else
        print_pass "No connection errors in collector logs"
    fi
}

#================================================================
# Check for VMs
#================================================================
check_vms() {
    print_step "Checking for Virtual Machines"
    
    local vm_count=$(oc get vmi --all-namespaces 2>/dev/null | grep -v "NAMESPACE" | wc -l)
    
    if [ "${vm_count}" -gt 0 ]; then
        print_pass "Found ${vm_count} running VM(s)"
        oc get vmi --all-namespaces 2>/dev/null | sed 's/^/  /'
    else
        print_info "No VMs running yet"
    fi
}

#================================================================
# Main function
#================================================================
main() {
    echo "=========================================="
    echo "RHACS VM Scanning Environment Check"
    echo "=========================================="
    echo ""
    
    check_cluster_connectivity
    echo ""
    
    check_virtualization
    echo ""
    
    check_vsock
    echo ""
    
    check_rhacs_components
    echo ""
    
    check_feature_flags
    echo ""
    
    check_collector_networking
    echo ""
    
    check_sensor_hostport
    echo ""
    
    check_collector_logs
    echo ""
    
    check_vms
    echo ""
    
    # Summary
    echo "=========================================="
    if [ ${FAILED_CHECKS} -eq 0 ]; then
        print_pass "All checks passed! ✓"
    else
        print_fail "${FAILED_CHECKS} check(s) failed"
        echo ""
        print_info "To fix configuration issues, run:"
        print_info "  ./01-configure-rhacs.sh"
    fi
    echo "=========================================="
    
    exit ${FAILED_CHECKS}
}

# Run main function
main "$@"
