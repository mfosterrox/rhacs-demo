#!/bin/bash

# Script: install.sh (fam-setup)
# Description: Enable file activity monitoring on SecuredCluster, submit FAM policies to ACS via API,
#              apply fam-cron-exec-target.yaml (Deployment with a sleep loop: oc exec → touch /etc/passwd
#              on an interval), and optionally run a one-shot oc exec for an immediate demo.
# Requires: ROX_CENTRAL_ADDRESS (or auto-detect), ROX_API_TOKEN, oc logged in, jq
#
# Optional env:
#   FAM_SKIP_CRONJOB=1        — do not apply the exec CronJob manifest
#   FAM_SKIP_WORKLOAD_EXEC=1  — do not run one-shot deploy/node FAM triggers
#   FAM_SKIP_NODE_TRIGGER=1   — skip host/node FAM trigger (oc debug node)
#   FAM_SKIP_VIOLATION_WAIT=1 — do not poll RHACS for FAM violations
#   FAM_REQUIRE_VIOLATION=1     — exit non-zero if deploy policy has no alert before timeout
#   FAM_REQUIRE_NODE_VIOLATION=1 — exit non-zero if node policy has no alert before timeout
#   FAM_NODE_POLICY_NAME        — default fam-basic-node-monitoring
#   FAM_NODE_NAME               — worker node for oc debug (auto-detected if unset)
#   FAM_NODE_DEBUG_TIMEOUT_SEC  — timeout for oc debug node (default 180)
#   FAM_POST_POLICY_SLEEP_SEC — sleep after policies before triggers (default 15; sensor/policy propagation)
#   FAM_VIOLATION_WAIT_SEC    — max time to poll APIs (default 420)
#   FAM_VIOLATION_POLL_SEC    — interval between polls (default 15)
#   FAM_DEPLOY_POLICY_NAME    — policy to check via API (default fam-basic-deploy-monitoring)
#   FAM_INITIAL_ROLLOUT_TIMEOUT_SEC — oc rollout status for rhacs-fam-exec-runner (default 180)
#   FAM_EXEC_NAMESPACE        — default payments (also rewrites the runner manifest on apply)
#   FAM_EXEC_WORKLOAD         — default deployment/visa-processor (privileged sidecar can touch /etc/passwd)
#   FAM_EXEC_CONTAINER        — default visa-processor-sidecar (mastercard-processor runs non-root)
#   FAM_LOOP_SLEEP_SEC        — optional; sets Deployment env (default in YAML: 600)

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RHACS_DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"
FAM_POLICIES=(
    "${SCRIPT_DIR}/fam-basic-node-monitoring.json"
    "${SCRIPT_DIR}/fam-basic-deploy-monitoring.json"
)
FAM_CRON_MANIFEST="${SCRIPT_DIR}/fam-cron-exec-target.yaml"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
FAM_EXEC_NAMESPACE="${FAM_EXEC_NAMESPACE:-payments}"
FAM_EXEC_WORKLOAD="${FAM_EXEC_WORKLOAD:-deployment/visa-processor}"
FAM_EXEC_CONTAINER="${FAM_EXEC_CONTAINER:-visa-processor-sidecar}"
FAM_DEPLOY_POLICY_NAME="${FAM_DEPLOY_POLICY_NAME:-fam-basic-deploy-monitoring}"
FAM_NODE_POLICY_NAME="${FAM_NODE_POLICY_NAME:-fam-basic-node-monitoring}"

# Get Central URL
get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    local url
    url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${url}" ]; then
        echo "${url}"
        return 0
    fi
    return 1
}

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster. Run: oc login"
    setup_rerun_hint_print
    exit 1
fi

for policy_file in "${FAM_POLICIES[@]}"; do
    if [ ! -f "${policy_file}" ]; then
        print_error "FAM policy file not found: ${policy_file}"
        setup_rerun_hint_print
        exit 1
    fi
done

