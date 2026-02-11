#!/bin/bash

set -euo pipefail

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

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
DEMO_APPS_REPO="https://github.com/mfosterrox/demo-applications.git"
DEMO_APPS_DIR="${HOME}/demo-applications"

# Function to check if repository exists and is valid
is_repo_valid() {
    local repo_dir=$1
    if [ ! -d "${repo_dir}/.git" ]; then
        return 1
    fi
    if ! git -C "${repo_dir}" rev-parse --git-dir >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Function to clone or update demo applications repository
setup_demo_apps_repo() {
    print_step "Setting up demo applications repository..."
    
    if is_repo_valid "${DEMO_APPS_DIR}"; then
        print_info "Repository already exists at ${DEMO_APPS_DIR}"
        print_info "Updating repository..."
        if git -C "${DEMO_APPS_DIR}" pull 2>/dev/null; then
            print_info "✓ Repository updated"
        else
            print_warn "Could not update repository (might be up to date or has local changes)"
        fi
    else
        print_info "Cloning demo applications repository..."
        if git clone "${DEMO_APPS_REPO}" "${DEMO_APPS_DIR}"; then
            print_info "✓ Repository cloned successfully"
        else
            print_error "Failed to clone repository"
            return 1
        fi
    fi
    
    return 0
}

# Function to check if applications are already deployed
are_apps_deployed() {
    # Check for some common deployments from the demo-applications repo
    local namespaces=("frontend" "backend" "payments" "ctf-web-to-system")
    local deployed_count=0
    
    for ns in "${namespaces[@]}"; do
        if oc get namespace "${ns}" >/dev/null 2>&1; then
            deployed_count=$((deployed_count + 1))
        fi
    done
    
    # If 2 or more namespaces exist, consider apps as deployed
    if [ ${deployed_count} -ge 2 ]; then
        return 0
    fi
    return 1
}

# Function to deploy applications
deploy_applications() {
    print_step "Deploying applications..."
    
    if [ ! -d "${DEMO_APPS_DIR}/k8s-deployment-manifests" ]; then
        print_error "Deployment manifests not found at: ${DEMO_APPS_DIR}/k8s-deployment-manifests"
        return 1
    fi
    
    print_info "Applying k8s-deployment-manifests..."
    local failed=false
    
    # Apply with continue on error to deploy as many as possible
    if ! oc apply -f "${DEMO_APPS_DIR}/k8s-deployment-manifests/" --recursive 2>&1 | tee /tmp/deploy-output.log; then
        print_warn "Some resources may have failed to apply"
        failed=true
    fi
    
    # Check output for actual errors vs warnings
    if grep -qi "error" /tmp/deploy-output.log && ! grep -qi "created\|configured\|unchanged" /tmp/deploy-output.log; then
        print_error "Deployment failed with errors"
        rm -f /tmp/deploy-output.log
        return 1
    fi
    
    rm -f /tmp/deploy-output.log
    
    if [ "${failed}" = true ]; then
        print_warn "Deployment completed with some warnings"
    else
        print_info "✓ Applications deployed successfully"
    fi
    
    return 0
}

# Function to list deployed namespaces
list_deployed_apps() {
    print_info ""
    print_info "Deployed application namespaces:"
    local common_apps=("frontend" "backend" "payments" "medical-app" "ctf-web-to-system" "ip-masq-agent")
    local found=false
    
    for ns in "${common_apps[@]}"; do
        if oc get namespace "${ns}" >/dev/null 2>&1; then
            print_info "  ✓ ${ns}"
            found=true
        fi
    done
    
    if [ "${found}" = false ]; then
        print_warn "No application namespaces found"
    fi
}

# Main function
main() {
    print_info "=========================================="
    print_info "Application Deployment"
    print_info "=========================================="
    print_info ""
    
    # Setup repository
    if ! setup_demo_apps_repo; then
        print_error "Failed to setup demo applications repository"
        exit 1
    fi
    
    print_info ""
    
    # Check if already deployed
    print_step "Checking for existing deployments..."
    if are_apps_deployed; then
        print_info "✓ Applications appear to be already deployed"
        list_deployed_apps
        print_info ""
        print_info "Skipping deployment"
    else
        print_info "Applications not found, proceeding with deployment..."
        print_info ""
        
        # Deploy applications
        if ! deploy_applications; then
            print_error "Failed to deploy applications"
            exit 1
        fi
        
        list_deployed_apps
    fi
    
    print_info ""
    print_info "=========================================="
    print_info "Application Deployment Complete"
    print_info "=========================================="
    print_info ""
    print_info "Repository location: ${DEMO_APPS_DIR}"
    print_info ""
    print_info "To check application status:"
    print_info "  oc get pods -A | grep -E 'frontend|backend|payments'"
    print_info ""
}

# Run main function
main "$@"
