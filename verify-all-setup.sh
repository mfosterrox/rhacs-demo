#!/usr/bin/env bash
#
# Verify cluster state for each *-setup install (basic, FAM, monitoring, MCP, OpenShift Pipelines).
#
# Usage:
#   ./verify-all-setup.sh
#
# Optional: ROX_API_TOKEN (for FAM policy checks via RHACS API). If unset, FAM API checks are skipped.
#
# Skip a section (e.g. you did not run that install):
#   VERIFY_SKIP_FAM=1 ./verify-all-setup.sh
#   # or reuse install-all flags (SKIP_FAM_SETUP; legacy SKIP_FIM_SETUP still honored):
#   SKIP_FAM_SETUP=1 ./verify-all-setup.sh
#   VERIFY_SKIP_PIPELINES=1 ./verify-all-setup.sh
#   SKIP_OPENSHIFT_PIPELINES_SETUP=1 ./verify-all-setup.sh
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

if [ -f "${REPO_ROOT}/setup-rerun-hint.sh" ]; then
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/setup-rerun-hint.sh"
    setup_rerun_register "${BASH_SOURCE[0]}" "$@"
fi

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
PIPELINE_NAMESPACE="${PIPELINE_NAMESPACE:-pipeline-demo}"
# CronJob rhacs-fam-exec-trigger is created in the app namespace (install.sh default: payments)
FAM_CRON_NAMESPACE="${FAM_CRON_NAMESPACE:-payments}"

