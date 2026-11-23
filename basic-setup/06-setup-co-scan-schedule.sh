#!/bin/bash

set -euo pipefail

_RHACS_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Default values
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
COMPLIANCE_NAMESPACE="${COMPLIANCE_NAMESPACE:-openshift-compliance}"
ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS:-}"
SCAN_NAME="acs-catch-all"
# Printed after a successful create. Left empty when an existing schedule is kept.
SCAN_PROFILE_SUMMARY=""

# Function to ensure jq is installed
ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    
    print_warn "jq is not installed, attempting to install..."
    
    if command -v dnf >/dev/null 2>&1; then
        if sudo dnf install -y jq >/dev/null 2>&1; then
            print_info "✓ jq installed successfully"
            return 0
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        if sudo apt-get update >/dev/null 2>&1 && sudo apt-get install -y jq >/dev/null 2>&1; then
            print_info "✓ jq installed successfully"
            return 0
        fi
    fi
    
    print_error "Could not install jq. Please install it manually"
    return 1
}

# Function to get Central URL
get_central_url() {
    if [ -n "${ROX_CENTRAL_ADDRESS}" ]; then
        echo "${ROX_CENTRAL_ADDRESS}"
        return 0
    fi
    
    local url=$(oc get route central -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${url}" ]; then
        echo "${url}"
        return 0
    fi
    
    return 1
}

# Function to get cluster ID
get_cluster_id() {
    local token=$1
    local api_base=$2
    
    # All print statements go to stderr so they don't get captured in the return value
    print_info "Fetching cluster ID..." >&2
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X GET \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${api_base}/v1/clusters" 2>&1 || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        print_error "Failed to fetch clusters (HTTP ${http_code})" >&2
        print_error "URL: ${api_base}/v1/clusters" >&2
        print_error "Response: ${body:0:500}" >&2
        return 1
    fi
    
    # Try to get cluster ID - first try by health status, then just get first cluster
    local cluster_id=$(echo "${body}" | jq -r '.clusters[] | select(.healthStatus.overallHealthStatus != null) | .id' 2>/dev/null | head -1 || echo "")
    
    if [ -z "${cluster_id}" ] || [ "${cluster_id}" = "null" ]; then
        cluster_id=$(echo "${body}" | jq -r '.clusters[0].id' 2>/dev/null || echo "")
    fi
    
    if [ -z "${cluster_id}" ] || [ "${cluster_id}" = "null" ]; then
        print_error "Could not find cluster ID" >&2
        print_error "API Response: ${body:0:500}" >&2
        return 1
    fi
    
    local cluster_name=$(echo "${body}" | jq -r ".clusters[] | select(.id == \"${cluster_id}\") | .name" 2>/dev/null || echo "")
    if [ -n "${cluster_name}" ] && [ "${cluster_name}" != "null" ]; then
        print_info "Found cluster: ${cluster_name} (ID: ${cluster_id})" >&2
    else
        print_info "Using cluster ID: ${cluster_id}" >&2
    fi
    
    # Only echo the cluster_id to stdout (for capture)
    echo "${cluster_id}"
    return 0
}

# Function to wait for Compliance Operator pods to be ready
wait_for_compliance_pods() {
    print_step "Checking Compliance Operator pod status..."
    
    # Required pods for compliance scanning
    local required_pods=("compliance-operator" "ocp4-openshift-compliance-pp" "rhcos4-openshift-compliance-pp")
    local max_wait=180  # 3 minutes
    local interval=10
    local elapsed=0
    
    while [ ${elapsed} -lt ${max_wait} ]; do
        local all_ready=true
        local pod_status=""
        
        for pod_prefix in "${required_pods[@]}"; do
            # Check if any pods with this prefix are running
            local pod_count=$(oc get pods -n "${COMPLIANCE_NAMESPACE}" --field-selector=status.phase=Running --no-headers 2>/dev/null | grep "${pod_prefix}" | wc -l | tr -d ' ')
            
            # Ensure we have a valid integer
            if [ -z "${pod_count}" ] || [ "${pod_count}" = "" ]; then
                pod_count="0"
            fi
            
            if [ "${pod_count}" -eq 0 ]; then
                all_ready=false
                pod_status="${pod_status}  ${pod_prefix}: Not running\n"
            else
                pod_status="${pod_status}  ${pod_prefix}: ✓ Running\n"
            fi
        done
        
        if [ "${all_ready}" = true ]; then
            print_info "✓ All Compliance Operator pods are running"
            echo -e "${pod_status}"
            return 0
        fi
        
        if [ $((elapsed % 30)) -eq 0 ]; then
            print_info "Waiting for Compliance Operator pods to be ready... (${elapsed}s/${max_wait}s)"
            if [ -n "${pod_status}" ]; then
                echo -e "${pod_status}"
            fi
        fi
        
        sleep ${interval}
        elapsed=$((elapsed + interval))
    done
    
    print_warn "Not all Compliance Operator pods are ready within ${max_wait}s"
    print_warn "Attempting to create scan configuration anyway..."
    return 0
}

# Function to check if scan configuration exists
scan_config_exists() {
    local token=$1
    local api_base=$2
    local scan_name=$3
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X GET \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${api_base}/v2/compliance/scan/configurations" 2>/dev/null || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    
    local scan_id=$(echo "${body}" | jq -r ".configurations[] | select(.scanName == \"${scan_name}\") | .id" 2>/dev/null || echo "")
    
    if [ -n "${scan_id}" ] && [ "${scan_id}" != "null" ]; then
        return 0
    fi
    
    return 1
}

# Function to delete existing scan configuration
delete_scan_config() {
    local token=$1
    local api_base=$2
    local scan_name=$3
    
    print_info "Checking for existing scan configuration..."
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X GET \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${api_base}/v2/compliance/scan/configurations" 2>/dev/null || echo "")
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        return 0
    fi
    
    local scan_id=$(echo "${body}" | jq -r ".configurations[] | select(.scanName == \"${scan_name}\") | .id" 2>/dev/null || echo "")
    
    if [ -z "${scan_id}" ] || [ "${scan_id}" = "null" ]; then
        print_info "No existing scan configuration found"
        return 0
    fi
    
    print_info "Deleting existing scan configuration (ID: ${scan_id})..."
    
    local del_response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X DELETE \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${api_base}/v2/compliance/scan/configurations/${scan_id}" 2>/dev/null || echo "")
    
    local del_code=$(echo "${del_response}" | tail -n1)
    
    if [ "${del_code}" = "200" ] || [ "${del_code}" = "204" ] || [ "${del_code}" = "404" ]; then
        print_info "✓ Existing scan configuration removed"
        sleep 2
    else
        print_warn "Could not delete scan configuration (HTTP ${del_code}), will try to create anyway"
    fi
    
    return 0
}

# Profile names Central has synced for this cluster.
# Central rejects the scan configuration unless every name exists for the cluster.
list_synced_profile_names() {
    local token=$1
    local api_base=$2
    local cluster_id=$3

    local response http_code body names
    response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -G \
        -H "Authorization: Bearer ${token}" \
        --data-urlencode "cluster_ids=${cluster_id}" \
        "${api_base}/v2/compliance/profiles/summary" 2>/dev/null || true)

    http_code=$(echo "${response}" | tail -n1)
    body=$(echo "${response}" | sed '$d')

    if [ "${http_code}" != "200" ]; then
        print_warn "Profile list request failed (HTTP ${http_code:-none})" >&2
        return 1
    fi

    if ! echo "${body}" | jq -e 'type == "object"' >/dev/null 2>&1; then
        print_warn "Profile list response was not JSON" >&2
        return 1
    fi

    names=$(echo "${body}" | jq -r '.profiles[]?.name // empty' | sed '/^$/d' | sort -u)
    printf '%s\n' "${names}"
    return 0
}

