# RHACS Advanced Monitoring Setup

This folder contains the advanced monitoring setup that installs **Cluster Observability Operator** and **Perses dashboards** for RHACS metrics visualization in the OpenShift console.

## Overview

The advanced setup provides enterprise-grade monitoring with:
- **Cluster Observability Operator** - Red Hat's comprehensive observability platform
- **Perses Dashboards** - Modern, interactive dashboards in OpenShift console
- **MonitoringStack** - Dedicated Prometheus instance for RHACS metrics
- **UI Plugin Integration** - Dashboards accessible via Observe → Dashboards

## Prerequisites

### Required
- OpenShift 4.12+ cluster (for Cluster Observability Operator support)
- RHACS installed in `stackrox` namespace (or set `RHACS_NAMESPACE`)
- Logged into OpenShift cluster via `oc login`
- `jq` installed on the system
- `ROX_API_TOKEN` environment variable set (for script 02 - metrics configuration)

### Basic Setup Must Be Completed First
Before running advanced setup, ensure you've completed the basic setup:

```bash
cd ../basic-setup
./install.sh [PASSWORD]
```

This ensures RHACS is properly configured.

**Generate API Token**:
```bash
# Generate token for advanced setup
curl -k -X POST \
  -u "admin:${ROX_PASSWORD}" \
  -H "Content-Type: application/json" \
  "${ROX_CENTRAL_URL}/v1/apitokens/generate" \
  -d '{"name":"dashboard-setup","roles":["Admin"]}' | jq -r '.token'

# Export it
export ROX_API_TOKEN="your-generated-token"
```

## Project Structure

The advanced setup consists of 4 focused scripts:

```
advanced-setup/
├── install.sh                                  # Main orchestrator
├── 01-install-cluster-observability-operator.sh # Install COO
├── 02-configure-rhacs-metrics.sh                # Configure metrics (requires ROX_API_TOKEN)
├── 03-deploy-monitoring-stack.sh                # Deploy Prometheus + auth
├── 04-deploy-perses-dashboard.sh                # Deploy dashboard + verify
└── monitoring/                                  # Manifests
```

## Installation

### Quick Start

```bash
cd advanced-setup

# Set RHACS API token (required for script 02)
export ROX_API_TOKEN="your-api-token"

# Run the complete installation
./install.sh
```

### Individual Script Usage

You can also run scripts individually for troubleshooting:

```bash
# Step 1: Install operator
bash 01-install-cluster-observability-operator.sh

# Step 2: Configure metrics (requires ROX_API_TOKEN)
export ROX_API_TOKEN="your-token"
bash 02-configure-rhacs-metrics.sh

# Step 3: Deploy monitoring stack
bash 03-deploy-monitoring-stack.sh

# Step 4: Deploy dashboard
bash 04-deploy-perses-dashboard.sh
```

## Script Details

### 01-install-cluster-observability-operator.sh
Installs the Cluster Observability Operator which provides the foundation for monitoring.

**Actions**:
- Creates `openshift-cluster-observability-operator` namespace
- Creates OperatorGroup and Subscription
- Waits for CSV to reach "Succeeded" state
- No external dependencies

### 02-configure-rhacs-metrics.sh
Configures RHACS to expose metrics for Prometheus scraping.

**Actions**:
- Fetches current RHACS configuration via API
- Configures 1-minute gathering periods for:
  - Image vulnerabilities (CVE, deployment, namespace)
  - Policy violations (deployment, namespace)
  - Node vulnerabilities (component, CVE, node)
- Applies configuration via RHACS API

**Requirements**: `ROX_API_TOKEN` environment variable

### 03-deploy-monitoring-stack.sh
Deploys Prometheus authentication and the MonitoringStack.

**Actions**:
- Creates ServiceAccount: `sample-stackrox-prometheus`
- Creates token secret for authentication
- Applies RHACS RBAC configuration via ConfigMap
- Deploys MonitoringStack CR
- Deploys ScrapeConfig CR for RHACS metrics

### 04-deploy-perses-dashboard.sh
Deploys Perses dashboard and verifies the complete installation.

**Actions**:
- Creates Perses datasource (pointing to Prometheus)
- Creates Perses dashboard with RHACS security metrics
- Enables UI plugin for console integration
- Verifies all resources are created
- Displays access information

