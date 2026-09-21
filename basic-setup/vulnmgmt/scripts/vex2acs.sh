#!/usr/bin/env bash
# D4: Translate OpenVEX statements into RHACS vulnerability exceptions.
# Usage: vex2acs.sh [<vex-file.json>] [--approve]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../env.sh"

: "${CENTRAL_ROUTE:?Set CENTRAL_ROUTE}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"
: "${REG_HOST:=quay.io}"
: "${IMAGE_REMOTE_SHOP_API:=mfoster/shop-api}"

AUTO_APPROVE=""
VEX_FILE=""
for arg in "$@"; do
    if [[ "$arg" == "--approve" ]]; then
        AUTO_APPROVE="--approve"
    elif [[ -z "$VEX_FILE" ]]; then
        VEX_FILE="$arg"
    fi
done
if [[ -z "$VEX_FILE" ]]; then
    VEX_FILE="${SCRIPT_DIR}/../vex/shop.openvex.json"
fi
if [[ ! -f "$VEX_FILE" ]]; then
    echo "ERROR: VEX file not found: ${VEX_FILE}" >&2
    echo "Usage: vex2acs.sh [<vex-file.json>] [--approve]" >&2
    exit 1
fi

STATE_FILE="$(dirname "$VEX_FILE")/state.json"
[[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"

rox_req() { curl -sk -H "Authorization: Bearer $ROX_API_TOKEN" "$@"; }
rox_approver() { curl -sk -H "Authorization: Bearer ${APPROVER_TOKEN:-$ROX_API_TOKEN}" "$@"; }

lookup_exception_id() {
    local cve="$1"
    rox_req "https://${CENTRAL_ROUTE}/v2/vulnerability-exceptions" | \
        jq -r --arg cve "$cve" '[.exceptions[]? | select(.cves[]? == $cve) | .id // .name] | first // empty'
}

echo "==> Processing VEX file: ${VEX_FILE}"
echo "    registry=${REG_HOST} remote=${IMAGE_REMOTE_SHOP_API} tag=.*"

STATEMENTS=$(jq -c '.statements[]' "$VEX_FILE")

while IFS= read -r stmt; do
    CVE=$(echo "$stmt" | jq -r '.vulnerability.name')
    STATUS=$(echo "$stmt" | jq -r '.status')
    JUSTIFICATION=$(echo "$stmt" | jq -r '.justification // empty')
    IMPACT=$(echo "$stmt" | jq -r '.impact_statement // empty')
    ACTION=$(echo "$stmt" | jq -r '.action_statement // empty')

    STATE_KEY="${CVE}"
    EXISTING_ID=$(jq -r --arg k "$STATE_KEY" '.[$k] // empty' "$STATE_FILE")
    if [[ -z "$EXISTING_ID" ]]; then
        EXISTING_ID=$(lookup_exception_id "$CVE")
        if [[ -n "$EXISTING_ID" ]]; then
            jq --arg k "$STATE_KEY" --arg v "$EXISTING_ID" '. + {($k): $v}' "$STATE_FILE" > "${STATE_FILE}.tmp" \
                && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
    fi

    if [[ -n "$EXISTING_ID" ]]; then
        echo " ${CVE}: already tracked (ID: ${EXISTING_ID})"
        if [[ "$AUTO_APPROVE" == "--approve" ]]; then
            APPROVE_RESULT=$(rox_approver "https://${CENTRAL_ROUTE}/v2/vulnerability-exceptions/${EXISTING_ID}/approve" \
                -X POST -H 'Content-Type: application/json' -d '{"comment":"Auto-approved from VEX pipeline"}' || true)
            APPROVE_STATUS=$(echo "$APPROVE_RESULT" | jq -r '.exception.status // empty')
            if [[ -n "$APPROVE_STATUS" ]]; then
                echo " Approved: ${APPROVE_STATUS}"
            else
                echo " Approve skipped or already approved: $(echo "$APPROVE_RESULT" | jq -r '.message // "ok"')"
            fi
        fi
        continue
    fi

    RESULT=""
    case "$STATUS" in
        not_affected|fixed)
            echo " ${CVE}: creating FALSE POSITIVE (${JUSTIFICATION})"
            COMMENT="OpenVEX: ${STATUS} -- ${JUSTIFICATION}${IMPACT:+ -- ${IMPACT}}"
            RESULT=$(rox_req "https://${CENTRAL_ROUTE}/v2/vulnerability-exceptions/false-positive" \
                -X POST -H 'Content-Type: application/json' -d "{
                    \"cves\": [\"${CVE}\"],
                    \"comment\": \"${COMMENT}\",
                    \"scope\": {
                        \"imageScope\": {
                            \"registry\": \"${REG_HOST}\",
                            \"remote\": \"${IMAGE_REMOTE_SHOP_API}\",
                            \"tag\": \".*\"
                        }
                    }
                }")
            ;;
        affected|under_investigation)
            EXPIRY_DATE=$(echo "$ACTION" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
            if [[ -n "$EXPIRY_DATE" ]]; then
                EXPIRY_JSON="\"exceptionExpiry\": {\"expiryType\": \"TIME\", \"expiresOn\": \"${EXPIRY_DATE}T00:00:00Z\"}"
            else
                EXPIRY_JSON="\"exceptionExpiry\": {\"expiryType\": \"ALL_CVE_FIXABLE\"}"
            fi
            echo " ${CVE}: creating DEFERRAL (${ACTION:-under investigation})"
            COMMENT="OpenVEX: ${STATUS}${ACTION:+ -- ${ACTION}}"
            RESULT=$(rox_req "https://${CENTRAL_ROUTE}/v2/vulnerability-exceptions/deferral" \
                -X POST -H 'Content-Type: application/json' -d "{
                    \"cves\": [\"${CVE}\"],
                    \"comment\": \"${COMMENT}\",
                    \"scope\": {
                        \"imageScope\": {
                            \"registry\": \"${REG_HOST}\",
                            \"remote\": \"${IMAGE_REMOTE_SHOP_API}\",
                            \"tag\": \".*\"
                        }
                    },
                    ${EXPIRY_JSON}
                }")
            ;;
        *)
            echo " ${CVE}: unknown status '${STATUS}', skipping"
            continue
            ;;
    esac

    EXCEPTION_ID=$(echo "$RESULT" | jq -r '.exception.id // empty')
    if [[ -z "$EXCEPTION_ID" ]]; then
        echo " ERROR: $(echo "$RESULT" | jq -r '.message // "unknown error"')"
        EXISTING_ID=$(lookup_exception_id "$CVE")
        if [[ -n "$EXISTING_ID" ]]; then
            echo " Found existing exception ${EXISTING_ID}"
            jq --arg k "$STATE_KEY" --arg v "$EXISTING_ID" '. + {($k): $v}' "$STATE_FILE" > "${STATE_FILE}.tmp" \
                && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
        continue
    fi

    jq --arg k "$STATE_KEY" --arg v "$EXCEPTION_ID" '. + {($k): $v}' "$STATE_FILE" > "${STATE_FILE}.tmp" \
        && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    echo " Created exception ${EXCEPTION_ID}"

    if [[ "$AUTO_APPROVE" == "--approve" ]]; then
        APPROVE_RESULT=$(rox_approver "https://${CENTRAL_ROUTE}/v2/vulnerability-exceptions/${EXCEPTION_ID}/approve" \
            -X POST -H 'Content-Type: application/json' -d '{"comment":"Auto-approved from VEX pipeline"}')
        APPROVE_STATUS=$(echo "$APPROVE_RESULT" | jq -r '.exception.status // empty')
        echo " Approved: ${APPROVE_STATUS}"
    fi

done <<< "$STATEMENTS"

echo ""
echo "==> Exception state saved to ${STATE_FILE}"
jq . "$STATE_FILE"