if [ ! -f "${FAM_CRON_MANIFEST}" ]; then
    print_error "FAM CronJob manifest not found: ${FAM_CRON_MANIFEST}"
    setup_rerun_hint_print
    exit 1
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
    print_error "ROX_API_TOKEN is required. Set it: export ROX_API_TOKEN='your-token'"
    setup_rerun_hint_print
    exit 1
fi

if ! command -v jq &>/dev/null; then
    print_error "jq is required. Install: dnf install jq / brew install jq"
    setup_rerun_hint_print
    exit 1
fi

CENTRAL_URL=$(get_central_url) || {
    print_error "Could not determine ROX_CENTRAL_ADDRESS. Set it or ensure RHACS route exists."
    setup_rerun_hint_print
    exit 1
}

API_BASE="${CENTRAL_URL}/v1"

# Violations are alerts. Check grouped counts via:
#   GET ${CENTRAL_URL}/v1/alerts/summary/groups?query=Policy:"<policy-name>"
# Example host (replace with your route / ROX_CENTRAL_ADDRESS):
#   https://central-stackrox.apps.cluster-7drtp.dynamic.redhatworkshops.io/v1/alerts/summary/groups?query=Policy:%22fam-basic-deploy-monitoring%22
# Response: { "alertsByPolicies": [ { "policy": { "name": "..." }, "numAlerts": "..." } ] }

