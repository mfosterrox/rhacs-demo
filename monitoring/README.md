# RHACS Monitoring Setup

This directory contains manifests and configuration for RHACS monitoring with the Cluster Observability Operator and Prometheus.

## Overview

This monitoring setup provides:
- **RHACS API Configuration**: Enables telemetry and custom metrics collection
- **Certificate-based Authentication**: TLS certificates for secure Prometheus access
- **RBAC Permissions**: Declarative configuration for Prometheus authorization
- **Monitoring Stack**: Prometheus deployment via Cluster Observability Operator
- **Simple Deployment**: Single command to apply all manifests

RHACS Central exposes Prometheus metrics on the `/metrics` endpoint (port 443/https) with TLS authentication.

## Directory Structure

```
monitoring/
├── manifests/
│   ├── declarative-configuration-configmap.yaml  # RHACS RBAC permissions
│   ├── monitoring-stack.yaml                     # MonitoringStack CR
│   └── scrape-config.yaml                        # ScrapeConfig CR
└── README.md
```

## Manifests

All manifests are pre-configured and version-controlled:

### declarative-configuration-configmap.yaml

Defines the **Prometheus Server** Role and Permission Set in RHACS:

**Permission Set** (Prometheus Server):
- Administration: READ_ACCESS
- Alert: READ_ACCESS
- Cluster: READ_ACCESS
- Deployment: READ_ACCESS
- Image: READ_ACCESS
- Integration: READ_ACCESS
- Namespace: READ_ACCESS
- Node: READ_ACCESS
- WorkflowAdministration: READ_ACCESS

**Role** (Prometheus Server):
- Access Scope: Unrestricted
- Permission Set: Prometheus Server

This ConfigMap is referenced in the Central CR's `spec.central.declarativeConfiguration.configMaps` to authorize Prometheus access.

### monitoring-stack.yaml

Defines the MonitoringStack custom resource for the Cluster Observability Operator:

- **Retention**: 7 days
- **Log Level**: info
- **Resource Requests**: 500m CPU, 2Gi memory
- **Resource Limits**: 1000m CPU, 4Gi memory
- **Resource Selector**: `app.kubernetes.io/part-of=rhacs-monitoring`
- **Alertmanager**: Enabled

### scrape-config.yaml

Configures Prometheus to scrape RHACS Central metrics:

- **Target**: `central.stackrox.svc.cluster.local:443`
- **Metrics Path**: `/metrics`
- **Scheme**: https
- **TLS Authentication**: Uses `stackrox-prometheus-tls` secret
- **Label**: `job=rhacs-central`

## Setup Script

The `setup/06-setup-monitoring.sh` script automates the monitoring deployment:

1. **Prerequisites Check**: Verifies oc, jq, curl, and cluster connection
2. **RHACS Verification**: Ensures RHACS is installed and ready
3. **RHACS Configuration**: Updates telemetry, metrics, and retention via API
4. **Certificate Generation**: Creates TLS certificate (cert-manager or openssl)
5. **Apply Manifests**: Runs `oc apply -f monitoring/ --recursive`
6. **Summary**: Displays deployed resources and access information

### Simple Deployment

```bash
# Automatic (via main install script)
./install.sh <password>

# Or standalone
./setup/06-setup-monitoring.sh
```

## RHACS Metrics

### Fixed Metrics (Gathered Hourly)

- `rox_central_health_cluster_info` - Cluster health status
- `rox_central_cfg_total_policies` - Total number of policies
- `rox_central_cert_exp_hours` - Certificate expiration time

### Custom Metrics (1-minute gathering period)

**Image Vulnerabilities**:
- `rox_central_image_vuln_cve_severity` - CVE vulnerabilities (Cluster, CVE, IsPlatformWorkload, IsFixable, Severity)
- `rox_central_image_vuln_deployment_severity` - Deployment vulnerabilities (Cluster, Namespace, Deployment, IsPlatformWorkload, IsFixable, Severity)
- `rox_central_image_vuln_namespace_severity` - Namespace vulnerabilities (Cluster, Namespace, IsPlatformWorkload, IsFixable, Severity)

**Policy Violations**:
- `rox_central_policy_viol_deployment_severity` - Deployment violations (Cluster, Namespace, Deployment, IsPlatformComponent, Action, Severity)
- `rox_central_policy_viol_namespace_severity` - Namespace violations (Cluster, Namespace, IsPlatformComponent, Action, Severity)

