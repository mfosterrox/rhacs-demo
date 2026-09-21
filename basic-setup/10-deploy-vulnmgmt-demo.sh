#!/bin/bash
# Deploy Module 07 GitOps vulnerability-management workloads and ACS config.
# Always-run (idempotent). Manifests live in demo-applications vulnmgmt/ (not under
# k8s-deployment-manifests/, so other workshops that bulk-apply that tree skip them).
#
# Requires: ROX_API_TOKEN, oc logged in, jq
# Optional: SKIP_VULNMGMT_DEMO=1, DEMO_APPS_DIR
#
# Workloads are not applied by 04-deploy-applications.sh (same pattern as hummingbird-demo).

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VULNMGMT_DIR="${SCRIPT_DIR}/vulnmgmt"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

DEMO_APPS_DIR="${DEMO_APPS_DIR:-${HOME}/demo-applications}"
if { [ -d "${_RHACS_DEMO_ROOT}/../demo-applications/vulnmgmt" ] \
        || [ -d "${_RHACS_DEMO_ROOT}/../demo-applications/k8s-deployment-manifests/vulnmgmt" ]; } \
    && [ "${DEMO_APPS_DIR}" = "${HOME}/demo-applications" ]; then
    DEMO_APPS_DIR="${_RHACS_DEMO_ROOT}/../demo-applications"
fi

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || return 1
}

rox_api() {
    curl -sk -H "Authorization: Bearer ${ROX_API_TOKEN}" "$@"
}

