#!/bin/bash
#
# RHACS Monitoring Setup Script
# Follows the official monitoring-examples installation flow
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
NAMESPACE="${NAMESPACE:-stackrox}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$SCRIPT_DIR/monitoring-examples"

# Detect kubectl/oc
if command -v oc &>/dev/null; then
    KUBE_CMD="oc"
else
    KUBE_CMD="kubectl"
fi

echo ""
step "RHACS Monitoring Setup"
echo "=========================================="
echo ""

#================================================================
# Prerequisites
#================================================================
log "Checking prerequisites..."

if ! $KUBE_CMD whoami &>/dev/null; then
    error "Not connected to cluster. Please login first: oc login"
fi
log "✓ Connected as: $($KUBE_CMD whoami)"

if ! $KUBE_CMD get namespace "$NAMESPACE" &>/dev/null; then
    error "Namespace '$NAMESPACE' not found. Install RHACS first."
fi
log "✓ Namespace '$NAMESPACE' exists"

if ! command -v openssl &>/dev/null; then
    error "openssl not found. Please install openssl."
fi
log "✓ openssl found"

if ! command -v jq &>/dev/null; then
    warning "jq not found - will use roxctl fallback for auth provider creation"
else
    log "✓ jq found"
fi

log ""

#================================================================
# Set project/namespace
#================================================================
step "Setting namespace to $NAMESPACE"
$KUBE_CMD project "$NAMESPACE" 2>/dev/null || log "Using namespace: $NAMESPACE"
log ""

#================================================================
# Load/Generate ROX_API_TOKEN
#================================================================
step "Configuring ROX_API_TOKEN"
log ""

# Get ROX_CENTRAL_URL
if [ -z "${ROX_CENTRAL_URL:-}" ]; then
    if $KUBE_CMD get route central -n "$NAMESPACE" &>/dev/null; then
        ROX_CENTRAL_URL="https://$($KUBE_CMD get route central -n "$NAMESPACE" -o jsonpath='{.spec.host}')"
        export ROX_CENTRAL_URL
        log "✓ Detected ROX_CENTRAL_URL: $ROX_CENTRAL_URL"
    else
        error "ROX_CENTRAL_URL not set and could not auto-detect from route"
    fi
else
    log "✓ ROX_CENTRAL_URL already set: $ROX_CENTRAL_URL"
fi

# Set ROX_API_ENDPOINT (without https://)
export ROX_API_ENDPOINT="${ROX_CENTRAL_URL#https://}"
export ROX_API_ENDPOINT="${ROX_API_ENDPOINT#http://}"

