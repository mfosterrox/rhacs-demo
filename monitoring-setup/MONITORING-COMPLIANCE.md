# RHACS Monitoring Setup - Documentation Compliance

## Summary of Changes

To align with [Red Hat RHACS 4.9 Documentation - Section 15.2](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs#monitoring-using-prometheus_monitoring-acs), the monitoring setup has been updated to properly disable default OpenShift monitoring before configuring custom Prometheus monitoring.

## Critical Documentation Requirement

From the official documentation:

> **Important**: If you have previously configured monitoring with the Prometheus Operator, consider removing your custom `ServiceMonitor` resources. RHACS ships with a pre-configured `ServiceMonitor` for Red Hat OpenShift monitoring. Multiple `ServiceMonitors` might result in duplicated scraping.

> **Before you can use custom Prometheus monitoring, if you have Red Hat OpenShift, you must disable the default monitoring.**

## What Changed

### New Script: `01-disable-openshift-monitoring.sh`

**Purpose**: Automatically disables default OpenShift monitoring before custom Prometheus setup.

**Features**:
- Auto-detects installation method (Operator, Helm, or Manifest)
- Patches Central CR for Operator installations
- Provides Helm upgrade instructions for Helm installations
- Removes ServiceMonitor resources for manifest installations
- Verifies monitoring is properly disabled
- Waits for Central to restart after changes

### Updated Script Order

**Before**:
```
1. 01-install-cluster-observability-operator.sh
2. 02-configure-rhacs-metrics.sh
3. 03-deploy-monitoring-stack.sh
4. 04-deploy-perses-dashboard.sh
```

**After** (Documentation Compliant):
```
1. 01-disable-openshift-monitoring.sh          ← NEW (REQUIRED FIRST)
2. 02-install-cluster-observability-operator.sh
3. 03-configure-rhacs-metrics.sh
4. 04-deploy-monitoring-stack.sh
5. 05-deploy-perses-dashboard.sh
```

## Why This Matters

### Problem: Duplicate Scraping

Without disabling default monitoring:
- ✗ Default OpenShift monitoring scrapes RHACS metrics
- ✗ Custom Prometheus also scrapes RHACS metrics
- ✗ Results in duplicate metrics and increased load on Central
- ✗ Confusing/incorrect metric values in dashboards

### Solution: Proper Monitoring Disablement

With the new script:
- ✓ Default OpenShift monitoring disabled via Central CR
- ✓ ServiceMonitor resources removed
- ✓ Only custom Prometheus scrapes metrics
- ✓ Clean, accurate metrics without duplication
- ✓ Follows Red Hat's documented best practices

## Installation Method Support

### Operator Installation (Automatic)
```yaml
# Central CR is automatically patched with:
spec:
  monitoring:
    openshift:
      enabled: false
```

The script:
1. Detects Central CR
2. Patches the monitoring configuration
3. Waits for Central to restart
4. Verifies ServiceMonitor removal

### Helm Installation (Manual Steps Provided)
```yaml
# User must update their values.yaml with:
monitoring:
  openshift:
    enabled: false

# Then run:
helm upgrade stackrox-central-services rhacs/central-services \
  -n stackrox \
  -f values.yaml
```

The script:
1. Detects Helm installation
2. Provides step-by-step instructions
3. Prompts for confirmation
4. Verifies ServiceMonitor removal

### Manifest Installation (Automatic)
```bash
# Script removes any ServiceMonitor resources:
oc delete servicemonitor -n stackrox -l app.kubernetes.io/name=stackrox
```

The script:
1. Detects manifest installation
2. Searches for ServiceMonitor resources
3. Removes any found ServiceMonitors
4. Provides guidance for custom monitors

## Verification

The script verifies monitoring is properly disabled:

```bash
# Check Central CR (Operator)
oc get central -n stackrox -o jsonpath='{.items[0].spec.monitoring.openshift.enabled}'
# Expected: false

# Check ServiceMonitor resources
oc get servicemonitor -n stackrox -l app.kubernetes.io/name=stackrox
# Expected: No resources found

# Verify custom Prometheus works
export SA_TOKEN=$(oc get secret sample-stackrox-prometheus-tls -n stackrox -o jsonpath='{.data.token}' | base64 -d)
curl -k -H "Authorization: Bearer ${SA_TOKEN}" \
  "https://central-stackrox.apps.example.com/metrics"
# Expected: Metrics returned
```

## Documentation References

1. **Section 15.2 - Monitoring with custom Prometheus**
   - https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs#monitoring-using-prometheus_monitoring-acs

2. **Section 15.2.1 - Disabling Red Hat OpenShift monitoring (Operator)**
   - https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs#disabling-red-hat-openshift-monitoring-for-central-services-by-using-the-rhacs-operator_monitoring-using-prometheus

3. **Section 15.2.2 - Disabling Red Hat OpenShift monitoring (Helm)**
   - https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs#disabling-red-hat-openshift-monitoring-for-central-services-by-using-helm_monitoring-using-prometheus

4. **Section 15.4 - Custom Prometheus metrics**
   - https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs#custom-prometheus-metrics_monitoring-acs

## Compliance Checklist

- ✅ Default OpenShift monitoring disabled before custom Prometheus setup
- ✅ ServiceMonitor resources removed to prevent duplicate scraping
- ✅ Service account authentication with proper RBAC (Section 15.4.3)
- ✅ Bearer token for `/metrics` endpoint access
- ✅ Custom metrics configured via API (Section 15.4.2)
- ✅ TLS configuration for secure scraping
- ✅ Perses dashboard as documented (Section 15.4.4)
- ✅ MonitoringStack with proper resource limits
- ✅ ScrapeConfig targeting Central service
- ✅ All installation methods supported (Operator, Helm, Manifest)

## Testing

To verify the setup is documentation-compliant:

```bash
# Run the full setup
cd monitoring-setup
export ROX_API_TOKEN="your-token"
./install.sh

# Verify monitoring is disabled
bash 01-disable-openshift-monitoring.sh  # Should show "already disabled"

# Check for duplicate ServiceMonitors
oc get servicemonitor -n stackrox
# Should only see custom servicemonitors, not RHACS default

# Verify metrics are accessible
oc port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090
# Open http://localhost:9090 and query: rox_central_cfg_total_policies
```

## Benefits of Compliance

1. **No Duplicate Metrics**
   - Single source of truth for RHACS metrics
   - Reduced load on Central API endpoint
   - Accurate metric values in dashboards

2. **Follows Best Practices**
   - Aligns with Red Hat's documented approach
   - Supported configuration pattern
   - Easier to troubleshoot with Red Hat support

3. **Clean Architecture**
   - Clear separation between default and custom monitoring
   - Explicit configuration choices
   - Predictable behavior

4. **Better Performance**
   - Only one Prometheus instance scraping RHACS
   - Reduced API calls to Central
   - Lower resource utilization

## Migration from Non-Compliant Setup

If you previously deployed without disabling default monitoring:

```bash
# Step 1: Run the disable script
cd monitoring-setup
bash 01-disable-openshift-monitoring.sh

# Step 2: Wait for Central to restart
oc rollout status deployment/central -n stackrox

# Step 3: Verify ServiceMonitors are gone
oc get servicemonitor -n stackrox -l app.kubernetes.io/name=stackrox
# Should return: No resources found

# Step 4: Verify custom Prometheus is working
oc get pods -n stackrox | grep prometheus
# Should show prometheus pod running

# Step 5: Check dashboard
# Navigate to OpenShift Console → Observe → Dashboards
# Look for "Advanced Cluster Security / Overview"
```

## Conclusion

The monitoring setup now fully complies with Red Hat's RHACS 4.9 documentation by:
- Disabling default OpenShift monitoring first
- Using custom Prometheus with proper authentication
- Following documented patterns for Perses dashboards
- Supporting all installation methods
- Providing proper verification steps

This ensures a production-ready, supported monitoring configuration that aligns with Red Hat's best practices.
