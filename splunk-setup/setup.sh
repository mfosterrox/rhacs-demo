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
#   SPLUNK_IMAGE            Splunk container image (default: splunk/splunk:latest)
#   SPLUNK_ROUTE_TERMINATION Route type: edge|passthrough|reencrypt (default: edge)
#   SPLUNK_INSTALL_RHACS_ADDON  Install RHACS Splunk add-on tarball (default: true)
#   SPLUNK_RHACS_ADDON_FILE     Path to add-on tgz (default: ./red-hat-advanced-cluster-security-splunk-technology-add-on_204.tgz)
#   SPLUNK_RHACS_ADDON_SHA256   Expected SHA256 for add-on package
#   RHACS_SPLUNK_ADDON_TOKEN    Read-scoped RHACS token used by Splunk add-on (preferred)
#   RHACS_SPLUNK_ADDON_INTERVAL Poll interval seconds for add-on inputs (default: 14400)
#   SPLUNK_INTEGRATE_WITH_RHACS  Create RHACS notifier via API (default: true)
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

    # Enable HEC globally via management REST API.
    oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl -k -s \
        -u "admin:${splunk_password}" \
        -X POST \
        "https://127.0.0.1:8089/services/data/inputs/http/http" \
        -d "disabled=0" >/dev/null 2>&1 || true

    # Create/update HEC input via management REST API.
    # If it already exists, Splunk returns an error; that's fine for idempotency.
    oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl -k -s \
        -u "admin:${splunk_password}" \
        -X POST \
        "https://127.0.0.1:8089/services/data/inputs/http" \
        -d "name=${hec_name}" \
        -d "description=RHACS notifier token" \
        -d "index=main" \
        -d "sourcetype=stackrox" \
        -d "disabled=0" >/dev/null 2>&1 || true

    # Read token value from Splunk REST API (JSON output is the most stable format).
    local token
    token="$(oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl -k -s \
        -u "admin:${splunk_password}" \
        "https://127.0.0.1:8089/services/data/inputs/http/${hec_name}?output_mode=json" 2>/dev/null | \
        jq -r '.entry[0].content.token // empty' 2>/dev/null || true)"

    # Fallback: list all HEC inputs and match by name.
    if [ -z "${token}" ]; then
        token="$(oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl -k -s \
            -u "admin:${splunk_password}" \
            "https://127.0.0.1:8089/services/data/inputs/http?output_mode=json&count=0" 2>/dev/null | \
            jq -r --arg n "${hec_name}" '.entry[]? | select(.name==$n) | .content.token' 2>/dev/null | head -n1 || true)"
    fi

    if [ -z "${token}" ]; then
        # Last fallback: parse token from CLI list output.
        token="$(oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk http-event-collector list \
            -uri "https://127.0.0.1:8089" \
            -auth "admin:${splunk_password}" 2>/dev/null | \
            awk -v n="${hec_name}" '
                $0 ~ "name:" && $0 ~ n {seen=1}
                seen && $0 ~ "token:" {print $2; exit}
            ' || true)"
    fi

    if [ -z "${token}" ]; then
        print_error "Failed to discover Splunk HEC token '${hec_name}'"
        print_warn "Troubleshoot with:"
        print_warn "  oc -n ${namespace} exec ${pod} -- /opt/splunk/bin/splunk http-event-collector list -uri https://127.0.0.1:8089 -auth admin:<password>"
        print_warn "  oc -n ${namespace} exec ${pod} -- /opt/splunk/bin/splunk cmd curl -k -u admin:<password> https://127.0.0.1:8089/services/data/inputs/http?output_mode=json"
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
        print_warn "RHACS Splunk add-on package not found at: ${addon_file}"
        print_warn "Place the .tgz there or set SPLUNK_RHACS_ADDON_FILE. Skipping add-on install."
        return 0
    fi

    print_step "Verifying RHACS Splunk add-on checksum"
    verify_sha256 "${addon_file}" "${addon_sha}" || return 1

    local pod
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ]; then
        print_error "No Splunk pod found for add-on installation."
        return 1
    fi

    print_step "Copying RHACS Splunk add-on into pod"
    oc -n "${namespace}" cp "${addon_file}" "${pod}:/tmp/${addon_name}"

    print_step "Installing RHACS Splunk add-on package"
    oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk install app "/tmp/${addon_name}" \
        -uri "https://127.0.0.1:8089" \
        -auth "admin:${splunk_password}" >/dev/null 2>&1 || true

    print_step "Restarting Splunk to activate add-on"
    oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk restart \
        -uri "https://127.0.0.1:8089" \
        -auth "admin:${splunk_password}" >/dev/null 2>&1 || true

    print_step "Waiting for Splunk rollout after add-on install"
    oc -n "${namespace}" rollout status "deployment/${name}" --timeout=10m
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
        print_warn "ROX_CENTRAL_ADDRESS not set; skipping add-on settings automation."
        print_warn "Set ROX_CENTRAL_ADDRESS (for example: central.example.com:443) and rerun."
        return 0
    fi
    central_hostport="$(to_central_hostport "${rox_central}")"

    # Prefer explicit add-on token; otherwise generate Analyst token from ROX_API_TOKEN.
    if [ -z "${addon_token}" ] && [ -n "${rox_token}" ]; then
        print_step "Generating read-scoped (Analyst) RHACS token for Splunk add-on"
        addon_token="$(generate_analyst_api_token "${rox_central}" "${rox_token}" || true)"
    fi
    if [ -z "${addon_token}" ]; then
        print_warn "No add-on token available (set RHACS_SPLUNK_ADDON_TOKEN or ROX_API_TOKEN)."
        print_warn "Skipping automatic Add-on Settings configuration."
        return 0
    fi

    local pod
    pod="$(oc -n "${namespace}" get pods -l "app=${name}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [ -z "${pod}" ]; then
        print_error "No Splunk pod found for add-on settings configuration."
        return 1
    fi

    print_step "Configuring RHACS add-on settings in Splunk"
    # Use Splunk management API instead of filesystem writes (works with restricted container permissions).
    # 1) Try to update existing stanza.
    local settings_code
    settings_code="$(oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl -k -s -o /tmp/stackrox-settings.out -w "%{http_code}" \
        -u "admin:${splunk_password}" \
        -X POST \
        "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/configs/conf-ta_stackrox_settings/additional_parameters" \
        -d "central_endpoint=${central_hostport}" \
        -d "api_token=${addon_token}" 2>/dev/null || true)"

    # 2) If stanza does not exist yet, create it.
    if ! echo "${settings_code}" | grep -qE "^(200|201)$"; then
        settings_code="$(oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk cmd curl -k -s -o /tmp/stackrox-settings.out -w "%{http_code}" \
            -u "admin:${splunk_password}" \
            -X POST \
            "https://127.0.0.1:8089/servicesNS/nobody/TA-stackrox/configs/conf-ta_stackrox_settings" \
            -d "name=additional_parameters" \
            -d "central_endpoint=${central_hostport}" \
            -d "api_token=${addon_token}" 2>/dev/null || true)"
    fi

    if ! echo "${settings_code}" | grep -qE "^(200|201)$"; then
        print_warn "Could not configure add-on settings automatically (HTTP ${settings_code})."
        print_warn "Proceed in Splunk UI: Configuration -> Add-on Settings."
        return 0
    fi

    print_step "Restarting Splunk to apply add-on settings"
    oc -n "${namespace}" exec "${pod}" -- /opt/splunk/bin/splunk restart \
        -uri "https://127.0.0.1:8089" \
        -auth "admin:${splunk_password}" >/dev/null 2>&1 || true
    oc -n "${namespace}" rollout status "deployment/${name}" --timeout=10m
    print_info "Add-on settings saved (Central Endpoint + API token)."
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
    print_info "After saving Add-on Settings, create these inputs in Splunk (Inputs -> Create New Input):"
    print_info "  - ACS Compliance"
    print_info "  - ACS Violations"
    print_info "  - ACS Vulnerability Management"
    print_info "Suggested polling interval: ${interval} seconds"
    print_info "Verification search: index=* sourcetype=\"stackrox-*\""
}

