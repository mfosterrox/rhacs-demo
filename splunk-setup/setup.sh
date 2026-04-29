#!/usr/bin/env bash
#
# Deploy a single-node Splunk Enterprise instance in OpenShift.
#
# Usage:
#   ./setup.sh
#
# Optional environment variables:
#   SPLUNK_NAMESPACE        Namespace to deploy into (default: splunk)
#   SPLUNK_NAME             Base name for deployment resources (default: splunk)
#   SPLUNK_STORAGE_SIZE     PVC size for index data (default: 20Gi)
#   SPLUNK_PASSWORD_DEFAULT Admin password used for every deployment run
#   SPLUNK_RUN_CLEAN_FIRST  Run ./clean.sh before setup (default: true)
#   SPLUNK_IMAGE            Splunk container image (default: splunk/splunk:latest)
#   SPLUNK_ROUTE_TERMINATION Route type: edge|passthrough|reencrypt (default: edge)
#   SPLUNK_INSTALL_RHACS_ADDON  Install RHACS Splunk add-on tarball (default: true)
#   SPLUNK_RHACS_ADDON_FILE     Path to add-on tgz (default: ./red-hat-advanced-cluster-security-splunk-technology-add-on_204.tgz)
#   SPLUNK_RHACS_ADDON_SHA256   Expected SHA256 for add-on package
#   RHACS_SPLUNK_ADDON_TOKEN    Read-scoped RHACS token used by Splunk add-on (preferred)
#   RHACS_SPLUNK_ADDON_INTERVAL Poll interval seconds for add-on inputs (default: 14400)
#   SPLUNK_CONFIGURE_ADDON_INPUTS Configure TA-stackrox inputs via API (default: true)
#   SPLUNK_ADDON_INDEX         Splunk index for add-on pulled data (default: main)
#   SPLUNK_INTEGRATE_WITH_RHACS  Create HEC token + RHACS Splunk notifier via API (default: true)
#   SPLUNK_HEC_SCHEME          HEC URL scheme for RHACS notifier (default: https)
#   ROX_CENTRAL_ADDRESS     RHACS Central URL (required for integration)
#   ROX_API_TOKEN           RHACS API token (preferred for integration)
#   ROX_PASSWORD            RHACS admin password (used to generate API token if needed)
#

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

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        print_error "Required command not found: ${cmd}"
        exit 1
    fi
}

load_env_from_bashrc_if_missing() {
    local var_name="$1"
    if [ -n "${!var_name:-}" ]; then
        return 0
    fi
    if [ ! -f "${HOME}/.bashrc" ]; then
        return 0
    fi

    local raw_line
    raw_line="$(grep -E "^(export[[:space:]]+)?${var_name}=" "${HOME}/.bashrc" 2>/dev/null | tail -n1 || true)"
    if [ -z "${raw_line}" ]; then
        return 0
    fi
    raw_line="${raw_line#export }"
    local value="${raw_line#*=}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    if [ -n "${value}" ]; then
        printf -v "${var_name}" '%s' "${value}"
        export "${var_name}"
    fi
}

verify_sha256() {
    local file_path="$1"
    local expected="$2"
    local actual=""
    if command -v sha256sum >/dev/null 2>&1; then
        actual="$(sha256sum "${file_path}" | awk '{print $1}')"
    elif command -v shasum >/dev/null 2>&1; then
        actual="$(shasum -a 256 "${file_path}" | awk '{print $1}')"
    elif command -v sha256 >/dev/null 2>&1; then
        actual="$(sha256 -q "${file_path}")"
    else
        print_warn "No SHA256 tool found (sha256sum/shasum/sha256). Skipping checksum verification."
        return 0
    fi

    if [ "${actual}" != "${expected}" ]; then
        print_error "SHA256 mismatch for ${file_path}"
        print_error "Expected: ${expected}"
        print_error "Actual:   ${actual}"
        return 1
    fi
    print_info "Checksum verified for $(basename "${file_path}")"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\/&]/\\&/g'
}

generate_password() {
    # 20 chars, includes upper/lower/digit and safe specials for shell/env usage.
    local raw
    raw="$(LC_ALL=C tr -dc 'A-Za-z0-9@#%+=' </dev/urandom | head -c 20)"
    printf 'Rhacs%s1!' "${raw}"
}

generate_api_token_from_password() {
    local central_url="$1"
    local password="$2"
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local response
    response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"splunk-setup-'$(date +%s)'","roles":["Admin"]}' 2>/dev/null)
    local http_code
    http_code="$(echo "${response}" | tail -n1)"
    local body
    body="$(echo "${response}" | sed '$d')"
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    echo "${body}" | jq -r '.token // empty'
}