# Fetch GET /v1/alerts/summary/groups; optional second arg "noquery" skips Policy filter (retry path).
_alerts_summary_groups_body() {
    local policy="$1"
    local mode="${2:-query}"
    local response http_code body
    if [ "${mode}" = "query" ]; then
        local search_q="Policy:\"${policy}\""
        response=$(curl -k -s -w "\n%{http_code}" -G "${API_BASE}/alerts/summary/groups" \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            --data-urlencode "query=${search_q}" 2>/dev/null) || return 1
    else
        response=$(curl -k -s -w "\n%{http_code}" -G "${API_BASE}/alerts/summary/groups" \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" 2>/dev/null) || return 1
    fi
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    printf '%s' "${body}"
}

# Prefer GET /v1/alerts/summary/groups with Policy query; then same URL without query; then alertscount; then list alerts.
alert_count_from_groups() {
    local policy="$1"
    local body=""
    body=$(_alerts_summary_groups_body "${policy}" "query" 2>/dev/null) || body=""
    if [ -z "${body}" ]; then
        body=$(_alerts_summary_groups_body "${policy}" "noquery" 2>/dev/null) || body=""
    fi
    if [ -z "${body}" ]; then
        return 1
    fi
    echo "${body}" | jq -r --arg p "${policy}" '
      ((.alertsByPolicies // .alerts_by_policies // [])
        | map(select(.policy.name == $p))
        | .[0]
        | (.numAlerts // .num_alerts)
      )
      // 0
      | if type == "string" then tonumber else . end
    ' 2>/dev/null || echo "0"
}

alert_count_for_policy() {
    local policy="$1"
    local query="Policy:\"${policy}\""
    local response http_code body
    response=$(curl -k -s -w "\n%{http_code}" -G "${API_BASE}/alertscount" \
        -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        --data-urlencode "query=${query}" 2>/dev/null) || return 1
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    echo "${body}" | jq -r '.count // 0' 2>/dev/null || echo "0"
}

# Fallback: list alerts with Policy search query + pagination cap.
alert_count_fallback_list() {
    local policy="$1"
    local search_q="Policy:\"${policy}\""
    local response http_code body
    response=$(curl -k -s -w "\n%{http_code}" -G "${API_BASE}/alerts" \
        -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        --data-urlencode "query=${search_q}" \
        --data-urlencode "pagination.limit=100" 2>/dev/null) || return 1
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    echo "${body}" | jq -r --arg p "${policy}" '[.alerts[]? | select(.policy.name == $p)] | length' 2>/dev/null || echo "0"
}

fam_violation_count() {
    local policy="$1"
    local c
    c=$(alert_count_from_groups "${policy}" 2>/dev/null | tr -d '\n\r ') || c=""
    if [ -z "${c}" ] || ! [[ "${c}" =~ ^[0-9]+$ ]]; then
        c=$(alert_count_for_policy "${policy}" 2>/dev/null | tr -d '\n\r ') || c=""
    fi
    if [ -z "${c}" ] || ! [[ "${c}" =~ ^[0-9]+$ ]]; then
        c=$(alert_count_fallback_list "${policy}" 2>/dev/null | tr -d '\n\r ') || c="0"
    fi
    echo "${c:-0}"
}

# Backward-compatible alias
fam_deploy_violation_count() { fam_violation_count "$1"; }

pick_worker_node() {
    list_fam_nodes | head -1
}

# Nodes suitable for host FAM demo (prefer workers; fall back to any node on compact clusters).
list_fam_nodes() {
    if ! command -v jq &>/dev/null; then
        local nodes
        nodes=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")
        if echo "${nodes}" | grep -Ev 'control-plane|master' | grep -q .; then
            echo "${nodes}" | grep -Ev 'control-plane|master'
        else
            echo "${nodes}"
        fi
        return 0
    fi
    oc get nodes -o json 2>/dev/null | jq -r '
        [.items | sort_by(.metadata.name)[] | .metadata.name] as $all |
        ([$all[] | select(test("control-plane|(^|[-/])master([-/]|$)"; "i") | not)] |
         if length > 0 then . else $all end) | .[]
    '
}

# Prefer visa-processor-sidecar (privileged); mastercard-processor runs non-root and cannot touch /etc/passwd.
resolve_fam_exec_target() {
    local ns="${FAM_EXEC_NAMESPACE}"
    local candidates=(
        "deployment/visa-processor:visa-processor-sidecar"
        "deployment/visa-processor:visa-processor"
    )
    local entry dep container

    if oc get "${FAM_EXEC_WORKLOAD}" -n "${ns}" &>/dev/null; then
        if oc get "${FAM_EXEC_WORKLOAD}" -n "${ns}" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"${FAM_EXEC_CONTAINER}\")].name}" 2>/dev/null | grep -q .; then
            print_info "FAM deploy target: ${FAM_EXEC_WORKLOAD} -c ${FAM_EXEC_CONTAINER} (ns ${ns})"
            return 0
        fi
        print_warn "Container '${FAM_EXEC_CONTAINER}' not found on ${FAM_EXEC_WORKLOAD}; scanning fallbacks..."
    else
        print_warn "Workload '${FAM_EXEC_WORKLOAD}' not found in ${ns}; scanning fallbacks..."
    fi

    for entry in "${candidates[@]}"; do
        dep="${entry%%:*}"
        container="${entry##*:}"
        if oc get "${dep}" -n "${ns}" &>/dev/null \
            && oc get "${dep}" -n "${ns}" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"${container}\")].name}" 2>/dev/null | grep -q .; then
            FAM_EXEC_WORKLOAD="${dep}"
            FAM_EXEC_CONTAINER="${container}"
            print_info "FAM deploy target (auto): ${FAM_EXEC_WORKLOAD} -c ${FAM_EXEC_CONTAINER} (ns ${ns})"
            return 0
        fi
    done

    print_error "No FAM deploy target found in ${ns}. Deploy demo apps (visa-processor) or set FAM_EXEC_WORKLOAD / FAM_EXEC_CONTAINER."
    return 1
}

trigger_deploy_fam_touch() {
    local rc=0
    print_info "Deploy FAM trigger: oc exec -n ${FAM_EXEC_NAMESPACE} ${FAM_EXEC_WORKLOAD} -c ${FAM_EXEC_CONTAINER} -- touch /etc/passwd"
    if ! oc exec -n "${FAM_EXEC_NAMESPACE}" "${FAM_EXEC_WORKLOAD}" -c "${FAM_EXEC_CONTAINER}" -- touch /etc/passwd; then
        rc=1
        print_warn "Deploy FAM trigger failed (non-root or read-only rootfs). Try a privileged container, e.g.:"
        print_warn "  FAM_EXEC_WORKLOAD=deployment/visa-processor FAM_EXEC_CONTAINER=visa-processor-sidecar ./fam-setup/install.sh"
    else
        print_info "✓ Container touch /etc/passwd succeeded (${FAM_DEPLOY_POLICY_NAME})"
    fi
    return "${rc}"
}

trigger_node_fam_touch() {
    local node timeout_sec output rc=1 tried=0
    timeout_sec="${FAM_NODE_DEBUG_TIMEOUT_SEC:-180}"
    # oc debug creates a pod → RHACS treats chroot/touch as DEPLOYMENT_EVENT, not NODE_EVENT.
    # nsenter into the host init namespace runs touch as a host process (NODE_EVENT).
    local node_cmd='nsenter -t 1 -m -u -i -n -p touch /etc/passwd'

    while IFS= read -r node; do
        [ -z "${node}" ] && continue
        tried=$((tried + 1))
        print_info "Node FAM trigger [${tried}]: oc debug node/${node} -- ${node_cmd} (timeout ${timeout_sec}s)"
        if command -v timeout &>/dev/null; then
            output=$(timeout "${timeout_sec}" oc debug "node/${node}" --quiet -- bash -c "${node_cmd}" 2>&1) && rc=0 || rc=$?
        else
            output=$(oc debug "node/${node}" --quiet -- bash -c "${node_cmd}" 2>&1) && rc=0 || rc=$?
        fi
        if [ "${rc}" -eq 0 ]; then
            print_info "✓ Host touch via nsenter on node/${node} (${FAM_NODE_POLICY_NAME})"
            print_info "  Node FAM alerts appear in the API/notifiers only — not the Violations UI"
            FAM_NODE_NAME="${node}"
            return 0
        fi
        print_warn "Node FAM trigger failed on ${node} (rc=${rc})"
        if [ -n "${output}" ]; then
            echo "${output}" | head -5 | while IFS= read -r line; do print_warn "  ${line}"; done
        fi
    done < <(if [ -n "${FAM_NODE_NAME:-}" ]; then echo "${FAM_NODE_NAME}"; else list_fam_nodes; fi)

    if [ "${tried}" -eq 0 ]; then
        print_warn "No nodes found for node FAM trigger"
    else
        print_warn "Node FAM trigger failed on all ${tried} node(s) — need cluster-admin or nodes/debug permission"
    fi
    return 1
}

wait_for_fam_violations() {
    local _deadline="${FAM_VIOLATION_WAIT_SEC:-420}"
    local _every="${FAM_VIOLATION_POLL_SEC:-15}"
    local _start _now node_retries=0
    local deploy_count=0 node_count=0
    _start=$(date +%s)

    while true; do
        deploy_count=$(fam_violation_count "${FAM_DEPLOY_POLICY_NAME}")
        node_count=$(fam_violation_count "${FAM_NODE_POLICY_NAME}")
        deploy_count=${deploy_count:-0}
        node_count=${node_count:-0}

        if [ "${deploy_count}" -ge 1 ] && [ "${node_count}" -ge 1 ]; then
            print_info "✓ Deploy policy '${FAM_DEPLOY_POLICY_NAME}': numAlerts=${deploy_count}"
            print_info "✓ Node policy '${FAM_NODE_POLICY_NAME}': numAlerts=${node_count}"
            return 0
        fi

        if [ "${node_count}" -lt 1 ] && [ "${node_retries}" -lt 3 ]; then
            node_retries=$((node_retries + 1))
            print_info "  Node alert still 0 — re-triggering host FAM (attempt ${node_retries}/3)..."
            trigger_node_fam_touch && NODE_TRIGGER_OK=1 || true
        fi

        _now=$(date +%s)
        if [ $((_now - _start)) -ge "${_deadline}" ]; then
            break
        fi

        print_info "  Waiting for FAM alerts — deploy=${deploy_count}, node=${node_count}; polling every ${_every}s (max ${_deadline}s)..."
        sleep "${_every}"
    done

    if [ "${deploy_count}" -lt 1 ]; then
        print_warn "No alert yet for '${FAM_DEPLOY_POLICY_NAME}' (count=${deploy_count})"
    fi
    if [ "${node_count}" -lt 1 ]; then
        print_warn "No alert yet for '${FAM_NODE_POLICY_NAME}' (count=${node_count}) — node alerts may take longer; query /v1/alerts API"
    fi

    if [ "${FAM_REQUIRE_VIOLATION:-0}" = "1" ] && [ "${deploy_count}" -lt 1 ]; then
        print_error "FAM_REQUIRE_VIOLATION=1 but deploy policy has no alert."
        setup_rerun_hint_print
        exit 1
    fi
    if [ "${FAM_REQUIRE_NODE_VIOLATION:-0}" = "1" ] && [ "${node_count}" -lt 1 ]; then
        print_error "FAM_REQUIRE_NODE_VIOLATION=1 but node policy has no alert."
        setup_rerun_hint_print
        exit 1
    fi
    return 1
}

#================================================================
# Step 1: Enable file activity monitoring on SecuredCluster
#================================================================
print_step "1. Enabling file activity monitoring on SecuredCluster..."

SC_NAME=$(oc get securedcluster -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${SC_NAME}" ]; then
    print_error "No SecuredCluster found in ${RHACS_NAMESPACE}"
    setup_rerun_hint_print
    exit 1
fi

print_info "Patching SecuredCluster ${SC_NAME}..."
if ! oc patch securedcluster "${SC_NAME}" \
    -n "${RHACS_NAMESPACE}" \
    --type=merge \
    -p '{"spec":{"perNode":{"fileActivityMonitoring":{"mode":"Enabled"}}}}' 2>/dev/null; then
    print_error "Failed to patch SecuredCluster"
    setup_rerun_hint_print
    exit 1
fi

# Verify patch was applied
FAM_MODE=$(oc get securedcluster "${SC_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.perNode.fileActivityMonitoring.mode}' 2>/dev/null || echo "")
if [ "${FAM_MODE}" != "Enabled" ]; then
    print_error "Patch verification failed: fileActivityMonitoring.mode is '${FAM_MODE}', expected 'Enabled'"
    setup_rerun_hint_print
    exit 1
fi
print_info "✓ File activity monitoring enabled (verified)"
echo ""

#================================================================
# Step 2: Submit FAM policies to ACS via API
#================================================================
print_step "2. Submitting file activity monitoring policies to ACS via API..."

for policy_file in "${FAM_POLICIES[@]}"; do
    policy_name=$(jq -r '.policies[0].name' "${policy_file}")
    POLICY_JSON=$(jq '.policies[0] | del(.id, .lastUpdated)' "${policy_file}")

    existing_id=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${API_BASE}/policies" | jq -r --arg name "${policy_name}" '.policies[] | select(.name==$name) | .id' 2>/dev/null || echo "")

    if [ -n "${existing_id}" ]; then
        print_info "Policy '${policy_name}' already exists (id: ${existing_id}), updating..."
        response=$(curl -k -s -w "\n%{http_code}" -X PUT \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$(echo "${POLICY_JSON}" | jq --arg id "${existing_id}" '. + {id: $id}')" \
            "${API_BASE}/policies/${existing_id}" 2>&1)
    else
        print_info "Creating policy '${policy_name}'..."
        response=$(curl -k -s -w "\n%{http_code}" -X POST \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${POLICY_JSON}" \
            "${API_BASE}/policies" 2>&1)
    fi

    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')

    if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
        print_error "Failed to submit policy '${policy_name}' (HTTP ${http_code})"
        print_error "Response: ${body:0:300}"
        setup_rerun_hint_print
        exit 1
    fi
    print_info "✓ ${policy_name} submitted"
done

if [ "${FAM_SKIP_POST_POLICY_SLEEP:-0}" != "1" ]; then
    _sleep="${FAM_POST_POLICY_SLEEP_SEC:-15}"
    print_info "Waiting ${_sleep}s for policy/sensor propagation before FAM triggers..."
    sleep "${_sleep}"
fi
echo ""

# Pick deploy target and node before applying the exec runner.
FAM_NODE_NAME="${FAM_NODE_NAME:-$(pick_worker_node)}"
if [ "${FAM_SKIP_CRONJOB:-0}" != "1" ] || [ "${FAM_SKIP_WORKLOAD_EXEC:-0}" != "1" ]; then
    resolve_fam_exec_target || print_warn "Could not resolve deploy FAM target — ensure visa-processor is deployed in ${FAM_EXEC_NAMESPACE}"
    if [ -n "${FAM_NODE_NAME}" ]; then
        print_info "FAM node target: ${FAM_NODE_NAME}"
    else
        print_warn "Could not resolve node for host FAM — set FAM_NODE_NAME manually"
    fi
fi

#================================================================
# Step 3: Deployment — loop: oc exec into target workload → touch /etc/passwd, then sleep
#================================================================
print_step "3. Applying FAM exec runner Deployment (${FAM_CRON_MANIFEST##*/})..."

if [ "${FAM_SKIP_CRONJOB:-0}" = "1" ]; then
    print_info "Skipping (FAM_SKIP_CRONJOB=1)"
else
    # Remove legacy CronJob from older installs so only the Deployment runs.
    oc delete cronjob rhacs-fam-exec-trigger -n "${FAM_EXEC_NAMESPACE}" --ignore-not-found &>/dev/null || true

    # Rewrite placeholders in the checked-in manifest to match FAM_EXEC_* (defaults: payments / visa-processor-sidecar)
    if ! sed \
        -e "s/namespace: payments/namespace: ${FAM_EXEC_NAMESPACE}/g" \
        -e "s#value: \"deployment/visa-processor\"#value: \"${FAM_EXEC_WORKLOAD}\"#g" \
        -e "s#value: \"visa-processor-sidecar\"#value: \"${FAM_EXEC_CONTAINER}\"#g" \
        -e "s#value: \"payments\"#value: \"${FAM_EXEC_NAMESPACE}\"#g" \
        "${FAM_CRON_MANIFEST}" | oc apply -f -; then
        print_error "Failed to apply FAM exec runner (is namespace ${FAM_EXEC_NAMESPACE} present? image pull ok?)"
        setup_rerun_hint_print
        exit 1
    fi
    oc set env "deployment/rhacs-fam-exec-runner" -n "${FAM_EXEC_NAMESPACE}" \
        "TARGET_WORKLOAD=${FAM_EXEC_WORKLOAD}" \
        "TARGET_CONTAINER=${FAM_EXEC_CONTAINER}" \
        "TARGET_NAMESPACE=${FAM_EXEC_NAMESPACE}" \
        "TARGET_NODE=${FAM_NODE_NAME:-}" \
        --overwrite &>/dev/null || print_warn "Could not patch rhacs-fam-exec-runner env"
    print_info "✓ Runner env: deploy=${FAM_EXEC_WORKLOAD} -c ${FAM_EXEC_CONTAINER}; node=${FAM_NODE_NAME:-unset}"
    if [ -n "${FAM_LOOP_SLEEP_SEC:-}" ]; then
        if oc set env "deployment/rhacs-fam-exec-runner" -n "${FAM_EXEC_NAMESPACE}" \
            "FAM_LOOP_SLEEP_SEC=${FAM_LOOP_SLEEP_SEC}" --overwrite &>/dev/null; then
            print_info "✓ Deployment env FAM_LOOP_SLEEP_SEC=${FAM_LOOP_SLEEP_SEC}"
        fi
    fi
    print_info "✓ Deployment rhacs-fam-exec-runner in ${FAM_EXEC_NAMESPACE} (loop → oc exec ${FAM_EXEC_WORKLOAD} -c ${FAM_EXEC_CONTAINER} → touch /etc/passwd)"

    if [ "${FAM_SKIP_INITIAL_ROLLOUT_WAIT:-0}" != "1" ]; then
        _ijt="${FAM_INITIAL_ROLLOUT_TIMEOUT_SEC:-180}"
        print_info "Waiting for rollout (timeout ${_ijt}s)..."
        if oc rollout status "deployment/rhacs-fam-exec-runner" -n "${FAM_EXEC_NAMESPACE}" --timeout="${_ijt}s" &>/dev/null; then
            print_info "✓ rhacs-fam-exec-runner rollout complete"
        else
            print_warn "Deployment rhacs-fam-exec-runner not ready within ${_ijt}s — check: oc describe deployment/rhacs-fam-exec-runner -n ${FAM_EXEC_NAMESPACE}; oc logs -n ${FAM_EXEC_NAMESPACE} -l app.kubernetes.io/name=rhacs-fam-exec-runner --tail=50"
        fi
    fi
fi
echo ""

#================================================================
# Step 4: Trigger deploy FAM (container) + node FAM (host)
#================================================================
print_step "4. Triggering FAM demo events (container + host)..."

DEPLOY_TRIGGER_OK=0
NODE_TRIGGER_OK=0

if [ "${FAM_SKIP_WORKLOAD_EXEC:-0}" = "1" ]; then
    print_info "Skipping deploy/node triggers (FAM_SKIP_WORKLOAD_EXEC=1)"
else
    print_info "4a. Deploy FAM (${FAM_DEPLOY_POLICY_NAME})..."
    if resolve_fam_exec_target && trigger_deploy_fam_touch; then
        DEPLOY_TRIGGER_OK=1
    fi

    echo ""
    print_info "4b. Node FAM (${FAM_NODE_POLICY_NAME})..."
    if [ "${FAM_SKIP_NODE_TRIGGER:-0}" = "1" ]; then
        print_info "Skipping node trigger (FAM_SKIP_NODE_TRIGGER=1)"
    elif trigger_node_fam_touch; then
        NODE_TRIGGER_OK=1
    fi
fi
echo ""

#================================================================
# Step 5: Verify deploy + node FAM violations via API
#================================================================
print_step "5. Verifying FAM violations (deploy + node policies)..."

if [ "${FAM_SKIP_VIOLATION_WAIT:-0}" = "1" ]; then
    print_info "Skipping (FAM_SKIP_VIOLATION_WAIT=1)"
else
    if wait_for_fam_violations; then
        print_info "  API: GET ${CENTRAL_URL}/v1/alerts/summary/groups?query=Policy:%22${FAM_DEPLOY_POLICY_NAME}%22"
        print_info "  API: GET ${CENTRAL_URL}/v1/alerts/summary/groups?query=Policy:%22${FAM_NODE_POLICY_NAME}%22"
    else
        print_warn "Timed out or missing alerts. Re-run triggers manually:"
        if [ "${DEPLOY_TRIGGER_OK}" != "1" ]; then
            print_warn "  oc exec -n ${FAM_EXEC_NAMESPACE} deployment/visa-processor -c visa-processor-sidecar -- touch /etc/passwd"
        fi
        if [ "${NODE_TRIGGER_OK}" != "1" ]; then
            print_warn "  oc debug node/\$(oc get nodes -o name | grep -v control-plane | head -1 | sed 's|node/||') -- bash -c 'nsenter -t 1 -m -u -i -n -p touch /etc/passwd'"
        fi
        print_warn "  curl -k -G \"${CENTRAL_URL}/v1/alerts/summary/groups\" -H \"Authorization: Bearer \${ROX_API_TOKEN}\" --data-urlencode 'query=Policy:\"${FAM_DEPLOY_POLICY_NAME}\"'"
    fi
fi
echo ""

#================================================================
# Summary
#================================================================
WORKER_NODE=$(pick_worker_node || echo "worker-0")

print_step "File activity monitoring (FAM) setup complete"
echo ""
print_info "Deploy target: ${FAM_EXEC_WORKLOAD} -c ${FAM_EXEC_CONTAINER} (${FAM_EXEC_NAMESPACE})"
print_info "Node target: ${WORKER_NODE} (nsenter via oc debug — alerts in API only, not Violations UI)"
print_info "Deploy policy is scoped to namespace ${FAM_EXEC_NAMESPACE}; openshift-debug is excluded."
print_info "Runner pod re-triggers deploy FAM every FAM_LOOP_SLEEP_SEC (default 600s)."
echo ""
