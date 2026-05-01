#!/usr/bin/env bash
#
# Configure OpenShift Lightspeed (OLSConfig) to use Claude as the default LLM.
#
# OpenShift Lightspeed does not expose a separate "Anthropic API" provider type in OLSConfig.
# Claude is typically wired either as:
#   - google_vertex_anthropic — Claude on Google Cloud Vertex AI (GCP service account JSON)
#   - bam — IBM BAM-style endpoint (API URL + token; see your IBM/product docs for the URL)
#
# Usage:
#   ./configure-claude-default.sh --backend vertex
#   ./configure-claude-default.sh --backend bam
#   ./configure-claude-default.sh --defaults-only --provider-name myClaude --model claude-sonnet-4-20250514
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
    setup_rerun_register "${BASH_SOURCE[0]}" "$@"
fi

LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
LIGHTSPEED_OLSCONFIG_NAME="${LIGHTSPEED_OLSCONFIG_NAME:-cluster}"
LIGHTSPEED_SECRET_NAME="${LIGHTSPEED_SECRET_NAME:-lightspeed-claude-credentials}"
LIGHTSPEED_RESTART="${LIGHTSPEED_RESTART:-true}"

CLAUDE_PROVIDER_NAME="${CLAUDE_PROVIDER_NAME:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-4-20250514}"

# vertex | bam
LIGHTSPEED_CLAUDE_BACKEND="${LIGHTSPEED_CLAUDE_BACKEND:-vertex}"

# BAM: base URL for your IBM / hosted Claude-compatible endpoint (required for backend=bam)
LIGHTSPEED_BAM_URL="${LIGHTSPEED_BAM_URL:-}"

# Vertex: GCP project/region and service account JSON file path
GCP_VERTEX_PROJECT="${GCP_VERTEX_PROJECT:-}"
GCP_VERTEX_LOCATION="${GCP_VERTEX_LOCATION:-us-central1}"

BACKEND=""
DEFAULTS_ONLY=false
TOKEN_FILE=""
TOKEN_ARG=""
GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-}"

usage() {
    sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
    echo ""
    echo "Options:"
    echo "  --backend vertex|bam     LLM wiring (default: env LIGHTSPEED_CLAUDE_BACKEND or vertex)"
    echo "  --defaults-only          Only set spec.ols.defaultProvider / defaultModel (no secret)"
    echo "  --provider-name NAME     Provider name in OLSConfig (default: ${CLAUDE_PROVIDER_NAME})"
    echo "  --model MODEL            Model id (default: ${CLAUDE_MODEL})"
    echo "  --token TOKEN            API token / key (prefer env CLAUDE_API_KEY for non-interactive)"
    echo "  --token-file PATH        Read token from file"
    echo "  -h, --help               Show help"
    echo ""
    echo "Environment (common):"
    echo "  CLAUDE_API_KEY | ANTHROPIC_API_KEY   Secret value for backend=bam (apitoken)"
    echo "  LIGHTSPEED_BAM_URL                   Required for backend=bam"
    echo "  GCP_VERTEX_PROJECT, GCP_VERTEX_LOCATION, GOOGLE_APPLICATION_CREDENTIALS  For backend=vertex"
    echo "  LIGHTSPEED_NAMESPACE, LIGHTSPEED_OLSCONFIG_NAME, LIGHTSPEED_SECRET_NAME"
}

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

read_token_interactive() {
    local t
    if [ -n "${CLAUDE_API_KEY:-}" ]; then
        printf '%s' "${CLAUDE_API_KEY}"
        return 0
    fi
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        printf '%s' "${ANTHROPIC_API_KEY}"
        return 0
    fi
    if [ -n "${TOKEN_ARG}" ]; then
        printf '%s' "${TOKEN_ARG}"
        return 0
    fi
    if [ -n "${TOKEN_FILE}" ]; then
        cat "${TOKEN_FILE}"
        return 0
    fi
    if [ -t 0 ]; then
        read -r -s -p "Paste API token / key (input hidden): " t
        echo "" >&2
        printf '%s' "${t}"
        return 0
    fi
    print_error "No token: set CLAUDE_API_KEY, use --token / --token-file, or run interactively."
    exit 1
}

parse_args() {
    BACKEND="${LIGHTSPEED_CLAUDE_BACKEND}"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --backend)
                BACKEND="$2"
                shift 2
                ;;
            --defaults-only)
                DEFAULTS_ONLY=true
                shift
                ;;
            --provider-name)
                CLAUDE_PROVIDER_NAME="$2"
                shift 2
                ;;
            --model)
                CLAUDE_MODEL="$2"
                shift 2
                ;;
            --token)
                TOKEN_ARG="$2"
                shift 2
                ;;
            --token-file)
                TOKEN_FILE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                print_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done
}

