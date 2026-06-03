#!/bin/bash
# Configure Collector ROX_NON_AGGREGATED_NETWORKS on the SecuredCluster CR so RHACS
# treats non-RFC1918 pod/service CIDRs as private networks (network graph visibility).

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

error_handler() {
    print_error "Script failed at line $2 (exit code: $1)"
    setup_rerun_hint_print
    exit "$1"
}
trap 'error_handler $? $LINENO' ERR

RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
COLLECTOR_ROLLOUT_TIMEOUT="${COLLECTOR_ROLLOUT_TIMEOUT:-300}"

ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    print_error "jq is required. Install with: sudo dnf install -y jq"
    return 1
}

# Returns 0 when the CIDR falls within RFC 1918 private ranges.
is_rfc1918_cidr() {
    local cidr="$1"
    local ip="${cidr%%/*}"
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    return 1
}

# Resolve comma-separated CIDR list: ROX_NON_AGGREGATED_NETWORKS override, else auto-detect.
detect_non_aggregated_networks() {
    if [ -n "${ROX_NON_AGGREGATED_NETWORKS:-}" ]; then
        echo "${ROX_NON_AGGREGATED_NETWORKS}"
        return 0
    fi

    local cidrs=() cidr service_cidr
    while IFS= read -r cidr; do
        [ -n "${cidr}" ] && cidrs+=("${cidr}")
    done < <(oc get network.config.openshift.io cluster -o jsonpath='{range .status.clusterNetwork[*]}{.cidr}{"\n"}{end}' 2>/dev/null || true)

    service_cidr=$(oc get network.config.openshift.io cluster -o jsonpath='{.status.serviceNetwork}' 2>/dev/null || true)
    [ -n "${service_cidr}" ] && cidrs+=("${service_cidr}")

    local non_rfc1918=()
    for cidr in "${cidrs[@]}"; do
        if ! is_rfc1918_cidr "${cidr}"; then
            non_rfc1918+=("${cidr}")
        fi
    done

    if [ ${#non_rfc1918[@]} -eq 0 ]; then
        return 1
    fi

    local IFS=','
    echo "${non_rfc1918[*]}"
}

collector_env_value() {
    local ns="$1"
    oc get ds collector -n "${ns}" -o json 2>/dev/null | jq -r '
        .spec.template.spec.containers[]
        | select(.name == "collector")
        | .env[]?
        | select(.name == "ROX_NON_AGGREGATED_NETWORKS")
        | .value
    ' 2>/dev/null | head -1
}

# Merge or create the collector DaemonSet overlay on the SecuredCluster CR.
apply_securedcluster_overlay() {
    local sc_name="$1"
    local ns="$2"
    local networks="$3"
    local env_block

    env_block=$(printf 'name: ROX_NON_AGGREGATED_NETWORKS\nvalue: "%s"' "${networks}")

    oc get securedcluster "${sc_name}" -n "${ns}" -o json | jq \
        --arg networks "${networks}" \
        --arg envblock "${env_block}" \
        '
        def has_rox_patch(patches):
            any(patches[]?; (.path // "" | test("ROX_NON_AGGREGATED"; "i"))
                or (.value // "" | test("ROX_NON_AGGREGATED"; "i")));

        def update_patches(patches):
            if has_rox_patch(patches) then
                patches
                | map(
                    if (.path // "" | test("ROX_NON_AGGREGATED"; "i"))
                        or (.value // "" | test("ROX_NON_AGGREGATED"; "i")) then
                        {
                            path: "spec.template.spec.containers[name:collector].env[name:ROX_NON_AGGREGATED_NETWORKS].value",
                            value: $networks
                        }
                    else .
                    end
                )
            else
                (patches // [])
                + [{
                    path: "spec.template.spec.containers[name:collector].env[-1]",
                    value: $envblock
                }]
            end;

        .spec.overlays = (.spec.overlays // [])
        | if any(.spec.overlays[]?; .kind == "DaemonSet" and .name == "collector") then
            .spec.overlays |= map(
                if .kind == "DaemonSet" and .name == "collector" then
                    .patches = update_patches(.patches // [])
                else .
                end
            )
        else
            .spec.overlays += [{
                apiVersion: "apps/v1",
                kind: "DaemonSet",
                name: "collector",
                patches: [{
                    path: "spec.template.spec.containers[name:collector].env[-1]",
                    value: $envblock
                }]
            }]
        end
        ' | oc apply -f -
}

wait_for_collector_rollout() {
    local ns="$1"
    local timeout="$2"

    print_info "Waiting for collector DaemonSet rollout (timeout ${timeout}s)..."
    if oc rollout status ds/collector -n "${ns}" --timeout="${timeout}s" >/dev/null 2>&1; then
        print_info "✓ Collector DaemonSet rollout complete"
        return 0
    fi

    print_warn "Collector rollout did not complete within ${timeout}s; verify manually:"
    print_warn "  oc rollout status ds/collector -n ${ns}"
    return 0
}

configure_collector_non_aggregated_networks() {
    print_step "Configuring Collector ROX_NON_AGGREGATED_NETWORKS..."

    local sc_name networks current

    sc_name=$(oc get securedcluster -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${sc_name}" ]; then
        print_warn "No SecuredCluster found in ${RHACS_NAMESPACE}; skipping collector network configuration"
        return 0
    fi

    if ! networks=$(detect_non_aggregated_networks); then
        print_info "No non-RFC1918 pod/service CIDRs detected; skipping ROX_NON_AGGREGATED_NETWORKS"
        print_info "Override manually with: export ROX_NON_AGGREGATED_NETWORKS=\"34.228.224.0/24\""
        return 0
    fi

    print_info "SecuredCluster: ${sc_name}"
    print_info "ROX_NON_AGGREGATED_NETWORKS: ${networks}"

    current=$(collector_env_value "${RHACS_NAMESPACE}")
    if [ "${current}" = "${networks}" ]; then
        print_info "✓ Collector already configured with ROX_NON_AGGREGATED_NETWORKS=${networks}"
        return 0
    fi

    if [ -n "${current}" ]; then
        print_info "Updating collector env (current value: ${current})"
    else
        print_info "Adding ROX_NON_AGGREGATED_NETWORKS to collector via SecuredCluster overlay"
    fi

    apply_securedcluster_overlay "${sc_name}" "${RHACS_NAMESPACE}" "${networks}"
    wait_for_collector_rollout "${RHACS_NAMESPACE}" "${COLLECTOR_ROLLOUT_TIMEOUT}"

    current=$(collector_env_value "${RHACS_NAMESPACE}")
    if [ "${current}" = "${networks}" ]; then
        print_info "✓ ROX_NON_AGGREGATED_NETWORKS verified on collector DaemonSet"
    else
        print_warn "Collector env not yet showing expected value (got: '${current:-<unset>}')"
        print_warn "The operator may still be reconciling; re-run this script if network graph data is missing"
    fi
}

main() {
    print_info "=========================================="
    print_info "Collector Network Configuration"
    print_info "=========================================="
    print_info ""

    if [ "${SKIP_COLLECTOR_NETWORK_CONFIG:-0}" = "1" ]; then
        print_info "SKIP_COLLECTOR_NETWORK_CONFIG=1 — skipping"
        return 0
    fi

    if ! oc whoami &>/dev/null; then
        print_error "Cannot connect to OpenShift cluster"
        exit 1
    fi

    ensure_jq
    configure_collector_non_aggregated_networks

    print_info ""
    print_info "=========================================="
    print_info "Collector Network Configuration Complete"
    print_info "=========================================="
}

main "$@"
