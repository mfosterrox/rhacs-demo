#!/bin/bash
#
# RHACS Monitoring Setup Script
# Follows the official monitoring-examples installation flow
#

set -euo pipefail

# Get the script directory and change to monitoring-examples
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/monitoring-examples"

oc project stackrox

echo "Installing Cluster Observability Operator..."
oc apply -f cluster-observability-operator/subscription.yaml

echo "Generating user certificates..."
cluster-observability-operator/generate-test-user-certificate.sh
export TLS_CERT=$(awk '{printf "%s\\n", $0}' tls.crt)

echo "Installing and configuring a monitoring stack instance..."
oc apply -f cluster-observability-operator/monitoring-stack.yaml
oc apply -f cluster-observability-operator/scrape-config.yaml

echo "Installing Perses and configuring the RHACS dashboard..."
oc apply -f perses/ui-plugin.yaml
oc apply -f perses/datasource.yaml
oc apply -f perses/dashboard.yaml

echo "Declaring a permission set and a role in RHACS..."

# First, create the declarative configuration ConfigMap
oc apply -f rhacs/declarative-configuration-configmap.yaml

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
  --data-raw "$(envsubst < rhacs/auth-provider.json.tpl)")

# Extract the auth provider ID from the response
export AUTH_PROVIDER_ID=$(echo "$AUTH_PROVIDER_RESPONSE" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)

if [ -n "$AUTH_PROVIDER_ID" ]; then
  echo "✓ Auth provider created with ID: $AUTH_PROVIDER_ID"
  
  echo "Assigning Admin role to Monitoring auth provider..."
  curl -k -X POST "$ROX_CENTRAL_URL/v1/groups" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$(envsubst < rhacs/admin-group.json.tpl)"
  
  echo "✓ Admin role assigned to Monitoring auth provider"
else
  echo "⚠ Warning: Could not extract auth provider ID. You may need to manually configure the role via ACS UI or /v1/groups API."
fi