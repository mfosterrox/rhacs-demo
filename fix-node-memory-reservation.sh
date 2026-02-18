#!/bin/bash
#
# OpenShift Node Memory Reservation Fix
# 
# This script fixes the "System memory usage exceeds 95% of reservation" issue
# by creating a KubeletConfig to increase system-reserved memory
#
# Reference: https://docs.openshift.com/container-platform/latest/nodes/nodes/nodes-nodes-managing.html
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

#================================================================
# Configuration
#================================================================

# Node role to apply this to (master, worker, or specific label)
NODE_ROLE="${NODE_ROLE:-master}"

# Custom values (optional - will be auto-calculated if not set)
SYSTEM_RESERVED_MEMORY="${SYSTEM_RESERVED_MEMORY:-}"
SYSTEM_RESERVED_CPU="${SYSTEM_RESERVED_CPU:-}"

#================================================================
# Pre-flight Checks
#================================================================

echo ""
step "OpenShift Node Memory Reservation Fix"
echo "=========================================="
echo ""

# Check if oc is available
if ! command -v oc &>/dev/null; then
    error "oc CLI not found. Please install OpenShift CLI."
    exit 1
fi

# Check if logged in
if ! oc whoami &>/dev/null; then
    error "Not logged into OpenShift cluster. Run: oc login"
    exit 1
fi

# Check cluster admin permissions
if ! oc auth can-i create kubeletconfig -n openshift-config &>/dev/null; then
    error "Insufficient permissions. Cluster admin access required."
    exit 1
fi

log "✓ Prerequisites check passed"
echo ""

#================================================================
# Gather Node Information
#================================================================

step "Step 1: Analyzing cluster nodes"
echo ""

log "Fetching node information..."

# Get nodes with the specified role
NODES=$(oc get nodes -l "node-role.kubernetes.io/${NODE_ROLE}=" -o name 2>/dev/null || echo "")

if [ -z "$NODES" ]; then
    warn "No nodes found with role: $NODE_ROLE"
    log "Checking all nodes..."
    NODES=$(oc get nodes -o name)
fi

NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')
log "Found $NODE_COUNT node(s) to analyze"
echo ""

# Analyze each node
for node in $NODES; do
    NODE_NAME=$(echo "$node" | cut -d'/' -f2)
    log "Analyzing node: $NODE_NAME"
    
    # Get node memory capacity
    MEMORY_KB=$(oc get node "$NODE_NAME" -o jsonpath='{.status.capacity.memory}' | sed 's/Ki$//')
    MEMORY_GB=$(echo "scale=2; $MEMORY_KB / 1024 / 1024" | bc)
    
    # Get current system reserved (if any)
    CURRENT_RESERVED=$(oc get node "$NODE_NAME" -o jsonpath='{.status.allocatable.memory}' 2>/dev/null || echo "N/A")
    
    log "  Total Memory: ${MEMORY_GB}GB (${MEMORY_KB}Ki)"
    log "  Current Allocatable: $CURRENT_RESERVED"
    echo ""
done

#================================================================
# Calculate Recommended Values
#================================================================

step "Step 2: Calculating recommended system-reserved values"
echo ""

