#!/bin/bash

set -euo pipefail

# Configure StackRox MCP integration with OpenShift Lightspeed
# Based on: https://github.com/stackrox/stackrox-mcp docs/lightspeed-integration
# Tested with OpenShift Lightspeed 1.0.8

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
OLS_CONFIG_NAME="${OLS_CONFIG_NAME:-cluster}"

# Load ROX_API_TOKEN from ~/.bashrc
export_bashrc_vars() {
    [ ! -f ~/.bashrc ] && return 0
    local line
    line=$(grep -E "^(export[[:space:]]+)?ROX_API_TOKEN=" ~/.bashrc 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
        eval "$line" 2>/dev/null || true
    fi
}

main() {
    print_step "StackRox MCP → OpenShift Lightspeed Integration"
    echo "=========================================="
    echo ""

    export_bashrc_vars

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_error "ROX_API_TOKEN is required for Lightspeed integration"
        print_info "Run basic-setup/install.sh first to generate it, or: export ROX_API_TOKEN='your-token'"
        exit 1
    fi

    # Check OpenShift Lightspeed is installed
    if ! oc get namespace "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_error "OpenShift Lightspeed namespace '${LIGHTSPEED_NAMESPACE}' not found"
        print_info "Install OpenShift Lightspeed first: ./lightspeed-setup/install.sh"
        exit 1
    fi

    if ! oc get olsconfig "${OLS_CONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_error "OLSConfig '${OLS_CONFIG_NAME}' not found in ${LIGHTSPEED_NAMESPACE}"
        print_info "Create OLSConfig with your LLM provider first (see lightspeed-setup/README.md)"
        exit 1
    fi

    # Check MCP server is running
    if ! oc get deployment stackrox-mcp -n "${MCP_NAMESPACE}" &>/dev/null; then
        print_error "StackRox MCP deployment not found in ${MCP_NAMESPACE}"
        print_info "Run mcp-server-setup/install.sh first"
        exit 1
    fi

    MCP_URL="http://stackrox-mcp.${MCP_NAMESPACE}.svc:8080/mcp"
    print_info "MCP server URL: ${MCP_URL}"
    echo ""

    # 1. Create authorization header secret
    print_step "Creating authorization header secret..."
    local auth_header_b64
    auth_header_b64=$(echo -n "Bearer ${ROX_API_TOKEN}" | base64 | tr -d '\n')
    oc create secret generic stackrox-mcp-authorization-header \
        --namespace "${LIGHTSPEED_NAMESPACE}" \
        --from-literal=header="${auth_header_b64}" \
        --dry-run=client -o yaml | oc apply -f -
    print_info "✓ Secret stackrox-mcp-authorization-header created/updated"
    echo ""

    # 2. Patch OLSConfig to add MCP server
    print_step "Configuring OLSConfig with StackRox MCP..."
    if ! command -v jq &>/dev/null; then
        print_error "jq is required for OLSConfig patch. Install: brew install jq (macOS) or dnf install jq (RHEL)"
        exit 1
    fi

    local olsconfig_json
    olsconfig_json=$(oc get olsconfig "${OLS_CONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" -o json)
    local has_mcpserver
    has_mcpserver=$(echo "${olsconfig_json}" | jq -r '.spec.featureGates[]? | select(. == "MCPServer")' 2>/dev/null || echo "")
    local has_stackrox
    has_stackrox=$(echo "${olsconfig_json}" | jq -r '.spec.mcpServers[]? | select(.name == "stackrox-mcp") | .name' 2>/dev/null || echo "")

    local patch_file
    patch_file=$(mktemp)
    trap 'rm -f "${patch_file}"' EXIT

    if [ -z "${has_mcpserver}" ] || [ -z "${has_stackrox}" ]; then
        # Build merge patch
        local feature_gates
        feature_gates=$(echo "${olsconfig_json}" | jq -c '.spec.featureGates // []')
        if [ -z "${has_mcpserver}" ]; then
            feature_gates=$(echo "${feature_gates}" | jq -c '. + ["MCPServer"] | unique')
        fi

        local mcp_servers
        mcp_servers=$(echo "${olsconfig_json}" | jq -c '.spec.mcpServers // []')
        if [ -z "${has_stackrox}" ]; then
            local mcp_entry
            mcp_entry=$(jq -n --arg url "${MCP_URL}" '{"name":"stackrox-mcp","streamableHTTP":{"url":$url,"enableSSE":false,"headers":{"authorization":"stackrox-mcp-authorization-header"},"sseReadTimeout":30,"timeout":60}}')
            mcp_servers=$(echo "${mcp_servers}" | jq -c --argjson entry "${mcp_entry}" '. + [$entry]')
        fi

        echo "{\"spec\":{\"featureGates\":${feature_gates},\"mcpServers\":${mcp_servers}}}" > "${patch_file}"

        patch_content=$(cat "${patch_file}")
        oc patch olsconfig "${OLS_CONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" \
            --type=merge -p "${patch_content}"
        print_info "✓ OLSConfig patched with StackRox MCP server"
    else
        print_info "✓ OLSConfig already has StackRox MCP integration"
    fi
    echo ""

    print_step "Integration complete"
    echo "=========================================="
    print_info "Test in OpenShift Lightspeed with: \"List all clusters secured by StackRox\""
    echo ""
}

main "$@"
