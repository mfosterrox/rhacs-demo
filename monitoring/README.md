# RHACS Monitoring Setup

This directory contains monitoring configurations for Red Hat Advanced Cluster Security for Kubernetes (RHACS). The setup provides Prometheus metrics collection and visualization options.

## Overview

RHACS Central exposes Prometheus metrics on the `/metrics` endpoint (port 443/HTTPS) starting from version 4.9. These metrics include:

- **Image vulnerabilities** - CVE data across deployments and namespaces
- **Policy violations** - Security policy enforcement metrics
- **Node vulnerabilities** - Host/node security posture
- **Cluster health** - Overall cluster status and certificate expiry
- **Configuration metrics** - Total policies, enabled policies, etc.

## Directory Structure

```
monitoring/
├── README.md                           # This file
├── rhacs/                              # RHACS-specific configuration
│   ├── README.md                       # Detailed RHACS metrics documentation
│   └── declarative-configuration-configmap.yaml  # RBAC for Prometheus access
├── prometheus-operator/                # Prometheus Operator manifests
│   ├── README.md
│   ├── service-account.yaml           # ServiceAccount with token
│   ├── additional-scrape-config.yaml  # Secret with RHACS scrape config
│   └── prometheus.yaml                # Prometheus instance
├── cluster-observability-operator/     # Cluster Observability Operator manifests
│   ├── service-account.yaml           # ServiceAccount with token
│   ├── monitoring-stack.yaml          # MonitoringStack CR
│   └── scrape-config.yaml             # ScrapeConfig CR
└── perses/                            # Perses dashboard manifests
    ├── dashboard.yaml                 # RHACS security dashboard
    ├── datasource.yaml                # Prometheus datasource
    └── ui-plugin.yaml                 # OpenShift console integration
```

## Monitoring Solutions

The setup supports multiple monitoring solutions depending on which operators are installed:

### 1. Prometheus Operator (Recommended)

**Status**: ✓ Installed automatically via setup scripts  
**Location**: `prometheus-operator/`

The Prometheus Operator is part of OpenShift's built-in monitoring stack. The setup scripts enable "user workload monitoring" which allows deploying Prometheus instances in user namespaces.

**Features:**
- Lightweight and fast
- Native OpenShift integration
- ServiceAccount-based authentication
- Automatic service discovery

**Resources Created:**
- `ServiceAccount`: `sample-stackrox-prometheus`
- `Secret`: `sample-stackrox-prometheus-token` (long-lived SA token)
- `Secret`: `sample-stackrox-prometheus-additional-scrape-configs` (scrape config)
- `Prometheus`: `sample-stackrox-prometheus-server`

### 2. Cluster Observability Operator (Optional)

**Status**: ⊘ Not installed by default  
**Location**: `cluster-observability-operator/`

The Cluster Observability Operator provides a comprehensive monitoring stack with built-in alerting and multi-tenancy support.

**Installation:**
```bash
# Install via OperatorHub
oc create namespace openshift-cluster-observability-operator
oc apply -f - <<EOF
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
EOF
```

**Resources Created (when operator is installed):**
- `MonitoringStack`: `sample-stackrox-monitoring-stack`
- `ScrapeConfig`: `sample-stackrox-scrape-config`