if [ -z "$SYSTEM_RESERVED_MEMORY" ]; then
    log "Calculating memory reservation based on OpenShift recommendations..."
    
    # Get the smallest node's memory for calculation
    MIN_MEMORY_KB=$(for node in $NODES; do
        NODE_NAME=$(echo "$node" | cut -d'/' -f2)
        oc get node "$NODE_NAME" -o jsonpath='{.status.capacity.memory}' | sed 's/Ki$//'
    done | sort -n | head -1)
    
    MIN_MEMORY_GB=$(echo "scale=0; $MIN_MEMORY_KB / 1024 / 1024" | bc)
    
    # OpenShift recommended formula for system-reserved memory:
    # - 1GB for the first 4GB
    # - 0.5GB for the next 4GB (up to 8GB)
    # - 0.25GB for the next 8GB (up to 16GB)
    # - 0.167GB for the next 112GB (up to 128GB)
    # - 2% of memory above 128GB
    
    if [ "$MIN_MEMORY_GB" -le 4 ]; then
        RESERVED_GB=1
    elif [ "$MIN_MEMORY_GB" -le 8 ]; then
        RESERVED_GB=1.5
    elif [ "$MIN_MEMORY_GB" -le 16 ]; then
        RESERVED_GB=2
    elif [ "$MIN_MEMORY_GB" -le 32 ]; then
        RESERVED_GB=3
    elif [ "$MIN_MEMORY_GB" -le 64 ]; then
        RESERVED_GB=4
    elif [ "$MIN_MEMORY_GB" -le 128 ]; then
        RESERVED_GB=6
    else
        # For nodes > 128GB: 6GB + 2% of memory above 128GB
        EXTRA=$(echo "scale=0; ($MIN_MEMORY_GB - 128) * 0.02" | bc)
        RESERVED_GB=$(echo "6 + $EXTRA" | bc)
    fi
    
    # Convert to Mi
    SYSTEM_RESERVED_MEMORY="${RESERVED_GB}Gi"
    
    log "Node memory: ${MIN_MEMORY_GB}GB"
    log "Recommended system-reserved memory: $SYSTEM_RESERVED_MEMORY"
else
    log "Using custom system-reserved memory: $SYSTEM_RESERVED_MEMORY"
fi

if [ -z "$SYSTEM_RESERVED_CPU" ]; then
    # Recommended: 100m per core, with minimum 500m
    SYSTEM_RESERVED_CPU="500m"
    log "Using default system-reserved CPU: $SYSTEM_RESERVED_CPU"
else
    log "Using custom system-reserved CPU: $SYSTEM_RESERVED_CPU"
fi

echo ""

#================================================================
# Create KubeletConfig
#================================================================

step "Step 3: Creating KubeletConfig"
echo ""

KUBELET_CONFIG_NAME="increase-system-reserved-${NODE_ROLE}"

log "Creating KubeletConfig: $KUBELET_CONFIG_NAME"

# Check if KubeletConfig already exists
if oc get kubeletconfig "$KUBELET_CONFIG_NAME" -n openshift-config &>/dev/null; then
    warn "KubeletConfig '$KUBELET_CONFIG_NAME' already exists"
    read -p "Do you want to delete and recreate it? (yes/no): " -r
    echo
    if [[ $REPLY =~ ^[Yy]es$ ]]; then
        log "Deleting existing KubeletConfig..."
        oc delete kubeletconfig "$KUBELET_CONFIG_NAME" -n openshift-config
        sleep 2
    else
        log "Keeping existing configuration. Exiting."
        exit 0
    fi
fi

# Create the KubeletConfig manifest
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: ${KUBELET_CONFIG_NAME}
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/${NODE_ROLE}: ""
  kubeletConfig:
    systemReserved:
      memory: ${SYSTEM_RESERVED_MEMORY}
      cpu: ${SYSTEM_RESERVED_CPU}
    evictionHard:
      memory.available: "500Mi"
      nodefs.available: "10%"
      nodefs.inodesFree: "5%"
      imagefs.available: "15%"
    kubeReserved:
      memory: "1Gi"
      cpu: "500m"
EOF

if [ $? -eq 0 ]; then
    log "✓ KubeletConfig created successfully"
else
    error "Failed to create KubeletConfig"
    exit 1
fi

echo ""

#================================================================
# Monitor MachineConfigPool
#================================================================

step "Step 4: Monitoring MachineConfigPool rollout"
echo ""

MCP_NAME="${NODE_ROLE}"

log "Waiting for MachineConfigPool '$MCP_NAME' to start updating..."
sleep 5

# Check if MCP exists
if ! oc get mcp "$MCP_NAME" &>/dev/null; then
    warn "MachineConfigPool '$MCP_NAME' not found"
    log "Available MCPs:"
    oc get mcp -o name
    exit 1
fi

log "MachineConfigPool status:"
oc get mcp "$MCP_NAME"

echo ""
warn "⚠️  IMPORTANT: Node rollout process has started"
warn "    - Nodes will be drained and rebooted one at a time"
warn "    - This process can take 20-60 minutes depending on cluster size"
warn "    - Workloads will be temporarily disrupted during node drain"
echo ""