FAILURES=0
WARNINGS=0
FAIL_BASIC=0
FAIL_FAM=0
FAIL_MONITORING=0
FAIL_MCP=0
FAIL_PIPELINES=0

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
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
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
    local ms_name="sample-stackrox-monitoring-stack"
    local scrape_name="sample-stackrox-scrape-config"
    local prom_sts default_sts
    default_sts="${ms_name}-prometheus"
    prom_sts=$(oc get sts -n "${RHACS_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -F "${ms_name}" | grep -i prometheus | head -1)
    if [ -z "${prom_sts}" ]; then
        prom_sts=$(oc get sts -n "${RHACS_NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i prometheus | head -1)
    fi
    if [ -z "${prom_sts}" ]; then
        prom_sts="${default_sts}"
    fi

    if oc get monitoringstack "${ms_name}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "MonitoringStack ${ms_name} exists in ${RHACS_NAMESPACE}"
    else
        print_fail "MonitoringStack not found (expected name ${ms_name})"
        failed=1
    fi

    if oc get scrapeconfig "${scrape_name}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_ok "ScrapeConfig ${scrape_name} exists in ${RHACS_NAMESPACE}"
    else
        print_fail "ScrapeConfig not found (expected name ${scrape_name}) — re-run monitoring-setup/02-install-monitoring.sh or oc apply -f monitoring-examples/cluster-observability-operator/scrape-config.yaml"
        failed=1
    fi

    if oc get "statefulset/${prom_sts}" -n "${RHACS_NAMESPACE}" &>/dev/null; then
        local ready desired
        ready=$(oc get "statefulset/${prom_sts}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        desired=$(oc get "statefulset/${prom_sts}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "1")
        if [ "${desired:-0}" -ge 1 ] 2>/dev/null && [ "${ready:-0}" -ge "${desired}" ] 2>/dev/null; then
            print_ok "Prometheus StatefulSet ${prom_sts} ready (readyReplicas=${ready}, desired=${desired})"
        else
            print_warn "Prometheus StatefulSet ${prom_sts} not fully ready (readyReplicas=${ready:-?}, desired=${desired:-?})"
            WARNINGS=$((WARNINGS + 1))
        fi
    elif oc get pods -n "${RHACS_NAMESPACE}" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | grep -q .; then
        print_ok "Prometheus pod(s) present (label app.kubernetes.io/name=prometheus); StatefulSet name may differ from ${default_sts}"
    else
        print_warn "No Prometheus StatefulSet ${prom_sts} and no pods with app.kubernetes.io/name=prometheus — COO may still be reconciling"
        WARNINGS=$((WARNINGS + 1))
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

verify_openshift_pipelines() {
    print_step "openshift-pipelines-setup (Tekton)"
    local failed=0
    local ns="${PIPELINE_NAMESPACE}"

    if ! oc get namespace "${ns}" &>/dev/null; then
        print_fail "Namespace ${ns} not found"
        return 1
    fi
    print_ok "Namespace ${ns} exists"

    local t
    for t in rox-image-scan rox-image-check rox-deployment-check; do
        if oc get task "${t}" -n "${ns}" &>/dev/null; then
            print_ok "Task ${t} exists"
        else
            print_fail "Task ${t} not found in ${ns}"
            failed=1
        fi
    done

    local p
    for p in rox-pipeline rox-log4shell-pipeline; do
        if oc get pipeline "${p}" -n "${ns}" &>/dev/null; then
            print_ok "Pipeline ${p} exists"
        else
            print_fail "Pipeline ${p} not found in ${ns}"
            failed=1
        fi
    done

    if oc get secret roxsecrets -n "${ns}" &>/dev/null; then
        print_ok "Secret roxsecrets exists"
    else
        print_fail "Secret roxsecrets not found in ${ns}"
        failed=1
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
        setup_rerun_hint_print
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into a cluster. Run: oc login"
        setup_rerun_hint_print
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq is required for API checks"
        setup_rerun_hint_print
        exit 1
    fi

    if skip_section "basic-setup" "VERIFY_SKIP_BASIC" "SKIP_BASIC_SETUP"; then
        :
    else
        verify_basic || {
            FAILURES=$((FAILURES + 1))
            FAIL_BASIC=1
        }
    fi
    echo ""

    if skip_section "fam-setup" "VERIFY_SKIP_FAM" "SKIP_FAM_SETUP" "VERIFY_SKIP_FIM" "SKIP_FIM_SETUP"; then
        :
    else
        verify_fam || {
            FAILURES=$((FAILURES + 1))
            FAIL_FAM=1
        }
    fi
    echo ""

    if skip_section "monitoring-setup" "VERIFY_SKIP_MONITORING" "SKIP_MONITORING_SETUP"; then
        :
    else
        verify_monitoring || {
            FAILURES=$((FAILURES + 1))
            FAIL_MONITORING=1
        }
    fi
    echo ""

    if skip_section "mcp-server-setup" "VERIFY_SKIP_MCP" "SKIP_MCP_SETUP"; then
        :
    else
        verify_mcp || {
            FAILURES=$((FAILURES + 1))
            FAIL_MCP=1
        }
    fi
    echo ""

    if skip_section "openshift-pipelines-setup" "VERIFY_SKIP_PIPELINES" "SKIP_OPENSHIFT_PIPELINES_SETUP"; then
        :
    else
        verify_openshift_pipelines || {
            FAILURES=$((FAILURES + 1))
            FAIL_PIPELINES=1
        }
    fi

    echo ""
    print_step "Summary"
    if [ "${FAILURES}" -eq 0 ]; then
        print_ok "No failed checks (${WARNINGS} warning(s))"
        exit 0
    fi
    print_fail "${FAILURES} section(s) had failures — review messages above"
    print_info "To rerun installs for failed section(s) (from repo root):"
    if [ "${FAIL_BASIC}" = "1" ]; then
        print_info "  cd \"${REPO_ROOT}\" && bash basic-setup/install.sh"
    fi
    if [ "${FAIL_FAM}" = "1" ]; then
        print_info "  cd \"${REPO_ROOT}\" && bash fam-setup/install.sh"
    fi
    if [ "${FAIL_MONITORING}" = "1" ]; then
        print_info "  cd \"${REPO_ROOT}\" && bash monitoring-setup/install.sh"
    fi
    if [ "${FAIL_MCP}" = "1" ]; then
        print_info "  cd \"${REPO_ROOT}\" && bash mcp-server-setup/install.sh"
    fi
    if [ "${FAIL_PIPELINES}" = "1" ]; then
        print_info "  cd \"${REPO_ROOT}\" && bash openshift-pipelines-setup/install.sh"
    fi
    print_info "To rerun this verifier: cd \"${REPO_ROOT}\" && bash verify-all-setup.sh"
    exit 1
}

main "$@"
