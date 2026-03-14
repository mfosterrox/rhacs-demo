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

    # Summary
    print_header "════════════════════════════════════════════════════════════"
    print_header "                    Setup Complete! ✓                       "
    print_header "════════════════════════════════════════════════════════════"
    echo ""
    print_info "OpenShift Lightspeed is installed with OpenShift console integration."
    echo ""
    print_info "Next steps:"
    echo "  1. Create an OLSConfig with your LLM provider credentials"
    echo "  2. Access Lightspeed from the OpenShift console:"
    echo "     - Open any resource (e.g. Deployment, Pod)"
    echo "     - Click 'Edit' in the YAML editor"
    echo "     - Click 'Ask OpenShift Lightspeed' button"
    echo ""
    print_info "See README.md for OLSConfig examples and LLM provider setup."
    echo ""
}

main "$@"