generate_analyst_api_token() {
    local central_url="$1"
    local admin_token="$2"
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local response
    response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"splunk-addon-analyst-'$(date +%s)'","roles":["Analyst"]}' 2>/dev/null)
    local http_code
    http_code="$(echo "${response}" | tail -n1)"
    local body
    body="$(echo "${response}" | sed '$d')"
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    echo "${body}" | jq -r '.token // empty'
}

to_central_hostport() {
    local central_url="$1"
    local hostport="${central_url#https://}"
    hostport="${hostport#http://}"
    if ! echo "${hostport}" | grep -q ":"; then
        hostport="${hostport}:443"
    fi
    printf '%s' "${hostport}"
}

print_deploy_diagnostics() {
    local namespace="$1"
    local name="$2"
    print_warn "Deployment diagnostics for ${namespace}/${name}:"
    oc -n "${namespace}" get deploy "${name}" -o wide || true
    oc -n "${namespace}" get rs -l "app=${name}" || true
    oc -n "${namespace}" get pods -l "app=${name}" -o wide || true
    # Use grep (not rg) because bastion hosts may not include ripgrep.
    oc -n "${namespace}" get events --sort-by=.lastTimestamp | grep -Ei "${name}|failed|forbidden|scc|denied" || true
    print_warn "If you see SCC/anyuid errors, run:"
    print_warn "  oc adm policy add-scc-to-user anyuid -z ${name}-sa -n ${namespace}"
}

is_splunk_deployment_ready() {
    local namespace="$1"
    local name="$2"
    local available
    available="$(oc -n "${namespace}" get deploy "${name}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [ "${available}" = "1" ]; then
        return 0
    fi
    return 1
}

wait_for_namespace_deleted() {
    local namespace="$1"
    local timeout_sec="${2:-300}"
    local elapsed=0
    local sleep_sec=5

    while oc get namespace "${namespace}" >/dev/null 2>&1; do
        if [ "${elapsed}" -ge "${timeout_sec}" ]; then
            print_error "Timed out waiting for namespace '${namespace}' deletion."
            return 1
        fi
        print_info "Waiting for namespace '${namespace}' deletion... (${elapsed}s/${timeout_sec}s)"
        sleep "${sleep_sec}"
        elapsed=$((elapsed + sleep_sec))
    done
    return 0
}

run_splunk_curl() {
    local namespace="$1"
    local pod="$2"
    shift 2
    # Prefer container curl; fallback to Splunk-bundled curl.
    if oc -n "${namespace}" exec "${pod}" -- sh -c "command -v curl >/dev/null 2>&1"; then
        oc -n "${namespace}" exec "${pod}" -- curl "$@"
    else
        oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl "$@"
    fi
}

# Splunk Enterprise: HEC tokens are HTTP inputs under the splunk_httpinput app.
# Create: POST .../servicesNS/admin/splunk_httpinput/data/inputs/http
# Token value is returned in the POST response .entry[0].content.token (and can be re-fetched with GET).
create_or_get_splunk_hec_token() {
    local namespace="$1"
    local name="$2"
    local splunk_password="$3"
    local hec_name="$4"

    local pod
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ]; then
        print_error "No Splunk pod found in namespace ${namespace}"
        return 1
    fi

    local auth_u="admin:${splunk_password}"

    # Enable HEC globally (splunk_httpinput app).
    run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" -X POST \
        "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http/http?output_mode=json" \
        --data-urlencode "disabled=0" >/dev/null 2>&1 || true

    # Create new HEC token; response includes the generated token.
    local create_body create_code
    create_body="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" -w "\n%{http_code}" -X POST \
        "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http?output_mode=json" \
        --data-urlencode "name=${hec_name}" \
        --data-urlencode "index=main" \
        --data-urlencode "indexes=main" \
        --data-urlencode "sourcetype=stackrox" \
        --data-urlencode "description=RHACS notifier" \
        --data-urlencode "disabled=0" 2>/dev/null || true)"
    create_code="$(echo "${create_body}" | tail -n1)"
    create_body="$(echo "${create_body}" | sed '$d')"

    local token
    token="$(echo "${create_body}" | jq -r '.entry[0].content.token // empty' 2>/dev/null || true)"

    # If input already exists, POST may fail — fetch token via GET on the named input.
    if [ -z "${token}" ]; then
        token="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" \
            "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http/${hec_name}?output_mode=json" 2>/dev/null | \
            jq -r '.entry[0].content.token // empty' 2>/dev/null || true)"
    fi

    # List all HEC inputs (splunk_httpinput) and match by name.
    if [ -z "${token}" ]; then
        token="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" \
            "https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http?output_mode=json&count=0" 2>/dev/null | \
            jq -r --arg n "${hec_name}" '.entry[]? | select(.name==$n) | .content.token' 2>/dev/null | head -n1 || true)"
    fi

    # Fallback: global data/inputs/http (some Splunk builds).
    if [ -z "${token}" ]; then
        token="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "${auth_u}" \
            "https://127.0.0.1:8089/services/data/inputs/http/${hec_name}?output_mode=json" 2>/dev/null | \
            jq -r '.entry[0].content.token // empty' 2>/dev/null || true)"
    fi

    if [ -z "${token}" ]; then
        print_error "Failed to create or read Splunk HEC token '${hec_name}' (create HTTP ${create_code:-n/a})"
        print_warn "Troubleshoot (inside pod):"
        print_warn "  splunk cmd curl -k -u admin:<password> https://127.0.0.1:8089/servicesNS/admin/splunk_httpinput/data/inputs/http?output_mode=json"
        return 1
    fi
    printf '%s' "${token}"
}

