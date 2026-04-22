#!/usr/bin/env bash
#
# Run basic-setup first (sequential), then the other *-setup installs in parallel (FAM, monitoring,
# MCP, OpenShift Pipelines/Tekton RHACS tasks, and GitOps-deployed RHACS custom policies).
# Order avoids RHACS Central churn (e.g. upgrades/restarts) while other scripts use the API.
#
# Typical usage:
#   ./install-all-setup.sh -p '<rhacs-admin-password>'
#   ./install-all-setup.sh '<rhacs-admin-password>'    # same (first positional arg = password)
#
# Prerequisites: oc (logged in), jq
#
# Options:
#   -p <password>   RHACS admin password (sets ROX_PASSWORD; used to generate ROX_API_TOKEN)
#   <password>       If the only argument and it does not start with -, treated as ROX_PASSWORD
#   -h, --help      Show this help
#
# If ROX_API_TOKEN is already exported, -p is optional.
#
# Optional skip flags (export before running):
#   SKIP_OPENSHIFT_PIPELINES_SETUP=1 — do not run openshift-pipelines-setup/install.sh (Tekton / rox-pipeline)
#   SKIP_CUSTOM_POLICIES_SETUP=1 — do not run custom-policies/install.sh (OpenShift GitOps / Argo CD)
#
# After install: ./verify-all-setup.sh
#
# On failure, the error output includes a copy-paste "To rerun" command for the phase or parallel job.
#
# Phase 2 progress (long waits / SSH): each job prints when it exits; every INSTALL_ALL_PARALLEL_PROGRESS_SEC
# (default 45) a line lists jobs still running. Tune with INSTALL_ALL_PARALLEL_POLL_SEC (default 3).
#
# Phase 1 (basic-setup) streams to your terminal and to .setup-parallel-logs/basic-setup.log so
# long runs do not look hung over SSH; parallel phases still log only to per-job files until they finish.
# --- end help ---

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-${REPO_ROOT}/.setup-parallel-logs}"
mkdir -p "${LOG_DIR}"

if [ -f "${REPO_ROOT}/setup-rerun-hint.sh" ]; then
    # shellcheck disable=SC1090
    source "${REPO_ROOT}/setup-rerun-hint.sh"
    setup_rerun_register "${BASH_SOURCE[0]}" "$@"
fi

NONINTERACTIVE="${INSTALL_ALL_NONINTERACTIVE:-0}"

usage() {
    sed -n '2,/^# --- end help ---$/p' "$0" | sed 's/^# \{0,1\}//' | sed '/^--- end help ---$/d'
}

prompt_if_missing() {
    local vn="$1"
    local prompt_text="$2"
    local is_secret="${3:-false}"
    if [ -n "${!vn:-}" ]; then
        return 0
    fi
    if [ "${NONINTERACTIVE}" = "1" ]; then
        print_error "${vn} is required (set ${vn} or unset INSTALL_ALL_NONINTERACTIVE)"
        return 1
    fi
    local val=""
    if [ "${is_secret}" = true ]; then
        read -r -s -p "${prompt_text}" val
        echo "" >&2
    else
        read -r -p "${prompt_text}" val
    fi
    if [ -z "${val}" ]; then
        print_error "${vn} cannot be empty"
        return 1
    fi
    printf -v "${vn}" '%s' "${val}"
    export "${vn}"
}