# Check for or generate ROX_API_TOKEN
if [ -z "${ROX_API_TOKEN:-}" ]; then
    # Try to load from ~/.bashrc
    if [ -f ~/.bashrc ] && grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
        ROX_API_TOKEN=$(grep "export ROX_API_TOKEN=" ~/.bashrc | head -1 | sed "s/export ROX_API_TOKEN=//g" | tr -d "'" | tr -d '"')
        export ROX_API_TOKEN
        log "✓ Loaded ROX_API_TOKEN from ~/.bashrc"
    else
        # Try to generate it
        log "Attempting to generate ROX_API_TOKEN..."
        
        ADMIN_PASSWORD=$($KUBE_CMD get secret central-htpasswd -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
        if [ -n "$ADMIN_PASSWORD" ]; then
            TOKEN_RESPONSE=$(curl -k -s --connect-timeout 15 --max-time 60 -X POST \
                -u "admin:${ADMIN_PASSWORD}" \
                -H "Content-Type: application/json" \
                "https://${ROX_API_ENDPOINT}/v1/apitokens/generate" \
                -d '{"name":"monitoring-setup-'$(date +%s)'","roles":["Admin"]}' 2>&1)
            
            if echo "$TOKEN_RESPONSE" | jq . >/dev/null 2>&1; then
                ROX_API_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token // empty')
                if [ -n "$ROX_API_TOKEN" ]; then
                    export ROX_API_TOKEN
                    log "✓ Generated ROX_API_TOKEN"
                    
                    # Save to ~/.bashrc
                    if [ -f ~/.bashrc ] && ! grep -q "export ROX_API_TOKEN=" ~/.bashrc; then
                        echo "export ROX_API_TOKEN='$ROX_API_TOKEN'" >> ~/.bashrc
                        log "✓ Saved ROX_API_TOKEN to ~/.bashrc"
                    fi
                fi
            fi
        fi
        
        if [ -z "${ROX_API_TOKEN:-}" ]; then
            error "Failed to generate ROX_API_TOKEN. Please set it manually: export ROX_API_TOKEN='your-token'"
        fi
    fi
else
    log "✓ ROX_API_TOKEN already set"
fi

# Save to ~/.bashrc if not there
if [ -f ~/.bashrc ]; then
    if ! grep -q "export ROX_CENTRAL_URL=" ~/.bashrc; then
        echo "export ROX_CENTRAL_URL='$ROX_CENTRAL_URL'" >> ~/.bashrc
    fi
    if ! grep -q "GRPC_ENFORCE_ALPN_ENABLED" ~/.bashrc; then
        echo "# Fix for gRPC ALPN enforcement issues with roxctl" >> ~/.bashrc
        echo "export GRPC_ENFORCE_ALPN_ENABLED=false" >> ~/.bashrc
    fi
fi

export GRPC_ENFORCE_ALPN_ENABLED=false
log ""

#================================================================
# Step 1: Install Cluster Observability Operator
#================================================================
step "Step 1: Installing Cluster Observability Operator"
log ""

if [ ! -f "$EXAMPLES_DIR/cluster-observability-operator/subscription.yaml" ]; then
    error "subscription.yaml not found in $EXAMPLES_DIR/cluster-observability-operator/"
fi

# Check if already installed
if $KUBE_CMD get csv -n openshift-cluster-observability-operator 2>/dev/null | grep -q cluster-observability-operator; then
    CSV=$($KUBE_CMD get csv -n openshift-cluster-observability-operator -o name 2>/dev/null | grep cluster-observability-operator | head -1)
    CSV_PHASE=$($KUBE_CMD get "$CSV" -n openshift-cluster-observability-operator -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$CSV_PHASE" = "Succeeded" ]; then
        log "✓ Cluster Observability Operator already installed and running"
    else
        log "Installing Cluster Observability Operator..."
        $KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/subscription.yaml"
        log "Waiting for operator to be ready..."
        sleep 30
    fi
else
    log "Installing Cluster Observability Operator..."
    $KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/subscription.yaml"
    
    # Wait for CSV to be created
    log "Waiting for CSV to be created (this may take 1-2 minutes)..."
    for i in {1..24}; do
        if $KUBE_CMD get csv -n openshift-cluster-observability-operator 2>/dev/null | grep -q cluster-observability-operator; then
            break
        fi
        sleep 5
        if [ $((i % 4)) -eq 0 ]; then
            log "  Still waiting... ($((i * 5))s)"
        fi
    done
    
    # Wait for CSV to succeed
    CSV=$($KUBE_CMD get csv -n openshift-cluster-observability-operator -o name 2>/dev/null | grep cluster-observability-operator | head -1 || echo "")
    if [ -n "$CSV" ]; then
        log "Found CSV: $CSV"
        log "Waiting for CSV to be ready..."
        $KUBE_CMD wait --for=jsonpath='{.status.phase}'=Succeeded "$CSV" -n openshift-cluster-observability-operator --timeout=300s || warning "CSV wait timeout"
        log "✓ Cluster Observability Operator installed"
    else
        error "CSV not found after installation"
    fi
fi
log ""

#================================================================
# Step 2: Generate User Certificates
#================================================================
step "Step 2: Generating user certificates"
log ""

cd "$SCRIPT_DIR"

# Generate certificate
CERT_CN="sample-$NAMESPACE-monitoring-stack-prometheus.$NAMESPACE.svc"
log "Generating TLS certificate with CN: $CERT_CN"

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj "/CN=$CERT_CN" \
    -keyout tls.key -out tls.crt 2>/dev/null

log "✓ Certificate generated: tls.crt, tls.key"

# Validate certificate
if openssl x509 -in tls.crt -noout -checkend 0 2>/dev/null; then
    log "✓ Certificate is valid"
else
    warning "Certificate validation failed"
fi

# Export TLS_CERT for later use
export TLS_CERT=$(cat tls.crt)
log "✓ TLS_CERT exported for auth provider creation"

# Create TLS secret
log "Creating TLS secret in namespace '$NAMESPACE'..."
$KUBE_CMD delete secret sample-$NAMESPACE-prometheus-tls -n "$NAMESPACE" 2>/dev/null || true
$KUBE_CMD create secret tls sample-$NAMESPACE-prometheus-tls --cert=tls.crt --key=tls.key -n "$NAMESPACE"
log "✓ TLS secret created"

# Create API token secret if token is set
if [ -n "${ROX_API_TOKEN:-}" ]; then
    log "Creating API token secret..."
    $KUBE_CMD delete secret $NAMESPACE-prometheus-api-token -n "$NAMESPACE" 2>/dev/null || true
    $KUBE_CMD create secret generic $NAMESPACE-prometheus-api-token \
        -n "$NAMESPACE" \
        --from-literal=token="$ROX_API_TOKEN"
    log "✓ API token secret created"
fi

log ""

#================================================================
# Step 3: Install and Configure Monitoring Stack
#================================================================
step "Step 3: Installing and configuring monitoring stack instance"
log ""

log "Applying MonitoringStack..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/monitoring-stack.yaml"
log "✓ MonitoringStack applied"

sleep 3

log "Applying ScrapeConfig..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/cluster-observability-operator/scrape-config.yaml"
log "✓ ScrapeConfig applied"

log "Waiting for Prometheus to start (30 seconds)..."
sleep 30

log ""

#================================================================
# Step 4: Install Perses and Configure Dashboard
#================================================================
step "Step 4: Installing Perses and configuring RHACS dashboard"
log ""

log "Applying Perses UI Plugin (cluster-scoped)..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/perses/ui-plugin.yaml"
log "✓ UI Plugin applied"

log "Applying Perses Datasource..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/perses/datasource.yaml"
log "✓ Datasource applied"

log "Applying Perses Dashboard..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/perses/dashboard.yaml"
log "✓ Dashboard applied"

log ""

#================================================================
# Step 5: Declare Permission Set and Role in RHACS
#================================================================
step "Step 5: Declaring permission set and role in RHACS"
log ""

log "Applying declarative configuration..."
$KUBE_CMD apply -f "$EXAMPLES_DIR/rhacs/declarative-configuration-configmap.yaml"
log "✓ Declarative configuration applied"
log "Note: RHACS will process this and create the 'Prometheus Server' role"

log ""

#================================================================
# Step 6: Create User-Certificate Auth Provider
#================================================================
step "Step 6: Creating User-Certificate auth provider"
log ""

# Try to create auth provider - API first, then roxctl fallback
AUTH_PROVIDER_CREATED=false

# Method 1: Try API with jq (proper JSON formatting)
if command -v jq &>/dev/null; then
    log "Attempting to create auth provider via API (using jq)..."
    
    # Build JSON payload using jq (handles escaping properly)
    AUTH_PROVIDER_JSON=$(jq -n \
        --arg name "Monitoring" \
        --arg type "userpki" \
        --arg uiEndpoint "$ROX_CENTRAL_URL" \
        --arg cert "$TLS_CERT" \
        '{
            name: $name,
            type: $type,
            uiEndpoint: $uiEndpoint,
            enabled: true,
            config: {
                keys: [$cert]
            },
            requiredAttributes: [],
            claimMappings: []
        }')
    
    # Create auth provider via API
    RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST "$ROX_CENTRAL_URL/v1/authProviders" \
        -H "Authorization: Bearer $ROX_API_TOKEN" \
        -H "Content-Type: application/json" \
        --data-raw "$AUTH_PROVIDER_JSON" 2>&1)
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    RESPONSE_BODY=$(echo "$RESPONSE" | head -n -1)
    
    if [ "$HTTP_CODE" = "200" ] || echo "$RESPONSE_BODY" | grep -q '"id"'; then
        log "✓ Auth provider 'Monitoring' created successfully via API"
        PROVIDER_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [ -n "$PROVIDER_ID" ]; then
            log "  Provider ID: $PROVIDER_ID"
        fi
        AUTH_PROVIDER_CREATED=true
    elif echo "$RESPONSE_BODY" | grep -qi "already exists"; then
        log "✓ Auth provider 'Monitoring' already exists"
        AUTH_PROVIDER_CREATED=true
    else
        warning "API method failed (HTTP $HTTP_CODE)"
        if [ -n "$RESPONSE_BODY" ]; then
            log "Response: ${RESPONSE_BODY:0:200}"
        fi
    fi
else
    warning "jq not found - skipping API method"
fi

# Method 2: Fallback to roxctl if API failed
if [ "$AUTH_PROVIDER_CREATED" = false ]; then
    log ""
    log "Attempting to create auth provider via roxctl..."
    
    # Check if roxctl is available
    ROXCTL_CMD=""
    if command -v roxctl &>/dev/null; then
        ROXCTL_CMD="roxctl"
    elif [ -f ~/.local/bin/roxctl ]; then
        ROXCTL_CMD="$HOME/.local/bin/roxctl"
    elif [ -f /usr/local/bin/roxctl ]; then
        ROXCTL_CMD="/usr/local/bin/roxctl"
    fi
    
    if [ -n "$ROXCTL_CMD" ]; then
        # Ensure GRPC fix is set
        export GRPC_ENFORCE_ALPN_ENABLED=false
        
        # Normalize endpoint (remove https://)
        ROX_ENDPOINT_NORMALIZED="${ROX_CENTRAL_URL#https://}"
        ROX_ENDPOINT_NORMALIZED="${ROX_ENDPOINT_NORMALIZED#http://}"
        
        log "Using roxctl: $ROXCTL_CMD"
        log "Endpoint: $ROX_ENDPOINT_NORMALIZED"
        
        # Try to create the auth provider
        AUTH_PROVIDER_OUTPUT=$(GRPC_ENFORCE_ALPN_ENABLED=false ROX_API_TOKEN="$ROX_API_TOKEN" \
            $ROXCTL_CMD -e "$ROX_ENDPOINT_NORMALIZED" \
            central userpki create Monitoring \
            -c tls.crt \
            -r Admin \
            --insecure-skip-tls-verify 2>&1)
        
        EXIT_CODE=$?
        
        if [ $EXIT_CODE -eq 0 ]; then
            log "✓ Auth provider 'Monitoring' created successfully via roxctl"
            AUTH_PROVIDER_CREATED=true
        elif echo "$AUTH_PROVIDER_OUTPUT" | grep -qi "already exists"; then
            log "✓ Auth provider 'Monitoring' already exists"
            AUTH_PROVIDER_CREATED=true
        else
            warning "roxctl method failed (exit code: $EXIT_CODE)"
            log "Output: ${AUTH_PROVIDER_OUTPUT:0:300}"
        fi
    else
        warning "roxctl not found - skipping roxctl method"
    fi
fi

# Method 3: Manual instructions if both methods failed
if [ "$AUTH_PROVIDER_CREATED" = false ]; then
    warning ""
    warning "Both API and roxctl methods failed."
    warning "You need to create the auth provider manually in RHACS UI:"
    warning "  1. Go to: $ROX_CENTRAL_URL"
    warning "  2. Navigate to: Platform Configuration → Access Control → Auth Providers"
    warning "  3. Create auth provider:"
    warning "     - Type: User Certificates"
    warning "     - Name: Monitoring"
    warning "     - Upload certificate: $SCRIPT_DIR/tls.crt"
fi

log ""

#================================================================
# Step 7: Configure Role for Auth Provider (Access Control)
#================================================================
step "Step 7: Configuring access control for Monitoring auth provider"
log ""

# Get the auth provider ID
log "Retrieving auth provider ID for 'Monitoring'..."
AUTH_PROVIDERS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
    "$ROX_CENTRAL_URL/v1/authProviders" 2>/dev/null || echo "")

