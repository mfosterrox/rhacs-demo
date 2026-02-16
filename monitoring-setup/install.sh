#!/bin/bash

# Script: monitoring-setup/install.sh
# Description: Orchestrator for advanced RHACS monitoring setup
# Usage: ./install.sh [PASSWORD]
#        ./install.sh  (will attempt to retrieve password from cluster)

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_DIR="${SCRIPT_DIR}"
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
# Main Function
#================================================================
main() {
    echo ""
    print_info "========================================================================"
    print_info "RHACS Advanced Monitoring Setup"
    print_info "========================================================================"
    echo ""
    print_info "This setup installs advanced monitoring and dashboards:"
    print_info "  1. Disable default OpenShift monitoring (required for custom Prometheus)"
    print_info "  2. Cluster Observability Operator (includes Perses)"
    print_info "  3. RHACS metrics configuration (requires ROX_API_TOKEN)"
    print_info "  4. Prometheus authentication + MonitoringStack"
    print_info "  5. Perses dashboards in OpenShift console"
    echo ""
    
    # Check prerequisites
    if ! command -v oc >/dev/null 2>&1; then
        print_error "oc CLI not found"
        exit 1
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        print_error "jq not found"
        exit 1
    fi
    
    if ! oc whoami >/dev/null 2>&1; then
        print_error "Not connected to OpenShift cluster"
        print_error "Please run: oc login <your-cluster>"
        exit 1
    fi
    
    if [ ! -d "${SETUP_DIR}/monitoring" ]; then
        print_error "Monitoring directory not found: ${SETUP_DIR}/monitoring"
        exit 1
    fi
    
    print_info "Connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    echo ""
    
    # Check for ROX_API_TOKEN (required for scripts 03 and 04)
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_error "ROX_API_TOKEN is required for RHACS configuration"
        print_error ""
        print_error "RHACS requires API tokens for:"
        print_error "  - Script 03: Configure metrics endpoints"
        print_error "  - Script 04: Configure RBAC (Permission Sets, Roles)"
        print_error ""
        print_error "To generate an API token:"
        print_error "  1. Get admin password:"
        print_error "     ROX_PASSWORD=\$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d)"
        print_error "  2. Get Central URL:"
        print_error "     CENTRAL_URL=\$(oc get route central -n stackrox -o jsonpath='{.spec.host}')"
        print_error "  3. Generate token:"
        print_error "     curl -k -X POST -u \"admin:\${ROX_PASSWORD}\" \\"
        print_error "       -H \"Content-Type: application/json\" \\"
        print_error "       \"https://\${CENTRAL_URL}/v1/apitokens/generate\" \\"
        print_error "       -d '{\"name\":\"monitoring-setup\",\"roles\":[\"Admin\"]}' | jq -r '.token'"
        print_error "  4. Export the token:"
        print_error "     export ROX_API_TOKEN=<token>"
        print_error ""
        exit 1
    fi
    
    print_info "✓ ROX_API_TOKEN found"
    
    print_info ""
    print_info "Running setup scripts..."
    print_info "========================="
    print_info ""
    
    # Run setup scripts in order
    for script in "${SETUP_DIR}"/[0-9][0-9]-*.sh; do
        if [ -f "${script}" ]; then
            print_info "Executing: $(basename "${script}")"
            
            if bash "${script}"; then
                print_info "✓ Successfully completed: $(basename "${script}")"
            else
                print_error "✗ Failed: $(basename "${script}")"
                exit 1
            fi
            
            print_info ""
        fi
    done
    
    print_info ""
    print_info "========================================================================"
    print_info "Advanced Setup Complete!"
    print_info "========================================================================"
    echo ""
    print_info "Resources created:"
    print_info "  ✓ Default OpenShift monitoring disabled"
    print_info "  ✓ Cluster Observability Operator"
    print_info "  ✓ RHACS metrics configured (1-minute gathering)"
    print_info "  ✓ RHACS RBAC configured (Permission Set, Role, Auth Provider)"
    print_info "  ✓ MonitoringStack (Prometheus with RHACS scraping)"
    print_info "  ✓ Perses Dashboard"
    print_info "  ✓ Perses Datasource"
    print_info "  ✓ UI Plugin (console integration)"
    echo ""
    
    local console_url=$(oc get route console -n openshift-console -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${console_url}" ]; then
        print_info "Access your dashboard:"
        print_info "  ${console_url}"
        print_info "  → Observe → Dashboards → 'Advanced Cluster Security / Overview'"
        echo ""
    fi
}

# Run main function
main "$@"
