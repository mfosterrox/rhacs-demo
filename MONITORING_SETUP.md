# RHACS Monitoring Setup - Fixed Installation

## Problem Summary

The monitoring setup was failing because the required operators weren't being installed. The error messages indicated:

```
resource mapping not found for name: "sample-stackrox-monitoring-stack" namespace: "stackrox" 
from "monitoring/cluster-observability-operator/monitoring-stack.yaml": 
no matches for kind "MonitoringStack" in version "monitoring.rhobs/v1alpha1"
ensure CRDs are installed first
```

## Root Cause

The setup scripts were structured as follows:
1. ✓ `01-verify-rhacs-install.sh` - Verify RHACS
2. ✓ `02-compliance-operator-install.sh` - Install Compliance Operator
3. ✓ `03-deploy-applications.sh` - Deploy demo apps
4. ✓ `04-configure-rhacs-settings.sh` - Configure RHACS
5. ✓ `05-setup-co-scan-schedule.sh` - Setup compliance scans
6. ✗ `06-setup-monitoring.sh` - **Tried to apply monitoring manifests without installing operators first**

The `06-setup-monitoring.sh` script was attempting to create resources (`MonitoringStack`, `ScrapeConfig`, `PersesDashboard`, etc.) that require operators which were never installed.

## Solution

### Changes Made

1. **Created new operator installation script**: `setup/06-install-monitoring-operators.sh`
   - Enables OpenShift user workload monitoring
   - Activates Prometheus Operator for user namespaces
   - Waits for operator pods to be ready

2. **Updated monitoring manifest script**: `setup/07-setup-monitoring.sh` (renamed from `06`)
   - Now checks which operators are actually installed
   - Only applies manifests for available operators
   - Provides clear feedback about what's installed vs skipped
   - Shows installation instructions for optional operators

3. **Created comprehensive documentation**: `monitoring/README.md`
   - Documents all monitoring solutions
   - Explains authentication methods
   - Provides troubleshooting guidance
   - Lists all available metrics

### New Setup Script Order

1. `01-verify-rhacs-install.sh` - Verify RHACS
2. `02-compliance-operator-install.sh` - Install Compliance Operator
3. `03-deploy-applications.sh` - Deploy demo apps
4. `04-configure-rhacs-settings.sh` - Configure RHACS API settings
5. `05-setup-co-scan-schedule.sh` - Setup compliance scan schedules
6. **`06-install-monitoring-operators.sh`** - **NEW: Install monitoring operators**
7. `07-setup-monitoring.sh` - Apply monitoring manifests (updated to check operator availability)

## Monitoring Solutions

### Automatic (Installed by Scripts)

✓ **Prometheus Operator**
- Part of OpenShift monitoring stack
- Enabled via "user workload monitoring"
- Used for RHACS metrics collection
- Lightweight and fast

### Optional (Manual Installation)

⊘ **Cluster Observability Operator**
- Provides comprehensive monitoring stack
- Includes alerting and multi-tenancy
- Manifests will be automatically applied if installed

⊘ **Perses**
- Advanced dashboard capabilities
- OpenShift console integration
- Pre-built RHACS security dashboard
- Manifests will be automatically applied if installed

## What Gets Created

### Core Components (Always)
- `ServiceAccount`: `sample-stackrox-prometheus` - Authentication
- `Secret`: `sample-stackrox-prometheus-token` - Long-lived SA token
- `ConfigMap`: `sample-stackrox-prometheus-declarative-configuration` - RHACS RBAC

### With Prometheus Operator (Automatic)
- `Secret`: `sample-stackrox-prometheus-additional-scrape-configs` - Scrape configuration
- `Prometheus`: `sample-stackrox-prometheus-server` - Prometheus instance

### With Cluster Observability Operator (If Installed)
- `MonitoringStack`: `sample-stackrox-monitoring-stack`
- `ScrapeConfig`: `sample-stackrox-scrape-config`

### With Perses (If Installed)
- `PersesDashboard`: `sample-stackrox-dashboard`
- `PersesDatasource`: `sample-stackrox-datasource`
- `UIPlugin`: `monitoring`

## Testing the Fix

### Run the Full Installation

```bash
cd /path/to/rhacs-demo
./install.sh [YOUR_RHACS_PASSWORD]
```

### Or Run Individual Scripts

