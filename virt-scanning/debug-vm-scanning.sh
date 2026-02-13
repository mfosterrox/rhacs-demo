#!/bin/bash

# Script: debug-vm-scanning.sh
# Description: Debug RHACS VM vulnerability scanning issues

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_header() { echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"; }

NAMESPACE="${NAMESPACE:-default}"

echo ""
print_header
print_step "RHACS VM Scanning Debug Tool"
print_header
echo ""

#================================================================
# Step 1: Check RHACS Feature Flags
#================================================================
check_rhacs_feature_flags() {
    print_step "1. Checking RHACS Feature Flags"
    echo ""
    
    print_info "Checking Central deployment..."
    local central_flag=$(oc get deployment central -n stackrox \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "NOT_SET")
    echo "  Central ROX_VIRTUAL_MACHINES: ${central_flag}"
    
    print_info "Checking Sensor deployment..."
    local sensor_flag=$(oc get deployment sensor -n stackrox \
        -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "NOT_SET")
    echo "  Sensor ROX_VIRTUAL_MACHINES: ${sensor_flag}"
    
    print_info "Checking Collector compliance container..."
    local collector_flag=$(oc get daemonset collector -n stackrox \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "NOT_SET")
    echo "  Collector compliance ROX_VIRTUAL_MACHINES: ${collector_flag}"
    
    echo ""
    if [ "${central_flag}" == "true" ] && [ "${sensor_flag}" == "true" ] && [ "${collector_flag}" == "true" ]; then
        print_info "✓ All RHACS components have VM feature flag enabled"
    else
        print_error "✗ Missing feature flags - run ./install.sh to configure"
    fi
    echo ""
}

#================================================================
# Step 2: Check VSOCK Configuration
#================================================================
check_vsock_configuration() {
    print_step "2. Checking VSOCK Configuration"
    echo ""
    
    print_info "Checking KubeVirt feature gates..."
    local kubevirt_name=$(oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [ -n "${kubevirt_name}" ]; then
        local vsock_enabled=$(oc get kubevirt "${kubevirt_name}" -n openshift-cnv \
            -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | grep -o "VSOCK" || echo "")
        
        if [ -n "${vsock_enabled}" ]; then
            print_info "✓ VSOCK feature gate is enabled in KubeVirt"
        else
            print_error "✗ VSOCK feature gate is NOT enabled - run ./install.sh"
        fi
    else
        print_error "✗ KubeVirt not found"
    fi
    echo ""
}

#================================================================
# Step 3: Check VM Status and VSOCK CID
#================================================================
check_vm_status() {
    print_step "3. Checking Virtual Machine Status"
    echo ""
    
    print_info "VMs and their VSOCK CIDs:"
    echo ""
    printf "  %-25s %-15s %-15s\n" "VM NAME" "STATUS" "VSOCK CID"
    printf "  %-25s %-15s %-15s\n" "-------" "------" "---------"
    
    for vm in $(oc get vm -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local phase=$(oc get vmi "${vm}" -n ${NAMESPACE} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotRunning")
        local vsock_cid=$(oc get vmi "${vm}" -n ${NAMESPACE} -o jsonpath='{.status.VSOCKCID}' 2>/dev/null || echo "N/A")
        local autoattach=$(oc get vm "${vm}" -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}' 2>/dev/null || echo "false")
        
        printf "  %-25s %-15s %-15s" "${vm}" "${phase}" "${vsock_cid}"
        
        if [ "${autoattach}" != "true" ]; then
            echo " (⚠️  autoattachVSOCK: false)"
        else
            echo ""
        fi
    done
    echo ""
}

#================================================================
# Step 4: Check Cloud-Init and roxagent
#================================================================
check_vm_roxagent() {
    print_step "4. Checking roxagent Status in VMs"
    echo ""
    
    print_info "To check roxagent in each VM, run these commands:"
    echo ""
    
    for vm in $(oc get vm -n ${NAMESPACE} -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        echo "  VM: ${vm}"
        echo "  ---"
        echo "  # Access VM console:"
        echo "  virtctl console ${vm} -n ${NAMESPACE}"
        echo ""
        echo "  # Inside VM, check cloud-init status:"
        echo "  cloud-init status"
        echo ""
        echo "  # Check if roxagent is installed:"
        echo "  ls -la /opt/roxagent/roxagent"
        echo ""
        echo "  # Check roxagent service status:"
        echo "  systemctl status roxagent"
        echo ""
        echo "  # Check roxagent logs:"
        echo "  journalctl -u roxagent -n 50"
        echo ""
        echo "  # Check if roxagent is running:"
        echo "  ps aux | grep roxagent"
        echo ""
    done
}

#================================================================
# Step 5: Quick VM Check Script
#================================================================
generate_vm_check_script() {
    print_step "5. Quick VM Check Script"
    echo ""
    
    local vm_name=${1:-rhel-roxagent-vm}
    
    print_info "Run this to quickly check a VM (${vm_name}):"
    echo ""
    
    cat <<'EOF'
# Create a helper script to check VM
cat > /tmp/check-roxagent.sh <<'VMSCRIPT'
#!/bin/bash
echo "=== Cloud-init Status ==="
cloud-init status --long

echo ""
echo "=== roxagent Binary ==="
ls -lh /opt/roxagent/roxagent 2>&1

echo ""
echo "=== roxagent Service ==="
systemctl status roxagent --no-pager

echo ""
echo "=== roxagent Process ==="
ps aux | grep -v grep | grep roxagent

echo ""
echo "=== roxagent Recent Logs ==="
journalctl -u roxagent --no-pager -n 20

echo ""
echo "=== Network Connectivity ==="
curl -I https://access.redhat.com 2>&1 | head -3

echo ""
echo "=== RHEL Subscription Status ==="
subscription-manager status 2>&1 | head -5

echo ""
echo "=== DNF Package Count ==="
dnf list installed 2>&1 | wc -l
VMSCRIPT

# Copy to VM and execute
oc cp /tmp/check-roxagent.sh default/REPLACE_VM_NAME:/tmp/check-roxagent.sh
virtctl ssh cloud-user@REPLACE_VM_NAME -n default "sudo bash /tmp/check-roxagent.sh"
EOF
    
    echo ""
    print_info "Replace REPLACE_VM_NAME with your VM name"
    echo ""
}

#================================================================
# Step 6: Check Collector Logs
#================================================================
check_collector_logs() {
    print_step "6. Checking Collector Logs for VM Activity"
    echo ""
    
    print_info "Check Collector compliance container logs for VM scanning:"
    echo ""
    echo "  # Get collector pods:"
    echo "  oc get pods -n stackrox -l app=collector"
    echo ""
    echo "  # Check compliance container logs for VSOCK/VM activity:"
    echo "  oc logs -n stackrox -l app=collector -c compliance --tail=100 | grep -i 'virtual\\|vsock\\|vm'"
    echo ""
    echo "  # Check for roxagent connections:"
    echo "  oc logs -n stackrox -l app=collector -c compliance --tail=200 | grep -i 'roxagent\\|report'"
    echo ""
}

#================================================================
# Step 7: Check Sensor Logs
#================================================================
check_sensor_logs() {
    print_step "7. Checking Sensor Logs for VM Data"
    echo ""
    
    print_info "Check Sensor logs for VM vulnerability data:"
    echo ""
    echo "  # Get sensor pod:"
    echo "  oc get pods -n stackrox -l app=sensor"
    echo ""
    echo "  # Check sensor logs for VM activity:"
    echo "  oc logs -n stackrox -l app=sensor --tail=100 | grep -i 'virtual\\|vm\\|roxagent'"
    echo ""
}

#================================================================
# Step 8: Common Issues and Solutions
#================================================================
show_common_issues() {
    print_step "8. Common Issues and Solutions"
    echo ""
    
    cat <<'EOF'
Issue 1: VMs showing "Not available" for scan data
-----------------------------------------------
Cause: roxagent hasn't completed first scan yet
Solution: 
  - VMs take 5-10 minutes to fully boot
  - Cloud-init must complete package installation
  - roxagent runs first scan after all packages installed
  - Check: virtctl console <vm-name> → systemctl status roxagent

Issue 2: roxagent service not running
-----------------------------------------------
Cause: Cloud-init may still be running or failed
Solution:
  - Check: cloud-init status
  - Check: tail -f /var/log/cloud-init-output.log
  - Manually start: sudo systemctl start roxagent

Issue 3: No VSOCK CID assigned to VM
-----------------------------------------------
Cause: VSOCK feature gate not enabled or VM missing autoattachVSOCK
Solution:
  - Check KubeVirt has VSOCK in feature gates
  - Check VM has spec.template.spec.domain.devices.autoattachVSOCK: true
  - Restart VM if needed

Issue 4: VMs need RHEL subscription
-----------------------------------------------
Cause: DNF repos require valid RHEL subscription
Solution:
  Inside VM:
    subscription-manager register --username <user> --password <pass>
    subscription-manager attach --auto
    subscription-manager status

Issue 5: Collector not receiving VM data
-----------------------------------------------
Cause: Feature flags not set or Collector needs restart
Solution:
  - Verify ROX_VIRTUAL_MACHINES=true on all components
  - Restart collector: oc rollout restart daemonset/collector -n stackrox
  - Check collector logs for VSOCK connections

Issue 6: Network connectivity from VM
-----------------------------------------------
Cause: VM can't reach internet for CPE mappings
Solution:
  Inside VM:
    curl -I https://access.redhat.com
    ping 8.8.8.8
  Check network configuration and firewall rules
EOF
    echo ""
}

#================================================================
# Step 9: Manual roxagent Test
#================================================================
show_manual_test() {
    print_step "9. Manual roxagent Test"
    echo ""
    
    print_info "To manually test roxagent inside a VM:"
    echo ""
    
    cat <<'EOF'
# Access VM
virtctl console rhel-roxagent-vm -n default

# Inside VM, run roxagent manually with verbose output
sudo /opt/roxagent/roxagent --verbose

# This will:
# - Scan installed packages
# - Generate vulnerability report
# - Send via VSOCK to Collector
# - Print output to stdout

# Expected output:
# - Package inventory list
# - CVE report
# - Success/error messages

# If it works manually but not as service:
sudo systemctl restart roxagent
sudo journalctl -u roxagent -f
EOF
    echo ""
}

#================================================================
# Main Execution
#================================================================
main() {
    check_rhacs_feature_flags
    check_vsock_configuration
    check_vm_status
    check_vm_roxagent
    generate_vm_check_script
    check_collector_logs
    check_sensor_logs
    show_common_issues
    show_manual_test
    
    echo ""
    print_header
    print_info "Debug information complete"
    print_header
    echo ""
    print_info "Next steps:"
    echo "  1. Check if VMs have completed cloud-init"
    echo "  2. Verify roxagent service is running in VMs"
    echo "  3. Check Collector logs for VSOCK connections"
    echo "  4. Ensure VMs have valid RHEL subscriptions"
    echo "  5. Wait 10-15 minutes for first scan cycle"
    echo ""
}

main "$@"