install_rhacs_splunk_addon() {
    local namespace="$1"
    local name="$2"
    local splunk_password="$3"

    local do_install="${SPLUNK_INSTALL_RHACS_ADDON:-true}"
    if [ "${do_install}" != "true" ]; then
        print_info "Skipping RHACS Splunk add-on install (SPLUNK_INSTALL_RHACS_ADDON=${do_install})"
        return 0
    fi

    local reinstall="${SPLUNK_REINSTALL_ADDON:-false}"

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local addon_file="${SPLUNK_RHACS_ADDON_FILE:-${script_dir}/red-hat-advanced-cluster-security-splunk-technology-add-on_204.tgz}"
    local addon_sha="${SPLUNK_RHACS_ADDON_SHA256:-62104fae3307184a16c3a92343aa4a4cd4116aa8df86422e89a6915ff7a28461}"
    local addon_name=""

    # Auto-discover common filename variants when explicit file is missing.
    if [ ! -f "${addon_file}" ]; then
        local candidate_tgz="${script_dir}/red-hat-advanced-cluster-security-splunk-technology-add-on_204"
        if [ -f "${candidate_tgz}.tgz" ]; then
            addon_file="${candidate_tgz}.tgz"
        elif [ -f "${candidate_tgz}" ]; then
            addon_file="${candidate_tgz}"
        fi
    fi
    addon_name="$(basename "${addon_file}")"

    if [ ! -f "${addon_file}" ]; then
        print_error "RHACS Splunk add-on package not found at: ${addon_file}"
        print_error "Place the .tgz there or set SPLUNK_RHACS_ADDON_FILE."
        return 1
    fi

    print_step "Verifying RHACS Splunk add-on checksum"
    verify_sha256 "${addon_file}" "${addon_sha}" || return 1

    local pod
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ]; then
        print_error "No Splunk pod found for add-on installation."
        return 1
    fi

    if [ "${reinstall}" != "true" ]; then
        if oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk display app TA-stackrox \
            -uri "https://127.0.0.1:8089" -auth "admin:${splunk_password}" >/dev/null 2>&1; then
            print_info "RHACS Splunk add-on already installed; skipping reinstall."
            return 0
        fi
    fi

    print_step "Copying RHACS Splunk add-on into pod"
    oc -n "${namespace}" cp "${addon_file}" "${pod}:/tmp/${addon_name}"

    print_step "Installing RHACS Splunk add-on package"
    if ! oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk install app "/tmp/${addon_name}" \
        -uri "https://127.0.0.1:8089" \
        -auth "admin:${splunk_password}"; then
        print_error "Failed to install RHACS Splunk add-on package."
        return 1
    fi

    print_step "Restarting Splunk to activate add-on"
    if ! oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk restart \
        -uri "https://127.0.0.1:8089" \
        -auth "admin:${splunk_password}"; then
        print_error "Failed to restart Splunk after add-on install."
        return 1
    fi

    print_step "Waiting for Splunk rollout after add-on install"
    oc -n "${namespace}" rollout status "deployment/${name}" --timeout=10m
    # Verify app is truly installed after restart.
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ] || ! oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk display app TA-stackrox \
        -uri "https://127.0.0.1:8089" -auth "admin:${splunk_password}" >/dev/null 2>&1; then
        print_error "RHACS Splunk add-on is not installed or not visible in Splunk."
        return 1
    fi
    print_info "RHACS Splunk add-on installation completed."
}

