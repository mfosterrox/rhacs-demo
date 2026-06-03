#!/bin/bash
# Configure Collector ROX_NON_AGGREGATED_NETWORKS on the SecuredCluster CR so RHACS
# treats non-RFC1918 pod/service CIDRs as private networks (network graph visibility).
#
# See KCS: network graph shows external entities when pod/service subnets are not RFC 1918.

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
SECURED_CLUSTER_NAME="${SECURED_CLUSTER_NAME:-}"
COLLECTOR_ROLLOUT_TIMEOUT="${COLLECTOR_ROLLOUT_TIMEOUT:-300}"

ensure_jq() {
    command -v jq >/dev/null 2>&1 || {
        print_error "jq is required. Install with: sudo dnf install -y jq"
        return 1
    }
}

# Returns 0 when the address is in a standard RFC 1918 private range (10/8, 172.16-31/12, 192.168/16).
is_standard_private_ip() {
    local ip="$1"
    [[ "${ip}" =~ ^10\. ]] && return 0
    [[ "${ip}" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] && return 0
    [[ "${ip}" =~ ^192\.168\. ]] && return 0
    return 1
}

is_standard_private_cidr() {
    is_standard_private_ip "${1%%/*}"
}

# Collect IPv4 addresses from pods, services, and nodes; merge with network.config CIDRs;
# aggregate non-standard (pseudo-private) ranges such as 172.231.0.0/16.
detect_non_aggregated_networks() {
    if [ -n "${ROX_NON_AGGREGATED_NETWORKS:-}" ]; then
        echo "${ROX_NON_AGGREGATED_NETWORKS}"
        return 0
    fi

    local net_json pod_ips svc_ips node_ips result

    net_json=$(oc get network.config.openshift.io cluster -o json 2>/dev/null || echo "{}")
    pod_ips=$(oc get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}' 2>/dev/null \
        | grep -E '^([0-9]+\.){3}[0-9]+$' | sort -u || true)
    svc_ips=$(oc get svc -A -o jsonpath='{range .items[*]}{.spec.clusterIP}{"\n"}{end}' 2>/dev/null \
        | grep -E '^([0-9]+\.){3}[0-9]+$' | sort -u || true)
    node_ips=$(oc get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{"\n"}{end}{end}' 2>/dev/null \
        | grep -E '^([0-9]+\.){3}[0-9]+$' | sort -u || true)

    result=$(NET_JSON="${net_json}" POD_IPS="${pod_ips}" SVC_IPS="${svc_ips}" NODE_IPS="${node_ips}" python3 <<'PY'
import ipaddress
import json
import os
from collections import defaultdict

def is_standard_private(ip_str: str) -> bool:
    """True for RFC 1918 ranges RHACS already treats as internal."""
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return True
    if ip.version != 4:
        return True
    octets = ip_str.split(".")
    if octets[0] == "10":
        return True
    if octets[0] == "192" and octets[1] == "168":
        return True
    if octets[0] == "172" and 16 <= int(octets[1]) <= 31:
        return True
    return False

def normalize_cidr_values(value) -> list[str]:
    """serviceNetwork may be a string or a list depending on OpenShift version."""
    if not value:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        out = []
        for item in value:
            if isinstance(item, str):
                out.append(item)
            elif isinstance(item, dict) and item.get("cidr"):
                out.append(item["cidr"])
        return out
    return []

def configured_cidrs(net: dict) -> list[str]:
    cidrs: list[str] = []
    for block in ("spec", "status"):
        data = net.get(block, {})
        for entry in data.get("clusterNetwork") or []:
            if c := entry.get("cidr"):
                cidrs.append(c)
        for c in normalize_cidr_values(data.get("serviceNetwork")):
            cidrs.append(c)
        for entry in data.get("machineNetwork") or []:
            if c := entry.get("cidr"):
                cidrs.append(c)
    # Preserve order, drop duplicates
    seen: set[str] = set()
    unique: list[str] = []
    for c in cidrs:
        if c not in seen:
            seen.add(c)
            unique.append(c)
    return unique

def host_prefix_for_ip(net: dict, ip_str: str):
    for block in ("spec", "status"):
        for entry in net.get(block, {}).get("clusterNetwork") or []:
            cidr = entry.get("cidr")
            if not cidr:
                continue
            try:
                network = ipaddress.ip_network(cidr, strict=False)
                if ipaddress.ip_address(ip_str) in network:
                    return int(entry.get("hostPrefix") or network.prefixlen)
            except ValueError:
                continue
    return None

def aggregate_observed_ips(ips: list[str], net: dict) -> set[str]:
    """Group pseudo-private workload/node IPs into covering prefixes (/16 by default)."""
    by_slash16: dict[str, list[str]] = defaultdict(list)
    result: set[str] = set()

    for ip_str in ips:
        if not ip_str or ip_str == "None" or is_standard_private(ip_str):
            continue
        prefix = host_prefix_for_ip(net, ip_str)
        if prefix is not None:
            try:
                net_addr = ipaddress.ip_network(f"{ip_str}/{prefix}", strict=False)
                result.add(str(net_addr))
                continue
            except ValueError:
                pass
        parts = ip_str.split(".")
        if len(parts) == 4:
            by_slash16[f"{parts[0]}.{parts[1]}"].append(ip_str)

    for key, group in by_slash16.items():
        a, b = key.split(".")
        # One or more non-RFC1918 addresses in the same /16 → cover the whole /16
        # (e.g. 172.231.x.x pseudo-private ranges used on RHDP/cloud clusters).
        result.add(f"{a}.{b}.0.0/16")

    return result

net = json.loads(os.environ.get("NET_JSON") or "{}")
pod_ips = [x for x in os.environ.get("POD_IPS", "").splitlines() if x.strip()]
svc_ips = [x for x in os.environ.get("SVC_IPS", "").splitlines() if x.strip()]
node_ips = [x for x in os.environ.get("NODE_IPS", "").splitlines() if x.strip()]

cidrs: set[str] = set()

# 1. Non-standard CIDRs declared in OpenShift network.config
for cidr in configured_cidrs(net):
    if not is_standard_private(cidr.split("/")[0]):
        try:
            cidrs.add(str(ipaddress.ip_network(cidr, strict=False)))
        except ValueError:
            cidrs.add(cidr)

# 2. Aggregate live pod, service, and node InternalIP addresses
observed = aggregate_observed_ips(pod_ips + svc_ips + node_ips, net)
cidrs.update(observed)

if not cidrs:
    raise SystemExit(1)

print(",".join(sorted(cidrs, key=lambda c: ipaddress.ip_network(c, strict=False))))
PY
) || return 1

    echo "${result}"
}

securedcluster_name() {
    if [ -n "${SECURED_CLUSTER_NAME}" ]; then
        echo "${SECURED_CLUSTER_NAME}"
        return 0
    fi
    oc get securedcluster -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
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

securedcluster_has_rox_overlay() {
    local sc_name="$1"
    local ns="$2"
    oc get securedcluster "${sc_name}" -n "${ns}" -o json 2>/dev/null | jq -e '
        .spec.overlays[]?
        | select(.kind == "DaemonSet" and .name == "collector")
        | .patches[]?
        | select(
            (.path // "" | test("ROX_NON_AGGREGATED"; "i"))
            or (.value // "" | test("ROX_NON_AGGREGATED"; "i"))
        )
    ' >/dev/null 2>&1
}

# Patch spec.overlays on the SecuredCluster CR (operator-managed installs).
apply_securedcluster_overlay() {
    local sc_name="$1"
    local ns="$2"
    local networks="$3"
    local ds_has_env patch_path patch_value env_block existing_overlays new_overlays

    ds_has_env=$(collector_env_value "${ns}")
    if [ -n "${ds_has_env}" ]; then
        patch_path="spec.template.spec.containers[name:collector].env[name:ROX_NON_AGGREGATED_NETWORKS].value"
        patch_value="${networks}"
    else
        patch_path="spec.template.spec.containers[name:collector].env[-1]"
        env_block=$(printf 'name: ROX_NON_AGGREGATED_NETWORKS\nvalue: "%s"' "${networks}")
        patch_value="${env_block}"
    fi

    existing_overlays=$(oc get securedcluster "${sc_name}" -n "${ns}" -o json | jq '.spec.overlays // []')

    new_overlays=$(echo "${existing_overlays}" | jq \
        --arg path "${patch_path}" \
        --arg value "${patch_value}" \
        '
        def collector_patch:
            {path: $path, value: $value};
        if any(.[]; .kind == "DaemonSet" and .name == "collector") then
            map(
                if .kind == "DaemonSet" and .name == "collector" then
                    .patches = [collector_patch]
                else .
                end
            )
        else
            . + [{
                apiVersion: "apps/v1",
                kind: "DaemonSet",
                name: "collector",
                patches: [collector_patch]
            }]
        end
        ')

    print_info "Patching SecuredCluster/${sc_name} spec.overlays..."
    oc patch "securedcluster/${sc_name}" -n "${ns}" --type=merge \
        -p "$(jq -n --argjson overlays "${new_overlays}" '{spec: {overlays: $overlays}}')"
}

wait_for_collector_rollout() {
    local ns="$1"
    local timeout="$2"

    print_info "Restarting collector to pick up ROX_NON_AGGREGATED_NETWORKS..."
    oc rollout restart "ds/collector" -n "${ns}" >/dev/null 2>&1 || true

    print_info "Waiting for collector DaemonSet rollout (timeout ${timeout}s)..."
    if oc rollout status "ds/collector" -n "${ns}" --timeout="${timeout}s" >/dev/null 2>&1; then
        print_info "✓ Collector DaemonSet rollout complete"
        return 0
    fi

    print_warn "Collector rollout did not complete within ${timeout}s"
    return 1
}

print_network_diagnostics() {
    local ns="${RHACS_NAMESPACE}"
    print_step "Network diagnostics"

    print_info "network.config.openshift.io/cluster:"
    oc get network.config.openshift.io cluster -o json 2>/dev/null | jq -r '
        "  clusterNetwork (spec): \(.spec.clusterNetwork // [] | map(.cidr) | join(", "))",
        "  serviceNetwork (spec): \(.spec.serviceNetwork // "n/a" | if type == "array" then map(if type == "string" then . else .cidr end) | join(", ") else . end)",
        "  machineNetwork (spec): \(.spec.machineNetwork // [] | map(.cidr) | join(", "))",
        "  clusterNetwork (status): \(.status.clusterNetwork // [] | map(.cidr) | join(", "))",
        "  serviceNetwork (status): \(.status.serviceNetwork // "n/a" | if type == "array" then map(if type == "string" then . else .cidr end) | join(", ") else . end)"
    ' 2>/dev/null || print_warn "  Could not read network.config"

    local sample_pods sample_svcs sample_nodes
    sample_pods=$(oc get pods -A -o jsonpath='{range .items[*]}{.status.podIP}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]+\.){3}[0-9]+$' | sort -u | head -5 | tr '\n' ' ' || true)
    sample_svcs=$(oc get svc -A -o jsonpath='{range .items[*]}{.spec.clusterIP}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]+\.){3}[0-9]+$' | sort -u | head -5 | tr '\n' ' ' || true)
    sample_nodes=$(oc get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="InternalIP")]}{.address}{" "}{end}{end}' 2>/dev/null | tr ' ' '\n' | grep -E '^([0-9]+\.){3}[0-9]+$' | sort -u | head -5 | tr '\n' ' ' || true)
    print_info "Sample pod IPs: ${sample_pods:-<none>}"
    print_info "Sample service ClusterIPs: ${sample_svcs:-<none>}"
    print_info "Sample node InternalIPs: ${sample_nodes:-<none>}"

    local sc_name env_val
    sc_name=$(securedcluster_name)
    if [ -n "${sc_name}" ]; then
        if securedcluster_has_rox_overlay "${sc_name}" "${ns}"; then
            print_info "SecuredCluster/${sc_name}: collector overlay for ROX_NON_AGGREGATED_NETWORKS present"
        else
            print_warn "SecuredCluster/${sc_name}: no ROX_NON_AGGREGATED_NETWORKS overlay in spec.overlays"
        fi
    fi

    env_val=$(collector_env_value "${ns}")
    if [ -n "${env_val}" ]; then
        print_info "collector DaemonSet env ROX_NON_AGGREGATED_NETWORKS=${env_val}"
    else
        print_warn "collector DaemonSet env ROX_NON_AGGREGATED_NETWORKS is not set"
    fi
    echo ""
}

configure_collector_non_aggregated_networks() {
    print_step "Configuring Collector ROX_NON_AGGREGATED_NETWORKS..."

    local sc_name networks current

    sc_name=$(securedcluster_name)
    if [ -z "${sc_name}" ]; then
        print_warn "No SecuredCluster found in ${RHACS_NAMESPACE}; skipping collector network configuration"
        return 0
    fi

    if ! networks=$(detect_non_aggregated_networks); then
        print_warn "No pseudo-private (non-RFC1918) CIDRs detected from cluster config or live IPs"
        print_warn "If network flows still show as external, set CIDRs explicitly and re-run:"
        print_warn "  export ROX_NON_AGGREGATED_NETWORKS=\"172.231.0.0/16\""
        print_warn "  bash basic-setup/02-configure-collector-networks.sh"
        print_network_diagnostics
        return 0
    fi

    print_info "SecuredCluster: ${sc_name}"
    print_info "ROX_NON_AGGREGATED_NETWORKS: ${networks}"

    current=$(collector_env_value "${RHACS_NAMESPACE}")
    if [ "${current}" = "${networks}" ]; then
        print_info "✓ Collector already configured with ROX_NON_AGGREGATED_NETWORKS=${networks}"
        return 0
    fi

    if securedcluster_has_rox_overlay "${sc_name}" "${RHACS_NAMESPACE}" && [ -z "${current}" ]; then
        print_warn "SecuredCluster overlay exists but collector env is unset — re-applying overlay"
    elif [ -n "${current}" ] && [ "${current}" != "${networks}" ]; then
        print_info "Updating collector env (current value: ${current})"
    elif [ -z "${current}" ]; then
        print_info "Adding ROX_NON_AGGREGATED_NETWORKS to collector via SecuredCluster overlay"
    fi

    apply_securedcluster_overlay "${sc_name}" "${RHACS_NAMESPACE}" "${networks}"

    if ! securedcluster_has_rox_overlay "${sc_name}" "${RHACS_NAMESPACE}"; then
        print_error "SecuredCluster overlay was not applied — check RHACS Operator logs"
        print_network_diagnostics
        return 1
    fi

    wait_for_collector_rollout "${RHACS_NAMESPACE}" "${COLLECTOR_ROLLOUT_TIMEOUT}" || true

    current=$(collector_env_value "${RHACS_NAMESPACE}")
    if [ "${current}" = "${networks}" ]; then
        print_info "✓ ROX_NON_AGGREGATED_NETWORKS verified on collector DaemonSet"
    else
        print_error "Collector env not set after patch (got: '${current:-<unset>}')"
        print_error "Check: oc get securedcluster ${sc_name} -n ${RHACS_NAMESPACE} -o yaml | grep -A5 overlays"
        print_error "Check: oc get ds collector -n ${RHACS_NAMESPACE} -o yaml | grep -A2 ROX_NON_AGGREGATED"
        print_error "Check RHACS Operator logs: oc logs -n rhacs-operator -l app.kubernetes.io/name=rhacs-operator --tail=100"
        print_network_diagnostics
        return 1
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
    print_network_diagnostics

    print_info "=========================================="
    print_info "Collector Network Configuration Complete"
    print_info "=========================================="
    print_info ""
    print_info "Network graph data may take several minutes to refresh after collector restart."
}

main "$@"
