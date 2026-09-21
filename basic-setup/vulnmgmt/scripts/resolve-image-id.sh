#!/usr/bin/env bash
# Resolve a Central image ID by registry remote and tag (not by Deployment).
# Sensor may not have linked shop-api to demo-dev yet; a name query plus scan
# still finds the image after setup or a presenter retry.
#
# Usage: resolve-image-id.sh [name[:tag]]
#   shop-api:1.0.0
#   mfoster/shop-api:1.0.0
#   quay.io/mfoster/shop-api:1.0.0
# Default: shop-api:1.0.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../env.sh"

: "${CENTRAL_ROUTE:?Set CENTRAL_ROUTE (source ~/.bashrc and vulnmgmt/env.sh)}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"
: "${REG:?Set REG}"
: "${REG_HOST:?Set REG_HOST}"
: "${IMAGE_REMOTE_SHOP_API:?Set IMAGE_REMOTE_SHOP_API}"

INPUT="${1:-shop-api:1.0.0}"
if [[ "${INPUT}" != *:* ]]; then
    INPUT="${INPUT}:1.0.0"
fi
TAG="${INPUT##*:}"
WITHOUT_TAG="${INPUT%:*}"
WITHOUT_TAG="${WITHOUT_TAG#https://}"
WITHOUT_TAG="${WITHOUT_TAG#http://}"

case "${WITHOUT_TAG}" in
    */*/*)
        REMOTE="${WITHOUT_TAG#*/}"
        ;;
    */*)
        REMOTE="${WITHOUT_TAG}"
        ;;
    *)
        REMOTE="${IMAGE_REMOTE_SHOP_API%/*}/${WITHOUT_TAG}"
        ;;
esac

FULL="${REG_HOST}/${REMOTE}:${TAG}"
NEEDLE="${REMOTE}:${TAG}"

list_images() {
    local query="$1"
    rox -G \
        --data-urlencode "query=${query}" \
        --data-urlencode "pagination.limit=200" \
        "https://${CENTRAL_ROUTE}/v1/images"
}

extract_id() {
    jq -r --arg needle "$NEEDLE" '
      def n: (.name.fullName // .name // "") | tostring;
      [.images[]?
        | select(
            (n | contains($needle))
            or ((.name.remote // "") + ":" + (.name.tag // "") == $needle)
          )
        | .id // empty]
      | map(select(. != null and . != "" and . != "null"))
      | .[0] // empty
    '
}

lookup() {
    local query="$1"
    local json id
    json=$(list_images "$query" || true)
    id=$(echo "$json" | extract_id || true)
    printf '%s' "$id"
}

ID="$(lookup "Image Remote:${REMOTE}+Image Tag:${TAG}")"
if [ -z "$ID" ]; then
    ID="$(lookup "Image:${FULL}")"
fi

if [ -z "$ID" ]; then
    if ! command -v roxctl >/dev/null 2>&1; then
        echo "ERROR: ${FULL} is not in Central yet and roxctl is not on PATH." >&2
        exit 1
    fi
    echo "Image ${FULL} is not in Central yet; scanning..." >&2
    if ! roxctl image scan --endpoint "${ROX_ENDPOINT}" --token-file <(echo "$ROX_API_TOKEN") \
        --image "${FULL}" --force --insecure-skip-tls-verify -o json >/dev/null; then
        echo "ERROR: scan failed for ${FULL}. Confirm the image exists and Sensor/Central can pull it." >&2
        exit 1
    fi
    sleep 2
    ID="$(lookup "Image Remote:${REMOTE}+Image Tag:${TAG}")"
    if [ -z "$ID" ]; then
        ID="$(lookup "Image:${FULL}")"
    fi
fi

if [ -z "$ID" ]; then
    echo "ERROR: could not resolve Central image ID for ${FULL}." >&2
    echo "Re-run basic-setup/10-deploy-vulnmgmt-demo.sh, then source ~/.bashrc and vulnmgmt/env.sh." >&2
    exit 1
fi

printf '%s\n' "$ID"
