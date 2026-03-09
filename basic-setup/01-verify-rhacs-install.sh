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
# Default target version when not set (script will upgrade to this version)
RHACS_VERSION="${RHACS_VERSION:-4.10}"

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
    local version=""
    
    # Try to get version from central resource status
    version=$(oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Release")].message}' 2>/dev/null | grep -oP 'version \K[0-9.]+')
    
    # If not found, try from Central spec.central.image
    if [ -z "${version}" ]; then
        version=$(oc get central -n "${RHACS_NAMESPACE}" -o jsonpath='{.items[0].spec.central.image}' 2>/dev/null | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+')
    fi
    
    # If not found, try from deployment image tag (looking for semantic version pattern)
    if [ -z "${version}" ]; then
        version=$(oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':\K[0-9]+\.[0-9]+\.[0-9]+')
    fi
    
    # If still not found and operator CSV exists, use operator version as installed version
    if [ -z "${version}" ]; then
        version=$(get_latest_available_version)
    fi
    
    echo "${version}"
}

# Function to get current image tag from deployment
get_current_image_tag() {
    oc get deployment central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | grep -oP ':[^:]+$' | sed 's/^://'
}

# Function to get latest available RHACS version from operator
get_latest_available_version() {
    local version=""
    
    # Try to get version from CSV (most reliable)
    version=$(oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.metadata.name=~"rhacs-operator.*")].spec.version}' 2>/dev/null | head -1)
    
    # If not found, try from CSV name
    if [ -z "${version}" ]; then
        version=$(oc get csv -n "${RHACS_OPERATOR_NAMESPACE}" -o name 2>/dev/null | grep rhacs-operator | head -1 | grep -oP 'rhacs-operator\.v\K[0-9.]+')
    fi
    
    # If still not found, try from subscription
    if [ -z "${version}" ]; then
        version=$(oc get subscription -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].status.installedCSV}' 2>/dev/null | grep -oP 'rhacs-operator\.v\K[0-9.]+')
    fi
    
    echo "${version}"
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
        
        # Verify each SecuredCluster by checking its pods
        while IFS= read -r sc; do
            if [ -n "${sc}" ]; then
                local sc_namespace=$(echo "${sc}" | awk '{print $1}')
                local sc_name=$(echo "${sc}" | awk '{print $2}')
                
                # Check if sensor, admission-control, and collector pods are running
                local sensor_ready=$(oc get deployment sensor -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
                local admission_ready=$(oc get deployment admission-control -n "${sc_namespace}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
                local collector_count=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
                local collector_desired=$(oc get daemonset collector -n "${sc_namespace}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
                
                if [ "${sensor_ready}" = "True" ] && [ "${admission_ready}" = "True" ] && [ "${collector_count}" -eq "${collector_desired}" ] && [ "${collector_count}" -gt 0 ]; then
                    print_info "  ✓ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' is ready (sensor, admission-control, and ${collector_count}/${collector_desired} collectors running)"
                else
                    print_warn "  ⚠ SecuredCluster '${sc_name}' in namespace '${sc_namespace}' components: sensor=${sensor_ready}, admission-control=${admission_ready}, collectors=${collector_count}/${collector_desired}"
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

# Ensure operator subscription is on a channel that provides the target version (e.g. 4.10 -> stable-4.10).
# Call this first so the operator can install the target version; otherwise it may stay on 4.9.
ensure_subscription_channel_for_version() {
    local target_version=$1
    local desired_channel
    desired_channel=$(get_channel_for_version "${target_version}")
    local sub_name
    sub_name=$(oc get subscription -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${sub_name}" ]; then
        return 0
    fi
    local current_channel
    current_channel=$(oc get subscription "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
    if [ "${current_channel}" = "${desired_channel}" ]; then
        print_info "Operator subscription already on channel: ${desired_channel}"
        return 0
    fi
    print_step "Setting operator subscription to channel ${desired_channel} (for RHACS ${target_version})..."
    if ! oc patch subscription "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${desired_channel}\"}]" 2>/dev/null; then
        print_warn "Could not set subscription channel to ${desired_channel}"
        return 1
    fi
    print_info "Waiting for operator to reconcile to ${desired_channel} (60s)..."
    sleep 60
    return 0
}

# Function to check and update RHACS version
# Uses RHACS_VERSION as target (default 4.10). Only reports "up to date" when installed equals target.
# Ensures subscription is on the correct channel (e.g. stable-4.10) first so 4.10 is available.
check_and_update_version() {
    print_step "Checking RHACS version..."
    
    # Single target: user-set or default 4.10 (so we always try to reach 4.10 when not set)
    local target_version="${RHACS_VERSION:-4.10}"
    print_info "Target version: ${target_version}"
    
    # First: ensure subscription is on a channel that provides the target (e.g. 4.9 -> stable-4.9, 4.10 -> stable-4.10).
    # Otherwise the operator only has 4.9 and we can't upgrade to 4.10.
    ensure_subscription_channel_for_version "${target_version}" || true
    
    # Get current installed version (after possible channel switch)
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
    
    # Latest from operator (after channel switch; informational)
    local latest_version=$(get_latest_available_version)
    if [ -n "${latest_version}" ]; then
        print_info "Latest available version from operator: ${latest_version}"
    fi
    
    # Already at target
    if [ "${current_image_tag}" = "${target_version}" ]; then
        print_info "✓ RHACS deployment is already using image tag ${target_version}"
        return 0
    fi
    if [ "${installed_version}" = "${target_version}" ] && [ "${installed_version}" != "unknown" ]; then
        print_info "✓ RHACS is already at target version ${target_version}"
        return 0
    fi
    
    # Downgrade check
    if [ "${installed_version}" != "unknown" ] && [ "${target_version}" != "unknown" ]; then
        if [ "$(printf '%s\n' "${target_version}" "${installed_version}" | sort -V | head -n1)" = "${target_version}" ] && \
           [ "${target_version}" != "${installed_version}" ]; then
            print_warn "⚠️  Warning: Target version ${target_version} is older than installed version ${installed_version}"
            print_warn "This would be a DOWNGRADE!"
            if [ "${RHACS_FORCE_DOWNGRADE:-false}" != "true" ]; then
                print_error "Refusing to downgrade. To force: export RHACS_FORCE_DOWNGRADE=true"
                print_info "Keeping current version: ${installed_version}"
                return 0
            fi
            print_warn "RHACS_FORCE_DOWNGRADE=true - proceeding with downgrade..."
        fi
    fi
    
    # Proceed with update to target
    print_info "Current version ${installed_version} -> Target version ${target_version}"
    update_rhacs_version "${target_version}"
}

# Map target minor version to operator channel (e.g. 4.10 -> stable-4.10)
# So the operator can install that version from the catalog.
get_channel_for_version() {
    local ver=$1
    local major_minor=""
    if [[ "${ver}" =~ ^([0-9]+\.[0-9]+) ]]; then
        major_minor="${BASH_REMATCH[1]}"
        echo "stable-${major_minor}"
    else
        echo "stable"
    fi
}

# Function to update RHACS version
update_rhacs_version() {
    local target_version=$1
    
    print_info "Updating RHACS to version ${target_version}..."
    
    # Discover Central CR name (operator may use "central" or "stackrox-central-services")
    local central_cr_name
    central_cr_name=$(get_central_cr_name)
    
    if [ -n "${central_cr_name}" ]; then
        print_info "Updating Central resource (${central_cr_name})..."
        
        # Ensure operator subscription is on a channel that can provide target version,
        # so the operator doesn't revert our image tag (e.g. 4.10 needs channel stable-4.10 or stable).
        local desired_channel
        desired_channel=$(get_channel_for_version "${target_version}")
        local sub_name
        sub_name=$(oc get subscription -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.items[?(@.spec.name=="rhacs-operator")].metadata.name}' 2>/dev/null || echo "")
        if [ -n "${sub_name}" ]; then
            local current_channel
            current_channel=$(oc get subscription "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
            if [ "${current_channel}" != "${desired_channel}" ]; then
                print_info "Switching operator channel: ${current_channel:-unknown} -> ${desired_channel} (for version ${target_version})"
                if oc patch subscription "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${desired_channel}\"}]" 2>/dev/null; then
                    print_info "Waiting for operator to reconcile (30s)..."
                    sleep 30
                else
                    print_warn "Could not set channel to ${desired_channel}; continuing (operator may revert image if catalog lacks ${target_version})"
                fi
            fi
        fi
        
        # Get current Central spec
        local current_image
        current_image=$(oc get central "${central_cr_name}" -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.image}' 2>/dev/null || echo "")
        local current_image
        current_image=$(oc get central central -n "${RHACS_NAMESPACE}" -o jsonpath='{.spec.central.image}' 2>/dev/null || echo "")
        
        if [ -n "${current_image}" ]; then
            # Update the image tag
            local image_repo
            image_repo=$(echo "${current_image}" | sed 's/:.*//')
            oc patch central "${central_cr_name}" -n "${RHACS_NAMESPACE}" --type=json -p="[
            local image_repo
            image_repo=$(echo "${current_image}" | sed 's/:.*//')
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
            # No image in spec: try updating via operator channel only (already set above)
            print_info "Central has no custom image; operator should deploy ${target_version} from channel ${desired_channel}"
        fi
        
        print_info "Waiting for update to complete..."
        oc wait --for=condition=ready --timeout=600s "central/${central_cr_name}" -n "${RHACS_NAMESPACE}" || {
            print_warn "Update may still be in progress. Please check manually."
        oc wait --for=condition=ready --timeout=600s central/central -n "${RHACS_NAMESPACE}" 2>/dev/null || {
            print_warn "Update may still be in progress. Check: oc get central -n ${RHACS_NAMESPACE} && oc get pods -n ${RHACS_NAMESPACE}"
        }
        
        print_info "✓ RHACS update initiated"
    else
        # For non-operator installations, try updating the deployment directly
        print_info "Central resource not found, attempting to update deployment directly..."
        oc set image deployment/central -n "${RHACS_NAMESPACE}" central="quay.io/rhacs-eng/central:${target_version}" || {
            print_error "Failed to update deployment image"
            return 1
        fi
        local current_channel
        current_channel=$(oc get subscription "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" -o jsonpath='{.spec.channel}' 2>/dev/null || echo "")
        if [ "${current_channel}" != "${desired_channel}" ]; then
            print_info "Switching operator channel: ${current_channel:-unknown} -> ${desired_channel} (for version ${target_version})"
            if ! oc patch subscription "${sub_name}" -n "${RHACS_OPERATOR_NAMESPACE}" --type=json -p="[{\"op\":\"replace\",\"path\":\"/spec/channel\",\"value\":\"${desired_channel}\"}]" 2>/dev/null; then
                print_error "Failed to update subscription channel to ${desired_channel}"
                return 1
            fi
            print_info "Waiting for operator to reconcile (45s)..."
            sleep 45
        else
            print_info "Subscription already on channel ${desired_channel}; operator should rollout ${target_version}."
        fi
        print_info "Waiting for deployment rollout to complete..."
        oc rollout status deployment/central -n "${RHACS_NAMESPACE}" --timeout=600s || {
            print_warn "Rollout may still be in progress. Check: oc get pods -n ${RHACS_NAMESPACE} && oc get subscription -n ${RHACS_OPERATOR_NAMESPACE}"
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

# Function to ensure RHACS OpenShift Console plugin is enabled
# On the Install Operator page, the Console plugin option should be set to Enable.
# This function ensures the plugin is enabled in the Console operator config (idempotent).
ensure_rhacs_console_plugin_enabled() {
    print_step "Ensuring RHACS Console plugin is enabled..."

    if ! oc get consoles.operator.openshift.io cluster &>/dev/null; then
        print_warn "Console operator resource not found; skipping Console plugin enablement"
        return 0
    fi

    # Find the RHACS ConsolePlugin name (operator may create "acs" or similar)
    local plugin_name=""
    if command -v jq &>/dev/null && oc get consoleplugins -o json &>/dev/null; then
        plugin_name=$(oc get consoleplugins -o json 2>/dev/null | jq -r '
            .items[] | select(
                .metadata.name == "acs" or
                .metadata.name == "rhacs" or
                (.spec.displayName != null and (
                    (.spec.displayName | ascii_downcase | test("advanced cluster security")) or
                    (.spec.displayName | ascii_downcase | test("rhacs"))
                ))
            ) | .metadata.name
        ' 2>/dev/null | head -1)
    fi

    if [ -z "${plugin_name}" ]; then
        # Fallback: try common name used by RHACS operator
        if oc get consoleplugin acs &>/dev/null; then
            plugin_name="acs"
        fi
    fi

    if [ -z "${plugin_name}" ]; then
        print_warn "RHACS ConsolePlugin not found (operator may not register a console plugin in this version); skipping"
        return 0
    fi

    local current_plugins
    current_plugins=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
    if echo "${current_plugins}" | tr ' ' '\n' | grep -q "^${plugin_name}$"; then
        print_info "✓ RHACS Console plugin '${plugin_name}' is already enabled"
        return 0
    fi

    # Build new plugins array: existing + RHACS plugin
    local new_plugins_json
    local current_json
    current_json=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if [ -z "${current_json}" ] || [ "${current_json}" = "[]" ]; then
        new_plugins_json="[\"${plugin_name}\"]"
    elif command -v jq &>/dev/null; then
        new_plugins_json=$(echo "${current_json}" | jq --arg p "${plugin_name}" '. + [$p] | unique' -c 2>/dev/null || echo "[\"${plugin_name}\"]")
    else
        # Without jq: append to existing JSON array (e.g. ["a","b"] -> ["a","b","acs"])
        new_plugins_json="${current_json%]},\"${plugin_name}\"]"
    fi

    if oc patch consoles.operator.openshift.io cluster --type=merge -p "{\"spec\":{\"plugins\":${new_plugins_json}}}" 2>/dev/null; then
        print_info "✓ RHACS Console plugin '${plugin_name}' enabled in OpenShift Console"
    else
        print_warn "Could not patch Console to enable plugin '${plugin_name}' (may require cluster-admin)"
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
    
    # Check and update version (e.g. to 4.10) before enabling Console plugin
    check_and_update_version
    
    print_info ""
    
    # Ensure Console plugin is enabled after version update (Install Operator page: Console plugin = Enable)
    ensure_rhacs_console_plugin_enabled
    
    print_info ""
    print_info "================================="
    print_info "✓ RHACS verification complete!"
    print_info "================================="
}

# Run main function
main "$@"
