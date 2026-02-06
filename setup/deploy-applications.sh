#!/bin/bash
# Application Deployment Script
# Deploys applications to OpenShift cluster and runs security scans

# Exit immediately on error, show exact error message
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[APP-DEPLOY]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[APP-DEPLOY]${NC} $1"
}

error() {
    echo -e "${RED}[APP-DEPLOY] ERROR:${NC} $1" >&2
    echo -e "${RED}[APP-DEPLOY] Script failed at line ${BASH_LINENO[0]}${NC}" >&2
    exit 1
}

# Trap to show error details on exit
trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR

# Set up script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
DEMO_LABEL="demo=roadshow"

# Prerequisites validation
log "Validating prerequisites..."

# Check if oc is available and connected
log "Checking OpenShift CLI connection..."
if ! oc whoami; then
    error "OpenShift CLI not connected. Please login first with: oc login"
fi
log "[OK] OpenShift CLI connected as: $(oc whoami)"
log "Prerequisites validated successfully"

# Clone demo applications repository
log "Cloning demo applications repository..."
if [ ! -d "demo-applications" ]; then
    if ! git clone https://github.com/mfosterrox/demo-applications demo-applications; then
        error "Failed to clone demo-applications repository. Check network connectivity and repository access."
    fi
    log "[OK] Demo applications repository cloned successfully"
else
    log "Demo applications repository already exists, skipping clone"
fi

# Set TUTORIAL_HOME environment variable
log "Setting TUTORIAL_HOME environment variable..."
TUTORIAL_HOME="$(pwd)/demo-applications"
if [ ! -d "$TUTORIAL_HOME" ]; then
    error "TUTORIAL_HOME directory does not exist: $TUTORIAL_HOME"
fi
sed -i '/^export TUTORIAL_HOME=/d' ~/.bashrc 2>/dev/null || true
echo "export TUTORIAL_HOME=\"$TUTORIAL_HOME\"" >> ~/.bashrc
export TUTORIAL_HOME="$TUTORIAL_HOME"
log "[OK] TUTORIAL_HOME set to: $TUTORIAL_HOME"

# Deploy applications
log "Deploying applications from $TUTORIAL_HOME..."

