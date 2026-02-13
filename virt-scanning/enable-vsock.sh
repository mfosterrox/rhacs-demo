#!/bin/bash

# Script: enable-vsock.sh
# Description: Try multiple methods to enable VSOCK feature gate in OpenShift Virtualization

set -euo pipefail

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }

readonly CNV_NAMESPACE="openshift-cnv"

#================================================================
# Check if VSOCK is currently enabled
#================================================================
check_vsock_status() {
    print_step "Checking current VSOCK status..."
    
    local kubevirt_gates=$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n ${CNV_NAMESPACE} -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")
    
    if echo "${kubevirt_gates}" | grep -q "VSOCK"; then
        print_success "VSOCK is already enabled!"
        echo "Feature gates: ${kubevirt_gates}"
        return 0
    else
        print_warn "VSOCK is NOT enabled"
        echo "Current feature gates: ${kubevirt_gates}"
        return 1
    fi
}

#================================================================
# Method 1: Direct KubeVirt patch (will be overwritten by HCO)
#================================================================
method_1_direct_kubevirt() {
    print_step "Method 1: Direct KubeVirt resource patch"
    print_info "Note: This may be overwritten by HyperConverged Operator"
    
    local kubevirt_name="kubevirt-kubevirt-hyperconverged"
    
    print_info "Patching KubeVirt resource: ${kubevirt_name}"
    
    if oc patch kubevirt ${kubevirt_name} -n ${CNV_NAMESPACE} --type=json -p '[
      {
        "op": "add",
        "path": "/spec/configuration/developerConfiguration/featureGates/-",
        "value": "VSOCK"
      }
    ]' 2>/dev/null; then
        print_success "Patch applied successfully"
        return 0
    else
        print_error "Patch failed"
        return 1
    fi
}

#================================================================
# Method 2: HyperConverged with custom JSON annotation
#================================================================
method_2_hco_jsonpatch_annotation() {
    print_step "Method 2: HyperConverged with JSON patch annotation"
    
    print_info "Adding JSON patch annotation to HyperConverged"
    
    if oc annotate hyperconverged kubevirt-hyperconverged -n ${CNV_NAMESPACE} --overwrite \
        kubevirt.kubevirt.io/jsonpatch='[
          {
            "op":"add",
            "path":"/spec/configuration/developerConfiguration/featureGates/-",
            "value":"VSOCK"
          }
        ]' 2>/dev/null; then
        print_success "Annotation applied successfully"
        return 0
    else
        print_error "Annotation failed"
        return 1
    fi
}

#================================================================
# Method 3: Pause HCO reconciliation and patch KubeVirt
#================================================================
method_3_pause_hco() {
    print_step "Method 3: Pause HCO reconciliation and patch KubeVirt"
    print_warn "This temporarily disables HCO management"
    
    read -p "Continue with pausing HCO? (y/n): " answer
    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        print_info "Skipped"
        return 1
    fi
    
    print_info "Pausing HyperConverged reconciliation..."
    oc annotate hyperconverged kubevirt-hyperconverged -n ${CNV_NAMESPACE} --overwrite \
        hco.kubevirt.io/pauseReconciliation=true
    
    sleep 5
    
    print_info "Patching KubeVirt directly..."
    method_1_direct_kubevirt
    
    sleep 30
    
    print_info "Checking if VSOCK persisted..."
    if check_vsock_status; then
        print_success "VSOCK enabled successfully with paused HCO"
        print_warn "HCO reconciliation is PAUSED - unpause with:"
        print_warn "  oc annotate hyperconverged kubevirt-hyperconverged -n ${CNV_NAMESPACE} hco.kubevirt.io/pauseReconciliation-"
        return 0
    else
        print_error "VSOCK did not persist"
        print_info "Unpausing HCO..."
        oc annotate hyperconverged kubevirt-hyperconverged -n ${CNV_NAMESPACE} hco.kubevirt.io/pauseReconciliation-
        return 1
    fi
}

