#!/usr/bin/env bash
# Register platform base-image repositories with RHACS (idempotent: 409 is OK).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../env.sh"

: "${REG:?Set REG}"
: "${CENTRAL_ROUTE:?Set CENTRAL_ROUTE}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"

echo "==> Registering base images in RHACS"
# RHACS tag patterns are path globs. Use * to match every tag. .* matches only tags that start with ".".
# path|pattern
REFS=(
    "${REG}/base-eap8|*"
    "${REG}/base-ubi9-openjdk|*"
    "registry.redhat.io/ubi9/openjdk-17-runtime|1.18-4"
    "registry.redhat.io/amq-streams/kafka-38-rhel9|2.8.0"
)

for ref in "${REFS[@]}"; do
    path="${ref%%|*}"
    PATTERN="${ref#*|}"
    repo="${path}"
    current=$(rox "https://${CENTRAL_ROUTE}/v2/baseimages" 2>/dev/null || echo '{}')
    id=$(echo "$current" | jq -r --arg path "$path" '.baseImageReferences[]? | select(.baseImageRepoPath == $path) | .id' | head -1)
    existing_pattern=$(echo "$current" | jq -r --arg path "$path" '.baseImageReferences[]? | select(.baseImageRepoPath == $path) | .baseImageTagPattern' | head -1)
    if [[ -n "$id" ]]; then
        result=$(rox "https://${CENTRAL_ROUTE}/v2/baseimages/${id}" -X PUT -H 'Content-Type: application/json' \
            -d "{\"id\":\"${id}\",\"baseImageTagPattern\":\"${PATTERN}\"}" 2>/dev/null || true)
        if echo "$result" | jq -e 'type == "object"' >/dev/null 2>&1 && ! echo "$result" | jq -e '.message' >/dev/null 2>&1; then
            if [[ "$existing_pattern" == "$PATTERN" ]]; then
                echo " ${repo}: refreshed watcher (${PATTERN})"
            else
                echo " ${repo}: updated tag pattern ${existing_pattern} -> ${PATTERN}"
            fi
        else
            echo " ${repo}: pattern update: $(echo "$result" | jq -r '.message // .' 2>/dev/null || echo "$result")"
        fi
        continue
    fi
    result=$(rox "https://${CENTRAL_ROUTE}/v2/baseimages" -X POST -H 'Content-Type: application/json' \
        -d "{\"baseImageRepoPath\":\"${path}\",\"baseImageTagPattern\":\"${PATTERN}\"}" 2>/dev/null || true)
    id=$(echo "$result" | jq -r '.baseImageReference.id // empty')
    msg=$(echo "$result" | jq -r '.message // empty')
    if [[ -n "$id" ]]; then
        echo " Registered ${repo} (ID: ${id})"
    elif echo "$result" | grep -qiE 'already exists|conflict|409'; then
        echo " ${repo}: already registered"
    else
        echo " ${repo}: ${msg:-already exists or error}"
    fi
done

echo ""
echo "==> Registered base images:"
rox "https://${CENTRAL_ROUTE}/v2/baseimages" | jq '[.baseImageReferences[]? | {path: .baseImageRepoPath, pattern: .baseImageTagPattern}]'