**Documentation:**
- [Installing Cluster Observability Operator](https://docs.openshift.com/container-platform/latest/observability/cluster_observability_operator/installing-the-cluster-observability-operator.html)

### 3. Perses Dashboards (Optional)

**Status**: ⊘ Not installed by default  
**Location**: `perses/`

Perses provides advanced dashboard capabilities and native OpenShift console integration for visualizing RHACS metrics.

**Features:**
- Rich visualization options (charts, tables, stats)
- OpenShift console integration
- Dynamic variables (cluster, namespace filtering)
- Pre-built RHACS security dashboard

**Installation:**
```bash
# Install Perses Operator
oc apply -f https://github.com/perses/perses-operator/releases/latest/download/install.yaml
```

**Resources Created (when operator is installed):**
- `PersesDashboard`: `sample-stackrox-dashboard` (security metrics dashboard)
- `PersesDatasource`: `sample-stackrox-datasource` (Prometheus connection)
- `UIPlugin`: `monitoring` (console integration)

**Documentation:**
- [Perses Documentation](https://perses.dev/)
- [Perses Operator](https://github.com/perses/perses-operator)

## Installation

The monitoring setup is automatically configured when running the main installation script:

```bash
./install.sh [PASSWORD]
```

The installation process:

1. **Script 06**: Install monitoring operators
   - Enables OpenShift user workload monitoring
   - Activates Prometheus Operator for user namespaces

2. **Script 07**: Apply monitoring manifests
   - Creates ServiceAccount and authentication token
   - Configures RHACS declarative RBAC
   - Deploys Prometheus instance (if Prometheus Operator available)
   - Deploys MonitoringStack (if Cluster Observability Operator available)
   - Deploys Perses dashboards (if Perses available)

## Authentication

All monitoring solutions use **Kubernetes ServiceAccount Token authentication**:

1. ServiceAccount `sample-stackrox-prometheus` is created in the `stackrox` namespace
2. Long-lived token secret is created: `sample-stackrox-prometheus-token`
3. RHACS declarative configuration grants the SA access to the `/metrics` endpoint
4. Prometheus uses the token via Bearer authentication

### RHACS Role Configuration

The `declarative-configuration-configmap.yaml` defines:
- **Permission Set**: `prometheus-server` with read-only metrics access
- **Access Scope**: Limited to specific resource types
- **Role**: `Prometheus Server` bound to the ServiceAccount

## Accessing Metrics

### Via Prometheus UI

```bash
# Port-forward to Prometheus (Prometheus Operator)
oc port-forward -n stackrox svc/sample-stackrox-prometheus-server 9090:9090

# Open browser
open http://localhost:9090
```

### Via RHACS Central API

```bash
# Get SA token
export SA_TOKEN=$(oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d)

# Get Central URL
export CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='https://{.spec.host}')

# Query metrics
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "${CENTRAL_URL}/metrics"
```

### Via roxctl

```bash
# Export metrics using roxctl
roxctl central debug metrics
```

## Available Metrics

### Fixed Metrics (Always Available)

- `rox_central_health_cluster_info` - Cluster health status
- `rox_central_cfg_total_policies` - Total number of policies
- `rox_central_cert_exp_hours` - Certificate expiration times

### Configurable Metrics (Enabled via API)

The setup scripts automatically configure these metrics with 1-minute gathering periods:

#### Image Vulnerabilities
- `rox_central_image_vuln_cve_severity` - CVEs by severity
- `rox_central_image_vuln_deployment_severity` - Vulnerabilities per deployment
- `rox_central_image_vuln_namespace_severity` - Vulnerabilities per namespace

#### Policy Violations  
- `rox_central_policy_violation_deployment_severity` - Violations per deployment
- `rox_central_policy_violation_namespace_severity` - Violations per namespace

#### Node Vulnerabilities
- `rox_central_node_vuln_component_severity` - Component vulnerabilities
- `rox_central_node_vuln_cve_severity` - Node CVEs
- `rox_central_node_vuln_node_severity` - Vulnerabilities per node

## Metric Labels

Common labels across metrics:
- `Cluster` - Cluster name
- `Namespace` - Kubernetes namespace
- `Deployment` - Deployment name
- `Severity` - Security severity (CRITICAL, HIGH, MEDIUM, LOW)
- `IsFixable` - Whether vulnerability has a fix available
- `IsPlatformWorkload` - Whether it's a platform vs user workload

## Configuration

### Adjusting Gathering Periods

By default, metrics are gathered every minute. To adjust:

```bash
# Get current config
curl -k -H "Authorization: Bearer ${ROX_API_TOKEN}" \
  "${ROX_CENTRAL_URL}/v1/config" | jq '.privateConfig.metrics'

# Update gathering period (example: 5 minutes)
curl -k -X PUT \
  -H "Authorization: Bearer ${ROX_API_TOKEN}" \
  -H "Content-Type: application/json" \
  "${ROX_CENTRAL_URL}/v1/config" \
  -d '{
    "config": {
      "privateConfig": {
        "metrics": {
          "imageVulnerabilities": { "gatheringPeriodMinutes": 5 }
        }
      }
    }
  }'
```

### Adding Custom Metric Descriptors

See [rhacs/README.md](rhacs/README.md) for detailed examples of configuring custom metrics via the RHACS API.

## Troubleshooting

### Metrics Not Appearing

1. Check ServiceAccount token exists:
   ```bash
   oc get secret sample-stackrox-prometheus-token -n stackrox
   ```

2. Verify RHACS declarative config is applied:
   ```bash
   oc get configmap sample-stackrox-prometheus-declarative-configuration -n stackrox
   ```

3. Check Prometheus is scraping successfully:
   ```bash
   oc logs -n stackrox -l app.kubernetes.io/name=prometheus
   ```

4. Verify metrics are enabled in RHACS:
   ```bash
   curl -k -H "Authorization: Bearer ${ROX_API_TOKEN}" \
     "${ROX_CENTRAL_URL}/v1/config" | jq '.privateConfig.metrics'
   ```

### Authentication Failures

Check that the ServiceAccount has proper RBAC:

```bash
# Check role binding in RHACS
curl -k -H "Authorization: Bearer ${ROX_API_TOKEN}" \
  "${ROX_CENTRAL_URL}/v1/roles" | jq '.roles[] | select(.name=="Prometheus Server")'
```

### Operator Not Found Errors

If monitoring manifests fail to apply with "no matches for kind" errors:

```bash
# Check which operators are installed
oc get csv -A | grep -iE "prometheus|observability|perses"

# Check available API resources
oc api-resources --api-group=monitoring.coreos.com
oc api-resources --api-group=monitoring.rhobs
oc api-resources --api-group=perses.dev
```

The setup script will automatically skip manifests for operators that aren't installed.

## References

- [RHACS Monitoring Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/operating/monitoring-using-prometheus)
- [OpenShift Monitoring](https://docs.openshift.com/container-platform/latest/monitoring/monitoring-overview.html)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [Cluster Observability Operator](https://docs.openshift.com/container-platform/latest/observability/cluster_observability_operator/cluster-observability-operator-overview.html)
- [Perses](https://perses.dev/)