print_final_details() {
    local namespace="$1"
    local name="$2"
    local route_host="$3"
    local password="$4"
    local addon_sha="${SPLUNK_RHACS_ADDON_SHA256:-62104fae3307184a16c3a92343aa4a4cd4116aa8df86422e89a6915ff7a28461}"

    echo ""
    print_step "Final details"
    print_info "Splunk Web URL: https://${route_host}"
    print_info "Splunk username: admin"
    print_info "Splunk password: ${password}"
    print_info "HEC base URL (in-cluster): http://${name}.${namespace}.svc.cluster.local:8088"
    print_info "Expected add-on package: red-hat-advanced-cluster-security-splunk-technology-add-on_204.tgz"
    print_info "Expected add-on SHA256: ${addon_sha}"
    print_info "Cleanup script: ./clean.sh"
    print_info "To fully remove setup: SPLUNK_DELETE_NAMESPACE=true ./clean.sh"
    echo ""
    print_info "Manual RHACS integration steps (for validation):"
    print_info "  1) In Splunk: enable HEC and create a token"
    print_info "  2) In RHACS: Platform Configuration -> Integrations -> Splunk notifier"
    print_info "  3) Use URL: https://<splunk-host>:8088/services/collector/event"
    print_info "  4) Paste HEC token, click Test, then Create"
    print_info "  5) Enable notifier on policies and trigger a new violation"
    print_info "  6) In Splunk Search, verify events"
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
    local splunk_service_url="http://${name}.${namespace}.svc.cluster.local:8088"
    local hec_name="${SPLUNK_HEC_NAME:-rhacs-hec}"
    local notifier_name="${SPLUNK_NOTIFIER_NAME:-Splunk SIEM (local)}"

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
    "sourceTypes": ["stackrox"],
    "skipTlsVerify": true
  }
}
EOF
)
    payload="$(echo "${payload}" | sed "s/__NOTIFIER_NAME__/$(escape_sed_replacement "${notifier_name}")/g")"
    payload="$(echo "${payload}" | sed "s/__HEC_ENDPOINT__/$(escape_sed_replacement "${splunk_service_url}")/g")"
    payload="$(echo "${payload}" | sed "s/__HEC_TOKEN__/$(escape_sed_replacement "${hec_token}")/g")"

    local code
    if [ -n "${notifier_id}" ]; then
        code="$(curl -k -s -o /tmp/rhacs-splunk-notifier.out -w "%{http_code}" \
            -X PUT "${rox_central}/v1/notifiers/${notifier_id}" \
            -H "Authorization: Bearer ${rox_token}" \
            -H "Content-Type: application/json" \
            --data "${payload}")"
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

    # Convenience: pick up RHACS API values from ~/.bashrc if user already saved them there.
    load_env_from_bashrc_if_missing "ROX_CENTRAL_ADDRESS"
    load_env_from_bashrc_if_missing "ROX_API_TOKEN"
    load_env_from_bashrc_if_missing "RHACS_SPLUNK_ADDON_TOKEN"

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
    integrate_rhacs_with_splunk "${namespace}" "${name}" "${password}"
    print_rhacs_addon_configuration_steps
    print_final_details "${namespace}" "${name}" "${route_host}" "${password}"
}

main "$@"
