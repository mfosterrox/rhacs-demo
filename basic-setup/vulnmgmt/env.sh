#!/usr/bin/env bash
# Source-able environment for Module 07 GitOps vulnerability-management helpers.
# Values are cluster-specific -- do not commit real tokens.

if [[ -z "${ROX_API_TOKEN:-}" || -z "${ROX_CENTRAL_ADDRESS:-}" || -z "${TEAM_A_TOKEN:-}" || -z "${APPROVER_TOKEN:-}" ]] \
    && [[ -f "${HOME}/.bashrc" ]]; then
    _env_sh_had_nounset=0
    case $- in *u*) _env_sh_had_nounset=1; set +u ;; esac
    # Parse instead of source to avoid /etc/bashrc exits
    for _var in ROX_API_TOKEN ROX_CENTRAL_ADDRESS RHACS_NAMESPACE TEAM_A_TOKEN APPROVER_TOKEN REG REG_HOST IMAGE_REMOTE_SHOP_API; do
        _line=$(grep -E "^(export[[:space:]]+)?${_var}=" "${HOME}/.bashrc" 2>/dev/null | head -1 || true)
        if [[ -n "${_line}" ]]; then
            [[ "${_line}" =~ ^export[[:space:]]+ ]] || _line="export ${_line}"
            eval "${_line}" 2>/dev/null || true
        fi
    done
    unset _var _line
    if [[ "${_env_sh_had_nounset}" -eq 1 ]]; then
        set -u
    fi
    unset _env_sh_had_nounset
fi

: "${REG:=quay.io/mfoster}"
: "${REG_HOST:=quay.io}"
: "${IMAGE_REMOTE_SHOP_API:=mfoster/shop-api}"
: "${RHACS_NAMESPACE:=stackrox}"
export REG REG_HOST IMAGE_REMOTE_SHOP_API RHACS_NAMESPACE

if [[ -z "${ROX_CENTRAL_ADDRESS:-}" ]] && command -v oc >/dev/null 2>&1; then
    _detected=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "${_detected}" ]]; then
        ROX_CENTRAL_ADDRESS="${_detected}"
    fi
    unset _detected
fi

if [[ -n "${ROX_CENTRAL_ADDRESS:-}" ]]; then
    export ROX_CENTRAL_ADDRESS
    _host="${ROX_CENTRAL_ADDRESS#https://}"
    _host="${_host#http://}"
    CENTRAL_ROUTE="${_host%%:*}"
    export CENTRAL_ROUTE
    if [[ "${_host}" == *:* ]]; then
        ROX_ENDPOINT="${_host}"
    else
        ROX_ENDPOINT="${_host}:443"
    fi
    export ROX_ENDPOINT
    unset _host
fi

if [[ -z "${ROX_API_TOKEN:-}" ]]; then
    echo "WARNING: ROX_API_TOKEN is not set. Export it or add it to ~/.bashrc." >&2
fi

rox() { curl -sk -H "Authorization: Bearer ${ROX_API_TOKEN}" "$@"; }
export -f rox

if [[ -n "${TEAM_A_TOKEN:-}" ]]; then
    export TEAM_A_TOKEN
fi
if [[ -n "${APPROVER_TOKEN:-}" ]]; then
    export APPROVER_TOKEN
fi
