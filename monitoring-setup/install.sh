#!/bin/bash
#
# RHACS Monitoring Setup Script
# Installs Cluster Observability Operator and configures Perses monitoring for RHACS
#

# Exit immediately on error, show exact error message
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAMESPACE="${NAMESPACE:-stackrox}"
OPERATOR_NAMESPACE="openshift-cluster-observability-operator"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITORING_EXAMPLES_DIR="$SCRIPT_DIR/monitoring-examples"
TLS_SECRET_NAME="sample-stackrox-prometheus-tls"
API_TOKEN_SECRET_NAME="stackrox-prometheus-api-token"

# Functions
log() {
    echo -e "${GREEN}[RHACS-MONITORING]${NC} $1"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    echo -e "${RED}[ERROR] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

check_prerequisites() {
    log "Validating prerequisites..."
    
    # Check if oc/kubectl is available and connected
    if command -v oc &> /dev/null; then
        KUBE_CMD="oc"
        log "Checking OpenShift CLI connection..."
        if ! oc whoami; then
            error "OpenShift CLI not connected. Please login first with: oc login"
        fi
        log "✓ OpenShift CLI connected as: $(oc whoami)"
    elif command -v kubectl &> /dev/null; then
        KUBE_CMD="kubectl"
        log "Using kubectl..."
    else
        error "Neither oc nor kubectl is installed. Please install one of them."
    fi
    
    # Check if openssl is installed
    if ! command -v openssl &> /dev/null; then
        error "openssl is required but not found. Please install openssl."
    fi
    log "✓ openssl found"
    
    # Check if we have cluster admin privileges
    log "Checking cluster admin privileges..."
    if ! $KUBE_CMD auth can-i create subscriptions --all-namespaces 2>/dev/null; then
        warning "Cluster admin privileges may be required to install operators. Current user: $($KUBE_CMD whoami 2>/dev/null || echo 'unknown')"
    else
        log "✓ Cluster admin privileges confirmed"
    fi
    
    # Check if namespace exists
    if ! $KUBE_CMD get namespace "$NAMESPACE" &> /dev/null; then
        error "Namespace '$NAMESPACE' does not exist. Please install RHACS first."
    fi
    log "✓ Namespace '$NAMESPACE' exists"
    
    log "Prerequisites validated successfully"
    log "Using namespace: $NAMESPACE"
    
    export KUBE_CMD
}

get_rox_central_url() {
    log_info "Getting ROX Central URL..."
    
    # Check if already set in environment
    if [ -n "${ROX_CENTRAL_URL:-}" ]; then
        log_info "✓ ROX Central URL already set: $ROX_CENTRAL_URL"
        return 0
    fi
    
    # Try to get the route (OpenShift)
    if $KUBE_CMD get route central -n "$NAMESPACE" &> /dev/null; then
        ROX_CENTRAL_URL="https://$($KUBE_CMD get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
    # Try to get the ingress
    elif $KUBE_CMD get ingress central -n "$NAMESPACE" &> /dev/null; then
        ROX_CENTRAL_URL="https://$($KUBE_CMD get ingress central -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')"
    # Fallback to service
    else
        ROX_CENTRAL_URL="https://central.$NAMESPACE.svc.cluster.local:443"
    fi
    
    log_info "ROX Central URL: $ROX_CENTRAL_URL"
    export ROX_CENTRAL_URL
    
    # Store in ~/.bashrc if not already there
    if [ -f ~/.bashrc ]; then
        if ! grep -q "export ROX_CENTRAL_URL=" ~/.bashrc; then
            echo "" >> ~/.bashrc
            echo "# RHACS Monitoring Configuration" >> ~/.bashrc
            echo "export ROX_CENTRAL_URL='$ROX_CENTRAL_URL'" >> ~/.bashrc
            log "✓ ROX_CENTRAL_URL added to ~/.bashrc"
        fi
    fi
}

load_or_create_api_token() {
    log_step "Checking for ROX_API_TOKEN..."
    
    # Check if already set in environment first
    if [ -n "${ROX_API_TOKEN:-}" ]; then
        log "✓ ROX_API_TOKEN already set in environment"
        # Store in ~/.bashrc
        if [ -f ~/.bashrc ] && ! grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
            if ! grep -q "# RHACS Monitoring Configuration" ~/.bashrc; then
                echo "" >> ~/.bashrc
                echo "# RHACS Monitoring Configuration" >> ~/.bashrc
            fi
            echo "export ROX_API_TOKEN='$ROX_API_TOKEN'" >> ~/.bashrc
            log "✓ ROX_API_TOKEN added to ~/.bashrc"
        fi
        return 0
    fi
    
    # Load from ~/.bashrc if available
    if [ -f ~/.bashrc ] && grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
        log "Found ROX_API_TOKEN in ~/.bashrc, extracting..."
        # Extract token directly from file instead of sourcing (avoids /etc/bashrc issues)
        ROX_API_TOKEN=$(grep "export ROX_API_TOKEN=" ~/.bashrc | head -1 | sed "s/export ROX_API_TOKEN=//g" | tr -d "'" | tr -d '"')
        if [ -n "${ROX_API_TOKEN:-}" ]; then
            export ROX_API_TOKEN
            log "✓ Loaded ROX_API_TOKEN from ~/.bashrc"
            return 0
        fi
    fi
    
    # Try to generate API token automatically
    log "Attempting to generate ROX_API_TOKEN automatically..."
    
    CENTRAL_ROUTE=$($KUBE_CMD get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "$CENTRAL_ROUTE" ]; then
        warning "Central route not found. Cannot auto-generate API token."
        warning "Please set ROX_API_TOKEN manually: export ROX_API_TOKEN='your-token-here'"
        return 1
    fi
    
    # Get admin password from secret
    ADMIN_PASSWORD_B64=$($KUBE_CMD get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null || echo "")
    if [ -z "$ADMIN_PASSWORD_B64" ]; then
        warning "Admin password secret not found. Cannot auto-generate API token."
        warning "Please set ROX_API_TOKEN manually: export ROX_API_TOKEN='your-token-here'"
        return 1
    fi
    
    ADMIN_PASSWORD=$(echo "$ADMIN_PASSWORD_B64" | base64 -d)
    if [ -z "$ADMIN_PASSWORD" ]; then
        warning "Failed to decode admin password. Cannot auto-generate API token."
        return 1
    fi
    
    # Generate API token
    log "Generating API token..."
    set +e
    TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
        -u "admin:${ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        "https://${CENTRAL_ROUTE}/v1/apitokens/generate" \
        -d '{"name":"rhacs-monitoring-setup-token","roles":["Admin"]}' 2>&1)
    TOKEN_CURL_EXIT_CODE=$?
    set -e
    
    if [ $TOKEN_CURL_EXIT_CODE -eq 0 ]; then
        # Extract token from response
        if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
            ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // .data.token // empty' 2>/dev/null || echo "")
        fi
        
        if [ -z "$ROX_API_TOKEN" ] || [ "$ROX_API_TOKEN" = "null" ]; then
            ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | grep -oE '[a-zA-Z0-9_-]{40,}' | head -1 || echo "")
        fi
        
        if [ -n "$ROX_API_TOKEN" ]; then
            log "✓ API token generated successfully (length: ${#ROX_API_TOKEN} chars)"
            export ROX_API_TOKEN
            
            # Store in ~/.bashrc
            if [ -f ~/.bashrc ]; then
                if ! grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
                    if ! grep -q "# RHACS Monitoring Configuration" ~/.bashrc; then
                        echo "" >> ~/.bashrc
                        echo "# RHACS Monitoring Configuration" >> ~/.bashrc
                    fi
                    echo "export ROX_API_TOKEN='$ROX_API_TOKEN'" >> ~/.bashrc
                    log "✓ ROX_API_TOKEN added to ~/.bashrc"
                fi
            fi
            return 0
        fi
    fi
    
    warning "Failed to auto-generate API token."
    warning "Please set ROX_API_TOKEN manually: export ROX_API_TOKEN='your-token-here'"
    return 1
}

