# RHACS Monitoring Installation Guide

This guide explains how to use the `install.sh` script to set up comprehensive monitoring for RHACS using the Cluster Observability Operator and Perses.

## Quick Start

```bash
cd monitoring-setup
./install.sh
```

The script will automatically handle everything!

## What the Script Does

### 1. **Prerequisites Check**
- Validates `oc`/`kubectl` is installed and connected
- Checks for `openssl`
- Verifies the `stackrox` namespace exists
- Confirms cluster admin privileges

### 2. **ROX Central URL Configuration**
- Automatically detects ROX Central URL from route/ingress
- Exports `ROX_CENTRAL_URL` environment variable
- **Stores it in `~/.bashrc` for persistence**

### 3. **API Token Management**
- Checks if `ROX_API_TOKEN` exists in environment or `~/.bashrc`
- If not **found, **automatically generates** an API token using admin credent**ials
- **Stores `ROX_API_TOKEN` in `~/.bashrc` for future use**
- Creates Kubernetes secret for Prometheus to use

### 4. **TLS Certificate Generation**
- Generates TLS certificates for Prometheus authentication
- Creates Kubernetes secret with certificates
- **Automatically installs `roxctl` permanently** to `/usr/local/bin` or `~/.local/bin`
- **Automatically creates UserPKI auth provider in RHACS** using `roxctl`
- Configures the auth provider with Admin role for metrics access

### 5. **RHACS Configuration**
- Applies declarative configuration for Prometheus Server role
- Configures permissions for metrics access

### 6. **Cluster Observability Operator Installation**
- Creates operator namespace (`openshift-cluster-observability-operator`)
- Creates OperatorGroup with AllNamespaces mode
- Creates Subscription to install the operator
- Waits for operator to be ready

### 7. **Monitoring Stack Deployment**
- Installs MonitoringStack CR (Prometheus, Alertmanager, Thanos)
- Configures ScrapeConfig to collect RHACS metrics
- All resources deployed to `stackrox` namespace

### 8. **Prometheus Resources**
- Installs Prometheus operator resources
- Configures additional scrape configs
- Sets up service monitors

### 9. **Perses Dashboard Installation**
- Installs Perses datasource
- Deploys RHACS monitoring dashboard
- Installs Perses UI plugin (cluster-scoped)

### 10. **Diagnostics**
- Tests TLS certificate authentication
- Tests API token authentication
- Displays all monitoring resources
- Shows connection status

## Environment Variables

After running the script, these variables are automatically set in `~/.bashrc`:

```bash
export ROX_CENTRAL_URL='https://central-stackrox.apps.your-cluster.com'
export ROX_API_TOKEN='eyJh...<your-token>...'
```

ßTo use them in a new shell session:

```bash
source ~/.bashrc
```
ß
## Namespace Configuration

The script uses the **`stackrox`** namespace by default. To use a different namespace:

```bash
export NAMESPACE='your-namespace'
./install.sh
```

## What Gets Installed

### System-Level:
- ✅ `roxctl` CLI permanently installed to `/usr/local/bin` or `~/.local/bin`

### In `stackrox` Namespace:
- ✅ TLS secret for Prometheus authentication
- ✅ API token secret for Prometheus
- ✅ MonitoringStack (Prometheus + Alertmanager)
- ✅ ScrapeConfig for RHACS metrics
- ✅ Prometheus custom resource
- ✅ Perses datasource
- ✅ Perses dashboard
- ✅ RHACS declarative configuration

### In `openshift-cluster-observability-operator` Namespace:
- ✅ Cluster Observability Operator
- ✅ OperatorGroup
- ✅ Subscription

### Cluster-Scoped:
- ✅ Perses UI plugin

## Accessing Monitoring

### Prometheus UI

```bash
kubectl port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090
```

Then open: http://localhost:9090

### View Metrics Directly

```bash
# Using API token
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/metrics

# Using TLS certificate (if generated)
curl --cert tls.crt --key tls.key -k $ROX_CENTRAL_URL/metrics
```

### Perses Dashboards

Check the OpenShift Console for the Perses UI plugin in the Observe menu.

## Authentication Methods

The script sets up **both** authentication methods:

### 1. **TLS Certificates** (Automatically configured)
- Certificate automatically generated
- UserPKI auth provider created in RHACS
- Prometheus uses certificate for authentication

### 2. **API Token** (Automatically configured)
- API token auto-generated or loaded from `~/.bashrc`
- Token stored in Kubernetes secret
- Token saved to `~/.bashrc` for manual use

## Troubleshooting

### Script fails at operator installation

