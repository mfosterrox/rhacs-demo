# RHACS Monitoring Setup

This directory contains scripts and configurations to set up monitoring for Red Hat Advanced Cluster Security (RHACS) using the Cluster Observability Operator.

## Overview

The monitoring setup enables Prometheus to scrape metrics from RHACS Central API service on the `/metrics` endpoint (port 443/HTTPS). The access requires proper authentication and authorization.

## Prerequisites

- OpenShift or Kubernetes cluster with RHACS installed
- Cluster Observability Operator installed (for OpenShift)
- `kubectl` CLI tool
- `openssl` tool
- RHACS installed in the `stackrox` namespace (or set `NAMESPACE` environment variable)

## Environment Variables

The scripts use the following environment variables:

- `ROX_CENTRAL_URL`: Full URL to RHACS Central (e.g., `https://central-stackrox.apps.cluster.com`)
- `ROX_API_TOKEN`: API token for authentication

**Important for `roxctl` usage:**

The `roxctl` CLI expects `host:port` format for the `-e` flag and defaults to `https://`. If your `ROX_CENTRAL_URL` includes `https://`, strip it before using with `roxctl`:

```bash
# Correct usage with roxctl
export ROX_CENTRAL_URL="https://central-stackrox.apps.cluster.com"
ROX_ENDPOINT="${ROX_CENTRAL_URL#https://}"  # Strips https:// prefix
roxctl -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" central userpki list

# Alternative: use the helper function in the scripts
ROX_ENDPOINT=$(get_rox_endpoint)
roxctl -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" central userpki list
```

For `curl` commands, use the full URL with `https://`:

```bash
# Correct usage with curl
curl -k -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_URL/v1/auth/status"
```

## Quick Start

### Automated Setup

Run the comprehensive setup script:

```bash
cd monitoring-setup
./install.sh
```

**What this script does:**

1. Validates prerequisites (oc/kubectl, openssl)
2. Checks cluster admin privileges
3. Detects ROX Central URL and saves to `~/.bashrc`
4. Auto-generates or loads `ROX_API_TOKEN` and saves to `~/.bashrc`
5. Configures gRPC ALPN fix (`GRPC_ENFORCE_ALPN_ENABLED=false`)
6. Generates TLS certificates for Prometheus
7. Installs roxctl CLI permanently (if not already installed)
8. Creates UserPKI auth provider in RHACS
9. Applies RHACS declarative configuration
10. Installs Cluster Observability Operator
11. Deploys monitoring stack (Prometheus + Alertmanager)
12. Installs Prometheus resources
13. Deploys Perses dashboards
14. Runs comprehensive diagnostics

**Note**: The script is idempotent and safe to run multiple times.

### Option 2: Manual Setup

If you prefer to set up components individually:

1. **Generate TLS certificates for testing:**
   ```bash
   cd monitoring-examples/cluster-observability-operator
   ./generate-test-user-certificate.sh
   ```

2. **Apply RHACS declarative configuration:**
   ```bash
   kubectl apply -f monitoring-examples/rhacs/declarative-configuration-configmap.yaml
   ```

3. **Deploy monitoring stack:**
   ```bash
   kubectl apply -f monitoring-examples/cluster-observability-operator/monitoring-stack.yaml
   ```

4. **Configure scrape settings:**
   ```bash
   kubectl apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml
   ```

## Authentication Methods

RHACS supports multiple authentication methods for Prometheus:

### 1. API Token (Recommended for Production)

Create an API token in RHACS with the "Prometheus Server" role:

1. In RHACS UI: **Platform Configuration** → **Integrations** → **API Token**
2. Create a new token with "Prometheus Server" role
3. Store the token in a secret:
   ```bash
   export ROX_API_TOKEN='your-token-here'
   kubectl create secret generic stackrox-prometheus-api-token \
     -n stackrox \
     --from-literal=token="$ROX_API_TOKEN"
   ```

### 2. TLS Certificates (Testing)

For testing purposes, you can use TLS client certificates:

1. Generate certificates using the provided script:
   ```bash
   cd monitoring-examples/cluster-observability-operator
   ./generate-test-user-certificate.sh
   ```

2. Configure User Certificates auth provider in RHACS:
   - Go to **Platform Configuration** → **Access Control** → **Auth Providers**
   - Add a new User Certificates provider
   - Upload the certificate (`tls.crt`)
   - Create a user with the certificate's CN as Subject
   - Assign the "Prometheus Server" role

