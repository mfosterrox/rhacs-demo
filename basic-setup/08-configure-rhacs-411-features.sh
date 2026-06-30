#!/bin/bash
# RHACS 4.11 demo configuration — Technology Preview flags, CRS hardening,
# attach policy verification, scheduled vulnerability report, label-scoped policy.
#
# Requires: ROX_API_TOKEN, oc logged in, jq
# Optional: SKIP_RHACS_411_TP_FLAGS=1, SKIP_RHACS_411_CRS=1, SKIP_RHACS_411_REPORT=1

set -euo pipefail

_RHACS_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS:-}"
ATTACH_POLICY_NAME="${ATTACH_POLICY_NAME:-Kubernetes Actions: Attach to Pod}"
LABEL_SCOPE_POLICY_NAME="${LABEL_SCOPE_POLICY_NAME:-demo-411-cluster-label-scope}"
VULN_REPORT_NAME="${VULN_REPORT_NAME:-demo-411-daily-vuln-report}"

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || return 1
}

get_central_cr_name() {
    oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Set Central env vars for 4.11 TP features via deployment patch (idempotent).
configure_central_tp_flags() {
    if [ "${SKIP_RHACS_411_TP_FLAGS:-0}" = "1" ]; then
        print_info "Skipping TP feature flags (SKIP_RHACS_411_TP_FLAGS=1)"
        return 0
    fi

    print_step "Enabling RHACS 4.11 Technology Preview flags on Central..."

    if ! oc get deployment central -n "${RHACS_NAMESPACE}" &>/dev/null; then
        print_warn "Central deployment not found; skipping TP flags"
        return 0
    fi

    local flags=("ROX_INIT_CONTAINER_SUPPORT=true" "ROX_POLICY_FILTERS_UI=enabled")
    local flag
    for flag in "${flags[@]}"; do
        local name="${flag%%=*}"
        local value="${flag#*=}"
        local current
        current=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o json 2>/dev/null | \
            jq -r --arg n "${name}" '.spec.template.spec.containers[0].env[]? | select(.name == $n) | .value' 2>/dev/null | head -1 || echo "")
        if [ "${current}" = "${value}" ]; then
            print_info "✓ Central env ${name}=${value} already set"
            continue
        fi
        if oc set env "deployment/central" -n "${RHACS_NAMESPACE}" "${name}=${value}" &>/dev/null; then
            print_info "✓ Set Central env ${name}=${value}"
        else
            print_warn "Could not set Central env ${name}; operator may reconcile — verify in RHACS UI"
        fi
    done

    oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=300s 2>/dev/null || \
        print_warn "Central rollout may still be in progress after TP flag update"
    return 0
}

api_call() {
    local method="$1"
    local endpoint="$2"
    local token="$3"
    local api_base="$4"
    local data="${5:-}"

    local response http_code body
    if [ -n "${data}" ]; then
        response=$(curl -k -s -w "\n%{http_code}" -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "${data}" \
            "${api_base}/${endpoint}" 2>/dev/null || echo "")
    else
        response=$(curl -k -s -w "\n%{http_code}" -X "${method}" \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            "${api_base}/${endpoint}" 2>/dev/null || echo "")
    fi
    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_warn "API ${method} ${endpoint} returned HTTP ${http_code}"
        echo "${body}" >&2
        return 1
    fi
    echo "${body}"
    return 0
}