create_api_token_secret() {
    log_info "Creating API token secret for Prometheus..."
    
    # Load or create API token
    if ! load_or_create_api_token; then
        log_warn "ROX_API_TOKEN is not set. Skipping API token secret creation."
        return 0
    fi
    
    # Check if secret already exists
    if $KUBE_CMD get secret "$API_TOKEN_SECRET_NAME" -n "$NAMESPACE" &> /dev/null; then
        log_warn "Secret '$API_TOKEN_SECRET_NAME' already exists. Deleting..."
        $KUBE_CMD delete secret "$API_TOKEN_SECRET_NAME" -n "$NAMESPACE"
    fi
    
    # Create the secret
    $KUBE_CMD create secret generic "$API_TOKEN_SECRET_NAME" \
        -n "$NAMESPACE" \
        --from-literal=token="$ROX_API_TOKEN"
    
    log_info "✓ API token secret created successfully."
}

generate_tls_certificates() {
    log_info "Generating TLS certificates for Prometheus..."
    
    # Generate certificate CN based on namespace
    CERT_CN="sample-$NAMESPACE-monitoring-stack-prometheus.$NAMESPACE.svc"
    
    # Generate a private key and certificate
    log "Generating TLS private key and certificate..."
    if openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -subj "/CN=$CERT_CN" \
            -keyout tls.key -out tls.crt 2>/dev/null; then
        log "✓ TLS certificate generated successfully"
        log "  Subject: $CERT_CN"
    else
        error "Failed to generate TLS certificate"
    fi
    
    # Always delete existing TLS secret to avoid certificate mixups
    log "Deleting existing TLS secret '$TLS_SECRET_NAME' if it exists..."
    $KUBE_CMD delete secret "$TLS_SECRET_NAME" -n "$NAMESPACE" 2>/dev/null && log "  Deleted existing secret" || log "  No existing secret found"
    
    # Create TLS secret in the namespace
    log "Creating TLS secret '$TLS_SECRET_NAME' in namespace '$NAMESPACE'..."
    if $KUBE_CMD create secret tls "$TLS_SECRET_NAME" --cert=tls.crt --key=tls.key -n "$NAMESPACE" 2>/dev/null; then
        log "✓ TLS secret created successfully"
    else
        error "Failed to create TLS secret"
    fi
    
    # Save certificates to monitoring-examples directory for testing
    if [ -d "$MONITORING_EXAMPLES_DIR/cluster-observability-operator" ]; then
        cp tls.crt tls.key "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/" 2>/dev/null || true
        log "✓ Certificates copied to monitoring-examples directory"
    fi
    
    # Export paths for diagnostics
    export TLS_CERT="$(pwd)/tls.crt"
    export TLS_KEY="$(pwd)/tls.key"
    
    # Create UserPKI auth provider in RHACS for Prometheus
    create_userpki_auth_provider
}