configure_rhacs_addon_settings() {
    local namespace="$1"
    local name="$2"
    local splunk_password="$3"

    local rox_central="${ROX_CENTRAL_ADDRESS:-}"
    local rox_token="${ROX_API_TOKEN:-}"
    local addon_token="${RHACS_SPLUNK_ADDON_TOKEN:-}"
    local central_hostport=""

    if [ -z "${rox_central}" ]; then
        print_error "ROX_CENTRAL_ADDRESS not set; cannot configure add-on settings."
        print_error "Set ROX_CENTRAL_ADDRESS (for example: central.example.com:443) and rerun."
        return 1
    fi
    central_hostport="$(to_central_hostport "${rox_central}")"

    # Prefer explicit add-on token; otherwise generate Analyst token from ROX_API_TOKEN.
    if [ -z "${addon_token}" ] && [ -n "${rox_token}" ]; then
        print_step "Generating read-scoped (Analyst) RHACS token for Splunk add-on"
        addon_token="$(generate_analyst_api_token "${rox_central}" "${rox_token}" || true)"
    fi
    if [ -z "${addon_token}" ]; then
        print_error "No add-on token available (set RHACS_SPLUNK_ADDON_TOKEN or ROX_API_TOKEN)."
        print_error "Cannot continue without add-on settings token."
        return 1
    fi

    local pod
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ]; then
        print_error "No Splunk pod found for add-on settings configuration."
        return 1
    fi

    # Skip updating if the configured endpoint already matches.
    local current_endpoint
    current_endpoint="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -u "admin:${splunk_password}" \
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/configs/conf-ta_stackrox_settings/additional_parameters?output_mode=json" 2>/dev/null | \
        jq -r '.entry[0].content.central_endpoint // empty' 2>/dev/null || true)"
    if [ -n "${current_endpoint}" ] && [ "${current_endpoint}" = "${central_hostport}" ] && [ "${SPLUNK_FORCE_ADDON_SETTINGS_UPDATE:-false}" != "true" ]; then
        print_info "RHACS add-on settings already configured for ${central_hostport}; skipping update."
        return 0
    fi

    print_step "Configuring RHACS add-on settings in Splunk"
    # Prefer the TA add-on REST handler endpoint, fallback to conf endpoint.
    local code=""
    local endpoint=""
    local -a endpoints=(
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/TA_stackrox_settings/additional_parameters"
        "https://127.0.0.1:8089/servicesNS/admin/TA-stackrox/TA_stackrox_settings/additional_parameters"
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/ta_stackrox_settings/additional_parameters"
        "https://127.0.0.1:8089/servicesNS/admin/TA-stackrox/ta_stackrox_settings/additional_parameters"
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/configs/conf-ta_stackrox_settings/additional_parameters"
        "https://127.0.0.1:8089/servicesNS/admin/TA-stackrox/configs/conf-ta_stackrox_settings/additional_parameters"
    )

    for endpoint in "${endpoints[@]}"; do
        code="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -o /tmp/stackrox-settings.out -w "%{http_code}" \
            -u "admin:${splunk_password}" \
            -X POST \
            "${endpoint}" \
            --data-urlencode "central_endpoint=${central_hostport}" \
            --data-urlencode "api_token=${addon_token}" 2>/dev/null || true)"
        if echo "${code}" | grep -qE "^(200|201)$"; then
            break
        fi
    done

    if ! echo "${code}" | grep -qE "^(200|201)$"; then
        print_error "Could not configure add-on settings automatically (last endpoint: ${endpoint}, HTTP ${code:-n/a})."
        return 1
    fi

    print_step "Restarting Splunk to apply add-on settings"
    oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk restart \
        -uri "https://127.0.0.1:8089" \
        -auth "admin:${splunk_password}" >/dev/null 2>&1 || true
    oc -n "${namespace}" rollout status "deployment/${name}" --timeout=10m
    print_info "Add-on settings saved (Central Endpoint + API token)."
}

