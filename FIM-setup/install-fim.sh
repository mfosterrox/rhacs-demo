#!/bin/bash

# Script: install-fim.sh
# Description: Submit FIM policy to ACS and run the FIM trigger loop on a worker node
# Requires: ROX_CENTRAL_URL, ROX_API_TOKEN, oc logged in

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIM_POLICY="${SCRIPT_DIR}/fim-policy-basic.json"
FIM_TRIGGER_SCRIPT="${SCRIPT_DIR}/fim-trigger-loop.sh"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Get Central URL
get_central_url() {
    if [ -n "${ROX_CENTRAL_URL:-}" ]; then
        echo "${ROX_CENTRAL_URL}"
        return 0
    fi
    local url
    url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${url}" ]; then
        echo "${url}"
        return 0
    fi
    return 1
}

# Check prerequisites
if ! oc whoami &>/dev/null; then
    print_error "Not connected to OpenShift cluster. Run: oc login"
    exit 1
fi

if [ ! -f "${FIM_POLICY}" ]; then
    print_error "FIM policy not found: ${FIM_POLICY}"
    exit 1
fi

if [ ! -f "${FIM_TRIGGER_SCRIPT}" ]; then
    print_error "FIM trigger script not found: ${FIM_TRIGGER_SCRIPT}"
    exit 1
fi

CENTRAL_URL=$(get_central_url) || {
    print_error "Could not determine ROX_CENTRAL_URL. Set it or ensure RHACS route exists."
    exit 1
}

if [ -z "${ROX_API_TOKEN:-}" ]; then
    print_error "ROX_API_TOKEN is required. Set it: export ROX_API_TOKEN='your-token'"
    exit 1
fi

API_BASE="${CENTRAL_URL}/v1"

#================================================================
# Step 1: Submit FIM policy to ACS
#================================================================
print_step "1. Submitting FIM policy to ACS..."
if ! command -v jq &>/dev/null; then
    print_error "jq is required. Install: dnf install jq / brew install jq"
    exit 1
fi

# Extract first policy, remove id for create (server will assign)
POLICY_JSON=$(jq '.policies[0] | del(.id, .lastUpdated)' "${FIM_POLICY}")

# Check if policy already exists
existing_id=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${API_BASE}/policies" | jq -r '.policies[] | select(.name=="FIM-basic-monitoring") | .id' 2>/dev/null || echo "")

if [ -n "${existing_id}" ]; then
    print_info "Policy 'FIM-basic-monitoring' already exists (id: ${existing_id})"
    print_info "Updating existing policy..."
    response=$(curl -k -s -w "\n%{http_code}" -X PUT \
        -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(echo "${POLICY_JSON}" | jq --arg id "${existing_id}" '. + {id: $id}')" \
        "${API_BASE}/policies/${existing_id}" 2>&1)
else
    print_info "Creating new policy..."
    response=$(curl -k -s -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${ROX_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${POLICY_JSON}" \
        "${API_BASE}/policies" 2>&1)
fi

http_code=$(echo "${response}" | tail -n1)
body=$(echo "${response}" | sed '$d')

if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
    print_error "Failed to submit policy (HTTP ${http_code})"
    print_error "Response: ${body:0:300}"
    exit 1
fi

print_info "✓ FIM policy submitted to ACS"
echo ""

#================================================================
# Step 2: Run FIM trigger loop on a worker node
#================================================================
print_step "2. Starting FIM trigger loop on worker node..."

# Get first worker node
WORKER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    oc get nodes -o jsonpath='{.items[?(@.metadata.labels.node-role\.kubernetes\.io/worker=="" || @.metadata.labels.node-role\.kubernetes\.io/worker=="true")].metadata.name}' 2>/dev/null | awk '{print $1}' || \
    oc get nodes -o jsonpath='{.items[1].metadata.name}' 2>/dev/null)

if [ -z "${WORKER_NODE}" ]; then
    print_warn "Could not find worker node"
    print_info "Run manually:"
    echo ""
    echo "  oc debug node/<worker-node-name>"
    echo "  chroot /host"
    echo "  # Then paste and run:"
    cat "${FIM_TRIGGER_SCRIPT}"
    echo ""
    exit 0
fi

print_info "Using node: ${WORKER_NODE}"
print_info "Starting oc debug with FIM trigger loop (runs in background)..."
echo ""

# Run oc debug with the trigger script piped into chroot
# The loop runs in background so the script returns (nohup keeps it running after script exits)
nohup oc debug "node/${WORKER_NODE}" -- chroot /host bash -s < "${FIM_TRIGGER_SCRIPT}" > /tmp/fim-trigger.log 2>&1 &
DEBUG_PID=$!
disown $DEBUG_PID 2>/dev/null || true

sleep 5
if kill -0 $DEBUG_PID 2>/dev/null; then
    print_info "✓ FIM trigger loop running in background (pid: ${DEBUG_PID})"
    print_info "  Violations will appear in ACS every ~60 seconds"
    print_info "  Check: RHACS UI → Violations → Policy: FIM-basic-monitoring"
    echo ""
    print_info "To stop: kill ${DEBUG_PID}"
else
    print_warn "Debug pod may have exited. Run manually:"
    echo ""
    echo "  oc debug node/${WORKER_NODE}"
    echo "  chroot /host"
    echo "  # Then paste and run the contents of: ${FIM_TRIGGER_SCRIPT}"
    echo ""
fi
