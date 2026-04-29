#!/usr/bin/env bash

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_ok() { echo -e "  ${GREEN}✓${NC} $*"; }
print_fail() { echo -e "  ${RED}✗${NC} $*"; }

MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
MCP_DEPLOYMENT="${MCP_DEPLOYMENT:-stackrox-mcp}"
MCP_ROUTE_NAME="${MCP_ROUTE_NAME:-stackrox-mcp}"
MCP_HEALTH_PATH="${MCP_HEALTH_PATH:-/health}"
MCP_ROLLOUT_TIMEOUT="${MCP_ROLLOUT_TIMEOUT:-120s}"

FAILURES=0

check_prereqs() {
    print_step "Checking prerequisites"
    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found in PATH"
        exit 1
    fi
    if ! command -v curl &>/dev/null; then
        print_error "curl not found in PATH"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq not found in PATH"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi
    print_ok "Tools present and cluster session is active"
}

check_namespace_and_deployment() {
    print_step "Validating namespace and deployment"
    if oc get namespace "${MCP_NAMESPACE}" &>/dev/null; then
        print_ok "Namespace ${MCP_NAMESPACE} exists"
    else
        print_fail "Namespace ${MCP_NAMESPACE} not found"
        FAILURES=$((FAILURES + 1))
        return
    fi

    if oc get deployment "${MCP_DEPLOYMENT}" -n "${MCP_NAMESPACE}" &>/dev/null; then
        print_ok "Deployment ${MCP_DEPLOYMENT} exists"
    else
        print_fail "Deployment ${MCP_DEPLOYMENT} not found"
        FAILURES=$((FAILURES + 1))
        return
    fi

    if oc rollout status "deployment/${MCP_DEPLOYMENT}" -n "${MCP_NAMESPACE}" --timeout="${MCP_ROLLOUT_TIMEOUT}" &>/dev/null; then
        print_ok "Deployment rollout is complete"
    else
        print_fail "Deployment rollout did not complete within ${MCP_ROLLOUT_TIMEOUT}"
        FAILURES=$((FAILURES + 1))
    fi
}

check_route_health() {
    print_step "Validating MCP route and health endpoint"
    local route_host
    route_host="$(oc get route "${MCP_ROUTE_NAME}" -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || true)"
    if [ -z "${route_host}" ]; then
        print_fail "Route ${MCP_ROUTE_NAME} not found or has no host"
        FAILURES=$((FAILURES + 1))
        return
    fi
    print_ok "Route host detected: ${route_host}"

    local health_url
    health_url="https://${route_host}${MCP_HEALTH_PATH}"

    local health_response
    health_response="$(curl -k -sS --max-time 15 "${health_url}" || true)"
    if [ -z "${health_response}" ]; then
        print_fail "Health endpoint returned an empty response: ${health_url}"
        FAILURES=$((FAILURES + 1))
        return
    fi

    if jq -e '.status == "ok"' >/dev/null 2>&1 <<< "${health_response}"; then
        print_ok "Health endpoint returned status=ok"
    else
        print_fail "Unexpected health response: ${health_response}"
        FAILURES=$((FAILURES + 1))
    fi
}

main() {
    echo ""
    print_step "MCP server smoke test"
    echo ""

    check_prereqs
    check_namespace_and_deployment
    check_route_health

    echo ""
    if [ "${FAILURES}" -eq 0 ]; then
        print_info "All MCP server checks passed"
        exit 0
    fi

    print_error "${FAILURES} check(s) failed"
    exit 1
}

main "$@"
