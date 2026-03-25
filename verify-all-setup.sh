#!/usr/bin/env bash
#
# Verify cluster state for each *-setup install (basic, lightspeed, FAM, monitoring, MCP, virt).
#
# Usage:
#   ./verify-all-setup.sh
#
# Optional: ROX_API_TOKEN (for FAM policy checks via RHACS API). If unset, FAM API checks are skipped.
#
# Skip a section (e.g. you did not run that install):
#   VERIFY_SKIP_FAM=1 ./verify-all-setup.sh
#   VERIFY_SKIP_VIRT=1 ./verify-all-setup.sh
#   # or reuse install-all flags (SKIP_FAM_SETUP; legacy SKIP_FIM_SETUP still honored):
#   SKIP_FAM_SETUP=1 ./verify-all-setup.sh
#   SKIP_VIRT_SCANNING=1 ./verify-all-setup.sh
#
# Exit: 0 = no failures (warnings allowed); 1 = one or more checks failed.
# --- end help ---

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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
# CronJob rhacs-fam-exec-trigger is created in the app namespace (install.sh default: payments)
FAM_CRON_NAMESPACE="${FAM_CRON_NAMESPACE:-payments}"

FAILURES=0
WARNINGS=0

usage() {
    sed -n '2,/^# --- end help ---$/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^--- end help ---$/d'
}

# $1 section name, $2 verify env name, $3 install skip env name
# Optional $4/$5: legacy verify/skip env names (e.g. VERIFY_SKIP_FIM / SKIP_FIM_SETUP for fam-setup)
skip_section() {
    local name="$1"
    local vv="$2"
    local iv="$3"
    if [ "${!vv:-0}" = "1" ] || [ "${!iv:-0}" = "1" ]; then
        print_info "Skipping ${name} (${vv}=1 or ${iv}=1)"
        return 0
    fi
    if [ -n "${4:-}" ] && [ -n "${5:-}" ]; then
        local lvv="$4"
        local liv="$5"
        if [ "${!lvv:-0}" = "1" ] || [ "${!liv:-0}" = "1" ]; then
            print_info "Skipping ${name} (legacy ${lvv}=1 or ${liv}=1)"
            return 0
        fi
    fi
    return 1
}

get_central_url() {
    if [ -n "${ROX_CENTRAL_URL:-}" ]; then
        echo "${ROX_CENTRAL_URL}"
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo ""
}

verify_basic() {
    print_step "basic-setup"
    local failed=0

    if ! oc get deployment central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_fail "Deployment 'central' not found in ${RHACS_NAMESPACE}"
        return 1
    fi
    print_ok "Deployment central exists"

    local ready desired
    ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
        print_ok "Central readyReplicas=${ready} (desired ${desired})"
    else
        print_fail "Central not ready (readyReplicas=${ready}, desired ${desired})"
        failed=1
    fi

    if oc get route central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "Route central exists"
    else
        print_warn "Route central not found (non-standard install?)"
        WARNINGS=$((WARNINGS + 1))
    fi

    if oc get securedcluster -n "${RHACS_NAMESPACE}" -o name &>/dev/null; then
        print_ok "SecuredCluster CR present"
    else
        print_warn "No SecuredCluster in ${RHACS_NAMESPACE}"
        WARNINGS=$((WARNINGS + 1))
    fi

    return "${failed}"
}

