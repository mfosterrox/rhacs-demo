#!/usr/bin/env bash
#
# Splunk on OpenShift + RHACS TA-stackrox (wrapper for setup.sh).
#
# Requires: oc (logged in), jq, curl — same as setup.sh.
# Uses ROX_CENTRAL_ADDRESS and ROX_API_TOKEN from the environment (e.g. install-all-setup.sh).
#
# Optional env:
#   SPLUNK_RUN_CLEAN_FIRST — passed through (default here: false so install-all does not delete the
#       splunk namespace on every full-demo run). Set true for a clean reinstall.
#   Other SPLUNK_* / RHACS_* vars — see splunk-setup/setup.sh header.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SPLUNK_RUN_CLEAN_FIRST="${SPLUNK_RUN_CLEAN_FIRST:-false}"

exec bash "${SCRIPT_DIR}/setup.sh" "$@"
