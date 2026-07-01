#!/bin/bash
# Build and deploy Project Hummingbird workloads from demo-applications, then register
# the base image in RHACS so layer filtering appears in the UI.
#
# Requires: ROX_API_TOKEN, oc logged in, demo-applications repo (cloned by script 04)
# Optional: SKIP_HUMMINGBIRD_DEMO=1, DEMO_APPS_DIR, HUMMINGBIRD_BUILD_ON_CLUSTER=0

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

DEMO_APPS_DIR="${DEMO_APPS_DIR:-${HOME}/demo-applications}"
if [ -d "${_RHACS_DEMO_ROOT}/../demo-applications/k8s-deployment-manifests/hummingbird-demo" ] && [ "${DEMO_APPS_DIR}" = "${HOME}/demo-applications" ]; then
    DEMO_APPS_DIR="${_RHACS_DEMO_ROOT}/../demo-applications"
fi
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/basic-setup/lib/hummingbird-demo.sh"

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || return 1
}

ensure_demo_applications() {
    if [ -d "${DEMO_APPS_DIR}/k8s-deployment-manifests/hummingbird-demo" ]; then
        return 0
    fi
    print_error "demo-applications not found at ${DEMO_APPS_DIR}"
    print_error "Run: bash basic-setup/04-deploy-applications.sh"
    return 1
}

apply_hummingbird_manifests() {
    local manifests_dir
    manifests_dir="$(hummingbird_manifests_dir "${DEMO_APPS_DIR}")"

    print_step "Applying Hummingbird demo manifests from demo-applications..."
    oc apply -f "${DEMO_APPS_DIR}/k8s-deployment-manifests/-namespaces/namespace-hummingbird-demo.yaml" 2>/dev/null || \
        oc apply -f "${manifests_dir}/../-namespaces/namespace-hummingbird-demo.yaml" 2>/dev/null || true
    oc apply -f "${manifests_dir}/"
}

main() {
    if [ "${SKIP_HUMMINGBIRD_DEMO:-0}" = "1" ]; then
        print_info "Skipping Hummingbird demo (SKIP_HUMMINGBIRD_DEMO=1)"
        exit 0
    fi

    print_info "=========================================="
    print_info "Project Hummingbird — Build & Deploy"
    print_info "=========================================="
    print_info ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        print_error "jq is required"
        exit 1
    fi

    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN is required"
        exit 1
    fi

    ensure_demo_applications || exit 1

    apply_hummingbird_manifests

    if [ "${HUMMINGBIRD_BUILD_ON_CLUSTER:-1}" = "1" ]; then
        build_hummingbird_layered_image "${DEMO_APPS_DIR}" || true
    else
        print_info "Skipping in-cluster build (HUMMINGBIRD_BUILD_ON_CLUSTER=0)"
    fi

    wait_for_hummingbird_deployments

    print_info ""
    local central_url api_host api_v2
    central_url=$(get_central_url) || true
    if [ -n "${central_url}" ]; then
        api_host="${central_url#https://}"
        api_host="${api_host#http://}"
        api_v2="https://${api_host}/v2"
        register_hummingbird_base_image "${token}" "${api_v2}"
    fi

    print_hummingbird_ui_guidance

    print_info ""
    print_info "=========================================="
    print_info "Hummingbird Demo Deployment Complete"
    print_info "=========================================="
    print_info ""
}

main "$@"
