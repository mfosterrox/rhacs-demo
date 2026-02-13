#!/bin/bash

# Script: install.sh
# Description: Complete RHACS VM vulnerability scanning setup
# This is the main orchestration script that calls all sub-scripts

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${CYAN}[STEP]${NC} $*"; }
print_header() { echo -e "${BOLD}${BLUE}$*${NC}"; }

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Configuration
DEPLOY_BASE_VM="${DEPLOY_BASE_VM:-false}"  # Base VM not needed for demo
DEPLOY_SAMPLE_VMS="${DEPLOY_SAMPLE_VMS:-true}"

# Red Hat subscription credentials (will be prompted)
RH_USERNAME=""
RH_PASSWORD=""

#================================================================
# Display banner
#================================================================
display_banner() {
    clear
    echo ""
    print_header "╔════════════════════════════════════════════════════════════╗"
    print_header "║                                                            ║"
    print_header "║     RHACS Virtual Machine Vulnerability Scanning Setup    ║"
    print_header "║                                                            ║"
    print_header "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This automated script will:"
    echo "  1. Prompt for Red Hat subscription credentials"
    echo "  2. Configure RHACS for VM scanning"
    echo "  3. Enable VSOCK in OpenShift Virtualization"
    echo "  4. Deploy 4 RHEL VMs with packages installed"
    echo "  5. Start vulnerability scanning automatically"
    echo ""
    echo "Sample VMs (with packages):"
    echo "  • rhel-webserver: httpd, nginx, php"
    echo "  • rhel-database: postgresql, mariadb"
    echo "  • rhel-devtools: git, gcc, python, nodejs"
    echo "  • rhel-monitoring: grafana, telegraf, net-snmp"
    echo ""
    echo "⏱️  Total time: ~15 minutes"
    echo ""
}

#================================================================
# Prompt for Red Hat credentials
#================================================================
prompt_credentials() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Red Hat Subscription Credentials"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    print_info "VMs will automatically register and install packages during deployment"
    print_info "Credentials are used only during VM setup (stored in cloud-init secrets)"
    echo ""
    
    read -p "Red Hat Username: " RH_USERNAME
    read -sp "Red Hat Password: " RH_PASSWORD
    echo ""
    echo ""
    
    if [ -z "$RH_USERNAME" ] || [ -z "$RH_PASSWORD" ]; then
        print_warn "Credentials not provided"
        print_warn "VMs will deploy but packages will NOT be installed"
        print_warn "You'll need to register and install packages manually"
        echo ""
        read -p "Continue without credentials? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Setup cancelled"
            exit 1
        fi
        export INSTALL_PACKAGES="false"
    else
        print_info "✓ Credentials received"
        export INSTALL_PACKAGES="true"
        export RH_USERNAME
        export RH_PASSWORD
    fi
    
    sleep 2
}


#================================================================
# Cleanup existing VMs
#================================================================
cleanup_existing_vms() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Cleaning up existing VMs for fresh deployment"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    local vms_to_delete=(
        "rhel-webserver"
        "rhel-database"
        "rhel-devtools"
        "rhel-monitoring"
    )
    
    local found_vms=false
    
    # Check which VMs exist
    print_info "Checking for existing VMs..."
    for vm in "${vms_to_delete[@]}"; do
        if oc get vm "$vm" -n default &>/dev/null; then
            print_warn "Found existing VM: $vm"
            found_vms=true
        fi
    done
    
    if [ "$found_vms" = false ]; then
        print_info "No existing VMs found - clean slate!"
        sleep 1
        return 0
    fi
    
    echo ""
    print_info "Deleting existing VMs to ensure clean deployment..."
    
    # Delete all VMs (gracefully handle if they don't exist)
    for vm in "${vms_to_delete[@]}"; do
        if oc get vm "$vm" -n default &>/dev/null; then
            print_info "Deleting VM: $vm"
            oc delete vm "$vm" -n default --wait=false || true
        fi
    done
    
    # Wait for deletions to complete
    print_info "Waiting for VM deletions to complete..."
    local max_wait=60
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        local remaining=0
        for vm in "${vms_to_delete[@]}"; do
            if oc get vm "$vm" -n default &>/dev/null; then
                ((remaining++))
            fi
        done
        
        if [ $remaining -eq 0 ]; then
            print_info "✓ All VMs deleted successfully"
            sleep 2
            return 0
        fi
        
        sleep 5
        ((elapsed+=5))
    done
    
    print_warn "Some VMs may still be deleting in background (timeout reached)"
    print_info "Continuing with setup..."
    sleep 2
}

