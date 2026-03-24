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

# Default oc client timeout (0 = no timeout in oc, which can hang silently on API issues)
MCP_OC_REQUEST_TIMEOUT="${MCP_OC_REQUEST_TIMEOUT:-60s}"

# Use a timeout on every oc call so the script cannot hang forever
mcp_oc() {
    command oc --request-timeout="${MCP_OC_REQUEST_TIMEOUT}" "$@"
}

# Surface failures when running under set -e (e.g. sed/oc) — log files stay useful
# shellcheck disable=SC2154 # LINENO is dynamic when the trap runs
trap 'e=$?; print_error "mcp-server-setup: command failed (exit ${e}) at line ${LINENO}. Re-run with: bash -x ${BASH_SOURCE[0]} for a trace." >&2; exit "${e}"' ERR

# Namespace placeholder substitution (must be top-level; nested defs can break on older bash)
mcp_subs_namespace() {
    sed -e "s|__MCP_NAMESPACE__|${MCP_NAMESPACE}|g" "$@"
}

# Load variables from ~/.bashrc without eval'ing command substitutions (e.g. $(oc get ...))
# — those would run during install and can hang with no output when the API is slow.
export_bashrc_vars() {
    [ ! -f ~/.bashrc ] && return 0
    for var in ROX_CENTRAL_URL ROX_API_TOKEN RHACS_NAMESPACE; do
        local line
        # grep exits 1 when no match; with pipefail that would kill the script under set -e
        line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1) || true
        if [ -z "$line" ]; then
            continue
        fi
        if grep -qE '\$\(|`' <<< "${line}"; then
            print_warn "Skipping ${var} from ~/.bashrc (contains command substitution — export ${var} in your shell first, or use a static URL/token)."
            continue
        fi
        [[ "${line}" =~ ^export[[:space:]]+ ]] || line="export ${line}"
        eval "${line}" 2>/dev/null || true
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
    if mcp_oc get svc central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        echo "central.${RHACS_NAMESPACE}.svc.cluster.local:443"
    else
        get_central_host_port
    fi
}

main() {
    print_step "StackRox MCP Server Deployment (Kubernetes manifests)"
    echo "=========================================="
    echo ""

    print_info "Loading ROX_* from ~/.bashrc (safe mode; no \$(...) execution)..."
    export_bashrc_vars

    print_info "Checking OpenShift login (oc request timeout ${MCP_OC_REQUEST_TIMEOUT})..."
    local oc_user
    oc_user=$(mcp_oc whoami 2>/dev/null || true)
    if [ -z "${oc_user}" ]; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi
    print_info "Logged in as: ${oc_user}"

    if [ -z "${ROX_CENTRAL_URL:-}" ]; then
        print_info "Detecting ROX_CENTRAL_URL from route central..."
        ROX_CENTRAL_URL=$(mcp_oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)
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

    print_info "Resolving Central URL for MCP config (cluster service vs route)..."
    CENTRAL_URL=$(get_central_url_for_mcp)
    print_info "Central URL for MCP: ${CENTRAL_URL}"
    echo ""

    if [ ! -d "${MANIFESTS_DIR}" ]; then
        print_error "Manifests directory not found: ${MANIFESTS_DIR}"
        exit 1
    fi

    local required
    required=(
        namespace.yaml serviceaccount.yaml configmap.yaml.template
        service.yaml deployment.yaml route.yaml
    )
    local f
    for f in "${required[@]}"; do
        if [ ! -f "${MANIFESTS_DIR}/${f}" ]; then
            print_error "Missing manifest file: ${MANIFESTS_DIR}/${f}"
            exit 1
        fi
    done

    # Process manifests (substitute placeholders)
    print_step "Processing manifests..."
    local tmpdir
    tmpdir=$(mktemp -d) || {
        print_error "mktemp -d failed (cannot build rendered manifests)"
        exit 1
    }
    trap "rm -rf '${tmpdir}'" EXIT

    mcp_subs_namespace "${MANIFESTS_DIR}/namespace.yaml" > "${tmpdir}/namespace.yaml"
    mcp_subs_namespace "${MANIFESTS_DIR}/serviceaccount.yaml" > "${tmpdir}/serviceaccount.yaml"
    if ! mcp_subs_namespace "${MANIFESTS_DIR}/configmap.yaml.template" | \
        sed -e "s|CENTRAL_URL|${CENTRAL_URL}|g" -e "s|AUTH_TYPE|${AUTH_TYPE}|g" \
        > "${tmpdir}/configmap.yaml"; then
        print_error "Failed to render configmap (sed pipeline). Check CENTRAL_URL / AUTH_TYPE."
        exit 1
    fi
    mcp_subs_namespace "${MANIFESTS_DIR}/service.yaml" > "${tmpdir}/service.yaml"
    mcp_subs_namespace "${MANIFESTS_DIR}/deployment.yaml" > "${tmpdir}/deployment.yaml"
    mcp_subs_namespace "${MANIFESTS_DIR}/route.yaml" > "${tmpdir}/route.yaml"
    print_info "✓ Manifests processed"
    echo ""

    # Apply manifests (stderr from oc is captured; ERR trap adds line number on failure)
    print_step "Deploying StackRox MCP server..."
    mcp_oc apply -f "${tmpdir}/namespace.yaml"
    mcp_oc apply -f "${tmpdir}/serviceaccount.yaml"
    mcp_oc apply -f "${tmpdir}/configmap.yaml"
    mcp_oc apply -f "${tmpdir}/service.yaml"
    mcp_oc apply -f "${tmpdir}/deployment.yaml"
    mcp_oc apply -f "${tmpdir}/route.yaml"

    # Inject API token as env var when using static auth
    if [ "${USE_STATIC_AUTH}" = true ]; then
        print_info "Configuring static auth with ROX_API_TOKEN..."
        mcp_oc set env deployment/stackrox-mcp -n "${MCP_NAMESPACE}" \
            STACKROX_MCP__CENTRAL__AUTH_TYPE=static \
            STACKROX_MCP__CENTRAL__API_TOKEN="${ROX_API_TOKEN}" \
            --overwrite
    fi

    print_info "✓ StackRox MCP server deployed"
    echo ""

    # Wait for rollout
    print_step "Waiting for deployment..."
    mcp_oc rollout status deployment/stackrox-mcp -n "${MCP_NAMESPACE}" --timeout=120s || true
    echo ""

    # OpenShift Lightspeed integration (optional)
    if [ -f "${SCRIPT_DIR}/02-configure-lightspeed-integration.sh" ]; then
        if mcp_oc get namespace openshift-lightspeed &>/dev/null && mcp_oc get olsconfig cluster -n openshift-lightspeed &>/dev/null; then
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
    actual_route_host=$(mcp_oc get route stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
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