**Issue**: Cluster Observability Operator installation timeout

**Solution**:
```bash
# Check operator status
oc get csv -n openshift-cluster-observability-operator

# Check subscription
oc get subscription cluster-observability-operator -n openshift-cluster-observability-operator

# View operator logs
oc logs -n openshift-cluster-observability-operator deployment/cluster-observability-operator
```

### API token not generated

**Issue**: Script cannot auto-generate API token

**Solution**:
```bash
# Manually create API token in RHACS UI
# Platform Configuration → Integrations → API Token
# Role: Admin

# Set it manually
export ROX_API_TOKEN='your-token-here'
echo "export ROX_API_TOKEN='your-token-here'" >> ~/.bashrc

# Re-run script
./install.sh
```

### Certificate authentication not working

**Issue**: `curl --cert` returns "credentials not found"

**Solution**:
The script should auto-configure this, but if it fails:
1. Check if roxctl is available: `which roxctl`
2. Verify auth provider was created: 
   ```bash
   roxctl -e $ROX_CENTRAL_URL:443 central userpki list --insecure-skip-tls-verify
   ```
3. If not created, run the auth configuration helper (if available) or create manually in RHACS UI

### Prometheus not scraping metrics

**Issue**: No RHACS metrics in Prometheus

**Solution**:
```bash
# Check Prometheus targets
kubectl port-forward -n stackrox svc/sample-stackrox-monitoring-stack-prometheus 9090:9090
# Open http://localhost:9090/targets

# Check scrape config
oc get scrapeconfig -n stackrox -o yaml

# Check Prometheus logs
oc logs -n stackrox -l app.kubernetes.io/name=prometheus
```

## Re-running the Script

The script is **idempotent** - safe to run multiple times. It will:
- Skip already-installed components
- Update existing configurations
- Reuse existing secrets and certificates

## Manual Cleanup

To remove all monitoring components:

```bash
# Delete monitoring resources
oc delete monitoringstack --all -n stackrox
oc delete scrapeconfig --all -n stackrox
oc delete prometheus --all -n stackrox
oc delete persesdashboard --all -n stackrox
oc delete persesdatasource --all -n stackrox

# Delete operator (optional)
oc delete subscription cluster-observability-operator -n openshift-cluster-observability-operator
oc delete csv -l operators.coreos.com/cluster-observability-operator -n openshift-cluster-observability-operator
oc delete namespace openshift-cluster-observability-operator

# Delete secrets
oc delete secret sample-stackrox-prometheus-tls -n stackrox
oc delete secret stackrox-prometheus-api-token -n stackrox
```

## Advanced Configuration

### Custom Metrics

After installation, configure custom RHACS metrics:

```bash
# View current metrics configuration
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k \
  $ROX_CENTRAL_URL/v1/config | jq '.privateConfig.metrics'

# Configure image vulnerability metrics
curl -H "Authorization: Bearer $ROX_API_TOKEN" -k $ROX_CENTRAL_URL/v1/config | \
  jq '.privateConfig.metrics.imageVulnerabilities = {
    gatheringPeriodMinutes: 10,
    descriptors: {
      deployment_severity: {
        labels: ["Cluster", "Namespace", "Deployment", "Severity"]
      }
    }
  } | { config: . }' | \
  curl -X PUT -H "Authorization: Bearer $ROX_API_TOKEN" -k \
    $ROX_CENTRAL_URL/v1/config --data-binary @-
```

### Alert Rules

Prometheus alert rules can be configured by editing:
```bash
oc edit prometheusrule -n stackrox
```

## Script Features Summary

✅ **Automatic API token generation and storage in `~/.bashrc`**  
✅ **Automatic ROX_CENTRAL_URL detection and storage in `~/.bashrc`**  
✅ **Automatic TLS certificate generation**  
✅ **Automatic UserPKI auth provider creation in RHACS**  
✅ **Complete Cluster Observability Operator installation**  
✅ **Full monitoring stack deployment (Prometheus + Alertmanager)**  
✅ **Perses dashboard installation**  
✅ **Comprehensive diagnostics and testing**  
✅ **Idempotent - safe to run multiple times**  
✅ **Error handling and recovery**  
✅ **Clear progress logging**

## Resources

- Main README: [README.md](README.md)
- RHACS Documentation: https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/
- Cluster Observability Operator: https://docs.redhat.com/en/documentation/red_hat_openshift_cluster_observability_operator/
- Monitoring Examples: [monitoring-examples/](monitoring-examples/)

---

**Need Help?** Check the diagnostics output at the end of the script run or review the main [README.md](README.md) for detailed troubleshooting.
