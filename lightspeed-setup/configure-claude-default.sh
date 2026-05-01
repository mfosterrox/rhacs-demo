#!/usr/bin/env bash
#
# Interactive walkthrough: make Claude the default LLM in OpenShift Lightspeed (OLSConfig).
#
# Anthropic Console keys use Secret key "apitoken" for Lightspeed (see README).
# Claude is typically wired as google_vertex_anthropic (GCP) or bam (hosted URL + token).
#
# Run:  ./configure-claude-default.sh
# Help: ./configure-claude-default.sh --help
#
# Docs: https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

if [ -f "${REPO_ROOT}/setup-rerun-hint.sh" ]; then
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/setup-rerun-hint.sh"
    setup_rerun_register "${BASH_SOURCE[0]}"
fi

LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
LIGHTSPEED_OLSCONFIG_NAME="${LIGHTSPEED_OLSCONFIG_NAME:-cluster}"
LIGHTSPEED_SECRET_NAME="${LIGHTSPEED_SECRET_NAME:-anthropic-api-keys}"
LIGHTSPEED_RESTART="${LIGHTSPEED_RESTART:-true}"

if declare -F setup_rerun_hint_print &>/dev/null; then
    trap 'e=$?; [ "${e}" -eq 0 ] || setup_rerun_hint_print; exit "${e}"' ERR
fi

ols_oc() {
    command oc --request-timeout="${OLS_OC_REQUEST_TIMEOUT:-60s}" "$@"
}

declare -a OLS_CMD=()
OLS_SCOPE=""

resolve_ols_cmd() {
    OLS_CMD=(ols_oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}")
    if ! "${OLS_CMD[@]}" &>/dev/null; then
        OLS_CMD=(ols_oc get olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}")
        if ! "${OLS_CMD[@]}" &>/dev/null; then
            return 1
        fi
        OLS_SCOPE="namespaced"
    else
        OLS_SCOPE="cluster"
    fi
    return 0
}

usage() {
    echo "Usage: $0"
    echo ""
    echo "Runs an interactive walkthrough (no flags). Makes Claude the default model in OLSConfig."
    echo "Requires: oc, python3, cluster login, and permission to patch olsconfig/${LIGHTSPEED_OLSCONFIG_NAME}."
    echo ""
    echo "See lightspeed-setup/README.md for Anthropic Console keys, Secret apitoken, and automation hints."
}

read_secret_token() {
    local t
    if [ -n "${CLAUDE_API_KEY:-}" ]; then
        printf '%s' "${CLAUDE_API_KEY}"
        return 0
    fi
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf '%s' "${ANTHROPIC_API_KEY}"
        return 0
    fi
    if [ -t 0 ]; then
        read -r -s -p "Paste API token (input hidden): " t
        echo "" >&2
        printf '%s' "${t}"
        return 0
    fi
    print_error "Cannot read token non-interactively. Export CLAUDE_API_KEY or ANTHROPIC_API_KEY, or run in a terminal."
    exit 1
}

ensure_secret_bam() {
    local token
    token="$(read_secret_token)"
    if [ -z "${token}" ]; then
        print_error "Empty token."
        exit 1
    fi
    print_step "Creating/updating secret ${LIGHTSPEED_NAMESPACE}/${LIGHTSPEED_SECRET_NAME} (key apitoken)..."
    ols_oc create secret generic "${LIGHTSPEED_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" \
        --from-literal=apitoken="${token}" \
        --dry-run=client -o yaml | ols_oc apply -f -
}

ensure_secret_vertex() {
    local creds_path="$1"
    if [ -z "${creds_path}" ] || [ ! -f "${creds_path}" ]; then
        print_error "That file path is missing or not readable."
        exit 1
    fi
    print_step "Creating/updating secret ${LIGHTSPEED_NAMESPACE}/${LIGHTSPEED_SECRET_NAME} from ${creds_path}..."
    ols_oc create secret generic "${LIGHTSPEED_SECRET_NAME}" -n "${LIGHTSPEED_NAMESPACE}" \
        --from-file=apitoken="${creds_path}" \
        --dry-run=client -o yaml | ols_oc apply -f -
}