generate_rox_api_token() {
    local central_url="${ROX_CENTRAL_ADDRESS:-}"
    local password="${ROX_PASSWORD:-}"
    if [ -z "${central_url}" ] || [ -z "${password}" ]; then
        return 1
    fi
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local response
    response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"install-all-setup-'$(date +%s)'","roles":["Admin"]}' 2>/dev/null)
    local http_code
    http_code=$(echo "${response}" | tail -n1)
    local body
    body=$(echo "${response}" | sed '$d')
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    local token
    token=$(echo "${body}" | jq -r '.token' 2>/dev/null)
    if [ -z "${token}" ] || [ "${token}" = "null" ] || [ ${#token} -lt 20 ]; then
        return 1
    fi
    printf '%s' "${token}"
}

ensure_rox_api_token() {
    if [ -n "${ROX_API_TOKEN:-}" ]; then
        print_info "ROX_API_TOKEN is already set"
        export ROX_API_TOKEN
        return 0
    fi
    if [ -z "${ROX_PASSWORD:-}" ] || [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        print_error "ROX_API_TOKEN is not set, and ROX_CENTRAL_ADDRESS/ROX_PASSWORD are missing for token generation."
        return 1
    fi
    print_step "Generating ROX_API_TOKEN from RHACS Central..."
    local token
    token=$(generate_rox_api_token) || {
        print_error "Failed to generate ROX_API_TOKEN. Check ROX_PASSWORD and ROX_CENTRAL_ADDRESS."
        return 1
    }
    export ROX_API_TOKEN="${token}"
    print_info "ROX_API_TOKEN generated (${#token} chars)"
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -p)
                if [ -z "${2:-}" ]; then
                    print_error "-p requires a password argument"
                    exit 1
                fi
                export ROX_PASSWORD="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                print_error "Unknown option: $1 (use -h for help)"
                exit 1
                ;;
            *)
                if [ -n "${ROX_PASSWORD:-}" ]; then
                    print_error "Unexpected argument: $1 (password already set via -p or environment)"
                    exit 1
                fi
                export ROX_PASSWORD="$1"
                shift
                ;;
        esac
    done

    print_step "RHACS demo — parallel *-setup install"
    echo ""

    if ! command -v oc &>/dev/null; then
        print_error "oc CLI not found"
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into a cluster. Run: oc login"
        exit 1
    fi
    if ! command -v jq &>/dev/null; then
        print_error "jq is required (for API token generation). Install jq and retry."
        exit 1
    fi

    RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
    export RHACS_NAMESPACE

    # ---- Core RHACS ----
    if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        if [ "${NONINTERACTIVE}" = "1" ]; then
            print_error "ROX_CENTRAL_ADDRESS is required when INSTALL_ALL_NONINTERACTIVE=1"
            exit 1
        fi
        print_info "ROX_CENTRAL_ADDRESS not set; attempting discovery from cluster..."
        ROX_CENTRAL_ADDRESS=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || true)
        export ROX_CENTRAL_ADDRESS
    fi
    if [ -z "${ROX_CENTRAL_ADDRESS:-}" ]; then
        prompt_if_missing ROX_CENTRAL_ADDRESS "RHACS Central URL (https://…): " || exit 1
    fi

    case "${ROX_CENTRAL_ADDRESS}" in
        http://*|https://*) ;;
        *) print_warn "ROX_CENTRAL_ADDRESS should usually start with https://" ;;
    esac

    if [ -z "${ROX_API_TOKEN:-}" ] && [ -z "${ROX_PASSWORD:-}" ]; then
        if [ "${NONINTERACTIVE}" = "1" ]; then
            print_error "Set ROX_API_TOKEN or ROX_PASSWORD (or use -p <password>)"
            exit 1
        fi
        prompt_if_missing ROX_PASSWORD "RHACS admin password (or set ROX_API_TOKEN to skip): " true || exit 1
    fi

    ensure_rox_api_token || exit 1

    export GRPC_ENFORCE_ALPN_ENABLED="${GRPC_ENFORCE_ALPN_ENABLED:-false}"

    export ROX_CENTRAL_ADDRESS ROX_PASSWORD ROX_API_TOKEN RHACS_NAMESPACE RHACS_ROUTE_NAME \
        MCP_NAMESPACE PIPELINE_NAMESPACE

    echo ""
    print_step "Setup phases (logs under ${LOG_DIR})..."
    echo ""

    # Phase 1: basic-setup alone so RHACS configuration / version settles before API-heavy demos
    if [ "${SKIP_BASIC_SETUP:-0}" != "1" ]; then
        print_step "Phase 1: basic-setup (sequential)"
        local basic_log="${LOG_DIR}/basic-setup.log"
        print_info "Streaming output here and to ${basic_log} (this phase often runs several minutes)."
        set +e
        (
            cd "${REPO_ROOT}"
            exec bash "${REPO_ROOT}/basic-setup/install.sh"
        ) 2>&1 | tee "${basic_log}"
        local basic_ec="${PIPESTATUS[0]}"
        set -e
        if [ "${basic_ec}" -ne 0 ]; then
            print_error "✗ basic-setup failed (exit ${basic_ec}); see ${basic_log}"
            print_info "To rerun Phase 1: cd \"${REPO_ROOT}\" && bash basic-setup/install.sh"
            exit 1
        fi
        print_info "✓ basic-setup completed (log: ${basic_log})"
        echo ""
    fi

    declare -a jobs_names=()
    declare -a jobs_pids=()
    declare -a jobs_logs=()
    declare -a jobs_scripts=()

    # Background jobs MUST start in this shell — do not use pid=$(...) around the launcher
    # or the child is not waitable (command substitution runs in a subshell).
    add_job() {
        local n="$1"
        local script="$2"
        shift 2
        local lg="${LOG_DIR}/${n}.log"
        (
            cd "${REPO_ROOT}"
            exec bash "${script}" "$@"
        ) >"${lg}" 2>&1 &
        local pid=$!
        jobs_names+=("${n}")
        jobs_pids+=("${pid}")
        jobs_logs+=("${lg}")
        jobs_scripts+=("${script}")
        print_info "Started ${n} (pid ${pid}) → ${lg}"
    }

    print_step "Phase 2: FAM, monitoring, MCP, OpenShift Pipelines, custom-policies (parallel)"
    if [ "${SKIP_FAM_SETUP:-0}" != "1" ] && [ "${SKIP_FIM_SETUP:-0}" != "1" ]; then
        add_job fam-setup "${REPO_ROOT}/fam-setup/install.sh"
    fi
    if [ "${SKIP_MONITORING_SETUP:-0}" != "1" ]; then
        add_job monitoring-setup "${REPO_ROOT}/monitoring-setup/install.sh"
    fi
    if [ "${SKIP_MCP_SETUP:-0}" != "1" ]; then
        add_job mcp-server-setup "${REPO_ROOT}/mcp-server-setup/install.sh"
    fi
    if [ "${SKIP_OPENSHIFT_PIPELINES_SETUP:-0}" != "1" ]; then
        add_job openshift-pipelines-setup "${REPO_ROOT}/openshift-pipelines-setup/install.sh"
    fi
    if [ "${SKIP_CUSTOM_POLICIES_SETUP:-0}" != "1" ]; then
        add_job custom-policies "${REPO_ROOT}/custom-policies/install.sh"
    fi

    if [ ${#jobs_pids[@]} -eq 0 ]; then
        if [ "${SKIP_BASIC_SETUP:-0}" != "1" ]; then
            print_info "No parallel jobs (all skipped); basic-setup already completed."
            exit 0
        fi
        print_error "No jobs enabled — set SKIP_* flags or run basic-setup."
        exit 1
    fi

    echo ""
    print_step "Waiting for ${#jobs_pids[@]} parallel job(s)..."
    echo ""

    # Poll so completions print in finish order (not start order) and SSH sees periodic activity.
    failed=0
    declare -a failed_parallel_scripts=()
    local n_jobs=${#jobs_pids[@]}
    declare -a job_done
    local _i _j
    for ((_j = 0; _j < n_jobs; _j++)); do
        job_done[$_j]=0
    done
    local completed=0
    local progress_every="${INSTALL_ALL_PARALLEL_PROGRESS_SEC:-45}"
    local poll_sleep="${INSTALL_ALL_PARALLEL_POLL_SEC:-3}"
    local next_progress=$((SECONDS + progress_every))

    print_info "Live progress: each job reports here when it exits; every ~${progress_every}s — which jobs are still running."

    while [ "${completed}" -lt "${n_jobs}" ]; do
        for _i in "${!jobs_pids[@]}"; do
            if [ "${job_done[$_i]}" = "1" ]; then
                continue
            fi
            local pid="${jobs_pids[$_i]}"
            if ! kill -0 "${pid}" 2>/dev/null; then
                local ec=0
                wait "${pid}" || ec=$?
                job_done[$_i]=1
                completed=$((completed + 1))
                if [ "${ec}" -eq 0 ]; then
                    print_info "✓ ${jobs_names[$_i]} finished (${completed}/${n_jobs}) — log: ${jobs_logs[$_i]}"
                else
                    failed=1
                    failed_parallel_scripts+=("${jobs_scripts[$_i]}")
                    print_error "✗ ${jobs_names[$_i]} failed (exit ${ec}); see ${jobs_logs[$_i]}"
                    print_info "To rerun this step: bash \"${jobs_scripts[$_i]}\""
                fi
            fi
        done
        if [ "${completed}" -ge "${n_jobs}" ]; then
            break
        fi
        if [ "${SECONDS}" -ge "${next_progress}" ]; then
            local running_list=()
            for _i in "${!jobs_pids[@]}"; do
                if [ "${job_done[$_i]}" = "1" ]; then
                    continue
                fi
                if kill -0 "${jobs_pids[$_i]}" 2>/dev/null; then
                    running_list+=("${jobs_names[$_i]}")
                fi
            done
            print_info "[parallel ${completed}/${n_jobs}] Still running: ${running_list[*]}"
            next_progress=$((SECONDS + progress_every))
        fi
        sleep "${poll_sleep}"
    done

    echo ""
    if [ "${failed}" -eq 0 ]; then
        print_info "All setup phases completed successfully."
        exit 0
    fi
    print_error "One or more parallel jobs failed. Review logs in ${LOG_DIR}"
    if [ ${#failed_parallel_scripts[@]} -gt 0 ]; then
        print_info "After fixing the issue, rerun failed step(s):"
        for s in "${failed_parallel_scripts[@]}"; do
            print_info "  bash \"${s}\""
        done
    fi
    exit 1
}

main "$@"