#================================================================
# Method 4: Try to enable via KubeVirt feature gates config
#================================================================
method_4_kubevirt_config() {
    print_step "Method 4: Patch KubeVirt with full feature gates array"
    
    print_info "Getting current feature gates..."
    local current_gates=$(oc get kubevirt kubevirt-kubevirt-hyperconverged -n ${CNV_NAMESPACE} -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null || echo "[]")
    
    # Add VSOCK to the array if not already present
    if echo "${current_gates}" | grep -q "VSOCK"; then
        print_info "VSOCK already in feature gates"
        return 0
    fi
    
    print_info "Current gates: ${current_gates}"
    print_info "Attempting to add VSOCK..."
    
    # Try to replace the entire array with VSOCK added
    local new_gates=$(echo "${current_gates}" | sed 's/\]/,"VSOCK"]/')
    
    print_info "New gates: ${new_gates}"
    
    if oc patch kubevirt kubevirt-kubevirt-hyperconverged -n ${CNV_NAMESPACE} --type=merge -p "{
      \"spec\": {
        \"configuration\": {
          \"developerConfiguration\": {
            \"featureGates\": ${new_gates}
          }
        }
      }
    }" 2>/dev/null; then
        print_success "Patch applied successfully"
        return 0
    else
        print_error "Patch failed"
        return 1
    fi
}

#================================================================
# Method 5: Check for Tech Preview environment variable
#================================================================
method_5_tech_preview_env() {
    print_step "Method 5: Enable Tech Preview features via HCO"
    
    print_info "Checking if Tech Preview can be enabled..."
    
    # Some versions support a tech preview flag
    if oc patch hyperconverged kubevirt-hyperconverged -n ${CNV_NAMESPACE} --type=merge -p '
{
  "metadata": {
    "annotations": {
      "deployTektonTaskResources": "true"
    }
  }
}' 2>/dev/null; then
        print_info "Applied Tech Preview annotation"
    fi
    
    # Try to set an environment variable on virt-api
    print_info "Attempting to set VSOCK env var on virt-api..."
    if oc set env deployment/virt-api -n ${CNV_NAMESPACE} FEATURE_GATES=VSOCK 2>/dev/null; then
        print_success "Environment variable set on virt-api"
        sleep 30
        return 0
    else
        print_error "Could not set environment variable"
        return 1
    fi
}

#================================================================
# Method 6: Manual ConfigMap creation
#================================================================
method_6_manual_configmap() {
    print_step "Method 6: Manually create kubevirt-config ConfigMap"
    print_warn "This is a workaround - may be overwritten by operators"
    
    read -p "Continue with manual ConfigMap creation? (y/n): " answer
    if [[ ! "${answer}" =~ ^[Yy] ]]; then
        print_info "Skipped"
        return 1
    fi
    
    print_info "Creating kubevirt-config ConfigMap with VSOCK..."
    
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kubevirt-config
  namespace: ${CNV_NAMESPACE}
data:
  feature-gates: "VSOCK,CPUManager,Snapshot,ExpandDisks,HostDevices,VMExport,KubevirtSeccompProfile,VMPersistentState,InstancetypeReferencePolicy,WithHostModelCPU,HypervStrictCheck,HotplugVolumes"
EOF
    
    if [ $? -eq 0 ]; then
        print_success "ConfigMap created"
        print_info "Restarting virt-api to pick up changes..."
        oc delete pod -n ${CNV_NAMESPACE} -l kubevirt.io=virt-api
        sleep 30
        return 0
    else
        print_error "ConfigMap creation failed"
        return 1
    fi
}

