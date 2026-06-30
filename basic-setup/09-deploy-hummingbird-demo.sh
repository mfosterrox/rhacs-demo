#!/bin/bash
# Deploy Project Hummingbird (Red Hat Hardened Images) demo workloads and trigger RHACS scans.
#
# - Base-only deployment: registry.access.redhat.com/hi/python:3.13
# - Layered app: built via OpenShift BuildConfig or pre-published HI_LAYERED_IMAGE
#
# Requires: ROX_API_TOKEN, oc logged in
# Optional: SKIP_HUMMINGBIRD_DEMO=1, HUMMINGBIRD_BUILD_ON_CLUSTER=1 (default try build),
#           HI_BASE_IMAGE, HI_LAYERED_IMAGE, HUMMINGBIRD_NAMESPACE

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hummingbird-demo"
HUMMINGBIRD_NAMESPACE="${HUMMINGBIRD_NAMESPACE:-hummingbird-demo}"
HI_BASE_IMAGE="${HI_BASE_IMAGE:-registry.access.redhat.com/hi/python:3.13}"
HI_LAYERED_IMAGE="${HI_LAYERED_IMAGE:-}"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
BUILD_TIMEOUT_SEC="${HUMMINGBIRD_BUILD_TIMEOUT_SEC:-900}"

get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || return 1
}

get_rox_endpoint() {
    local url
    url=$(get_central_url) || return 1
    url="${url#https://}"
    url="${url#http://}"
    echo "${url%%/*}"
}

scan_image() {
    local image="$1"
    local label="$2"

    if ! command -v roxctl &>/dev/null; then
        print_warn "roxctl not in PATH; skipping scan of ${label}"
        return 0
    fi

    local endpoint
    endpoint=$(get_rox_endpoint) || {
        print_warn "Could not resolve Central endpoint for roxctl scan"
        return 0
    }

    print_step "Scanning ${label}: ${image}"
    export GRPC_ENFORCE_ALPN_ENABLED="${GRPC_ENFORCE_ALPN_ENABLED:-false}"
    if roxctl image scan --insecure-skip-tls-verify \
        -e "${endpoint}" \
        --image "${image}" \
        --output json 2>/dev/null | jq -r '
            if .imageVulnerabilities then
              "  CVE summary: " + ([.imageVulnerabilities[]?.vulnerabilities[]? | .severity] | group_by(.) | map("\(.[0]): \(length)") | join(", "))
            else
              "  Scan completed (see RHACS UI for VEX-aware results)"
            end
        ' 2>/dev/null; then
        print_info "✓ roxctl scan completed for ${label}"
    else
        print_warn "roxctl scan failed for ${image} — verify registry pull and ROX_API_TOKEN"
    fi
}

register_base_image() {
    local token="$1"
    local api_v2="$2"
    local repo="${RHACS_BASE_IMAGE_REPO_PATH:-registry.access.redhat.com/hi/python}"
    local tag="${RHACS_BASE_IMAGE_TAG_PATTERN:-3.13}"

    print_step "Registering Hummingbird base image in RHACS..."

    local existing_id
    existing_id=$(curl -k -s -H "Authorization: Bearer ${token}" "${api_v2}/baseimages" 2>/dev/null | \
        jq -r --arg repo "${repo}" --arg tag "${tag}" \
        '.baseImageReferences[]? | select(.baseImageRepoPath == $repo and .baseImageTagPattern == $tag) | .id' 2>/dev/null | head -1)

    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        print_info "✓ Base image already registered: ${repo}:${tag}"
        return 0
    fi

    local payload
    payload=$(jq -n --arg repo "${repo}" --arg tag "${tag}" \
        '{baseImageRepoPath: $repo, baseImageTagPattern: $tag}')

    local http_code
    http_code=$(curl -k -s -w "%{http_code}" -o /tmp/hi-base-reg.json -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_v2}/baseimages" 2>/dev/null || echo "000")

    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
        print_info "✓ Registered base image ${repo}:${tag}"
    else
        print_warn "Base image registration returned HTTP ${http_code} (script 05 may have already configured this)"
    fi
    rm -f /tmp/hi-base-reg.json
}

wait_for_build() {
    local ns="$1"
    local name="$2"
    local deadline=$((SECONDS + BUILD_TIMEOUT_SEC))

    print_step "Waiting for BuildConfig ${name} (up to ${BUILD_TIMEOUT_SEC}s)..."
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        local phase
        phase=$(oc get builds -n "${ns}" -l "buildconfig=${name}" -o jsonpath='{.items[-1].status.phase}' 2>/dev/null || echo "")
        case "${phase}" in
            Complete)
                print_info "✓ Build ${name} complete"
                return 0
                ;;
            Failed|Error|Cancelled)
                print_warn "Build ${name} ended with phase: ${phase}"
                oc logs -n "${ns}" "build/${name}-1" 2>/dev/null | tail -20 || true
                return 1
                ;;
        esac
        sleep 15
    done
    print_warn "Build ${name} timed out"
    return 1
}

