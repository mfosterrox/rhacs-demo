#!/bin/bash
# Application Setup API Script for RHACS
# Fetches cluster ID and creates compliance scan configuration

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[API-SETUP]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[API-SETUP]${NC} $1"
}

error() {
    echo -e "${RED}[API-SETUP] ERROR:${NC} $1" >&2
    echo -e "${RED}[API-SETUP] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# RHACS operator namespace
RHACS_OPERATOR_NAMESPACE="stackrox"

# Generate ROX_ENDPOINT from Central route
log "Extracting ROX_ENDPOINT from Central route..."
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -z "$CENTRAL_ROUTE" ]; then
    error "Central route not found in namespace '$RHACS_OPERATOR_NAMESPACE'. Please ensure RHACS Central is installed."
fi
ROX_ENDPOINT="$CENTRAL_ROUTE"
log "✓ Extracted ROX_ENDPOINT: $ROX_ENDPOINT"

# Initialize ROX_API_TOKEN (will be generated if needed)
ROX_API_TOKEN=""

# Check if API token is valid, generate new one if needed
NEEDS_NEW_TOKEN=false

if [ -z "$ROX_API_TOKEN" ]; then
    log "ROX_API_TOKEN not set, will generate new token..."
    NEEDS_NEW_TOKEN=true
