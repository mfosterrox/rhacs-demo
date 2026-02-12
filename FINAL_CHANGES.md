# Final Changes Summary - RHACS Monitoring Setup

## Overview

All monitoring operators are now **REQUIRED** and installed automatically. The setup will **fail fast** if any operator installation fails, ensuring a complete and functional monitoring stack.

## Key Changes Made

### 1. Enhanced Operator Installation Script

**File**: `setup/06-install-monitoring-operators.sh`

**Changes**:
- ✅ Now installs **ALL three required operators**:
  1. **Prometheus Operator** (via user workload monitoring)
  2. **Cluster Observability Operator** (from Red Hat operators catalog)
  3. **Perses Operator** (from GitHub releases)
- ✅ Waits for each operator to be fully ready before proceeding
- ✅ Fails immediately if any operator installation fails
- ✅ Provides detailed status messages during installation
- ✅ Validates all operators are running before completing

### 2. Updated Manifest Application Script

**File**: `setup/07-setup-monitoring.sh`

**Changes**:
- ✅ **Validates all required operators are installed** before applying manifests
- ✅ **Fails fast** with clear error messages if any operator is missing
- ✅ Applies manifests for ALL monitoring components:
  - RHACS configuration
  - Prometheus instances
  - MonitoringStack resources
  - Perses dashboards
- ✅ No more "graceful skipping" - all components are required
- ✅ Provides clear error messages directing users to run script 06 if operators are missing

### 3. Updated Documentation

**Files Updated**:
- `MONITORING_SETUP.md` - Updated to reflect all operators are required
- `monitoring/README.md` - Changed from "optional" to "required" for all operators
- Both docs now emphasize fail-fast behavior

## What Gets Installed

### Operators (Script 06)
1. **Prometheus Operator** (namespace: `openshift-user-workload-monitoring`)
2. **Cluster Observability Operator** (namespace: `openshift-cluster-observability-operator`)
3. **Perses Operator** (namespace: `perses-system`)

### Resources (Script 07)
1. **Core Authentication**:
   - ServiceAccount: `sample-stackrox-prometheus`
   - Token Secret: `sample-stackrox-prometheus-token`
   - RHACS RBAC ConfigMap

2. **Prometheus Resources**:
   - Prometheus instance
   - Scrape configurations

3. **Cluster Observability Resources**:
   - MonitoringStack
   - ScrapeConfig

4. **Perses Resources**:
   - Dashboard
   - Datasource
   - UI Plugin

## Fail-Fast Behavior

### Script 06 Failure Scenarios
- Prometheus Operator not available → **FAIL**
- User workload monitoring fails to enable → **FAIL**
- Prometheus Operator pods don't start → **FAIL**
- Cluster Observability Operator fails to install → **FAIL**
- Perses Operator fails to install → **FAIL**

### Script 07 Failure Scenarios
- Any required operator CRDs not found → **FAIL** with message to run script 06
- RHACS configuration fails → **FAIL**
- Any manifest fails to apply → **FAIL**

## Installation Process

### Run Full Installation
```bash
cd /path/to/rhacs-demo
./install.sh [YOUR_RHACS_PASSWORD]
```

This will run all scripts in order, including:
- Script 06: Install all monitoring operators
- Script 07: Apply all monitoring manifests

### Run Monitoring Scripts Individually
```bash
# Install operators (takes 5-10 minutes)
bash setup/06-install-monitoring-operators.sh

# Apply manifests (takes 1-2 minutes)
bash setup/07-setup-monitoring.sh
```

### Verify Installation
```bash
# Run verification script
./check-monitoring-status.sh
```

## Expected Output

### Script 06 Success Output
```
==========================================
Monitoring Operators Installation
==========================================

Installing ALL required operators for RHACS monitoring:
  1. Prometheus Operator (via user workload monitoring)
  2. Cluster Observability Operator
  3. Perses Operator

[1/3] Prometheus Operator
✓ User workload monitoring enabled
✓ Prometheus Operator is running

[2/3] Cluster Observability Operator
✓ Subscription created
✓ Cluster Observability Operator installed successfully
✓ Operator pods running: 1

[3/3] Perses Operator
✓ Perses Operator manifests applied
✓ Perses Operator is running

==========================================
✓ ALL Monitoring Operators Installed
==========================================

Operators installed:
  ✓ Prometheus Operator (openshift-user-workload-monitoring)
  ✓ Cluster Observability Operator (openshift-cluster-observability-operator)
  ✓ Perses Operator (perses-system)
```

