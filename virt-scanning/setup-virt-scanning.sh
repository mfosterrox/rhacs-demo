#!/bin/bash

# Script: setup-virt-scanning.sh
# Description: Master script to set up complete RHACS VM vulnerability scanning environment

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

#================================================================
# Configuration
#================================================================
SKIP_ENV_CHECK="${SKIP_ENV_CHECK:-false}"
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
    echo "  3. Verify environment prerequisites"
    echo "  4. Prepare VM image configuration (cloud-init)"
    echo "  5. Deploy base RHEL VM with roxagent"
    echo "  6. Deploy 4 sample VMs with different DNF packages"
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
# Step 1: Configure RHACS and enable VSOCK
#================================================================
step_configure_platform() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 1: Configure RHACS Platform and Enable VSOCK"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/install.sh" ]; then
        print_error "install.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Running install.sh..."
    if ! bash "${SCRIPT_DIR}/install.sh"; then
        print_error "Platform configuration failed"
        return 1
    fi
    
    print_info "✓ Platform configuration complete"
    sleep 2
}

#================================================================
# Step 2: Verify environment
#================================================================
step_verify_environment() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 2: Verify Environment Prerequisites"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ "${SKIP_ENV_CHECK}" == "true" ]; then
        print_warn "Skipping environment check (SKIP_ENV_CHECK=true)"
        return 0
    fi
    
    if [ ! -f "${SCRIPT_DIR}/01-check-env.sh" ]; then
        print_error "01-check-env.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Running environment checks..."
    if ! bash "${SCRIPT_DIR}/01-check-env.sh"; then
        print_warn "Some prerequisites not met - continuing anyway"
        print_info "Note: Setup may encounter issues if prerequisites are missing"
    fi
    
    print_info "✓ Environment verification complete"
    sleep 2
}

#================================================================
# Step 3: Build VM image configuration
#================================================================
step_build_vm_image() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 3: Prepare VM Image Configuration"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/02-build-vm-image.sh" ]; then
        print_error "02-build-vm-image.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Running VM image preparation (using cloud-init method)..."
    
    # Always use cloud-init method (recommended)
    export IMAGE_METHOD=cloud-init
    
    if ! bash "${SCRIPT_DIR}/02-build-vm-image.sh"; then
        print_error "VM image preparation failed"
        return 1
    fi
    
    print_info "✓ VM image configuration complete"
    sleep 2
}

#================================================================
# Step 4: Deploy base VM
#================================================================
step_deploy_base_vm() {
    if [ "${DEPLOY_BASE_VM}" != "true" ]; then
        print_warn "Skipping base VM deployment (DEPLOY_BASE_VM=false)"
        return 0
    fi
    
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 4: Deploy Base RHEL VM"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/03-deploy-vm.sh" ]; then
        print_error "03-deploy-vm.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Deploying base RHEL VM with roxagent..."
    if ! bash "${SCRIPT_DIR}/03-deploy-vm.sh"; then
        print_error "Base VM deployment failed"
        return 1
    fi
    
    print_info "✓ Base VM deployment complete"
    sleep 2
}

#================================================================
# Step 5: Deploy sample VMs
#================================================================
step_deploy_sample_vms() {
    if [ "${DEPLOY_SAMPLE_VMS}" != "true" ]; then
        print_warn "Skipping sample VMs deployment (DEPLOY_SAMPLE_VMS=false)"
        return 0
    fi
    
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Step 5: Deploy Sample VMs with DNF Packages"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    if [ ! -f "${SCRIPT_DIR}/04-deploy-sample-vms.sh" ]; then
        print_error "04-deploy-sample-vms.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Deploying 4 sample VMs with different package profiles..."
    
    # Export AUTO_CONFIRM to skip prompts
    export AUTO_CONFIRM=true
    
    if ! bash "${SCRIPT_DIR}/04-deploy-sample-vms.sh"; then
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
    echo "  ✓ Cloud-init configuration for roxagent deployment"
    
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
    echo "  1. Wait 5-10 minutes for VMs to fully boot and install packages"
    echo ""
    echo "  2. Check VM status:"
    echo "     $ oc get vmi -n default"
    echo ""
    echo "  3. View vulnerabilities in RHACS UI:"
    echo "     Platform Configuration → Clusters → Virtual Machines"
    echo ""
    echo "  4. Access a VM console (optional):"
    echo "     $ virtctl console rhel-webserver -n default"
    echo ""
    echo "  5. Check roxagent status inside VM:"
    echo "     $ systemctl status roxagent"
    echo "     $ journalctl -u roxagent -f"
    echo ""
    
    print_warn "Important: VMs need valid RHEL subscriptions for package updates"
    echo "           Register inside each VM:"
    echo "           $ subscription-manager register --username <user> --password <pass>"
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
    echo "  • ${SCRIPT_DIR}/install.sh"
    echo "  • ${SCRIPT_DIR}/01-check-env.sh"
    echo "  • ${SCRIPT_DIR}/02-build-vm-image.sh"
    echo "  • ${SCRIPT_DIR}/03-deploy-vm.sh"
    echo "  • ${SCRIPT_DIR}/04-deploy-sample-vms.sh"
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
    step_configure_platform || handle_error "Configure Platform"
    step_verify_environment || handle_error "Verify Environment"
    step_build_vm_image || handle_error "Build VM Image"
    step_deploy_base_vm || handle_error "Deploy Base VM"
    step_deploy_sample_vms || handle_error "Deploy Sample VMs"
    
    # Show summary
    display_summary
}

# Check we're in the right directory
if [ ! -f "${SCRIPT_DIR}/install.sh" ]; then
    print_error "This script must be run from the virt-scanning directory"
    print_info "Expected location: ${SCRIPT_DIR}/install.sh"
    exit 1
fi

main "$@"
