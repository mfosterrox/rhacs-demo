# RHACS Custom TLS Configuration - Quick Reference

This document provides detailed information about configuring RHACS Central with custom TLS certificates using the Red Hat cert-manager Operator.

## Overview

The `07-configure-custom-tls.sh` script automates the configuration of RHACS Central with:
- **Passthrough route termination** (allows Central to serve its own certificate)
- **Custom TLS certificates** from Let's Encrypt
- **Automatic certificate renewal** via cert-manager

## Architecture

### Before Configuration
```
Internet → OpenShift Router → Route (reencrypt) → Central Service → Central Pod
                               ↓
                           Router terminates TLS
                           Re-encrypts with OpenShift certs
```

### After Configuration
```
Internet → OpenShift Router → Route (passthrough) → Central Service → Central Pod
                               ↓                                        ↓
                           Passes through TLS                    Serves custom cert
                           (no termination)
```

## Components

### 1. Red Hat cert-manager Operator
- **Namespace**: `cert-manager-operator`
- **Version**: 1.18.1 (stable-v1.18 channel)
- **Source**: Red Hat Operators (OperatorHub)
- **Components**:
  - `cert-manager-controller-manager` - Main controller
  - `cert-manager-cainjector` - CA injection
  - `cert-manager-webhook` - Validation webhook

### 2. ClusterIssuer
- **Type**: ACME (Automated Certificate Management Environment)
- **Provider**: Let's Encrypt
- **Challenge Type**: HTTP-01
- **Environments**:
  - **Production**: `letsencrypt-prod` → Trusted certificates
  - **Staging**: `letsencrypt-staging` → Test certificates (not trusted by browsers)

### 3. Certificate Resource
- **Name**: `central-tls-cert`
- **Namespace**: `stackrox` (or your RHACS namespace)
- **Secret**: `central-tls` (contains cert and key)
- **Duration**: 90 days
- **Renewal**: 15 days before expiry

### 4. Route Configuration
- **Termination**: `passthrough`
- **Target Port**: `https` (443)
- **Insecure Edge Policy**: `Redirect` (HTTP → HTTPS)

## Prerequisites

