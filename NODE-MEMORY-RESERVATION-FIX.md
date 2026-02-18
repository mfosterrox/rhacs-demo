# OpenShift Node Memory Reservation Fix

## Problem

You're seeing this alert in your OpenShift cluster:

```
System memory usage of 1.239G on Node control-plane-cluster-c4dkt-1 exceeds 95% 
of the reservation. Reserved memory ensures system processes can function even 
when the node is fully allocated and protects against workload out of memory 
events impacting the proper functioning of the node.
```

## Root Cause

The default system-reserved memory in OpenShift is often insufficient for nodes with:
- High pod density
- Large amounts of total memory
- Heavy system process usage

This causes system processes to compete with workloads for memory, potentially causing:
- Node instability
- OOM kills of system processes
- Degraded cluster performance

## Solution

The `fix-node-memory-reservation.sh` script automatically:

1. ✅ Analyzes your cluster nodes
2. ✅ Calculates appropriate system-reserved memory (based on OpenShift recommendations)
3. ✅ Creates a KubeletConfig to increase reservations
4. ✅ Monitors the MachineConfigPool rollout
5. ✅ Verifies the configuration is applied

## Quick Start

### For Control Plane Nodes (Most Common)

```bash
./fix-node-memory-reservation.sh
```

This will apply the fix to master/control plane nodes (default).

### For Worker Nodes

```bash
NODE_ROLE=worker ./fix-node-memory-reservation.sh
```

### Custom Memory Reservation

```bash
SYSTEM_RESERVED_MEMORY="4Gi" NODE_ROLE=master ./fix-node-memory-reservation.sh
```

## What the Script Does

### 1. Memory Calculation Formula

The script uses OpenShift's recommended formula:

| Total Node Memory | System Reserved |
|-------------------|----------------|
| ≤ 4GB | 1GB |
| ≤ 8GB | 1.5GB |
| ≤ 16GB | 2GB |
| ≤ 32GB | 3GB |
| ≤ 64GB | 4GB |
| ≤ 128GB | 6GB |
| > 128GB | 6GB + 2% of memory above 128GB |

### 2. KubeletConfig Created

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: increase-system-reserved-master
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    systemReserved:
      memory: "4Gi"  # Calculated value
      cpu: "500m"
    evictionHard:
      memory.available: "500Mi"
      nodefs.available: "10%"
      nodefs.inodesFree: "5%"
      imagefs.available: "15%"
    kubeReserved:
      memory: "1Gi"
      cpu: "500m"
```

### 3. Node Rollout Process

1. **MachineConfig is generated** from the KubeletConfig
2. **MachineConfigPool starts updating** (one node at a time)
3. **For each node:**
   - Workloads are drained
   - Node is cordoned
   - Configuration is applied
   - Node is rebooted
   - Node rejoins cluster
   - Next node is processed

**⏱️ Expected Duration:** 20-60 minutes depending on cluster size

## Configuration Options

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NODE_ROLE` | `master` | Node role to apply fix to (master, worker, infra) |
| `SYSTEM_RESERVED_MEMORY` | (auto) | Custom memory reservation (e.g., "4Gi") |
| `SYSTEM_RESERVED_CPU` | `500m` | Custom CPU reservation |

### Examples

**Apply to all worker nodes with 8GB reserved:**
```bash
NODE_ROLE=worker SYSTEM_RESERVED_MEMORY="8Gi" ./fix-node-memory-reservation.sh
```

**Apply to infrastructure nodes:**
```bash
NODE_ROLE=infra ./fix-node-memory-reservation.sh
```

**Custom CPU and memory:**
```bash
SYSTEM_RESERVED_MEMORY="6Gi" SYSTEM_RESERVED_CPU="1000m" ./fix-node-memory-reservation.sh
```

## Monitoring the Fix

### During Execution

The script automatically monitors the rollout and shows:
```
Status: Updating=True | Degraded=False | Ready=False
Progress: 1/3 nodes updated, 2/3 ready
```

### After Completion

**Check KubeletConfig:**
```bash
oc get kubeletconfig
```

**Check MachineConfigPool:**
```bash
oc get mcp master
```

**Verify node memory:**
```bash
oc get nodes -o custom-columns=NAME:.metadata.name,MEMORY:.status.capacity.memory,ALLOCATABLE:.status.allocatable.memory
```

**Check for the alert:**
```bash
# Wait 5-10 minutes after completion
# Check in OpenShift Console: Observe → Alerting
# The alert should resolve
```

## Verification Steps

### 1. Check Node Configuration

```bash
# Get node name
NODE_NAME="control-plane-cluster-c4dkt-1"

# View node details
oc describe node $NODE_NAME | grep -A5 "Allocated resources"

# Check system reserved
oc get node $NODE_NAME -o jsonpath='{.status.allocatable}' | jq .
```