else
    # Test if existing token is valid
    log "Testing existing API token..."
    set +e
    TEST_RESPONSE=$(curl -k -s --connect-timeout 10 --max-time 30 -X GET \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$ROX_ENDPOINT/v1/clusters" 2>&1)
    TEST_EXIT_CODE=$?
    set -e
    
    if [ $TEST_EXIT_CODE -ne 0 ] || echo "$TEST_RESPONSE" | grep -q "not authorized\|token validation failed"; then
        log "Existing API token is invalid or expired, will generate new token..."
        NEEDS_NEW_TOKEN=true
    else
        log "✓ Existing API token is valid"
    fi
fi

if [ "$NEEDS_NEW_TOKEN" = true ]; then
    log "Generating new API token..."
    
    # Get ADMIN_PASSWORD - first check ~/.bashrc, then try secret
    ADMIN_PASSWORD=""
    
    # Check if password is in ~/.bashrc (from install.sh -p flag)
    if [ -f ~/.bashrc ] && grep -q "^export ACS_PASSWORD=" ~/.bashrc; then
        ADMIN_PASSWORD=$(grep "^export ACS_PASSWORD=" ~/.bashrc | head -1 | sed -E 's/^export ACS_PASSWORD=["'\'']?//; s/["'\'']?$//')
        if [ -n "$ADMIN_PASSWORD" ]; then
            log "Using password from ~/.bashrc (set via install.sh -p flag)"
        fi
    fi
    
    # If not in ~/.bashrc, try to get from secret (may contain hash, not plaintext)
    if [ -z "$ADMIN_PASSWORD" ]; then
        log "Password not in ~/.bashrc, attempting to get from secret..."
        ADMIN_PASSWORD_B64=""
        MAX_RETRIES=3
        RETRY_COUNT=0
        
        while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ -z "$ADMIN_PASSWORD_B64" ]; do
            if [ $RETRY_COUNT -gt 0 ]; then
                log "Retrying to get admin password from secret (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
                sleep 2
            fi
            
            if oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" >/dev/null 2>&1; then
                # Try password key first
                ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
                # If not found, try htpasswd key (this is what RHACS actually uses)
                if [ -z "$ADMIN_PASSWORD_B64" ]; then
                    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.htpasswd}' 2>/dev/null || echo "")
                fi
            fi
            RETRY_COUNT=$((RETRY_COUNT + 1))
        done
        
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            HTPASSWD_CONTENT=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
            # Check if it's a hash (starts with $2a$, $2y$, etc.)
            if echo "$HTPASSWD_CONTENT" | grep -q "^admin:\$2"; then
                warning "Secret contains htpasswd hash, not plaintext password."
                warning "Cannot extract password from hash. Please run: ./install.sh -p YOUR_PASSWORD"
                error "Password required but not available. Run install.sh with -p flag to set password."
            else
                # Might be plaintext or different format
                ADMIN_PASSWORD=$(echo "$HTPASSWD_CONTENT" | cut -d: -f2- | head -1)
            fi
        fi
    fi
    
    if [ -z "$ADMIN_PASSWORD" ]; then
        error "Admin password not found. Please run: ./install.sh -p YOUR_PASSWORD"
    fi
    
    # Normalize ROX_ENDPOINT for roxctl (add :443 if no port)
    normalize_rox_endpoint() {
        local input="$1"
        input="${input#https://}"
        input="${input#http://}"
        input="${input%/}"
        if [[ "$input" != *:* ]]; then
            input="${input}:443"
        fi
        echo "$input"
    }
    
    ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
    
    # Download roxctl if not available (Linux bastion host)
    ROXCTL_CMD=""
    if ! command -v roxctl &>/dev/null; then
        log "roxctl not found, downloading..."
        
        # Get RHACS version from CSV
        RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
        if [ -z "$RHACS_VERSION" ]; then
            RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
        fi
        
        # Download roxctl for Linux
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/Linux/roxctl"
        ROXCTL_TMP="/tmp/roxctl"
        
        log "Downloading roxctl from: $ROXCTL_URL"
        if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
            # Try latest if version-specific download fails
            ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
            log "Retrying with latest version: $ROXCTL_URL"
            if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
                error "Failed to download roxctl. Please install it manually."
            fi
        fi
        
        chmod +x "$ROXCTL_TMP"
        ROXCTL_CMD="$ROXCTL_TMP"
        log "✓ roxctl downloaded to $ROXCTL_TMP"
    else
        ROXCTL_CMD="roxctl"
        log "✓ roxctl found in PATH"
    fi
    
    # Generate API token using roxctl
    log "Generating API token with roxctl..."
    # Generate token using API directly with basic auth (more reliable than roxctl)
    ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
    ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
    TOKEN_NAME="script-generated-token"
    
    # Check if API token already exists and delete it
    log "Checking for existing API token '$TOKEN_NAME'..."
    set +e
    EXISTING_TOKENS=$(curl -k -s --connect-timeout 15 --max-time 60 -X GET \
        -u "admin:${ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens" 2>&1)
    TOKEN_LIST_EXIT_CODE=$?
    set -e
    
    TOKEN_EXISTS=false
    if [ $TOKEN_LIST_EXIT_CODE -eq 0 ] && echo "$EXISTING_TOKENS" | jq . >/dev/null 2>&1; then
        if echo "$EXISTING_TOKENS" | jq -r --arg name "$TOKEN_NAME" '.tokens[]? | select(.name == $name) | .name' 2>/dev/null | grep -q "^${TOKEN_NAME}$"; then
            TOKEN_EXISTS=true
            log "Found existing API token '$TOKEN_NAME', deleting it..."
            TOKEN_ID=$(echo "$EXISTING_TOKENS" | jq -r --arg name "$TOKEN_NAME" '.tokens[]? | select(.name == $name) | .id' 2>/dev/null | head -1)
            if [ -n "$TOKEN_ID" ] && [ "$TOKEN_ID" != "null" ]; then
                set +e
                DELETE_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X DELETE \
                    -u "admin:${ADMIN_PASSWORD}" \
                    -H "Content-Type: application/json" \
                    "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/${TOKEN_ID}" 2>&1)
                if [ $? -eq 0 ]; then
                    log "✓ Deleted existing token (ID: $TOKEN_ID)"
                fi
                set -e
            fi
        fi
    fi
    
    log "Generating API token '$TOKEN_NAME' using Central API..."
    set +e
    TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
        -u "admin:${ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
        -d "{\"name\":\"${TOKEN_NAME}\",\"roles\":[\"Admin\"]}" 2>&1)
    TOKEN_CURL_EXIT_CODE=$?
    set -e
    
    # Debug: Log the raw response for troubleshooting
    log "Debug: Token API response (first 500 chars): ${TOKEN_RESPONSE:0:500}"
    
    if [ $TOKEN_CURL_EXIT_CODE -ne 0 ]; then
        log "API token generation via curl failed, trying roxctl..."
        # Fallback to roxctl
        set +e
        TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central token generate \
            --password "$ADMIN_PASSWORD" \
            --insecure-skip-tls-verify 2>&1)
        TOKEN_EXIT_CODE=$?
        set -e
        
        if [ $TOKEN_EXIT_CODE -ne 0 ]; then
            error "Failed to generate API token. roxctl output: ${TOKEN_OUTPUT:0:500}"
        fi
        
        # Extract token from roxctl output
        ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
        if [ -z "$ROX_API_TOKEN" ]; then
            ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | tail -1 | tr -d '[:space:]' || echo "")
        fi
        
        if [ -z "$ROX_API_TOKEN" ]; then
            error "Failed to extract API token from roxctl output. Output: ${TOKEN_OUTPUT:0:500}"
        fi
    else
        # Extract token from API response
        # First try jq to parse JSON response
        if command -v jq >/dev/null 2>&1 && echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
            ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // .data // empty' 2>/dev/null || echo "")
            # If we got a JSON object, try to extract token from it
            if [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ] && echo "$ROX_API_TOKEN" | jq . >/dev/null 2>&1; then
                ROX_API_TOKEN=$(echo "$ROX_API_TOKEN" | jq -r '.token // empty' 2>/dev/null || echo "")
            fi
        fi
        
        # If jq extraction failed, try regex patterns
        if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
            # Look for tokens that are at least 30 characters (RHACS tokens are typically 40+ chars)
            ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{30,}' | head -1 || echo "")
        fi
        
        # If still no valid token, try roxctl
        if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
            log "Failed to extract valid token from API response, trying roxctl..."
            log "API Response preview: ${TOKEN_RESPONSE:0:200}"
            # Fallback to roxctl
            set +e
            TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
                central token generate \
                --password "$ADMIN_PASSWORD" \
                --insecure-skip-tls-verify 2>&1)
            TOKEN_EXIT_CODE=$?
            set -e
            
            if [ $TOKEN_EXIT_CODE -eq 0 ]; then
                # Extract token from roxctl output - look for long alphanumeric strings
                ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{30,}' | head -1 || echo "")
                # If that fails, roxctl might output just the token on a line
                if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                    # Get the last line that looks like a token
                    ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -E '^[a-zA-Z0-9_-]{30,}$' | tail -1 || echo "")
                fi
            fi
        fi
        
        if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
            error "Failed to extract valid API token. Token length: ${#ROX_API_TOKEN}. API Response: ${TOKEN_RESPONSE:0:500}"
        fi
    fi
    
    # Verify token is not empty and has reasonable length (RHACS tokens are typically 40+ characters)
    if [ ${#ROX_API_TOKEN} -lt 30 ]; then
        log "Debug: TOKEN_RESPONSE full: $TOKEN_RESPONSE"
        log "Debug: TOKEN_OUTPUT full: $TOKEN_OUTPUT"
        error "Generated token appears to be invalid (too short: ${#ROX_API_TOKEN} chars). Token preview: ${ROX_API_TOKEN:0:30}..."
    fi
    
    log "✓ API token generated (length: ${#ROX_API_TOKEN} chars)"
    log "Debug: Token first 20 chars: ${ROX_API_TOKEN:0:20}..."
    
    # Save token to ~/.bashrc
    log "✓ New API token generated"
fi

# Ensure jq is installed
if ! command -v jq >/dev/null 2>&1; then
    log "Installing jq..."
    if command -v dnf >/dev/null 2>&1; then
        if ! sudo dnf install -y jq; then
            error "Failed to install jq using dnf. Check sudo permissions and package repository."
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if ! sudo apt-get update && sudo apt-get install -y jq; then
            error "Failed to install jq using apt-get. Check sudo permissions and package repository."
        fi
    else
        error "jq not found and cannot be installed automatically. Please install jq manually."
    fi
    log "✓ jq installed successfully"
else
    log "✓ jq is already installed"
fi

# Ensure ROX_ENDPOINT has https:// prefix
if [[ ! "$ROX_ENDPOINT" =~ ^https?:// ]]; then
    ROX_ENDPOINT="https://$ROX_ENDPOINT"
    log "Added https:// prefix to ROX_ENDPOINT: $ROX_ENDPOINT"
fi

# Fetch cluster ID - try to match by name first, then fall back to first connected cluster
log "Fetching cluster ID..."
MAX_RETRIES=2
RETRY_COUNT=0
CLUSTER_RESPONSE=""
CLUSTER_CURL_EXIT_CODE=1

while [ $RETRY_COUNT -le $MAX_RETRIES ]; do
    # Temporarily disable exit on error to capture curl exit code
    set +e
    CLUSTER_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        "$ROX_ENDPOINT/v1/clusters" 2>&1)
    CLUSTER_CURL_EXIT_CODE=$?
    set -e
    
    # Check for authorization errors
    if echo "$CLUSTER_RESPONSE" | grep -q "not authorized\|token validation failed"; then
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log "API token authorization failed. Generating new token and retrying..."
            # Generate new token (reuse the token generation logic from above)
            ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
            if [ -z "$ADMIN_PASSWORD_B64" ]; then
                # Try alternative key names
                ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.data.htpasswd}' 2>/dev/null || echo "")
            fi
            if [ -z "$ADMIN_PASSWORD_B64" ]; then
                error "Admin password secret 'central-htpasswd' found but 'password' key not found in namespace '$RHACS_OPERATOR_NAMESPACE'"
            fi
            ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
            
            normalize_rox_endpoint() {
                local input="$1"
                input="${input#https://}"
                input="${input#http://}"
                input="${input%/}"
                if [[ "$input" != *:* ]]; then
                    input="${input}:443"
                fi
                echo "$input"
            }
            
            ROX_ENDPOINT_NORMALIZED="$(normalize_rox_endpoint "$ROX_ENDPOINT")"
            
            # Use roxctl if available, otherwise download it
            ROXCTL_CMD=""
            if command -v roxctl &>/dev/null; then
                ROXCTL_CMD="roxctl"
            else
                ROXCTL_TMP="/tmp/roxctl"
                if [ -f "$ROXCTL_TMP" ] && [ -x "$ROXCTL_TMP" ]; then
                    ROXCTL_CMD="$ROXCTL_TMP"
                else
                    RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
                    if [ -z "$RHACS_VERSION" ]; then
                        RHACS_VERSION=$(oc get csv -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "latest")
                    fi
                    ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/Linux/roxctl"
                    if ! curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null; then
                        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
                        curl -L -f -o "$ROXCTL_TMP" "$ROXCTL_URL" 2>/dev/null || error "Failed to download roxctl"
                    fi
                    chmod +x "$ROXCTL_TMP"
                    ROXCTL_CMD="$ROXCTL_TMP"
                fi
            fi
            
            # Generate token using API directly with basic auth (more reliable than roxctl)
            ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT#https://}"
            ROX_ENDPOINT_FOR_API="${ROX_ENDPOINT_FOR_API#http://}"
            TOKEN_NAME_RETRY="script-generated-token-retry"
            
            # Check if retry token already exists and delete it
            log "Checking for existing API token '$TOKEN_NAME_RETRY'..."
            set +e
            EXISTING_TOKENS_RETRY=$(curl -k -s --connect-timeout 15 --max-time 60 -X GET \
                -u "admin:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens" 2>&1)
            TOKEN_LIST_EXIT_CODE_RETRY=$?
            set -e
            
            if [ $TOKEN_LIST_EXIT_CODE_RETRY -eq 0 ] && echo "$EXISTING_TOKENS_RETRY" | jq . >/dev/null 2>&1; then
                if echo "$EXISTING_TOKENS_RETRY" | jq -r --arg name "$TOKEN_NAME_RETRY" '.tokens[]? | select(.name == $name) | .name' 2>/dev/null | grep -q "^${TOKEN_NAME_RETRY}$"; then
                    log "Found existing API token '$TOKEN_NAME_RETRY', deleting it..."
                    TOKEN_ID_RETRY=$(echo "$EXISTING_TOKENS_RETRY" | jq -r --arg name "$TOKEN_NAME_RETRY" '.tokens[]? | select(.name == $name) | .id' 2>/dev/null | head -1)
                    if [ -n "$TOKEN_ID_RETRY" ] && [ "$TOKEN_ID_RETRY" != "null" ]; then
                        set +e
                        DELETE_RESPONSE_RETRY=$(curl -k -s --connect-timeout 15 --max-time 60 -X DELETE \
                            -u "admin:${ADMIN_PASSWORD}" \
                            -H "Content-Type: application/json" \
                            "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/${TOKEN_ID_RETRY}" 2>&1)
                        if [ $? -eq 0 ]; then
                            log "✓ Deleted existing retry token (ID: $TOKEN_ID_RETRY)"
                        fi
                        set -e
                    fi
                fi
            fi
            
            set +e
            TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
                -u "admin:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
                -d "{\"name\":\"${TOKEN_NAME_RETRY}\",\"roles\":[\"Admin\"]}" 2>&1)
            TOKEN_CURL_EXIT_CODE=$?
            set -e
            
            if [ $TOKEN_CURL_EXIT_CODE -ne 0 ]; then
                log "API token generation via curl failed, trying roxctl..."
                set +e
                TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
                    central token generate \
                    --password "$ADMIN_PASSWORD" \
                    --insecure-skip-tls-verify 2>&1)
                TOKEN_EXIT_CODE=$?
                set -e
                
                if [ $TOKEN_EXIT_CODE -ne 0 ]; then
                    error "Failed to generate API token. roxctl output: ${TOKEN_OUTPUT:0:500}"
                fi
                
                # Extract token from roxctl output - look for long alphanumeric strings (30+ chars)
                ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{30,}' | head -1 || echo "")
                # If that fails, roxctl might output just the token on a line
                if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                    ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -E '^[a-zA-Z0-9_-]{30,}$' | tail -1 || echo "")
                fi
                
                if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                    error "Failed to extract valid API token from roxctl output. Token length: ${#ROX_API_TOKEN}. Output: ${TOKEN_OUTPUT:0:500}"
                fi
            else
                # Extract token from API response
                # First try jq to parse JSON response
                if command -v jq >/dev/null 2>&1 && echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
                    ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // .data // empty' 2>/dev/null || echo "")
                    # If we got a JSON object, try to extract token from it
                    if [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ] && echo "$ROX_API_TOKEN" | jq . >/dev/null 2>&1; then
                        ROX_API_TOKEN=$(echo "$ROX_API_TOKEN" | jq -r '.token // empty' 2>/dev/null || echo "")
                    fi
                fi
                
                # If jq extraction failed, try regex patterns
                if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                    # Look for tokens that are at least 30 characters
                    ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{30,}' | head -1 || echo "")
                fi
                
                # If still no valid token, try roxctl
                if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                    log "Failed to extract valid token from API response, trying roxctl fallback..."
                    log "API Response preview: ${TOKEN_RESPONSE:0:200}"
                    set +e
                    TOKEN_OUTPUT=$($ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
                        central token generate \
                        --password "$ADMIN_PASSWORD" \
                        --insecure-skip-tls-verify 2>&1)
                    TOKEN_EXIT_CODE=$?
                    set -e
                    
                    if [ $TOKEN_EXIT_CODE -eq 0 ]; then
                        ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE '[a-zA-Z0-9_-]{30,}' | head -1 || echo "")
                        if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                            ROX_API_TOKEN=$(echo "$TOKEN_OUTPUT" | grep -E '^[a-zA-Z0-9_-]{30,}$' | tail -1 || echo "")
                        fi
                    fi
                fi
                
                if [ -z "$ROX_API_TOKEN" ] || [ ${#ROX_API_TOKEN} -lt 30 ]; then
                    error "Failed to extract valid API token. Token length: ${#ROX_API_TOKEN}. API Response: ${TOKEN_RESPONSE:0:500}"
                fi
            fi
            
            # Verify token is not empty and has reasonable length (RHACS tokens are typically 40+ characters)
            if [ ${#ROX_API_TOKEN} -lt 30 ]; then
                error "Generated token appears to be invalid (too short: ${#ROX_API_TOKEN} chars). Token preview: ${ROX_API_TOKEN:0:30}..."
            fi
            
            log "✓ API token generated (length: ${#ROX_API_TOKEN} chars)"
            
            log "✓ New API token generated, retrying cluster fetch..."
            RETRY_COUNT=$((RETRY_COUNT + 1))
            continue
        else
            error "API token authorization failed after $MAX_RETRIES retries. Response: ${CLUSTER_RESPONSE:0:500}"
        fi
    fi
    
    if [ $CLUSTER_CURL_EXIT_CODE -ne 0 ]; then
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            log "Cluster API request failed (exit code: $CLUSTER_CURL_EXIT_CODE), retrying..."
            RETRY_COUNT=$((RETRY_COUNT + 1))
            sleep 2
            continue
        else
            log "Debug: ROX_ENDPOINT=$ROX_ENDPOINT"
            log "Debug: ROX_API_TOKEN length=${#ROX_API_TOKEN} (first 20 chars: ${ROX_API_TOKEN:0:20}...)"
            error "Cluster API request failed with exit code $CLUSTER_CURL_EXIT_CODE after $MAX_RETRIES retries. Response: ${CLUSTER_RESPONSE:0:500}"
        fi
    fi
    
    # Success - break out of retry loop
    break
done

if [ -z "$CLUSTER_RESPONSE" ]; then
    error "Empty response from cluster API"
fi

# Extract cluster ID
if ! echo "$CLUSTER_RESPONSE" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from cluster API. Response: ${CLUSTER_RESPONSE:0:300}"
fi

# Get the cluster name from the SecuredCluster resource
RHACS_OPERATOR_NAMESPACE="stackrox"
SECURED_CLUSTER_NAME="rhacs-secured-cluster-services"
EXPECTED_CLUSTER_NAME=$(oc get securedcluster "$SECURED_CLUSTER_NAME" -n "$RHACS_OPERATOR_NAMESPACE" -o jsonpath='{.spec.clusterName}' 2>/dev/null || echo "")

PRODUCTION_CLUSTER_ID=""
if [ -n "$EXPECTED_CLUSTER_NAME" ]; then
    log "Attempting to find cluster by name from SecuredCluster resource: '$EXPECTED_CLUSTER_NAME'..."
    # Use set +e to prevent failure if jq doesn't find a match
    set +e
    PRODUCTION_CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.name == \"$EXPECTED_CLUSTER_NAME\") | .id" 2>/dev/null | head -1 || echo "")
    set -e
fi

if [ -z "$PRODUCTION_CLUSTER_ID" ] || [ "$PRODUCTION_CLUSTER_ID" = "null" ]; then
    if [ -n "$EXPECTED_CLUSTER_NAME" ]; then
        log "Cluster '$EXPECTED_CLUSTER_NAME' not found. Looking for any connected cluster..."
    else
        log "Cluster name not set in SecuredCluster. Looking for any connected cluster..."
    fi
    # Fall back to first connected/healthy cluster
    set +e
    PRODUCTION_CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[] | select(.healthStatus.overallHealthStatus == "HEALTHY" or .healthStatus.overallHealthStatus == "UNHEALTHY" or .healthStatus == null) | .id' 2>/dev/null | head -1 || echo "")
    set -e
    
    if [ -z "$PRODUCTION_CLUSTER_ID" ] || [ "$PRODUCTION_CLUSTER_ID" = "null" ]; then
        # Last resort: use first cluster
        set +e
        PRODUCTION_CLUSTER_ID=$(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[0].id // empty' 2>/dev/null || echo "")
        set -e
    fi
fi

if [ -z "$PRODUCTION_CLUSTER_ID" ] || [ "$PRODUCTION_CLUSTER_ID" = "null" ]; then
    error "Failed to find a valid cluster ID. Available clusters: $(echo "$CLUSTER_RESPONSE" | jq -r '.clusters[] | "\(.name): \(.id)"' 2>/dev/null | tr '\n' ' ' || echo "none")"
fi

# Verify cluster exists and get its name for logging
CLUSTER_NAME=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$PRODUCTION_CLUSTER_ID\") | .name" 2>/dev/null | head -1)
CLUSTER_HEALTH=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$PRODUCTION_CLUSTER_ID\") | .healthStatus.overallHealthStatus // \"UNKNOWN\"" 2>/dev/null | head -1)

if [ -n "$CLUSTER_NAME" ] && [ "$CLUSTER_NAME" != "null" ]; then
    log "✓ Found cluster: $CLUSTER_NAME (ID: $PRODUCTION_CLUSTER_ID, Health: ${CLUSTER_HEALTH:-UNKNOWN})"
else
    log "✓ Using cluster ID: $PRODUCTION_CLUSTER_ID"
fi

# Verify cluster is connected (not disconnected)
CLUSTER_STATUS=$(echo "$CLUSTER_RESPONSE" | jq -r ".clusters[] | select(.id == \"$PRODUCTION_CLUSTER_ID\") | .status.connectionStatus // \"UNKNOWN\"" 2>/dev/null | head -1)
if [ "$CLUSTER_STATUS" = "DISCONNECTED" ] || [ "$CLUSTER_STATUS" = "UNINITIALIZED" ]; then
    warning "Cluster $CLUSTER_NAME (ID: $PRODUCTION_CLUSTER_ID) has status: $CLUSTER_STATUS"
    warning "This may cause scan failures. Ensure the cluster is properly connected to RHACS."
fi

# Check if Compliance Operator ProfileBundles are ready
# This is critical - scans cannot be created until ProfileBundles are processed
if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    log "Checking Compliance Operator ProfileBundle status..."
    log "ProfileBundles must be ready before creating scan configurations..."
    
    PROFILEBUNDLE_WAIT_TIMEOUT=600  # 10 minutes max wait
    PROFILEBUNDLE_WAIT_INTERVAL=10  # Check every 10 seconds
    PROFILEBUNDLE_ELAPSED=0
    PROFILEBUNDLES_READY=false
    
    # Required ProfileBundles for the profiles we're using
    REQUIRED_BUNDLES=("ocp4" "rhcos4")
    
    while [ $PROFILEBUNDLE_ELAPSED -lt $PROFILEBUNDLE_WAIT_TIMEOUT ]; do
        ALL_READY=true
        BUNDLE_STATUS=""
        
        for bundle in "${REQUIRED_BUNDLES[@]}"; do
            # Check multiple status fields - different versions use different fields
            BUNDLE_PHASE=$(oc get profilebundle "$bundle" -n openshift-compliance -o jsonpath='{.status.phase}' 2>/dev/null || echo "NOT_FOUND")
            BUNDLE_DATASTREAM=$(oc get profilebundle "$bundle" -n openshift-compliance -o jsonpath='{.status.dataStreamStatus}' 2>/dev/null || echo "")
            
            if [ "$BUNDLE_PHASE" = "NOT_FOUND" ]; then
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: Not found\n"
                ALL_READY=false
            elif [ "$BUNDLE_PHASE" = "Ready" ] || [ "$BUNDLE_PHASE" = "READY" ]; then
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: ✓ Ready\n"
            elif [ -n "$BUNDLE_DATASTREAM" ] && [ "$BUNDLE_DATASTREAM" = "Valid" ] || [ "$BUNDLE_DATASTREAM" = "VALID" ]; then
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: ✓ Ready (dataStream: Valid)\n"
            else
                STATUS_DISPLAY="${BUNDLE_PHASE:-Unknown}"
                if [ -n "$BUNDLE_DATASTREAM" ] && [ "$BUNDLE_DATASTREAM" != "Valid" ]; then
                    STATUS_DISPLAY="${STATUS_DISPLAY} (dataStream: ${BUNDLE_DATASTREAM})"
                fi
                BUNDLE_STATUS="${BUNDLE_STATUS}  $bundle: ⏳ Processing ($STATUS_DISPLAY)\n"
                ALL_READY=false
            fi
        done
        
        if [ "$ALL_READY" = true ]; then
            PROFILEBUNDLES_READY=true
            log "✓ All ProfileBundles are ready:"
            echo -e "$BUNDLE_STATUS"
            break
        else
            if [ $((PROFILEBUNDLE_ELAPSED % 30)) -eq 0 ]; then
                log "Waiting for ProfileBundles to be ready... (${PROFILEBUNDLE_ELAPSED}s/${PROFILEBUNDLE_WAIT_TIMEOUT}s)"
                echo -e "$BUNDLE_STATUS"
            fi
        fi
        
        sleep $PROFILEBUNDLE_WAIT_INTERVAL
        PROFILEBUNDLE_ELAPSED=$((PROFILEBUNDLE_ELAPSED + PROFILEBUNDLE_WAIT_INTERVAL))
    done
    
    if [ "$PROFILEBUNDLES_READY" = false ]; then
        warning "ProfileBundles did not become ready within ${PROFILEBUNDLE_WAIT_TIMEOUT}s timeout"
        log "Current ProfileBundle status:"
        echo -e "$BUNDLE_STATUS"
        log ""
        log "This may indicate:"
        log "  1. Compliance Operator is still installing/processing"
        log "  2. ProfileBundles are stuck in processing state"
        log ""
        log "Troubleshooting steps:"
        log "  1. Check Compliance Operator pods: oc get pods -n openshift-compliance"
        log "  2. Check ProfileBundle status: oc get profilebundle -n openshift-compliance"
        log "  3. Check ProfileBundle details: oc describe profilebundle ocp4 -n openshift-compliance"
        log "  4. Check operator logs: oc logs -n openshift-compliance -l name=compliance-operator"
        log ""
        warning "Attempting to create scan configuration anyway..."
        warning "If it fails with 'ProfileBundle still being processed', wait and retry later"
    fi
else
    warning "OpenShift CLI (oc) not available - cannot check ProfileBundle status"
    warning "If scan creation fails with 'ProfileBundle still being processed', ensure ProfileBundles are ready"
fi

log ""

# Check for existing acs-catch-all scan configuration and validate it before recreating
log "Checking for existing 'acs-catch-all' scan configuration..."
set +e
EXISTING_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
CONFIG_CURL_EXIT_CODE=$?
set -e

if [ $CONFIG_CURL_EXIT_CODE -ne 0 ]; then
    error "Failed to fetch existing scan configurations (exit code: $CONFIG_CURL_EXIT_CODE). Response: ${EXISTING_CONFIGS:0:500}"
fi

if [ -z "$EXISTING_CONFIGS" ]; then
    error "Empty response from scan configurations API"
fi

if ! echo "$EXISTING_CONFIGS" | jq . >/dev/null 2>&1; then
    error "Invalid JSON response from scan configurations API. Response: ${EXISTING_CONFIGS:0:300}"
fi

EXISTING_SCAN=$(echo "$EXISTING_CONFIGS" | jq -r '.configurations[] | select(.scanName == "acs-catch-all") | .id' 2>/dev/null || echo "")
EXISTING_SCAN_CONFIG=$(echo "$EXISTING_CONFIGS" | jq '.configurations[] | select(.scanName == "acs-catch-all")' 2>/dev/null || echo "")

NEED_RECREATE=true
SCAN_CONFIG_ID=""

if [ -n "$EXISTING_SCAN" ] && [ "$EXISTING_SCAN" != "null" ] && [ -n "$EXISTING_SCAN_CONFIG" ]; then
    log "Found existing scan configuration 'acs-catch-all' (ID: $EXISTING_SCAN)"
    
    # Check if configuration is valid and matches expected settings
    EXISTING_ONE_TIME=$(echo "$EXISTING_SCAN_CONFIG" | jq -r '.scanConfig.oneTimeScan // false' 2>/dev/null || echo "false")
    EXISTING_SCHEDULE_TYPE=$(echo "$EXISTING_SCAN_CONFIG" | jq -r '.scanConfig.scanSchedule.intervalType // "none"' 2>/dev/null || echo "none")
    
    # Extract clusters as an array and normalize for comparison
    EXISTING_CLUSTERS_RAW=$(echo "$EXISTING_SCAN_CONFIG" | jq -r '.clusters[]?' 2>/dev/null || echo "")
    EXISTING_CLUSTERS=$(echo "$EXISTING_CLUSTERS_RAW" | tr '\n' ' ' | xargs || echo "")
    
    # Debug: Show what we're comparing
    log "  Existing scan type: oneTimeScan=$EXISTING_ONE_TIME, schedule=$EXISTING_SCHEDULE_TYPE"
    log "  Existing clusters: $EXISTING_CLUSTERS"
    log "  Expected cluster ID: $PRODUCTION_CLUSTER_ID"
    
    # Check if it's a scheduled scan (not one-time) and includes our cluster
    if [ "$EXISTING_ONE_TIME" = "false" ] && [ "$EXISTING_SCHEDULE_TYPE" != "none" ]; then
        # More robust cluster matching - check if any cluster ID matches
        CLUSTER_MATCH=false
        if [ -n "$EXISTING_CLUSTERS" ]; then
            # Check each cluster ID individually
            while IFS= read -r cluster_id; do
                if [ -n "$cluster_id" ] && [ "$cluster_id" != "null" ]; then
                    # Normalize both IDs (remove whitespace) and compare
                    NORMALIZED_EXISTING=$(echo "$cluster_id" | tr -d '[:space:]')
                    NORMALIZED_EXPECTED=$(echo "$PRODUCTION_CLUSTER_ID" | tr -d '[:space:]')
                    if [ "$NORMALIZED_EXISTING" = "$NORMALIZED_EXPECTED" ]; then
                        CLUSTER_MATCH=true
                        break
                    fi
                fi
            done <<< "$EXISTING_CLUSTERS_RAW"
        fi
        
        # Also check if there are any clusters at all (if empty, might be valid for all clusters)
        if [ -z "$EXISTING_CLUSTERS" ] || [ "$EXISTING_CLUSTERS" = "null" ]; then
            log "  Note: Existing scan has no specific clusters (may apply to all clusters)"
            # If scan is scheduled and successful, keep it even without specific cluster match
            CLUSTER_MATCH=true
        fi
        
        if [ "$CLUSTER_MATCH" = true ]; then
            log "✓ Existing configuration is valid: scheduled scan with matching cluster"
            log "  Schedule: $EXISTING_SCHEDULE_TYPE"
            log "  Cluster: $PRODUCTION_CLUSTER_ID"
            log "Using existing scan configuration (ID: $EXISTING_SCAN)"
            NEED_RECREATE=false
            SCAN_CONFIG_ID="$EXISTING_SCAN"
        else
            # Check if the scan configuration includes any clusters at all
            # If it's a scheduled scan that's working, we should preserve it
            # Only recreate if we're certain it needs the specific cluster
            log "Existing configuration found but cluster IDs don't match exactly."
            log "  Existing clusters: $EXISTING_CLUSTERS"
            log "  Expected cluster: $PRODUCTION_CLUSTER_ID"
            
            # If existing scan has no clusters specified, it might apply to all clusters
            # In that case, if it's scheduled and working, keep it
            if [ -z "$EXISTING_CLUSTERS" ] || [ "$EXISTING_CLUSTERS" = "null" ] || [ "$EXISTING_CLUSTERS" = "" ]; then
                log "  Note: Existing scan has no specific clusters - may apply to all clusters"
                log "  Keeping existing scan configuration (scheduled scans without clusters apply to all)"
                NEED_RECREATE=false
                SCAN_CONFIG_ID="$EXISTING_SCAN"
            else
                # Only recreate if there's a real mismatch with specific clusters
                log "  Will recreate to ensure correct cluster is included..."
            fi
        fi
    else
        log "Existing configuration is a one-time scan or missing schedule. Will recreate..."
    fi
fi

if [ "$NEED_RECREATE" = true ]; then
    if [ -n "$EXISTING_SCAN" ] && [ "$EXISTING_SCAN" != "null" ]; then
        log "Deleting existing scan configuration before creating new one..."
        
        set +e
        DELETE_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X DELETE \
            -H "Authorization: Bearer $ROX_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$ROX_ENDPOINT/v2/compliance/scan/configurations/$EXISTING_SCAN" 2>&1)
        DELETE_EXIT_CODE=$?
        DELETE_HTTP_CODE=$(echo "$DELETE_RESPONSE" | grep -oE '[0-9]{3}' | tail -1 || echo "")
        set -e
        
        if [ $DELETE_EXIT_CODE -ne 0 ]; then
            warning "Failed to delete existing scan configuration (exit code: $DELETE_EXIT_CODE). Response: ${DELETE_RESPONSE:0:500}"
            warning "Will attempt to create new configuration anyway..."
        elif [ -n "$DELETE_HTTP_CODE" ] && [ "$DELETE_HTTP_CODE" -ge 200 ] && [ "$DELETE_HTTP_CODE" -lt 300 ]; then
            log "✓ Successfully deleted existing scan configuration"
            # Wait a moment for deletion to complete
            sleep 2
        elif [ -n "$DELETE_HTTP_CODE" ] && [ "$DELETE_HTTP_CODE" -eq 404 ]; then
            log "Scan configuration already deleted or not found (HTTP 404)"
        else
            warning "Unexpected response when deleting scan configuration (HTTP ${DELETE_HTTP_CODE:-unknown}). Response: ${DELETE_RESPONSE:0:500}"
            warning "Will attempt to create new configuration anyway..."
        fi
    else
        log "No existing 'acs-catch-all' scan configuration found"
    fi
    
    # Create compliance scan configuration
    log "Creating compliance scan configuration 'acs-catch-all'..."
    set +e
    SCAN_CONFIG_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X POST \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data-raw "{
        \"scanName\": \"acs-catch-all\",
        \"scanConfig\": {
            \"oneTimeScan\": false,
            \"profiles\": [
                \"ocp4-cis\",
                \"ocp4-cis-node\",
                \"ocp4-moderate\",
                \"ocp4-moderate-node\",
                \"ocp4-e8\",
                \"ocp4-high\",
                \"ocp4-high-node\",
                \"ocp4-nerc-cip\",
                \"ocp4-nerc-cip-node\",
                \"ocp4-pci-dss\",
                \"ocp4-pci-dss-node\",
                \"ocp4-stig\",
                \"ocp4-bsi\",
                \"ocp4-pci-dss-4-0\"
            ],
            \"scanSchedule\": {
                \"intervalType\": \"DAILY\",
                \"hour\": 12,
                \"minute\": 0
            },
            \"description\": \"Daily compliance scan for all profiles\"
        },
        \"clusters\": [
            \"$PRODUCTION_CLUSTER_ID\"
        ]
    }" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
    SCAN_CREATE_EXIT_CODE=$?
    set -e
    
    if [ $SCAN_CREATE_EXIT_CODE -ne 0 ]; then
        error "Failed to create compliance scan configuration (exit code: $SCAN_CREATE_EXIT_CODE). Response: ${SCAN_CONFIG_RESPONSE:0:500}"
    fi
    
    if [ -z "$SCAN_CONFIG_RESPONSE" ]; then
        error "Empty response from scan configuration creation API"
    fi
    
    # Log response for debugging (first 500 chars)
    log "API Response: ${SCAN_CONFIG_RESPONSE:0:500}"
    
    # Check for ProfileBundle processing error
    if echo "$SCAN_CONFIG_RESPONSE" | grep -qi "ProfileBundle.*still being processed"; then
        warning "Scan creation failed: ProfileBundle is still being processed"
        log ""
        log "This means the Compliance Operator is still processing profile bundles."
        log "Please wait for ProfileBundles to be ready and retry."
        log ""
        log "To check ProfileBundle status:"
        log "  oc get profilebundle -n openshift-compliance"
        log "  oc describe profilebundle ocp4 -n openshift-compliance"
        log ""
        log "Wait for dataStreamStatus to show 'Valid' before retrying."
        log ""
        error "Cannot create scan: ProfileBundles are still being processed. Wait and retry."
    fi
    
    if ! echo "$SCAN_CONFIG_RESPONSE" | jq . >/dev/null 2>&1; then
        # Check if it's an error message about ProfileBundle
        if echo "$SCAN_CONFIG_RESPONSE" | grep -qi "ProfileBundle"; then
            warning "Scan creation failed with ProfileBundle-related error:"
            echo "$SCAN_CONFIG_RESPONSE" | head -20
            log ""
            log "Check ProfileBundle status: oc get profilebundle -n openshift-compliance"
            error "ProfileBundle error detected. See above for details."
        else
            error "Invalid JSON response from scan configuration creation API. Response: ${SCAN_CONFIG_RESPONSE:0:300}"
        fi
    fi
    
    log "✓ Compliance scan configuration created successfully"
    
    # Get the scan configuration ID from the response - try multiple possible response structures
    SCAN_CONFIG_ID=$(echo "$SCAN_CONFIG_RESPONSE" | jq -r '.id // .configuration.id // empty' 2>/dev/null)
