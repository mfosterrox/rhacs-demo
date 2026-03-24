#!/bin/bash

set -euo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${CYAN}[STEP]${NC} $*"; }
print_header() { echo -e "${BOLD}${BLUE}$*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#================================================================
# Display banner
#================================================================
display_banner() {
    echo ""
    print_header "╔════════════════════════════════════════════════════════════╗"
    print_header "║                                                            ║"
    print_header "║     OpenShift Lightspeed Installation & Console Setup      ║"
    print_header "║                                                            ║"
    print_header "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This script will:"
    echo "  1. Install the OpenShift Lightspeed Operator from OperatorHub"
    echo "  2. Enable OpenShift Lightspeed integration in the OpenShift web console"
    echo ""
    echo "Prerequisites:"
    echo "  - OpenShift 4.15+ (x86_64)"
    echo "  - cluster-admin access"
    echo "  - LLM provider (OpenShift AI, Azure OpenAI, OpenAI, Watsonx, RHEL AI)"
    echo ""
    echo "⏱️  Total time: ~5 minutes"
    echo ""
}

#================================================================
# Main execution
#================================================================
main() {
    display_banner

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift cluster. Run: oc login"
        exit 1
    fi

    # Step 1: Install operator
    if [ ! -f "${SCRIPT_DIR}/01-install-lightspeed-operator.sh" ]; then
        print_error "01-install-lightspeed-operator.sh not found"
        exit 1
    fi
    print_info "Executing: 01-install-lightspeed-operator.sh"
    if ! bash "${SCRIPT_DIR}/01-install-lightspeed-operator.sh"; then
        print_error "Operator installation failed"
        exit 1
    fi
    print_info "✓ Operator installation complete"
    echo ""

    # Step 2: Enable console integration
    if [ ! -f "${SCRIPT_DIR}/02-verify-console-integration.sh" ]; then
        print_error "02-verify-console-integration.sh not found"
        exit 1
    fi
    print_info "Executing: 02-verify-console-integration.sh"
    if bash "${SCRIPT_DIR}/02-verify-console-integration.sh"; then
        print_info "✓ Console integration complete"
    else
        print_warn "Console integration skipped or incomplete"
        print_info "The ConsolePlugin may appear after creating OLSConfig with your LLM provider"
        print_info "Re-run: ./lightspeed-setup/02-verify-console-integration.sh"
    fi
    echo ""

    # Step 3: Offer to create OLSConfig (credentials secret + OLSConfig)
    if [ -f "${SCRIPT_DIR}/03-create-olsconfig.sh" ]; then
        if [ "${LIGHTSPEED_SKIP_OLSCONFIG:-0}" = "1" ]; then
            print_info "LIGHTSPEED_SKIP_OLSCONFIG=1 — skipping OLSConfig (run 03-create-olsconfig.sh later if needed)"
        elif [ "${LIGHTSPEED_AUTO_OLSCONFIG:-0}" = "1" ]; then
            if [ -z "${OPENAI_API_KEY:-}" ] && [ -z "${LLM_API_KEY:-}" ]; then
                print_error "LIGHTSPEED_AUTO_OLSCONFIG=1 requires OPENAI_API_KEY or LLM_API_KEY"
                exit 1
            fi
            print_info "Executing: 03-create-olsconfig.sh (non-interactive; LLM env from environment)"
            if bash "${SCRIPT_DIR}/03-create-olsconfig.sh"; then
                print_info "✓ OLSConfig created"
                print_info "Wait 2-3 minutes, then run: ./lightspeed-setup/02-verify-console-integration.sh"
            else
                print_error "03-create-olsconfig.sh failed"
                exit 1
            fi
        elif [ -t 0 ] && [ -t 1 ]; then
            echo ""
            read -r -p "Configure LLM provider now? (will prompt for API token and details) [y/N]: " configure_llm
            if [[ "${configure_llm,,}" =~ ^(y|yes)$ ]]; then
                print_info "Executing: 03-create-olsconfig.sh"
                if bash "${SCRIPT_DIR}/03-create-olsconfig.sh"; then
                    print_info "✓ OLSConfig created"
                    print_info "Wait 2-3 minutes, then run: ./lightspeed-setup/02-verify-console-integration.sh"
                fi
            else
                print_info "Skipped. Run ./lightspeed-setup/03-create-olsconfig.sh when ready."
            fi
        else
            print_info "To configure LLM: ./lightspeed-setup/03-create-olsconfig.sh (prompts for token and details)"
        fi
        echo ""
    fi

    # Summary
    print_header "════════════════════════════════════════════════════════════"
    print_header "                    Setup Complete! ✓                       "
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    print_info "OpenShift Lightspeed is installed with OpenShift console integration."
    echo ""
    print_info "Next steps:"
    echo "  1. If not done: ./lightspeed-setup/03-create-olsconfig.sh (prompts for API token and details)"
    echo "  2. Access Lightspeed from the OpenShift console:"
    echo "     - Open any resource (e.g. Deployment, Pod)"
    echo "     - Click 'Edit' in the YAML editor"
    echo "     - Click 'Ask OpenShift Lightspeed' button"
    echo ""
    print_info "See README.md for OLSConfig examples and LLM provider setup."
    echo ""
}

main "$@"