### Required
1. **OpenShift Cluster**
   - Cluster-admin access
   - Internet connectivity (for Let's Encrypt validation)

2. **RHACS Installation**
   - Central deployed and running
   - Route exists (typically `central`)

3. **DNS & Network**
   - Route hostname must be publicly accessible
   - Port 80 must be accessible (for HTTP-01 challenge)

4. **Email Address**
   - Valid email for Let's Encrypt registration
   - Used for certificate expiry notifications

### Optional
- Custom RHACS namespace (default: `stackrox`)
- Custom route name (default: `central`)

## Usage

### Basic Usage (Production)

```bash
cd basic-setup
./07-configure-custom-tls.sh --email admin@example.com
```

### Testing with Staging

```bash
# Use staging to test without hitting Let's Encrypt rate limits
./07-configure-custom-tls.sh --email admin@example.com --staging
```

### With Custom Namespace

```bash
export RHACS_NAMESPACE="my-rhacs"
export RHACS_ROUTE_NAME="central"
./07-configure-custom-tls.sh --email admin@example.com
```

## What the Script Does

### Step 1: Pre-flight Checks
- Verifies `oc` and `kubectl` are installed
- Checks cluster connectivity
- Validates cluster-admin permissions
- Confirms RHACS Central is deployed
- Verifies route exists

### Step 2: Install cert-manager Operator
- Creates `cert-manager-operator` namespace
- Creates OperatorGroup
- Creates Subscription (stable-v1.18 channel)
- Waits for CSV to reach "Succeeded" state
- Verifies all deployments are ready

### Step 3: Create ClusterIssuer
- Creates Let's Encrypt ClusterIssuer
- Configures HTTP-01 challenge solver
- Uses OpenShift default ingress class

### Step 4: Generate Certificate
- Creates Certificate resource
- Requests certificate from Let's Encrypt
- Waits for certificate issuance (up to 10 minutes)
- Stores cert/key in `central-tls` secret

### Step 5: Configure Central
- Updates Central CR (if operator-based)
- Or provides Helm values (if Helm-based)
- References `central-tls` secret

### Step 6: Update Route
- Changes termination from reencrypt/edge to passthrough
- Updates target port to `https`
- Maintains redirect from HTTP to HTTPS

### Step 7: Restart Central
- Rolls out Central deployment
- Waits for deployment to be ready
- Applies new TLS configuration

### Step 8: Verify Configuration
- Tests TLS connection
- Displays certificate details
- Shows summary and next steps

## Verification

### Check cert-manager Operator

```bash
# Check operator status
oc get csv -n cert-manager-operator

# Expected output:
# NAME                      VERSION   PHASE
# cert-manager.v1.18.1      1.18.1    Succeeded

# Check operator pods
oc get pods -n cert-manager-operator

# Expected output:
# NAME                                           READY   STATUS
# cert-manager-cainjector-...                    1/1     Running
# cert-manager-controller-manager-...            1/1     Running
# cert-manager-webhook-...                       1/1     Running
```

### Check Certificate Status

```bash
# Check certificate
oc get certificate -n stackrox

# Expected output:
# NAME               READY   SECRET         AGE
# central-tls-cert   True    central-tls    5m

# Detailed certificate info
oc describe certificate central-tls-cert -n stackrox
```

### Check Certificate Secret

```bash
# Verify secret exists
oc get secret central-tls -n stackrox

# View certificate details
oc get secret central-tls -n stackrox -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text
```

### Check Route Configuration

```bash
# View route
oc get route central -n stackrox -o yaml

# Check termination type (should be "passthrough")
oc get route central -n stackrox -o jsonpath='{.spec.tls.termination}'
```

### Test TLS Connection

```bash
# Get route URL
CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='https://{.spec.host}')

# Test with curl
curl -v $CENTRAL_URL

# Test with openssl
CENTRAL_HOST=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')
openssl s_client -connect $CENTRAL_HOST:443 -servername $CENTRAL_HOST
```

## Troubleshooting

### Certificate Not Issuing

**Symptoms**: Certificate stuck in "Issuing" or "False" state

**Check certificate status**:
```bash
oc describe certificate central-tls-cert -n stackrox
```

**Common causes**:

1. **HTTP-01 Challenge Failed**
   - Route not publicly accessible
   - Firewall blocking port 80
   - DNS not resolving correctly

   **Solution**: Verify route is accessible from internet
   ```bash
   ROUTE_HOST=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')
   curl -v http://$ROUTE_HOST/.well-known/acme-challenge/test
   ```

2. **Let's Encrypt Rate Limits**
   - Too many certificate requests
   - Production environment rate limited

   **Solution**: Use staging environment for testing
   ```bash
   ./07-configure-custom-tls.sh --email your@email.com --staging
   ```

3. **ClusterIssuer Not Ready**
   ```bash
   oc get clusterissuer
   oc describe clusterissuer letsencrypt-prod
   ```

**Check certificate request**:
```bash
oc get certificaterequest -n stackrox
oc describe certificaterequest -n stackrox
```

**Check ACME order and challenges**:
```bash
oc get order -n stackrox
oc get challenge -n stackrox
oc describe challenge -n stackrox
```

### Central Not Serving Custom Certificate

**Symptoms**: Browser shows old certificate or OpenShift default

**Check Central is using the secret**:
```bash
# For operator-based installations
oc get central stackrox-central-services -n stackrox -o yaml | grep -A 5 defaultTLS

# Check Central pod environment
oc get deployment central -n stackrox -o yaml | grep -A 10 volumes
```

**Restart Central**:
```bash
oc rollout restart deployment/central -n stackrox
oc rollout status deployment/central -n stackrox
```

**Verify secret is mounted**:
```bash
oc get pods -n stackrox -l app=central -o yaml | grep -A 5 volumeMounts
```

### Route Not Working with Passthrough

**Symptoms**: Connection refused or SSL errors

**Check route configuration**:
```bash
oc get route central -n stackrox -o yaml
```

**Verify termination is passthrough**:
```bash
# Should output: passthrough
oc get route central -n stackrox -o jsonpath='{.spec.tls.termination}'
```

**Check target port**:
```bash
# Should output: https
oc get route central -n stackrox -o jsonpath='{.spec.port.targetPort}'
```

**Reapply passthrough configuration**:
```bash
oc patch route central -n stackrox --type=json -p='[
  {
    "op": "replace",
    "path": "/spec/tls",
    "value": {
      "termination": "passthrough",
      "insecureEdgeTerminationPolicy": "Redirect"
    }
  }
]'
```

### cert-manager Operator Issues

**Check operator logs**:
```bash
# Controller manager logs
oc logs -n cert-manager-operator deployment/cert-manager-controller-manager

# Webhook logs
oc logs -n cert-manager-operator deployment/cert-manager-webhook

# CA injector logs
oc logs -n cert-manager-operator deployment/cert-manager-cainjector
```

**Restart cert-manager pods**:
```bash
oc rollout restart deployment/cert-manager-controller-manager -n cert-manager-operator
oc rollout restart deployment/cert-manager-webhook -n cert-manager-operator
oc rollout restart deployment/cert-manager-cainjector -n cert-manager-operator
```

## Certificate Renewal

### Automatic Renewal
- cert-manager automatically renews certificates 15 days before expiry
- No manual intervention required
- Check renewal status: `oc get certificate -n stackrox -w`

### Manual Renewal
```bash
# Delete the secret to force renewal
oc delete secret central-tls -n stackrox

# cert-manager will automatically recreate it
watch oc get certificate -n stackrox
```

### Monitor Renewal
```bash
# Watch certificate events
oc get events -n stackrox --field-selector involvedObject.name=central-tls-cert -w

# Check certificate expiry
oc get secret central-tls -n stackrox -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates
```

## Rollback

### Revert to Edge/Reencrypt Termination

```bash
# Change route back to reencrypt
oc patch route central -n stackrox --type=json -p='[
  {
    "op": "replace",
    "path": "/spec/tls",
    "value": {
      "termination": "reencrypt",
      "insecureEdgeTerminationPolicy": "Redirect"
    }
  }
]'

# Remove custom TLS from Central CR
oc patch central stackrox-central-services -n stackrox --type=json -p='[
  {
    "op": "remove",
    "path": "/spec/central/defaultTLSSecret"
  }
]'

# Restart Central
oc rollout restart deployment/central -n stackrox
```

### Uninstall cert-manager Operator

```bash
# Delete Certificate
oc delete certificate central-tls-cert -n stackrox

# Delete ClusterIssuer
oc delete clusterissuer letsencrypt-prod letsencrypt-staging

# Delete Subscription
oc delete subscription cert-manager -n cert-manager-operator

# Delete CSV
CSV_NAME=$(oc get csv -n cert-manager-operator -o name | grep cert-manager)
oc delete $CSV_NAME -n cert-manager-operator

# Delete namespace
oc delete namespace cert-manager-operator
```

## Let's Encrypt Rate Limits

### Production Limits
- **Certificates per Registered Domain**: 50 per week
- **Duplicate Certificate**: 5 per week
- **Failed Validation**: 5 per account/hostname/hour

### Staging Environment
- **Use for testing**: `--staging` flag
- **No rate limits**: Test as much as needed
- **Certificates not trusted**: Only for development

### Best Practices
1. Always test with staging first
2. Monitor certificate count for your domain
3. Use duplicate certificates when possible
4. Implement proper testing before production

## Security Considerations

### Certificate Storage
- Certificates stored in `central-tls` secret
- Kubernetes secret encryption should be enabled
- RBAC should restrict secret access

### Let's Encrypt Account Key
- Stored in secret: `letsencrypt-prod-account-key` or `letsencrypt-staging-account-key`
- Namespace: `cert-manager-operator`
- Keep this secret secure - it's your ACME account identity

### Email Privacy
- Email used for Let's Encrypt registration
- Used for expiry notifications only
- Not shared with third parties

## Additional Resources

- [Red Hat cert-manager Operator Documentation](https://docs.openshift.com/container-platform/latest/security/cert_manager_operator/index.html)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [OpenShift Route Configuration](https://docs.openshift.com/container-platform/latest/networking/routes/route-configuration.html)

## Support

For issues with:
- **Script execution**: Check the script logs and troubleshooting section above
- **cert-manager Operator**: Red Hat Support
- **Let's Encrypt**: Let's Encrypt community forums
- **RHACS configuration**: Red Hat Advanced Cluster Security support
