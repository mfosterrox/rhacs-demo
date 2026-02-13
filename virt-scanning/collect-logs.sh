#!/bin/bash

# Script: collect-logs.sh
# Description: Collect all logs for RHACS VM vulnerability scanning debugging

set -euo pipefail

# Configuration
VM_NAME="${1:-rhel-webserver}"
NAMESPACE="${NAMESPACE:-default}"
RHACS_NAMESPACE="stackrox"
OUTPUT_DIR="./vm-scanning-logs"

echo "Collecting logs for VM scanning debugging..."
echo "Target VM: ${VM_NAME}"
echo ""

# Create output directory
mkdir -p ${OUTPUT_DIR}

#================================================================
# 1. Get VM and Node Information
#================================================================
echo "1. Collecting VM and node information..."

NODE=$(oc get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "Unknown")
VM_POD=$(oc get pods -n ${NAMESPACE} -l kubevirt.io/vm=${VM_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "Unknown")
VSOCK_CID=$(oc get vmi ${VM_NAME} -n ${NAMESPACE} -o jsonpath='{.status.VSOCKCID}' 2>/dev/null || echo "N/A")

echo "  VM: ${VM_NAME}"
echo "  Node: ${NODE}"
echo "  VM Pod: ${VM_POD}"
echo "  VSOCK CID: ${VSOCK_CID}"

cat > ${OUTPUT_DIR}/00-vm-info.txt <<EOF
VM Name: ${VM_NAME}
Node: ${NODE}
VM Pod: ${VM_POD}
VSOCK CID: ${VSOCK_CID}
Timestamp: $(date)
EOF

#================================================================
# 2. Collector Logs (from VM's node)
#================================================================
echo "2. Collecting Collector compliance container logs..."

if [ "${NODE}" != "Unknown" ]; then
    COLLECTOR_POD=$(oc get pods -n ${RHACS_NAMESPACE} -l app=collector -o jsonpath="{.items[?(@.spec.nodeName=='${NODE}')].metadata.name}" 2>/dev/null || echo "Unknown")
    
    echo "  Collector pod on node ${NODE}: ${COLLECTOR_POD}"
    
    if [ "${COLLECTOR_POD}" != "Unknown" ]; then
        oc logs -n ${RHACS_NAMESPACE} ${COLLECTOR_POD} -c compliance --tail=500 > ${OUTPUT_DIR}/01-collector-compliance.log 2>&1
        
        # Extract VM-related logs
        grep -iE "vsock|roxagent|virtual|vm" ${OUTPUT_DIR}/01-collector-compliance.log > ${OUTPUT_DIR}/01-collector-vm-activity.log 2>/dev/null || echo "No VM activity found" > ${OUTPUT_DIR}/01-collector-vm-activity.log
    fi
fi

#================================================================
# 3. All Collector Logs (for comparison)
#================================================================
echo "3. Collecting logs from all Collector pods..."

oc logs -n ${RHACS_NAMESPACE} -l app=collector -c compliance --tail=1000 > ${OUTPUT_DIR}/02-all-collectors.log 2>&1

# Extract errors
grep -i "error" ${OUTPUT_DIR}/02-all-collectors.log > ${OUTPUT_DIR}/02-collector-errors.log 2>/dev/null || echo "No errors found" > ${OUTPUT_DIR}/02-collector-errors.log

#================================================================
# 4. Sensor Logs
#================================================================
echo "4. Collecting Sensor logs..."

SENSOR_POD=$(oc get pods -n ${RHACS_NAMESPACE} -l app=sensor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "Unknown")

if [ "${SENSOR_POD}" != "Unknown" ]; then
    echo "  Sensor pod: ${SENSOR_POD}"
    oc logs -n ${RHACS_NAMESPACE} ${SENSOR_POD} --tail=500 > ${OUTPUT_DIR}/03-sensor.log 2>&1
    
    # Extract VM-related logs
    grep -iE "virtual|vm|roxagent" ${OUTPUT_DIR}/03-sensor.log > ${OUTPUT_DIR}/03-sensor-vm-activity.log 2>/dev/null || echo "No VM activity found" > ${OUTPUT_DIR}/03-sensor-vm-activity.log
fi

#================================================================
# 5. Central Logs
#================================================================
echo "5. Collecting Central logs..."

CENTRAL_POD=$(oc get pods -n ${RHACS_NAMESPACE} -l app=central -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "Unknown")

if [ "${CENTRAL_POD}" != "Unknown" ]; then
    echo "  Central pod: ${CENTRAL_POD}"
    oc logs -n ${RHACS_NAMESPACE} ${CENTRAL_POD} -c central --tail=500 > ${OUTPUT_DIR}/04-central.log 2>&1
    
    # Extract VM-related logs
    grep -iE "virtual|vm" ${OUTPUT_DIR}/04-central.log > ${OUTPUT_DIR}/04-central-vm-activity.log 2>/dev/null || echo "No VM activity found" > ${OUTPUT_DIR}/04-central-vm-activity.log
fi

#================================================================
# 6. VM Console/Compute Logs
#================================================================
echo "6. Collecting VM console logs..."

if [ "${VM_POD}" != "Unknown" ]; then
    oc logs ${VM_POD} -n ${NAMESPACE} -c compute --tail=500 > ${OUTPUT_DIR}/05-vm-console.log 2>&1
    
    # Extract roxagent and cloud-init logs
    grep -iE "roxagent|cloud-init|downloading|error" ${OUTPUT_DIR}/05-vm-console.log > ${OUTPUT_DIR}/05-vm-roxagent-activity.log 2>/dev/null || echo "No roxagent activity found" > ${OUTPUT_DIR}/05-vm-roxagent-activity.log
fi

#================================================================
# 7. RHACS Configuration Status
#================================================================
echo "7. Collecting RHACS configuration..."

cat > ${OUTPUT_DIR}/06-rhacs-config.txt <<EOF
=== RHACS Feature Flags ===
Central ROX_VIRTUAL_MACHINES: $(oc get deployment central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "NOT_SET")
Sensor ROX_VIRTUAL_MACHINES: $(oc get deployment sensor -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "NOT_SET")
Collector ROX_VIRTUAL_MACHINES: $(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}' 2>/dev/null || echo "NOT_SET")

=== Collector Network Configuration ===
hostNetwork: $(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.hostNetwork}' 2>/dev/null || echo "false")
dnsPolicy: $(oc get daemonset collector -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.template.spec.dnsPolicy}' 2>/dev/null || echo "Default")

=== VSOCK Configuration ===
$(oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | grep VSOCK || echo "VSOCK not enabled")

=== VM Status ===
$(oc get vmi -n ${NAMESPACE} -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,VSOCK:.status.VSOCKCID 2>/dev/null)
EOF

cat ${OUTPUT_DIR}/06-rhacs-config.txt

#================================================================
# Summary
#================================================================
echo ""
echo "============================================"
echo "Log collection complete!"
echo "============================================"
echo ""
echo "Logs saved to: ${OUTPUT_DIR}/"
echo ""
echo "Key files:"
echo "  00-vm-info.txt              - VM and node details"
echo "  01-collector-compliance.log - Collector logs from VM's node"
echo "  01-collector-vm-activity.log - Filtered VM activity"
echo "  02-all-collectors.log       - All Collector pods logs"
echo "  03-sensor.log               - Sensor logs"
echo "  04-central.log              - Central logs"
echo "  05-vm-console.log           - VM console/boot logs"
echo "  05-vm-roxagent-activity.log - Filtered roxagent activity"
echo "  06-rhacs-config.txt         - RHACS configuration status"
echo ""
echo "To check for roxagent inside VM, you need console access:"
echo "  virtctl console ${VM_NAME} -n ${NAMESPACE}"
echo "  Login: cloud-user"
echo "  Password: redhat (after redeploying VMs with updated scripts)"
echo ""