ensure_stackrox_input() {
    local namespace="$1"
    local pod="$2"
    local splunk_password="$3"
    local stanza="$4"
    local interval="$5"
    local index_name="$6"

    local get_code
    get_code="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -o /dev/null -w "%{http_code}" \
        -u "admin:${splunk_password}" \
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/configs/conf-inputs/${stanza}?output_mode=json" 2>/dev/null || true)"

    if echo "${get_code}" | grep -qE "^(200|201)$"; then
        print_info "Add-on input exists: ${stanza}"
        return 0
    fi

    local create_code
    create_code="$(run_splunk_curl "${namespace}" "${pod}" -k -sS -o /tmp/stackrox-input-create.out -w "%{http_code}" \
        -u "admin:${splunk_password}" \
        -X POST \
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/configs/conf-inputs?output_mode=json" \
        --data-urlencode "name=${stanza}" \
        --data-urlencode "index=${index_name}" \
        --data-urlencode "interval=${interval}" \
        --data-urlencode "disabled=0" 2>/dev/null || true)"

    if ! echo "${create_code}" | grep -qE "^(200|201)$"; then
        print_warn "Failed to create add-on input ${stanza} (HTTP ${create_code:-n/a})."
        print_warn "Response: $(cat /tmp/stackrox-input-create.out 2>/dev/null || echo '<empty>')"
        return 1
    fi
    print_info "Created add-on input: ${stanza}"
    return 0
}

configure_rhacs_addon_inputs() {
    local namespace="$1"
    local name="$2"
    local splunk_password="$3"
    local do_inputs="${SPLUNK_CONFIGURE_ADDON_INPUTS:-true}"

    if [ "${do_inputs}" != "true" ]; then
        print_info "Skipping add-on input API configuration (SPLUNK_CONFIGURE_ADDON_INPUTS=${do_inputs})."
        return 0
    fi

    local pod
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ]; then
        print_error "No Splunk pod found for add-on inputs configuration."
        return 1
    fi

    local interval="${RHACS_SPLUNK_ADDON_INTERVAL:-14400}"
    local index_name="${SPLUNK_ADDON_INDEX:-main}"

    print_step "Configuring RHACS Splunk add-on inputs via API"
    ensure_stackrox_input "${namespace}" "${pod}" "${splunk_password}" "stackrox_compliance://rhacs-compliance" "${interval}" "${index_name}"
    ensure_stackrox_input "${namespace}" "${pod}" "${splunk_password}" "stackrox_violations://rhacs-violations" "${interval}" "${index_name}"
    ensure_stackrox_input "${namespace}" "${pod}" "${splunk_password}" "stackrox_vulnerability_management://rhacs-vulnerability-management" "${interval}" "${index_name}"
}

print_rhacs_addon_configuration_steps() {
    local rox_central="${ROX_CENTRAL_ADDRESS:-}"
    local rox_token="${ROX_API_TOKEN:-}"
    local addon_token="${RHACS_SPLUNK_ADDON_TOKEN:-}"
    local interval="${RHACS_SPLUNK_ADDON_INTERVAL:-14400}"
    local central_hostport=""

    if [ -n "${rox_central}" ]; then
        central_hostport="$(to_central_hostport "${rox_central}")"
    fi

    # RH docs recommend a read-scoped token (Analyst role) for the Splunk add-on.
    if [ -z "${addon_token}" ] && [ -n "${rox_central}" ] && [ -n "${rox_token}" ]; then
        print_step "Generating read-scoped (Analyst) RHACS token for Splunk add-on"
        addon_token="$(generate_analyst_api_token "${rox_central}" "${rox_token}" || true)"
    fi

    print_step "RHACS 4.10 doc-aligned Splunk add-on configuration"
    print_info "In Splunk UI: Apps -> Red Hat Advanced Cluster Security for Kubernetes"
    print_info "Then: Configuration -> Add-on Settings"
    if [ -n "${central_hostport}" ]; then
        print_info "  Central Endpoint: ${central_hostport}"
    else
        print_warn "  Central Endpoint: <set ROX_CENTRAL_ADDRESS to auto-populate>"
    fi
    if [ -n "${addon_token}" ]; then
        print_info "  API token (Analyst/read): ${addon_token}"
    else
        print_warn "  API token (Analyst/read): <set RHACS_SPLUNK_ADDON_TOKEN or ROX_* vars>"
    fi
    print_info "Add-on inputs are configured via API by default (can be disabled)."
    print_info "Inputs created: ACS Compliance, ACS Violations, ACS Vulnerability Management."
    print_info "Suggested polling interval: ${interval} seconds"
    print_info "Verification search: index=* sourcetype=\"stackrox-*\""
}

