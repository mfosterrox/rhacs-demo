#!/bin/bash
# Shared helpers for Project Hummingbird demo (deploy via demo-applications, RHACS registration).
# Sourced by 09-deploy-hummingbird-demo.sh.

HUMMINGBIRD_NAMESPACE="${HUMMINGBIRD_NAMESPACE:-hummingbird-demo}"
HI_BASE_IMAGE="${HI_BASE_IMAGE:-registry.access.redhat.com/hi/python:3.13}"
HI_LAYERED_IMAGE="${HI_LAYERED_IMAGE:-quay.io/mfoster/hi-python-demo:0.1.0}"

hummingbird_manifests_dir() {
    local demo_apps_dir="${1:-${DEMO_APPS_DIR:-${HOME}/demo-applications}}"
    echo "${demo_apps_dir}/k8s-deployment-manifests/hummingbird-demo"
}

wait_for_hummingbird_deployments() {
    print_step "Waiting for Hummingbird demo deployments..."
    oc rollout status deployment/hi-python-base -n "${HUMMINGBIRD_NAMESPACE}" --timeout=180s 2>/dev/null || \
        print_warn "hi-python-base rollout still in progress"
    oc rollout status deployment/hi-python-layered -n "${HUMMINGBIRD_NAMESPACE}" --timeout=300s 2>/dev/null || \
        print_warn "hi-python-layered rollout still in progress"
}

register_hummingbird_base_image() {
    local token="${1:-${ROX_API_TOKEN:-}}"
    local api_v2="${2:-}"

    if [ -z "${token}" ] || [ -z "${api_v2}" ]; then
        return 0
    fi

    local repo="${RHACS_BASE_IMAGE_REPO_PATH:-registry.access.redhat.com/hi/python}"
    local tag="${RHACS_BASE_IMAGE_TAG_PATTERN:-3.13}"

    print_step "Registering Hummingbird base image in RHACS..."

    local existing existing_id
    existing=$(curl -k -s -H "Authorization: Bearer ${token}" "${api_v2}/baseimages" 2>/dev/null || echo "")
    existing_id=$(echo "${existing}" | jq -r --arg repo "${repo}" --arg tag "${tag}" '
        .baseImageReferences[]? | select(.baseImageRepoPath == $repo and .baseImageTagPattern == $tag) | .id
    ' 2>/dev/null | head -1)

    if [ -z "${existing_id}" ] || [ "${existing_id}" = "null" ]; then
        existing_id=$(echo "${existing}" | jq -r --arg repo "${repo}" '
            .baseImageReferences[]? | select(.baseImageRepoPath == $repo) | .id
        ' 2>/dev/null | head -1)
    fi

    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        print_info "✓ Base image already registered: ${repo}:${tag} (id: ${existing_id})"
        return 0
    fi

    local payload http_code body
    payload=$(jq -n --arg repo "${repo}" --arg tag "${tag}" \
        '{baseImageRepoPath: $repo, baseImageTagPattern: $tag}')

    body=$(curl -k -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_v2}/baseimages" 2>/dev/null || echo "")
    http_code=$(echo "${body}" | tail -n1)
    body=$(echo "${body}" | sed '$d')

    if [ "${http_code}" = "200" ] || [ "${http_code}" = "201" ]; then
        print_info "✓ Registered base image ${repo}:${tag}"
        return 0
    fi

    if echo "${body}" | grep -qiE 'duplicate key|already exists|23505'; then
        print_info "✓ Base image already registered: ${repo}:${tag}"
        return 0
    fi

    print_warn "Base image registration returned HTTP ${http_code}"
    [ -n "${body}" ] && print_warn "Response: ${body:0:200}"
    return 0
}

print_hummingbird_ui_guidance() {
    local route_url
    route_url=$(oc get route hi-python-layered -n "${HUMMINGBIRD_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")

    print_info ""
    print_info "Hummingbird demo workloads (view in RHACS UI after sensor scan):"
    print_info "  Namespace: ${HUMMINGBIRD_NAMESPACE}"
    print_info "  Base deployment: hi-python-base → ${HI_BASE_IMAGE}"
    print_info "  Layered deployment: hi-python-layered → ${HI_LAYERED_IMAGE}"
    if [ -n "${route_url}" ]; then
        print_info "  Layered app route: ${route_url}"
    fi
    print_info ""
    print_info "In RHACS Central:"
    print_info "  Platform Configuration → Image base references → ${HI_BASE_IMAGE}"
    print_info "  Vulnerability Management → Workloads → namespace ${HUMMINGBIRD_NAMESPACE}"
    print_info "  Compare hi-python-base vs hi-python-layered for base vs application layer CVEs"
    print_info "  (enable ROX_POLICY_FILTERS_UI via script 08 for layer filtering in the UI)"
}
