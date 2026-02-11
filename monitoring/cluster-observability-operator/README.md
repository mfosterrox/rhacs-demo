# Cluster Observability Operator - RHACS Monitoring

This directory contains manifests for monitoring RHACS using the Cluster Observability Operator with **Service Account Token authentication**.

## Prerequisites

- OpenShift 4.14+ with Cluster Observability Operator installed
- RHACS 4.9+ installed in the `stackrox` namespace
- RHACS declarative configuration enabled

## Components

### 1. Service Account (`service-account.yaml`)

Creates a Kubernetes ServiceAccount and a long-lived token secret:

```yaml
ServiceAccount: sample-stackrox-prometheus
Secret: sample-stackrox-prometheus-token (type: kubernetes.io/service-account-token)
```

The token in this secret is automatically generated and managed by Kubernetes.

### 2. MonitoringStack (`monitoring-stack.yaml`)

Deploys a Prometheus instance using the Cluster Observability Operator:

- **Name**: `sample-stackrox-monitoring-stack`
- **Replicas**: 1
- **Retention**: 1 day
- **Resource Selector**: Matches resources with `app: central` label

### 3. ScrapeConfig (`scrape-config.yaml`)

Configures Prometheus to scrape RHACS Central metrics endpoint:

- **Endpoint**: `central.stackrox.svc.cluster.local:443`
- **Scheme**: HTTPS
- **Authentication**: Bearer token from `sample-stackrox-prometheus-token` secret
- **TLS**: Uses service CA for verification

## Authentication Flow

1. Kubernetes creates a long-lived token for the ServiceAccount
2. The token is stored in the `sample-stackrox-prometheus-token` secret
3. RHACS declarative configuration (in `../rhacs/`) creates:
   - Permission Set: "Prometheus Server" with read-only access
   - Role: "Prometheus Server" 
   - Binding: Links the ServiceAccount to the Role
4. Prometheus uses the Bearer token to authenticate to RHACS `/metrics` endpoint

## Deployment

Deploy all manifests:

```bash
oc apply -f monitoring/cluster-observability-operator/
```

Or use the automated setup script:

```bash
./setup/06-setup-monitoring.sh
```

## Verification

Check that all resources are created:

```bash
# Service Account
oc get serviceaccount sample-stackrox-prometheus -n stackrox

# Token Secret (should have a token value)
oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d

# MonitoringStack
oc get monitoringstack sample-stackrox-monitoring-stack -n stackrox

# ScrapeConfig
oc get scrapeconfig sample-stackrox-scrape-config -n stackrox

# Prometheus Pods
oc get pods -n stackrox -l app.kubernetes.io/name=prometheus
```

Test the metrics endpoint:

```bash
# Get the token
TOKEN=$(oc get secret sample-stackrox-prometheus-token -n stackrox -o jsonpath='{.data.token}' | base64 -d)

# Test metrics access
oc exec -n stackrox deployment/central -- curl -k -H "Authorization: Bearer $TOKEN" https://central.stackrox.svc:443/metrics
```

## Troubleshooting

### No metrics being scraped

1. Check Prometheus logs:
   ```bash
   oc logs -n stackrox -l app.kubernetes.io/name=prometheus --tail=100
   ```

2. Verify the token exists:
   ```bash
   oc get secret sample-stackrox-prometheus-token -n stackrox
   ```

3. Check RHACS declarative configuration was applied:
   ```bash
   oc logs -n stackrox deployment/central | grep -i declarative
   ```

### Authentication errors (401/403)

- Ensure declarative configuration is properly applied
- Verify the ServiceAccount name matches in both the secret and declarative config
- Check RHACS logs for authentication failures:
  ```bash
  oc logs -n stackrox deployment/central | grep -i auth
  ```

## Why Service Account Tokens?

**Advantages for demos:**
- ✅ Simple, Kubernetes-native authentication
- ✅ No certificate generation required
- ✅ Automatic token lifecycle management
- ✅ Easy to troubleshoot
- ✅ Production-grade security

**Compared to TLS certificates:**
- No CN matching issues
- No certificate expiration concerns during demos
- Fewer dependencies (no cert-manager or OpenSSL required)