print_final_details() {
    local namespace="$1"
    local name="$2"
    local route_host="$3"
    local password="$4"
    local addon_sha="${SPLUNK_RHACS_ADDON_SHA256:-62104fae3307184a16c3a92343aa4a4cd4116aa8df86422e89a6915ff7a28461}"
    local hec_scheme="${SPLUNK_HEC_SCHEME:-https}"

    echo ""
    print_info "======================================"
    print_info "Splunk setup complete"
    print_info "======================================"
    print_info ""
    print_info "Integration:"
    print_info "  Add-on endpoint : ${name}.${namespace}.svc.cluster.local:443"
    print_info "  HEC endpoint    : ${hec_scheme}://${name}.${namespace}.svc.cluster.local:8088/services/collector/event"
    print_info "  Add-on package  : red-hat-advanced-cluster-security-splunk-technology-add-on_204.tgz"
    print_info "  Add-on SHA256   : ${addon_sha}"
    print_info ""
    print_info "Verify in Splunk:"
    print_info "  index=* sourcetype=\"stackrox-*\""
    print_info ""
    print_info "Cleanup:"
    print_info "  ./clean.sh"
    print_info "  SPLUNK_DELETE_NAMESPACE=true ./clean.sh"
    print_info ""
    print_info "Sign in:"
    print_info "  URL      : https://${route_host}"
    print_info "  Username : admin"
    print_info "  Password : ${password}"
    echo ""
}