create_userpki_auth_provider() {
    log "Creating UserPKI auth provider in RHACS for Prometheus..."
    
    if [ -z "${ROX_API_TOKEN:-}" ]; then
        warning "ROX_API_TOKEN not set. Skipping UserPKI auth provider creation."
        warning "You may need to create the UserPKI auth provider manually later."
        return 0
    fi
    
    # Check if roxctl is available and working
    if command -v roxctl &>/dev/null; then
        # Test if it actually works (not a corrupted file)
        if roxctl version >/dev/null 2>&1; then
            ROXCTL_CMD="roxctl"
            log "✓ roxctl found in PATH and working"
        else
            warning "roxctl exists but appears corrupted, reinstalling..."
            # Remove corrupted version
            local roxctl_path=$(which roxctl 2>/dev/null)
            if [ -n "$roxctl_path" ] && [ -w "${roxctl_path}" ]; then
                rm -f "${roxctl_path}"
            elif [ -f ~/.local/bin/roxctl ]; then
                rm -f ~/.local/bin/roxctl
            fi
        fi
    fi
    
    # If roxctl is not available or was corrupted, install it
    if ! command -v roxctl &>/dev/null || ! roxctl version >/dev/null 2>&1; then
        log "roxctl not found or not working, attempting to install permanently..."
        
        # Detect OS and architecture
        local os=$(uname -s | tr '[:upper:]' '[:lower:]')
        local arch=$(uname -m)
        
        case "${arch}" in
            x86_64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
        esac
        
        # Download to temporary location
        local temp_dir=$(mktemp -d)
        local download_success=false
        
        # Method 1: Try downloading from Red Hat mirror (more reliable)
        log "Attempting download from Red Hat mirror..."
        local mirror_url="https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
        if curl -L -f -s -o "${temp_dir}/roxctl" "${mirror_url}" 2>/dev/null; then
            # Verify it's actually a binary
            if file "${temp_dir}/roxctl" 2>/dev/null | grep -q "executable"; then
                log "✓ Successfully downloaded from Red Hat mirror"
                download_success=true
            else
                warning "Downloaded file from mirror is not a valid executable"
                rm -f "${temp_dir}/roxctl"
            fi
        fi
        
        # Method 2: Try downloading from Central route (if method 1 failed)
        if [ "$download_success" = false ]; then
            log "Attempting download from RHACS Central..."
            local central_route=$($KUBE_CMD get route central -n ${NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            if [ -n "${central_route}" ]; then
                local roxctl_url="https://${central_route}/api/cli/download/roxctl-${os}"
                log "Downloading from: ${roxctl_url}"
                
                if curl -k -f -s -o "${temp_dir}/roxctl" "${roxctl_url}" 2>/dev/null; then
                    # Verify it's actually a binary
                    if file "${temp_dir}/roxctl" 2>/dev/null | grep -q "executable"; then
                        log "✓ Successfully downloaded from RHACS Central"
                        download_success=true
                    else
                        warning "Downloaded file from Central is not a valid executable"
                        rm -f "${temp_dir}/roxctl"
                    fi
                fi
            fi
        fi
        
        # Check if download was successful
        if [ "$download_success" = false ]; then
            warning "Failed to download roxctl from all sources"
            rm -rf "${temp_dir}"
            warning "Skipping UserPKI auth provider creation."
            warning "Install roxctl manually with:"
            warning "  curl -L -o /tmp/roxctl https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
            warning "  chmod +x /tmp/roxctl && sudo mv /tmp/roxctl /usr/local/bin/roxctl"
            return 0
        fi
        
        # Make executable
        chmod +x "${temp_dir}/roxctl"
        
        # Test the binary before installing
        if ! "${temp_dir}/roxctl" version >/dev/null 2>&1; then
            warning "Downloaded roxctl binary is not working correctly"
            rm -rf "${temp_dir}"
            warning "Skipping UserPKI auth provider creation."
            return 0
        fi
        
        # Install to /usr/local/bin or ~/.local/bin
        if [ -w "/usr/local/bin" ]; then
            mv "${temp_dir}/roxctl" /usr/local/bin/roxctl
            log "✓ roxctl installed to /usr/local/bin/roxctl"
        else
            mkdir -p ~/.local/bin
            mv "${temp_dir}/roxctl" ~/.local/bin/roxctl
            log "✓ roxctl installed to ~/.local/bin/roxctl"
            
            # Add to PATH if not already there
            if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
                export PATH="$HOME/.local/bin:$PATH"
                if [ -f ~/.bashrc ] && ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc; then
                    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
                    log "Added ~/.local/bin to PATH in ~/.bashrc"
                fi
            fi
        fi
        
        rm -rf "${temp_dir}"
        
        # Add gRPC ALPN fix to ~/.bashrc if not already there
        if [ -f ~/.bashrc ] && ! grep -q "GRPC_GO_REQUIRE_HANDSHAKE_ON" ~/.bashrc; then
            echo "" >> ~/.bashrc
            echo "# Fix for gRPC ALPN handshake issues with roxctl" >> ~/.bashrc
            echo "export GRPC_GO_REQUIRE_HANDSHAKE_ON=off" >> ~/.bashrc
            log "Added GRPC_GO_REQUIRE_HANDSHAKE_ON=off to ~/.bashrc"
        fi
        
        # Export it for current session
        export GRPC_GO_REQUIRE_HANDSHAKE_ON=off
        
        # Verify installation
        if command -v roxctl &>/dev/null && GRPC_GO_REQUIRE_HANDSHAKE_ON=off roxctl version >/dev/null 2>&1; then
            ROXCTL_CMD="roxctl"
            log "✓ roxctl successfully installed and verified"
        else
            warning "Failed to install or verify roxctl"
            warning "Skipping UserPKI auth provider creation."
            warning "You may need to run: source ~/.bashrc"
            return 0
        fi
    fi
    
    # Ensure GRPC fix is set for roxctl operations
    export GRPC_GO_REQUIRE_HANDSHAKE_ON=off
    
    if [ -n "${ROXCTL_CMD:-}" ]; then
        # Normalize ROX_ENDPOINT for roxctl
        ROX_ENDPOINT_NORMALIZED="${ROX_CENTRAL_URL#https://}"
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED#http://}"
        if [[ ! "$ROX_ENDPOINT_NORMALIZED" =~ :[0-9]+$ ]]; then
            ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED}:443"
        fi
        
        export ROX_API_TOKEN
        
        # Delete existing auth provider
        log "Deleting existing UserPKI auth provider 'Prometheus' if it exists..."
        set +e
        trap '' ERR
        printf 'y\n' | timeout 30 $ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central userpki delete Prometheus \
            --insecure-skip-tls-verify 2>&1 | head -5 || true
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        # Create new auth provider
        log "Creating UserPKI auth provider 'Prometheus' with Admin role..."
        if [ ! -f "tls.crt" ]; then
            error "Certificate file 'tls.crt' not found. Cannot create UserPKI auth provider."
        fi
        
        # Verify environment variables are set
        log "Verifying roxctl configuration..."
        log "  ROX_ENDPOINT: $ROX_ENDPOINT_NORMALIZED"
        log "  ROX_API_TOKEN: ${ROX_API_TOKEN:+<set>}"
        log "  Certificate: tls.crt"
        log "  roxctl command: $ROXCTL_CMD"
        
        # Test roxctl connectivity first
        log "Testing roxctl connectivity to RHACS..."
        set +e
        trap '' ERR
        WHOAMI_OUTPUT=$(ROX_API_TOKEN="$ROX_API_TOKEN" $ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central whoami --insecure-skip-tls-verify 2>&1)
        WHOAMI_EXIT_CODE=$?
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        if [ $WHOAMI_EXIT_CODE -eq 0 ]; then
            log "✓ roxctl can connect to RHACS Central"
            log "  Authenticated as: $(echo "$WHOAMI_OUTPUT" | grep -o '"name":"[^"]*"' | cut -d'"' -f4 || echo 'unknown')"
        else
            warning "roxctl cannot connect to RHACS Central"
            log "Error output: $WHOAMI_OUTPUT"
            warning "Skipping UserPKI auth provider creation."
            warning ""
            warning "To create manually, run:"
            warning "  export ROX_API_TOKEN='$ROX_API_TOKEN'"
            warning "  roxctl -e $ROX_ENDPOINT_NORMALIZED central userpki create Prometheus \\"
            warning "    -c tls.crt -r Admin --insecure-skip-tls-verify"
            return 0
        fi
        
        # Now try to create the auth provider
        log "Creating UserPKI auth provider..."
        set +e
        trap '' ERR
        AUTH_PROVIDER_OUTPUT=$(ROX_API_TOKEN="$ROX_API_TOKEN" $ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central userpki create Prometheus \
            -c tls.crt \
            -r Admin \
            --insecure-skip-tls-verify 2>&1)
        AUTH_PROVIDER_EXIT_CODE=$?
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        if [ $AUTH_PROVIDER_EXIT_CODE -eq 0 ]; then
            log "✓ UserPKI auth provider 'Prometheus' created successfully"
        elif echo "$AUTH_PROVIDER_OUTPUT" | grep -qi "already exists"; then
            log "✓ UserPKI auth provider 'Prometheus' already exists"
        else
            warning "Failed to create UserPKI auth provider."
            log "Exit code: $AUTH_PROVIDER_EXIT_CODE"
            log "Output: $AUTH_PROVIDER_OUTPUT"
            warning ""
            warning "This is optional - API token authentication is working."
            warning "To create the auth provider manually:"
            warning ""
            warning "1. Via roxctl command line:"
            warning "   export ROX_API_TOKEN='$ROX_API_TOKEN'"
            warning "   roxctl -e $ROX_ENDPOINT_NORMALIZED central userpki create Prometheus \\"
            warning "     -c tls.crt -r Admin --insecure-skip-tls-verify"
            warning ""
            warning "2. Via RHACS UI:"
            warning "   - Login to: $ROX_CENTRAL_URL"
            warning "   - Go to: Platform Configuration → Access Control → Auth Providers"
            warning "   - Click 'Create auth provider'"
            warning "   - Type: User Certificates"
            warning "   - Name: Prometheus"
            warning "   - Upload: tls.crt"
            warning "   - Save and enable"
            warning ""
        fi
    fi
}

apply_rhacs_configuration() {
    log_info "Applying RHACS declarative configuration..."
    
    if [ ! -f "$MONITORING_EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml" ]; then
        log_error "Declarative configuration file not found."
        return 1
    fi
    
    $KUBE_CMD apply -f "$MONITORING_EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml"
    
    log_info "✓ RHACS configuration applied successfully."
}

# Function to apply YAML with namespace substitution
apply_yaml_with_namespace() {
    local yaml_file="$1"
    local description="$2"
    
    if [ ! -f "$yaml_file" ]; then
        error "YAML file not found: $yaml_file"
    fi
    
    log "Installing $description..."
    # Replace various namespace patterns
    sed "s/namespace: stackrox/namespace: $NAMESPACE/g; \
         s/namespace: \"stackrox\"/namespace: \"$NAMESPACE\"/g; \
         s/\\.stackrox\\.svc\\.cluster\\.local/\\.$NAMESPACE\\.svc\\.cluster\\.local/g; \
         s/\\.stackrox\\.svc/\\.$NAMESPACE\\.svc/g" "$yaml_file" | \
        $KUBE_CMD apply -f - || error "Failed to apply $yaml_file"
    log "✓ $description installed successfully"
}

install_cluster_observability_operator() {
    log ""
    log "========================================================="
    log "Installing Cluster Observability Operator"
    log "========================================================="
    
    # Check if already installed
    if $KUBE_CMD get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        if $KUBE_CMD get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
            CURRENT_CSV=$($KUBE_CMD get subscription.operators.coreos.com cluster-observability-operator -n $OPERATOR_NAMESPACE -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
            if [ -n "$CURRENT_CSV" ] && $KUBE_CMD get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE >/dev/null 2>&1; then
                CSV_PHASE=$($KUBE_CMD get csv $CURRENT_CSV -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
                if [ "$CSV_PHASE" = "Succeeded" ]; then
                    log "✓ Cluster Observability Operator is already installed and running"
                    return 0
                fi
            fi
        fi
    fi
    
    # Create namespace
    log "Creating $OPERATOR_NAMESPACE namespace..."
    if ! $KUBE_CMD get namespace $OPERATOR_NAMESPACE >/dev/null 2>&1; then
        $KUBE_CMD create namespace $OPERATOR_NAMESPACE || error "Failed to create namespace"
        log "✓ Namespace created"
    else
        log "✓ Namespace already exists"
    fi
    
    # Create OperatorGroup
    log "Creating OperatorGroup..."
    cat <<EOF | $KUBE_CMD apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cluster-observability-og
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces: []
EOF
    log "✓ OperatorGroup created"
    sleep 3
    
    # Create Subscription
    log "Creating Subscription..."
    cat <<EOF | $KUBE_CMD apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-observability-operator
  namespace: $OPERATOR_NAMESPACE
spec:
  channel: stable
  installPlanApproval: Automatic
  name: cluster-observability-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    log "✓ Subscription created"
    
    # Wait for CSV
    log "Waiting for operator to be installed (this may take a few minutes)..."
    MAX_WAIT=60
    WAIT_COUNT=0
    while ! $KUBE_CMD get csv -n $OPERATOR_NAMESPACE 2>/dev/null | grep -q cluster-observability-operator; do
        if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
            error "CSV not created after $((MAX_WAIT * 10)) seconds"
        fi
        if [ $((WAIT_COUNT % 6)) -eq 0 ]; then
            log "Waiting for CSV to be created... ($WAIT_COUNT/$MAX_WAIT)"
        fi
        sleep 10
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done
    
    CSV_NAME=$($KUBE_CMD get csv -n $OPERATOR_NAMESPACE -o name 2>/dev/null | grep cluster-observability-operator | head -1 | sed 's|clusterserviceversion.operators.coreos.com/||' || echo "")
    if [ -z "$CSV_NAME" ]; then
        error "Failed to find CSV name"
    fi
    log "Found CSV: $CSV_NAME"
    
    # Wait for CSV to succeed
    log "Waiting for CSV to be ready..."
    if ! $KUBE_CMD wait --for=jsonpath='{.status.phase}'=Succeeded "csv/$CSV_NAME" -n $OPERATOR_NAMESPACE --timeout=300s 2>/dev/null; then
        warning "CSV wait timeout, but continuing..."
    fi
    
    log "✓ Cluster Observability Operator installed successfully"
    log ""
}

apply_monitoring_stack() {
    log ""
    log "========================================================="
    log "Installing Monitoring Resources"
    log "========================================================="
    
    # Check if Cluster Observability Operator is installed
    if ! $KUBE_CMD get crd monitoringstacks.monitoring.rhobs &> /dev/null; then
        log_warn "Cluster Observability Operator CRDs not found."
        log_warn "Installing operator first..."
        install_cluster_observability_operator
    fi
    
    # Install MonitoringStack
    if [ -f "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml" ]; then
        apply_yaml_with_namespace \
            "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml" \
            "MonitoringStack"
        sleep 3
    fi
    
    # Install ScrapeConfig
    if [ -f "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml" ]; then
        apply_yaml_with_namespace \
            "$MONITORING_EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml" \
            "ScrapeConfig"
    fi
    
    log "✓ Monitoring stack resources installed"
}

apply_prometheus_resources() {
    log ""
    log "========================================================="
    log "Installing Prometheus Resources"
    log "========================================================="
    
    if [ -f "$MONITORING_EXAMPLES_DIR/prometheus-operator/additional-scrape-config.yaml" ]; then
        apply_yaml_with_namespace \
            "$MONITORING_EXAMPLES_DIR/prometheus-operator/additional-scrape-config.yaml" \
            "Prometheus additional scrape config"
    fi
    
    if [ -f "$MONITORING_EXAMPLES_DIR/prometheus-operator/prometheus.yaml" ]; then
        apply_yaml_with_namespace \
            "$MONITORING_EXAMPLES_DIR/prometheus-operator/prometheus.yaml" \
            "Prometheus server"
    fi
    
    log "✓ Prometheus resources installed"
}

apply_perses_resources() {
    log ""
    log "========================================================="
    log "Installing Perses Resources"
    log "========================================================="
    
    if [ -f "$MONITORING_EXAMPLES_DIR/perses/datasource.yaml" ]; then
        apply_yaml_with_namespace \
            "$MONITORING_EXAMPLES_DIR/perses/datasource.yaml" \
            "Perses Datasource"
    fi
    
    if [ -f "$MONITORING_EXAMPLES_DIR/perses/dashboard.yaml" ]; then
        apply_yaml_with_namespace \
            "$MONITORING_EXAMPLES_DIR/perses/dashboard.yaml" \
            "Perses Dashboard"
    fi
    
    if [ -f "$MONITORING_EXAMPLES_DIR/perses/ui-plugin.yaml" ]; then
        log "Installing Perses UI Plugin..."
        if grep -q "namespace:" "$MONITORING_EXAMPLES_DIR/perses/ui-plugin.yaml"; then
            apply_yaml_with_namespace \
                "$MONITORING_EXAMPLES_DIR/perses/ui-plugin.yaml" \
                "Perses UI Plugin"
        else
            $KUBE_CMD apply -f "$MONITORING_EXAMPLES_DIR/perses/ui-plugin.yaml" || warning "Failed to apply UI plugin"
            log "✓ Perses UI Plugin installed"
        fi
    fi
    
    log "✓ Perses resources installed"
}

run_diagnostics() {
    log ""
    log "========================================================="
    log "Running Diagnostics"
    log "========================================================="
    
    echo ""
    log "=== Namespace Resources ==="
    $KUBE_CMD get all -n "$NAMESPACE" 2>/dev/null | grep -E "(prometheus|monitoring|alertmanager)" || log "No monitoring resources found"
    
    echo ""
    log "=== Secrets ==="
    $KUBE_CMD get secrets -n "$NAMESPACE" 2>/dev/null | grep -E "(prometheus|tls|token)" || log "No monitoring secrets found"
    
    echo ""
    log "=== MonitoringStack Status ==="
    $KUBE_CMD get monitoringstack -n "$NAMESPACE" 2>/dev/null || log "No MonitoringStack found"
    
    echo ""
    log "=== ScrapeConfig Status ==="
    $KUBE_CMD get scrapeconfig -n "$NAMESPACE" 2>/dev/null || log "No ScrapeConfig found"
    
    echo ""
    log "=== Testing Certificate Access ==="
    if [ -f "${TLS_CERT:-}" ] && [ -f "${TLS_KEY:-}" ]; then
        log "Testing: curl --cert $TLS_CERT --key $TLS_KEY $ROX_CENTRAL_URL/v1/auth/status"
        
        if curl --cert "$TLS_CERT" --key "$TLS_KEY" -k -s "$ROX_CENTRAL_URL/v1/auth/status" > /dev/null 2>&1; then
            log "✓ TLS certificate authentication successful!"
            curl --cert "$TLS_CERT" --key "$TLS_KEY" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>/dev/null | head -20
        else
            warning "✗ Certificate authentication not yet working"
            warning "You may need to configure the User Certificates auth provider in RHACS UI"
        fi
    fi
    
    echo ""
    if [ -n "${ROX_API_TOKEN:-}" ]; then
        log "=== Testing API Token Access ==="
        if curl -H "Authorization: Bearer $ROX_API_TOKEN" -k -s "$ROX_CENTRAL_URL/v1/auth/status" > /dev/null 2>&1; then
            log "✓ API token authentication successful!"
            curl -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>/dev/null | head -20
        else
            warning "✗ API token authentication failed"
        fi
    fi
}

print_next_steps() {
    echo ""
    log "========================================================="
    log "Setup Complete!"
    log "========================================================="
    echo ""
    echo "Environment variables configured in ~/.bashrc:"
    echo "  - ROX_CENTRAL_URL='$ROX_CENTRAL_URL'"
    [ -n "${ROX_API_TOKEN:-}" ] && echo "  - ROX_API_TOKEN=<set>"
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Access Prometheus UI:"
    echo "   $KUBE_CMD port-forward -n $NAMESPACE svc/sample-$NAMESPACE-monitoring-stack-prometheus 9090:9090"
    echo "   Open: http://localhost:9090"
    echo ""
    echo "2. View metrics:"
    echo "   curl -H \"Authorization: Bearer \$ROX_API_TOKEN\" -k \$ROX_CENTRAL_URL/metrics"
    echo ""
    echo "3. Configure custom metrics:"
    echo "   See: $MONITORING_EXAMPLES_DIR/rhacs/README.md"
    echo ""
    echo "4. Access Perses dashboards (if available):"
    echo "   Check the OpenShift console for Perses UI plugin"
    echo ""
}

# Main execution
main() {
    log ""
    log "========================================================="
    log "RHACS Monitoring Setup"
    log "========================================================="
    echo ""
    
    check_prerequisites
    get_rox_central_url
    create_api_token_secret
    generate_tls_certificates
    apply_rhacs_configuration
    install_cluster_observability_operator
    apply_monitoring_stack
    apply_prometheus_resources
    apply_perses_resources
    run_diagnostics
    print_next_steps
    
    log ""
    log "✓ Setup completed successfully!"
    log ""
}

# Run main function
main "$@"