log "Monitoring rollout progress..."
log "Press Ctrl+C to stop monitoring (rollout will continue in background)"
echo ""

# Monitor the rollout
TIMEOUT=3600  # 1 hour timeout
ELAPSED=0
INTERVAL=15

while [ $ELAPSED -lt $TIMEOUT ]; do
    # Get MCP status
    UPDATING=$(oc get mcp "$MCP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
    DEGRADED=$(oc get mcp "$MCP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
    READY=$(oc get mcp "$MCP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "Unknown")
    
    MACHINE_COUNT=$(oc get mcp "$MCP_NAME" -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
    READY_COUNT=$(oc get mcp "$MCP_NAME" -o jsonpath='{.status.readyMachineCount}' 2>/dev/null || echo "0")
    UPDATED_COUNT=$(oc get mcp "$MCP_NAME" -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
    
    log "Status: Updating=$UPDATING | Degraded=$DEGRADED | Ready=$READY"
    log "Progress: $UPDATED_COUNT/$MACHINE_COUNT nodes updated, $READY_COUNT/$MACHINE_COUNT ready"
    
    # Check if update is complete
    if [ "$READY" = "True" ] && [ "$UPDATING" = "False" ] && [ "$UPDATED_COUNT" = "$MACHINE_COUNT" ]; then
        echo ""
        log "✓ MachineConfigPool rollout completed successfully!"
        break
    fi
    
    # Check if degraded
    if [ "$DEGRADED" = "True" ]; then
        echo ""
        error "MachineConfigPool is in degraded state!"
        log "Checking status..."
        oc get mcp "$MCP_NAME" -o yaml | grep -A10 "conditions:"
        exit 1
    fi
    
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    warn "Monitoring timeout reached. Rollout is still in progress."
    log "Check status with: oc get mcp $MCP_NAME"
    exit 1
fi

#================================================================
# Verify Configuration
#================================================================

echo ""
step "Step 5: Verifying node configuration"
echo ""

log "Waiting for nodes to be ready..."
sleep 10

for node in $NODES; do
    NODE_NAME=$(echo "$node" | cut -d'/' -f2)
    
    log "Verifying node: $NODE_NAME"
    
    # Check node is ready
    NODE_READY=$(oc get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [ "$NODE_READY" = "True" ]; then
        log "  ✓ Node is Ready"
    else
        warn "  ⚠ Node is not Ready yet"
    fi
    
    # Get new allocatable memory
    NEW_ALLOCATABLE=$(oc get node "$NODE_NAME" -o jsonpath='{.status.allocatable.memory}')
    log "  New allocatable memory: $NEW_ALLOCATABLE"
    
    # Try to get system reserved from node config (if available)
    SYSTEM_RESERVED=$(oc get --raw "/api/v1/nodes/$NODE_NAME/proxy/configz" 2>/dev/null | \
        jq -r '.kubeletconfig.systemReserved.memory // "N/A"' 2>/dev/null || echo "N/A")
    
    if [ "$SYSTEM_RESERVED" != "N/A" ]; then
        log "  ✓ System reserved: $SYSTEM_RESERVED"
    fi
    
    echo ""
done

#================================================================
# Summary
#================================================================

echo ""
step "Configuration Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - KubeletConfig: $KUBELET_CONFIG_NAME"
echo "  - System Reserved Memory: $SYSTEM_RESERVED_MEMORY"
echo "  - System Reserved CPU: $SYSTEM_RESERVED_CPU"
echo "  - Applied to: $NODE_ROLE nodes"
echo ""
log "✓ Nodes have been updated with increased memory reservation"
log "✓ System processes now have more protected memory"
log "✓ The alert should resolve within a few minutes"
echo ""

log "To verify the fix:"
echo "  oc get kubeletconfig"
echo "  oc get mcp $MCP_NAME"
echo "  oc get nodes"
echo ""

log "To rollback if needed:"
echo "  oc delete kubeletconfig $KUBELET_CONFIG_NAME"
echo ""
