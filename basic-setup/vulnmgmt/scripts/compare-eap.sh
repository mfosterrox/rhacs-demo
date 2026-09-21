#!/usr/bin/env bash
# D3: Compare Scanner V4 results between official Red Hat product image
# (content manifests -> Red Hat VEX filtering) and repacked variant
# (same JARs, no manifests -> upstream CVEs).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../env.sh"

: "${REG:?Set REG (expected quay.io/mfoster)}"
: "${ROX_ENDPOINT:?Set ROX_ENDPOINT}"
: "${ROX_API_TOKEN:?Set ROX_API_TOKEN}"

OFFICIAL="${REG}/base-eap8:1.0"
REPACKED="${REG}/base-eap8-repacked:1.0"
OUT_DIR="${SCRIPT_DIR}/../output"
mkdir -p "$OUT_DIR"

echo "==> Scanning official image: ${OFFICIAL}"
roxctl image scan --endpoint "${ROX_ENDPOINT}" --token-file <(echo "$ROX_API_TOKEN") \
  --image "$OFFICIAL" --force --insecure-skip-tls-verify -o json 2>/dev/null > "$OUT_DIR/eap8-official.json"

echo "==> Scanning repacked image: ${REPACKED}"
roxctl image scan --endpoint "${ROX_ENDPOINT}" --token-file <(echo "$ROX_API_TOKEN") \
  --image "$REPACKED" --force --insecure-skip-tls-verify -o json 2>/dev/null > "$OUT_DIR/eap8-repacked.json"

echo ""
echo "=============================="
echo " OFFICIAL (Red Hat VEX active)"
echo "=============================="
jq -r '.result.summary | to_entries | .[] | " \(.key): \(.value)"' "$OUT_DIR/eap8-official.json"

echo ""
echo "=============================="
echo " REPACKED (no content manifests)"
echo "=============================="
jq -r '.result.summary | to_entries | .[] | " \(.key): \(.value)"' "$OUT_DIR/eap8-repacked.json"

echo ""
echo "=============================="
echo " JAVA component CVE comparison"
echo "=============================="

OFFICIAL_JAVA_CVES=$(jq '[.result.vulnerabilities[] | select(.componentName | test("^(com\\.|org\\.|io\\.|net\\.)")) | .cveId] | unique | length' "$OUT_DIR/eap8-official.json")
REPACKED_JAVA_CVES=$(jq '[.result.vulnerabilities[] | select(.componentName | test("^(com\\.|org\\.|io\\.|net\\.)")) | .cveId] | unique | length' "$OUT_DIR/eap8-repacked.json")

echo " Official Java CVEs: ${OFFICIAL_JAVA_CVES}"
echo " Repacked Java CVEs: ${REPACKED_JAVA_CVES}"
echo " Delta (FPs avoided by VEX): $(( REPACKED_JAVA_CVES - OFFICIAL_JAVA_CVES ))"

echo ""
echo "=============================="
echo " Sample: CVEs only in repacked (false positives)"
echo "=============================="
OFFICIAL_CVES=$(jq -r '[.result.vulnerabilities[].cveId] | unique | .[]' "$OUT_DIR/eap8-official.json")
REPACKED_CVES=$(jq -r '[.result.vulnerabilities[].cveId] | unique | .[]' "$OUT_DIR/eap8-repacked.json")

comm -23 <(echo "$REPACKED_CVES" | sort) <(echo "$OFFICIAL_CVES" | sort) | head -10

echo ""
echo "Full scan results saved to ${OUT_DIR}/"