profile_present() {
    local synced=$1
    local name=$2
    [ -n "${synced}" ] && printf '%s\n' "${synced}" | grep -qx "${name}"
}

# CIS platform and node are required. Virtualization profiles are included
# only when Central has already synced them from the Compliance Operator.
resolve_scan_profiles() {
    local token=$1
    local api_base=$2
    local cluster_id=$3

    local required=("ocp4-cis" "ocp4-cis-node")
    local virt=("ocp4-cis-vm-extension" "ocp4-cis-vm-extension-node")
    local desired=("${required[@]}" "${virt[@]}")

    local max_wait=120
    local interval=10
    local elapsed=0
    local synced=""
    local api_ok=false
    local name

    while true; do
        if synced=$(list_synced_profile_names "${token}" "${api_base}" "${cluster_id}"); then
            api_ok=true
            local required_ready=true
            for name in "${required[@]}"; do
                if ! profile_present "${synced}" "${name}"; then
                    required_ready=false
                    break
                fi
            done
            if [ "${required_ready}" = true ]; then
                break
            fi
        fi

        if [ "${elapsed}" -ge "${max_wait}" ]; then
            break
        fi

        print_info "Waiting for Compliance Operator profiles to sync to Central... (${elapsed}s/${max_wait}s)" >&2
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done

    if [ "${api_ok}" != true ]; then
        print_error "Could not list compliance profiles from Central" >&2
        return 1
    fi

    local synced_count=0
    if [ -n "${synced}" ]; then
        synced_count=$(printf '%s\n' "${synced}" | sed '/^$/d' | wc -l | tr -d ' ')
    fi
    print_info "Central has ${synced_count} compliance profile(s) for this cluster" >&2

    local selected=()
    for name in "${desired[@]}"; do
        if profile_present "${synced}" "${name}"; then
            selected+=("${name}")
            print_info "  + ${name}" >&2
        fi
    done

    local missing_required=()
    for name in "${required[@]}"; do
        if ! profile_present "${synced}" "${name}"; then
            missing_required+=("${name}")
        fi
    done

    if [ ${#missing_required[@]} -gt 0 ]; then
        print_error "Central has not synced required profiles: ${missing_required[*]}" >&2
        print_error "Profiles currently visible to Central:" >&2
        if [ -n "${synced}" ]; then
            printf '%s\n' "${synced}" | sed 's/^/  /' >&2
        else
            print_error "  (none)" >&2
        fi
        return 1
    fi

    local missing_virt=()
    for name in "${virt[@]}"; do
        if ! profile_present "${synced}" "${name}"; then
            missing_virt+=("${name}")
        fi
    done
    if [ ${#missing_virt[@]} -gt 0 ]; then
        print_warn "OpenShift Virtualization profiles are not synced, so they were left out: ${missing_virt[*]}" >&2
        print_warn "Those profiles ship with Compliance Operator 1.10 (ocp4 ProfileBundle)" >&2
    fi

    printf '%s\n' "${selected[@]}"
    return 0
}

# Function to create scan configuration
create_scan_config() {
    local token=$1
    local api_base=$2
    local cluster_id=$3
    local scan_name=$4
    
    print_info "Creating compliance scan configuration '${scan_name}'..."

    local profiles_file
    profiles_file=$(mktemp)
    if ! resolve_scan_profiles "${token}" "${api_base}" "${cluster_id}" > "${profiles_file}"; then
        rm -f "${profiles_file}"
        return 1
    fi

    local selected=()
    local name
    while IFS= read -r name; do
        [ -n "${name}" ] && selected+=("${name}")
    done < "${profiles_file}"
    rm -f "${profiles_file}"

    if [ ${#selected[@]} -eq 0 ]; then
        print_error "No compliance profiles available for the scan configuration"
        return 1
    fi

    local description="Daily CIS compliance scan"
    if printf '%s\n' "${selected[@]}" | grep -q 'cis-vm-extension'; then
        description="Daily CIS and OpenShift Virtualization compliance scan"
    fi

    SCAN_PROFILE_SUMMARY=$(printf '%s, ' "${selected[@]}")
    SCAN_PROFILE_SUMMARY="${SCAN_PROFILE_SUMMARY%, }"

    local profiles_json
    profiles_json=$(printf '%s\n' "${selected[@]}" | jq -R . | jq -s .)
    
    # Create JSON payload in a temp file for reliable transmission
    local temp_file=$(mktemp)
    jq -n \
        --arg scanName "${scan_name}" \
        --arg clusterId "${cluster_id}" \
        --arg description "${description}" \
        --argjson profiles "${profiles_json}" \
        '{
          scanName: $scanName,
          scanConfig: {
            oneTimeScan: false,
            profiles: $profiles,
            scanSchedule: { intervalType: "DAILY", hour: 12, minute: 0 },
            description: $description
          },
          clusters: [$clusterId]
        }' > "${temp_file}"
    
    # Debug: verify JSON is valid
    if ! jq . "${temp_file}" >/dev/null 2>&1; then
        print_error "Generated invalid JSON payload"
        rm -f "${temp_file}"
        return 1
    fi
    
    print_info "Making API request to: ${api_base}/v2/compliance/scan/configurations"
    
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        --data @"${temp_file}" \
        "${api_base}/v2/compliance/scan/configurations" 2>&1)
    
    # Clean up temp file
    rm -f "${temp_file}"
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    # Check if we got HTML response (indicates wrong endpoint or proxy issue)
    if echo "${body}" | grep -qi "<html>\|<body>"; then
        print_error "Received HTML response instead of JSON (HTTP ${http_code})"
        print_error "URL: ${api_base}/v2/compliance/scan/configurations"
        print_error "This usually indicates:"
        print_error "  - Wrong API endpoint or route configuration"
        print_error "  - Proxy or load balancer intercepting the request"
        print_error "Response: ${body:0:300}"
        return 1
    fi
    
    if [ "${http_code}" != "200" ] && [ "${http_code}" != "201" ]; then
        print_error "Failed to create scan configuration (HTTP ${http_code})"
        print_error "URL: ${api_base}/v2/compliance/scan/configurations"
        print_error "Cluster ID: ${cluster_id}"
        print_error "Response: ${body:0:500}"
        print_error "Profiles sent: ${selected[*]}"
        print_error ""
        print_error "This may indicate:"
        print_error "  - ProfileBundles not yet ready (wait and retry)"
        print_error "  - A requested profile is not synced for this cluster"
        print_error "  - Invalid cluster ID"
        print_error "  - API authentication issue"
        return 1
    fi
    
    print_info "✓ Scan configuration created successfully"
    
    # Wait and verify
    sleep 2
    
    local verify_response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X GET \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "${api_base}/v2/compliance/scan/configurations" 2>/dev/null || echo "")
    
    local verify_code=$(echo "${verify_response}" | tail -n1)
    local verify_body=$(echo "${verify_response}" | sed '$d')
    
    if [ "${verify_code}" = "200" ]; then
        local verify_id=$(echo "${verify_body}" | jq -r ".configurations[] | select(.scanName == \"${scan_name}\") | .id" 2>/dev/null || echo "")
        if [ -n "${verify_id}" ] && [ "${verify_id}" != "null" ]; then
            print_info "✓ Scan configuration verified (ID: ${verify_id})"
        fi
    fi
    
    return 0
}

# Main function
main() {
    print_info "=========================================="
    print_info "Compliance Scan Schedule Setup"
    print_info "=========================================="
    print_info ""
    
    # Check prerequisites
    print_step "Checking prerequisites..."
    
    if ! ensure_jq; then
        exit 1
    fi
    
    # Get Central URL
    print_info "Getting Central URL..."
    local central_url=$(get_central_url)
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        exit 1
    fi
    print_info "Central URL: ${central_url}"
    
    # Setup API base URL
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local api_base="https://${api_host}"
    
    # Use API token from environment (required)
    local token="${ROX_API_TOKEN:-}"
    if [ -z "${token}" ]; then
        print_error "ROX_API_TOKEN environment variable is not set"
        print_error "Please set ROX_API_TOKEN before running this script"
        print_error "You can generate a token using the RHACS UI or API"
        exit 1
    fi
    
    print_info "✓ Using API token from environment"
    
    # Get cluster ID
    local cluster_id=$(get_cluster_id "${token}" "${api_base}")
    if [ -z "${cluster_id}" ] || [ "${cluster_id}" = "null" ]; then
        print_error "Failed to get cluster ID"
        print_error "Verify that at least one cluster is connected to RHACS Central"
        exit 1
    fi
    print_info "✓ Cluster ID validated: ${cluster_id}"
    
    print_info ""
    
    # Wait for Compliance Operator pods to be ready
    wait_for_compliance_pods || true
    
    print_info ""
    
    # Check if already configured
    print_step "Checking for existing scan configuration..."
    if scan_config_exists "${token}" "${api_base}" "${SCAN_NAME}"; then
        print_info "✓ Scan configuration '${SCAN_NAME}' already exists"
        print_info "Skipping scan configuration setup"
    else
        print_info "Scan configuration not found, creating..."
        
        # Delete any existing config
        delete_scan_config "${token}" "${api_base}" "${SCAN_NAME}" || true
        
        # Create new config
        if ! create_scan_config "${token}" "${api_base}" "${cluster_id}" "${SCAN_NAME}"; then
            print_error "Failed to create scan configuration"
            exit 1
        fi
    fi
    
    print_info ""
    print_info "=========================================="
    print_info "Compliance Scan Schedule Setup Complete"
    print_info "=========================================="
    print_info ""
    print_info "Scan Configuration: ${SCAN_NAME}"
    print_info "Schedule: Daily at 12:00 PM"
    if [ -n "${SCAN_PROFILE_SUMMARY}" ]; then
        print_info "Profiles: ${SCAN_PROFILE_SUMMARY}"
    else
        print_info "Profiles: existing scan configuration left unchanged"
    fi
    print_info ""
}

# Run main function
main "$@"