if [ -z "$AUTH_PROVIDERS" ]; then
    warning "Failed to retrieve auth providers"
    warning "You'll need to configure access control manually (see below)"
else
    PROVIDER_ID=$(echo "$AUTH_PROVIDERS" | jq -r '.authProviders[] | select(.name=="Monitoring") | .id' 2>/dev/null || echo "")
    
    if [ -n "$PROVIDER_ID" ]; then
        log "✓ Found auth provider 'Monitoring' (ID: $PROVIDER_ID)"
        
        # Check if a group for this auth provider already exists
        EXISTING_GROUPS=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
            "$ROX_CENTRAL_URL/v1/groups" 2>/dev/null || echo "")
        
        GROUP_EXISTS=$(echo "$EXISTING_GROUPS" | jq -r --arg pid "$PROVIDER_ID" \
            '.groups[] | select(.props.authProviderId==$pid) | .props.id' 2>/dev/null || echo "")
        
        if [ -n "$GROUP_EXISTS" ]; then
            log "✓ Access control group already exists for this auth provider"
        else
            log "Creating access control group..."
            
            # Build the group JSON payload
            if command -v jq &>/dev/null; then
                GROUP_JSON=$(jq -n \
                    --arg authProviderId "$PROVIDER_ID" \
                    --arg key "$CERT_CN" \
                    --arg roleName "Prometheus Server" \
                    '{
                        props: {
                            authProviderId: $authProviderId,
                            key: $key
                        },
                        roleName: $roleName
                    }')
                
                # Create the group
                GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" -X POST \
                    "$ROX_CENTRAL_URL/v1/groups" \
                    -H "Authorization: Bearer $ROX_API_TOKEN" \
                    -H "Content-Type: application/json" \
                    --data-raw "$GROUP_JSON" 2>&1)
                
                HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)
                GROUP_BODY=$(echo "$GROUP_RESPONSE" | head -n -1)
                
                if [ "$HTTP_CODE" = "200" ] || echo "$GROUP_BODY" | grep -q '"props"'; then
                    log "✓ Access control group created successfully"
                    log "  Certificate CN: $CERT_CN"
                    log "  Role: Prometheus Server"
                    log "  Auth Provider: Monitoring"
                elif echo "$GROUP_BODY" | grep -qi "already exists"; then
                    log "✓ Access control group already exists"
                else
                    warning "Failed to create access control group (HTTP $HTTP_CODE)"
                    if [ -n "$GROUP_BODY" ]; then
                        log "Response: ${GROUP_BODY:0:200}"
                    fi
                    warning "You'll need to configure it manually (see below)"
                fi
            else
                warning "jq not found - cannot create access control group automatically"
                warning "You'll need to configure it manually (see below)"
            fi
        fi
    else
        warning "Auth provider 'Monitoring' not found"
        warning "You'll need to configure it manually (see below)"
    fi