```bash
# Install monitoring operators
bash setup/06-install-monitoring-operators.sh

# Apply monitoring manifests
bash setup/07-setup-monitoring.sh
```

### Verify Installation

```bash
# Check Prometheus Operator
oc api-resources --api-group=monitoring.coreos.com | grep prometheuses

# Check user workload monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload

# Check Prometheus instance
oc get prometheus -n stackrox

# Check ServiceAccount and token
oc get serviceaccount sample-stackrox-prometheus -n stackrox
oc get secret sample-stackrox-prometheus-token -n stackrox

# Access Prometheus UI
oc port-forward -n stackrox svc/sample-stackrox-prometheus-server 9090:9090
# Then open http://localhost:9090
```

### Query RHACS Metrics

```bash
# Get ServiceAccount token
export SA_TOKEN=$(oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d)

# Get Central URL
export CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='https://{.spec.host}')

# Query metrics directly
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "${CENTRAL_URL}/metrics"
```

## Available Metrics

### Fixed Metrics (Always Available)
- `rox_central_health_cluster_info` - Cluster health
- `rox_central_cfg_total_policies` - Total policies
- `rox_central_cert_exp_hours` - Certificate expiry

### Configurable Metrics (Enabled by Setup Scripts)
- **Image Vulnerabilities**: `rox_central_image_vuln_*` (cve, deployment, namespace severity)
- **Policy Violations**: `rox_central_policy_violation_*` (deployment, namespace severity)
- **Node Vulnerabilities**: `rox_central_node_vuln_*` (component, cve, node severity)

All metrics are configured with 1-minute gathering periods for real-time monitoring.

## Troubleshooting

### If User Workload Monitoring Fails to Enable

```bash
# Check cluster monitoring config
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml

# Manually enable if needed
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF

# Wait for namespace to be created
oc get namespace openshift-user-workload-monitoring
```

### If Prometheus Operator Pods Don't Start

```bash
# Check operator status
oc get pods -n openshift-user-workload-monitoring

# Check operator logs
oc logs -n openshift-user-workload-monitoring -l app.kubernetes.io/name=prometheus-operator

# Check cluster monitoring operator
oc get pods -n openshift-monitoring | grep cluster-monitoring-operator
oc logs -n openshift-monitoring -l app.kubernetes.io/name=cluster-monitoring-operator
```

### If Metrics Don't Appear in Prometheus

```bash
# Check Prometheus configuration
oc get prometheus sample-stackrox-prometheus-server -n stackrox -o yaml

# Check Prometheus logs
oc logs -n stackrox -l app.kubernetes.io/name=prometheus

# Verify RHACS metrics endpoint is accessible
export SA_TOKEN=$(oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d)
export CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='https://{.spec.host}')
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "${CENTRAL_URL}/metrics" | head -20
```

## Installing Optional Operators

### Cluster Observability Operator

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cluster-observability-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  targetNamespaces: []
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: openshift-cluster-observability-operator
spec:
  channel: development
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

# Wait for operator to be ready
oc wait --for=condition=ready pod -l app.kubernetes.io/name=cluster-observability-operator \
  -n openshift-cluster-observability-operator --timeout=300s

# Re-run monitoring setup to apply MonitoringStack manifests
bash setup/07-setup-monitoring.sh
```

### Perses Operator

```bash
# Install Perses Operator
kubectl apply -f https://github.com/perses/perses-operator/releases/latest/download/install.yaml

# Wait for operator to be ready
kubectl wait --for=condition=ready pod -l app=perses-operator \
  -n perses-system --timeout=300s

# Re-run monitoring setup to apply Perses manifests
bash setup/07-setup-monitoring.sh
```

## Benefits of This Approach

1. **Graceful Degradation**: Works with whatever operators are available
2. **Clear Feedback**: Shows what's installed, what's skipped, and why
3. **Easy Extension**: Installing additional operators automatically enables their features
4. **Production Ready**: Uses official OpenShift monitoring stack
5. **Well Documented**: Comprehensive docs for all monitoring solutions

## References

- [RHACS Monitoring Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/operating/monitoring-using-prometheus)
- [OpenShift User Workload Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/enabling-monitoring-for-user-defined-projects.html)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [monitoring/README.md](monitoring/README.md) - Comprehensive monitoring setup documentation