## What Gets Installed

#### 1. Cluster Observability Operator
- Namespace: `openshift-cluster-observability-operator`
- Provides: MonitoringStack, ScrapeConfig CRDs
- Includes: Perses operator for dashboards

#### 2. RHACS Authentication
- **ServiceAccount**: `sample-stackrox-prometheus`
- **Secret**: `sample-stackrox-prometheus-token` (long-lived token)
- **ConfigMap**: Declarative RBAC configuration for metrics access

#### 3. MonitoringStack
- Dedicated Prometheus instance in `stackrox` namespace
- Configured to scrape RHACS Central metrics endpoint
- 1-day retention, resource limits configured
- Automatic alerting capabilities

#### 4. Perses Dashboards
- **Dashboard**: "Advanced Cluster Security / Overview"
- **Datasource**: Connected to Prometheus
- **UI Plugin**: Enabled for OpenShift console integration

## Dashboard Features

The installed dashboard provides real-time monitoring of:

### Policy Compliance
- Total policy violations
- Total policies enabled
- Violations by severity (CRITICAL, HIGH, MEDIUM, LOW)
- Violations over time with trends

### Vulnerability Management
- Total vulnerabilities across all assets
- Fixable vulnerabilities in user workloads
- Vulnerabilities by severity
- Vulnerabilities by asset type (images, nodes)
- Fixable vulnerability trends

### Cluster Health
- Cluster status and upgradability
- Certificate expiration monitoring
- Component health status

### Interactive Filtering
- Filter by **Cluster** name
- Filter by **Namespace**
- Multi-select support
- 30-day time range with 1-minute refresh

## Accessing the Dashboard

### Via OpenShift Console

1. **Open OpenShift Console**
   ```bash
   oc get route console -n openshift-console -o jsonpath='https://{.spec.host}'
   ```

2. **Navigate to Observe → Dashboards**
   - Click "Observe" in left navigation
   - Select "Dashboards"

3. **Open RHACS Dashboard**
   - Find: "Advanced Cluster Security / Overview"
   - Click to view real-time metrics

### Via Prometheus (Direct Access)

```bash
# Port-forward to Prometheus
oc port-forward -n stackrox -l app.kubernetes.io/name=prometheus 9090:9090

# Open in browser
open http://localhost:9090
```

## Monitoring Configuration

All monitoring resources are stored in the `monitoring/` subdirectory:

```
monitoring/
├── rhacs/
│   └── declarative-configuration-configmap.yaml  # RBAC for Prometheus
├── cluster-observability-operator/
│   ├── service-account.yaml                      # ServiceAccount + token
│   ├── monitoring-stack.yaml                     # MonitoringStack CR
│   └── scrape-config.yaml                        # ScrapeConfig CR
└── perses/
    ├── datasource.yaml                           # Prometheus datasource
    ├── dashboard.yaml                            # RHACS security dashboard
    └── ui-plugin.yaml                            # Console integration
```

## RHACS Metrics

The dashboard visualizes metrics collected from RHACS:

### Image Vulnerabilities
- `rox_central_image_vuln_cve_severity`
- `rox_central_image_vuln_deployment_severity`
- `rox_central_image_vuln_namespace_severity`

### Policy Violations
- `rox_central_policy_violation_deployment_severity`
- `rox_central_policy_violation_namespace_severity`

### Node Vulnerabilities
- `rox_central_node_vuln_component_severity`
- `rox_central_node_vuln_cve_severity`
- `rox_central_node_vuln_node_severity`

### System Metrics
- `rox_central_health_cluster_info` - Cluster health
- `rox_central_cfg_total_policies` - Policy counts
- `rox_central_cert_exp_hours` - Certificate expiry

All metrics are gathered every **1 minute** for real-time visibility.

## Troubleshooting

### Operator Installation Fails

If the Cluster Observability Operator installation gets stuck:

```bash
# Check subscription
oc get subscriptions.operators.coreos.com -n openshift-cluster-observability-operator

# Check CSV
oc get csv -n openshift-cluster-observability-operator

# Check events
oc get events -n openshift-cluster-observability-operator --sort-by='.lastTimestamp'

# Use the fix script (from project root)
cd ..
./fix-cluster-observability-operator.sh
```

### Dashboard Not Appearing

