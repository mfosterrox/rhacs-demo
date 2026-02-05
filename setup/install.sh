#!/bin/bash
# RHACS Demo Installation Script
# Executes all setup scripts in the correct order

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INSTALL]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[INSTALL]${NC} $1"
}

error() {
    echo -e "${RED}[INSTALL] ERROR:${NC} $1" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Array of scripts to execute in order
SCRIPTS=(
    "compliance-operator-install.sh"
    "deploy-applications.sh"
    "setup-co-scan-schedule.sh"
    "trigger-compliance-scan.sh"
    "configure-rhacs-settings.sh"
    "setup-perses-monitoring.sh"
)

log "Starting RHACS Demo installation..."
log "This will execute ${#SCRIPTS[@]} setup scripts in order"
echo ""

# Function to save variable to ~/.bashrc
save_to_bashrc() {
    local var_name="$1"
    local var_value="$2"
    
    # Remove existing export line for this variable
    if [ -f ~/.bashrc ]; then
        sed -i "/^export ${var_name}=/d" ~/.bashrc 2>/dev/null || true
    fi
    
    # Append export statement to ~/.bashrc
    echo "export ${var_name}=\"${var_value}\"" >> ~/.bashrc
    export "${var_name}=${var_value}"
}

# Ensure ~/.bashrc exists
if [ ! -f ~/.bashrc ]; then
    log "Creating ~/.bashrc file..."
    touch ~/.bashrc
fi

# Download roxctl and configure ACS credentials
log "Setting up roxctl and ACS credentials..."
RHACS_NAMESPACE="stackrox"

# Check if RHACS Central route exists
CENTRAL_ROUTE=$(oc get route central -n "$RHACS_NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "$CENTRAL_ROUTE" ]; then
    # Get ACS URL (ensure it has https:// prefix)
    if [[ ! "$CENTRAL_ROUTE" =~ ^https?:// ]]; then
        ACS_URL="https://$CENTRAL_ROUTE"
    else
        ACS_URL="$CENTRAL_ROUTE"
    fi
    
    log "[OK] Found ACS Central route: $ACS_URL"
    
    # Get admin password from secret
    ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -n "$ADMIN_PASSWORD_B64" ]; then
        ACS_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
        ACS_USERNAME="admin"
        
        # Save to ~/.bashrc
        save_to_bashrc "ACS_URL" "$ACS_URL"
        save_to_bashrc "ACS_USERNAME" "$ACS_USERNAME"
        save_to_bashrc "ACS_PASSWORD" "$ACS_PASSWORD"
        
        log "[OK] ACS credentials saved to ~/.bashrc"
        log "  ACS_URL: $ACS_URL"
        log "  ACS_USERNAME: $ACS_USERNAME"
    else
        warning "Could not retrieve ACS password from secret central-htpasswd in namespace $RHACS_NAMESPACE"
    fi
else
    warning "Could not find ACS Central route in namespace $RHACS_NAMESPACE. ACS credentials will not be configured."
fi

# Download roxctl if not already available
if ! command -v roxctl &>/dev/null; then
    log "Downloading roxctl..."
    
    # Try to get RHACS version from CSV
    RHACS_VERSION=$(oc get csv -n "$RHACS_NAMESPACE" -o jsonpath='{.items[?(@.spec.displayName=="Advanced Cluster Security for Kubernetes")].spec.version}' 2>/dev/null || echo "")
    if [ -z "$RHACS_VERSION" ]; then
        RHACS_VERSION=$(oc get csv -n "$RHACS_NAMESPACE" -o jsonpath='{.items[0].spec.version}' 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || echo "")
    fi
    
    # Determine OS and architecture
    OS_TYPE="Linux"
    ARCH_TYPE="amd64"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_TYPE="Darwin"
    fi
    
    # Try downloading roxctl
    ROXCTL_URL=""
    if [ -n "$RHACS_VERSION" ]; then
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/${RHACS_VERSION}/bin/${OS_TYPE}/roxctl"
    else
        ROXCTL_URL="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/${OS_TYPE}/roxctl"
    fi
    
    if curl -L -f -o /tmp/roxctl "$ROXCTL_URL" 2>/dev/null; then
        chmod +x /tmp/roxctl
        # Add to PATH via ~/.bashrc
        if ! grep -q "/tmp/roxctl" ~/.bashrc 2>/dev/null; then
            echo 'export PATH="$PATH:/tmp"' >> ~/.bashrc
        fi
        export PATH="$PATH:/tmp"
        log "[OK] roxctl downloaded to /tmp/roxctl"
    else
        warning "Failed to download roxctl from $ROXCTL_URL"
        warning "You may need to install roxctl manually"
    fi
else
    log "[OK] roxctl already available in PATH"
fi

echo ""

# Execute each script in order
for script in "${SCRIPTS[@]}"; do
    script_path="${SCRIPT_DIR}/${script}"
    
    if [ ! -f "$script_path" ]; then
        error "Script not found: $script_path"
    fi
    
    if [ ! -x "$script_path" ]; then
        warning "Making $script executable..."
        chmod +x "$script_path"
    fi
    
    log "Executing: $script"
    echo ""
    
    # Execute the script
    if bash "$script_path"; then
        log "[OK] Completed: $script"
    else
        error "Failed: $script"
    fi
    
    echo ""
done

log "========================================================="
log "RHACS Demo Installation Completed Successfully"
log "========================================================="