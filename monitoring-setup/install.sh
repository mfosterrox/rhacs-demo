#!/bin/bash

# Script: advanced-setup/install.sh
# Description: Orchestrator for advanced RHACS monitoring setup
# Usage: ./advanced-setup/install.sh or cd advanced-setup && ./install.sh

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
    print_info "  1. Cluster Observability Operator (includes Perses)"
    print_info "  2. RHACS metrics configuration (requires ROX_API_TOKEN)"
    print_info "  3. Prometheus authentication + MonitoringStack"
    print_info "  4. Perses dashboards in OpenShift console"
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
    
    # Check for ROX_API_TOKEN (needed for script 02)
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_warn "ROX_API_TOKEN is not set"
        print_warn "Script 02 (configure-rhacs-metrics) will fail without it"
        print_warn ""
        print_warn "To generate a token, run:"
        print_warn "  curl -k -X POST -u \"admin:\${ROX_PASSWORD}\" \\"
        print_warn "    -H \"Content-Type: application/json\" \\"
        print_warn "    \"\${ROX_CENTRAL_URL}/v1/apitokens/generate\" \\"
        print_warn "    -d '{\"name\":\"dashboard-token\",\"roles\":[\"Admin\"]}'"
        print_warn ""
        
        read -p "Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Exiting. Please set ROX_API_TOKEN and try again."
            exit 0
        fi
    fi
    
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
    print_info "  ✓ Cluster Observability Operator"
    print_info "  ✓ RHACS metrics configured (1-minute gathering)"
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
