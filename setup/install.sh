#!/bin/bash
# RHACS Demo Installation Script
# Executes all setup scripts in the correct order
#
# Usage: ./install.sh [-p PASSWORD]
#   -p PASSWORD: RHACS admin password (will be saved to ~/.bashrc)

# Exit immediately on error, show exact error message
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse command line arguments
ACS_PASSWORD_PROVIDED=""
while getopts "p:h" opt; do
    case $opt in
        p)
            ACS_PASSWORD_PROVIDED="$OPTARG"
            ;;
        h)
            echo "Usage: $0 [-p PASSWORD]"
            echo ""
            echo "Options:"
            echo "  -p PASSWORD    RHACS admin password (will be saved to ~/.bashrc)"
            echo "  -h             Show this help message"
            echo ""
            echo "If -p is not provided, the script will attempt to retrieve the password"
            echo "from the central-htpasswd secret, but this may not work if the secret"
            echo "contains only a hash."
            exit 0
            ;;
        \?)
            error "Invalid option: -$OPTARG. Use -h for help."
            ;;
    esac
done
shift $((OPTIND-1))

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
    "01-compliance-operator-install.sh"
    "02-deploy-applications.sh"
    "03-setup-co-scan-schedule.sh"
    "04-trigger-compliance-scan.sh"
    "05-configure-rhacs-settings.sh"
    # "06-setup-perses-monitoring.sh"  # Script not found - uncomment when available
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

