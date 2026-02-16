#!/bin/bash

# Script: 04-deploy-monitoring-stack.sh
# Description: Deploy Prometheus authentication and MonitoringStack
# Usage: ./04-deploy-monitoring-stack.sh [PASSWORD]

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly MONITORING_DIR="${SCRIPT_DIR}/monitoring"

# Get password from argument or environment
readonly ROX_PASSWORD="${1:-${ROX_PASSWORD:-}}"

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

#================================================================
# Get RHACS credentials
#================================================================
get_rhacs_credentials() {
    local password="${ROX_PASSWORD}"
    
    # If no password provided, try to get from secret
    if [ -z "${password}" ]; then
        print_info "No password provided, retrieving from cluster..."
        password=$(oc get secret central-htpasswd -n ${RHACS_NAMESPACE} -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
        
        if [ -z "${password}" ]; then
            print_error "Could not retrieve admin password"
            print_error "Please run: ./04-deploy-monitoring-stack.sh <PASSWORD>"
            print_error "Or set: export ROX_PASSWORD=<password>"
            exit 1
        fi
    fi
    
    echo "${password}"
}

#================================================================
# Deploy Prometheus Authentication
#================================================================
deploy_prometheus_auth() {
    print_step "Deploying Prometheus Authentication"
    echo "================================================================"
    
    print_info "Creating ServiceAccount and token..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/service-account.yaml
    
    # Wait for token to be populated
    print_info "Waiting for service account token..."
    local max_wait=60
    local waited=0
    
    while [ ${waited} -lt ${max_wait} ]; do
        local token=$(oc get secret sample-stackrox-prometheus-token -n ${RHACS_NAMESPACE} -o jsonpath='{.data.token}' 2>/dev/null || echo "")
        if [ -n "${token}" ]; then
            print_info "✓ Service account token ready"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    
    print_info "✓ ServiceAccount created"
}

#================================================================
# Configure RHACS RBAC via API
#================================================================
configure_rhacs_rbac() {
    print_step "Configuring RHACS RBAC for Prometheus via API"
    echo "================================================================"
    
    # Get credentials
    local password=$(get_rhacs_credentials)
    local central_url=$(oc get route central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    
    if [ -z "${central_url}" ]; then
        print_error "Could not get Central route"
        exit 1
    fi
    
    print_info "Central URL: https://${central_url}"
    
    # Step 1: Create Permission Set
    print_info "Creating Permission Set..."
    local perm_response=$(curl -k -s -u "admin:${password}" -X POST \
        "https://${central_url}/v1/permissionsets" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "Prometheus Server",
            "description": "Permissions for Prometheus metrics collection",
            "resources": [
                {"resource": "Administration", "access": "READ_ACCESS"},
                {"resource": "Alert", "access": "READ_ACCESS"},
                {"resource": "Cluster", "access": "READ_ACCESS"},
                {"resource": "Deployment", "access": "READ_ACCESS"},
                {"resource": "Image", "access": "READ_ACCESS"},
                {"resource": "Integration", "access": "READ_ACCESS"},
                {"resource": "Namespace", "access": "READ_ACCESS"},
                {"resource": "Node", "access": "READ_ACCESS"},
                {"resource": "WorkflowAdministration", "access": "READ_ACCESS"}
            ]
        }' 2>&1)
    
    # Check if it already exists (that's ok)
    if echo "${perm_response}" | grep -q "already exists\|\"id\":"; then
        print_info "✓ Permission Set created or already exists"
    else
        print_warn "Permission Set response: ${perm_response}"
    fi
    
    # Get Permission Set ID
    local perm_set_id=$(curl -k -s -u "admin:${password}" \
        "https://${central_url}/v1/permissionsets" | \
        jq -r '.permissionSets[] | select(.name=="Prometheus Server") | .id' 2>/dev/null || echo "")
    
    if [ -z "${perm_set_id}" ]; then
        print_error "Could not get Permission Set ID"
        print_error "Response was: ${perm_response}"
        exit 1
    fi
    
    print_info "  Permission Set ID: ${perm_set_id}"
    
    # Step 2: Create Role
    print_info "Creating Role..."
    local role_response=$(curl -k -s -u "admin:${password}" -X POST \
        "https://${central_url}/v1/roles" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"Prometheus Server\",
            \"description\": \"Role for Prometheus metrics collection\",
            \"permissionSetId\": \"${perm_set_id}\",
            \"accessScopeId\": \"io.stackrox.authz.accessscope.unrestricted\"
        }" 2>&1)
    
    if echo "${role_response}" | grep -q "already exists\|\"name\":"; then
        print_info "✓ Role created or already exists"
    else
        print_warn "Role response: ${role_response}"
    fi
    
    # Step 3: Create Auth Provider (Machine Access)
    print_info "Creating Auth Provider for ServiceAccount..."
    local auth_response=$(curl -k -s -u "admin:${password}" -X POST \
        "https://${central_url}/v1/groups/attributes" \
        -H "Content-Type: application/json" \
        -d "{
            \"key\": \"email\",
            \"value\": \"system:serviceaccount:${RHACS_NAMESPACE}:sample-stackrox-prometheus\",
            \"roleName\": \"Prometheus Server\"
        }" 2>&1)
    
    if echo "${auth_response}" | grep -q "\"key\"\|already exists\|success"; then
        print_info "✓ Auth provider configured"
    else
        print_warn "Auth provider response: ${auth_response}"
    fi
    
    print_info "✓ RHACS RBAC configured via API"
}

#================================================================
# Deploy MonitoringStack
#================================================================
deploy_monitoring_stack() {
    print_step "Deploying MonitoringStack"
    echo "================================================================"
    
    print_info "Creating MonitoringStack..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/monitoring-stack.yaml
    
    print_info "Creating ScrapeConfig..."
    oc apply -f ${MONITORING_DIR}/cluster-observability-operator/scrape-config.yaml
    
    print_info "✓ MonitoringStack deployed"
    print_info ""
    print_info "Resources created:"
    print_info "  • MonitoringStack: sample-stackrox-monitoring-stack"
    print_info "  • ScrapeConfig: sample-stackrox-scrape-config"
}

#================================================================
# Main Function
#================================================================
main() {
    # Check prerequisites
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    if [ ! -d "${MONITORING_DIR}" ]; then
        print_error "Monitoring directory not found: ${MONITORING_DIR}"
        exit 1
    fi
    
    # Execute setup steps
    deploy_prometheus_auth
    echo ""
    
    configure_rhacs_rbac
    echo ""
    
    deploy_monitoring_stack
    
    # Wait for resources to stabilize
    print_info ""
    print_info "Waiting for resources to stabilize..."
    sleep 10
    
    # Verify MonitoringStack was created
    if oc get monitoringstack sample-stackrox-monitoring-stack -n ${RHACS_NAMESPACE} >/dev/null 2>&1; then
        print_info "✓ MonitoringStack created successfully"
    else
        print_warn "⊘ MonitoringStack not found - may still be creating"
    fi
    
    # Test metrics endpoint
    print_info ""
    print_info "Testing metrics endpoint..."
    local sa_token=$(oc get secret sample-stackrox-prometheus-token -n ${RHACS_NAMESPACE} -o jsonpath='{.data.token}' | base64 -d)
    local central_route=$(oc get route central -n ${RHACS_NAMESPACE} -o jsonpath='{.spec.host}')
    
    local test_result=$(curl -k -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${sa_token}" "https://${central_route}/metrics" 2>/dev/null || echo "000")
    
    if [ "${test_result}" = "200" ]; then
        print_info "✓ Metrics endpoint accessible (HTTP ${test_result})"
    else
        print_warn "⚠ Metrics endpoint returned HTTP ${test_result}"
        print_info "  This may take a few minutes to become available"
    fi
}

# Run main function
main "$@"