configure_crs_hardening() {
    if [ "${SKIP_RHACS_411_CRS:-0}" = "1" ]; then
        print_info "Skipping CRS hardening (SKIP_RHACS_411_CRS=1)"
        return 0
    fi

    print_step "Configuring cluster registration secret (CRS) limits..."

    local token="$1"
    local api_base="$2"
    local config_body patched

    config_body=$(api_call "GET" "config" "${token}" "${api_base}" "") || {
        print_warn "Could not read Central config for CRS settings; skipping"
        return 0
    }

    # Merge CRS limits if the config schema supports them (4.11+).
    patched=$(echo "${config_body}" | jq '
        .config.privateConfig.clusterRegistrationConfig //= {} |
        .config.privateConfig.clusterRegistrationConfig.maxClusters //= 50 |
        .config.privateConfig.clusterRegistrationConfig.maxExpirationDays //= 90
    ' 2>/dev/null) || patched=""

    if [ -z "${patched}" ]; then
        print_warn "Could not build CRS config patch; skipping"
        return 0
    fi

    local payload
    payload=$(echo "${patched}" | jq '{config: .config}' 2>/dev/null) || return 0

    if api_call "PUT" "config" "${token}" "${api_base}" "${payload}" >/dev/null 2>&1; then
        print_info "✓ CRS limits configured (maxClusters=50, maxExpirationDays=90)"
    else
        print_warn "CRS config PUT failed — field names may differ on this Central version; configure via UI if needed"
    fi
    return 0
}

ensure_attach_policy() {
    local token="$1"
    local api_base="$2"
    local enforce="${RHACS_ATTACH_POLICY_ENFORCE:-alert}"

    print_step "Verifying Attach to Pod policy (4.11)..."

    local policies policy_id policy_json
    policies=$(api_call "GET" "policies" "${token}" "${api_base}" "") || return 0

    policy_id=$(echo "${policies}" | jq -r --arg n "${ATTACH_POLICY_NAME}" '.policies[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
    if [ -z "${policy_id}" ] || [ "${policy_id}" = "null" ]; then
        print_warn "Default policy '${ATTACH_POLICY_NAME}' not found; may appear after Central upgrade"
        return 0
    fi

    policy_json=$(echo "${policies}" | jq --arg id "${policy_id}" '.policies[] | select(.id == $id)' 2>/dev/null)
    if [ -z "${policy_json}" ]; then
        return 0
    fi

    if [ "${enforce}" = "enforce" ]; then
        policy_json=$(echo "${policy_json}" | jq '.disabled = false | .enforcementActions = ["UNSATISFIABLE"]' 2>/dev/null)
        if api_call "PUT" "policies/${policy_id}" "${token}" "${api_base}" "${policy_json}" >/dev/null 2>&1; then
            print_info "✓ Attach policy enabled with enforcement"
        else
            print_warn "Could not update Attach policy enforcement"
        fi
    else
        local disabled
        disabled=$(echo "${policy_json}" | jq -r '.disabled' 2>/dev/null)
        if [ "${disabled}" = "true" ]; then
            policy_json=$(echo "${policy_json}" | jq '.disabled = false' 2>/dev/null)
            api_call "PUT" "policies/${policy_id}" "${token}" "${api_base}" "${policy_json}" >/dev/null 2>&1 || true
        fi
        print_info "✓ Attach policy '${ATTACH_POLICY_NAME}' present (alert mode)"
    fi
    return 0
}

create_label_scope_policy() {
    local token="$1"
    local api_base="$2"

    print_step "Creating label-scoped demo policy (4.11)..."

    local policies existing_id
    policies=$(api_call "GET" "policies" "${token}" "${api_base}" "") || return 0
    existing_id=$(echo "${policies}" | jq -r --arg n "${LABEL_SCOPE_POLICY_NAME}" '.policies[]? | select(.name == $n) | .id' 2>/dev/null | head -1)
    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        print_info "✓ Policy '${LABEL_SCOPE_POLICY_NAME}' already exists"
        return 0
    fi

    local cluster_label_key="${RHACS_DEMO_CLUSTER_LABEL_KEY:-environment}"
    local cluster_label_value="${RHACS_DEMO_CLUSTER_LABEL_VALUE:-production}"

    local payload
    payload=$(jq -n \
        --arg name "${LABEL_SCOPE_POLICY_NAME}" \
        --arg ckey "${cluster_label_key}" \
        --arg cval "${cluster_label_value}" \
        '{
          policies: [{
            name: $name,
            description: "Demo policy scoped by cluster and namespace labels (RHACS 4.11)",
            rationale: "Demonstrates expanded policy scope with cluster label selectors.",
            remediation: "Review workloads matching the label scope.",
            disabled: true,
            categories: ["Security Best Practices"],
            lifecycleStages: ["DEPLOY"],
            eventSource: "NOT_APPLICABLE",
            scope: [
              { clusterLabel: { key: $ckey, value: $cval } },
              { namespaceLabel: { key: "kubernetes.io/metadata.name", value: "payments" } }
            ],
            severity: "LOW_SEVERITY",
            enforcementActions: [],
            policyVersion: "1.1",
            policySections: [{
              sectionName: "Rule 1",
              policyGroups: [{
                fieldName: "Image Tag",
                booleanOperator: "OR",
                negate: true,
                values: [{ value: "latest" }]
              }]
            }],
            criteriaLocked: false,
            mitreVectorsLocked: false,
            isDefault: false,
            source: "IMPERATIVE"
          }]
        }')

    if api_call "POST" "policies" "${token}" "${api_base}" "${payload}" >/dev/null 2>&1; then
        print_info "✓ Created disabled demo policy '${LABEL_SCOPE_POLICY_NAME}' (cluster label ${cluster_label_key}=${cluster_label_value})"
    else
        print_warn "Could not create label-scoped policy — scope schema may differ; create manually in UI"
    fi
    return 0
}

create_scheduled_vuln_report() {
    if [ "${SKIP_RHACS_411_REPORT:-0}" = "1" ]; then
        print_info "Skipping scheduled vulnerability report (SKIP_RHACS_411_REPORT=1)"
        return 0
    fi

    print_step "Creating scheduled vulnerability report (4.11)..."

    local token="$1"
    local api_v2="$2"

    local existing
    existing=$(curl -k -s -H "Authorization: Bearer ${token}" "${api_v2}/reports/configurations" 2>/dev/null || echo "")
    if echo "${existing}" | jq -e --arg n "${VULN_REPORT_NAME}" '.reportConfigs[]? | select(.name == $n)' &>/dev/null 2>&1; then
        print_info "✓ Vulnerability report '${VULN_REPORT_NAME}' already exists"
        return 0
    fi

    local payload
    payload=$(jq -n \
        --arg name "${VULN_REPORT_NAME}" \
        '{
          reportConfigs: [{
            name: $name,
            description: "Daily demo report with exact schedule and fixable CVE filter (RHACS 4.11)",
            type: "VULNERABILITY",
            schedule: {
              intervalType: "DAILY",
              hour: 6,
              minute: 30
            },
            vulnReportFilters: {
              fixable: true
            }
          }]
        }')

    local response http_code
    response=$(curl -k -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_v2}/reports/configurations" 2>/dev/null || echo "")
    http_code=$(echo "${response}" | tail -n1)

    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
        print_info "✓ Scheduled vulnerability report '${VULN_REPORT_NAME}' created (daily 06:30, fixable CVEs)"
        return 0
    fi

    print_warn "Scheduled vulnerability report API returned HTTP ${http_code}; configure report in Vulnerability Management UI"
    return 0
}

main() {
    print_info "=========================================="
    print_info "RHACS 4.11 Feature Configuration"
    print_info "=========================================="
    print_info ""

    if ! command -v jq &>/dev/null; then
        print_error "jq is required"
        exit 1
    fi

    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN is required"
        exit 1
    fi

    local central_url api_host api_base api_v2_base
    central_url=$(get_central_url) || {
        print_error "Could not determine Central URL"
        exit 1
    }
    api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    api_base="https://${api_host}/v1"
    api_v2_base="https://${api_host}/v2"

    configure_central_tp_flags

    print_info ""
    configure_crs_hardening "${token}" "${api_base}"

    print_info ""
    ensure_attach_policy "${token}" "${api_base}"

    print_info ""
    create_label_scope_policy "${token}" "${api_base}"

    print_info ""
    create_scheduled_vuln_report "${token}" "${api_v2_base}"

    print_info ""
    print_info "=========================================="
    print_info "RHACS 4.11 Feature Configuration Complete"
    print_info "=========================================="
    print_info "  - TP flags: ROX_INIT_CONTAINER_SUPPORT, ROX_POLICY_FILTERS_UI"
    print_info "  - CRS hardening (if supported by config API)"
    print_info "  - Attach to Pod policy verified"
    print_info "  - Label-scoped demo policy"
    print_info "  - Scheduled vulnerability report (if API available)"
    print_info ""
}

main "$@"
