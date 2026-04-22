#!/usr/bin/env bash
#
# Tekton / OpenShift Pipelines demo — RHACS roxctl tasks and sample pipeline (roadshow module 05).
# Applies namespace pipeline-demo, Secret roxsecrets (Central host:443 + API token), Tasks, and Pipelines (rox-pipeline, rox-log4shell-pipeline).
#
# Prerequisites:
#   - oc logged in; OpenShift Pipelines operator installed (Tekton Task/Pipeline CRDs available)
#   - RHACS Central route in RHACS_NAMESPACE (default stackrox), or ROX_CENTRAL_ADDRESS set
#   - API_TOKEN or ROX_API_TOKEN — RHACS API token (Admin or CI-capable); ~/.bashrc may export API_TOKEN
#   - ROXCTL_CENTRAL_ENDPOINT or Central route / ROX_CENTRAL_ADDRESS — host:port for roxctl -e (no https://)
#
# Optional env:
#   PIPELINE_NAMESPACE  — default pipeline-demo
#   RHACS_NAMESPACE    — default stackrox
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS="${SCRIPT_DIR}/manifests"
PIPELINE_NS="${PIPELINE_NAMESPACE:-pipeline-demo}"
RHACS_NS="${RHACS_NAMESPACE:-stackrox}"

_RHACS_DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

export_bashrc_vars() {
  [ ! -f ~/.bashrc ] && return 0
  local var line
  for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN ROXCTL_CENTRAL_ENDPOINT API_TOKEN RHACS_NAMESPACE; do
    line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1) || true
    [ -z "${line}" ] && continue
    if grep -qE '\$\(|`' <<< "${line}"; then
      print_warn "Skipping ${var} from ~/.bashrc (command substitution). Export ${var} in this shell."
      continue
    fi
    [[ "${line}" =~ ^export[[:space:]]+ ]] || line="export ${line}"
    eval "${line}" 2>/dev/null || true
  done
}

# host:port for roxctl -e (no scheme); accepts bare host, host:port, or http(s) URL
normalize_central_endpoint() {
  local url="$1"
  url="${url#https://}"
  url="${url#http://}"
  url="${url%%/*}"
  if [[ "${url}" =~ :[0-9]+$ ]]; then
    echo "${url}"
  else
    echo "${url}:443"
  fi
}

# host:port for roxctl -e when ROXCTL_CENTRAL_ENDPOINT is unset
resolve_central_endpoint_port() {
  local host=""
  host=$(oc get route central -n "${RHACS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${host}" ]; then
    normalize_central_endpoint "${host}"
    return 0
  fi
  local url="${ROX_CENTRAL_ADDRESS:-}"
  if [ -z "${url}" ]; then
    return 1
  fi
  normalize_central_endpoint "${url}"
}

# Renders the same Secret schema as manifests/secrets/rox-secrets.yml and applies it.
apply_rox_secrets_manifest() {
  local endpoint="$1"
  local token="$2"
  local ns="$3"
  export _INSTALL_ROX_EP="${endpoint}"
  export _INSTALL_ROX_TK="${token}"
  export _INSTALL_ROX_NS="${ns}"
  python3 -c '
import json, os, sys
ep, tk, ns = os.environ["_INSTALL_ROX_EP"], os.environ["_INSTALL_ROX_TK"], os.environ["_INSTALL_ROX_NS"]
for v in (ep, tk, ns):
    if "\x00" in v:
        print("refusing secret value containing NUL", file=sys.stderr)
        sys.exit(1)
print("""apiVersion: v1
kind: Secret
metadata:
  name: roxsecrets
  namespace: %s
type: Opaque
stringData:
  rox_central_endpoint: %s
  rox_api_token: %s
""" % (ns, json.dumps(ep), json.dumps(tk)))
' | oc apply -f -
  unset _INSTALL_ROX_EP _INSTALL_ROX_TK _INSTALL_ROX_NS
}

main() {
  print_info "OpenShift Pipelines / Tekton — RHACS CI demo (rox-pipeline, rox-log4shell-pipeline)"
  echo ""

  if ! command -v oc &>/dev/null; then
    print_error "oc not found"
    setup_rerun_hint_print
    exit 1
  fi
  if ! oc whoami &>/dev/null; then
    print_error "Not logged in. Run: oc login"
    setup_rerun_hint_print
    exit 1
  fi

  export_bashrc_vars
  if [ -n "${RHACS_NAMESPACE:-}" ]; then
    RHACS_NS="${RHACS_NAMESPACE}"
  fi

  local rox_token=""
  if [ -n "${API_TOKEN:-}" ]; then
    rox_token="${API_TOKEN}"
  elif [ -n "${ROX_API_TOKEN:-}" ]; then
    rox_token="${ROX_API_TOKEN}"
  fi
  if [ -z "${rox_token}" ] || [ ${#rox_token} -lt 20 ]; then
    print_error "API_TOKEN or ROX_API_TOKEN is required (generate via basic-setup or RHACS UI). Export one in this shell or ~/.bashrc."
    setup_rerun_hint_print
    exit 1
  fi

  local endpoint=""
  if [ -n "${ROXCTL_CENTRAL_ENDPOINT:-}" ]; then
    endpoint=$(normalize_central_endpoint "${ROXCTL_CENTRAL_ENDPOINT}")
  else
    endpoint=$(resolve_central_endpoint_port) || {
      print_error "Could not resolve Central endpoint. Set ROXCTL_CENTRAL_ENDPOINT, ROX_CENTRAL_ADDRESS, or ensure route 'central' exists in ${RHACS_NS}."
      setup_rerun_hint_print
      exit 1
    }
  fi

  if ! oc get crd tasks.tekton.dev &>/dev/null; then
    print_error "Tekton Task CRD (tasks.tekton.dev) not found. Install OpenShift Pipelines from OperatorHub, then retry."
    setup_rerun_hint_print
    exit 1
  fi

  print_step "Applying namespace ${PIPELINE_NS}..."
  oc apply -f "${MANIFESTS}/namespace.yaml"

  print_step "Applying Secret roxsecrets in ${PIPELINE_NS} (rox_central_endpoint from ROXCTL_CENTRAL_ENDPOINT or route/ROX_CENTRAL_ADDRESS; rox_api_token from API_TOKEN or ROX_API_TOKEN)..."
  if ! command -v python3 &>/dev/null; then
    print_error "python3 is required to render manifests/secrets/rox-secrets.yml for oc apply."
    setup_rerun_hint_print
    exit 1
  fi
  apply_rox_secrets_manifest "${endpoint}" "${rox_token}" "${PIPELINE_NS}"

  print_step "Applying Tekton Tasks (rox-image-scan, rox-image-check, rox-deployment-check)..."
  oc apply -f "${MANIFESTS}/tasks/"

  print_step "Applying Pipelines (rox-pipeline, rox-log4shell-pipeline)..."
  oc apply -f "${MANIFESTS}/pipeline/"

  print_info ""
  print_info "✓ Tekton resources applied in ${PIPELINE_NS}"
  print_info "  Console: Pipelines → Project ${PIPELINE_NS} → PipelineRuns"
  print_info "  Fixed image (log4shell): tkn pipeline start rox-log4shell-pipeline -n ${PIPELINE_NS}"
  print_info "  Custom image: tkn pipeline start rox-pipeline -n ${PIPELINE_NS} -p image=quay.io/example/app:latest"
  print_info ""
  print_info "Manifest templates (module 05) live under: ${MANIFESTS}"
}

main "$@"