```bash
# Verify Perses resources exist
oc get persesdashboard -n stackrox
oc get persesdatasource -n stackrox
oc get uiplugin monitoring

# Restart console to reload plugins
oc delete pods -n openshift-console -l app=console
```

### No Metrics in Dashboard

```bash
# Check MonitoringStack is running
oc get monitoringstack sample-stackrox-monitoring-stack -n stackrox
oc get pods -n stackrox | grep prometheus

# Verify RHACS metrics are configured
# (Should show 1-minute gathering periods)
export ROX_API_TOKEN="your-token"
export ROX_CENTRAL_URL="https://your-central-url"
curl -k -H "Authorization: Bearer ${ROX_API_TOKEN}" \
  "${ROX_CENTRAL_URL}/v1/config" | jq '.privateConfig.metrics'

# Test metrics endpoint directly
export SA_TOKEN=$(oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d)
export CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='https://{.spec.host}')
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "${CENTRAL_URL}/metrics"
```

### MonitoringStack Not Creating Prometheus

```bash
# Check MonitoringStack status
oc get monitoringstack sample-stackrox-monitoring-stack -n stackrox -o yaml

# Check operator logs
oc logs -n openshift-cluster-observability-operator -l app.kubernetes.io/name=cluster-observability-operator

# Verify CRDs exist
oc api-resources --api-group=monitoring.rhobs
```

## Verification

Check the installation status:

```bash
# From project root
./check-monitoring-status.sh

# Or manually verify
oc get csv -n openshift-cluster-observability-operator
oc get monitoringstack -n stackrox
oc get persesdashboard -n stackrox
oc get uiplugin monitoring
```

## Uninstalling

To remove the advanced monitoring setup:

```bash
# Remove dashboard resources
oc delete persesdashboard sample-stackrox-dashboard -n stackrox
oc delete persesdatasource sample-stackrox-datasource -n stackrox
oc delete uiplugin monitoring

# Remove monitoring stack
oc delete monitoringstack sample-stackrox-monitoring-stack -n stackrox
oc delete scrapeconfig sample-stackrox-scrape-config -n stackrox

# Remove authentication
oc delete serviceaccount sample-stackrox-prometheus -n stackrox
oc delete secret sample-stackrox-prometheus-token -n stackrox
oc delete configmap sample-stackrox-prometheus-declarative-configuration -n stackrox

# Optionally remove operator
oc delete subscription cluster-observability-operator -n openshift-cluster-observability-operator
oc delete namespace openshift-cluster-observability-operator
```

## Integration with Basic Setup

The advanced setup is **independent** but works best after basic setup:

1. **Basic Setup** (`../basic-setup/install.sh`):
   - Installs Compliance Operator
   - Deploys demo applications
   - **Configures RHACS metrics** (enables telemetry, sets gathering periods)
   - Sets up compliance scanning

2. **Advanced Setup** (`./install.sh`):
   - Installs monitoring infrastructure
   - Creates Prometheus scraping
   - Deploys OpenShift console dashboards

**Recommended order**:
```bash
# 1. Basic setup first
cd basic-setup
./install.sh [PASSWORD]

# 2. Then advanced setup
cd ../advanced-setup
./install.sh
```

## Benefits

### vs. Basic Setup
- ✅ **OpenShift Console Integration** - Dashboards in native UI
- ✅ **Interactive Visualizations** - Charts, graphs, tables
- ✅ **Real-time Updates** - 1-minute refresh interval
- ✅ **Advanced Filtering** - By cluster, namespace, severity
- ✅ **Alerting Capabilities** - Via MonitoringStack

### vs. Manual Configuration
- ✅ **Automated** - Single command installation
- ✅ **Pre-built Dashboard** - Production-ready RHACS dashboard
- ✅ **Proper Authentication** - ServiceAccount with RBAC
- ✅ **Validated** - Tested configuration patterns

## References

- [RHACS Monitoring Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/operating/monitoring-using-prometheus)
- [Cluster Observability Operator](https://docs.openshift.com/container-platform/latest/observability/cluster_observability_operator/cluster-observability-operator-overview.html)
- [Perses Documentation](https://perses.dev/)
- [Dashboard Setup Guide](../DASHBOARD_SETUP_GUIDE.md)
- [Monitoring README](./monitoring/README.md)