find_vulnmgmt_manifests() {
    local candidates=(
        "${DEMO_APPS_DIR}/vulnmgmt"
        "${HOME}/demo-applications/vulnmgmt"
        "${_RHACS_DEMO_ROOT}/../demo-applications/vulnmgmt"
        "${DEMO_APPS_DIR}/k8s-deployment-manifests/vulnmgmt"
        "${HOME}/demo-applications/k8s-deployment-manifests/vulnmgmt"
        "${_RHACS_DEMO_ROOT}/../demo-applications/k8s-deployment-manifests/vulnmgmt"
    )
    local d
    for d in "${candidates[@]}"; do
        if [ -d "$d" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

wait_ns_ready() {
    local ns="$1"
    local timeout="${2:-180s}"
    if ! oc get namespace "$ns" >/dev/null 2>&1; then
        print_warn "Namespace $ns not found yet"
        return 0
    fi
    if oc get deploy -n "$ns" --no-headers 2>/dev/null | grep -q .; then
        if ! oc wait --for=condition=Available deployment --all -n "$ns" --timeout="$timeout"; then
            print_warn "Some deployments in $ns not ready within $timeout -- continuing"
        else
            print_info "✓ Deployments available in $ns"
        fi
    else
        print_warn "No deployments in $ns yet"
    fi
}

scan_and_watch() {
    local img="$1"
    if ! command -v roxctl >/dev/null 2>&1; then
        print_warn "roxctl missing -- skip scan of $img"
        return 0
    fi
    print_info "Scanning ${REG}/${img}..."
    if ! roxctl image scan --endpoint "${ROX_ENDPOINT}" --token-file <(echo "$ROX_API_TOKEN") \
        --image "${REG}/${img}" --force --insecure-skip-tls-verify -o json >/dev/null 2>&1; then
        print_warn "Scan failed for ${REG}/${img} -- image may not be in the registry yet"
    else
        print_info "✓ Scanned ${img}"
    fi
    local watch_body
    watch_body=$(rox_api "https://${CENTRAL_ROUTE}/v1/watchedimages" -X POST -H 'Content-Type: application/json' \
        -d "{\"name\":\"${REG}/${img}\"}" || true)
    if echo "$watch_body" | jq -e '.normalizedName' >/dev/null 2>&1; then
        print_info "✓ Watched ${img}"
    else
        print_info "Watch ${img}: $(echo "$watch_body" | jq -r '.message // "already watched or pending"')"
    fi
}

create_collection() {
    local json="$1"
    local name
    name=$(echo "$json" | jq -r '.name')
    local body
    body=$(rox_api "https://${CENTRAL_ROUTE}/v1/collections" -X POST -H 'Content-Type: application/json' -d "$json" || true)
    if echo "$body" | jq -e '.collection.name' >/dev/null 2>&1; then
        print_info "✓ Collection $name created"
    else
        print_info "Collection $name: $(echo "$body" | jq -r '.message // "already exists"')"
    fi
}

post_role() {
    local name="$1"
    local payload="$2"
    local body
    body=$(rox_api "https://${CENTRAL_ROUTE}/v1/roles/${name}" -X POST -H 'Content-Type: application/json' -d "$payload" || true)
    if echo "$body" | grep -qiE 'already exists|already present'; then
        print_info "Role $name already exists"
    elif echo "$body" | jq -e '.name' >/dev/null 2>&1; then
        print_info "✓ Role $name created"
    else
        if rox_api "https://${CENTRAL_ROUTE}/v1/roles/${name}" | jq -e '.name' >/dev/null 2>&1; then
            print_info "Role $name already present"
        else
            print_warn "Role $name: $(echo "$body" | jq -r '.message // "unexpected response"' 2>/dev/null || echo "$body")"
        fi
    fi
}

generate_token_if_needed() {
    local var_name="$1"
    local role_name="$2"
    local token_name="$3"
    local current="${!var_name:-}"
    if [ -n "$current" ] && [ "$current" != "null" ]; then
        print_info "$var_name already set (length ${#current}) -- not regenerating"
        return 0
    fi
    local body token
    body=$(rox_api "https://${CENTRAL_ROUTE}/v1/apitokens/generate" -X POST -H 'Content-Type: application/json' \
        -d "{\"name\":\"${token_name}-$(date +%s)\",\"roles\":[\"${role_name}\"]}" || true)
    token=$(echo "$body" | jq -r '.token // empty')
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        print_warn "Failed to generate $var_name for role $role_name: $(echo "$body" | jq -r '.message // "no token"')"
        return 0
    fi
    printf -v "$var_name" '%s' "$token"
    export "$var_name"
    print_info "✓ Generated $var_name (length ${#token})"
}

persist_bashrc() {
    local bashrc="${HOME}/.bashrc"
    touch "$bashrc"
    if grep -q '# rhacs-demo (vulnmgmt)' "$bashrc" 2>/dev/null; then
        sed -i '/# rhacs-demo (vulnmgmt)/,/# rhacs-demo (vulnmgmt) end/d' "$bashrc"
    fi
    {
        echo ""
        echo "# rhacs-demo (vulnmgmt)"
        echo "export REG=\"${REG}\""
        echo "export REG_HOST=\"${REG_HOST}\""
        echo "export IMAGE_REMOTE_SHOP_API=\"${IMAGE_REMOTE_SHOP_API}\""
        echo "export CENTRAL_ROUTE=\"${CENTRAL_ROUTE}\""
        echo "export ROX_ENDPOINT=\"${ROX_ENDPOINT}\""
        if [ -n "${TEAM_A_TOKEN:-}" ]; then
            echo "export TEAM_A_TOKEN=\"${TEAM_A_TOKEN}\""
        fi
        if [ -n "${APPROVER_TOKEN:-}" ]; then
            echo "export APPROVER_TOKEN=\"${APPROVER_TOKEN}\""
        fi
        echo 'rox() { curl -sk -H "Authorization: Bearer ${ROX_API_TOKEN}" "$@"; }'
        echo "export -f rox"
        echo "# rhacs-demo (vulnmgmt) end"
    } >> "$bashrc"
    print_info "✓ Persisted REG, CENTRAL_ROUTE, ROX_ENDPOINT, scoped tokens, and rox() to ~/.bashrc"
}

main() {
    if [ "${SKIP_VULNMGMT_DEMO:-0}" = "1" ]; then
        print_info "Skipping GitOps vulnmgmt demo (SKIP_VULNMGMT_DEMO=1)"
        exit 0
    fi

    print_info "=========================================="
    print_info "GitOps vulnerability-management demo"
    print_info "=========================================="
    print_info ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift"
        setup_rerun_hint_print
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        print_error "jq is required"
        setup_rerun_hint_print
        exit 1
    fi

    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_error "ROX_API_TOKEN is required"
        setup_rerun_hint_print
        exit 1
    fi

    export ROX_CENTRAL_ADDRESS
    ROX_CENTRAL_ADDRESS="$(get_central_url)" || {
        print_error "Could not determine Central URL"
        setup_rerun_hint_print
        exit 1
    }
    export RHACS_NAMESPACE

    # shellcheck disable=SC1091
    source "${VULNMGMT_DIR}/env.sh"
    : "${REG:=quay.io/mfoster}"
    : "${REG_HOST:=quay.io}"
    : "${IMAGE_REMOTE_SHOP_API:=mfoster/shop-api}"
    export REG REG_HOST IMAGE_REMOTE_SHOP_API
    print_info "REG=$REG  CENTRAL_ROUTE=$CENTRAL_ROUTE  ROX_ENDPOINT=$ROX_ENDPOINT"

    print_step "Locating vulnmgmt manifests..."
    local manifests
    if ! manifests=$(find_vulnmgmt_manifests); then
        print_error "vulnmgmt manifests not found in demo-applications (expected vulnmgmt/ at repo root)."
        print_error "Merge the vulnmgmt-shop-images changes to mfosterrox/demo-applications first."
        setup_rerun_hint_print
        exit 1
    fi
    print_info "✓ Manifests: $manifests"

    print_step "Applying vulnmgmt namespaces and workloads..."
    if ! oc apply -f "${manifests}" --recursive; then
        print_warn "Some vulnmgmt resources may have failed to apply"
    else
        print_info "✓ Manifest apply finished"
    fi

    print_step "Waiting for demo workloads (timeout ~180s per namespace)..."
    local pids=()
    local ns
    for ns in demo-dev demo-stage demo-prod demo-platform; do
        wait_ns_ready "$ns" "180s" &
        pids+=($!)
    done
    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" || true
    done

    print_step "Registering shop base images..."
    chmod +x "${VULNMGMT_DIR}/scripts/"*.sh
    if [ -f "${SCRIPT_DIR}/lib/rhacs-base-images.sh" ]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/lib/rhacs-base-images.sh"
        local existing
        existing=$(rox_api "https://${CENTRAL_ROUTE}/v2/baseimages" || echo "{}")
        register_rhacs_base_image_reference "${ROX_API_TOKEN}" "https://${CENTRAL_ROUTE}/v2" \
            "${REG}/base-eap8" ".*" "${existing}" || print_warn "base-eap8 registration reported errors"
        existing=$(rox_api "https://${CENTRAL_ROUTE}/v2/baseimages" || echo "{}")
        register_rhacs_base_image_reference "${ROX_API_TOKEN}" "https://${CENTRAL_ROUTE}/v2" \
            "${REG}/base-ubi9-openjdk" ".*" "${existing}" || print_warn "base-ubi9-openjdk registration reported errors"
    fi
    bash "${VULNMGMT_DIR}/scripts/register-baseimages.sh" || print_warn "register-baseimages.sh reported errors (409 is OK)"

    print_step "Scanning and watching base images..."
    scan_and_watch "base-eap8:1.0"
    scan_and_watch "base-ubi9-openjdk:1.0"

    print_step "Creating collections..."
    create_collection '{"name":"shop-all","description":"All shop deployments","resourceSelectors":[{"rules":[{"fieldName":"Deployment Label","operator":"OR","values":[{"value":"app=shop"}]}]}]}'
    create_collection '{"name":"shop-prod","description":"Shop in production","resourceSelectors":[{"rules":[{"fieldName":"Namespace Label","operator":"OR","values":[{"value":"stage=prod"}]},{"fieldName":"Deployment Label","operator":"OR","values":[{"value":"app=shop"}]}]}]}'
    create_collection '{"name":"team-a-everything","description":"All team-a workloads","resourceSelectors":[{"rules":[{"fieldName":"Namespace Label","operator":"OR","values":[{"value":"team=team-a"}]}]}]}'
    create_collection '{"name":"platform-base-images","description":"Platform base images","resourceSelectors":[{"rules":[{"fieldName":"Namespace","operator":"OR","values":[{"value":"demo-platform"}]}]}]}'

    print_step "Creating access scope team-a-namespaces..."
    local scope_body scope_id
    scope_body=$(rox_api "https://${CENTRAL_ROUTE}/v1/simpleaccessscopes" -X POST -H 'Content-Type: application/json' -d '{
      "name": "team-a-namespaces",
      "description": "Namespaces labeled team=team-a",
      "rules": {
        "namespaceLabelSelectors": [{
          "requirements": [{
            "key": "team", "op": "IN", "values": ["team-a"]
          }]
        }]
      }
    }' || true)
    scope_id=$(echo "$scope_body" | jq -r '.id // .simpleAccessScope.id // empty')
    if [ -z "$scope_id" ]; then
        scope_id=$(rox_api "https://${CENTRAL_ROUTE}/v1/simpleaccessscopes" | \
            jq -r '.accessScopes[]? | select(.name=="team-a-namespaces") | .id' | head -1)
    fi
    if [ -z "$scope_id" ]; then
        print_warn "Could not resolve access scope team-a-namespaces -- demo-team-a-dev role may fail"
    else
        print_info "✓ Access scope team-a-namespaces id=$scope_id"
    fi

    print_step "Creating roles demo-team-a-dev and demo-vuln-approver..."
    if [ -n "$scope_id" ]; then
        post_role "demo-team-a-dev" "{\"name\":\"demo-team-a-dev\",\"permissionSetId\":\"ffffffff-ffff-fff4-f5ff-fffffffffff6\",\"accessScopeId\":\"${scope_id}\"}"
    else
        print_warn "Skipping demo-team-a-dev role (no access scope id)"
    fi
    post_role "demo-vuln-approver" '{"name":"demo-vuln-approver","permissionSetId":"ffffffff-ffff-fff4-f5ff-fffffffffff9","accessScopeId":"ffffffff-ffff-fff4-f5ff-ffffffffffff"}'

    print_step "Ensuring TEAM_A_TOKEN and APPROVER_TOKEN..."
    generate_token_if_needed TEAM_A_TOKEN "demo-team-a-dev" "demo-team-a-dev-token"
    generate_token_if_needed APPROVER_TOKEN "demo-vuln-approver" "demo-vuln-approver-token"

    print_step "Applying SecurityPolicy CRs..."
    local policy_dir="${VULNMGMT_DIR}/acs/policies"
    if [ "${RHACS_NAMESPACE}" != "stackrox" ]; then
        print_info "RHACS namespace is ${RHACS_NAMESPACE} -- applying policies into that namespace"
        local f
        for f in "$policy_dir"/*.yaml; do
            [ -f "$f" ] || continue
            sed "s/namespace: stackrox/namespace: ${RHACS_NAMESPACE}/" "$f" | oc apply -f - \
                || print_warn "Policy apply failed for $f"
        done
    else
        oc apply -f "$policy_dir/" || print_warn "Policy apply reported errors"
    fi

    print_step "Creating and approving VEX exceptions..."
    if ! bash "${VULNMGMT_DIR}/scripts/vex2acs.sh" "${VULNMGMT_DIR}/vex/shop.openvex.json" --approve; then
        print_warn "vex2acs.sh reported errors -- exceptions may already exist"
    fi

    print_step "Verifying Scanner V4 Red Hat layer flag..."
    local flag_json flag_enabled filters_enabled
    flag_json=$(rox_api "https://${CENTRAL_ROUTE}/v1/featureflags" || true)
    flag_enabled=$(echo "$flag_json" | jq -r '.featureFlags[]? | select(.envVar=="ROX_SCANNER_V4_RED_HAT_LAYERS_RED_HAT_VULNS_ONLY") | .enabled' | head -1)
    filters_enabled=$(echo "$flag_json" | jq -r '.featureFlags[]? | select(.envVar=="ROX_POLICY_FILTERS_UI") | .enabled' | head -1)
    print_info "ROX_POLICY_FILTERS_UI enabled=${filters_enabled:-unknown}"
    print_info "ROX_SCANNER_V4_RED_HAT_LAYERS_RED_HAT_VULNS_ONLY enabled=${flag_enabled:-unknown}"
    if [ "$flag_enabled" != "true" ]; then
        print_warn "ROX_SCANNER_V4_RED_HAT_LAYERS_RED_HAT_VULNS_ONLY is not enabled. Re-run 08-configure-rhacs-411-features.sh so D3 counts diverge."
    fi

    persist_bashrc

    print_info ""
    print_info "=========================================="
    print_info "GitOps vulnerability-management demo complete"
    print_info "=========================================="
    print_info "  namespaces: demo-dev demo-stage demo-prod demo-platform"
    print_info "  registry:   ${REG}"
    print_info "  Central:    https://${CENTRAL_ROUTE}"
    print_info "  source ~/.bashrc before Module 07 commands"
    print_info ""
}

main "$@"
