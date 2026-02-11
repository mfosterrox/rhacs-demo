#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Default values
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
ROX_CENTRAL_URL="${ROX_CENTRAL_URL:-}"
ROX_PASSWORD="${ROX_PASSWORD:-}"

# Function to check if jq is installed
ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    
    print_warn "jq is not installed, attempting to install..."
    
    if command -v dnf >/dev/null 2>&1; then
        if sudo dnf install -y jq >/dev/null 2>&1; then
            print_info "✓ jq installed successfully"
            return 0
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1; then
            print_info "✓ jq installed successfully"
            return 0
        fi
    fi
    
    print_error "Could not install jq. Please install it manually: sudo dnf install -y jq"
    return 1
}

# Function to get Central URL
get_central_url() {
    if [ -n "${ROX_CENTRAL_URL}" ]; then
        echo "${ROX_CENTRAL_URL}"
        return 0
    fi
    
    # Try to get from route
    local url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${url}" ]; then
        echo "${url}"
        return 0
    fi
    
    return 1
}

# Function to generate API token
generate_api_token() {
    local central_url=$1
    local password=$2
    
    # Remove https:// prefix for API call
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    
    print_info "Generating API token..."
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"rhacs-config-script-'$(date +%s)'","roles":["Admin"]}' 2>/dev/null || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        print_error "Failed to generate API token (HTTP ${http_code})"
        return 1
    fi
    
    local token=$(echo "${body}" | jq -r '.token' 2>/dev/null || echo "")
    if [ -z "${token}" ] || [ "${token}" = "null" ]; then
        print_error "Could not extract token from response"
        return 1
    fi
    
    echo "${token}"
    return 0
}

# Function to make API call
make_api_call() {
    local method=$1
    local endpoint=$2
    local token=$3
    local api_base=$4
    local data="${5:-}"
    
    local curl_opts="-k -s -w \n%{http_code}"
    curl_opts="${curl_opts} -X ${method}"
    curl_opts="${curl_opts} -H \"Authorization: Bearer ${token}\""
    curl_opts="${curl_opts} -H \"Content-Type: application/json\""
    
    if [ -n "${data}" ]; then
        curl_opts="${curl_opts} -d '${data}'"
    fi
    
    local response=$(eval "curl ${curl_opts} \"${api_base}/${endpoint}\"" 2>/dev/null || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_error "API call failed (HTTP ${http_code}): ${method} ${endpoint}"
        return 1
    fi
    
    echo "${body}"
    return 0
}

# Function to check if telemetry is already enabled
is_telemetry_enabled() {
    local token=$1
    local api_base=$2
    
    local config=$(make_api_call "GET" "config" "${token}" "${api_base}" "" 2>/dev/null || echo "")
    if [ -z "${config}" ]; then
        return 1
    fi
    
    local telemetry=$(echo "${config}" | jq -r '.config.publicConfig.telemetry.enabled' 2>/dev/null || echo "false")
    if [ "${telemetry}" = "true" ]; then
        return 0
    fi
    
    return 1
}

# Function to update RHACS configuration
update_rhacs_config() {
    local token=$1
    local api_base=$2
    
    print_info "Updating RHACS configuration..."
    
    # Simplified configuration focusing on key settings
    local config_payload='
{
  "config": {
    "publicConfig": {
      "telemetry": { "enabled": true }
    },
    "privateConfig": {
      "metrics": {
        "imageVulnerabilities": { "gatheringPeriodMinutes": 1 },
        "policyViolations": { "gatheringPeriodMinutes": 1 },
        "nodeVulnerabilities": { "gatheringPeriodMinutes": 1 }
      }
    }
  }
}'
    
    if ! make_api_call "PUT" "config" "${token}" "${api_base}" "${config_payload}" >/dev/null; then
        print_error "Failed to update configuration"
        return 1
    fi
    
    print_info "✓ Configuration updated successfully"
    return 0
}

# Main function
main() {
    print_info "=========================================="
    print_info "RHACS Configuration"
    print_info "=========================================="
    print_info ""
    
    # Check prerequisites
    print_step "Checking prerequisites..."
    
    if ! ensure_jq; then
        exit 1
    fi
    
    if [ -z "${ROX_PASSWORD}" ]; then
        print_error "ROX_PASSWORD is not set"
        print_error "Please provide the password as an argument to install.sh or set ROX_PASSWORD environment variable"
        exit 1
    fi
    
    # Get Central URL
    print_info "Getting Central URL..."
    local central_url=$(get_central_url)
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        print_error "Please ensure RHACS is installed or set ROX_CENTRAL_URL"
        exit 1
    fi
    print_info "Central URL: ${central_url}"
    
    # Setup API base URL
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local api_base="https://${api_host}/v1"
    
    # Generate API token
    local token=$(generate_api_token "${central_url}" "${ROX_PASSWORD}")
    if [ -z "${token}" ]; then
        print_error "Failed to generate API token"
        print_error "Please verify ROX_PASSWORD is correct"
        exit 1
    fi
    print_info "✓ API token generated"
    
    print_info ""
    
    # Check if already configured
    print_step "Checking current configuration..."
    if is_telemetry_enabled "${token}" "${api_base}"; then
        print_info "✓ RHACS configuration already applied (telemetry enabled)"
        print_info "Skipping configuration update"
    else
        print_info "Telemetry not enabled, applying configuration..."
        
        if ! update_rhacs_config "${token}" "${api_base}"; then
            print_error "Failed to update RHACS configuration"
            exit 1
        fi
        
        print_info "✓ RHACS configuration applied successfully"
    fi
    
    print_info ""
    print_info "=========================================="
    print_info "RHACS Configuration Complete"
    print_info "=========================================="
    print_info ""
    print_info "Configuration applied:"
    print_info "  - Telemetry and monitoring enabled"
    print_info "  - Metrics collection configured"
    print_info ""
}

# Run main function
main "$@"