# Set GRPC_ENFORCE_ALPN_ENABLED to false to fix ALPN/gRPC compatibility issues
log "Configuring GRPC environment variable..."
save_to_bashrc "GRPC_ENFORCE_ALPN_ENABLED" "false"
log "[OK] GRPC_ENFORCE_ALPN_ENABLED=false saved to ~/.bashrc"

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
    
    # Always save ACS_URL
    save_to_bashrc "ACS_URL" "$ACS_URL"
    ACS_USERNAME="admin"
    save_to_bashrc "ACS_USERNAME" "$ACS_USERNAME"
    
    # Handle password - use provided password or try to get from secret
    if [ -n "$ACS_PASSWORD_PROVIDED" ]; then
        # Use password provided via -p flag
        ACS_PASSWORD="$ACS_PASSWORD_PROVIDED"
        save_to_bashrc "ACS_PASSWORD" "$ACS_PASSWORD"
        log "[OK] Using provided password (saved to ~/.bashrc)"
    else
        # Try to get password from secret (may contain hash, not plaintext)
        ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
        if [ -z "$ADMIN_PASSWORD_B64" ]; then
            # Try htpasswd key
            ADMIN_PASSWORD_B64=$(oc get secret central-htpasswd -n "$RHACS_NAMESPACE" -o jsonpath='{.data.htpasswd}' 2>/dev/null || echo "")
        fi
        
        if [ -n "$ADMIN_PASSWORD_B64" ]; then
            HTPASSWD_CONTENT=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
            # Check if it's a hash (starts with $2a$, $2y$, etc.) or might be plaintext
            if echo "$HTPASSWD_CONTENT" | grep -q "^admin:\$2"; then
                warning "Secret contains htpasswd hash, not plaintext password."
                warning "Password cannot be extracted from hash. Please provide password with -p flag:"
                warning "  ./install.sh -p YOUR_PASSWORD"
                warning "ACS_URL and ACS_USERNAME saved, but password not available."
            else
                # Might be plaintext or different format - try to extract
                ACS_PASSWORD=$(echo "$HTPASSWD_CONTENT" | cut -d: -f2- | head -1)
                if [ -n "$ACS_PASSWORD" ] && [ ${#ACS_PASSWORD} -lt 200 ]; then
                    save_to_bashrc "ACS_PASSWORD" "$ACS_PASSWORD"
                    log "[OK] Password extracted from secret and saved to ~/.bashrc"
                else
                    warning "Could not extract usable password from secret."
                    warning "Please provide password with -p flag: ./install.sh -p YOUR_PASSWORD"
                fi
            fi
        else
            warning "Could not retrieve ACS password from secret central-htpasswd in namespace $RHACS_NAMESPACE"
            warning "Please provide password with -p flag: ./install.sh -p YOUR_PASSWORD"
        fi
    fi
    
    log "[OK] ACS credentials configuration:"
    log "  ACS_URL: $ACS_URL"
    log "  ACS_USERNAME: $ACS_USERNAME"
    if [ -n "${ACS_PASSWORD:-}" ]; then
        log "  ACS_PASSWORD: [saved to ~/.bashrc]"
        
        # Generate and save ROX_API_TOKEN if we have password
        ROX_ENDPOINT_FOR_API="${CENTRAL_ROUTE}"
        TOKEN_NAME="install-script-token"
        
        # Check if API token already exists and delete it
        log "Checking for existing API token '$TOKEN_NAME'..."
        set +e
        EXISTING_TOKENS=$(curl -k -s --connect-timeout 15 --max-time 60 -X GET \
            -u "admin:${ACS_PASSWORD}" \
            -H "Content-Type: application/json" \
            "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens" 2>&1)
        TOKEN_LIST_EXIT_CODE=$?
        set -e
        
        TOKEN_EXISTS=false
        if [ $TOKEN_LIST_EXIT_CODE -eq 0 ] && echo "$EXISTING_TOKENS" | jq . >/dev/null 2>&1; then
            if echo "$EXISTING_TOKENS" | jq -r --arg name "$TOKEN_NAME" '.tokens[]? | select(.name == $name) | .name' 2>/dev/null | grep -q "^${TOKEN_NAME}$"; then
                TOKEN_EXISTS=true
                log "Found existing API token '$TOKEN_NAME', deleting it..."
                TOKEN_ID=$(echo "$EXISTING_TOKENS" | jq -r --arg name "$TOKEN_NAME" '.tokens[]? | select(.name == $name) | .id' 2>/dev/null | head -1)
                if [ -n "$TOKEN_ID" ] && [ "$TOKEN_ID" != "null" ]; then
                    set +e
                    DELETE_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X DELETE \
                        -u "admin:${ACS_PASSWORD}" \
                        -H "Content-Type: application/json" \
                        "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/${TOKEN_ID}" 2>&1)
                    if [ $? -eq 0 ]; then
                        log "✓ Deleted existing token (ID: $TOKEN_ID)"
                    fi
                    set -e
                fi
            fi
        fi
        
        log "Generating API token '$TOKEN_NAME'..."
        set +e
        TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
            -u "admin:${ACS_PASSWORD}" \
            -H "Content-Type: application/json" \
            "https://${ROX_ENDPOINT_FOR_API}/v1/apitokens/generate" \
            -d "{\"name\":\"${TOKEN_NAME}\",\"roles\":[\"Admin\"]}" 2>&1)
        TOKEN_CURL_EXIT_CODE=$?
        set -e
        
        if [ $TOKEN_CURL_EXIT_CODE -eq 0 ]; then
            # Extract token from response
            ROX_API_TOKEN=""
            if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
                ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
            fi
            
            if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
                ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
            fi
            
            if [ -n "$ROX_API_TOKEN" ] && [ "$ROX_API_TOKEN" != "null" ] && [ ${#ROX_API_TOKEN} -ge 30 ]; then
                save_to_bashrc "ROX_API_TOKEN" "$ROX_API_TOKEN"
                log "[OK] ROX_API_TOKEN generated and saved to ~/.bashrc"
            else
                warning "Failed to extract valid API token from response"
                warning "Token generation failed, but installation will continue"
            fi
        else
            warning "Failed to generate API token (curl exit code: $TOKEN_CURL_EXIT_CODE)"
            warning "Token generation failed, but installation will continue"
        fi
    else
        log "  ACS_PASSWORD: [not set - use -p flag to provide]"
        log "  ROX_API_TOKEN: [not generated - password required]"
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