3. Test access:
   ```bash
   export ROX_CENTRAL_URL='https://your-central-url'
   curl --cert tls.crt --key tls.key $ROX_CENTRAL_URL/v1/auth/status
   ```

**Detailed Instructions**: See [CERTIFICATE-AUTH-GUIDE.md](CERTIFICATE-AUTH-GUIDE.md) for step-by-step configuration with screenshots and troubleshooting.

### 3. Service Account Token

You can also use Kubernetes service account tokens:

- **OpenShift OAuth provider**: Use long-lived service account token as client key
- **Short-lived projected token**: Configure via additional scrape config file
- **Generated token secret**: Create a secret of type `kubernetes.io/service-account-token`

## RHACS Configuration

### Permission Set and Role

The setup creates a permission set and role for Prometheus with read access to:

- Administration
- Alert
- Cluster
- Deployment
- Image
- Integration
- Namespace
- Node
- WorkflowAdministration

These permissions are defined in `monitoring-examples/rhacs/declarative-configuration-configmap.yaml`.

### Configuring Custom Metrics

RHACS exposes both fixed and customizable metrics:

**Fixed metrics** (gathered once per hour):
- `rox_central_health_cluster_info` - Cluster health
- `rox_central_cfg_total_policies` - Total policy numbers
- `rox_central_cert_exp_hours` - Certificate expiry

**Customizable metrics**:
- `rox_central_image_vuln_<name>` - Image vulnerabilities
- `rox_central_node_vuln_<name>` - Node vulnerabilities
- `rox_central_policy_violation_<name>` - Policy violations

To configure custom metrics:

```bash
# Get current configuration
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/v1/config | jq

# Set custom metrics (example: image vulnerabilities)
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/v1/config | \
  jq '.privateConfig.metrics.imageVulnerabilities = {
        gatheringPeriodMinutes: 10,
        descriptors: {
          deployment_severity: {
            labels: ["Cluster", "Namespace", "Deployment", "IsPlatformWorkload", "IsFixable", "Severity"]
          },
          namespace_severity: {
            labels: ["Cluster", "Namespace", "Severity"]
          }
        }
      } | { config: . }' | \
  curl -X PUT -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/v1/config --data-binary @-
```

## Monitoring Stack

The Cluster Observability Operator deploys a namespaced monitoring stack that includes:

- **Prometheus**: Metrics collection and storage
- **Alertmanager**: Alert handling and routing
- **Thanos Querier**: Multi-cluster querying (optional)

### Configuration

The monitoring stack configuration (`monitoring-stack.yaml`) includes:

```yaml
spec:
  alertmanagerConfig:
    disabled: false
  prometheusConfig:
    replicas: 1
  resourceSelector:
    matchLabels:
      app: central
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 256Mi
  retention: 1d
```

### Accessing Prometheus UI

Forward the Prometheus port:

```bash
kubectl port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090
```

Then open http://localhost:9090 in your browser.

## Diagnostics

### Check Monitoring Resources

```bash
kubectl get all -n stackrox | grep -E "(prometheus|monitoring|alertmanager)"
```

### Check Secrets

```bash
kubectl get secrets -n stackrox | grep -E "(prometheus|tls|token)"
```

### Check MonitoringStack Status

```bash
kubectl get monitoringstack -n stackrox
kubectl describe monitoringstack sample-stackrox-monitoring-stack -n stackrox
```

### Check ScrapeConfig Status

```bash
kubectl get scrapeconfig -n stackrox
kubectl describe scrapeconfig sample-stackrox-scrape-config -n stackrox
```

### Test Authentication

**With TLS certificates:**
```bash
export ROX_CENTRAL_URL='https://your-central-url'
curl --cert tls.crt --key tls.key -k $ROX_CENTRAL_URL/v1/auth/status
curl --cert tls.crt --key tls.key -k $ROX_CENTRAL_URL/metrics
```

**With API token:**
```bash
export ROX_API_TOKEN='your-token-here'
export ROX_CENTRAL_URL='https://your-central-url'
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/v1/auth/status
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/metrics
```

### View Prometheus Logs

```bash
kubectl logs -n stackrox -l app.kubernetes.io/name=prometheus -f
```

## Troubleshooting

### Issue: Client certificate authentication fails with "credentials not found"

**Symptoms:** `curl --cert client.crt --key client.key -k $ROX_CENTRAL_URL/v1/auth/status` returns `{"code":16, "message":"credentials not found"}`