**Node Vulnerabilities**:
- `rox_central_node_vuln_component_severity` - Component vulnerabilities (Cluster, Node, Component, IsFixable, Severity)
- `rox_central_node_vuln_cve_severity` - CVE vulnerabilities (Cluster, CVE, IsFixable, Severity)
- `rox_central_node_vuln_node_severity` - Node vulnerabilities (Cluster, Node, IsFixable, Severity)

## Authentication

The monitoring setup uses **User Certificate (TLS)** authentication:

- **Common Name**: `stackrox-monitoring-prometheus.stackrox.svc`
- **Secret Name**: `stackrox-prometheus-tls`
- **Validity**: 365 days

### Certificate Generation Methods

The setup script automatically detects and uses the best method:

1. **cert-manager** (Recommended): If available, creates a Certificate resource with automatic renewal (30 days before expiration).
2. **openssl** (Fallback): Generates a self-signed certificate (manual renewal required after 365 days).

## Prerequisites

### Required

- **OpenShift/Kubernetes cluster** with oc/kubectl access
- **RHACS installed** and ready (Central deployment running)
- **Cluster Observability Operator** installed in the cluster

### Optional

- **cert-manager** for automatic certificate renewal

## Testing

### Verify Certificate

```bash
# Extract certificate from secret
oc extract secret/stackrox-prometheus-tls -n stackrox --to=/tmp --confirm

# Test metrics endpoint
curl --cert /tmp/tls.crt --key /tmp/tls.key \
  https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')/metrics
```

### Check Monitoring Resources

```bash
# Check ConfigMap
oc get configmap stackrox-prometheus-declarative-configuration -n stackrox

# Check MonitoringStack
oc get monitoringstack rhacs-monitoring-stack -n stackrox

# Check ScrapeConfig
oc get scrapeconfig rhacs-scrape-config -n stackrox

# Check Prometheus pods
oc get pods -n stackrox -l app.kubernetes.io/name=prometheus
```

### Verify Metrics Collection

```bash
# Port-forward to Prometheus
oc port-forward -n stackrox svc/prometheus-operated 9090:9090

# Query metrics (in browser or curl)
curl http://localhost:9090/api/v1/query?query=rox_central_image_vuln_deployment_severity
```

## Customization

All manifests are in git and can be customized before deployment:

### Adjust Retention Period

Edit `monitoring-stack.yaml`:

```yaml
spec:
  retention: 30d  # Change from 7d to 30d
```

### Modify Resource Limits

Edit `monitoring-stack.yaml`:

```yaml
spec:
  resources:
    requests:
      cpu: 1000m    # Increase from 500m
      memory: 4Gi   # Increase from 2Gi
```

### Add Scrape Targets

Edit `scrape-config.yaml` to add more targets:

```yaml
spec:
  staticConfigs:
  - targets:
    - central.stackrox.svc.cluster.local:443
    - scanner.stackrox.svc.cluster.local:8080  # Add scanner
```

## Troubleshooting

### Certificate Issues

Regenerate the certificate:

```bash
# For cert-manager
oc delete certificate stackrox-prometheus-cert -n stackrox
oc delete secret stackrox-prometheus-tls -n stackrox

# For openssl
oc delete secret stackrox-prometheus-tls -n stackrox

# Re-run setup
./setup/06-setup-monitoring.sh
```

### Verify cert-manager

```bash
# Check CRDs
oc get crd certificates.cert-manager.io

# Check certificate status
oc get certificate -n stackrox
oc describe certificate stackrox-prometheus-cert -n stackrox
```

### Check RHACS Configuration

```bash
# Verify metrics configuration
curl -k -u admin:$ROX_PASSWORD \
  https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')/v1/config | \
  jq '.privateConfig.metrics'

# List auth providers
curl -k -u admin:$ROX_PASSWORD \
  https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')/v1/authProviders | \
  jq
```

### Missing Metrics

1. Check RHACS telemetry is enabled: `jq '.publicConfig.telemetry.enabled'`
2. Verify gathering period is set: `jq '.privateConfig.metrics.imageVulnerabilities.gatheringPeriodMinutes'`
3. Check Prometheus is scraping: `oc logs -n stackrox -l app.kubernetes.io/name=prometheus`

## References

- [RHACS Monitoring Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs)
- [StackRox Monitoring Examples](https://github.com/stackrox/monitoring-examples)
- [OpenShift Cluster Observability Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator)

## Security Considerations

1. **Certificate Rotation**: Plan for renewal before 365-day expiration (automatic with cert-manager)
2. **Secret Protection**: Ensure proper RBAC policies for the TLS secret
3. **Read-Only Access**: Prometheus role only grants read access
4. **Network Policies**: Consider restricting access to the metrics endpoint
