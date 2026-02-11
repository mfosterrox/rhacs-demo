#!/bin/bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Default values if not set
RHACS_NAMESPACE="${RHACS_NAMESPACE:-stackrox}"
RHACS_ROUTE_NAME="${RHACS_ROUTE_NAME:-central}"
RHACS_OPERATOR_NAMESPACE="${RHACS_OPERATOR_NAMESPACE:-rhacs-operator}"

# Function to check if a resource exists
check_resource_exists() {
    local resource_type=$1
    local resource_name=$2
    local namespace=${3:-}
    
    if [ -n "${namespace}" ]; then
        oc get "${resource_type}" "${resource_name}" -n "${namespace}" &>/dev/null
    else
        oc get "${resource_type}" "${resource_name}" &>/dev/null
    fi
}

# Function to get RHACS operator version
get_operator_version() {
    oc get subscription -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].status.currentCSV}' 2>/dev/null | grep -oP 'rhacs-operator\.v\K[0-9.]+' || echo ""
}

# Function to get installed RHACS version
get_installed_version() {
    # Try to get version from central resource status
    local version=$(oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Release")].message}' 2>/dev/null | grep -oP 'version \K[0-9.]+')
    
    # If not found, try from deployment image tag (looking for semantic version pattern)
    if [ -z "${version}" ]; then
        version=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+')
    fi
    
    echo "${version}"
}

# Function to get current image tag from deployment
get_current_image_tag() {
    oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':[^:]+$' | sed 's/^://'
}

# Function to get latest available RHACS version from operator
get_latest_available_version() {
    oc get subscription -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].status.installedCSV}' 2>/dev/null | grep -oP 'rhacs-operator\.v\K[0-9.]+' || \
    oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.metadata.name=~"rhacs-operator.*")].spec.version}' 2>/dev/null | head -1 || echo ""
}

# Function to verify RHACS installation
verify_rhacs_installation() {
    print_step "Verifying RHACS installation..."
    
    # Check if namespace exists
    if ! check_resource_exists "namespace" "${RHACS_NAMESPACE}"; then
        print_error "RHACS namespace '${RHACS_NAMESPACE}' does not exist"
        return 1
    fi
    print_info "✓ Namespace '${RHACS_NAMESPACE}' exists"
    
    # Check for Central deployment
    if ! check_resource_exists "deployment" "central" "${RHACS_NAMESPACE}"; then
        print_error "Central deployment not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    print_info "✓ Central deployment exists"
    
    # Check if Central is ready
    local central_ready=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
    if [ "${central_ready}" != "True" ]; then
        print_warn "Central deployment is not yet ready"
        print_info "Waiting for Central to become ready..."
        oc wait --for=condition=available --timeout=300s deployment/central -n "${RHACS_NAMESPACE}" || {
            print_error "Central deployment did not become ready within timeout"
            return 1
        }
    fi
    print_info "✓ Central deployment is ready"
    
    # Check for SecuredCluster resources
    print_step "Checking SecuredCluster services..."
    local secured_clusters=$(oc get securedcluster -A -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
    if [ "${secured_clusters}" -eq 0 ]; then
        print_warn "No SecuredCluster resources found"
    else
        print_info "✓ Found ${secured_clusters} SecuredCluster resource(s)"
        
        # Verify each SecuredCluster is healthy
        while IFS= read -r sc; do
            if [ -n "${sc}" ]; then
                local sc_namespace=$(echo "${sc}" | awk '{print $1}')
                local sc_name=$(echo "${sc}" | awk '{print $2}')
                local sc_status=$(oc get securedcluster "${sc_name}" -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
                
                if [ "${sc_status}" = "True" ]; then
                    print_info "  ✓ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' is ready"
                else
                    print_warn "  ⚠ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' is not ready (status: ${sc_status})"
                fi
            fi
        done < <(oc get securedcluster -A --no-headers 2>/dev/null || true)
    fi
    
    return 0
}

# Function to verify route encryption
verify_route_encryption() {
    print_step "Verifying RHACS route encryption..."
    
    # Check if route exists
    if ! check_resource_exists "route" "${RHACS_ROUTE_NAME}" "${RHACS_NAMESPACE}"; then
        print_error "Route '${RHACS_ROUTE_NAME}' not found in namespace '${RHACS_NAMESPACE}'"
        return 1
    fi
    print_info "✓ Route '${RHACS_ROUTE_NAME}' exists"
    
    # Check if route has TLS termination
    local tls_term=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.tls.termination}' 2>/dev/null || echo "")
    
    if [ -z "${tls_term}" ] || [ "${tls_term}" = "None" ]; then
        print_error "Route '${RHACS_ROUTE_NAME}' does not have TLS termination configured"
        print_info "Updating route to use edge TLS termination..."
        
        # Patch the route to add TLS termination
        oc patch route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" --type=json -p='[
            {
                "op": "add",
                "path": "/spec/tls",
                "value": {
                    "termination": "edge",
                    "insecureEdgeTerminationPolicy": "Redirect"
                }
            }
        ]' || {
            print_error "Failed to update route TLS configuration"
            return 1
        }
        
        print_info "✓ Route updated with TLS termination"
    else
        print_info "✓ Route has TLS termination: ${tls_term}"
    fi
    
    # Verify route is accessible via HTTPS
    local route_url=$(oc get route "${RHACS_ROUTE_NAME}" -n "${RHACS_NAMESPACE}" -o jsonpath='https://{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${route_url}" ]; then
        print_info "Route URL: ${route_url}"
        
        # Check if route responds (with a timeout)
        if curl -k -s -o /dev/null -w "%{http_code}" --max-time 10 "${route_url}" | grep -q "200\|302\|401\|403"; then
            print_info "✓ Route is accessible via HTTPS"
        else
            print_warn "Route may not be fully accessible yet (this is normal if RHACS is still initializing)"
        fi
    fi
    
    return 0
}