integrate_rhacs_with_splunk() {
    local namespace="$1"
    local name="$2"
    local splunk_password="$3"

    local do_integration="${SPLUNK_INTEGRATE_WITH_RHACS:-true}"
    if [ "${do_integration}" != "true" ]; then
        print_info "Skipping RHACS integration (SPLUNK_INTEGRATE_WITH_RHACS=${do_integration})"
        return 0
    fi

    local rox_central="${ROX_CENTRAL_ADDRESS:-}"
    local rox_token="${ROX_API_TOKEN:-}"
    local rox_password="${ROX_PASSWORD:-}"
    local hec_scheme="${SPLUNK_HEC_SCHEME:-https}"
    local splunk_service_url="${hec_scheme}://${name}.${namespace}.svc.cluster.local:8088"
    local hec_name="${SPLUNK_HEC_NAME:-rhacs-hec}"
    local notifier_name="${SPLUNK_NOTIFIER_NAME:-Splunk SIEM (local)}"
    local source_type_alert="${SPLUNK_SOURCE_TYPE_ALERT:-stackrox-alert}"
    local source_type_audit="${SPLUNK_SOURCE_TYPE_AUDIT:-stackrox-audit}"

    if [ -z "${rox_central}" ]; then
        print_warn "ROX_CENTRAL_ADDRESS is not set; skipping RHACS notifier integration."
        return 0
    fi

    if [ -z "${rox_token}" ] && [ -n "${rox_password}" ]; then
        print_step "Generating ROX_API_TOKEN from ROX_PASSWORD for integration"
        rox_token="$(generate_api_token_from_password "${rox_central}" "${rox_password}" || true)"
    fi

    if [ -z "${rox_token}" ]; then
        print_warn "ROX_API_TOKEN is not set and could not be generated; skipping RHACS notifier integration."
        return 0
    fi

    print_step "Creating/reading Splunk HEC token"
    local hec_token
    hec_token="$(create_or_get_splunk_hec_token "${namespace}" "${name}" "${splunk_password}" "${hec_name}")"

    print_step "Creating/updating RHACS Splunk notifier via API"
    local notifiers_json
    notifiers_json="$(curl -k -s \
        -H "Authorization: Bearer ${rox_token}" \
        "${rox_central}/v1/notifiers" 2>/dev/null || true)"

    local notifier_id
    notifier_id="$(echo "${notifiers_json}" | jq -r --arg n "${notifier_name}" '.notifiers[]? | select(.name==$n) | .id' 2>/dev/null || true)"

    local payload
    payload=$(cat <<EOF
{
  "name": "__NOTIFIER_NAME__",
  "uiEndpoint": "__HEC_ENDPOINT__",
  "type": "splunk",
  "splunk": {
    "httpEndpoint": "__HEC_ENDPOINT__/services/collector/event",
    "httpToken": "__HEC_TOKEN__",
    "sourceTypes": {
      "alert": "__SOURCE_TYPE_ALERT__",
      "audit": "__SOURCE_TYPE_AUDIT__"
    },
    "insecure": true,
    "skipTlsVerify": true
  }
}
EOF
)
    payload="$(echo "${payload}" | sed "s/__NOTIFIER_NAME__/$(escape_sed_replacement "${notifier_name}")/g")"
    payload="$(echo "${payload}" | sed "s/__HEC_ENDPOINT__/$(escape_sed_replacement "${splunk_service_url}")/g")"
    payload="$(echo "${payload}" | sed "s/__HEC_TOKEN__/$(escape_sed_replacement "${hec_token}")/g")"
    payload="$(echo "${payload}" | sed "s/__SOURCE_TYPE_ALERT__/$(escape_sed_replacement "${source_type_alert}")/g")"
    payload="$(echo "${payload}" | sed "s/__SOURCE_TYPE_AUDIT__/$(escape_sed_replacement "${source_type_audit}")/g")"

    local code
    if [ -n "${notifier_id}" ]; then
        code="$(curl -k -s -o /tmp/rhacs-splunk-notifier.out -w "%{http_code}" \
            -X PUT "${rox_central}/v1/notifiers/${notifier_id}" \
            -H "Authorization: Bearer ${rox_token}" \
            -H "Content-Type: application/json" \
            --data "${payload}")"
        # RHACS may require credential re-entry for certain Splunk field changes.
        # If update is rejected, recreate notifier to apply endpoint/token together.
        if ! echo "${code}" | grep -qE "^(200|201)$"; then
            local update_err
            update_err="$(cat /tmp/rhacs-splunk-notifier.out 2>/dev/null || true)"
            if echo "${update_err}" | grep -qi "credentials required to update field"; then
                print_warn "Existing notifier cannot be updated in-place; recreating it."
                curl -k -s -o /tmp/rhacs-splunk-notifier-delete.out -w "%{http_code}" \
                    -X DELETE "${rox_central}/v1/notifiers/${notifier_id}" \
                    -H "Authorization: Bearer ${rox_token}" >/dev/null || true
                code="$(curl -k -s -o /tmp/rhacs-splunk-notifier.out -w "%{http_code}" \
                    -X POST "${rox_central}/v1/notifiers" \
                    -H "Authorization: Bearer ${rox_token}" \
                    -H "Content-Type: application/json" \
                    --data "${payload}")"
            fi
        fi
    else
        code="$(curl -k -s -o /tmp/rhacs-splunk-notifier.out -w "%{http_code}" \
            -X POST "${rox_central}/v1/notifiers" \
            -H "Authorization: Bearer ${rox_token}" \
            -H "Content-Type: application/json" \
            --data "${payload}")"
    fi

    if ! echo "${code}" | grep -qE "^(200|201)$"; then
        print_warn "RHACS notifier API call returned HTTP ${code}."
        print_warn "Response: $(cat /tmp/rhacs-splunk-notifier.out 2>/dev/null || echo '<empty>')"
        print_warn "You can still configure this notifier manually in RHACS UI."
        return 0
    fi

    print_info "RHACS Splunk notifier configured: ${notifier_name}"
    print_info "Splunk HEC endpoint: ${splunk_service_url}/services/collector/event"
    print_info "HEC token name in Splunk: ${hec_name}"
}

