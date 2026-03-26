#!/bin/bash

# Script: install.sh (fam-setup)
# Description: Enable file activity monitoring on SecuredCluster, submit FAM policies to ACS via API,
#              apply fam-cron-exec-target.yaml (CronJob that oc exec’s into the payment processor and
#              touch /etc/passwd every 10 minutes), and optionally run a one-shot oc exec for an immediate demo.
# Requires: ROX_CENTRAL_ADDRESS (or auto-detect), ROX_API_TOKEN, oc logged in, jq
#
# Optional env:
#   FAM_SKIP_CRONJOB=1        — do not apply the exec CronJob manifest
#   FAM_SKIP_WORKLOAD_EXEC=1  — do not run one-shot oc exec into the demo workload
#   FAM_EXEC_NAMESPACE        — default payments (also rewrites the CronJob manifest on apply)
#   FAM_EXEC_WORKLOAD         — default deployment/mastercard-processor
#   FAM_EXEC_CONTAINER        — optional -c name for multi-container pods

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
FAM_POLICIES=(
    "${SCRIPT_DIR}/fam-basic-node-monitoring.json"
    "${SCRIPT_DIR}/fam-basic-deploy-monitoring.json"
)
FAM_CRON_MANIFEST="${SCRIPT_DIR}/fam-cron-exec-target.yaml"
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
FAM_EXEC_NAMESPACE="${FAM_EXEC_NAMESPACE:-payments}"
FAM_EXEC_WORKLOAD="${FAM_EXEC_WORKLOAD:-deployment/mastercard-processor}"
FAM_EXEC_CONTAINER="${FAM_EXEC_CONTAINER:-}"

# Get Central URL
get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS:-}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
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

for policy_file in "${FAM_POLICIES[@]}"; do
    if [ ! -f "${policy_file}" ]; then
        print_error "FAM policy file not found: ${policy_file}"
        exit 1
    fi
done

if [ ! -f "${FAM_CRON_MANIFEST}" ]; then
    print_error "FAM CronJob manifest not found: ${FAM_CRON_MANIFEST}"
    exit 1
fi

if [ -z "${ROX_API_TOKEN:-}" ]; then
    print_error "ROX_API_TOKEN is required. Set it: export ROX_API_TOKEN='your-token'"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    print_error "jq is required. Install: dnf install jq / brew install jq"
    exit 1
fi

CENTRAL_URL=$(get_central_url) || {
    print_error "Could not determine ROX_CENTRAL_ADDRESS. Set it or ensure RHACS route exists."
    exit 1
}

API_BASE="${CENTRAL_URL}/v1"

#================================================================
# Step 1: Enable file activity monitoring on SecuredCluster
#================================================================
print_step "1. Enabling file activity monitoring on SecuredCluster..."

SC_NAME=$(oc get securedcluster -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "${SC_NAME}" ]; then
    print_error "No SecuredCluster found in ${RHACS_NAMESPACE}"
    exit 1
fi

print_info "Patching SecuredCluster ${SC_NAME}..."
if ! oc patch securedcluster "${SC_NAME}" \
    -n "${RHACS_NAMESPACE}" \
    --type=merge \
    -p '{"spec":{"perNode":{"fileActivityMonitoring":{"mode":"Enabled"}}}}' 2>/dev/null; then
    print_error "Failed to patch SecuredCluster"
    exit 1
fi