### 2. Verify Memory Allocation

```bash
# Before: System uses >95% of reservation
# After: System uses <80% of reservation

# Check memory usage
oc adm top nodes
```

### 3. Check Kubelet Logs

```bash
oc adm node-logs <node-name> -u kubelet | grep "system-reserved"
```

## Rollback

If you need to revert the changes:

```bash
# Delete the KubeletConfig
oc delete kubeletconfig increase-system-reserved-master

# Wait for MachineConfigPool to rollback
oc get mcp master -w

# Nodes will automatically revert to previous configuration
```

## Troubleshooting

### Issue: MachineConfigPool is Degraded

**Check status:**
```bash
oc get mcp master -o yaml | grep -A20 "conditions:"
```

**Common causes:**
- Invalid KubeletConfig syntax
- Insufficient node resources
- Node not draining properly

**Fix:**
```bash
# Delete the problematic config
oc delete kubeletconfig increase-system-reserved-master

# Wait for recovery
oc get mcp master -w
```

### Issue: Nodes Not Updating

**Check MachineConfigPool:**
```bash
oc describe mcp master
```

**Check Machine Config Operator:**
```bash
oc get co machine-config -o yaml
```

**Force refresh:**
```bash
oc patch mcp master --type merge -p '{"spec":{"paused":false}}'
```

### Issue: Alert Still Firing

**Wait Time:** Allow 5-10 minutes after rollout completes for metrics to update

**Verify configuration:**
```bash
# Check that system-reserved increased
oc get node <node-name> -o jsonpath='{.status.allocatable.memory}'

# Compare with capacity
oc get node <node-name> -o jsonpath='{.status.capacity.memory}'
```

**Check node metrics:**
```bash
oc adm top node <node-name>
```

## Impact Assessment

### During Rollout
- ✅ **Control Plane:** Highly Available - other masters handle requests
- ✅ **Worker Workloads:** Temporarily moved to other nodes
- ⚠️ **Node Reboots:** Yes, one at a time
- ⚠️ **Cluster API:** Brief disruptions during master updates
- ⏱️ **Duration:** 20-60 minutes

### After Completion
- ✅ **More stable nodes** - system processes have guaranteed memory
- ✅ **Fewer OOM events** - better memory protection
- ✅ **Slightly less allocatable memory** - some memory reserved for system
- ✅ **Better cluster health** - system processes won't compete with workloads

## Best Practices

### 1. Test in Non-Production First
```bash
# Apply to a test cluster or single node first
NODE_ROLE=worker ./fix-node-memory-reservation.sh
```

### 2. Backup Current Config
```bash
# Export current MachineConfig
oc get mc -o yaml > machineconfigs-backup.yaml

# Export current KubeletConfigs
oc get kubeletconfig -o yaml > kubeletconfigs-backup.yaml
```

### 3. Schedule During Maintenance Window
- Apply to master nodes during low-traffic periods
- Apply to worker nodes in batches

### 4. Monitor After Changes
```bash
# Watch for issues
oc get mcp -w

# Monitor alerts
# OpenShift Console → Observe → Alerting
```

## Advanced Configuration

### Apply to Specific Nodes

```yaml
# Create KubeletConfig with node selector
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: custom-system-reserved
spec:
  machineConfigPoolSelector:
    matchLabels:
      custom-pool: high-memory
  kubeletConfig:
    systemReserved:
      memory: "8Gi"
      cpu: "1000m"
```

### Multiple Node Pools

```bash
# Apply different values to different pools
NODE_ROLE=master SYSTEM_RESERVED_MEMORY="6Gi" ./fix-node-memory-reservation.sh
NODE_ROLE=worker SYSTEM_RESERVED_MEMORY="4Gi" ./fix-node-memory-reservation.sh
NODE_ROLE=infra SYSTEM_RESERVED_MEMORY="8Gi" ./fix-node-memory-reservation.sh
```

## References

- [OpenShift Node Management](https://docs.openshift.com/container-platform/latest/nodes/nodes/nodes-nodes-managing.html)
- [System Reserved Resources](https://docs.openshift.com/container-platform/latest/nodes/nodes/nodes-nodes-resources-configuring.html)
- [KubeletConfig API](https://docs.openshift.com/container-platform/latest/rest_api/machine_apis/kubeletconfig-machineconfiguration-openshift-io-v1.html)

## Support

For issues or questions:
1. Check OpenShift documentation
2. Review MachineConfigPool status
3. Examine node logs
4. Contact Red Hat Support if needed

## Summary

This script provides an automated, safe way to fix the memory reservation alert by:
- Calculating appropriate values based on your cluster
- Creating proper Kubernetes configurations
- Monitoring the rollout process
- Verifying the fix was applied

After completion, your nodes will have adequate system memory reserved, preventing the alert and improving cluster stability.
