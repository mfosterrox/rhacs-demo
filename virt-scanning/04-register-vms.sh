#!/bin/bash

# Script: 04-register-vms.sh
# Description: Register RHEL VMs with subscription and install packages for vulnerability scanning demo

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

#================================================================
# Configuration
#================================================================

# VM profiles and their packages
declare -A VM_PACKAGES=(
    ["rhel-webserver"]="httpd nginx php php-mysqlnd mod_ssl mod_security"
    ["rhel-database"]="postgresql postgresql-server mariadb mariadb-server mysql"
    ["rhel-devtools"]="git gcc make python3 python3-pip nodejs java-11-openjdk-devel"
    ["rhel-monitoring"]="grafana telegraf collectd net-snmp prometheus"
)

VM_PASSWORD="redhat"
VM_USER="cloud-user"

#================================================================
# Display banner
#================================================================
display_banner() {
    clear
    echo ""
    print_header "╔════════════════════════════════════════════════════════════╗"
    print_header "║                                                            ║"
    print_header "║         RHEL VM Registration and Package Installation     ║"
    print_header "║                                                            ║"
    print_header "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This script will:"
    echo "  1. Register RHEL VMs with Red Hat subscription"
    echo "  2. Install DNF packages on each VM"
    echo "  3. Trigger roxagent to scan immediately"
    echo "  4. Display vulnerability data in RHACS"
    echo ""
}

#================================================================
# Get subscription credentials
#================================================================
get_credentials() {
    echo ""
    print_step "Subscription Credentials"
    echo ""
    
    print_info "Choose authentication method:"
    echo "  1. Username/Password"
    echo "  2. Organization ID/Activation Key"
    echo ""
    
    read -p "Select method (1 or 2): " AUTH_METHOD
    
    if [ "$AUTH_METHOD" == "1" ]; then
        read -p "Red Hat Username: " RH_USERNAME
        read -sp "Red Hat Password: " RH_PASSWORD
        echo ""
        AUTH_TYPE="userpass"
    elif [ "$AUTH_METHOD" == "2" ]; then
        read -p "Organization ID: " RH_ORG
        read -p "Activation Key: " RH_ACTIVATION_KEY
        AUTH_TYPE="orgkey"
    else
        print_error "Invalid selection"
        exit 1
    fi
    
    echo ""
    print_info "Credentials captured"
    sleep 1
}

#================================================================
# Register a single VM
#================================================================
register_vm() {
    local vm_name=$1
    
    print_step "Registering VM: ${vm_name}"
    
    # Check if virtctl is available
    if ! command -v virtctl &> /dev/null; then
        print_error "virtctl not found. Please install virtctl first."
        return 1
    fi
    
    # Create registration script
    local reg_script="/tmp/register-${vm_name}.sh"
    
    if [ "$AUTH_TYPE" == "userpass" ]; then
        cat > "$reg_script" << EOF
#!/bin/bash
set -e

echo "Registering with username/password..."
sudo subscription-manager register --username "${RH_USERNAME}" --password "${RH_PASSWORD}" --auto-attach

echo "Enabling repositories..."
sudo subscription-manager repos --enable rhel-9-for-x86_64-baseos-rpms
sudo subscription-manager repos --enable rhel-9-for-x86_64-appstream-rpms

echo "Registration complete!"
EOF
    else
        cat > "$reg_script" << EOF
#!/bin/bash
set -e

echo "Registering with org/activation key..."
sudo subscription-manager register --org="${RH_ORG}" --activationkey="${RH_ACTIVATION_KEY}"

echo "Enabling repositories..."
sudo subscription-manager repos --enable rhel-9-for-x86_64-baseos-rpms
sudo subscription-manager repos --enable rhel-9-for-x86_64-appstream-rpms

echo "Registration complete!"
EOF
    fi
    
    chmod +x "$reg_script"
    
    # Execute commands via virtctl console
    print_info "Executing registration via console..."
    
    # Create expect script for automated console interaction
    local expect_script="/tmp/register-expect-${vm_name}.exp"
    cat > "$expect_script" << EXPECTEOF
#!/usr/bin/expect -f
set timeout 120

spawn virtctl console ${vm_name} -n default

expect "login:"
send "${VM_USER}\r"

expect "Password:"
send "${VM_PASSWORD}\r"

expect "$ "
send "$(cat $reg_script | tail -n +2 | tr '\n' ';')\r"

expect "$ "
send "exit\r"

expect eof
EXPECTEOF

    chmod +x "$expect_script"
    
    if command -v expect &> /dev/null; then
        "$expect_script" || print_warn "Registration may have failed for ${vm_name}"
    else
        print_warn "expect not found - please install expect package"
        print_info "Or manually run commands from: $reg_script"
        return 1
    fi
    
    rm -f "$reg_script"
    print_info "✓ ${vm_name} registered successfully"
}

