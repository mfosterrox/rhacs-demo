#!/bin/bash

set -euo pipefail

# Trap to show error location
trap 'echo "Error at line $LINENO"' ERR

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

# Function to check if a variable exists in ~/.bashrc or current environment
check_variable() {
    local var_name=$1
    local description=$2
    
    # First check if it's in ~/.bashrc
    if grep -q "^export ${var_name}=" ~/.bashrc 2>/dev/null || grep -q "^${var_name}=" ~/.bashrc 2>/dev/null; then
        print_info "Found ${var_name} in ~/.bashrc"
        return 0
    # If not in ~/.bashrc, check if it's set in current environment
    elif [ -n "${!var_name:-}" ]; then
        print_info "Found ${var_name} in current environment"
        return 0
    else
        print_error "${var_name} not found in ~/.bashrc or environment"
        print_warn "Description: ${description}"
        return 1
    fi
}

# Function to add missing RHACS variables to ~/.bashrc by fetching from the cluster
add_bashrc_vars_from_cluster() {
    local ns="${RHACS_NAMESPACE:-stackrox}"
    local route="${RHACS_ROUTE_NAME:-central}"

    touch ~/.bashrc

    if ! grep -qE "^(export[[:space:]]+)?ROX_CENTRAL_URL=" ~/.bashrc 2>/dev/null; then
        local url
        url=$(oc get route "${route}" -n "${ns}" -o jsonpath='https://{.spec.host}' 2>/dev/null) || true
        if [ -n "${url}" ]; then
            echo "export ROX_CENTRAL_URL=\"${url}\"" >> ~/.bashrc
            print_info "Added ROX_CENTRAL_URL to ~/.bashrc"
        fi
    fi

    if ! grep -qE "^(export[[:space:]]+)?ROX_PASSWORD=" ~/.bashrc 2>/dev/null; then
        local password
        # Try multiple common locations for the plaintext admin password
        
        # Option 1: central-htpasswd secret with 'password' field
        password=$(oc get secret central-htpasswd -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        
        # Option 2: admin-password secret
        if [ -z "${password}" ]; then
            password=$(oc get secret admin-password -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        
        # Option 3: stackrox-central-services secret
        if [ -z "${password}" ]; then
            password=$(oc get secret stackrox-central-services -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        
        if [ -n "${password}" ]; then
            local escaped
            escaped=$(printf '%s' "${password}" | sed "s/'/'\\\\''/g")
            echo "export ROX_PASSWORD='${escaped}'" >> ~/.bashrc
            print_info "Added ROX_PASSWORD to ~/.bashrc"
        fi
    fi

    if ! grep -qE "^(export[[:space:]]+)?RHACS_NAMESPACE=" ~/.bashrc 2>/dev/null; then
        echo "export RHACS_NAMESPACE=\"${ns}\"" >> ~/.bashrc
        print_info "Added RHACS_NAMESPACE to ~/.bashrc"
    fi

    if ! grep -qE "^(export[[:space:]]+)?RHACS_ROUTE_NAME=" ~/.bashrc 2>/dev/null; then
        echo "export RHACS_ROUTE_NAME=\"${route}\"" >> ~/.bashrc
        print_info "Added RHACS_ROUTE_NAME to ~/.bashrc"
    fi
}

# Function to export variables from ~/.bashrc without sourcing (avoids exit from /etc/bashrc etc)
export_bashrc_vars() {
    local vars=(ROX_CENTRAL_URL ROX_PASSWORD RHACS_NAMESPACE RHACS_ROUTE_NAME KUBECONFIG GUID CLOUDUSER)
    [ ! -f ~/.bashrc ] && return 0
    
    for var in "${vars[@]}"; do
        local line
        line=$(grep -E "^(export[[:space:]]+)?${var}=" ~/.bashrc 2>/dev/null | head -1)
        if [ -n "$line" ]; then
            [[ "$line" =~ ^export[[:space:]]+ ]] || line="export $line"
            eval "$line" 2>/dev/null || true
        fi
    done
}

# Main installation function
main() {
    print_info "Starting RHACS Demo Environment Setup"
    print_info "======================================"
    echo "" >&2  # Flush stderr
    
    # Load variables from ~/.bashrc (parse instead of source to avoid exit from /etc/bashrc)
    print_info "Loading variables from ~/.bashrc..."
    export_bashrc_vars || true

    # If cluster is accessible, populate missing variables from RHACS installation
    if oc whoami &>/dev/null; then
        print_info "Cluster accessible - populating missing variables from RHACS installation..."
        trap - ERR
        set +e
        add_bashrc_vars_from_cluster || true
        set -euo pipefail
        trap 'echo "Error at line $LINENO"' ERR
        export_bashrc_vars || true
    fi

    # Required variables and credentials
    print_info "Checking for required variables and credentials..."
    echo ""  # Ensure output is flushed
    
    local missing_vars=0
    
    # Check for RHACS API/CLI credentials (needed for roxctl and API calls)
    print_info "Checking ROX_CENTRAL_URL..."
    if ! check_variable "ROX_CENTRAL_URL" "RHACS Central URL for API access and roxctl CLI"; then
        missing_vars=$((missing_vars + 1))
    fi
    print_info "Checking ROX_PASSWORD..."
    if ! check_variable "ROX_PASSWORD" "RHACS Central password for API access and roxctl CLI"; then
        missing_vars=$((missing_vars + 1))
    fi
    
    # Optional but recommended variables
    if ! check_variable "RHACS_NAMESPACE" "Namespace where RHACS is installed (default: stackrox)"; then
        print_warn "RHACS_NAMESPACE not set - will use default: stackrox"
    fi
    if ! check_variable "RHACS_ROUTE_NAME" "Name of the RHACS route (default: central)"; then
        print_warn "RHACS_ROUTE_NAME not set - will use default: central"
    fi
    
    # Set RHACS version (defaults to 4.9.2 if not provided)
    if [ -z "${RHACS_VERSION:-}" ]; then
        export RHACS_VERSION="4.9.2"
    fi
    print_info "Using RHACS version: ${RHACS_VERSION}"
    
    echo ""  # Ensure output is flushed
    
    if [ "${missing_vars}" -gt 0 ]; then
        print_error ""
        print_error "Missing ${missing_vars} required variable(s)"
        print_error "Please add the missing variables to ~/.bashrc or export them in your environment"
        print_error ""
        print_error "Required variables:"
        print_error "  - ROX_CENTRAL_URL"
        print_error "  - ROX_PASSWORD"
        print_error ""
        exit 1
    fi
    
    print_info "All required variables found"
    print_info ""
    
    # Ensure setup directory exists
    print_info "Checking for setup directory: ${SETUP_DIR}"
    if [ ! -d "${SETUP_DIR}" ]; then
        print_error "Setup directory not found: ${SETUP_DIR}"
        exit 1
    fi
    print_info "✓ Setup directory found"
    
    # Ensure we have the latest variables from ~/.bashrc
    export_bashrc_vars || true
    
    # Verify we can connect to the cluster (optional, but recommended for verification scripts)
    print_info "Verifying cluster connectivity..."
    if ! oc whoami &>/dev/null; then
        print_warn "Cannot connect to OpenShift cluster. Some verification steps may fail."
        print_warn "Please ensure KUBECONFIG is set if you need cluster access."
    else
        print_info "Successfully connected to cluster: $(oc whoami --show-server 2>/dev/null || echo 'unknown')"
    fi
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
    print_info ""
    
    # Display important connection information
    print_info "RHACS Central Access Information:"
    print_info "=================================="
    
    if [ -n "${ROX_CENTRAL_URL:-}" ]; then
        print_info "Central URL: ${ROX_CENTRAL_URL}"
    fi
    
    if [ -n "${ROX_PASSWORD:-}" ]; then
        print_info "Admin Password: ${ROX_PASSWORD}"
    else
        # Try to fetch it if not already loaded from multiple possible locations
        local password
        local ns="${RHACS_NAMESPACE:-stackrox}"
        
        # Option 1: central-htpasswd secret with 'password' field
        password=$(oc get secret central-htpasswd -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        
        # Option 2: admin-password secret
        if [ -z "${password}" ]; then
            password=$(oc get secret admin-password -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        
        # Option 3: stackrox-central-services secret
        if [ -z "${password}" ]; then
            password=$(oc get secret stackrox-central-services -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
        fi
        
        if [ -n "${password}" ]; then
            print_info "Admin Password: ${password}"
        else
            print_warn "Could not retrieve admin password from cluster secrets"
            print_warn "Please check your RHACS installation or set ROX_PASSWORD manually"
        fi
    fi
    
    if [ -n "${RHACS_VERSION:-}" ]; then
        print_info "RHACS Version: ${RHACS_VERSION}"
    fi
    
    print_info ""
    print_info "Username: admin"
    print_info ""
}

# Run main function
main "$@"
