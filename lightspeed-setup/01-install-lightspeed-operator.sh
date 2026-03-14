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

# Default values
LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"

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

# Function to discover the Lightspeed operator package name from OperatorHub
get_lightspeed_package_name() {
    # Try known package names first
    local known_names=("red-hat-openshift-lightspeed-operator" "lightspeed-operator" "openshift-lightspeed-operator")
    for pkg in "${known_names[@]}"; do
        if oc get packagemanifest "${pkg}" -n openshift-marketplace &>/dev/null; then
            echo "${pkg}"
            return 0
        fi
    done
    # Fallback: search packagemanifests for lightspeed
    oc get packagemanifest -n openshift-marketplace -o json 2>/dev/null | \
        jq -r '.items[] | select(.metadata.name | test("lightspeed"; "i")) | .metadata.name' 2>/dev/null | head -1
}

# Function to check if Lightspeed operator is installed
is_lightspeed_operator_installed() {
    # Check for subscription in openshift-lightspeed or openshift-operators
    if oc get subscription -n "${LIGHTSPEED_NAMESPACE}" 2>/dev/null | grep -q lightspeed; then
        return 0
    fi
    if oc get subscription -n openshift-operators 2>/dev/null | grep -q lightspeed; then
        return 0
    fi
    # Check for OLSConfig CR (indicates operator is managing the service)
    if oc get olsconfig -A 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

# Function to install OpenShift Lightspeed Operator
install_lightspeed_operator() {
    print_step "Installing OpenShift Lightspeed Operator..."

    # Discover package name
    print_info "Discovering OpenShift Lightspeed operator in OperatorHub..."
    local package_name
    package_name=$(get_lightspeed_package_name)
    if [ -z "${package_name}" ]; then
        print_error "OpenShift Lightspeed operator not found in OperatorHub"
        print_error ""
        print_error "Possible causes:"
        print_error "  - OpenShift 4.15+ required (check: oc version)"
        print_error "  - Operator only available on x86_64 architecture"
        print_error "  - red-hat-operators catalog not available"
        print_error ""
        print_error "Manual installation: OpenShift Console → Operators → OperatorHub → search 'Lightspeed'"
        return 1
    fi
    print_info "Found operator package: ${package_name}"

    # Create namespace
    print_info "Creating namespace ${LIGHTSPEED_NAMESPACE}..."
    oc create ns "${LIGHTSPEED_NAMESPACE}" --dry-run=client -o yaml | oc apply -f - || {
        print_error "Failed to create namespace"
        return 1
    }
    print_info "✓ Namespace ready"

    # Determine channel
    print_info "Determining operator channel..."
    local channel="stable"
    if oc get packagemanifest "${package_name}" -n openshift-marketplace &>/dev/null; then
        local available_channels
        available_channels=$(oc get packagemanifest "${package_name}" -n openshift-marketplace -o jsonpath='{.status.channels[*].name}' 2>/dev/null || echo "")
        if echo "${available_channels}" | grep -q "stable"; then
            channel="stable"
        elif [ -n "${available_channels}" ]; then
            channel=$(echo "${available_channels}" | awk '{print $1}')
        fi
    fi
    print_info "Using channel: ${channel}"

    # Create OperatorGroup (target openshift-lightspeed only - operator does not support AllNamespaces)
    print_info "Creating OperatorGroup..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: lightspeed-operator-group
  namespace: ${LIGHTSPEED_NAMESPACE}
spec:
  targetNamespaces:
    - ${LIGHTSPEED_NAMESPACE}
EOF
    then
        print_error "Failed to create OperatorGroup"
        return 1
    fi
    print_info "✓ OperatorGroup created"

    # Create Subscription
    print_info "Creating Subscription..."
    if ! cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lightspeed-operator
  namespace: ${LIGHTSPEED_NAMESPACE}
spec:
  channel: ${channel}
  installPlanApproval: Automatic
  name: ${package_name}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    then
        print_error "Failed to create Subscription"
        return 1
    fi
    print_info "✓ Subscription created"

    # Wait for CSV to be created
    print_info "Waiting for CSV to be created (max 120s)..."
    local wait_count=0
    local max_wait=120
    local csv_created=false

    while [ ${wait_count} -lt ${max_wait} ]; do
        if oc get csv -n "${LIGHTSPEED_NAMESPACE}" 2>/dev/null | grep -q lightspeed; then
            csv_created=true
            break
        fi
        sleep 2
        wait_count=$((wait_count + 2))
    done

    if [ "${csv_created}" = false ]; then
        print_error "CSV not created after ${max_wait} seconds"
        print_error "Check: oc get subscription -n ${LIGHTSPEED_NAMESPACE}"
        return 1
    fi
    print_info "✓ CSV created"

    # Get CSV name and wait for it to be ready
    local csv_name
    csv_name=$(oc get csv -n "${LIGHTSPEED_NAMESPACE}" -o name 2>/dev/null | grep -i lightspeed | head -1 | cut -d'/' -f2)
    if [ -z "${csv_name}" ]; then
        print_error "Could not determine CSV name"
        return 1
    fi

    print_info "Waiting for CSV ${csv_name} to reach Succeeded phase..."
    oc wait --for=jsonpath='{.status.phase}'=Succeeded csv/"${csv_name}" -n "${LIGHTSPEED_NAMESPACE}" --timeout=300s || {
        print_error "CSV did not reach Succeeded phase"
        return 1
    }
    print_info "✓ Operator installed successfully"

    return 0
}

# Main function
main() {
    print_info "=========================================="
    print_info "OpenShift Lightspeed Operator Installation"
    print_info "=========================================="
    print_info ""

    # Verify cluster connectivity
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift cluster. Run: oc login"
        exit 1
    fi

    # Check if already installed
    print_step "Checking OpenShift Lightspeed installation..."
    if is_lightspeed_operator_installed; then
        print_info "✓ OpenShift Lightspeed Operator is already installed"
        print_info ""
        print_info "To configure an LLM provider, create an OLSConfig resource."
        print_info "See: lightspeed-setup/README.md"
        return 0
    fi

    # Install operator
    if ! install_lightspeed_operator; then
        print_error "Failed to install OpenShift Lightspeed Operator"
        exit 1
    fi

    print_info ""
    print_info "=========================================="
    print_info "OpenShift Lightspeed Operator Installed"
    print_info "=========================================="
    print_info ""
    print_info "Next steps:"
    print_info "  1. Create OLSConfig with your LLM provider credentials"
    print_info "  2. Console integration is enabled automatically by the operator"
    print_info "  3. Access Lightspeed from the OpenShift console (YAML editor 'Ask OpenShift Lightspeed' button)"
    print_info ""
}

main "$@"