#================================================================
# Step 1: Configure RHACS and VSOCK
#================================================================
step_configure_rhacs() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 1: Configure RHACS Platform and Enable VSOCK"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/01-configure-rhacs.sh" ]; then
        print_error "01-configure-rhacs.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Running RHACS configuration..."
    if ! bash "${SCRIPT_DIR}/01-configure-rhacs.sh"; then
        print_error "RHACS configuration failed"
        return 1
    fi
    
    print_info "✓ RHACS configuration complete"
    sleep 2
}

#================================================================
# Step 2: Deploy VMs
#================================================================
step_deploy_sample_vms() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 2: Deploy VMs with Packages"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/03-deploy-sample-vms.sh" ]; then
        print_error "03-deploy-sample-vms.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Deploying 4 sample VMs with different package profiles..."
    
    # Export AUTO_CONFIRM to skip prompts
    export AUTO_CONFIRM=true
    
    if ! bash "${SCRIPT_DIR}/03-deploy-sample-vms.sh"; then
        print_error "Sample VMs deployment failed"
        return 1
    fi
    
    print_info "✓ Sample VMs deployment complete"
    sleep 2
}

#================================================================
# Display final summary
#================================================================
display_summary() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_header "                    Setup Complete! ✓                       "
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    print_info "What was configured:"
    echo ""
    echo "  ✓ RHACS Central, Sensor, Collector (ROX_VIRTUAL_MACHINES=true)"
    echo "  ✓ OpenShift Virtualization VSOCK feature gate enabled"
    echo "  ✓ Collector hostNetwork + DNS configured for VSOCK"
    echo "  ✓ 4 RHEL VMs deployed with roxagent:"
    echo "    • rhel-webserver (httpd, nginx, php)"
    echo "    • rhel-database (postgresql, mariadb)"
    echo "    • rhel-devtools (git, gcc, python, nodejs)"
    echo "    • rhel-monitoring (grafana, telegraf, net-snmp)"
    
    if [ "${INSTALL_PACKAGES}" == "true" ]; then
        echo "  ✓ VMs registered with Red Hat subscription"
        echo "  ✓ Packages installing via cloud-init (background)"
    else
        echo "  ⚠ No credentials provided - packages NOT installed"
    fi
    
    echo ""
    print_header "⏱️  Deployment Timeline:"
    echo ""
    echo "  Now      VMs are starting (deploying in background)"
    echo "  +5 min   VMs booting, cloud-init running"
    if [ "${INSTALL_PACKAGES}" == "true" ]; then
        echo "  +8 min   Subscription registration + package installation"
    fi
    echo "  +10 min  roxagent first scan"
    echo "  +12 min  Vulnerability data appears in RHACS"
    echo ""
    print_header "Next Steps:"
    echo ""
    echo "  1. Wait 10-15 minutes, then check status:"
    echo "     $ oc get vmi -n default"
    echo "     $ ./check-vm-status.sh"
    echo ""
    echo "  2. View results in RHACS UI:"
    CENTRAL_URL="https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || echo 'central-stackrox')"
    echo "     ${CENTRAL_URL}"
    echo "     → Platform Configuration → Clusters → Virtual Machines"
    echo ""
    
    if [ "${INSTALL_PACKAGES}" != "true" ]; then
        print_warn "To see vulnerability data, VMs need packages installed"
        print_warn "You can manually register inside each VM with:"
        print_warn "  virtctl console <vm-name> -n default"
        print_warn "  sudo subscription-manager register"
        print_warn "  sudo dnf install <packages>"
    fi
    echo ""
    
    print_info "Documentation: ${SCRIPT_DIR}/README.md"
    echo ""
}

#================================================================
# Handle errors
#================================================================
handle_error() {
    local exit_code=$?
    echo ""
    print_error "Setup failed at step: $1"
    print_info "Check the logs above for details"
    echo ""
    print_info "You can run individual scripts manually:"
    echo "  • ${SCRIPT_DIR}/01-configure-rhacs.sh"
    echo "  • ${SCRIPT_DIR}/03-deploy-sample-vms.sh"
    echo ""
    exit $exit_code
}

#================================================================
# Main execution
#================================================================
main() {
    display_banner
    prompt_credentials
    
    # Clean up existing VMs first
    cleanup_existing_vms || handle_error "Cleanup existing VMs"
    
    # Execute steps in order
    step_configure_rhacs || handle_error "Configure RHACS"
    step_deploy_sample_vms || handle_error "Deploy Sample VMs"
    
    # Show summary
    display_summary
}

# Check we're in the right directory
if [ ! -f "${SCRIPT_DIR}/01-configure-rhacs.sh" ]; then
    print_error "This script must be run from the virt-scanning directory"
    print_info "Expected location: ${SCRIPT_DIR}/01-configure-rhacs.sh"
    exit 1
fi

main "$@"
