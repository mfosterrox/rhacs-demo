#!/bin/bash

set -uo pipefail
# Note: 'e' disabled - we handle failures gracefully; plugin may not exist until OLSConfig is created

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

# Function to find the OpenShift Lightspeed ConsolePlugin name
get_lightspeed_console_plugin_name() {
    # Try known plugin names first (operator may register as "lightspeed" or "ols")
    local known_names=("lightspeed" "ols" "openshift-lightspeed")
    for name in "${known_names[@]}"; do
        if oc get consoleplugin "${name}" &>/dev/null; then
            echo "${name}"
            return 0
        fi
    done
    # Fallback: search by displayName
    if command -v jq &>/dev/null; then
        oc get consoleplugins -o json 2>/dev/null | jq -r '
            .items[]? | select(
                (.metadata.name | test("lightspeed|ols"; "i")) or
                (.spec.displayName != null and (.spec.displayName | test("lightspeed|ols"; "i")))
            ) | .metadata.name
        ' 2>/dev/null | head -1
    fi
    return 0
}

# Function to ensure OpenShift Lightspeed Console plugin is enabled
ensure_lightspeed_console_plugin_enabled() {
    print_step "Ensuring OpenShift Lightspeed Console integration is enabled..."

    if ! oc get consoles.operator.openshift.io cluster &>/dev/null; then
        print_warn "Console operator resource not found; skipping plugin enablement"
        return 0
    fi

    local plugin_name
    plugin_name=$(get_lightspeed_console_plugin_name)
    if [ -z "${plugin_name}" ]; then
        print_warn "OpenShift Lightspeed ConsolePlugin not found"
        print_info ""
        print_info "The ConsolePlugin is created only AFTER you create an OLSConfig with your LLM provider."
        print_info "Without OLSConfig, the 'Ask OpenShift Lightspeed' button will not appear."
        print_info ""
        print_info "To fix:"
        print_info "  1. Create a credentials secret and OLSConfig (see lightspeed-setup/README.md)"
        print_info "  2. Wait 2-3 minutes for the operator to create the ConsolePlugin"
        print_info "  3. Re-run: ./lightspeed-setup/02-verify-console-integration.sh"
        print_info ""
        if ! oc get olsconfig cluster -n openshift-lightspeed &>/dev/null; then
            print_info "Current status: OLSConfig 'cluster' not found in openshift-lightspeed"
        else
            print_info "Current status: OLSConfig exists - plugin may still be deploying (wait and re-run)"
        fi
        return 0
    fi

    local current_plugins
    current_plugins=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}' 2>/dev/null || echo "")
    if echo "${current_plugins}" | tr ' ' '\n' | grep -q "^${plugin_name}$"; then
        print_info "✓ OpenShift Lightspeed Console plugin '${plugin_name}' is already enabled"
        return 0
    fi

    # Build new plugins array: existing + Lightspeed plugin
    local new_plugins_json
    local current_json
    current_json=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "[]")
    if [ -z "${current_json}" ] || [ "${current_json}" = "[]" ]; then
        new_plugins_json="[\"${plugin_name}\"]"
    elif command -v jq &>/dev/null; then
        new_plugins_json=$(echo "${current_json}" | jq --arg p "${plugin_name}" '. + [$p] | unique' -c 2>/dev/null || echo "[\"${plugin_name}\"]")
    else
        new_plugins_json="${current_json%]},\"${plugin_name}\"]"
    fi

    if oc patch consoles.operator.openshift.io cluster --type=merge -p '{"spec":{"plugins":'"${new_plugins_json}"'}}' 2>/dev/null; then
        print_info "✓ OpenShift Lightspeed Console plugin '${plugin_name}' enabled in OpenShift Console"
    else
        print_warn "Could not patch Console to enable plugin '${plugin_name}'; may require cluster-admin"
    fi
}

# Main function
main() {
    print_info "=========================================="
    print_info "OpenShift Lightspeed Console Integration"
    print_info "=========================================="
    print_info ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift cluster. Run: oc login"
        exit 1
    fi

    ensure_lightspeed_console_plugin_enabled

    print_info ""
    print_info "Console integration provides:"
    print_info "  - 'Ask OpenShift Lightspeed' button in the YAML Editor"
    print_info "  - AI-powered assistance for OpenShift resources"
    print_info ""
    print_info "Note: Create an OLSConfig with LLM provider credentials to use Lightspeed."
    print_info ""
}

main "$@"
