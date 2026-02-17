#!/bin/bash
#
# Script: 03-configure-vm-subscriptions.sh
# Description: Register VMs with Red Hat subscriptions and install packages for vulnerability scanning
#
# This script:
# 1. Registers VMs with Red Hat subscription-manager
# 2. Installs packages based on VM profile
# 3. Restarts roxagent to scan new packages
#
# Prerequisites:
# - VMs must be deployed (run 02-deploy-sample-vms.sh first)
# - VMs must be running and accessible
# - Valid Red Hat subscription credentials or activation key
#
# Usage:
#   ç
#   ./03-configure-vm-subscriptions.sh --org ORG --activation-key KEY [OPTIONS]
#
# Options:
#   --username USER          Red Hat username
#   --password PASS          Red Hat password
#   --org ORG               Organization ID
#   --activation-key KEY    Activation key
#   --namespace NS          VM namespace (default: demo-vms)
#   --skip-registration     Skip subscription registration (packages only)
#   --vm-name NAME          Process only specific VM (default: all)
#

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Print functions
print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Error handler
trap 'echo "Error at line $LINENO"' ERR

# Default configuration
NAMESPACE="demo-vms"
RHEL_USERNAME=""
RHEL_PASSWORD=""
RHEL_ORG=""
RHEL_ACTIVATION_KEY=""
SKIP_REGISTRATION=false
SPECIFIC_VM=""

# VM profiles (must match 02-deploy-sample-vms.sh)
declare -A VM_PROFILES=(
    ["webserver"]="httpd nginx php php-mysqlnd mod_ssl mod_security"
    ["database"]="postgresql postgresql-server postgresql-contrib mariadb mariadb-server"
    ["devtools"]="git gcc gcc-c++ make python3 python3-pip nodejs npm java-11-openjdk-devel maven"
    ["monitoring"]="grafana telegraf collectd collectd-utils net-snmp net-snmp-utils"
)

#================================================================
# Parse arguments
#================================================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --username)
                RHEL_USERNAME="$2"
                shift 2
                ;;
            --password)
                RHEL_PASSWORD="$2"
                shift 2
                ;;
            --org)
                RHEL_ORG="$2"
                shift 2
                ;;
            --activation-key)
                RHEL_ACTIVATION_KEY="$2"
                shift 2
                ;;
            --namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            --skip-registration)
                SKIP_REGISTRATION=true
                shift
                ;;
            --vm-name)
                SPECIFIC_VM="$2"
                shift 2
                ;;
            -h|--help)
                cat <<EOF
Usage: $0 [OPTIONS]

Register VMs with Red Hat subscription and install packages.

Authentication Options (choose one):
  --username USER         Red Hat customer portal username
  --password PASS         Red Hat customer portal password
  
  OR
  
  --org ORG              Organization ID
  --activation-key KEY   Activation key

Other Options:
  --namespace NS         VM namespace (default: demo-vms)
  --skip-registration    Skip subscription registration (packages only)
  --vm-name NAME         Process only specific VM (default: all)
  -h, --help            Show this help

Examples:
  # Register with username/password
  $0 --username myuser --password mypass

  # Register with activation key
  $0 --org 12345678 --activation-key my-key

  # Only install packages (subscription already registered)
  $0 --skip-registration

  # Process specific VM only
  $0 --username myuser --password mypass --vm-name rhel-webserver

Environment Variables:
  RHEL_USERNAME          Red Hat username (alternative to --username)
  RHEL_PASSWORD          Red Hat password (alternative to --password)
  RHEL_ORG              Organization ID (alternative to --org)
  RHEL_ACTIVATION_KEY   Activation key (alternative to --activation-key)

