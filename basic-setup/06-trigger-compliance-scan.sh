#!/bin/bash

# Script: 06-trigger-compliance-scan.sh
# Description: Trigger compliance scans for multiple standards in RHACS

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Print functions
print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Error handler
error_handler() {
    local exit_code=$1
    local line_number=$2
    print_error "Error at line ${line_number} (exit code: ${exit_code})"
    exit "${exit_code}"
}

trap 'error_handler $? $LINENO' ERR

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"

# Compliance standards to trigger
readonly COMPLIANCE_STANDARDS=(
    "CIS Kubernetes v1.5"
    "HIPAA 164"
    "NIST SP 800-190"
    "NIST SP 800-53"
    "PCI DSS 3.2.1"
)

#================================================================
# Function to make API call
#================================================================
make_api_call() {
    local method=$1
    local endpoint=$2
    local data="${3:-}"
    
    local curl_opts="-k -s -w \n%{http_code}"
    
    if [ -n "${data}" ]; then
        local temp_file=$(mktemp)
        echo "${data}" > "${temp_file}"
        
        local response=$(curl ${curl_opts} \
            -X "${method}" \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            --data-binary @"${temp_file}" \
            "${endpoint}" 2>&1)
        
        rm -f "${temp_file}"
    else
        local response=$(curl ${curl_opts} \
            -X "${method}" \
            -H "Authorization: Bearer ${ROX_API_TOKEN}" \
            -H "Content-Type: application/json" \
            "${endpoint}" 2>&1)
    fi
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
        print_error "API call failed (HTTP ${http_code})"
        print_error "Response: ${body:0:300}"
        return 1
    fi
    
    echo "${body}"
    return 0
}

#================================================================
# Function to get cluster ID
#================================================================
get_cluster_id() {
    local api_base=$1
    
    print_info "Fetching cluster ID..."
    
    local body=$(make_api_call "GET" "${api_base}/clusters")
    if [ -z "${body}" ]; then
        return 1
    fi
    
    # Try to find "Production" cluster first
    local cluster_id=$(echo "${body}" | jq -r '.clusters[] | select(.name == "Production") | .id' 2>/dev/null | head -1)
    
    # If not found, use first cluster
    if [ -z "${cluster_id}" ] || [ "${cluster_id}" = "null" ]; then
        cluster_id=$(echo "${body}" | jq -r '.clusters[0].id // empty' 2>/dev/null)
    fi
    
    if [ -z "${cluster_id}" ]; then
        print_error "No clusters found"
        return 1
    fi
    
    # Get cluster name and health
    local cluster_name=$(echo "${body}" | jq -r ".clusters[] | select(.id == \"${cluster_id}\") | .name" 2>/dev/null)
    local cluster_health=$(echo "${body}" | jq -r ".clusters[] | select(.id == \"${cluster_id}\") | .healthStatus.overallHealthStatus // \"UNKNOWN\"" 2>/dev/null)
    
    print_info "✓ Cluster: ${cluster_name} (ID: ${cluster_id}, Health: ${cluster_health})"
    
    echo "${cluster_id}"
    return 0
}

#================================================================
# Function to find standard ID by name
#================================================================
find_standard_id() {
    local search_name=$1
    local standards_body=$2
    
    # Try exact match
    local standard_id=$(echo "${standards_body}" | jq -r ".standards[]? | select(.name == \"${search_name}\") | .id" 2>/dev/null | head -1)
    
    # Try case-insensitive match
    if [ -z "${standard_id}" ] || [ "${standard_id}" = "null" ]; then
        local search_lower=$(echo "${search_name}" | tr '[:upper:]' '[:lower:]')
        standard_id=$(echo "${standards_body}" | jq -r ".standards[]? | select(.name | ascii_downcase == \"${search_lower}\") | .id" 2>/dev/null | head -1)
    fi
    
    # Try partial pattern match
    if [ -z "${standard_id}" ] || [ "${standard_id}" = "null" ]; then
        local pattern=$(echo "${search_name}" | sed 's/ /.*/g')
        standard_id=$(echo "${standards_body}" | jq -r ".standards[]? | select(.name | test(\"${pattern}\"; \"i\")) | .id" 2>/dev/null | head -1)
    fi
    
    echo "${standard_id}"
}

