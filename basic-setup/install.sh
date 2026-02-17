#!/bin/bash
#
# RHACS Demo Environment Setup Script
#
# Usage:
#   ./install.sh [PASSWORD]
#
# Arguments:
#   PASSWORD    Optional: RHACS Central admin password (sets ROX_PASSWORD)
#
# Examples:
#   ./install.sh                      # Use password from environment or ~/.bashrc
#   ./install.sh mySecurePassword123  # Provide password as argument
#
# The script will check for required environment variables in this order:
#   1. Command-line arguments
#   2. Current environment variables
#   3. Variables defined in ~/.bashrc
#   4. Auto-detection from cluster (for ROX_CENTRAL_URL)
#

set -euo pipefail

# Trap to show error location
trap 'echo "Error at line $LINENO"' ERR

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory (install.sh is now in basic-setup folder)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SCRIPT_DIR}"  # Scripts are in the same directory
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

#================================================================
# Utility Functions
#================================================================

# Strip https:// from ROX_CENTRAL_URL for roxctl -e flag
# roxctl expects host:port format and defaults to https
#
# Usage:
#   ROX_ENDPOINT=$(get_rox_endpoint)
#   roxctl -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" central userpki create ...
#
# Example:
#   If ROX_CENTRAL_URL="https://central-stackrox.apps.cluster.com"
#   Then get_rox_endpoint returns "central-stackrox.apps.cluster.com"
get_rox_endpoint() {
    local url="${ROX_CENTRAL_URL:-}"
    # Remove https:// prefix if present
    echo "${url#https://}"
}

