#!/usr/bin/env bash
#
# Tekton / OpenShift Pipelines demo — RHACS roxctl tasks and sample pipeline (roadshow module 05).
# Applies namespace pipeline-demo, Secret roxsecrets (Central host:443 + API token), Tasks, and Pipeline rox-pipeline.
#
# Prerequisites:
#   - oc logged in; OpenShift Pipelines operator installed (Tekton Task/Pipeline CRDs available)
#   - RHACS Central route in RHACS_NAMESPACE (default stackrox), or ROX_CENTRAL_ADDRESS set
#   - ROX_API_TOKEN — same as basic-setup (Admin or CI-capable token)
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

export_bashrc_vars() {
  [ ! -f ~/.bashrc ] && return 0
  local var line
  for var in ROX_CENTRAL_ADDRESS ROX_API_TOKEN RHACS_NAMESPACE; do
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

# host:port for roxctl -e (no scheme)
resolve_central_endpoint_port() {
  local host=""
  host=$(oc get route central -n "${RHACS_NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "${host}" ]; then
    echo "${host}:443"
    return 0
  fi
  local url="${ROX_CENTRAL_ADDRESS:-}"
  if [ -z "${url}" ]; then
    return 1
  fi
  url="${url#https://}"
  url="${url#http://}"
  url="${url%%/*}"
  if [[ "${url}" =~ :[0-9]+$ ]]; then
    echo "${url}"
  else
    echo "${url}:443"
  fi
}

main() {
  print_info "OpenShift Pipelines / Tekton — RHACS CI demo (rox-pipeline)"
  echo ""

  if ! command -v oc &>/dev/null; then
    print_error "oc not found"
    print_info "To rerun: bash \"${SCRIPT_DIR}/install.sh\""
    exit 1
  fi
  if ! oc whoami &>/dev/null; then
    print_error "Not logged in. Run: oc login"
    print_info "To rerun: bash \"${SCRIPT_DIR}/install.sh\""
    exit 1
  fi

  export_bashrc_vars
  if [ -n "${RHACS_NAMESPACE:-}" ]; then
    RHACS_NS="${RHACS_NAMESPACE}"
  fi

  if [ -z "${ROX_API_TOKEN:-}" ] || [ ${#ROX_API_TOKEN} -lt 20 ]; then
    print_error "ROX_API_TOKEN is required (generate via basic-setup or RHACS UI)."
    print_info "To rerun: bash \"${SCRIPT_DIR}/install.sh\""
    exit 1
  fi

  local endpoint
  endpoint=$(resolve_central_endpoint_port) || {
    print_error "Could not resolve Central endpoint. Set ROX_CENTRAL_ADDRESS or ensure route 'central' exists in ${RHACS_NS}."
    print_info "To rerun: bash \"${SCRIPT_DIR}/install.sh\""
    exit 1
  }

  if ! oc get crd tasks.tekton.dev &>/dev/null; then
    print_error "Tekton Task CRD (tasks.tekton.dev) not found. Install OpenShift Pipelines from OperatorHub, then retry."
    print_info "To rerun: bash \"${SCRIPT_DIR}/install.sh\""
    exit 1
  fi

  print_step "Applying namespace ${PIPELINE_NS}..."
  oc apply -f "${MANIFESTS}/namespace.yaml"

  print_step "Creating Secret roxsecrets in ${PIPELINE_NS}..."
  oc create secret generic roxsecrets -n "${PIPELINE_NS}" \
    --from-literal=rox_central_endpoint="${endpoint}" \
    --from-literal=rox_api_token="${ROX_API_TOKEN}" \
    --dry-run=client -o yaml | oc apply -f -

  print_step "Applying Tekton Tasks (rox-image-scan, rox-image-check, rox-deployment-check)..."
  oc apply -f "${MANIFESTS}/tasks/"

  print_step "Applying Pipeline rox-pipeline..."
  oc apply -f "${MANIFESTS}/pipeline/"

  print_info ""
  print_info "✓ Tekton resources applied in ${PIPELINE_NS}"
  print_info "  Console: Pipelines → Project ${PIPELINE_NS} → PipelineRuns — start rox-pipeline with param image=<full image ref>"
  print_info "  Example: tkn pipeline start rox-pipeline -n ${PIPELINE_NS} -p image=quay.io/example/app:latest"
  print_info ""
  print_info "Manifest templates (module 05) live under: ${MANIFESTS}"
}

main "$@"