#================================================================
# Verify VSOCK is working
#================================================================
verify_vsock_enabled() {
    print_step "Verifying VSOCK is enabled and persisted..."
    
    sleep 10
    
    # Check KubeVirt resource
    if check_vsock_status; then
        print_success "✓ VSOCK is enabled in KubeVirt resource"
    else
        print_error "✗ VSOCK is NOT in KubeVirt resource"
        return 1
    fi
    
    # Check if kubevirt-config exists and has VSOCK
    if oc get configmap kubevirt-config -n ${CNV_NAMESPACE} >/dev/null 2>&1; then
        local config_gates=$(oc get configmap kubevirt-config -n ${CNV_NAMESPACE} -o jsonpath='{.data.feature-gates}' 2>/dev/null || echo "")
        if echo "${config_gates}" | grep -q "VSOCK"; then
            print_success "✓ VSOCK is in kubevirt-config ConfigMap"
        else
            print_warn "⚠ kubevirt-config exists but doesn't have VSOCK"
            echo "  Feature gates: ${config_gates}"
        fi
    else
        print_warn "⚠ kubevirt-config ConfigMap doesn't exist yet"
    fi
    
    # Try to create a test VM with VSOCK
    print_info "Testing VSOCK with a minimal VM spec..."
    
    cat <<EOF | oc apply --dry-run=server -f - 2>&1 | grep -i vsock || true
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vsock-test
  namespace: default
spec:
  running: false
  template:
    spec:
      domain:
        devices:
          autoattachVSOCK: true
        resources:
          requests:
            memory: 1Gi
EOF
    
    print_info "If you see 'VSOCK feature gate is not enabled', it's not working yet"
}

#================================================================
# Main execution
#================================================================
main() {
    print_info "=========================================="
    print_info "VSOCK Feature Gate Enablement"
    print_info "=========================================="
    echo ""
    
    # Check prerequisites
    if ! oc whoami &>/dev/null; then
        print_error "Not connected to OpenShift cluster"
        exit 1
    fi
    
    print_info "Connected to: $(oc whoami --show-server)"
    print_info "OpenShift Virtualization version:"
    oc get csv -n ${CNV_NAMESPACE} | grep kubevirt | head -1
    echo ""
    
    # Initial status check
    if check_vsock_status; then
        print_success "VSOCK is already enabled! No action needed."
        exit 0
    fi
    
    echo ""
    print_info "Will try multiple methods to enable VSOCK..."
    echo ""
    
    # Try each method in sequence
    local methods=(
        "method_1_direct_kubevirt"
        "method_2_hco_jsonpatch_annotation"
        "method_4_kubevirt_config"
        "method_5_tech_preview_env"
        "method_3_pause_hco"
        "method_6_manual_configmap"
    )
    
    for method in "${methods[@]}"; do
        echo ""
        echo "=========================================="
        
        if $method; then
            echo ""
            print_info "Waiting for changes to propagate (30s)..."
            sleep 30
            
            echo ""
            if verify_vsock_enabled; then
                print_success "=========================================="
                print_success "VSOCK ENABLED SUCCESSFULLY!"
                print_success "Method that worked: ${method}"
                print_success "=========================================="
                exit 0
            else
                print_warn "Method applied but VSOCK not yet active"
                print_info "Trying next method..."
            fi
        else
            print_warn "Method failed or skipped"
        fi
        
        sleep 5
    done
    
    echo ""
    print_error "=========================================="
    print_error "All methods exhausted"
    print_error "=========================================="
    echo ""
    print_info "VSOCK may not be supported in this OpenShift Virtualization version"
    print_info "or may require Red Hat support to enable Tech Preview features."
    echo ""
    print_info "Current CNV version:"
    oc get csv -n ${CNV_NAMESPACE} | grep kubevirt
    echo ""
    print_info "Next steps:"
    print_info "  1. Check Red Hat documentation for VSOCK support in your CNV version"
    print_info "  2. Contact Red Hat support for Tech Preview feature enablement"
    print_info "  3. Consider upgrading to a newer CNV version"
    
    exit 1
}

# Run main function
main "$@"
