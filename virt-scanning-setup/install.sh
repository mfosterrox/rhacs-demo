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
    echo "This automated script will:"
    echo "  1. Install virtctl CLI tool"
    echo "  2. Configure RHACS for VM scanning"
    echo "  3. Enable VSOCK in OpenShift Virtualization"
    echo "  4. Deploy 4 RHEL VMs with roxagent"
    echo ""
    echo "Sample VMs:"
    echo "  • rhel-webserver"
    echo "  • rhel-database"
    echo "  • rhel-devtools"
    echo "  • rhel-monitoring"
    echo ""
    echo "After deployment, you'll register VMs and install packages"
    echo "to populate vulnerability data in RHACS."
    echo ""
    echo "⏱️  Total time: ~5 minutes"
    echo ""
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
    
    if [ ! -f "${SCRIPT_DIR}/02-deploy-sample-vms.sh" ]; then
        print_error "02-deploy-sample-vms.sh not found in ${SCRIPT_DIR}"
        return 1
    fi
    
    print_info "Deploying 4 sample VMs..."
    
    # Export AUTO_CONFIRM to skip prompts
    export AUTO_CONFIRM=true
    
    if ! bash "${SCRIPT_DIR}/02-deploy-sample-vms.sh"; then
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
    echo "  ✓ virtctl CLI tool installed"
    echo "  ✓ RHACS Central, Sensor, Collector (ROX_VIRTUAL_MACHINES=true)"
    echo "  ✓ OpenShift Virtualization VSOCK feature gate enabled"
    echo "  ✓ Collector hostNetwork + DNS configured for VSOCK"
    echo "  ✓ 4 RHEL VMs deployed with roxagent:"
    echo "    • rhel-webserver"
    echo "    • rhel-database"
    echo "    • rhel-devtools"
    echo "    • rhel-monitoring"
    
    echo ""
    print_header "⏱️  Deployment Timeline:"
    echo ""
    echo "  Now      VMs deploying"
    echo "  +3 min   VMs booting, cloud-init running"
    echo "  +5 min   roxagent running, VMs visible in RHACS (no packages yet)"
    echo ""
    print_header "Next Steps:"
    echo ""
    echo "  1. Wait 5 minutes for VMs to boot, then check:"
    echo "     $ oc get vmi -n default"
    echo ""
    echo "  2. Access VMs with console (password: redhat):"
    echo "     $ virtctl console rhel-webserver -n default"
    echo ""
    echo "  3. Register each VM and install packages:"
    echo "     Inside VM console:"
    echo "     $ sudo subscription-manager register --username <user> --password <pass> --auto-attach"
    echo "     $ sudo subscription-manager repos --enable rhel-9-for-x86_64-baseos-rpms --enable rhel-9-for-x86_64-appstream-rpms"
    echo "     $ sudo dnf install -y <packages>  # httpd nginx php, etc."
    echo "     $ sudo systemctl restart roxagent"
    echo ""
    echo "  4. Wait 2-3 minutes, then view results in RHACS UI:"
    CENTRAL_URL="https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || echo 'central-stackrox')"
    echo "     ${CENTRAL_URL}"
    echo "     → Platform Configuration → Clusters → Virtual Machines"
    echo ""
    print_info "VMs will show in RHACS immediately (without vulnerabilities)"
    print_info "After installing packages, vulnerability data will appear"
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
    echo "  • ${SCRIPT_DIR}/02-deploy-sample-vms.sh"
    echo ""
    exit $exit_code
}

#================================================================
# Install virtctl
#================================================================
install_virtctl() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_step "Installing virtctl CLI Tool"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    # Check if virtctl already exists
    if command -v virtctl &>/dev/null; then
        local current_version=$(virtctl version --client 2>/dev/null | grep -oP 'GitVersion:"v\K[^"]+' || echo "unknown")
        print_info "✓ virtctl is already installed (version: ${current_version})"
        sleep 1
        return 0
    fi
    
    print_info "Installing virtctl CLI tool..."
    
    # Determine architecture
    local arch=$(uname -m)
    local virtctl_binary="virtctl-linux-amd64"
    
    case "$arch" in
        x86_64)
            virtctl_binary="virtctl-linux-amd64"
            ;;
        aarch64|arm64)
            virtctl_binary="virtctl-linux-arm64"
            ;;
        *)
            print_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
    
    print_info "Detected architecture: $arch"
    print_info "Downloading virtctl..."
    
    # Get latest version
    local latest_version=$(curl -s https://api.github.com/repos/kubevirt/kubevirt/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
    
    if [ -z "$latest_version" ]; then
        print_warn "Could not determine latest version, using stable URL"
        latest_version="latest"
    else
        print_info "Latest version: $latest_version"
    fi
    
    # Download virtctl
    local download_url="https://github.com/kubevirt/kubevirt/releases/${latest_version}/download/${virtctl_binary}"
    local temp_file="/tmp/virtctl-download"
    
    if ! curl -L -o "$temp_file" "$download_url" 2>&1 | grep -v "%" || [ ! -f "$temp_file" ]; then
        print_error "Failed to download virtctl"
        return 1
    fi
    
    print_info "✓ Downloaded virtctl"
    
    # Make executable
    chmod +x "$temp_file"
    
    # Try to install to /usr/local/bin (preferred), fallback to ~/.local/bin
    local install_path=""
    
    if [ -w /usr/local/bin ]; then
        install_path="/usr/local/bin/virtctl"
        print_info "Installing to /usr/local/bin/virtctl..."
        mv "$temp_file" "$install_path"
    elif sudo -n true 2>/dev/null; then
        install_path="/usr/local/bin/virtctl"
        print_info "Installing to /usr/local/bin/virtctl (with sudo)..."
        sudo mv "$temp_file" "$install_path"
        sudo chmod +x "$install_path"
    else
        # Fallback to user local bin
        install_path="${HOME}/.local/bin/virtctl"
        mkdir -p "${HOME}/.local/bin"
        print_info "Installing to ~/.local/bin/virtctl..."
        mv "$temp_file" "$install_path"
        
        # Check if ~/.local/bin is in PATH
        if [[ ":$PATH:" != *":${HOME}/.local/bin:"* ]]; then
            print_warn "~/.local/bin is not in your PATH"
            print_info "Add this to your ~/.bashrc or ~/.zshrc:"
            echo '  export PATH="$HOME/.local/bin:$PATH"'
            echo ""
            print_info "For this session, run:"
            echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
            echo ""
        fi
    fi
    
    # Verify installation
    if [ -f "$install_path" ] && [ -x "$install_path" ]; then
        local installed_version=$("$install_path" version --client 2>/dev/null | grep -oP 'GitVersion:"v\K[^"]+' || echo "unknown")
        print_info "✓ virtctl installed successfully to: $install_path"
        print_info "  Version: $installed_version"
        echo ""
        print_info "virtctl is used for VM management and debugging:"
        echo "  • virtctl console <vm-name> -n <namespace>  # Connect to VM console"
        echo "  • virtctl ssh cloud-user@<vm-name>          # SSH into VM"
        echo "  • virtctl start/stop/restart <vm-name>      # VM lifecycle"
        echo ""
        sleep 2
        return 0
    else
        print_error "Installation verification failed"
        return 1
    fi
}

#================================================================
# Main execution
#================================================================
main() {
    display_banner
    
    # Install virtctl first
    install_virtctl || handle_error "Install virtctl"
    
    echo ""
    read -p "Press Enter to continue..."
    
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