fi

# Show manual instructions if automated setup may have failed
log ""
log "To verify or manually configure access control:"
log "  1. Go to: $ROX_CENTRAL_URL"
log "  2. Navigate to: Platform Configuration → Access Control → Access Control"
log "  3. Verify or create access rule:"
log "     - Auth Provider: Monitoring"
log "     - Role: Prometheus Server"
log "     - Subject/Key: $CERT_CN"

log ""

#================================================================
# Diagnostics
#================================================================
step "Running diagnostics"
log ""

# Check MonitoringStack
log "=== MonitoringStack Status ==="
$KUBE_CMD get monitoringstack -n "$NAMESPACE" 2>/dev/null || warning "No MonitoringStack found"

# Check Prometheus pods
log ""
log "=== Prometheus Pods ==="
$KUBE_CMD get pods -n "$NAMESPACE" 2>/dev/null | grep prometheus || warning "No Prometheus pods found yet (may take a few minutes)"

# Check secrets
log ""
log "=== Secrets ==="
$KUBE_CMD get secrets -n "$NAMESPACE" | grep -E "prometheus|tls" || warning "No monitoring secrets found"

# Test API authentication
log ""
log "=== Testing API Token Authentication ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ROX_API_TOKEN" -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
if [ "$HTTP_CODE" = "200" ]; then
    log "✓ API token authentication working (HTTP $HTTP_CODE)"
