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
VIRTCTL_DEFAULT_VERSION="${VIRTCTL_DEFAULT_VERSION:-v1.6.3}"

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
    echo "  4. Deploy RHEL webserver VM (httpd, cloud-init)"
    echo ""
    echo "VM: rhel-webserver (Apache)"
    echo ""
    echo "Use console after boot to register subscription and install packages."
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
    
    local vms_to_delete=("rhel-webserver")
    
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
    
    print_info "Deploying webserver VM..."
    
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
    echo "  ✓ Webserver VM deployed (cloud-init):"
    echo "    • rhel-webserver"
    
    echo ""
    print_header "⏱️  Deployment Timeline:"
    echo ""
    echo "  Now      VM deploying"
    echo "  +3 min   VM booting, cloud-init running"
    echo "  +5 min   VM ready, httpd serving /var/www/html"
    echo ""
    print_header "Next Steps:"
    echo ""
    echo "  1. Wait ~5 minutes for VM to boot, then connect via console:"
    echo "     $ virtctl console rhel-webserver -n default"
    echo "     (login: cloud-user / redhat)"
    echo ""
    echo "  2. Optional: register RHEL subscription for vulnerability scanning:"
    echo "     $ sudo subscription-manager register --username <user> --password <pass> --auto-attach"
    echo ""
    echo "  3. Check status: oc get vmi -n default"
    echo ""
    CENTRAL_URL="https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}' 2>/dev/null || echo 'central-stackrox')"
    echo "  RHACS UI: ${CENTRAL_URL}"
    echo "     → Platform Configuration → Clusters → Virtual Machines"
    
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
    
    # Get cluster KubeVirt version to match virtctl (avoids client/server version mismatch)
    local cluster_version=""
    local raw_version
    raw_version=$(oc get kubevirt -A -o jsonpath='{.items[0].status.observedKubeVirtVersion}' 2>/dev/null || true)
    if [ -n "${raw_version}" ] && [ "${raw_version}" != "null" ] && [[ ! "${raw_version}" =~ ^sha256: ]]; then
        cluster_version=$(echo "${raw_version}" | grep -oP '^v?\d+\.\d+\.\d+' | sed 's/^/v/')
    fi
    
    # If observedKubeVirtVersion is a hash (digest-based install), get server version from virtctl
    if [ -z "${cluster_version}" ] && command -v virtctl &>/dev/null; then
        cluster_version=$(virtctl version 2>/dev/null | grep -i "server" | grep -oP 'v?\d+\.\d+\.\d+' | head -1 | sed 's/^/v/')
        [ -n "${cluster_version}" ] && print_info "Cluster KubeVirt version from virtctl: ${cluster_version}"
    fi
    
    # Use cluster version when available, else default (e.g. v1.6.3)
    local target_version="${cluster_version:-${VIRTCTL_DEFAULT_VERSION}}"
    # Ensure target has v prefix
    [[ "${target_version}" =~ ^v ]] || target_version="v${target_version}"
    print_info "Target virtctl version: ${target_version}"
    
    # Check if virtctl already exists and matches target version
    if command -v virtctl &>/dev/null; then
        local current_version
        current_version=$(virtctl version --client 2>/dev/null | grep -oP 'GitVersion:"v\K[^"]+' || virtctl version 2>/dev/null | grep -oP 'Client Version:\s*v\K[^\s]+' || echo "unknown")
        print_info "Installed virtctl version: ${current_version}"
        if [ -n "${target_version}" ]; then
            local target_major_minor
            target_major_minor=$(echo "${target_version}" | grep -oP '\d+\.\d+' | sed 's/^/v/')
            local current_major_minor
            current_major_minor=$(echo "${current_version}" | grep -oP '\d+\.\d+' | sed 's/^/v/')
            if [ -n "${target_major_minor}" ] && [ -n "${current_major_minor}" ] && [ "${target_major_minor}" = "${current_major_minor}" ]; then
                print_info "✓ virtctl matches target version (${target_major_minor}.x)"
                sleep 1
                return 0
            else
                print_warn "virtctl ${current_version} does not match target ${target_version} - reinstalling..."
                local virtctl_path
                virtctl_path=$(command -v virtctl)
                if [ -n "${virtctl_path}" ]; then
                    if [ -w "${virtctl_path}" ]; then
                        rm -f "${virtctl_path}"
                        print_info "Removed ${virtctl_path}"
                    elif sudo -n true 2>/dev/null; then
                        sudo rm -f "${virtctl_path}"
                        print_info "Removed ${virtctl_path}"
                    else
                        print_error "Cannot remove virtctl (need write access or sudo). Run: sudo rm ${virtctl_path}"
                        return 1
                    fi
                fi
            fi
        else
            print_info "✓ virtctl is already installed (cluster version unknown)"
            sleep 1
            return 0
        fi
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
    
    local temp_file="/tmp/virtctl-download"
    local download_success=false
    
    # Remove any existing temp file
    rm -f "$temp_file"
    
    # Method 1: Target version (cluster or default - avoids client/server mismatch)
    if [ -n "${target_version}" ] && [ "$download_success" = false ]; then
        print_info "Trying version ${target_version} (matches cluster or default)..."
        local official_binary="virtctl-${target_version}-linux-amd64"
        if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
            official_binary="virtctl-${target_version}-linux-arm64"
        fi
        local download_url="https://github.com/kubevirt/kubevirt/releases/download/${target_version}/${official_binary}"
        
        if curl -L -f -o "$temp_file" "$download_url" 2>/dev/null; then
            if file "$temp_file" 2>/dev/null | grep -q "executable"; then
                print_info "✓ Successfully downloaded virtctl ${target_version}"
                download_success=true
            else
                rm -f "$temp_file"
            fi
        fi
    fi
    
    # Method 2: Official stable release (fallback)
    if [ "$download_success" = false ]; then
        print_info "Trying official stable release..."
        local stable_version=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt 2>/dev/null)
        
        if [ -n "$stable_version" ] && [ "$stable_version" != "null" ]; then
            print_info "Stable version: ${stable_version}"
            local official_binary="virtctl-${stable_version}-linux-amd64"
            if [ "$arch" = "aarch64" ] || [ "$arch" = "arm64" ]; then
                official_binary="virtctl-${stable_version}-linux-arm64"
            fi
            local download_url="https://github.com/kubevirt/kubevirt/releases/download/${stable_version}/${official_binary}"
            
            if curl -L -f -o "$temp_file" "$download_url" 2>/dev/null; then
                if file "$temp_file" 2>/dev/null | grep -q "executable"; then
                    print_info "✓ Successfully downloaded virtctl ${stable_version} (official stable)"
                    download_success=true
                else
                    rm -f "$temp_file"
                fi
            fi
        fi
    fi
    
    # Method 3: Fallback to known working versions
    if [ "$download_success" = false ]; then
        print_info "Trying alternative versions..."
        local versions_to_try=("v1.6.3" "v1.5.0" "v1.3.1" "v1.2.2")
        [ -n "${target_version}" ] && versions_to_try=("${target_version}" "${versions_to_try[@]}")
        
        for version in "${versions_to_try[@]}"; do
            [ -z "$version" ] || [ "$version" = "null" ] && continue
            local download_url="https://github.com/kubevirt/kubevirt/releases/download/${version}/${virtctl_binary}"
            print_info "Trying version: ${version}"
            if curl -L -f -o "$temp_file" "$download_url" 2>/dev/null; then
                if file "$temp_file" 2>/dev/null | grep -q "executable"; then
                    print_info "✓ Successfully downloaded virtctl ${version}"
                    download_success=true
                    break
                else
                    rm -f "$temp_file"
                fi
            fi
        done
    fi
    
    if [ "$download_success" = false ]; then
        print_error "Failed to download virtctl"
        print_info ""
        print_info "Manual installation (recommended method):"
        echo '  VERSION=$(curl -s https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt)'
        echo '  curl -L https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/virtctl-${VERSION}-linux-amd64 -o virtctl'
        echo '  chmod +x virtctl'
        echo '  sudo mv virtctl /usr/local/bin/virtctl'
        return 1
    fi
    
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
        echo "  • virtctl start/stop/restart <vm-name>       # VM lifecycle"
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
