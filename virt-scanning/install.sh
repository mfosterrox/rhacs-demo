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
DEPLOY_BASE_VM="${DEPLOY_BASE_VM:-true}"
DEPLOY_SAMPLE_VMS="${DEPLOY_SAMPLE_VMS:-true}"

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
    echo "This script will:"
    echo "  1. Configure RHACS platform (Central, Sensor, Collector)"
    echo "  2. Enable VSOCK support in OpenShift Virtualization"
    echo "  3. Enable hostNetwork on Collector for VSOCK access"
    echo "  4. Deploy base RHEL VM with roxagent (optional)"
    echo "  5. Deploy 4 sample VMs with different DNF packages (optional)"
    echo ""
    echo "Sample VMs include:"
    echo "  • Web Server (httpd, nginx, php)"
    echo "  • Database (postgresql, mariadb)"
    echo "  • Dev Tools (git, gcc, python, nodejs, java)"
    echo "  • Monitoring (grafana, telegraf, collectd)"
    echo ""
}

#================================================================
# Display configuration
#================================================================
display_configuration() {
    echo ""
    print_info "Configuration:"
    echo "  • Base VM deployment: ${DEPLOY_BASE_VM}"
    echo "  • Sample VMs deployment: ${DEPLOY_SAMPLE_VMS}"
    echo ""
    print_info "Starting automated setup..."
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
# Step 2: Deploy base VM
#================================================================
step_deploy_base_vm() {
    if [ "${DEPLOY_BASE_VM}" != "true" ]; then
        print_warn "Skipping base VM deployment (DEPLOY_BASE_VM=false)"
        return 0
    fi
    
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 2: Deploy Base RHEL VM"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/02-deploy-base-vm.sh" ]; then
        print_error "02-deploy-base-vm.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Deploying base RHEL VM with roxagent..."
    if ! bash "${SCRIPT_DIR}/02-deploy-base-vm.sh"; then
        print_error "Base VM deployment failed"
        return 1
    fi
    
    print_info "✓ Base VM deployment complete"
    sleep 2
}

#================================================================
# Step 3: Deploy sample VMs
#================================================================
step_deploy_sample_vms() {
    if [ "${DEPLOY_SAMPLE_VMS}" != "true" ]; then
        print_warn "Skipping sample VMs deployment (DEPLOY_SAMPLE_VMS=false)"
        return 0
    fi
    
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 3: Deploy Sample VMs with DNF Packages"
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
    echo "  ✓ Collector hostNetwork enabled for VSOCK access"
    
    if [ "${DEPLOY_BASE_VM}" == "true" ]; then
        echo "  ✓ Base RHEL VM deployed (rhel-roxagent-vm)"
    fi
    
    if [ "${DEPLOY_SAMPLE_VMS}" == "true" ]; then
        echo "  ✓ Sample VMs deployed:"
        echo "    • rhel-webserver (httpd, nginx, php)"
        echo "    • rhel-database (postgresql, mariadb)"
        echo "    • rhel-devtools (git, gcc, python, nodejs)"
        echo "    • rhel-monitoring (grafana, telegraf, collectd)"
    fi
    
    echo ""
    print_header "Next Steps:"
    echo ""
    echo "  1. Wait 10-15 minutes for VMs to fully boot and install packages"
    echo ""
    echo "  2. Check VM status:"
    echo "     $ oc get vmi -n default"
    echo ""
    echo "  3. View vulnerabilities in RHACS UI:"
    echo "     Platform Configuration → Clusters → Virtual Machines"
    echo ""
    echo "  4. VMs need valid RHEL subscriptions for package updates:"
    echo "     Inside each VM:"
    echo "     $ subscription-manager register --username <user> --password <pass>"
    echo "     $ subscription-manager attach --auto"
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
    echo "  • ${SCRIPT_DIR}/02-deploy-base-vm.sh"
    echo "  • ${SCRIPT_DIR}/03-deploy-sample-vms.sh"
    echo ""
    exit $exit_code
}

#================================================================
# Main execution
#================================================================
main() {
    display_banner
    display_configuration
    
    # Execute steps in order
    step_configure_rhacs || handle_error "Configure RHACS"
    step_deploy_base_vm || handle_error "Deploy Base VM"
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