main() {
    if [ "${SKIP_HUMMINGBIRD_DEMO:-0}" = "1" ]; then
        print_info "Skipping Hummingbird demo (SKIP_HUMMINGBIRD_DEMO=1)"
        exit 0
    fi

    print_info "=========================================="
    print_info "Project Hummingbird / Hardened Images Demo"
    print_info "=========================================="
    print_info ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift"
        exit 1
    fi

    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN is required"
        exit 1
    fi

    print_step "Applying Hummingbird demo manifests..."
    oc apply -f "${SCRIPT_DIR}/manifests/namespace.yaml"
    oc apply -f "${SCRIPT_DIR}/manifests/hi-base-deployment.yaml"

    # Patch base deployment image if overridden
    if [ "${HI_BASE_IMAGE}" != "registry.access.redhat.com/hi/python:3.13" ]; then
        oc set image "deployment/hi-python-base" -n "${HUMMINGBIRD_NAMESPACE}" \
            "python=${HI_BASE_IMAGE}" 2>/dev/null || true
    fi

    local layered_image="${HI_LAYERED_IMAGE}"
    if [ -z "${layered_image}" ]; then
        oc apply -f "${SCRIPT_DIR}/manifests/imagestream.yaml"
        oc apply -f "${SCRIPT_DIR}/manifests/buildconfig.yaml"

        if [ "${HUMMINGBIRD_BUILD_ON_CLUSTER:-1}" = "1" ]; then
            print_step "Starting layered image build from local context..."
            if oc start-build hi-python-demo -n "${HUMMINGBIRD_NAMESPACE}" \
                --from-dir="${SCRIPT_DIR}" --wait=false 2>/dev/null; then
                wait_for_build "${HUMMINGBIRD_NAMESPACE}" "hi-python-demo" || \
                    print_warn "In-cluster build failed — set HI_LAYERED_IMAGE to a pre-built image"
            else
                print_warn "Could not start binary build; set HI_LAYERED_IMAGE to a pre-built layered image"
            fi
        fi

        oc apply -f "${SCRIPT_DIR}/manifests/hi-layered-deployment.yaml"
        layered_image="image-registry.openshift-image-registry.svc:5000/${HUMMINGBIRD_NAMESPACE}/hi-python-demo:latest"
    else
        print_info "Using external layered image: ${layered_image}"
        oc apply -f "${SCRIPT_DIR}/manifests/hi-layered-deployment.yaml"
        oc set image "deployment/hi-python-layered" -n "${HUMMINGBIRD_NAMESPACE}" \
            "app=${layered_image}" 2>/dev/null || true
    fi

    print_step "Waiting for demo deployments..."
    oc rollout status deployment/hi-python-base -n "${HUMMINGBIRD_NAMESPACE}" --timeout=180s 2>/dev/null || \
        print_warn "hi-python-base rollout still in progress"
    oc rollout status deployment/hi-python-layered -n "${HUMMINGBIRD_NAMESPACE}" --timeout=300s 2>/dev/null || \
        print_warn "hi-python-layered rollout still in progress (build may be running)"

    print_info ""
    local central_url api_host api_v2
    central_url=$(get_central_url) || true
    if [ -n "${central_url}" ]; then
        api_host="${central_url#https://}"
        api_host="${api_host#http://}"
        api_v2="https://${api_host}/v2"
        register_base_image "${token}" "${api_v2}"
    fi

    print_info ""
    scan_image "${HI_BASE_IMAGE}" "Hummingbird base"
    if [ -n "${layered_image}" ]; then
        scan_image "${layered_image}" "Hummingbird layered app"
    fi

    print_info ""
    print_info "=========================================="
    print_info "Hummingbird Demo Deployment Complete"
    print_info "=========================================="
    print_info "  Namespace: ${HUMMINGBIRD_NAMESPACE}"
    print_info "  Base image: ${HI_BASE_IMAGE}"
    print_info "  Layered image: ${layered_image:-<ImageStreamTag>}"
    print_info ""
    print_info "In RHACS: Vulnerability Management → compare base vs application layer CVEs"
    print_info "  (requires ROX_POLICY_FILTERS_UI=enabled from script 08)"
    print_info ""
}

main "$@"
