#!/usr/bin/env bash
# Shared helpers for rhacs-demo shell scripts: print a copy-paste "To rerun" line on ERR or on demand.
#
# Typical usage (after set -euo pipefail):
#   _RHACS_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # scripts one level under repo root
#   # Repo-root scripts: _RHACS_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=setup-rerun-hint.sh
#   source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
#   setup_rerun_register "${BASH_SOURCE[0]}" "$@"
#
# If the script installs its own ERR trap, call setup_rerun_set_script "${BASH_SOURCE[0]}" "$@" instead,
# then invoke setup_rerun_hint_print from that trap (see basic-setup/06-trigger-compliance-scan.sh).
#
# After trap - ERR, re-arm the default with: setup_rerun_restore_trap

declare -a _SETUP_RERUN_ARGS=()
_SETUP_RERUN_SCRIPT=""

# Store script path and args without changing ERR (for scripts that install their own ERR trap).
setup_rerun_set_script() {
    local self="$1"
    shift || true
    _SETUP_RERUN_SCRIPT="$(cd "$(dirname "${self}")" && pwd)/$(basename "${self}")"
    _SETUP_RERUN_ARGS=("$@")
}

setup_rerun__emit() {
    if [ -z "${_SETUP_RERUN_SCRIPT:-}" ]; then
        return 0
    fi
    local d s cmd a
    d="$(dirname "${_SETUP_RERUN_SCRIPT}")"
    s="$(printf '%q' "${_SETUP_RERUN_SCRIPT}")"
    cmd="cd $(printf '%q' "${d}") && bash ${s}"
    for a in "${_SETUP_RERUN_ARGS[@]}"; do
        cmd+=" $(printf '%q' "${a}")"
    done
    echo "[INFO] To rerun this script: ${cmd}" >&2
}

setup_rerun_on_err_trap() {
    setup_rerun__emit
}

# Call after parsing args / at top level so "$@" matches how the script was invoked.
setup_rerun_register() {
    setup_rerun_set_script "$@"
    trap 'setup_rerun_on_err_trap' ERR
}

setup_rerun_restore_trap() {
    if [ -z "${_SETUP_RERUN_SCRIPT:-}" ]; then
        return 0
    fi
    trap 'setup_rerun_on_err_trap' ERR
}

# Print the same line without waiting for ERR (e.g. before explicit exit 1).
setup_rerun_hint_print() {
    setup_rerun__emit
}
