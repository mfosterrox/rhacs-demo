#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SCRIPT_DIR}/setup"

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

# Function to check if a variable exists in ~/.bashrc
check_variable_in_bashrc() {
    local var_name=$1
    local description=$2
    
    if grep -q "^export ${var_name}=" ~/.bashrc 2>/dev/null || grep -q "^${var_name}=" ~/.bashrc 2>/dev/null; then
        print_info "Found ${var_name} in ~/.bashrc"
        return 0
    else
        print_error "${var_name} not found in ~/.bashrc"
        print_warn "Description: ${description}"
        return 1
    fi
}

# Function to source ~/.bashrc to get current variables
source_bashrc() {
    if [ -f ~/.bashrc ]; then
        # Source bashrc in a way that doesn't exit on errors
        set +e
        source ~/.bashrc 2>/dev/null || true
        set -e
    fi
}

# Main installation function
main() {
    print_info "Starting RHACS Demo Environment Setup"
    print_info "======================================"
    
    # Source bashrc to get current environment
    source_bashrc
    
    # Required variables and credentials
    print_info "Checking for required variables and credentials in ~/.bashrc..."
    
    local missing_vars=0
    
    # Check for OpenShift/Kubernetes credentials
    check_variable_in_bashrc "KUBECONFIG" "Path to kubeconfig file for OpenShift cluster access" || ((missing_vars++))
    check_variable_in_bashrc "OC_CLUSTER_URL" "OpenShift cluster URL (e.g., https://api.example.com:6443)" || ((missing_vars++))
    check_variable_in_bashrc "OC_CLUSTER_USER" "OpenShift cluster admin username" || ((missing_vars++))
    check_variable_in_bashrc "OC_CLUSTER_PASSWORD" "OpenShift cluster admin password" || ((missing_vars++))
    
    # Check for RHACS specific variables
    check_variable_in_bashrc "RHACS_NAMESPACE" "Namespace where RHACS is installed (default: stackrox)" || ((missing_vars++))
    check_variable_in_bashrc "RHACS_ROUTE_NAME" "Name of the RHACS route (default: central)" || ((missing_vars++))
    
    # Optional but recommended variables
    check_variable_in_bashrc "RHACS_VERSION" "Desired RHACS version (e.g., 4.5.0)" || print_warn "RHACS_VERSION not set - will use latest stable"
    
    if [ $missing_vars -gt 0 ]; then
        print_error "Missing ${missing_vars} required variable(s) in ~/.bashrc"
        print_error "Please add the missing variables to ~/.bashrc and run this script again"
        exit 1
    fi
    
    print_info "All required variables found in ~/.bashrc"
    print_info ""
    
    # Ensure setup directory exists
    if [ ! -d "${SETUP_DIR}" ]; then
        print_error "Setup directory not found: ${SETUP_DIR}"
        exit 1
    fi
    
    # Source bashrc again to ensure we have the latest variables
    source_bashrc
    
    # Verify we can connect to the cluster
    print_info "Verifying cluster connectivity..."
    if ! oc whoami &>/dev/null; then
        print_error "Cannot connect to OpenShift cluster. Please check your KUBECONFIG and credentials."
        exit 1
    fi
    print_info "Successfully connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    print_info ""
    
    # Run setup scripts in order
    print_info "Running setup scripts..."
    print_info "========================="
    
    local script_num=1
    local script_pattern=""
    
    # Find and run scripts in numerical order (01-*.sh, 02-*.sh, etc.)
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
    
    print_info "======================================"
    print_info "RHACS Demo Environment Setup Complete!"
    print_info "======================================"
}

# Run main function
main "$@"