# Verify patch was applied
FAM_MODE=$(oc get securedcluster "${SC_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.perNode.fileActivityMonitoring.mode}' 2>/dev/null || echo "")
if [ "${FAM_MODE}" != "Enabled" ]; then
    print_error "Patch verification failed: fileActivityMonitoring.mode is '${FAM_MODE}', expected 'Enabled'"
    exit 1
fi
print_info "✓ File activity monitoring enabled (verified)"
echo ""

#================================================================
# Step 2: Submit FAM policies to ACS via API
#================================================================
print_step "2. Submitting file activity monitoring policies to ACS via API..."

for policy_file in "${FAM_POLICIES[@]}"; do
    policy_name=$(jq -r '.policies[0].name' "${policy_file}")
    POLICY_JSON=$(jq '.policies[0] | del(.id, .lastUpdated)' "${policy_file}")

    existing_id=$(curl -k -s -H "Authorization: Bearer ${ROX_API_TOKEN}" "${API_BASE}/policies" | jq -r --arg name "${policy_name}" '.policies[] | select(.name==$name) | .id' 2>/dev/null || echo "")

    if [ -n "${existing_id}" ]; then
        print_info "Policy '${policy_name}' already exists (id: ${existing_id}), updating..."
        response=$(curl -k -s -w "\n%{http_code}" -X PUT \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$(echo "${POLICY_JSON}" | jq --arg id "${existing_id}" '. + {id: $id}')" \
            "${API_BASE}/policies/${existing_id}" 2>&1)
    else
        print_info "Creating policy '${policy_name}'..."
        response=$(curl -k -s -w "\n%{http_code}" -X POST \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "${POLICY_JSON}" \
            "${API_BASE}/policies" 2>&1)
    fi

    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')

    if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
        print_error "Failed to submit policy '${policy_name}' (HTTP ${http_code})"
        print_error "Response: ${body:0:300}"
        exit 1
    fi
    print_info "✓ ${policy_name} submitted"
done
echo ""

#================================================================
# Step 3: CronJob — periodic oc exec into target workload → touch /etc/passwd
#================================================================
print_step "3. Applying FAM exec CronJob (${FAM_CRON_MANIFEST##*/})..."

if [ "${FAM_SKIP_CRONJOB:-0}" = "1" ]; then
    print_info "Skipping (FAM_SKIP_CRONJOB=1)"
else
    # Rewrite placeholders in the checked-in manifest to match FAM_EXEC_* (defaults: payments / mastercard-processor)
    if ! sed \
        -e "s/namespace: payments/namespace: ${FAM_EXEC_NAMESPACE}/g" \
        -e "s#value: \"deployment/mastercard-processor\"#value: \"${FAM_EXEC_WORKLOAD}\"#g" \
        -e "s#value: \"payments\"#value: \"${FAM_EXEC_NAMESPACE}\"#g" \
        "${FAM_CRON_MANIFEST}" | oc apply -f -; then
        print_error "Failed to apply FAM exec CronJob (is namespace ${FAM_EXEC_NAMESPACE} present? image pull ok?)"
        exit 1
    fi
    if [ -n "${FAM_EXEC_CONTAINER}" ]; then
        if oc set env cronjob/rhacs-fam-exec-trigger -n "${FAM_EXEC_NAMESPACE}" \
            "TARGET_CONTAINER=${FAM_EXEC_CONTAINER}" --overwrite &>/dev/null; then
            print_info "✓ CronJob env TARGET_CONTAINER=${FAM_EXEC_CONTAINER}"
        else
            print_warn "Could not patch CronJob TARGET_CONTAINER (cronjob missing yet?) — set manually if needed"
        fi
    fi
    print_info "✓ CronJob rhacs-fam-exec-trigger in ${FAM_EXEC_NAMESPACE} (every 10m → oc exec ${FAM_EXEC_WORKLOAD} -- touch /etc/passwd)"
fi
echo ""

#================================================================
# Step 4: One-shot oc exec — touch /etc/passwd inside target workload (deploy FAM demo)
#================================================================
print_step "4. FAM demo workload: oc exec → touch /etc/passwd (fam-basic-deploy-monitoring)..."

if [ "${FAM_SKIP_WORKLOAD_EXEC:-0}" = "1" ]; then
    print_info "Skipping (FAM_SKIP_WORKLOAD_EXEC=1)"
else
    if ! oc get "${FAM_EXEC_WORKLOAD}" -n "${FAM_EXEC_NAMESPACE}" &>/dev/null; then
        print_warn "Resource not found: ${FAM_EXEC_WORKLOAD} in ${FAM_EXEC_NAMESPACE} — skipping oc exec"
        print_warn "Set FAM_EXEC_NAMESPACE / FAM_EXEC_WORKLOAD or deploy your app first."
    else
        print_info "Running oc exec into ${FAM_EXEC_WORKLOAD} (ns ${FAM_EXEC_NAMESPACE}) ..."
        if [ -n "${FAM_EXEC_CONTAINER}" ]; then
            oc_cmd=(oc exec -n "${FAM_EXEC_NAMESPACE}" "${FAM_EXEC_WORKLOAD}" -c "${FAM_EXEC_CONTAINER}" -- touch /etc/passwd)
        else
            oc_cmd=(oc exec -n "${FAM_EXEC_NAMESPACE}" "${FAM_EXEC_WORKLOAD}" -- touch /etc/passwd)
        fi
        if "${oc_cmd[@]}"; then
            print_info "✓ touch completed inside workload (check RHACS: fam-basic-deploy-monitoring)"
        else
            print_warn "oc exec failed (permissions, read-only FS, or default container) — run manually or set FAM_EXEC_CONTAINER"
        fi
    fi
fi
echo ""

#================================================================
# Next steps: Trigger FAM violations (run manually after install)
#================================================================
WORKER_NODE=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
    oc get nodes -o jsonpath='{.items[1].metadata.name}' 2>/dev/null || echo "worker-0")

print_step "File activity monitoring (FAM) setup complete"
echo ""
print_info "CronJob rhacs-fam-exec-trigger (unless skipped) runs every 10 minutes with oc exec into ${FAM_EXEC_WORKLOAD} (${FAM_EXEC_NAMESPACE})."
print_info "Step 4 runs one immediate oc exec when that workload exists (override with FAM_EXEC_* env)."
print_info "To trigger node-level FAM manually, run these commands:"
echo ""
echo "  1. Debug a worker node (detected: ${WORKER_NODE}):"
echo "       oc debug node/${WORKER_NODE}"
echo ""
echo "  2. In the debug shell, chroot to the host:"
echo "       chroot /host"
echo ""
echo "  3. Trigger a monitored path change:"
echo "       touch /etc/passwd"
echo ""
echo "  4. RHACS UI: Violations → filter by policy fam-basic-node-monitoring"
echo ""
echo "  5. Exit: run exit twice (leave chroot, then leave the debug pod)"
echo ""
