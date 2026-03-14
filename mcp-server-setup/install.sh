#!/bin/bash

set -euo pipefail

# StackRox MCP Server Deployment for RHACS
# Deploys using Kubernetes manifests from https://github.com/stackrox/stackrox-mcp
# Commit: 779f4a0c1af4c4bfbe340a918f8f3c658e153538

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
MANIFESTS_DIR="${SCRIPT_DIR}/manifests"
MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Load variables from ~/.bashrc
export_bashrc_vars() {
    [ ! -f ~/.bashrc ] && return 0
    for var in ROX_CENTRAL_URL ROX_API_TOKEN RHACS_NAMESPACE; do
        local line
        line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
            eval "$line" 2>/dev/null || true
        fi
    done
}

# Convert ROX_CENTRAL_URL (https://host) to host:port for MCP config
get_central_host_port() {
    local url="${ROX_CENTRAL_URL:-}"
    url="${url#https://}"
    url="${url#http://}"
    if [[ ! "$url" =~ :[0-9]+$ ]]; then
        url="${url}:443"
    fi
    echo "$url"
}

# Use internal K8s service URL when possible (same cluster)
get_central_url_for_mcp() {
    if oc get svc central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        echo "central.${RHACS_NAMESPACE}.svc.cluster.local:443"
    else
        get_central_host_port
    fi
}

main() {
    print_step "StackRox MCP Server Deployment (Kubernetes manifests)"
    echo "=========================================="
    echo ""

    export_bashrc_vars

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi

    if [ -z "${ROX_CENTRAL_URL:-}" ]; then
        ROX_CENTRAL_URL=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)
    fi

    if [ -z "${ROX_CENTRAL_URL:-}" ]; then
        print_error "ROX_CENTRAL_URL not set and could not detect from cluster"
        print_info "Set it: export ROX_CENTRAL_URL='https://central-stackrox.apps.your-cluster.com'"
        exit 1
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_warn "ROX_API_TOKEN not set - MCP server will use passthrough auth"
        print_info "For Cursor/CLI clients, use static auth: run basic-setup/install.sh first to generate ROX_API_TOKEN"
        AUTH_TYPE="passthrough"
        USE_STATIC_AUTH=false
    else
        AUTH_TYPE="static"
        USE_STATIC_AUTH=true
    fi

    CENTRAL_URL=$(get_central_url_for_mcp)
    print_info "Central URL for MCP: ${CENTRAL_URL}"
    echo ""

    if [ ! -d "${MANIFESTS_DIR}" ]; then
        print_error "Manifests directory not found: ${MANIFESTS_DIR}"
        exit 1
    fi

    # Process manifests (substitute placeholders)
    print_step "Processing manifests..."
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf '${tmpdir}'" EXIT

    subs() { sed -e "s|__MCP_NAMESPACE__|${MCP_NAMESPACE}|g" "$@"; }

    subs "${MANIFESTS_DIR}/namespace.yaml" > "${tmpdir}/namespace.yaml"
    subs "${MANIFESTS_DIR}/serviceaccount.yaml" > "${tmpdir}/serviceaccount.yaml"
    subs "${MANIFESTS_DIR}/configmap.yaml.template" | \
        sed -e "s|CENTRAL_URL|${CENTRAL_URL}|g" -e "s|AUTH_TYPE|${AUTH_TYPE}|g" \
        > "${tmpdir}/configmap.yaml"
    subs "${MANIFESTS_DIR}/service.yaml" > "${tmpdir}/service.yaml"
    subs "${MANIFESTS_DIR}/deployment.yaml" > "${tmpdir}/deployment.yaml"
    subs "${MANIFESTS_DIR}/route.yaml" > "${tmpdir}/route.yaml"
    print_info "✓ Manifests processed"
    echo ""

    # Apply manifests
    print_step "Deploying StackRox MCP server..."
    oc apply -f "${tmpdir}/namespace.yaml"
    oc apply -f "${tmpdir}/serviceaccount.yaml"
    oc apply -f "${tmpdir}/configmap.yaml"
    oc apply -f "${tmpdir}/service.yaml"
    oc apply -f "${tmpdir}/deployment.yaml"
    oc apply -f "${tmpdir}/route.yaml"

    # Inject API token as env var when using static auth
    if [ "${USE_STATIC_AUTH}" = true ]; then
        print_info "Configuring static auth with ROX_API_TOKEN..."
        oc set env deployment/stackrox-mcp -n "${MCP_NAMESPACE}" \
            STACKROX_MCP__CENTRAL__AUTH_TYPE=static \
            STACKROX_MCP__CENTRAL__API_TOKEN="${ROX_API_TOKEN}" \
            --overwrite
    fi

    print_info "✓ StackRox MCP server deployed"
    echo ""

    # Wait for rollout
    print_step "Waiting for deployment..."
    oc rollout status deployment/stackrox-mcp -n "${MCP_NAMESPACE}" --timeout=120s || true
    echo ""

    # OpenShift Lightspeed integration (optional)
    if [ -f "${SCRIPT_DIR}/02-configure-lightspeed-integration.sh" ]; then
        if oc get namespace openshift-lightspeed &>/dev/null && oc get olsconfig cluster -n openshift-lightspeed &>/dev/null; then
            if [ "${USE_STATIC_AUTH}" = true ]; then
                print_step "Configuring OpenShift Lightspeed integration..."
                if bash "${SCRIPT_DIR}/02-configure-lightspeed-integration.sh"; then
                    print_info "✓ Lightspeed integration configured"
                else
                    print_warn "Lightspeed integration failed (non-fatal)"
                fi
                echo ""
            else
                print_info "Skipping Lightspeed integration (ROX_API_TOKEN required)"
            fi
        else
            print_info "OpenShift Lightspeed not detected - skipping integration"
        fi
    fi

    # Summary
    print_step "Deployment complete"
    echo "=========================================="
    print_info "Namespace: ${MCP_NAMESPACE}"
    print_info "Service: stackrox-mcp.${MCP_NAMESPACE}.svc:8080"
    local actual_route_host
    actual_route_host=$(oc get route stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "${actual_route_host}" ]; then
        print_info "Route: https://${actual_route_host}"
        echo ""
        print_info "Add to Cursor MCP (HTTP transport):"
        echo "  claude mcp add stackrox --transport http --url https://${actual_route_host}"
    else
        echo ""
        print_info "For external access, create a Route or check: oc get route -n ${MCP_NAMESPACE}"
    fi
    echo ""
    print_info "Documentation: https://github.com/stackrox/stackrox-mcp"
    echo ""
}

main "$@"
