#!/usr/bin/env bash
#
# Splunk on OpenShift + RHACS TA-stackrox (wrapper for setup.sh).
#
# Requires: oc (logged in), jq, curl — same as setup.sh.
# Uses ROX_CENTRAL_ADDRESS and ROX_API_TOKEN from the environment (e.g. install-all-setup.sh).
#
# Optional env:
#   SPLUNK_RUN_CLEAN_FIRST — default false when using this wrapper (e.g. from install-all-setup.sh).
#       Matches “environment already up”: reuse Splunk namespace/PVCs and only reconcile install/settings.
#       Run splunk-setup/clean.sh yourself first, or export SPLUNK_RUN_CLEAN_FIRST=true here, for full teardown.
#   Other SPLUNK_* / RHACS_* vars — see splunk-setup/setup.sh header.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export SPLUNK_RUN_CLEAN_FIRST="${SPLUNK_RUN_CLEAN_FIRST:-false}"

exec bash "${SCRIPT_DIR}/setup.sh" "$@"