# Function to check and update RHACS version
check_and_update_version() {
    print_step "Checking RHACS version..."
    
    # Get current installed version
    local installed_version=$(get_installed_version)
    local current_image_tag=$(get_current_image_tag)
    
    if [ -z "${installed_version}" ]; then
        print_warn "Could not determine installed RHACS version from semantic version pattern"
        if [ -n "${current_image_tag}" ]; then
            print_info "Current image tag: ${current_image_tag}"
        fi
        installed_version="unknown"
    else
        print_info "Installed RHACS version: ${installed_version}"
    fi
    
    # Get latest available version from operator
    local latest_version=$(get_latest_available_version)
    if [ -z "${latest_version}" ]; then
        print_warn "Could not determine latest available RHACS version from operator"
        latest_version="unknown"
    else
        print_info "Latest available version from operator: ${latest_version}"
    fi
    
    # If RHACS_VERSION is set, use that as target
    if [ -n "${RHACS_VERSION:-}" ]; then
        print_info "Target version specified: ${RHACS_VERSION}"
        
        # Check if the current image tag already matches the target version
        if [ "${current_image_tag}" = "${RHACS_VERSION}" ]; then
            print_info "✓ RHACS deployment is already using image tag ${RHACS_VERSION}"
            return 0
        fi
        
        # Check if installed version matches (for operator-managed installations)
        if [ "${installed_version}" = "${RHACS_VERSION}" ] && [ "${installed_version}" != "unknown" ]; then
            print_info "✓ RHACS is already at target version ${RHACS_VERSION}"
            return 0
        fi
        
        # Version doesn't match, proceed with update
        print_info "Current version/tag does not match target. Proceeding with update..."
        update_rhacs_version "${RHACS_VERSION}"
        
    elif [ "${installed_version}" != "${latest_version}" ] && [ "${latest_version}" != "unknown" ] && [ "${installed_version}" != "unknown" ]; then
        print_info "Update available: ${installed_version} -> ${latest_version}"
        print_info "Updating RHACS to latest version..."
        update_rhacs_version "${latest_version}"
    else
        print_info "✓ RHACS is up to date"
    fi
}

# Function to update RHACS version
update_rhacs_version() {
    local target_version=$1
    
    print_info "Updating RHACS to version ${target_version}..."
    
    # Check if Central resource exists (for operator-managed installation)
    if check_resource_exists "central" "central" "${RHACS_NAMESPACE}"; then
        print_info "Updating Central resource..."
        
        # Get current Central spec
        local current_image=$(oc get central central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.image}' 2>/dev/null || echo "")
        
        if [ -n "${current_image}" ]; then
            # Update the image tag
            local image_repo=$(echo "${current_image}" | sed 's/:.*//')
            oc patch central central -n "${RHACS_NAMESPACE}" --type=json -p="[
                {
                    \"op\": \"replace\",
                    \"path\": \"/spec/central/image\",
                    \"value\": \"${image_repo}:${target_version}\"
                }
            ]" || {
                print_error "Failed to update Central image"
                return 1
            }
        else
            # Try updating via operator channel
            print_info "Attempting to update via operator subscription..."
            oc patch subscription -n "${RHACS_OPERATOR_NAMESPACE}" -l operators.coreos.com/rhacs-operator.rhacs-operator= --type=json -p="[
                {
                    \"op\": \"replace\",
                    \"path\": \"/spec/channel\",
                    \"value\": \"stable\"
                }
            ]" 2>/dev/null || print_warn "Could not update via subscription"
        fi
        
        print_info "Waiting for update to complete..."
        oc wait --for=condition=ready --timeout=600s central/central -n "${RHACS_NAMESPACE}" || {
            print_warn "Update may still be in progress. Please check manually."
        }
        
        print_info "✓ RHACS update initiated"
    else
        # For non-operator installations, try updating the deployment directly
        print_info "Central resource not found, attempting to update deployment directly..."
        oc set image deployment/central -n "${RHACS_NAMESPACE}" central="quay.io/rhacs-eng/central:${target_version}" || {
            print_error "Failed to update deployment image"
            return 1
        }
        
        print_info "Waiting for rollout to complete..."
        oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=600s || {
            print_warn "Rollout may still be in progress. Please check manually."
        }
        
        print_info "✓ RHACS update initiated"
    fi
    
    # Verify new version
    sleep 10
    local new_version=$(get_installed_version)
    if [ -n "${new_version}" ] && [ "${new_version}" != "unknown" ]; then
        print_info "Current version after update: ${new_version}"
    fi
}

# Main function
main() {
    print_info "RHACS Installation Verification"
    print_info "================================="
    
    # Verify RHACS installation
    if ! verify_rhacs_installation; then
        print_error "RHACS installation verification failed"
        exit 1
    fi
    
    print_info ""
    
    # Verify route encryption
    if ! verify_route_encryption; then
        print_error "Route encryption verification failed"
        exit 1
    fi
    
    print_info ""
    
    # Check and update version
    check_and_update_version
    
    print_info ""
    print_info "================================="
    print_info "✓ RHACS verification complete!"
    print_info "================================="
}

# Run main function
main "$@"
