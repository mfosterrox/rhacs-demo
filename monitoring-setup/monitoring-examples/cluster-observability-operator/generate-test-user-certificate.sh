#!/bin/bash
#
# This script generates a TLS private key and certificate for testing purposes.
#
# After having configured User Certificates auth provider in RHACS, you can test
# the access with:
#
# curl --cert tls.crt --key tls.key $ROX_CENTRAL_URL/v1/auth/status

set -euo pipefail

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}[INFO]${NC} Generating TLS private key and certificate..."

# Generate a private key and certificate:
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
        -subj "/CN=sample-stackrox-monitoring-stack-prometheus.stackrox.svc" \
        -keyout tls.key -out tls.crt

echo -e "${GREEN}[INFO]${NC} TLS certificate generated successfully."
echo -e "${GREEN}[INFO]${NC} Files created: tls.crt, tls.key"

# Create TLS secret in the current namespace:
echo -e "${GREEN}[INFO]${NC} Creating TLS secret in current namespace..."
kubectl create secret tls sample-stackrox-prometheus-tls --cert=tls.crt --key=tls.key

echo ""
echo -e "${GREEN}[INFO]${NC} Testing access to RHACS..."

# Get ROX_CENTRAL_URL if not set
if [ -z "${ROX_CENTRAL_URL:-}" ]; then
    NAMESPACE="${NAMESPACE:-stackrox}"
    
    # Try to get the route (OpenShift)
    if kubectl get route central -n "$NAMESPACE" &> /dev/null; then
        ROX_CENTRAL_URL="https://$(kubectl get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
    # Try to get the ingress
    elif kubectl get ingress central -n "$NAMESPACE" &> /dev/null; then
        ROX_CENTRAL_URL="https://$(kubectl get ingress central -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')"
    # Fallback to service
    else
        ROX_CENTRAL_URL="https://central.$NAMESPACE.svc.cluster.local:443"
    fi
    
    echo -e "${YELLOW}[WARN]${NC} ROX_CENTRAL_URL was not set. Using: $ROX_CENTRAL_URL"
fi

echo -e "${GREEN}[INFO]${NC} Testing with: curl --cert tls.crt --key tls.key $ROX_CENTRAL_URL/v1/auth/status"
echo ""

# Test the access
if curl --cert tls.crt --key tls.key -k -s "$ROX_CENTRAL_URL/v1/auth/status" > /dev/null 2>&1; then
    echo -e "${GREEN}[INFO]${NC} ✓ TLS certificate authentication successful!"
    echo ""
    curl --cert tls.crt --key tls.key -k "$ROX_CENTRAL_URL/v1/auth/status" 2>/dev/null
else
    echo -e "${YELLOW}[WARN]${NC} ✗ TLS certificate authentication failed or not yet configured."
    echo -e "${YELLOW}[WARN]${NC} Make sure to configure User Certificates auth provider in RHACS:"
    echo "  1. Go to Platform Configuration -> Access Control -> Auth Providers"
    echo "  2. Add a new User Certificates provider"
    echo "  3. Upload the certificate: $(pwd)/tls.crt"
    echo "  4. Assign the 'Prometheus Server' role"
    echo ""
    echo "Then test again with:"
    echo "  export ROX_CENTRAL_URL='$ROX_CENTRAL_URL'"
    echo "  curl --cert tls.crt --key tls.key \$ROX_CENTRAL_URL/v1/auth/status"
fi
