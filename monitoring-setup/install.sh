#!/bin/bash
#
# RHACS Monitoring Setup Script
# Follows the official monitoring-examples installation flow
#

set -euo pipefail

# Get the script directory and ensure we're in it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

#================================================================
# Utility Functions
#================================================================

# Strip https:// from ROX_CENTRAL_URL for roxctl -e flag
# roxctl expects host:port format and defaults to https
#
# Usage:
#   ROX_ENDPOINT=$(get_rox_endpoint)
#   roxctl -e "$ROX_ENDPOINT" central userpki create ...
#
# Example:
#   If ROX_CENTRAL_URL="https://central-stackrox.apps.cluster.com"
#   Then get_rox_endpoint returns "central-stackrox.apps.cluster.com"
get_rox_endpoint() {
    local url="${ROX_CENTRAL_URL:-}"
    # Remove https:// prefix if present
    echo "${url#https://}"
}

oc project stackrox

echo "Installing Cluster Observability Operator..."
oc apply -f monitoring-examples/cluster-observability-operator/subscription.yaml

echo "Generating CA and client certificates in $SCRIPT_DIR..."

# Clean up any existing certificates
rm -f ca.key ca.crt ca.srl client.key client.crt client.csr

# Step 1: Create a proper CA (Certificate Authority)
echo "Creating CA certificate..."
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 1825 -out ca.crt \
  -subj "/CN=Monitoring Root CA/O=RHACS Demo" \
  -addext "basicConstraints=CA:TRUE"

# Step 2: Generate client certificate signed by the CA
echo "Creating client certificate..."
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
  -subj "/CN=monitoring-user/O=Monitoring Team"

# Sign the client cert with the CA and add clientAuth extended key usage
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 365 -sha256 \
  -extfile <(printf "extendedKeyUsage=clientAuth")

# Clean up intermediate files
rm -f client.csr ca.srl

# Create TLS secret for Prometheus using the client certificate
kubectl delete secret sample-stackrox-prometheus-tls -n stackrox 2>/dev/null || true
kubectl create secret tls sample-stackrox-prometheus-tls --cert=client.crt --key=client.key -n stackrox

# Export the CA certificate for the auth provider (this is what goes in the userpki config)
# The auth provider trusts certificates signed by this CA
export TLS_CERT=$(awk '{printf "%s\\n", $0}' ca.crt)

echo "✓ Certificates generated successfully"
echo "  CA: $(openssl x509 -in ca.crt -noout -subject -dates | head -1)"
echo "  Client: $(openssl x509 -in client.crt -noout -subject -dates | head -1)"

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
  GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_URL/v1/groups" \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data-raw "$(envsubst < monitoring-examples/rhacs/admin-group.json.tpl)")
  
  HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)
  RESPONSE_BODY=$(echo "$GROUP_RESPONSE" | head -n -1)
  
  # Check if group was created successfully
  if [ "$HTTP_CODE" = "200" ] && echo "$RESPONSE_BODY" | grep -q '"props"'; then
    echo "✓ Admin role assigned to Monitoring auth provider (HTTP $HTTP_CODE)"
    echo ""
    echo "Note: Auth changes may take 10-30 seconds to propagate"
  elif [ "$HTTP_CODE" = "409" ]; then
    echo "✓ Group already exists for Monitoring auth provider"
  else
    echo "⚠ Warning: Group creation failed (HTTP $HTTP_CODE)"
    echo "Response: $RESPONSE_BODY"
    echo ""
    echo "You can create the group manually:"
    echo ""
    echo "Option 1 - Via RHACS UI:"
    echo "  Platform Configuration → Access Control → Groups → Create Group"
    echo "  - Auth Provider: Monitoring"
    echo "  - Key: (leave empty)"
    echo "  - Value: (leave empty)"
    echo "  - Role: Admin"
    echo ""
    echo "Option 2 - Via API:"
    echo "  curl -k -X POST \"\$ROX_CENTRAL_URL/v1/groups\" \\"
    echo "    -H \"Authorization: Bearer \$ROX_API_TOKEN\" \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Admin\"}'"
    echo ""
    echo "Option 3 - Run troubleshooting script:"
    echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
  fi
else
  echo "⚠ Warning: Could not extract auth provider ID. You may need to manually configure the role via ACS UI or /v1/groups API."
fi

echo ""
echo "============================================"
echo "Verifying Configuration"
echo "============================================"
echo ""

# Give auth system time to propagate changes
echo "Waiting for auth configuration to propagate (10 seconds)..."
sleep 10

# Verify the group was created
echo "Checking groups for auth provider..."
GROUPS_LIST=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" "$ROX_CENTRAL_URL/v1/groups" | grep -A5 "$AUTH_PROVIDER_ID" || echo "")

if [ -n "$GROUPS_LIST" ]; then
  echo "✓ Group mapping found for Monitoring auth provider"
  
  # Test client certificate authentication
  echo ""
  echo "Testing client certificate authentication..."
  AUTH_TEST=$(curl -k -s --cert client.crt --key client.key "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
  
  if echo "$AUTH_TEST" | grep -q '"userId"'; then
    echo "✓ Client certificate authentication successful!"
  elif echo "$AUTH_TEST" | grep -q "credentials not found"; then
    echo "⚠ Authentication failed: credentials not found"
    echo ""
    echo "This may take 10-30 seconds to propagate. Wait a moment and try:"
    echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/v1/auth/status"
    echo ""
    echo "If it continues to fail, run the troubleshooting script:"
    echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
  else
    echo "⚠ Unexpected response: $AUTH_TEST"
  fi
else
  echo "⚠ No group mapping found - authentication will fail!"
  echo ""
  echo "Run the troubleshooting script to diagnose and fix:"
  echo "  cd $SCRIPT_DIR && ./troubleshoot-auth.sh"
fi

echo ""
echo "============================================"
echo "Installation Complete!"
echo "============================================"
echo ""
echo "Certificates created in: $SCRIPT_DIR/"
echo "  - ca.crt / ca.key          (CA certificate - configured in auth provider)"
echo "  - client.crt / client.key  (Client certificate - use for API calls)"
echo ""
echo "Test authentication:"
echo "  cd $SCRIPT_DIR"
echo "  curl --cert client.crt --key client.key -k \$ROX_CENTRAL_URL/v1/auth/status"
echo ""
echo "If authentication fails with 'credentials not found', run:"
echo "  ./troubleshoot-auth.sh"
echo ""
echo "Verify configuration with roxctl:"
echo "  ROX_ENDPOINT=\${ROX_CENTRAL_URL#https://}"
echo "  roxctl -e \"\$ROX_ENDPOINT\" central userpki list --insecure-skip-tls-verify"
echo "  roxctl -e \"\$ROX_ENDPOINT\" central group list --insecure-skip-tls-verify"
echo ""
echo "Note: Auth changes may take 10-30 seconds to propagate."
echo ""
