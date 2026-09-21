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

for repo in base-eap8 base-ubi9-openjdk; do
    result=$(rox "https://${CENTRAL_ROUTE}/v2/baseimages" -X POST -H 'Content-Type: application/json' \
        -d "{\"baseImageRepoPath\":\"${REG}/${repo}\",\"baseImageTagPattern\":\".*\"}" 2>/dev/null || true)
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
