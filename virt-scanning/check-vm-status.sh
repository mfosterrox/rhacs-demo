#!/bin/bash

# Quick script to check if VM scanning is working end-to-end

set -euo pipefail

# Color codes
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

echo -e "${CYAN}=== RHACS VM Scanning Status Check ===${NC}"
echo ""

# 1. Check RHACS environment variables
echo -e "${CYAN}1. Checking RHACS Feature Flags...${NC}"
echo ""

echo "Central:"
oc get deployment central -n stackrox -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")]}' | jq -r '.name + "=" + .value'

echo ""
echo "Sensor:"
oc get deployment sensor -n stackrox -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")]}' | jq -r '.name + "=" + .value'

echo ""
echo "Collector (compliance container):"
oc get daemonset collector -n stackrox -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")]}' | jq -r '.name + "=" + .value'

echo ""
echo -e "${CYAN}2. Checking VMs Status...${NC}"
echo ""
oc get vmi -n default

echo ""
echo -e "${CYAN}3. Checking Collector for VSOCK activity...${NC}"
echo ""

COLLECTOR_POD=$(oc get pods -n stackrox -l app=collector -o jsonpath='{.items[0].metadata.name}')
echo "Collector pod: $COLLECTOR_POD"
echo ""

echo "Recent VSOCK/Virtual Machine related logs:"
oc logs -n stackrox $COLLECTOR_POD -c compliance --tail=100 | grep -i "vsock\|virtual\|vm\|relay" || echo "No VSOCK/VM related logs found"

echo ""
echo -e "${CYAN}4. Checking Sensor for VM data...${NC}"
echo ""

SENSOR_POD=$(oc get pods -n stackrox -l app=sensor -o jsonpath='{.items[0].metadata.name}')
echo "Sensor pod: $SENSOR_POD"
echo ""

echo "Recent Virtual Machine related logs:"
oc logs -n stackrox $SENSOR_POD --tail=100 | grep -i "virtual\|vm" || echo "No VM related logs found"

echo ""
echo -e "${CYAN}5. RHACS Central URL:${NC}"
CENTRAL_URL="https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')"
echo "$CENTRAL_URL"
echo ""
echo "Check for VMs at: Platform Configuration → Clusters → Virtual Machines"

echo ""
echo -e "${CYAN}=== Status Check Complete ===${NC}"
