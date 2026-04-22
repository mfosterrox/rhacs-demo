#!/usr/bin/env bash
#
# Deploy RHACS PaC (Policy-as-Code) custom policies via OpenShift GitOps (Argo CD).
# Syncs YAML from: https://github.com/mfosterrox/demo-apps/tree/main/PaC-custom-policies
#
# Prerequisites:
#   - oc logged into the cluster
#   - OpenShift GitOps installed (openshift-gitops-operator); default Argo CD in openshift-gitops
#   - RHACS installed so the stackrox namespace exists (SecurityPolicy CRs apply there)
#
# Optional environment:
#   POLICY_REPO_URL         — Git repo URL (default https://github.com/mfosterrox/demo-apps.git)
#   POLICY_REPO_PATH         — Path inside repo (default PaC-custom-policies)
#   POLICY_REPO_REVISION     — Branch/tag/commit (default main)
#   RHACS_NAMESPACE          — Where policies are synced (default stackrox)
#   GITOPS_NAMESPACE         — Argo CD Application namespace (default openshift-gitops)
#   ARGOCD_APP_NAME          — Application resource name (default rhacs-pac-custom-policies)
#   ARGOCD_PROJECT           — Argo CD AppProject (default default)
#   ARGOCD_WAIT_SYNC=1       — Wait until status.sync.status is Synced (default off)
#   ARGOCD_SYNC_WAIT_SEC     — Max seconds to wait when ARGOCD_WAIT_SYNC=1 (default 180)
#
# If the Application reports sync errors due to RBAC, grant the GitOps application controller
# permission to manage config.stackrox.io resources in the RHACS namespace (cluster policy
# varies by OpenShift GitOps version).

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RHACS_DEMO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

POLICY_REPO_URL="${POLICY_REPO_URL:-https://github.com/mfosterrox/demo-apps.git}"
POLICY_REPO_PATH="${POLICY_REPO_PATH:-PaC-custom-policies}"
POLICY_REPO_REVISION="${POLICY_REPO_REVISION:-main}"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-openshift-gitops}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-rhacs-pac-custom-policies}"
ARGOCD_PROJECT="${ARGOCD_PROJECT:-default}"

require_oc() {
    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found"
        setup_rerun_hint_print
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged in. Run: oc login"
        setup_rerun_hint_print
        exit 1
    fi
}

render_application() {
    cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${ARGOCD_APP_NAME}
  namespace: ${GITOPS_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: rhacs-demo
spec:
  project: ${ARGOCD_PROJECT}
  source:
    repoURL: ${POLICY_REPO_URL}
    targetRevision: ${POLICY_REPO_REVISION}
    path: ${POLICY_REPO_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${RHACS_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

wait_for_argo_sync() {
    local deadline=$((SECONDS + ${ARGOCD_SYNC_WAIT_SEC:-180}))
    local status="" health=""
    print_step "Waiting for Argo CD sync (up to ${ARGOCD_SYNC_WAIT_SEC:-180}s)..."
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        status=$(oc get "application.argoproj.io/${ARGOCD_APP_NAME}" -n "${GITOPS_NAMESPACE}" \
            -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
        health=$(oc get "application.argoproj.io/${ARGOCD_APP_NAME}" -n "${GITOPS_NAMESPACE}" \
            -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
        if [ -n "${status}" ]; then
            print_info "  sync.status=${status} health.status=${health:-unknown}"
        fi
        if [ "${status}" = "Synced" ]; then
            print_info "✓ Application is Synced"
            return 0
        fi
        sleep 5
    done
    print_warn "Timed out waiting for Synced (last sync.status=${status:-n/a})"
    print_warn "Check: oc describe application.argoproj.io/${ARGOCD_APP_NAME} -n ${GITOPS_NAMESPACE}"
    return 1
}

main() {
    print_info "=========================================="
    print_info "RHACS custom policies (GitOps)"
    print_info "=========================================="

    require_oc

    print_step "Checking namespaces and CRDs..."
    if ! oc get namespace "${RHACS_NAMESPACE}" &>/dev/null; then
        print_error "Namespace '${RHACS_NAMESPACE}' not found. Install RHACS before syncing policies."
        setup_rerun_hint_print
        exit 1
    fi
    if ! oc get namespace "${GITOPS_NAMESPACE}" &>/dev/null; then
        print_error "Namespace '${GITOPS_NAMESPACE}' not found."
        print_error "Install OpenShift GitOps: OperatorHub → OpenShift GitOps, or see"
        print_error "https://docs.redhat.com/en/documentation/gitops/latest/"
        setup_rerun_hint_print
        exit 1
    fi
    if ! oc get crd applications.argoproj.io &>/dev/null; then
        print_error "CRD applications.argoproj.io not found. OpenShift GitOps may not be fully installed."
        setup_rerun_hint_print
        exit 1
    fi

    print_info "Repository: ${POLICY_REPO_URL}"
    print_info "Path: ${POLICY_REPO_PATH} @ ${POLICY_REPO_REVISION}"
    print_info "Policy destination namespace: ${RHACS_NAMESPACE}"
    print_info "Argo CD Application: ${GITOPS_NAMESPACE}/${ARGOCD_APP_NAME}"

    print_step "Applying Argo CD Application..."
    render_application | oc apply -f -

    print_info "✓ Application applied"

    if [ "${ARGOCD_WAIT_SYNC:-0}" = "1" ]; then
        wait_for_argo_sync || true
    else
        print_info "Tip: export ARGOCD_WAIT_SYNC=1 to wait until resources are Synced"
    fi

    print_info ""
    print_info "Verify in cluster:"
    print_info "  oc get application.argoproj.io -n ${GITOPS_NAMESPACE} ${ARGOCD_APP_NAME}"
    print_info "  oc get securitypolicy -n ${RHACS_NAMESPACE}"
    print_info ""
    print_info "Argo CD UI (if exposed):"
    print_info "  oc get route openshift-gitops-server -n ${GITOPS_NAMESPACE} -o jsonpath='https://{.spec.host}{\"\\n\"}'"
}

main "$@"
