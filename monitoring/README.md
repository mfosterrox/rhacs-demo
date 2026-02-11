# RHACS Comprehensive Monitoring Setup

This directory contains configuration files and manifests for a complete RHACS monitoring solution with the Cluster Observability Operator and Prometheus.

## Overview

This monitoring setup provides:
- **RHACS API Configuration**: Enables telemetry and custom metrics collection
- **Certificate-based Authentication**: TLS certificates for secure Prometheus access
- **Cluster Observability Operator**: Production-grade monitoring infrastructure
- **Custom Metrics**: Image vulnerabilities, policy violations, node vulnerabilities
- **Auto-renewal**: Automatic certificate rotation with cert-manager (when available)

RHACS Central exposes Prometheus metrics on the `/metrics` endpoint (port 443/https). All access is authenticated and uses TLS encryption.

## Components

### Manifests

**Pre-configured** (in `monitoring/manifests/`):
- **declarative-configuration-configmap.yaml**: RHACS Permission Set and Role for Prometheus
  - Grants read-only access to Administration, Alert, Cluster, Deployment, Image, etc.
  - Required for Prometheus authentication and authorization

**Auto-generated** (by script):
- **monitoring-stack.yaml**: MonitoringStack resource for Cluster Observability Operator
- **scrape-config.yaml**: ScrapeConfig for RHACS Central metrics endpoint with TLS authentication

### Setup Script

The `setup/06-setup-monitoring.sh` script provides a complete monitoring solution:

1. **RHACS Configuration**: Configures telemetry, metrics collection, and retention policies via API
2. **Certificate Generation**: Creates TLS certificates (cert-manager or openssl fallback)
3. **Declarative RBAC**: Applies Permission Set and Role for Prometheus access
4. **Operator Installation**: Installs and configures Cluster Observability Operator
5. **Monitoring Stack**: Deploys MonitoringStack with Prometheus and custom scrape configs
6. **Custom Metrics**: Enables comprehensive metrics for vulnerabilities and policy violations
7. **Central CR Integration**: Automatically configures Central to use declarative configuration
8. **Idempotent**: Safe to run multiple times, skips already-configured components

## RHACS Metrics

### Fixed Metrics (Gathered Hourly)

- `rox_central_health_cluster_info` - Cluster health status
- `rox_central_cfg_total_policies` - Total number of policies
- `rox_central_cert_exp_hours` - Certificate expiration time

### Customizable Metrics

Configured with 10-minute gathering period:

- `rox_central_image_vuln_deployment_severity` - Image vulnerabilities by deployment
  - Labels: Cluster, Namespace, Deployment, IsPlatformWorkload, IsFixable, Severity
- `rox_central_image_vuln_namespace_severity` - Image vulnerabilities by namespace
  - Labels: Cluster, Namespace, Severity

## RBAC and Authorization

The monitoring setup configures proper RBAC permissions for Prometheus:

### Declarative Configuration

The **stackrox-prometheus-declarative-configuration** ConfigMap defines:

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

This ConfigMap is automatically:
1. Applied to the `stackrox` namespace
2. Referenced in the Central CR's `declarativeConfiguration.configMaps`
3. Used by RHACS to authorize Prometheus scrape requests

## Authentication

The monitoring setup uses **User Certificate (TLS)** authentication:

- **Common Name**: `stackrox-monitoring-prometheus.stackrox.svc`
- **Secret Name**: `stackrox-prometheus-tls`
- **Validity**: 365 days
- **Auto-renewal**: Enabled (if cert-manager is available)

### Certificate Generation Methods

The setup script automatically detects the best method for certificate generation:

1. **cert-manager (Recommended)**: If cert-manager is installed in the cluster, the script creates a Certificate resource with automatic renewal configured. Certificates will be renewed 30 days before expiration.

2. **OpenSSL (Fallback)**: If cert-manager is not available, the script uses openssl to generate a self-signed certificate. Manual renewal is required after 365 days.

## Usage

### Automatic Setup

The monitoring configuration is automatically deployed when running the main installation script:

```bash
./install.sh <password>
```

### Manual Setup

To run the monitoring setup separately:

```bash
cd setup
./06-setup-monitoring.sh
```

### Testing Access

Test the metrics endpoint with the generated certificate:

```bash
# Get the certificate and key from the secret
oc extract secret/stackrox-prometheus-tls -n stackrox --to=/tmp --confirm

# Test the metrics endpoint
curl --cert /tmp/tls.crt --key /tmp/tls.key \
  https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')/metrics
```

### Prometheus Configuration

To configure Prometheus to scrape RHACS metrics:

```yaml
scrape_configs:
  - job_name: 'rhacs-central'
    scheme: https
    tls_config:
      cert_file: /etc/prometheus/secrets/stackrox-prometheus-tls/tls.crt
      key_file: /etc/prometheus/secrets/stackrox-prometheus-tls/tls.key
      insecure_skip_verify: true
    static_configs:
      - targets:
        - central.stackrox.svc:443
    metrics_path: /metrics
```

## References

- [RHACS Monitoring Documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/monitor-acs)
- [StackRox Monitoring Examples](https://github.com/stackrox/monitoring-examples)
- [OpenShift Cluster Observability Operator](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator)

## Security Considerations

1. **Certificate Rotation**: The generated certificate is valid for 365 days. Plan for certificate rotation before expiration.
2. **Secret Protection**: The TLS secret contains sensitive credentials. Ensure proper RBAC policies are in place.
3. **Read-Only Access**: The Prometheus role only grants read access to metrics endpoints.
4. **Network Policies**: Consider implementing network policies to restrict access to the metrics endpoint.

## Troubleshooting

### Certificate Issues

If you need to regenerate the certificate:

```bash
# For cert-manager certificates
oc delete certificate stackrox-prometheus-cert -n stackrox
oc delete secret stackrox-prometheus-tls -n stackrox

# For openssl certificates
oc delete secret stackrox-prometheus-tls -n stackrox

# Re-run the monitoring setup
./setup/06-setup-monitoring.sh
```

### Verify cert-manager Installation

Check if cert-manager is installed and ready:

```bash
# Check if cert-manager CRDs are present
oc get crd certificates.cert-manager.io

# Check cert-manager deployment
oc get deployment -n cert-manager

# View certificate status
oc get certificate -n stackrox
oc describe certificate stackrox-prometheus-cert -n stackrox
```

### Authentication Failures

Check the RHACS auth provider configuration:

```bash
# List auth providers
curl -k -u admin:$ROX_PASSWORD \
  https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')/v1/authProviders | jq
```

### Missing Metrics

Verify custom metrics configuration:

```bash
# Get current metrics configuration
curl -k -u admin:$ROX_PASSWORD \
  https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')/v1/config | \
  jq '.privateConfig.metrics'
```