**Root cause:** The group mapping (role assignment) for the auth provider wasn't created or hasn't propagated yet.

**Solution:**

1. **Run the troubleshooting script:**
   ```bash
   cd monitoring-setup
   ./troubleshoot-auth.sh
   ```
   
   This script will:
   - Verify the auth provider is configured
   - Check if group mappings exist
   - Automatically create missing group mappings
   - Test client certificate authentication
   - Provide specific guidance based on the issue found

2. **Wait for propagation:** Auth changes can take 10-30 seconds to propagate. Wait a moment and test again.

3. **Manual fix via UI:**
   - Go to RHACS UI: **Platform Configuration** → **Access Control** → **Groups**
   - Create a new group:
     - **Auth Provider**: Monitoring
     - **Key**: (leave empty)
     - **Value**: (leave empty)
     - **Role**: Admin

4. **Manual fix via API:**
   ```bash
   # Get the auth provider ID
   AUTH_PROVIDER_ID=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
     "$ROX_CENTRAL_URL/v1/authProviders" | \
     grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)
   
   # Create the group
   curl -k -X POST "$ROX_CENTRAL_URL/v1/groups" \
     -H "Authorization: Bearer $ROX_API_TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Admin\"}"
   ```

### Issue: Prometheus can't scrape RHACS metrics

**Symptoms:** No metrics appearing in Prometheus

**Solutions:**
1. Verify authentication is configured correctly
2. Check if the scrape config has the correct TLS settings
3. Verify the service CA certificate is available:
   ```bash
   kubectl get secret service-ca -n stackrox
   ```
4. Check Prometheus logs for errors:
   ```bash
   kubectl logs -n stackrox -l app.kubernetes.io/name=prometheus -f
   ```

### Issue: TLS certificate authentication fails

**Symptoms:** `curl --cert tls.crt --key tls.key` returns 401 or 403

**Solutions:**
1. Verify User Certificates auth provider is configured in RHACS
2. Ensure the certificate CN matches the expected format
3. Check if the certificate is properly uploaded in RHACS
4. Verify the "Prometheus Server" role is assigned

### Issue: API token authentication fails

**Symptoms:** `curl -H "Authorization: Bearer $ROX_API_TOKEN"` returns 401 or 403

**Solutions:**
1. Verify the API token is valid and not expired
2. Check if the token has the "Prometheus Server" role
3. Ensure the secret is created correctly:
   ```bash
   kubectl get secret stackrox-prometheus-api-token -n stackrox -o yaml
   ```

### Issue: MonitoringStack not deploying

**Symptoms:** MonitoringStack resource exists but Prometheus pods don't start

**Solutions:**
1. Check if Cluster Observability Operator is installed:
   ```bash
   kubectl get csv -A | grep observability
   ```
2. Check operator logs:
   ```bash
   kubectl logs -n openshift-operators -l app.kubernetes.io/name=cluster-observability-operator
   ```
3. Verify resource quotas and limits in the namespace

## Directory Structure

```
monitoring-setup/
├── README.md                           # This file
├── INSTALL-GUIDE.md                    # Detailed installation guide
├── install.sh                          # Main installation script
└── monitoring-examples/                # Configuration examples
    ├── README.md                       # General overview
    ├── rhacs/                          # RHACS-specific configuration
    │   ├── README.md
    │   └── declarative-configuration-configmap.yaml
    ├── cluster-observability-operator/ # COO configuration
    │   ├── README.md
    │   ├── monitoring-stack.yaml
    │   ├── scrape-config.yaml
    │   └── generate-test-user-certificate.sh
    ├── prometheus-operator/            # Prometheus Operator examples
    │   ├── README.md
    │   ├── prometheus.yaml
    │   └── additional-scrape-config.yaml
    └── perses/                         # Dashboard examples
        ├── README.md
        ├── dashboard.yaml
        ├── datasource.yaml
        └── ui-plugin.yaml
```

## Resources

- **RHACS Documentation**: [Red Hat Advanced Cluster Security for Kubernetes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/)
- **Cluster Observability Operator**: [OpenShift Monitoring Overview](https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/1-latest/)
- **Monitoring Examples Repository**: [stackrox/stackrox](https://github.com/stackrox/stackrox)

## License

See [LICENSE](monitoring-examples/LICENSE) file in the monitoring-examples directory.