EOF
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
    
    # Check for credentials in environment if not provided
    RHEL_USERNAME="${RHEL_USERNAME:-${RHEL_USERNAME_ENV:-}}"
    RHEL_PASSWORD="${RHEL_PASSWORD:-${RHEL_PASSWORD_ENV:-}}"
    RHEL_ORG="${RHEL_ORG:-${RHEL_ORG_ENV:-}}"
    RHEL_ACTIVATION_KEY="${RHEL_ACTIVATION_KEY:-${RHEL_ACTIVATION_KEY_ENV:-}}"
    
    # Validate credentials
    if [ "${SKIP_REGISTRATION}" = false ]; then
        if [ -n "${RHEL_USERNAME}" ] && [ -n "${RHEL_PASSWORD}" ]; then
            print_info "Using username/password authentication"
        elif [ -n "${RHEL_ORG}" ] && [ -n "${RHEL_ACTIVATION_KEY}" ]; then
            print_info "Using organization/activation-key authentication"
        else
            print_error "Missing subscription credentials"
            echo ""
            echo "Provide either:"
            echo "  --username USER --password PASS"
            echo "OR"
            echo "  --org ORG --activation-key KEY"
            echo ""
            echo "Or use --skip-registration to only install packages"
            exit 1
        fi
    fi
}

#================================================================
# Check prerequisites
#================================================================
check_prerequisites() {
    print_step "Checking prerequisites"
    
    # Check oc command
    if ! command -v oc &>/dev/null; then
        print_error "oc command not found"
        exit 1
    fi
    
    # Check virtctl command
    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl command not found"
        print_info "Install with: curl -L -o /usr/local/bin/virtctl https://github.com/kubevirt/kubevirt/releases/latest/download/virtctl-linux-amd64"
        exit 1
    fi
    
    # Check cluster connection
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    print_info "✓ Connected to cluster as: $(oc whoami)"
    
    # Check namespace exists
    if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
        print_error "Namespace '${NAMESPACE}' not found"
        print_info "Deploy VMs first with: ./02-deploy-sample-vms.sh"
        exit 1
    fi
    
    print_info "✓ Namespace '${NAMESPACE}' exists"
}

#================================================================
# Get list of VMs to process
#================================================================
get_vm_list() {
    if [ -n "${SPECIFIC_VM}" ]; then
        # Check if specific VM exists
        if ! oc get vm "${SPECIFIC_VM}" -n "${NAMESPACE}" &>/dev/null; then
            print_error "VM '${SPECIFIC_VM}' not found in namespace '${NAMESPACE}'"
            exit 1
        fi
        echo "${SPECIFIC_VM}"
    else
        # Get all VMs with rhel- prefix
        oc get vms -n "${NAMESPACE}" -o jsonpath='{.items[?(@.metadata.name=~"^rhel-.*")].metadata.name}' | tr ' ' '\n'
    fi
}