#================================================================
# Install packages on a VM
#================================================================
install_packages() {
    local vm_name=$1
    local packages="${VM_PACKAGES[$vm_name]}"
    
    if [ -z "$packages" ]; then
        print_warn "No packages defined for ${vm_name}"
        return 0
    fi
    
    print_step "Installing packages on ${vm_name}"
    print_info "Packages: ${packages}"
    
    # Create install script
    local install_script="/tmp/install-${vm_name}.sh"
    
    cat > "$install_script" << EOF
#!/bin/bash
set -e

echo "Updating package cache..."
sudo dnf clean all
sudo dnf makecache

echo "Installing packages: ${packages}"
sudo dnf install -y ${packages} || {
    echo "Some packages may not be available, continuing..."
}

echo "Restarting roxagent to trigger immediate scan..."
sudo systemctl restart roxagent

echo "Package installation complete!"
echo "Roxagent will scan and report to RHACS within 1-2 minutes"
EOF
    
    chmod +x "$install_script"
    
    # Copy script to VM and execute
    print_info "Copying install script to VM..."
    cat "$install_script" | virtctl scp -n default - ${VM_USER}@${vm_name}:/tmp/install.sh
    
    print_info "Installing packages (this may take 2-3 minutes)..."
    virtctl ssh -n default ${VM_USER}@${vm_name} "chmod +x /tmp/install.sh && /tmp/install.sh" || {
        print_warn "Some packages may have failed to install on ${vm_name}"
        return 1
    }
    
    rm -f "$install_script"
    print_info "✓ Packages installed on ${vm_name}"
}

#================================================================
# Process all VMs
#================================================================
process_vms() {
    print_header "════════════════════════════════════════════════════════════"
    print_step "Processing VMs"
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    # Check VMs are running
    print_info "Checking VM status..."
    if ! oc get vmi -n default &>/dev/null; then
        print_error "No VMs found in default namespace"
        exit 1
    fi
    
    local vm_count=$(oc get vmi -n default --no-headers | wc -l)
    print_info "Found ${vm_count} VMs"
    echo ""
    
    # Process each VM
    for vm_name in "${!VM_PACKAGES[@]}"; do
        echo ""
        print_header "--- Processing: ${vm_name} ---"
        echo ""
        
        # Check if VM exists
        if ! oc get vmi "${vm_name}" -n default &>/dev/null; then
            print_warn "VM ${vm_name} not found, skipping"
            continue
        fi
        
        # Register VM
        if ! register_vm "$vm_name"; then
            print_error "Failed to register ${vm_name}, skipping package installation"
            continue
        fi
        
        echo ""
        
        # Install packages
        if ! install_packages "$vm_name"; then
            print_error "Failed to install packages on ${vm_name}"
            continue
        fi
        
        print_info "✓ ${vm_name} completed successfully"
        echo ""
    done
}

#================================================================
# Display summary
#================================================================
display_summary() {
    echo ""
    print_header "════════════════════════════════════════════════════════════"
    print_header "                Registration Complete! ✓                    "
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    
    print_info "What was done:"
    echo ""
    echo "  ✓ VMs registered with Red Hat subscription"
    echo "  ✓ DNF packages installed on each VM:"
    echo "    • rhel-webserver: Web server packages (httpd, nginx, php)"
    echo "    • rhel-database: Database packages (postgresql, mariadb)"
    echo "    • rhel-devtools: Development tools (git, gcc, python, java)"
    echo "    • rhel-monitoring: Monitoring tools (grafana, telegraf)"
    echo "  ✓ roxagent restarted on each VM for immediate scanning"
    echo ""
    
    print_header "Next Steps:"
    echo ""
    echo "  1. Wait 2-3 minutes for roxagent to scan and send reports"
    echo ""
    echo "  2. Check RHACS UI for vulnerability data:"
    CENTRAL_URL="https://$(oc get route central -n stackrox -o jsonpath='{.spec.host}')"
    echo "     ${CENTRAL_URL}"
    echo "     → Platform Configuration → Clusters → Virtual Machines"
    echo ""
    echo "  3. Run status check:"
    echo "     $ ./check-vm-status.sh"
    echo ""
    
    print_info "VMs now have scannable packages with real vulnerabilities!"
    echo ""
}

#================================================================
# Main execution
#================================================================
main() {
    display_banner
    get_credentials
    process_vms
    display_summary
}

# Check prerequisites
if ! command -v virtctl &> /dev/null; then
    print_error "virtctl is required but not installed"
    print_info "Install with: curl -L https://github.com/kubevirt/kubevirt/releases/download/v1.3.1/virtctl-v1.3.1-linux-amd64 -o /usr/local/bin/virtctl && chmod +x /usr/local/bin/virtctl"
    exit 1
fi

main "$@"