verify_lightspeed() {
    print_step "lightspeed-setup"
    local failed=0

    if ! oc get namespace "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_fail "Namespace ${LIGHTSPEED_NAMESPACE} not found"
        return 1
    fi
    print_ok "Namespace ${LIGHTSPEED_NAMESPACE} exists"

    local pods_ready=0
    pods_ready=$(oc get pods -n "${LIGHTSPEED_NAMESPACE}" --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')
    if [ "${pods_ready:-0}" -ge 1 ] 2>/dev/null; then
        print_ok "At least one pod Running in ${LIGHTSPEED_NAMESPACE}"
    else
        print_warn "No Running pods in ${LIGHTSPEED_NAMESPACE} yet"
        WARNINGS=$((WARNINGS + 1))
    fi

    if oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_ok "OLSConfig cluster exists"
        # OLS publishes overallStatus (e.g. Ready) and per-component conditions (ApiReady, CacheReady, — not type "Ready")
        local overall api_ready cache_ready plugin_ready legacy_ready
        overall=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.overallStatus}' 2>/dev/null || echo "")
        api_ready=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="ApiReady")].status}' 2>/dev/null || echo "")
        cache_ready=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="CacheReady")].status}' 2>/dev/null || echo "")
        plugin_ready=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="ConsolePluginReady")].status}' 2>/dev/null || echo "")
        legacy_ready=$(oc get olsconfig cluster -n "${LIGHTSPEED_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

        if [ "${overall}" = "Ready" ]; then
            print_ok "OLSConfig overallStatus=Ready"
        elif [ "${legacy_ready}" = "True" ]; then
            print_ok "OLSConfig Ready=True (legacy condition)"
        elif [ "${api_ready}" = "True" ] && [ "${cache_ready}" = "True" ] && [ "${plugin_ready}" = "True" ]; then
            print_ok "OLSConfig component conditions all True (Api/Cache/ConsolePlugin)"
        elif [ -n "${overall}" ]; then
            print_warn "OLSConfig overallStatus=${overall} (expected Ready when fully reconciled)"
            WARNINGS=$((WARNINGS + 1))
        else
            print_warn "OLSConfig status not Ready yet (overallStatus empty; ApiReady=${api_ready:-?} CacheReady=${cache_ready:-?} ConsolePluginReady=${plugin_ready:-?})"
            WARNINGS=$((WARNINGS + 1))
        fi
    else
        print_warn "OLSConfig not found (skipped LLM step or not created yet)"
        WARNINGS=$((WARNINGS + 1))
    fi

    return "${failed}"
}