fi

# Get scan configuration ID for schedule creation (if not already set from existing config)
if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then

    if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
        log "Could not extract scan configuration ID from response, waiting a moment and trying to get it from configurations list..."
    log "Full response: $SCAN_CONFIG_RESPONSE"
    
    # Wait a moment for the configuration to be available
    sleep 2
    
    # Retry getting scan configurations with a few attempts
    MAX_RETRIES=3
    RETRY_COUNT=0
    SCAN_CONFIG_ID=""
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && ([ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]); do
        if [ $RETRY_COUNT -gt 0 ]; then
            log "Retry $RETRY_COUNT/$MAX_RETRIES: Waiting 3 seconds before checking again..."
            sleep 3
        fi
        
        # Get scan configurations to find our configuration
        set +e
        CONFIGS_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
            -H "Authorization: Bearer $ROX_API_TOKEN" \
            -H "Content-Type: application/json" \
            "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
        CONFIGS_EXIT_CODE=$?
        set -e

        if [ $CONFIGS_EXIT_CODE -ne 0 ]; then
            if [ $RETRY_COUNT -eq $((MAX_RETRIES - 1)) ]; then
                error "Failed to get scan configurations list (exit code: $CONFIGS_EXIT_CODE). Response: ${CONFIGS_RESPONSE:0:500}"
            else
                warning "Failed to get scan configurations list (exit code: $CONFIGS_EXIT_CODE), will retry..."
            fi
        else
            # Validate JSON response
            if echo "$CONFIGS_RESPONSE" | jq . >/dev/null 2>&1; then
                SCAN_CONFIG_ID=$(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[]? | select(.scanName == "acs-catch-all") | .id' 2>/dev/null | head -1)
                
                if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
                    log "✓ Found scan configuration ID: $SCAN_CONFIG_ID"
                    break
                else
                    # Log available configurations for debugging
                    AVAILABLE_CONFIGS=$(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[]? | .scanName' 2>/dev/null | tr '\n' ' ' || echo "none")
                    log "Configuration 'acs-catch-all' not found yet. Available configurations: $AVAILABLE_CONFIGS"
                fi
            else
                warning "Invalid JSON in configurations response: ${CONFIGS_RESPONSE:0:200}"
            fi
        fi
        
        RETRY_COUNT=$((RETRY_COUNT + 1))
    done
    
        if [ -z "$SCAN_CONFIG_ID" ] || [ "$SCAN_CONFIG_ID" = "null" ]; then
            # Final attempt - show full response for debugging
            log "Final configurations response: $CONFIGS_RESPONSE"
            error "Could not find 'acs-catch-all' configuration after $MAX_RETRIES attempts. Available configurations: $(echo "$CONFIGS_RESPONSE" | jq -r '.configurations[]? | .scanName' 2>/dev/null | tr '\n' ' ' || echo "none")"
        fi
    fi
fi

if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
    log "✓ Scan configuration ID: $SCAN_CONFIG_ID"
fi

# SCAN_CONFIG_ID is now available for use by subsequent scripts
if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
    log "✓ Scan configuration ID ready: $SCAN_CONFIG_ID"
else
    warning "Scan configuration ID not available. Scan schedule may not have been created successfully."
fi

log ""
log "========================================================="
log "Compliance Scan Schedule Setup Completed!"
log "========================================================="
log "Scan Configuration Name: acs-catch-all"
if [ -n "$SCAN_CONFIG_ID" ] && [ "$SCAN_CONFIG_ID" != "null" ]; then
    log "Scan Configuration ID: $SCAN_CONFIG_ID"
fi
log "Cluster ID: $PRODUCTION_CLUSTER_ID"
log "Profiles: ocp4-cis, ocp4-cis-node, ocp4-moderate, ocp4-moderate-node, ocp4-e8, ocp4-high, ocp4-high-node, ocp4-nerc-cip, ocp4-nerc-cip-node, ocp4-pci-dss, ocp4-pci-dss-node, ocp4-stig-node"
log "Schedule: Daily at 12:00"
log "========================================================="
log ""
log "The compliance scan schedule has been created in ACS Central."
log "The scan will run automatically on the configured schedule."
log "You can trigger a scan manually using the trigger script."
log ""

# Verify scan configuration was created successfully
log "Verifying scan configuration..."
set +e
VERIFY_CONFIGS=$(curl -k -s --connect-timeout 15 --max-time 120 -X GET \
    -H "Authorization: Bearer $ROX_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$ROX_ENDPOINT/v2/compliance/scan/configurations" 2>&1)
VERIFY_EXIT_CODE=$?
set -e

if [ $VERIFY_EXIT_CODE -eq 0 ] && echo "$VERIFY_CONFIGS" | jq . >/dev/null 2>&1; then
    VERIFY_SCAN=$(echo "$VERIFY_CONFIGS" | jq -r ".configurations[] | select(.scanName == \"acs-catch-all\") | .id" 2>/dev/null | head -1)
    if [ -n "$VERIFY_SCAN" ] && [ "$VERIFY_SCAN" != "null" ]; then
        log "✓ Scan configuration verified in ACS Central (ID: $VERIFY_SCAN)"
    else
        warning "Scan configuration not found in verification check"
    fi
else
    warning "Could not verify scan configuration (this is non-fatal)"
fi

log ""