else
    warning "API token authentication returned HTTP $HTTP_CODE"
fi

# Test certificate authentication
log ""
log "=== Testing Certificate Authentication ==="
if [ -f "tls.crt" ] && [ -f "tls.key" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --cert tls.crt --key tls.key -k "$ROX_CENTRAL_URL/v1/auth/status" 2>&1)
    if [ "$HTTP_CODE" = "200" ]; then
        log "✓ Certificate authentication working (HTTP $HTTP_CODE)"
    else
        warning "Certificate authentication not configured yet (HTTP $HTTP_CODE)"
        warning "Complete Step 7 above to enable certificate authentication"
    fi
fi

log ""

#================================================================
# Summary
#================================================================
step "Setup Complete!"
echo "=========================================="
echo ""
echo "✓ Cluster Observability Operator installed"
echo "✓ MonitoringStack deployed"
echo "✓ ScrapeConfig applied"
echo "✓ Perses resources installed"
echo "✓ RHACS declarative configuration applied"
echo "✓ User-Certificate auth provider created"
echo ""
echo "⚠️  REQUIRED: Complete Step 7 (configure role for auth provider)"
echo ""
echo "Next steps:"
echo ""
echo "1. Configure the role for 'Monitoring' auth provider (see Step 7 above)"
echo ""
echo "2. Wait for Prometheus pods to start (check with):"
echo "   oc get pods -n $NAMESPACE | grep prometheus"
echo ""
echo "3. Access Prometheus UI:"
echo "   oc port-forward -n $NAMESPACE \$(oc get pods -n $NAMESPACE -o name | grep prometheus | head -1 | sed 's|pod/||') 9090:9090"
echo "   Open: http://localhost:9090"
echo ""
echo "4. Check Prometheus targets (in UI):"
echo "   Status → Targets → Look for 'stackrox' job"
echo ""
echo "5. Verify RHACS metrics are being scraped:"
echo "   curl -H \"Authorization: Bearer \$ROX_API_TOKEN\" -k \$ROX_CENTRAL_URL/metrics | head -20"
echo ""
echo "6. Run diagnostics:"
echo "   ./debug-monitoring.sh"
echo ""
echo "Environment variables saved to ~/.bashrc:"
echo "  - ROX_CENTRAL_URL"
echo "  - ROX_API_TOKEN"
echo "  - GRPC_ENFORCE_ALPN_ENABLED"
echo ""
log "Setup completed successfully!"
echo ""
