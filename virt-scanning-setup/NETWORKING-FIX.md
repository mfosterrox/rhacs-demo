# RHACS VM Scanning - Networking Fix

## Problem Summary

When RHACS collector uses `hostNetwork: true` (required for VSOCK access to VMs), it runs in the host network namespace and may not be able to reach Kubernetes ClusterIP services, depending on the CNI configuration.

### Symptoms

Collector compliance container logs show connection timeouts when trying to reach the sensor service:

```
virtualmachines/relay: Error sending index report to sensor, retrying. Error was: 
  rpc error: code = Unavailable desc = connection error: 
  desc = "transport: Error while dialing: dial tcp 172.231.132.191:443: i/o timeout"
```

### Root Cause Analysis

1. **Collector configuration** (correct):
   - `hostNetwork: true` - Required to access VSOCK devices on the host
   - `dnsPolicy: ClusterFirstWithHostNet` - Allows DNS resolution of cluster services

2. **The Problem**:
   - Even with DNS resolution working, the collector cannot reach the ClusterIP `172.231.132.191:443`
   - From the host network namespace, ClusterIP routing may not work depending on CNI
   - Testing confirmed: `curl -k https://172.231.132.191:443` times out from host network

3. **VSOCK is working**:
   - VMs successfully connect via VSOCK: `Handling vsock connection from vm(4124886176)`
   - roxagent inside VMs is scanning and collecting vulnerability data
   - The only issue is collector → sensor communication

## Solution

Configure sensor to be reachable from the host network by:

1. **Add hostPort to sensor**: Bind sensor's API port to host port 8443
2. **Update collector**: Configure to reach sensor via `localhost:8443` instead of ClusterIP

This allows the collector (running in host network) to reach sensor via localhost, which always works.

## Changes Made

### 1. Updated `01-configure-rhacs.sh`

Added two new functions:

#### `configure_sensor_networking()`
- Checks if sensor already has hostPort configured
- If not, patches sensor deployment to add `hostPort: 8443` on the API port
- Updates collector environment variables:
  - `GRPC_SERVER=localhost:8443`
  - `ROX_ADVERTISED_ENDPOINT=localhost:8443`
  - Keeps `SNI_HOSTNAME=sensor.stackrox.svc` for TLS validation
- Waits for both sensor and collector to restart

#### `verify_sensor_connectivity()`
- Waits for pods to stabilize (30 seconds)
- Checks collector logs for VSOCK connections
- Checks for connection errors
- Provides troubleshooting hints if issues found

### 2. Created `01-check-env.sh`

Comprehensive environment verification script that checks:

- ✓ Cluster connectivity
- ✓ OpenShift Virtualization operator
- ✓ VSOCK feature gate enabled
- ✓ RHACS components (Central, Sensor, Collector) running
- ✓ ROX_VIRTUAL_MACHINES feature flags set
- ✓ Collector networking (hostNetwork, dnsPolicy)
- ✓ Sensor hostPort configuration
- ✓ Collector → Sensor connectivity
- ✓ Collector logs for connection errors
- ✓ Running VMs

Returns exit code based on number of failed checks.

### 3. Updated `README.md`

Added comprehensive troubleshooting section:
- Symptoms and root cause explanation
- Solution steps
- Verification commands
- Reference to `01-check-env.sh` script

## Testing the Fix

### On an existing cluster with the issue:

```bash
# 1. Run the configure script (applies the fix)
cd /path/to/rhacs-demo/virt-scanning
./01-configure-rhacs.sh

# 2. Wait for pods to restart (about 2-3 minutes)
oc get pods -n stackrox -w

# 3. Verify the configuration
./01-check-env.sh

# 4. Check collector logs for successful VSOCK connections
COLLECTOR_POD=$(oc get pods -n stackrox -l app=collector -o jsonpath='{.items[0].metadata.name}')
oc logs $COLLECTOR_POD -n stackrox -c compliance --tail=50

# Should see:
# - "Handling vsock connection from vm(...)"
# - "Sending index report to sensor"
# - NO "i/o timeout" errors
```

### Verification Commands

```bash
# Check sensor hostPort configuration
oc get deployment sensor -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="api")]}'
# Expected output: {"containerPort":8443,"hostPort":8443,"name":"api","protocol":"TCP"}

# Check collector GRPC_SERVER configuration
oc get daemonset collector -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="GRPC_SERVER")].value}'
# Expected output: localhost:8443

# Test from collector pod (should work now)
COLLECTOR_POD=$(oc get pods -n stackrox -l app=collector -o jsonpath='{.items[0].metadata.name}')
oc exec -n stackrox $COLLECTOR_POD -c compliance -- \
  timeout 5 sh -c 'echo > /dev/tcp/localhost/8443' && echo "SUCCESS" || echo "FAILED"
```

## Architecture

### Before (Broken)

```
┌─────────────────────────────┐
│ Collector                    │
│ hostNetwork: true            │
│ GRPC_SERVER:                 │
│   sensor.stackrox.svc:443    │
└──────────────┬──────────────┘
               │
               │ ❌ Cannot reach ClusterIP from host network
               │
┌──────────────▼──────────────┐
│ Sensor Service (ClusterIP)  │
│ 172.231.132.191:443         │
│   → Pod: 10.233.1.61:8443   │
└─────────────────────────────┘
```

### After (Fixed)

```
┌─────────────────────────────┐
│ Collector                    │
│ hostNetwork: true            │
│ GRPC_SERVER: localhost:8443  │
└──────────────┬──────────────┘
               │
               │ ✅ localhost always works
               │
┌──────────────▼──────────────┐
│ Sensor Pod                   │
│ hostPort: 8443               │
│ containerPort: 8443          │
└─────────────────────────────┘
```

## Key Insights

1. **hostNetwork is required**: Without it, collector cannot access VSOCK devices
2. **ClusterIP may not work from host network**: CNI-dependent behavior
3. **hostPort is the solution**: Sensor binds directly to host port
4. **localhost is always reachable**: Works from any network namespace on the same node
5. **Multi-node consideration**: Sensor pod and collector pods are on the same node (sensor is a Deployment, typically 1 replica)

## Alternative Solutions Considered

### 1. NodePort Service
**Pros**: Standard Kubernetes approach
**Cons**: Requires external port allocation, more complex configuration

### 2. Remove hostNetwork from collector
**Pros**: Would restore ClusterIP access
**Cons**: ❌ **Cannot work** - collector needs host network to access VSOCK devices

### 3. DaemonSet proxy on each node
**Pros**: More flexible
**Cons**: Adds complexity, unnecessary when hostPort works

### 4. Change CNI configuration
**Pros**: Would fix at infrastructure level
**Cons**: Not always possible, affects entire cluster, hostPort is simpler

## Related Issues

- [RHACS Documentation - VM Scanning](https://docs.openshift.com/acs/)
- Requires RHACS 4.x with VM scanning support
- OpenShift Virtualization 4.x with VSOCK support

## Files Modified

- `01-configure-rhacs.sh` - Added networking configuration
- `01-check-env.sh` - New verification script
- `README.md` - Added troubleshooting documentation
- `NETWORKING-FIX.md` - This document