ensure_secret_bam() {
    local token
    token="$(read_token_interactive)"
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
    local creds_path="${GOOGLE_APPLICATION_CREDENTIALS:-}"
    if [ -z "${creds_path}" ] || [ ! -f "${creds_path}" ]; then
        print_error "GOOGLE_APPLICATION_CREDENTIALS must point to a readable GCP service account JSON file."
        print_info "Vertex Claude uses GCP credentials, not an Anthropic-console API key alone."
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
    ols = spec.setdefault("ols", {})
    ols["defaultProvider"] = provider_name
    ols["defaultModel"] = model_name
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
        print("error: LIGHTSPEED_BAM_URL / bam URL required for backend=bam", file=sys.stderr)
        sys.exit(2)
    entry["type"] = "bam"
    entry["url"] = bam_url
elif backend == "vertex":
    if not gcp_project or not gcp_location:
        print("error: GCP_VERTEX_PROJECT and GCP_VERTEX_LOCATION required for backend=vertex", file=sys.stderr)
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

main() {
    parse_args "$@"

    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found"
        exit 1
    fi
    if ! command -v python3 &>/dev/null; then
        print_error "python3 is required"
        exit 1
    fi
    if ! ols_oc whoami &>/dev/null; then
        print_error "Not logged in: oc login ..."
        exit 1
    fi

    if ! resolve_ols_cmd; then
        print_error "Could not read olsconfig ${LIGHTSPEED_OLSCONFIG_NAME}. Is OpenShift Lightspeed installed?"
        exit 1
    fi
    print_info "OLSConfig scope: ${OLS_SCOPE}"

    local tmpjson patchfile
    tmpjson="$(mktemp)"
    patchfile="$(mktemp)"
    if ! "${OLS_CMD[@]}" -o json > "${tmpjson}"; then
        print_error "Failed to export OLSConfig JSON"
        rm -f "${tmpjson}"
        exit 1
    fi

    if [ "${DEFAULTS_ONLY}" = true ]; then
        export _OLS_JSON_IN="${tmpjson}"
        apply_ols_patch_python "${patchfile}" "${BACKEND}" "${CLAUDE_PROVIDER_NAME}" "${CLAUDE_MODEL}" \
            "${LIGHTSPEED_SECRET_NAME}" "" "${GCP_VERTEX_PROJECT}" "${GCP_VERTEX_LOCATION}" "1"
        py_rc=$?
        if [ "${py_rc}" -ne 0 ]; then
            rm -f "${tmpjson}" "${patchfile}"
            print_error "Failed to build OLSConfig defaults patch."
            exit 1
        fi
    else
        case "${BACKEND}" in
            bam)
                if [ -z "${LIGHTSPEED_BAM_URL}" ]; then
                    print_error "LIGHTSPEED_BAM_URL is required for --backend bam (IBM/hosted Claude endpoint)."
                    exit 1
                fi
                ensure_secret_bam
                ;;
            vertex)
                if [ -z "${GCP_VERTEX_PROJECT}" ]; then
                    print_error "GCP_VERTEX_PROJECT is required for --backend vertex."
                    exit 1
                fi
                ensure_secret_vertex
                ;;
            *)
                print_error "Unsupported --backend ${BACKEND} (use vertex or bam)."
                exit 1
                ;;
        esac

        export _OLS_JSON_IN="${tmpjson}"
        apply_ols_patch_python "${patchfile}" "${BACKEND}" "${CLAUDE_PROVIDER_NAME}" "${CLAUDE_MODEL}" \
            "${LIGHTSPEED_SECRET_NAME}" "${LIGHTSPEED_BAM_URL:-}" "${GCP_VERTEX_PROJECT}" "${GCP_VERTEX_LOCATION}" "0"
        py_rc=$?
        if [ "${py_rc}" -eq 2 ]; then
            rm -f "${tmpjson}" "${patchfile}"
            exit 1
        fi
        if [ "${py_rc}" -ne 0 ]; then
            rm -f "${tmpjson}" "${patchfile}"
            print_error "Failed to build OLSConfig patch."
            exit 1
        fi
    fi

    print_step "Patching OLSConfig..."
    local prc=0
    if [ "${OLS_SCOPE}" = "cluster" ]; then
        ols_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" --type=merge -p "$(cat "${patchfile}")" || prc=$?
    else
        ols_oc patch olsconfig "${LIGHTSPEED_OLSCONFIG_NAME}" -n "${LIGHTSPEED_NAMESPACE}" --type=merge -p "$(cat "${patchfile}")" || prc=$?
    fi
    rm -f "${tmpjson}" "${patchfile}"

    if [ "${prc}" -ne 0 ]; then
        print_error "oc patch failed (exit ${prc}). Check RBAC and CRD validation messages."
        exit 1
    fi

    print_info "✓ OLSConfig updated (defaultProvider=${CLAUDE_PROVIDER_NAME}, defaultModel=${CLAUDE_MODEL})"

    if [ "${LIGHTSPEED_RESTART}" = "true" ] && ols_oc get deployment lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_step "Restarting lightspeed-app-server..."
        ols_oc rollout restart deployment/lightspeed-app-server -n "${LIGHTSPEED_NAMESPACE}" >/dev/null
        print_info "✓ Rollout restart triggered"
    fi

    print_info "Done."
}

main "$@"
