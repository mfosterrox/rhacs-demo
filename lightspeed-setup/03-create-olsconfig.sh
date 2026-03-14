#!/bin/bash

# Create OLSConfig and credentials secret for OpenShift Lightspeed
# This triggers the operator to create the ConsolePlugin (enables "Ask OpenShift Lightspeed" in console)
#
# Usage:
#   Interactive:  ./03-create-olsconfig.sh          # Prompts for token and details
#   Non-interactive: OPENAI_API_KEY=sk-xxx ./03-create-olsconfig.sh
#   Skip secret:   OLS_CONFIG_ONLY=1 ./03-create-olsconfig.sh

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

LIGHTSPEED_NAMESPACE="${LIGHTSPEED_NAMESPACE:-openshift-lightspeed}"
SECRET_NAME="${LLM_SECRET_NAME:-llm-credentials}"

prompt_for_input() {
    local prompt="$1"
    local default="${2:-}"
    local secret="${3:-false}"
    local value=""
    if [ "$secret" = "true" ]; then
        read -r -s -p "${prompt}" value
        echo "" >&2
    else
        read -r -p "${prompt}" value
    fi
    if [ -z "${value}" ] && [ -n "${default}" ]; then
        echo "${default}"
    else
        echo "${value}"
    fi
}

main() {
    print_step "OpenShift Lightspeed OLSConfig Setup"
    echo "=========================================="
    echo ""

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi

    if ! oc get namespace "${LIGHTSPEED_NAMESPACE}" &>/dev/null; then
        print_error "Namespace ${LIGHTSPEED_NAMESPACE} not found. Install the Lightspeed operator first."
        exit 1
    fi

    # Gather credentials and config (interactive or from env)
    local api_key="${OPENAI_API_KEY:-${LLM_API_KEY}}"
    local provider="${LLM_PROVIDER:-}"
    local model="${LLM_MODEL:-}"
    local url="${LLM_URL:-}"
    local azure_deployment="${AZURE_DEPLOYMENT:-}"
    local azure_api_version="${AZURE_API_VERSION:-}"
    local watsonx_project="${WATSONX_PROJECT_ID:-}"

    # Prompt for config if not set (needed for OLSConfig in all cases)
    if [ -z "${provider}" ]; then
        echo ""
        echo "LLM provider options: openai, azure_openai, watsonx, openshift_ai, rhel_ai"
        provider=$(prompt_for_input "Provider type [openai]: " "openai")
    fi
    if [ -z "${model}" ]; then
        model=$(prompt_for_input "Model name [gpt-4o-mini]: " "gpt-4o-mini")
    fi

    case "${provider}" in
        openai)
            if [ -z "${url}" ]; then
                url=$(prompt_for_input "API URL [https://api.openai.com/v1]: " "https://api.openai.com/v1")
            fi
            ;;
        azure_openai)
            if [ -z "${url}" ]; then
                url=$(prompt_for_input "Azure OpenAI endpoint URL (e.g. https://myresource.openai.azure.com): " "")
            fi
            if [ -z "${azure_deployment}" ]; then
                azure_deployment=$(prompt_for_input "Deployment name: " "")
            fi
            if [ -z "${azure_api_version}" ]; then
                azure_api_version=$(prompt_for_input "API version [2024-02-15-preview]: " "2024-02-15-preview")
            fi
            ;;
        watsonx)
            if [ -z "${url}" ]; then
                url=$(prompt_for_input "Watsonx URL (e.g. https://us-south.ml.cloud.ibm.com): " "")
            fi
            if [ -z "${watsonx_project}" ]; then
                watsonx_project=$(prompt_for_input "Watsonx project ID: " "")
            fi
            ;;
        *)
            if [ -z "${url}" ]; then
                url=$(prompt_for_input "API URL: " "https://api.openai.com/v1")
            fi
            ;;
    esac
    url="${url:-https://api.openai.com/v1}"

    if [ "${OLS_CONFIG_ONLY:-0}" != "1" ]; then
        if [ -z "${api_key}" ]; then
            echo ""
            print_info "Enter your LLM provider API token (input is hidden):"
            api_key=$(prompt_for_input "API token: " "" "true")
            if [ -z "${api_key}" ]; then
                print_error "API token is required"
                exit 1
            fi
            echo ""
        fi

        print_step "Creating credentials secret..."
        oc create secret generic "${SECRET_NAME}" \
            -n "${LIGHTSPEED_NAMESPACE}" \
            --from-literal=apitoken="${api_key}" \
            --dry-run=client -o yaml | oc apply -f -
        print_info "✓ Secret ${SECRET_NAME} created/updated"
        echo ""
    fi

    # Build provider YAML
    local provider_yaml
    case "${provider}" in
        azure_openai)
            provider_yaml="
      - name: ${provider}
        type: azure_openai
        url: \"${url}\"
        apiVersion: \"${azure_api_version}\"
        deploymentName: \"${azure_deployment}\"
        credentialsSecretRef:
          name: ${SECRET_NAME}
        models:
          - name: ${model}"
            ;;
        watsonx)
            provider_yaml="
      - name: ${provider}
        type: watsonx
        url: \"${url}\"
        projectID: \"${watsonx_project}\"
        credentialsSecretRef:
          name: ${SECRET_NAME}
        models:
          - name: ${model}"
            ;;
        *)
            provider_yaml="
      - name: ${provider}
        type: ${provider}
        url: \"${url}\"
        credentialsSecretRef:
          name: ${SECRET_NAME}
        models:
          - name: ${model}"
            ;;
    esac

    # Create OLSConfig
    print_step "Creating OLSConfig..."
    cat <<EOF | oc apply -f -
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
  namespace: ${LIGHTSPEED_NAMESPACE}
spec:
  llm:
    providers:${provider_yaml}
  ols:
    defaultProvider: ${provider}
    defaultModel: ${model}
EOF

    print_info "✓ OLSConfig created"
    echo ""
    print_info "The operator will now deploy the Lightspeed service and create the ConsolePlugin."
    print_info "Wait 2-3 minutes, then run: ./02-verify-console-integration.sh"
    print_info ""
    print_info "The 'Ask OpenShift Lightspeed' button will appear in the YAML editor."
    echo ""
}

main "$@"
