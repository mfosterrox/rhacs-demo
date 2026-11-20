#!/bin/bash
# Register RHACS base image references (v2 API) for layer filtering in vulnerability results.
#
# Default references (repo|tag, space-separated via RHACS_BASE_IMAGE_REFERENCES):
#   - registry.access.redhat.com/hi/python:3.13  (Hummingbird / HI demo)
#   - docker.io/library/python:3.12-alpine        (medical-app frontend and similar)
#
# Requires: print_info, print_warn, print_error, print_step (from calling script)

# Legacy single-image overrides (included in defaults when RHACS_BASE_IMAGE_REFERENCES is unset)
RHACS_BASE_IMAGE_REPO_PATH="${RHACS_BASE_IMAGE_REPO_PATH:-registry.access.redhat.com/hi/python}"
RHACS_BASE_IMAGE_TAG_PATTERN="${RHACS_BASE_IMAGE_TAG_PATTERN:-3.13}"

rhacs_default_base_image_references() {
    if [ -n "${RHACS_BASE_IMAGE_REFERENCES:-}" ]; then
        echo "${RHACS_BASE_IMAGE_REFERENCES}"
        return 0
    fi
    printf '%s\n' \
        "${RHACS_BASE_IMAGE_REPO_PATH}|${RHACS_BASE_IMAGE_TAG_PATTERN}" \
        "docker.io/library/python|3.12-alpine"
}

register_rhacs_base_image_reference() {
    local token="$1"
    local api_v2="$2"
    local repo="$3"
    local tag="$4"
    local existing="${5:-}"

    # Tag patterns are Go path globs (* and ?), not regular expressions.
    # "*" matches every tag. ".*" matches only tags that start with a dot.
    local existing_id current_pattern
    existing_id=$(echo "${existing}" | jq -r --arg repo "${repo}" --arg tag "${tag}" '
        .baseImageReferences[]? | select(.baseImageRepoPath == $repo and .baseImageTagPattern == $tag) | .id
    ' 2>/dev/null | head -1)

    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        # PUT resets the repository to CREATED even when the pattern is unchanged,
        # so a rebuilt tag is indexed on the next watcher pass instead of waiting hours.
        print_info "Refreshing base image reference: ${repo}:${tag} (id: ${existing_id})"
        local refresh_body refresh_code
        refresh_body=$(curl -k -s -w "\n%{http_code}" -X PUT \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"${existing_id}\",\"baseImageTagPattern\":\"${tag}\"}" \
            "${api_v2}/baseimages/${existing_id}" 2>/dev/null || echo "")
        refresh_code=$(echo "${refresh_body}" | tail -n1)
        if [ "${refresh_code}" -ge 200 ] && [ "${refresh_code}" -lt 300 ]; then
            print_info "✓ Base image reference refreshed: ${repo}:${tag}"
            return 0
        fi
        print_warn "Base image reference refresh failed for ${repo}:${tag} (HTTP ${refresh_code}); leaving the existing reference"
        return 0
    fi

    existing_id=$(echo "${existing}" | jq -r --arg repo "${repo}" '
        .baseImageReferences[]? | select(.baseImageRepoPath == $repo) | .id
    ' 2>/dev/null | head -1)
    current_pattern=$(echo "${existing}" | jq -r --arg repo "${repo}" '
        .baseImageReferences[]? | select(.baseImageRepoPath == $repo) | .baseImageTagPattern
    ' 2>/dev/null | head -1)

    if [ -n "${existing_id}" ] && [ "${existing_id}" != "null" ]; then
        print_info "Updating base image tag pattern: ${repo} ${current_pattern} -> ${tag}"
        local update_body update_code
        update_body=$(curl -k -s -w "\n%{http_code}" -X PUT \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d "{\"id\":\"${existing_id}\",\"baseImageTagPattern\":\"${tag}\"}" \
            "${api_v2}/baseimages/${existing_id}" 2>/dev/null || echo "")
        update_code=$(echo "${update_body}" | tail -n1)
        update_body=$(echo "${update_body}" | sed '$d')
        if [ "${update_code}" -ge 200 ] && [ "${update_code}" -lt 300 ]; then
            print_info "✓ Base image tag pattern updated: ${repo}:${tag} (id: ${existing_id})"
            print_info "RHACS base image watcher will re-index this repository on its next pass"
            return 0
        fi
        print_error "Failed to update base image tag pattern ${repo}:${tag} (HTTP ${update_code})"
        [ -n "${update_body}" ] && print_error "Response: ${update_body:0:300}"
        return 1
    fi

    local payload http_code body created_id
    payload=$(jq -n --arg repo "${repo}" --arg tag "${tag}" \
        '{baseImageRepoPath: $repo, baseImageTagPattern: $tag}')

    print_info "Creating base image reference: ${repo}:${tag}"

    body=$(curl -k -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${api_v2}/baseimages" 2>/dev/null || echo "")
    http_code=$(echo "${body}" | tail -n1)
    body=$(echo "${body}" | sed '$d')

    if [ "${http_code}" -ge 200 ] && [ "${http_code}" -lt 300 ]; then
        created_id=$(echo "${body}" | jq -r '.baseImageReference.id // empty' 2>/dev/null)
        if [ -n "${created_id}" ]; then
            print_info "✓ Base image registered: ${repo}:${tag} (id: ${created_id})"
        else
            print_info "✓ Base image registered: ${repo}:${tag}"
        fi
        return 0
    fi

    if echo "${body}" | grep -qiE 'duplicate key|already exists|23505'; then
        print_info "✓ Base image already registered: ${repo}:${tag}"
        return 0
    fi

    print_error "Failed to create base image reference ${repo}:${tag} (HTTP ${http_code})"
    [ -n "${body}" ] && print_error "Response: ${body:0:300}"
    return 1
}

register_rhacs_base_images() {
    local token="$1"
    local api_v2="$2"
    local refs ref repo tag existing failures=0

    existing=$(curl -k -s -H "Authorization: Bearer ${token}" "${api_v2}/baseimages" 2>/dev/null || echo "")

    while IFS= read -r ref; do
        [ -z "${ref}" ] && continue
        repo="${ref%%|*}"
        tag="${ref#*|}"
        if [ -z "${repo}" ] || [ -z "${tag}" ] || [ "${repo}" = "${ref}" ]; then
            print_warn "Skipping invalid base image reference (expected repo|tag): ${ref}"
            continue
        fi
        if ! register_rhacs_base_image_reference "${token}" "${api_v2}" "${repo}" "${tag}" "${existing}"; then
            failures=$((failures + 1))
        fi
    done < <(rhacs_default_base_image_references)

    if [ "${failures}" -gt 0 ]; then
        print_error "Ensure the API token has ImageAdministration permission (Admin or Analyst role)"
        return 1
    fi

    print_info "RHACS refreshes base image metadata from registries every 4 hours"
    return 0
}