# Deploy k8s-deployment-manifests
if [ -d "$TUTORIAL_HOME/k8s-deployment-manifests" ]; then
    log "Deploying k8s-deployment-manifests..."
    
    # Check if Skupper CRDs are installed, install if needed
    SKUPPER_CRDS_INSTALLED=false
    if oc get crd sites.skupper.io >/dev/null 2>&1 && oc get crd serviceexports.skupper.io >/dev/null 2>&1; then
        SKUPPER_CRDS_INSTALLED=true
        log "[OK] Skupper CRDs already installed"
    else
        # Try to install Skupper CRDs using the installation script if it exists
        SKUPPER_INSTALL_SCRIPT="$TUTORIAL_HOME/k8s-deployment-manifests/skupper-online-boutique/00-install-skupper-crds.sh"
        if [ -f "$SKUPPER_INSTALL_SCRIPT" ]; then
            log "Skupper CRDs not found. Installing using $SKUPPER_INSTALL_SCRIPT..."
            set +e
            # Use bash to run the script and capture output
            if bash "$SKUPPER_INSTALL_SCRIPT" 2>&1 | tee /tmp/skupper-install.log; then
                log "Waiting for Skupper CRDs to be established..."
                sleep 5  # Give CRDs a moment to register
                oc wait --for=condition=Established crd/sites.skupper.io --timeout=120s >/dev/null 2>&1 || true
                oc wait --for=condition=Established crd/serviceexports.skupper.io --timeout=120s >/dev/null 2>&1 || true
                oc wait --for=condition=Established crd/connectors.skupper.io --timeout=120s >/dev/null 2>&1 || true
                oc wait --for=condition=Established crd/listeners.skupper.io --timeout=120s >/dev/null 2>&1 || true
                
                # Verify CRDs are actually available
                if oc get crd sites.skupper.io >/dev/null 2>&1 && oc get crd serviceexports.skupper.io >/dev/null 2>&1; then
                    SKUPPER_CRDS_INSTALLED=true
                    log "[OK] Skupper CRDs installed and verified successfully"
                else
                    warning "Skupper CRDs installation completed but CRDs not yet available. Will retry check..."
                    # Give it more time and check again
                    sleep 10
                    if oc get crd sites.skupper.io >/dev/null 2>&1 && oc get crd serviceexports.skupper.io >/dev/null 2>&1; then
                        SKUPPER_CRDS_INSTALLED=true
                        log "[OK] Skupper CRDs now available"
                    else
                        warning "Skupper CRDs still not available after installation. Skupper resources will be skipped."
                    fi
                fi
            else
                warning "Skupper CRD installation script failed. Trying direct installation..."
                # Fall back to direct installation
                SKUPPER_VERSION="${SKUPPER_VERSION:-2.1.3}"
                if oc apply -f "https://github.com/skupperproject/skupper/releases/download/${SKUPPER_VERSION}/skupper-cluster-scope.yaml" 2>&1; then
                    log "Waiting for Skupper CRDs to be established..."
                    sleep 5
                    oc wait --for=condition=Established crd/sites.skupper.io --timeout=120s >/dev/null 2>&1 || true
                    oc wait --for=condition=Established crd/serviceexports.skupper.io --timeout=120s >/dev/null 2>&1 || true
                    if oc get crd sites.skupper.io >/dev/null 2>&1 && oc get crd serviceexports.skupper.io >/dev/null 2>&1; then
                        SKUPPER_CRDS_INSTALLED=true
                        log "[OK] Skupper CRDs installed successfully via direct method"
                    fi
                fi
            fi
            set -e
        else
            # Install Skupper CRDs directly if script doesn't exist
            log "Skupper CRDs not found. Installing Skupper CRDs directly..."
            SKUPPER_VERSION="${SKUPPER_VERSION:-2.1.3}"
            set +e
            INSTALL_OUTPUT=$(oc apply -f "https://github.com/skupperproject/skupper/releases/download/${SKUPPER_VERSION}/skupper-cluster-scope.yaml" 2>&1)
            INSTALL_EXIT_CODE=$?
            set -e
            
            if [ $INSTALL_EXIT_CODE -eq 0 ]; then
                log "Waiting for Skupper CRDs to be established..."
                sleep 5
                
                # Wait for CRDs with retries
                MAX_RETRIES=3
                RETRY_COUNT=0
                CRDS_READY=false
                
                while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$CRDS_READY" = false ]; do
                    # Wait for CRDs to be established
                    oc wait --for=condition=Established crd/sites.skupper.io --timeout=60s >/dev/null 2>&1 || true
                    oc wait --for=condition=Established crd/serviceexports.skupper.io --timeout=60s >/dev/null 2>&1 || true
                    oc wait --for=condition=Established crd/connectors.skupper.io --timeout=60s >/dev/null 2>&1 || true
                    oc wait --for=condition=Established crd/listeners.skupper.io --timeout=60s >/dev/null 2>&1 || true
                    
                    # Verify CRDs are actually available
                    if oc get crd sites.skupper.io >/dev/null 2>&1 && oc get crd serviceexports.skupper.io >/dev/null 2>&1; then
                        CRDS_READY=true
                        SKUPPER_CRDS_INSTALLED=true
                        log "[OK] Skupper CRDs installed and verified successfully"
                    else
                        RETRY_COUNT=$((RETRY_COUNT + 1))
                        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                            log "CRDs not yet available, retrying in 10 seconds... (attempt $RETRY_COUNT/$MAX_RETRIES)"
                            sleep 10
                        fi
                    fi
                done
                
                if [ "$CRDS_READY" = false ]; then
                    # Final check - maybe CRDs are there but just not established yet
                    if oc get crd sites.skupper.io >/dev/null 2>&1 && oc get crd serviceexports.skupper.io >/dev/null 2>&1; then
                        SKUPPER_CRDS_INSTALLED=true
                        log "[OK] Skupper CRDs found (may still be establishing)"
                    else
                        warning "Skupper CRDs installation completed but CRDs not yet available."
                        warning "This may be normal - CRDs can take time to be established."
                        warning "If Skupper resources deploy successfully, the CRDs are working."
                        warning "To verify manually: oc get crd | grep skupper"
                    fi
                fi
            else
                warning "Failed to install Skupper CRDs (exit code: $INSTALL_EXIT_CODE)."
                warning "Output: ${INSTALL_OUTPUT:0:200}"
                warning "Skupper resources will be skipped."
                warning "To install manually: kubectl apply -f https://github.com/skupperproject/skupper/releases/download/${SKUPPER_VERSION}/skupper-cluster-scope.yaml"
            fi
        fi
    fi
    
    # Deploy all manifests - try Skupper even if CRD check was uncertain
    # The actual deployment will fail gracefully if CRDs aren't ready
    if [ "$SKUPPER_CRDS_INSTALLED" = "true" ]; then
        # Deploy everything including Skupper
        log "Deploying all resources including Skupper..."
        if ! oc apply -R -f "$TUTORIAL_HOME/k8s-deployment-manifests/" 2>&1; then
            error "Failed to deploy k8s-deployment-manifests. Check manifests: ls -la $TUTORIAL_HOME/k8s-deployment-manifests/"
        fi
    else
        # Try deploying Skupper anyway - if CRDs are actually there, it will work
        # If not, we'll get a clear error and can skip just that part
        log "Attempting to deploy all resources (including Skupper)..."
        set +e
        # Temporarily disable ERR trap to allow controlled error handling
        trap '' ERR
        DEPLOY_OUTPUT=$(oc apply -R -f "$TUTORIAL_HOME/k8s-deployment-manifests/" 2>&1)
        DEPLOY_EXIT_CODE=$?
        # Re-enable ERR trap
        trap 'error "Command failed: $(cat <<< "$BASH_COMMAND")"' ERR
        set -e
        
        if [ $DEPLOY_EXIT_CODE -eq 0 ]; then
            log "[OK] All resources deployed successfully (including Skupper)"
        else
            # Check if the error is specifically about Skupper CRDs
            if echo "$DEPLOY_OUTPUT" | grep -qi "no matches for kind.*skupper\|unable to recognize.*skupper"; then
                warning "Skupper CRDs not available. Deploying non-Skupper resources only..."
                # Deploy everything except Skupper resources
                for dir in "$TUTORIAL_HOME/k8s-deployment-manifests"/*; do
                    if [ -d "$dir" ] && [ "$(basename "$dir")" != "skupper-online-boutique" ]; then
                        log "Deploying $(basename "$dir")..."
                        if ! oc apply -R -f "$dir" 2>&1; then
                            warning "Failed to deploy $(basename "$dir")"
                        fi
                    fi
                done
                warning "Skipped skupper-online-boutique (Skupper CRDs not available)"
            else
                # Some other error occurred
                error "Failed to deploy k8s-deployment-manifests. Error: ${DEPLOY_OUTPUT:0:500}"
            fi
        fi
    fi
    
    # Deploy namespace files (regardless of Skupper CRD status)
    if [ -d "$TUTORIAL_HOME/k8s-deployment-manifests/-namespaces" ]; then
        log "Deploying namespace definitions..."
        if ! oc apply -f "$TUTORIAL_HOME/k8s-deployment-manifests/-namespaces/"; then
            warning "Failed to deploy some namespace definitions, continuing..."
        fi
    fi
    
    log "[OK] k8s-deployment-manifests deployed successfully"
else
    error "k8s-deployment-manifests directory not found at: $TUTORIAL_HOME/k8s-deployment-manifests"
fi

# Deploy skupper-demo
if [ -d "$TUTORIAL_HOME/skupper-demo" ]; then
    log "Deploying skupper-demo..."
    if ! oc apply -R -f "$TUTORIAL_HOME/skupper-demo/"; then
        error "Failed to deploy skupper-demo. Check manifests: ls -la $TUTORIAL_HOME/skupper-demo/"
    fi
    log "[OK] skupper-demo deployed successfully"
else
    warning "skupper-demo directory not found at: $TUTORIAL_HOME/skupper-demo, skipping"
fi

# Deployment completed - skipping wait/verification steps
log "Application deployment completed!"
log "Deployments have been applied. Use 'oc get pods -A' to check status."