# RHACS Monitoring Configuration

This directory contains configuration files and manifests for setting up monitoring integration with Red Hat Advanced Cluster Security (RHACS).

## Overview

RHACS Central exposes Prometheus metrics on the `/metrics` endpoint (port 443/https). Access to these metrics requires authentication and proper authorization. This configuration sets up certificate-based authentication for Prometheus to securely access RHACS metrics.

## Components

### Manifests

- **declarative-configuration-configmap.yaml**: Defines the RHACS Permission Set and Role for Prometheus server access. This grants read-only access to the metrics endpoint.

### Setup Script

The `setup/06-setup-monitoring.sh` script automates the following:

1. **Certificate Generation**: Creates a TLS certificate and private key for Prometheus authentication
2. **Secret Creation**: Stores the certificate in a Kubernetes secret
3. **Auth Provider Configuration**: Configures RHACS User Certificate authentication provider
4. **Declarative Configuration**: Applies the Prometheus permissions and role via ConfigMap
5. **Custom Metrics Configuration**: Enables custom metrics for image vulnerabilities and policy violations

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
