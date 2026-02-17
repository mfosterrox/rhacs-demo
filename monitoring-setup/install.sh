#!/bin/bash
#
# RHACS Monitoring Setup Script
# Follows the official monitoring-examples installation flow
#

set -euo pipefail

# Get the script directory and ensure we're in it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

oc project stackrox

echo "Installing Cluster Observability Operator..."
oc apply -f monitoring-examples/cluster-observability-operator/subscription.yaml

echo "Generating user certificates in $SCRIPT_DIR..."
# Generate certificates in the monitoring-setup directory
rm -f tls.key tls.crt
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=sample-stackrox-monitoring-stack-prometheus.stackrox.svc" \
        -keyout tls.key -out tls.crt

# Create TLS secret
kubectl delete secret sample-stackrox-prometheus-tls -n stackrox 2>/dev/null || true
kubectl create secret tls sample-stackrox-prometheus-tls --cert=tls.crt --key=tls.key -n stackrox

export TLS_CERT=$(awk '{printf "%s\\n", $0}' tls.crt)

echo "Installing and configuring a monitoring stack instance..."
oc apply -f monitoring-examples/cluster-observability-operator/monitoring-stack.yaml
oc apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml

echo "Installing Perses and configuring the RHACS dashboard..."
oc apply -f monitoring-examples/perses/ui-plugin.yaml
oc apply -f monitoring-examples/perses/datasource.yaml
oc apply -f monitoring-examples/perses/dashboard.yaml

echo "Declaring a permission set and a role in RHACS..."

# First, create the declarative configuration ConfigMap
oc apply -f monitoring-examples/rhacs/declarative-configuration-configmap.yaml

# Check if declarative configuration is enabled on Central
echo "Checking if declarative configuration is enabled on Central..."
if oc get deployment central -n stackrox -o yaml | grep -q "declarative-config"; then
  echo "✓ Declarative configuration is already enabled"
else
  echo "⚠ Declarative configuration mount not found on Central deployment"
  echo "Enabling declarative configuration on Central..."
  
  # Check if Central is managed by operator or deployed directly
  if oc get central stackrox-central-services -n stackrox &>/dev/null; then
    echo "Using RHACS Operator to enable declarative configuration..."
    oc patch central stackrox-central-services -n stackrox --type=merge -p='
spec:
  central:
    declarativeConfiguration:
      mounts:
        configMaps:
        - sample-stackrox-prometheus-declarative-configuration
'
    echo "Waiting for Central to update..."
    sleep 10
  else
    echo "Directly patching Central deployment..."
    # For non-operator deployments, manually add volume and mount
    oc set volume deployment/central -n stackrox \
      --add --name=declarative-config \
      --type=configmap \
      --configmap-name=sample-stackrox-prometheus-declarative-configuration \
      --mount-path=/run/secrets/stackrox.io/declarative-config \
      --read-only=true
  fi
  
  echo "Waiting for Central to restart..."
  oc rollout status deployment/central -n stackrox --timeout=300s
  echo "✓ Declarative configuration enabled"
fi

echo "Creating a User-Certificate auth-provider..."
AUTH_PROVIDER_RESPONSE=$(curl -k -X POST "$ROX_CENTRAL_URL/v1/authProviders" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  --data-raw "$(envsubst < monitoring-examples/rhacs/auth-provider.json.tpl)")

# Extract the auth provider ID from the response
export AUTH_PROVIDER_ID=$(echo "$AUTH_PROVIDER_RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

if [ -n "$AUTH_PROVIDER_ID" ]; then
  echo "✓ Auth provider created with ID: $AUTH_PROVIDER_ID"
  
  echo "Assigning Admin role to Monitoring auth provider..."
  curl -k -X POST "$ROX_CENTRAL_URL/v1/groups" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$(envsubst < monitoring-examples/rhacs/admin-group.json.tpl)"
  
  echo "✓ Admin role assigned to Monitoring auth provider"
else
  echo "⚠ Warning: Could not extract auth provider ID. You may need to manually configure the role via ACS UI or /v1/groups API."
fi

echo ""
echo "Installation complete!"
echo "Certificates created at: $SCRIPT_DIR/tls.crt and $SCRIPT_DIR/tls.key"
echo ""
echo "You can test the authentication with:"
echo "  cd $SCRIPT_DIR"
echo "  curl --cert tls.crt --key tls.key \$ROX_CENTRAL_URL/v1/auth/status"
