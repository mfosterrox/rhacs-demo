#!/bin/bash
# Debug script to test token generation manually
# Run this on the bastion host to see what the API actually returns

set -euo pipefail

# Get ACS URL and password from environment or ~/.bashrc
echo "Checking for ACS_URL..."
if [ -z "${ACS_URL:-}" ]; then
    if [ -f ~/.bashrc ] && grep -q "^export ACS_URL=" ~/.bashrc; then
        # Extract ACS_URL from ~/.bashrc (handle both quoted and unquoted values)
        ACS_URL_LINE=$(grep "^export ACS_URL=" ~/.bashrc | head -1)
        echo "Found ACS_URL line: $ACS_URL_LINE"
        # Remove export and get the value, handling both "value" and value formats
        ACS_URL=$(echo "$ACS_URL_LINE" | sed -E 's/^export ACS_URL=["'\'']?//; s/["'\'']?$//')
    fi
fi

# Also try getting it from the route directly
if [ -z "${ACS_URL:-}" ]; then
    echo "ACS_URL not in ~/.bashrc, trying to get from route..."
    RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
    CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$CENTRAL_ROUTE" ]; then
        ACS_URL="https://$CENTRAL_ROUTE"
        echo "Found route: $CENTRAL_ROUTE"
    fi
fi

if [ -z "${ACS_URL:-}" ]; then
    echo "Error: ACS_URL not set. Checking ~/.bashrc..."
    if [ -f ~/.bashrc ]; then
        echo "ACS_URL lines in ~/.bashrc:"
        grep "ACS_URL" ~/.bashrc || echo "  (none found)"
    fi
    echo ""
    echo "You can set it manually:"
    echo "  export ACS_URL=\"https://central-stackrox.apps.your-cluster.domain\""
    exit 1
fi

echo "Using ACS_URL: $ACS_URL"

# Get password from secret
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
if [ -z "$ADMIN_PASSWORD_B64" ]; then
    echo "Error: Could not get password from secret central-htpasswd in namespace $RHACS_NAMESPACE"
    exit 1
fi
ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)

# Extract endpoint without https:// and remove trailing slashes
ROX_ENDPOINT_FOR_API="${ACS_URL#https://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API%/}"
# Remove any path after the hostname
ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API%%/*}"

echo "Extracted endpoint (hostname only): $ROX_ENDPOINT_FOR_API"

echo "=========================================="
echo "Testing Token Generation"
echo "=========================================="
echo "ACS URL: $ACS_URL"
echo "Endpoint for API: $ROX_ENDPOINT_FOR_API"
echo ""

# Test API call
echo "1. Testing API token generation via curl..."
TOKEN_RESPONSE=$(curl -k -v -s --connect-timeout 15 --max-time 60 -X POST \
    -u "admin:${ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
    -d '{"name":"debug-token","roles":["Admin"]}' 2>&1)

echo ""
echo "Full curl response:"
echo "$TOKEN_RESPONSE"
echo ""

# Try to extract token with jq
if command -v jq >/dev/null 2>&1; then
    echo "2. Parsing with jq..."
    echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "Not valid JSON"
    echo ""
    
    TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
    if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
        echo "Extracted token (length: ${#TOKEN}): ${TOKEN:0:50}..."
    else
        echo "Could not extract token with jq"
    fi
fi

# Test roxctl if available
if command -v roxctl >/dev/null 2>&1; then
    echo ""
    echo "3. Testing roxctl token generation..."
    ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_FOR_API}"
    if [[ ! "$ROX_ENDPOINT_NORMALIZED" =~ :[0-9]+$ ]]; then
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED}:443"
    fi
    
    ROXCTL_OUTPUT=$(roxctl -e "$ROX_ENDPOINT_NORMALIZED" \
        central token generate \
        --password "$ADMIN_PASSWORD" \
        --insecure-skip-tls-verify 2>&1)
    
    echo "roxctl output:"
    echo "$ROXCTL_OUTPUT"
    echo ""
    
    ROXCTL_TOKEN=$(echo "$ROXCTL_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{30,}' | head -1 || echo "")
    if [ -n "$ROXCTL_TOKEN" ]; then
        echo "Extracted roxctl token (length: ${#ROXCTL_TOKEN}): ${ROXCTL_TOKEN:0:50}..."
    fi
fi

echo ""
echo "=========================================="
echo "Debug complete"
echo "=========================================="