#================================================================
# Install roxctl CLI
#================================================================
install_roxctl() {
    print_step "Installing roxctl CLI"
    echo "================================================================"
    
    # Check if roxctl is already installed and working
    if command -v roxctl >/dev/null 2>&1; then
        # Test if it actually works (not a corrupted file)
        if roxctl version >/dev/null 2>&1; then
            local version=$(roxctl version 2>/dev/null | grep "roxctl version" || echo "installed")
            print_info "✓ roxctl already installed and working: ${version}"
            return 0
        else
            print_warn "roxctl exists but appears corrupted, reinstalling..."
            # Remove corrupted version
            local roxctl_path=$(which roxctl)
            if [ -w "${roxctl_path}" ]; then
                rm -f "${roxctl_path}"
            elif [ -f ~/.local/bin/roxctl ]; then
                rm -f ~/.local/bin/roxctl
            fi
        fi
    fi
    
    print_info "Downloading roxctl..."
    
    # Detect OS and architecture
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
    
    case "${arch}" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_error "Unsupported architecture: ${arch}"; exit 1 ;;
    esac
    
    # Download to temporary location
    local temp_dir=$(mktemp -d)
    local download_success=false
    
    # Method 1: Try downloading from Red Hat mirror (more reliable)
    print_info "Attempting download from Red Hat mirror..."
    local mirror_url="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
    if curl -L -f -s -o "${temp_dir}/roxctl" "${mirror_url}" 2>/dev/null; then
        # Verify it's actually a binary (check file signature)
        if file "${temp_dir}/roxctl" | grep -q "executable"; then
            print_info "✓ Successfully downloaded from Red Hat mirror"
            download_success=true
        else
            print_warn "Downloaded file from mirror is not a valid executable"
            rm -f "${temp_dir}/roxctl"
        fi
    else
        print_warn "Failed to download from Red Hat mirror"
    fi
    
    # Method 2: Try downloading from Central route (if method 1 failed)
    if [ "$download_success" = false ]; then
        print_info "Attempting download from RHACS Central..."
        local central_route=$(oc get route central -n ${RHACS_NAMESPACE:-stackrox} -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "${central_route}" ]; then
            local roxctl_url="https://${central_route}/api/cli/download/roxctl-${os}"
            print_info "Downloading from: ${roxctl_url}"
            
            if curl -k -f -s -o "${temp_dir}/roxctl" "${roxctl_url}" 2>/dev/null; then
                # Verify it's actually a binary
                if file "${temp_dir}/roxctl" | grep -q "executable"; then
                    print_info "✓ Successfully downloaded from RHACS Central"
                    download_success=true
                else
                    print_warn "Downloaded file from Central is not a valid executable"
                    rm -f "${temp_dir}/roxctl"
                fi
            else
                print_warn "Failed to download from RHACS Central"
            fi
        fi
    fi
    
    # Check if download was successful
    if [ "$download_success" = false ]; then
        print_error "Failed to download roxctl from all sources"
        rm -rf "${temp_dir}"
        print_error "Please install roxctl manually:"
        print_error "  curl -L -o /tmp/roxctl https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
        print_error "  chmod +x /tmp/roxctl"
        print_error "  sudo mv /tmp/roxctl /usr/local/bin/roxctl"
        exit 1
    fi
    
    # Make executable
    chmod +x "${temp_dir}/roxctl"
    
    # Test the binary before installing
    if ! "${temp_dir}/roxctl" version >/dev/null 2>&1; then
        print_error "Downloaded roxctl binary is not working correctly"
        rm -rf "${temp_dir}"
        exit 1
    fi
    
    # Move to /usr/local/bin or ~/.local/bin
    if [ -w "/usr/local/bin" ]; then
        mv "${temp_dir}/roxctl" /usr/local/bin/roxctl
        print_info "✓ roxctl installed to /usr/local/bin/roxctl"
    else
        mkdir -p ~/.local/bin
        mv "${temp_dir}/roxctl" ~/.local/bin/roxctl
        print_info "✓ roxctl installed to ~/.local/bin/roxctl"
        
        # Add to PATH if not already there
        if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
            print_info "Adding ~/.local/bin to PATH in ~/.bashrc"
            if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc 2>/dev/null; then
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
            fi
        fi
    fi
    
    rm -rf "${temp_dir}"
    
    # Verify installation
    if command -v roxctl >/dev/null 2>&1; then
        local version=$(roxctl version 2>/dev/null | grep "roxctl version" || echo "installed")
        print_info "✓ roxctl successfully installed: ${version}"
    else
        print_warn "roxctl installed but not in current PATH"
        print_info "Please run: source ~/.bashrc"
    fi
    
    echo ""
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

# Generate API token using curl (outputs only token to stdout)
generate_api_token() {
    local central_url="${ROX_CENTRAL_URL:-}"
    local password="${ROX_PASSWORD:-}"
    
    if [ -z "${central_url}" ] || [ -z "${password}" ]; then
        return 1
    fi
    
    # Remove https:// prefix
    local api_host="${central_url#https://}"
    api_host="${api_host#http://}"
    
    # Make API call silently
    local response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 15 --max-time 60 \
        -X POST \
        -u "admin:${password}" \
        -H "Content-Type: application/json" \
        "https://${api_host}/v1/apitokens/generate" \
        -d '{"name":"install-script-'$(date +%s)'","roles":["Admin"]}' 2>/dev/null)
    
    local http_code=$(echo "${response}" | tail -n1)
    local body=$(echo "${response}" | sed '$d')
    
    if [ "${http_code}" != "200" ]; then
        return 1
    fi
    
    local token=$(echo "${body}" | jq -r '.token' 2>/dev/null)
    if [ -z "${token}" ] || [ "${token}" = "null" ]; then
        return 1
    fi
    
    # Validate token length
    if [ ${#token} -lt 20 ]; then
        return 1
    fi
    
    # Output ONLY the token to stdout (no other text)
    printf "%s" "${token}"
    return 0
}

# Save password to ~/.bashrc
save_password_to_bashrc() {
    local password="${1}"
    
    if [ -z "${password}" ]; then
        return 1
    fi
    
    touch ~/.bashrc
    
    # Check if password already exists in ~/.bashrc
    local existing_password
    existing_password=$(grep -E "^export ROX_PASSWORD=" ~/.bashrc 2>/dev/null | head -1 | sed 's/.*="\(.*\)".*/\1/' || echo "")
    
    if [ "${existing_password}" = "${password}" ]; then
        print_info "✓ Password already saved in ~/.bashrc (unchanged)"
        return 0
    fi
    
    # Remove any existing ROX_PASSWORD entries
    sed -i.bak '/^export ROX_PASSWORD=/d' ~/.bashrc 2>/dev/null || true
    
    # Add new password
    echo "export ROX_PASSWORD=\"${password}\"" >> ~/.bashrc
    
    if [ -n "${existing_password}" ] && [ "${existing_password}" != "${password}" ]; then
        print_info "✓ Password updated in ~/.bashrc"
    else
        print_info "✓ Password saved to ~/.bashrc"
    fi
    
    return 0
}

# Main installation function
main() {
    # Accept password as command-line argument
    local provided_password="${1:-}"
    
    if [ -n "${provided_password}" ]; then
        export ROX_PASSWORD="${provided_password}"
        print_info "Using password provided via command-line argument"
        # Save password to ~/.bashrc for future runs
        save_password_to_bashrc "${provided_password}"
    fi
    
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
    
    # Add gRPC ALPN fix to ~/.bashrc (required for roxctl)
    print_info "Configuring gRPC ALPN fix for roxctl..."
    if [ -f ~/.bashrc ] && ! grep -q "GRPC_ENFORCE_ALPN_ENABLED" ~/.bashrc; then
        echo "" >> ~/.bashrc
        echo "# Fix for gRPC ALPN enforcement issues with roxctl (https://github.com/grpc/grpc-go/issues/7769)" >> ~/.bashrc
        echo "export GRPC_ENFORCE_ALPN_ENABLED=false" >> ~/.bashrc
        print_info "✓ Added GRPC_ENFORCE_ALPN_ENABLED=false to ~/.bashrc"
    else
        print_info "✓ GRPC_ENFORCE_ALPN_ENABLED already in ~/.bashrc"
    fi
    # Export it for current session
    export GRPC_ENFORCE_ALPN_ENABLED=false
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
    
    # Install roxctl CLI if not present
    install_roxctl
    
    # Check if ROX_API_TOKEN is needed and generate if missing
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        print_info "ROX_API_TOKEN not set - attempting to generate..."
        
        # Generate token (function outputs ONLY token, no other text)
        local token=""
        token=$(generate_api_token) || true
        
        # Validate we got a clean token
        if [ -n "${token}" ] && [ "${token}" != "null" ] && [ ${#token} -gt 20 ]; then
            # Make sure it doesn't contain any unwanted text
            if echo "${token}" | grep -q "^\[INFO\]\|^\[ERROR\]\|^\[WARN\]"; then
                print_error "Token generation returned invalid output"
                print_error ""
                print_error "API token generation is REQUIRED for setup to continue"
                print_error "Scripts 04, 05, and 06 require ROX_API_TOKEN"
                print_error ""
                print_error "Please verify:"
                print_error "  1. RHACS Central is running and accessible"
                print_error "  2. ROX_PASSWORD is correct"
                print_error "  3. ROX_CENTRAL_URL is accessible"
                print_error ""
                exit 1
            else
                export ROX_API_TOKEN="${token}"
                
                # Save to ~/.bashrc - clean up any old entries first
                if [ -f ~/.bashrc ]; then
                    # Remove all old ROX_API_TOKEN lines
                    grep -v "^export ROX_API_TOKEN=" ~/.bashrc > ~/.bashrc.tmp 2>/dev/null || true
                    mv ~/.bashrc.tmp ~/.bashrc
                else
                    touch ~/.bashrc
                fi
                
                # Add new token (only the token, nothing else)
                echo "export ROX_API_TOKEN=\"${token}\"" >> ~/.bashrc
                
                print_info "✓ API token generated and saved to ~/.bashrc (length: ${#token} chars)"
            fi
        else
            print_error "Failed to generate API token"
            print_error ""
            print_error "API token generation is REQUIRED for setup to continue"
            print_error "Scripts 04, 05, and 06 require ROX_API_TOKEN for:"
            print_error "  - Configuring RHACS metrics and settings"
            print_error "  - Creating compliance scan schedules"
            print_error "  - Triggering compliance scans"
            print_error ""
            print_error "Possible causes:"
            print_error "  1. RHACS Central is not running or not accessible"
            print_error "  2. ROX_PASSWORD is incorrect or not set"
            print_error "  3. ROX_CENTRAL_URL is incorrect or unreachable"
            print_error "  4. Network connectivity issues"
            print_error ""
            print_error "To debug:"
            print_error "  - Check Central status: oc get pods -n ${RHACS_NAMESPACE:-stackrox}"
            print_error "  - Verify password: oc get secret central-htpasswd -n ${RHACS_NAMESPACE:-stackrox} -o jsonpath='{.data.password}' | base64 -d"
            print_error "  - Test URL: curl -k ${ROX_CENTRAL_URL:-<CENTRAL_URL>}/v1/ping"
            print_error ""
            exit 1
        fi
        print_info ""
    else
        print_info "✓ ROX_API_TOKEN already set in environment"
        print_info ""
    fi
    
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
    
    print_info ""
    print_info "======================================"
    print_info "RHACS Demo Environment Setup Complete!"
    print_info "======================================"
    print_info ""
    
    # Display setup summary
    print_info "Setup Summary:"
    print_info "=============="
    print_info "  ✓ roxctl CLI installed"
    if [ -n "${ROX_API_TOKEN:-}" ]; then
        print_info "  ✓ ROX_API_TOKEN generated and saved to ~/.bashrc"
    fi
    print_info "  ✓ RHACS installation verified"
    print_info "  ✓ Compliance Operator installed"
    print_info "  ✓ Demo applications deployed"
    print_info "  ✓ RHACS settings configured"
    print_info "  ✓ Compliance scan schedules created"
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
        
        # Try multiple common secret locations for RHACS admin password
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
        
        # Option 4: Try to extract from Central deployment logs (operator installations)
        if [ -z "${password}" ]; then
            print_info "Checking Central deployment logs for initial password..."
            password=$(oc logs deployment/central -n "${ns}" --since=24h 2>/dev/null | grep -oP '(?<=password:\s).*' | head -1 || true)
            
            # Alternative pattern for operator logs
            if [ -z "${password}" ]; then
                password=$(oc logs deployment/central -n "${ns}" --since=24h 2>/dev/null | grep -i "admin.*password" | grep -oP '[A-Za-z0-9@#$%^&*()_+\-=\[\]{};:,.<>?]{16,}' | head -1 || true)
            fi
        fi
        
        if [ -n "${password}" ]; then
            print_info "Admin Password: ${password}"
        else
            print_warn "Admin password not found in secrets or logs"
            print_info ""
            print_info "For operator-managed RHACS installations, the password is typically only"
            print_info "available in the Central deployment logs during initial setup."
            print_info ""
            print_info "To retrieve or reset the admin password:"
            print_info "  1. Check Central logs: oc logs -n ${ns} deployment/central --tail=1000 | grep -i password"
            print_info "  2. Check if stored in ~/.bashrc: grep ROX_PASSWORD ~/.bashrc"
            print_info "  3. Reset via Central UI at: ${ROX_CENTRAL_URL:-[Central URL]}"
            print_info ""
        fi
    fi
    
    if [ -n "${RHACS_VERSION:-}" ]; then
        print_info "RHACS Version: ${RHACS_VERSION}"
    fi
    
}

# Run main function
main "$@"