main() {
    require_cmd oc
    require_cmd curl
    require_cmd jq

    if ! oc whoami >/dev/null 2>&1; then
        print_error "You are not logged in to OpenShift. Run: oc login"
        exit 1
    fi

    local namespace="${SPLUNK_NAMESPACE:-splunk}"
    local name="${SPLUNK_NAME:-splunk}"
    local storage_size="${SPLUNK_STORAGE_SIZE:-20Gi}"
    local image="${SPLUNK_IMAGE:-splunk/splunk:latest}"
    local route_termination="${SPLUNK_ROUTE_TERMINATION:-edge}"
    local password="${SPLUNK_PASSWORD_DEFAULT:-RhacsSplunkDemo123!}"
    local skip_if_ready="${SPLUNK_SKIP_IF_READY:-true}"
    local run_clean_first="${SPLUNK_RUN_CLEAN_FIRST:-true}"

    # Convenience: pick up RHACS API values from ~/.bashrc if user already saved them there.
    load_env_from_bashrc_if_missing "ROX_CENTRAL_ADDRESS"
    load_env_from_bashrc_if_missing "ROX_API_TOKEN"
    load_env_from_bashrc_if_missing "RHACS_SPLUNK_ADDON_TOKEN"
    load_env_from_bashrc_if_missing "ROX_PASSWORD"

    if [ "${run_clean_first}" = "true" ]; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        local clean_script="${script_dir}/clean.sh"
        if [ -x "${clean_script}" ]; then
            print_step "Running clean.sh before setup"
            bash "${clean_script}"
            wait_for_namespace_deleted "${namespace}" 300 || exit 1
            # After clean-and-wait, always perform full deploy path.
            skip_if_ready="false"
        else
            print_warn "SPLUNK_RUN_CLEAN_FIRST=true but clean.sh is missing or not executable: ${clean_script}"
        fi
    fi

    if [ "${skip_if_ready}" = "true" ] && is_splunk_deployment_ready "${namespace}" "${name}"; then
        print_info "Splunk deployment is already ready; skipping base deploy/apply steps."
    else
        print_step "Deploying Splunk in OpenShift namespace '${namespace}'"

        oc get namespace "${namespace}" >/dev/null 2>&1 || oc create namespace "${namespace}"

        print_step "Creating service account and granting SCC (anyuid)"
        oc -n "${namespace}" create serviceaccount "${name}-sa" --dry-run=client -o yaml | oc apply -f -
        if ! oc adm policy add-scc-to-user anyuid -z "${name}-sa" -n "${namespace}" >/dev/null 2>&1; then
            print_warn "Could not grant anyuid SCC automatically (insufficient permissions?)."
            print_warn "If rollout fails with SCC errors, grant it as a cluster admin:"
            print_warn "  oc adm policy add-scc-to-user anyuid -z ${name}-sa -n ${namespace}"
        fi

        print_step "Creating/updating Splunk secret"
        oc -n "${namespace}" create secret generic "${name}-auth" \
            --from-literal=password="${password}" \
            --dry-run=client -o yaml | oc apply -f -

        print_step "Applying PVC, Deployment, Service, and Route"
        cat <<EOF | oc -n "${namespace}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}-var
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${storage_size}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      securityContext:
        runAsUser: 41812
        runAsGroup: 41812
        fsGroup: 41812
      serviceAccountName: ${name}-sa
      containers:
        - name: splunk
          image: ${image}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
              name: web
            - containerPort: 8088
              name: hec
            - containerPort: 8089
              name: mgmt
            - containerPort: 9997
              name: s2s
          env:
            - name: SPLUNK_GENERAL_TERMS
              value: "--accept-sgt-current-at-splunk-com"
            - name: SPLUNK_START_ARGS
              value: "--accept-license"
            - name: SPLUNK_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${name}-auth
                  key: password
          volumeMounts:
            - name: var
              mountPath: /opt/splunk/var
          readinessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 45
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          livenessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 90
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 6
      volumes:
        - name: var
          persistentVolumeClaim:
            claimName: ${name}-var
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
spec:
  selector:
    app: ${name}
  ports:
    - name: web
      port: 8000
      targetPort: web
    - name: hec
      port: 8088
      targetPort: hec
    - name: mgmt
      port: 8089
      targetPort: mgmt
    - name: s2s
      port: 9997
      targetPort: s2s
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${name}-web
spec:
  to:
    kind: Service
    name: ${name}
  port:
    targetPort: web
  tls:
    termination: ${route_termination}
EOF

        print_step "Waiting for Splunk deployment rollout"
        if ! oc -n "${namespace}" rollout status "deployment/${name}" --timeout=10m; then
            print_error "Splunk deployment rollout did not complete."
            print_deploy_diagnostics "${namespace}" "${name}"
            exit 1
        fi
    fi

    local route_host
    route_host="$(oc -n "${namespace}" get route "${name}-web" -o jsonpath='{.spec.host}')"

    print_info "Splunk deployment is ready."
    print_info "Namespace: ${namespace}"
    print_info "Splunk Web URL: https://${route_host}"
    print_info "Username: admin"
    print_info "Password: ${password}"
    echo ""
    print_info "RHACS SIEM tip: use Splunk HEC on port 8088 with a token created in Splunk."
    print_info "If using in-cluster endpoint, use: http://${name}.${namespace}.svc.cluster.local:8088"
    echo ""

    install_rhacs_splunk_addon "${namespace}" "${name}" "${password}"
    configure_rhacs_addon_settings "${namespace}" "${name}" "${password}"
    configure_rhacs_addon_inputs "${namespace}" "${name}" "${password}"
    integrate_rhacs_with_splunk "${namespace}" "${name}" "${password}"
    print_rhacs_addon_configuration_steps
    print_final_details "${namespace}" "${name}" "${route_host}" "${password}"
}

main "$@"