#================================================================
# Wait for VM to be ready
#================================================================
wait_for_vm_ready() {
    local vm_name=$1
    local max_wait=300
    local elapsed=0
    
    print_info "Waiting for VM '${vm_name}' to be ready..."
    
    while [ ${elapsed} -lt ${max_wait} ]; do
        local status=$(oc get vm "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
        
        if [ "${status}" = "Running" ]; then
            print_info "✓ VM is running"
            # Wait additional time for cloud-init and roxagent to complete
            print_info "  Waiting 30 seconds for cloud-init to complete..."
            sleep 30
            return 0
        fi
        
        if [ "${status}" = "Stopped" ] || [ "${status}" = "Paused" ]; then
            print_warn "VM is ${status}, attempting to start..."
            virtctl start "${vm_name}" -n "${NAMESPACE}" || true
        fi
        
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    print_error "VM did not become ready within ${max_wait} seconds"
    return 1
}

#================================================================
# Register VM subscription
#================================================================
register_subscription() {
    local vm_name=$1
    
    if [ "${SKIP_REGISTRATION}" = true ]; then
        print_info "Skipping subscription registration"
        return 0
    fi
    
    print_step "Registering subscription for '${vm_name}'"
    
    # Check if already registered
    local check_cmd="subscription-manager status | grep -q 'Overall Status: Current' && echo 'registered' || echo 'not_registered'"
    local reg_status=$(virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="${check_cmd}" "cloud-user@${vm_name}" 2>/dev/null || echo "not_registered")
    
    if echo "${reg_status}" | grep -q "registered"; then
        print_info "✓ VM already registered with subscription"
        return 0
    fi
    
    # Build registration command
    local reg_cmd=""
    if [ -n "${RHEL_USERNAME}" ] && [ -n "${RHEL_PASSWORD}" ]; then
        print_info "Registering with username/password..."
        reg_cmd="sudo subscription-manager register --username '${RHEL_USERNAME}' --password '${RHEL_PASSWORD}' --auto-attach"
    elif [ -n "${RHEL_ORG}" ] && [ -n "${RHEL_ACTIVATION_KEY}" ]; then
        print_info "Registering with organization/activation-key..."
        reg_cmd="sudo subscription-manager register --org '${RHEL_ORG}' --activationkey '${RHEL_ACTIVATION_KEY}'"
    else
        print_error "No valid credentials provided"
        return 1
    fi
    
    # Execute registration
    if virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="${reg_cmd}" "cloud-user@${vm_name}" 2>&1 | tee /tmp/register-output.log; then
        print_info "✓ Subscription registered successfully"
    else
        print_error "Failed to register subscription"
        print_info "Check output above for details"
        return 1
    fi
}

#================================================================
# Install packages on VM
#================================================================
install_packages() {
    local vm_name=$1
    
    # Extract profile from VM name (rhel-webserver → webserver)
    local profile="${vm_name#rhel-}"
    
    if [ -z "${VM_PROFILES[$profile]:-}" ]; then
        print_warn "No package profile defined for '${profile}', skipping"
        return 0
    fi
    
    local packages="${VM_PROFILES[$profile]}"
    
    print_step "Installing packages on '${vm_name}' (profile: ${profile})"
    print_info "Packages: ${packages}"
    
    # Execute install script (created by 02-deploy-sample-vms.sh)
    local install_cmd="sudo /root/install-packages.sh 2>&1"
    
    print_info "Installing packages (this may take 2-3 minutes)..."
    
    if virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="${install_cmd}" "cloud-user@${vm_name}" 2>&1 | tee /tmp/install-output-${profile}.log; then
        print_info "✓ Packages installed successfully"
    else
        print_error "Failed to install packages"
        print_info "Log saved to: /tmp/install-output-${profile}.log"
        return 1
    fi
    
    # Verify roxagent restarted
    print_info "Verifying roxagent is running..."
    local roxagent_status=$(virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="sudo systemctl is-active roxagent" "cloud-user@${vm_name}" 2>/dev/null || echo "unknown")
    
    if [ "${roxagent_status}" = "active" ]; then
        print_info "✓ roxagent is active and scanning"
    else
        print_warn "roxagent status: ${roxagent_status}"
        print_info "Attempting to start roxagent..."
        virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="sudo systemctl restart roxagent" "cloud-user@${vm_name}" || true
    fi
}

#================================================================
# Verify package installation
#================================================================
verify_packages() {
    local vm_name=$1
    
    print_step "Verifying packages on '${vm_name}'"
    
    # Count installed packages
    local pkg_count=$(virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="rpm -qa | wc -l" "cloud-user@${vm_name}" 2>/dev/null || echo "0")
    
    print_info "Total packages installed: ${pkg_count}"
    
    # Check specific profile packages
    local profile="${vm_name#rhel-}"
    if [ -n "${VM_PROFILES[$profile]:-}" ]; then
        local packages="${VM_PROFILES[$profile]}"
        local first_pkg=$(echo "${packages}" | awk '{print $1}')
        
        if virtctl -n "${NAMESPACE}" ssh --local-ssh=false --command="rpm -q ${first_pkg}" "cloud-user@${vm_name}" &>/dev/null; then
            print_info "✓ Profile packages are installed"
        else
            print_warn "Profile packages may not be fully installed"
        fi
    fi
}

#================================================================
# Process single VM
#================================================================
process_vm() {
    local vm_name=$1
    
    echo ""
    echo "=========================================="
    print_info "Processing VM: ${vm_name}"
    echo "=========================================="
    echo ""
    
    # Wait for VM to be ready
    if ! wait_for_vm_ready "${vm_name}"; then
        print_error "VM '${vm_name}' not ready, skipping"
        return 1
    fi
    
    # Register subscription
    if ! register_subscription "${vm_name}"; then
        print_error "Subscription registration failed for '${vm_name}'"
        return 1
    fi
    
    echo ""
    
    # Install packages
    if ! install_packages "${vm_name}"; then
        print_error "Package installation failed for '${vm_name}'"
        return 1
    fi
    
    echo ""
    
    # Verify installation
    verify_packages "${vm_name}"
    
    echo ""
    print_info "✓ VM '${vm_name}' configured successfully"
}

#================================================================
# Display summary
#================================================================
display_summary() {
    local processed=$1
    local successful=$2
    local failed=$3
    
    echo ""
    echo "=========================================="
    print_step "Configuration Summary"
    echo "=========================================="
    echo ""
    
    print_info "VMs processed: ${processed}"
    print_info "Successful: ${successful}"
    if [ ${failed} -gt 0 ]; then
        print_warn "Failed: ${failed}"
    fi
    
    echo ""
    print_info "Next steps:"
    print_info "  1. Wait 5-10 minutes for roxagent to scan packages"
    print_info "  2. Check RHACS UI: Platform Configuration → Clusters → Virtual Machines"
    print_info "  3. View VM vulnerabilities: Vulnerability Management → Workload CVEs"
    echo ""
    print_info "Verify VM scanning:"
    print_info "  # Check roxagent logs inside VM"
    print_info "  virtctl console <vm-name> -n ${NAMESPACE}"
    print_info "  sudo journalctl -u roxagent -f"
    echo ""
    print_info "  # Check collector logs on cluster"
    print_info "  oc logs -n stackrox daemonset/collector -c compliance --tail=100 | grep -i vsock"
    echo ""
}

#================================================================
# Main function
#================================================================
main() {
    echo ""
    echo "=========================================="
    echo "RHACS VM Subscription Configuration"
    echo "=========================================="
    echo ""
    
    # Parse arguments
    parse_arguments "$@"
    
    # Check prerequisites
    check_prerequisites
    
    echo ""
    
    # Get list of VMs
    local vm_list=$(get_vm_list)
    
    if [ -z "${vm_list}" ]; then
        print_error "No VMs found in namespace '${NAMESPACE}'"
        print_info "Deploy VMs first with: ./02-deploy-sample-vms.sh"
        exit 1
    fi
    
    local vm_count=$(echo "${vm_list}" | wc -l)
    print_info "Found ${vm_count} VM(s) to configure"
    echo ""
    
    # Display VMs
    while IFS= read -r vm_name; do
        print_info "  • ${vm_name}"
    done <<< "${vm_list}"
    
    echo ""
    
    # Confirm before proceeding
    if [ "${AUTO_CONFIRM:-false}" != "true" ]; then
        read -p "Proceed with VM configuration? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Configuration cancelled"
            exit 0
        fi
    fi
    
    # Process each VM
    local processed=0
    local successful=0
    local failed=0
    
    while IFS= read -r vm_name; do
        processed=$((processed + 1))
        
        if process_vm "${vm_name}"; then
            successful=$((successful + 1))
        else
            failed=$((failed + 1))
            print_warn "Continuing with next VM..."
        fi
    done <<< "${vm_list}"
    
    # Display summary
    display_summary ${processed} ${successful} ${failed}
    
    # Exit with error if any failures
    if [ ${failed} -gt 0 ]; then
        exit 1
    fi
}

# Execute main
main "$@"