### Script 07 Success Output
```
==========================================
RHACS Monitoring Setup
==========================================

[STEP] Checking required operators...
✓ Prometheus Operator is installed
✓ Cluster Observability Operator is installed
✓ Perses Operator is installed
✓ All required operators are installed

[STEP] Applying monitoring manifests...
Applying RHACS configuration...
  serviceaccount/sample-stackrox-prometheus created
  secret/sample-stackrox-prometheus-token created
  configmap/sample-stackrox-prometheus-declarative-configuration created

Applying Prometheus Operator manifests...
  secret/sample-stackrox-prometheus-additional-scrape-configs created
  prometheus.monitoring.coreos.com/sample-stackrox-prometheus-server created

Applying Cluster Observability Operator manifests...
  monitoringstack.monitoring.rhobs/sample-stackrox-monitoring-stack created
  scrapeconfig.monitoring.rhobs/sample-stackrox-scrape-config created

Applying Perses manifests...
  persesdashboard.perses.dev/sample-stackrox-dashboard created
  persesdatasource.perses.dev/sample-stackrox-datasource created
  uiplugin.observability.openshift.io/monitoring created

✓ All monitoring manifests applied successfully
```

## Troubleshooting

### If Script 06 Fails

```bash
# Check operator installation status
oc get subscriptions -A
oc get csv -A

# Check specific operator pods
oc get pods -n openshift-user-workload-monitoring
oc get pods -n openshift-cluster-observability-operator
oc get pods -n perses-system

# View operator logs
oc logs -n openshift-cluster-observability-operator -l app.kubernetes.io/name=cluster-observability-operator
oc logs -n perses-system -l app=perses-operator

# Re-run after fixing issues
bash setup/06-install-monitoring-operators.sh
```

### If Script 07 Fails

```bash
# Verify all operators are installed
./check-monitoring-status.sh

# Check API resources
oc api-resources --api-group=monitoring.coreos.com | grep prometheuses
oc api-resources --api-group=monitoring.rhobs | grep monitoringstacks
oc api-resources --api-group=perses.dev | grep persesdashboards

# If operators are missing, run script 06
bash setup/06-install-monitoring-operators.sh

# Then retry script 07
bash setup/07-setup-monitoring.sh
```

## Benefits

1. **✅ Complete Installation**: All required operators installed automatically
2. **✅ No Partial States**: Script fails if anything goes wrong
3. **✅ Clear Error Messages**: Know exactly what failed and how to fix it
4. **✅ Fully Functional**: All monitoring features work out of the box
5. **✅ Production Ready**: Uses official Red Hat and open-source operators
6. **✅ Easy Verification**: Simple status check script included

## Access Monitoring

### Prometheus UI
```bash
# Port-forward to Prometheus
oc port-forward -n stackrox svc/sample-stackrox-prometheus-server 9090:9090

# Open in browser
open http://localhost:9090
```

### Query Metrics Directly
```bash
# Get ServiceAccount token
export SA_TOKEN=$(oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d)

# Get Central URL
export CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='https://{.spec.host}')

# Query metrics
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "${CENTRAL_URL}/metrics"
```

### Access Perses Dashboard
```bash
# Find console URL
oc get route console -n openshift-console -o jsonpath='https://{.spec.host}'

# Navigate to: Observe → Dashboards
# Look for "Advanced Cluster Security / Overview"
```

## Summary

The monitoring setup is now **100% complete and required**:
- ✅ All three operators are installed automatically
- ✅ All manifests are applied for all components
- ✅ Setup fails fast if anything goes wrong
- ✅ Clear error messages guide troubleshooting
- ✅ Complete monitoring stack with dashboards ready to use

No more "graceful skipping" - everything is installed and working!