verify_fam() {
    print_step "fam-setup"
    local failed=0

    local sc mode
    sc=$(oc get securedcluster -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${sc}" ]; then
        print_fail "No SecuredCluster in ${RHACS_NAMESPACE}"
        return 1
    fi

    mode=$(oc get securedcluster "${sc}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.perNode.fileActivityMonitoring.mode}' 2>/dev/null || echo "")
    if [ "${mode}" = "Enabled" ]; then
        print_ok "SecuredCluster ${sc}: fileActivityMonitoring.mode=Enabled"
    else
        print_fail "File activity monitoring not enabled on SecuredCluster ${sc} (mode='${mode}')"
        failed=1
    fi

    if oc get cronjob rhacs-fam-exec-trigger -n "${FAM_CRON_NAMESPACE}" &>/dev/null; then
        print_ok "CronJob rhacs-fam-exec-trigger in ${FAM_CRON_NAMESPACE}"
    else
        print_fail "CronJob rhacs-fam-exec-trigger not found in ${FAM_CRON_NAMESPACE}"
        failed=1
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_warn "ROX_API_TOKEN unset — skipping FAM policy API check"
        WARNINGS=$((WARNINGS + 1))
        return "${failed}"
    fi

    local base
    base=$(get_central_url)
    if [ -z "${base}" ]; then
        print_warn "Could not determine Central URL — skipping policy API check"
        WARNINGS=$((WARNINGS + 1))
        return "${failed}"
    fi

    local policies_json
    policies_json=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${base}/v1/policies" 2>/dev/null || echo "")
    if ! echo "${policies_json}" | jq -e '.policies' &>/dev/null; then
        print_fail "Could not list policies from RHACS API"
        return 1
    fi

    for name in "fam-basic-node-monitoring" "fam-basic-deploy-monitoring"; do
        if echo "${policies_json}" | jq -e --arg n "$name" '.policies[] | select(.name==$n)' &>/dev/null; then
            print_ok "Policy present: ${name}"
        else
            print_fail "Policy missing: ${name}"
            failed=1
        fi
    done

    return "${failed}"
}

verify_monitoring() {
    print_step "monitoring-setup"
    local failed=0

    if oc get monitoringstack sample-stackrox-monitoring-stack -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "MonitoringStack sample-stackrox-monitoring-stack exists in ${RHACS_NAMESPACE}"
    else
        print_fail "MonitoringStack not found (expected name sample-stackrox-monitoring-stack)"
        failed=1
    fi

    if [ -n "${ROX_API_TOKEN:-}" ]; then
        local base providers
        base=$(get_central_url)
        if [ -n "${base}" ]; then
            providers=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${base}/v1/authProviders" 2>/dev/null || echo "")
            if echo "${providers}" | jq -e '.authProviders[] | select(.name=="Monitoring")' &>/dev/null; then
                print_ok "RHACS auth provider 'Monitoring' exists"
            else
                print_warn "Auth provider 'Monitoring' not found (step 03 may not have completed)"
                WARNINGS=$((WARNINGS + 1))
            fi
        fi
    else
        print_warn "ROX_API_TOKEN unset — skipping Monitoring auth provider API check"
        WARNINGS=$((WARNINGS + 1))
    fi

    return "${failed}"
}

verify_mcp() {
    print_step "mcp-server-setup"
    local failed=0

    if ! oc get namespace "${MCP_NAMESPACE}" &>/dev/null; then
        print_fail "Namespace ${MCP_NAMESPACE} not found"
        return 1
    fi
    print_ok "Namespace ${MCP_NAMESPACE} exists"

    if ! oc get deployment stackrox-mcp -n "${MCP_NAMESPACE}" &>/dev/null; then
        print_fail "Deployment stackrox-mcp not found"
        return 1
    fi

    local ready desired
    ready=$(oc get deployment stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    desired=$(oc get deployment stackrox-mcp -n "${MCP_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
    if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then
        print_ok "stackrox-mcp readyReplicas=${ready}"
    else
        print_fail "stackrox-mcp not ready (readyReplicas=${ready}, desired ${desired})"
        failed=1
    fi

    return "${failed}"
}

verify_virt() {
    print_step "virt-scanning-setup"
    local failed=0

    if ! oc get vm rhel-webserver -n default &>/dev/null; then
        print_fail "VM rhel-webserver not found in namespace default"
        failed=1
    else
        print_ok "VM rhel-webserver exists"
        local phase
        phase=$(oc get vm rhel-webserver -n default -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "")
        if [ -n "${phase}" ]; then
            print_ok "VM status: ${phase}"
        fi
    fi

    return "${failed}"
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    echo ""
    print_step "RHACS demo — verify all *-setup installs"
    echo ""

    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into a cluster. Run: oc login"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq is required for API checks"
        exit 1
    fi

    if skip_section "basic-setup" "VERIFY_SKIP_BASIC" "SKIP_BASIC_SETUP"; then
        :
    else
        verify_basic || FAILURES=$((FAILURES + 1))
    fi
    echo ""

    if skip_section "lightspeed-setup" "VERIFY_SKIP_LIGHTSPEED" "SKIP_LIGHTSPEED_SETUP"; then
        :
    else
        verify_lightspeed || FAILURES=$((FAILURES + 1))
    fi
    echo ""

    if skip_section "fam-setup" "VERIFY_SKIP_FAM" "SKIP_FAM_SETUP" "VERIFY_SKIP_FIM" "SKIP_FIM_SETUP"; then
        :
    else
        verify_fam || FAILURES=$((FAILURES + 1))
    fi
    echo ""

    if skip_section "monitoring-setup" "VERIFY_SKIP_MONITORING" "SKIP_MONITORING_SETUP"; then
        :
    else
        verify_monitoring || FAILURES=$((FAILURES + 1))
    fi
    echo ""

    if skip_section "mcp-server-setup" "VERIFY_SKIP_MCP" "SKIP_MCP_SETUP"; then
        :
    else
        verify_mcp || FAILURES=$((FAILURES + 1))
    fi
    echo ""

    if skip_section "virt-scanning-setup" "VERIFY_SKIP_VIRT" "SKIP_VIRT_SCANNING"; then
        :
    else
        verify_virt || FAILURES=$((FAILURES + 1))
    fi

    echo ""
    print_step "Summary"
    if [ "${FAILURES}" -eq 0 ]; then
        print_ok "No failed checks (${WARNINGS} warning(s))"
        exit 0
    fi
    print_fail "${FAILURES} section(s) had failures — review messages above"
    exit 1
}

main "$@"