apply_ols_patch_python() {
    local patch_json_out="$1"
    shift
    export _OLS_PATCH_OUT="${patch_json_out}"
    export _OLS_BACKEND="$1"
    export _OLS_PROVIDER_NAME="$2"
    export _OLS_MODEL="$3"
    export _OLS_SECRET_NAME="$4"
    export _OLS_BAM_URL="${5:-}"
    export _OLS_GCP_PROJECT="$6"
    export _OLS_GCP_LOCATION="$7"
    export _OLS_DEFAULTS_ONLY="$8"

    python3 - <<'PY'
import json, os, sys

out_path = os.environ["_OLS_PATCH_OUT"]
backend = os.environ["_OLS_BACKEND"]
provider_name = os.environ["_OLS_PROVIDER_NAME"]
model_name = os.environ["_OLS_MODEL"]
secret_name = os.environ["_OLS_SECRET_NAME"]
bam_url = os.environ.get("_OLS_BAM_URL") or ""
gcp_project = os.environ.get("_OLS_GCP_PROJECT") or ""
gcp_location = os.environ.get("_OLS_GCP_LOCATION") or ""
defaults_only = os.environ.get("_OLS_DEFAULTS_ONLY") == "1"

inp_path = os.environ["_OLS_JSON_IN"]

with open(inp_path, encoding="utf-8") as f:
    doc = json.load(f)

spec = doc.setdefault("spec", {})

if defaults_only:
    fragment = {"spec": {"ols": {"defaultProvider": provider_name, "defaultModel": model_name}}}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(fragment, f)
    sys.exit(0)

llm = spec.setdefault("llm", {})
providers = list(llm.get("providers") or [])
providers = [p for p in providers if isinstance(p, dict) and p.get("name") != provider_name]

entry = {
    "name": provider_name,
    "credentialsSecretRef": {"name": secret_name},
    "models": [{"name": model_name}],
}

if backend == "bam":
    if not bam_url:
        print("error: BAM URL required", file=sys.stderr)
        sys.exit(2)
    entry["type"] = "bam"
    entry["url"] = bam_url
elif backend == "vertex":
    if not gcp_project or not gcp_location:
        print("error: GCP project and region required for vertex", file=sys.stderr)
        sys.exit(2)
    region = gcp_location.strip()
    entry["type"] = "google_vertex_anthropic"
    entry["url"] = f"https://{region}-aiplatform.googleapis.com"
    entry["googleVertexAnthropicConfig"] = {"project": gcp_project, "location": region}
else:
    print(f"error: unknown backend {backend}", file=sys.stderr)
    sys.exit(2)

providers.append(entry)
llm["providers"] = providers

ols = spec.setdefault("ols", {})
ols["defaultProvider"] = provider_name
ols["defaultModel"] = model_name

fragment = {
    "spec": {
        "llm": {"providers": llm["providers"]},
        "ols": {"defaultProvider": ols["defaultProvider"], "defaultModel": ols["defaultModel"]},
    }
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(fragment, f)
PY
}

run_patch_and_restart() {
    local defaults_only_flag="$1"
    local backend="$2"
    local provider_name="$3"
    local model_name="$4"
    local bam_url="$5"
    local gcp_project="$6"
    local gcp_location="$7"

    local tmpjson patchfile
    tmpjson="$(mktemp)"
    patchfile="$(mktemp)"
    if ! "${OLS_CMD[@]}" -o json > "${tmpjson}"; then
        print_error "Failed to export OLSConfig JSON"
        rm -f "${tmpjson}"
        exit 1
    fi

    export _OLS_JSON_IN="${tmpjson}"
    apply_ols_patch_python "${patchfile}" "${backend}" "${provider_name}" "${model_name}" \
        "${LIGHTSPEED_SECRET_NAME}" "${bam_url}" "${gcp_project}" "${gcp_location}" "${defaults_only_flag}"
    local py_rc=$?
    if [ "${py_rc}" -ne 0 ]; then
        rm -f "${tmpjson}" "${patchfile}"
        print_error "Could not build the configuration patch."
        exit 1
    fi

    print_step "Applying change to OLSConfig..."
    local prc=0
    if [ "${OLS_SCOPE}" = "cluster" ]; then
        ols_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" --type=merge -p "$(cat "${patchfile}")" || prc=$?
    else
        ols_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" --type=merge -p "$(cat "${patchfile}")" || prc=$?
    fi
    rm -f "${tmpjson}" "${patchfile}"

    if [ "${prc}" -ne 0 ]; then
        print_error "oc patch failed. Check messages above (RBAC or invalid provider settings)."
        exit 1
    fi

    print_info "✓ OLSConfig updated. Default provider is now «${provider_name}», model «${model_name}»."

    if [ "${LIGHTSPEED_RESTART}" = "true" ] && ols_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_step "Restarting lightspeed-app-server so the console picks up changes..."
        ols_oc rollout restart deployment/lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null || true
        print_info "✓ Restart triggered."
    fi
}

walkthrough() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  OpenShift Lightspeed — set Claude as the default model"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    print_info "Connected. OLSConfig «${LIGHTSPEED_OLSCONFIG_NAME}» is ${OLS_SCOPE}-scoped."
    echo ""
    echo "Choose what you need:"
    echo ""
    echo "  1) Claude is already listed under LLM providers in OLSConfig — only switch the default"
    echo "  2) Add a Claude provider (secret + OLSConfig) and make it the default"
    echo ""
    read -r -p "Enter 1 or 2 [1]: " choice
    choice="${choice:-1}"

    case "${choice}" in
        1)
            echo ""
            print_step "Switch default only"
            echo "Open your current providers with:"
            echo "  oc get olsconfig ${LIGHTSPEED_OLSCONFIG_NAME} -o jsonpath='{range .spec.llm.providers[*]}Name: {.name}{\"\\n\"}{end}'"
            echo "Use the exact provider name and a model name that appears under that provider."
            echo ""
            read -r -p "Provider name as shown in OLSConfig [Anthropic]: " pname
            pname="${pname:-Anthropic}"
            read -r -p "Model name [claude-sonnet-4-20250514]: " mname
            mname="${mname:-claude-sonnet-4-20250514}"
            echo ""
            print_info "Setting defaultProvider=${pname}, defaultModel=${mname}"
            run_patch_and_restart "1" "" "${pname}" "${mname}" "" "" ""
            ;;
        2)
            echo ""
            print_step "Add provider and set default"
            echo "Lightspeed expects API credentials in namespace «${LIGHTSPEED_NAMESPACE}»"
            echo "in a Secret named «${LIGHTSPEED_SECRET_NAME}» with key «apitoken»."
            echo ""
            read -r -p "Secret name [${LIGHTSPEED_SECRET_NAME}]: " sname
            LIGHTSPEED_SECRET_NAME="${sname:-${LIGHTSPEED_SECRET_NAME}}"
            echo ""
            echo "How will this cluster reach Claude?"
            echo "  A) Google Cloud Vertex AI (you have a GCP service account JSON file)"
            echo "  B) A BAM-style HTTPS URL + API token (from your product or IBM docs)"
            echo ""
            read -r -p "Enter A or B [B]: " conn
            conn="${conn:-B}"
            conn="$(echo "${conn}" | tr '[:upper:]' '[:lower:]')"

            local backend="" gcp_proj="" gcp_loc="" bam_url="" gcp_file=""

            if [ "${conn}" = "a" ]; then
                backend="vertex"
                read -r -p "GCP project ID: " gcp_proj
                read -r -p "GCP region (location) [us-central1]: " gcp_loc
                gcp_loc="${gcp_loc:-us-central1}"
                read -r -p "Full path to GCP service account JSON file: " gcp_file
                if [ -z "${gcp_proj}" ]; then
                    print_error "GCP project ID is required."
                    exit 1
                fi
                ensure_secret_vertex "${gcp_file}"
            else
                backend="bam"
                read -r -p "Base URL for the endpoint (example: https://your-host/v1): " bam_url
                if [ -z "${bam_url}" ]; then
                    print_error "URL is required."
                    exit 1
                fi
                ensure_secret_bam
            fi

            echo ""
            read -r -p "Provider name to show in OLSConfig [claude]: " pname
            pname="${pname:-claude}"
            read -r -p "Model id [claude-sonnet-4-20250514]: " mname
            mname="${mname:-claude-sonnet-4-20250514}"

            run_patch_and_restart "0" "${backend}" "${pname}" "${mname}" "${bam_url}" "${gcp_proj}" "${gcp_loc}"
            ;;
        *)
            print_error "Please enter 1 or 2."
            exit 1
            ;;
    esac

    echo ""
    print_info "All set. Open the OpenShift console and use Lightspeed — Claude should be the default."
    echo ""
}

main() {
    case "${1:-}" in
        -h|--help)
            usage
            exit 0
            ;;
        "")
            ;;
        *)
            print_error "This script is interactive and does not take arguments (except --help)."
            echo "Run:  $0" >&2
            exit 1
            ;;
    esac

    if ! command -v oc &>/dev/null; then
        print_error "Install the oc CLI and add it to PATH."
        exit 1
    fi
    if ! command -v python3 &>/dev/null; then
        print_error "python3 is required."
        exit 1
    fi
    if ! ols_oc whoami &>/dev/null; then
        print_error "Not logged in. Run: oc login ..."
        exit 1
    fi
    if ! resolve_ols_cmd; then
        print_error "Could not read OLSConfig «${LIGHTSPEED_OLSCONFIG_NAME}». Is OpenShift Lightspeed installed?"
        exit 1
    fi

    walkthrough
}

main "$@"
