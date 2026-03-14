#!/bin/bash

# Diagnose OpenShift Lightspeed / OLSConfig issues
# Use when you see "Waiting for OpenShift Lightspeed service" or the service is not ready
#
# Usage: ./04-diagnose-olsconfig.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_ok() { echo -e "  ${GREEN}✓${NC} $*"; }
print_fail() { echo -e "  ${RED}✗${NC} $*"; }

LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"

main() {
    echo ""
    print_step "OpenShift Lightspeed / OLSConfig Diagnostics"
    echo "=================================================="
    echo ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi

    local issues=0

    # 1. OLSConfig
    print_step "1. OLSConfig status"
    if ! oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_fail "OLSConfig 'cluster' not found in ${LIGHTSPEED_NAMESPACE}"
        print_info "  Create it with: ./03-create-olsconfig.sh"
        ((issues++))
    else
        print_ok "OLSConfig exists"
        oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o wide 2>/dev/null || true
        echo ""
        print_info "Conditions:"
        oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}' 2>/dev/null || echo "  (none)"
        local ready
        ready=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "${ready}" = "False" ]; then
            local msg
            msg=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "")
            print_warn "  OLSConfig Ready=False: ${msg}"
            ((issues++))
        elif [ "${ready}" = "True" ]; then
            print_ok "OLSConfig Ready=True"
        fi
    fi
    echo ""

    # 2. Credentials secret
    print_step "2. Credentials secret"
    local secret_name
    secret_name=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.spec.llm.providers[0].credentialsSecretRef.name}' 2>/dev/null || echo "llm-credentials")
    if [ -z "${secret_name}" ]; then
        secret_name="llm-credentials"
    fi
    if ! oc get secret "${secret_name}" -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_fail "Secret '${secret_name}' not found"
        print_info "  Create it with: ./03-create-olsconfig.sh (or oc create secret generic ...)"
        ((issues++))
    else
        print_ok "Secret '${secret_name}' exists"
        if ! oc get secret "${secret_name}" -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.data.apitoken}' 2>/dev/null | base64 -d &>/dev/null; then
            print_warn "  Secret may be missing 'apitoken' key"
            ((issues++))
        else
            print_ok "Secret has apitoken"
        fi
    fi
    echo ""

    # 3. Pods
    print_step "3. Pods in ${LIGHTSPEED_NAMESPACE}"
    local pods
    pods=$(oc get pods -n "${LIGHTSPEED_NAMESPACE}" --no-headers 2>/dev/null | wc -l)
    if [ "${pods}" -eq 0 ]; then
        print_fail "No pods found - operator may not have deployed the Lightspeed service yet"
        print_info "  Wait 2-5 minutes after creating OLSConfig"
        ((issues++))
    else
        oc get pods -n "${LIGHTSPEED_NAMESPACE}" 2>/dev/null
        local not_ready
        not_ready=$(oc get pods -n "${LIGHTSPEED_NAMESPACE}" --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)
        if [ "${not_ready}" -gt 0 ]; then
            print_warn "Some pods not Running/Completed:"
            oc get pods -n "${LIGHTSPEED_NAMESPACE}" --no-headers 2>/dev/null | grep -v "Running\|Completed" | while read -r line; do
                echo "    ${line}"
            done
            ((issues++))
        fi
    fi
    echo ""

    # 4. Operator / controller logs (last 30 lines)
    print_step "4. Operator controller logs (recent)"
    local controller_pod
    controller_pod=$(oc get pods -n "${LIGHTSPEED_NAMESPACE}" -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "${controller_pod}" ]; then
        controller_pod=$(oc get pods -n "${LIGHTSPEED_NAMESPACE}" -o name 2>/dev/null | grep -i controller | head -1 | cut -d'/' -f2)
    fi
    if [ -z "${controller_pod}" ]; then
        print_warn "Controller pod not found - operator may be in a different namespace"
        print_info "  Try: oc get pods -A | grep -i lightspeed"
    else
        print_info "Pod: ${controller_pod}"
        oc logs -n "${LIGHTSPEED_NAMESPACE}" "${controller_pod}" --tail=30 2>/dev/null || print_warn "Could not fetch logs"
    fi
    echo ""

    # 5. LLM connectivity (if API/OLS pods exist)
    print_step "5. LLM / OLS service pods"
    oc get pods -n "${LIGHTSPEED_NAMESPACE}" -l app.kubernetes.io/name=ols 2>/dev/null || true
    oc get pods -n "${LIGHTSPEED_NAMESPACE}" 2>/dev/null | grep -E "api|ols|lightspeed" || true
    echo ""

    # Summary
    print_step "Summary"
    if [ "${issues}" -eq 0 ]; then
        print_ok "No obvious issues found. If the service still shows 'not ready':"
        echo "  - Wait a few more minutes (502 Bad Gateway often means components are still starting)"
        echo "  - Verify your LLM API key is valid and has quota"
        echo "  - Check provider-specific config (URL, deployment name, project ID)"
    else
        print_warn "Found ${issues} potential issue(s). See above."
    fi
    echo ""
    print_info "Useful commands:"
    echo "  oc get olsconfig -A"
    echo "  oc get pods -n ${LIGHTSPEED_NAMESPACE}"
    echo "  oc logs -n ${LIGHTSPEED_NAMESPACE} -l control-plane=controller-manager -f"
    echo "  oc describe olsconfig cluster -n ${LIGHTSPEED_NAMESPACE}"
    echo ""
}

main "$@"