#================================================================
# Function to trigger compliance scans
#================================================================
trigger_compliance_scans() {
    local api_base=$1
    local cluster_id=$2
    
    print_step "Fetching available compliance standards..."
    
    # Fetch compliance standards
    local standards_body=$(make_api_call "GET" "${api_base}/compliance/standards")
    if [ -z "${standards_body}" ]; then
        print_error "Failed to fetch compliance standards"
        return 1
    fi
    
    print_info "Available standards fetched"
    
    print_step "Triggering compliance scans..."
    echo ""
    
    local success_count=0
    local failed_count=0
    local -A triggered_standards
    
    # Find and trigger each standard
    for standard_name in "${COMPLIANCE_STANDARDS[@]}"; do
        local standard_id=$(find_standard_id "${standard_name}" "${standards_body}")
        
        if [ -z "${standard_id}" ] || [ "${standard_id}" = "null" ]; then
            print_warn "✗ ${standard_name} - not found"
            failed_count=$((failed_count + 1))
            continue
        fi
        
        # Get actual standard name
        local actual_name=$(echo "${standards_body}" | jq -r ".standards[]? | select(.id == \"${standard_id}\") | .name" 2>/dev/null || echo "${standard_name}")
        
        # Build scan payload
        local scan_payload=$(cat <<EOF
{
  "selection": {
    "clusterId": "${cluster_id}",
    "standardId": "${standard_id}"
  }
}
EOF
)
        
        # Trigger scan
        local scan_result=""
        local scan_error=""
        
        set +e
        scan_result=$(make_api_call "POST" "${api_base}/compliancemanagement/runs" "${scan_payload}" 2>&1)
        local exit_code=$?
        set -e
        
        if [ ${exit_code} -eq 0 ] && [ -n "${scan_result}" ]; then
            print_info "✓ ${actual_name} - scan triggered"
            
            # Try to extract scan ID
            local scan_id=$(echo "${scan_result}" | jq -r '.id // .scanId // .runId // empty' 2>/dev/null)
            if [ -n "${scan_id}" ] && [ "${scan_id}" != "null" ]; then
                print_info "  Scan ID: ${scan_id}"
            fi
            
            triggered_standards["${actual_name}"]="${standard_id}"
            success_count=$((success_count + 1))
        else
            print_warn "✗ ${actual_name} - failed to trigger"
            if [ -n "${scan_result}" ]; then
                print_warn "  Error: ${scan_result:0:200}"
            fi
            failed_count=$((failed_count + 1))
        fi
        
        sleep 1
    done
    
    echo ""
    print_info "=========================================="
    print_info "Scan Trigger Summary"
    print_info "=========================================="
    print_info "Standards found: $(( success_count + failed_count ))/${#COMPLIANCE_STANDARDS[@]}"
    print_info "Scans triggered: ${success_count}"
    
    if [ ${failed_count} -gt 0 ]; then
        print_warn "Scans failed: ${failed_count}"
    fi
    
    echo ""
    print_info "Triggered scans:"
    for name in "${!triggered_standards[@]}"; do
        print_info "  • ${name}"
    done
    
    return 0
}

#================================================================
# Main function
#================================================================
main() {
    print_info "=========================================="
    print_info "Compliance Scan Trigger"
    print_info "=========================================="
    print_info ""
    
    # Check prerequisites
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq not found - required for JSON processing"
        exit 1
    fi
    
    # Get Central URL
    local central_url=$(oc get route central -n ${RHACS_NAMESPACE} -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -z "${central_url}" ]; then
        print_error "Could not determine Central URL"
        exit 1
    fi
    
    print_info "Central URL: ${central_url}"
    
    # Check for API token
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_error "ROX_API_TOKEN environment variable is not set"
        print_error "Please set ROX_API_TOKEN before running this script"
        exit 1
    fi
    
    print_info "✓ Using API token from environment"
    
    # Setup API base URL
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    local api_base="https://${api_host}/v1"
    
    print_info ""
    
    # Get cluster ID
    local cluster_id=$(get_cluster_id "${api_base}")
    if [ -z "${cluster_id}" ]; then
        print_error "Failed to get cluster ID"
        exit 1
    fi
    
    print_info ""
    
    # Trigger scans
    trigger_compliance_scans "${api_base}" "${cluster_id}"
    
    print_info ""
    print_info "=========================================="
    print_info "Compliance Scan Trigger Complete"
    print_info "=========================================="
    print_info ""
    print_info "Scans are now running and may take several minutes."
    print_info "Monitor progress: RHACS UI → Compliance → Coverage"
    print_info ""
}

# Run main function
main "$@"
