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

# Show a numbered menu and return the selected value (or "custom" key for custom input)
# Options use key|label (pipe). Do not use ':' — URLs contain ':' after the scheme (https://).
# Usage: select_from_menu "Prompt" "opt1|Display 1" "opt2|Display 2" "custom|Enter custom URL"
# Returns the key (e.g. opt1, opt2, or prompts for input if custom)
select_from_menu() {
    local prompt="$1"
    shift
    local -a options=("$@")
    local -a keys=()
    local -a labels=()
    local i=1
    local choice

    for opt in "${options[@]}"; do
        local key="${opt%%|*}"
        local label="${opt#*|}"
        keys+=("$key")
        labels+=("$label")
        echo "  $i) $label" >&2
        ((i++))
    done

    echo "" >&2
    while true; do
        read -r -p "${prompt}" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
            local idx=$((choice - 1))
            echo "${keys[$idx]}"
            return
        fi
        print_warn "Enter a number 1-${#keys[@]}" >&2
    done
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
    local api_key="${OPENAI_API_KEY:-${LLM_API_KEY:-}}"
    local provider="${LLM_PROVIDER:-}"
    local model="${LLM_MODEL:-}"
    local url="${LLM_URL:-}"
    local azure_deployment="${AZURE_DEPLOYMENT:-}"
    local azure_api_version="${AZURE_API_VERSION:-}"
    local watsonx_project="${WATSONX_PROJECT_ID:-}"

    # Prompt for config if not set (needed for OLSConfig in all cases)
    if [ -z "${provider}" ]; then
        echo ""
        print_step "Select LLM provider"
        provider=$(select_from_menu "Provider [1-5]: " \
            "openai|OpenAI (api.openai.com)" \
            "azure_openai|Azure OpenAI" \
            "watsonx|IBM Watsonx" \
            "openshift_ai|OpenShift AI (in-cluster)" \
            "rhel_ai|RHEL AI")
        echo ""
    fi

    if [ -z "${model}" ]; then
        echo ""
        case "${provider}" in
            openai|azure_openai)
                print_step "Select model"
                model=$(select_from_menu "Model [1-5]: " \
                    "gpt-4o-mini|gpt-4o-mini (recommended)" \
                    "gpt-4o|gpt-4o" \
                    "gpt-4-turbo|gpt-4-turbo" \
                    "gpt-3.5-turbo|gpt-3.5-turbo" \
                    "custom|Enter custom model name")
                [ "$model" = "custom" ] && model=$(prompt_for_input "Model name: " "gpt-4o-mini")
                ;;
            watsonx)
                print_step "Select model"
                model=$(select_from_menu "Model [1-4]: " \
                    "granitenano|granitenano" \
                    "granitenano-2|granitenano-2" \
                    "meta-llama/llama-3-1-70b-instruct|meta-llama/llama-3-1-70b-instruct" \
                    "custom|Enter custom model name")
                [ "$model" = "custom" ] && model=$(prompt_for_input "Model name: " "granitenano")
                ;;
            *)
                model=$(prompt_for_input "Model name [gpt-4o-mini]: " "gpt-4o-mini")
                ;;
        esac
        echo ""
    fi

    case "${provider}" in
        openai)
            if [ -z "${url}" ]; then
                echo ""
                print_step "Select OpenAI API endpoint"
                local url_choice
                url_choice=$(select_from_menu "API URL [1-2]: " \
                    "https://api.openai.com/v1|OpenAI (api.openai.com)" \
                    "custom|Enter custom URL")
                [ "$url_choice" = "custom" ] && url=$(prompt_for_input "API URL: " "https://api.openai.com/v1")
                [ "$url_choice" != "custom" ] && url="$url_choice"
                echo ""
            fi
            ;;
        azure_openai)
            if [ -z "${url}" ]; then
                echo ""
                print_step "Azure OpenAI configuration"
                print_info "Enter your Azure OpenAI resource endpoint (e.g. https://myresource.openai.azure.com)"
                url=$(prompt_for_input "Azure endpoint URL: " "")
            fi
            if [ -z "${azure_deployment}" ]; then
                azure_deployment=$(prompt_for_input "Deployment name: " "")
            fi
            if [ -z "${azure_api_version}" ]; then
                echo ""
                azure_api_version=$(select_from_menu "API version [1-3]: " \
                    "2024-02-15-preview|2024-02-15-preview (recommended)" \
                    "2024-08-01-preview|2024-08-01-preview" \
                    "custom|Enter custom version")
                [ "$azure_api_version" = "custom" ] && azure_api_version=$(prompt_for_input "API version: " "2024-02-15-preview")
                echo ""
            fi
            ;;
        watsonx)
            if [ -z "${url}" ]; then
                echo ""
                print_step "Select Watsonx region"
                local url_choice
                url_choice=$(select_from_menu "Region [1-7]: " \
                    "https://us-south.ml.cloud.ibm.com|Dallas (us-south)" \
                    "https://eu-de.ml.cloud.ibm.com|Frankfurt (eu-de)" \
                    "https://eu-gb.ml.cloud.ibm.com|London (eu-gb)" \
                    "https://jp-tok.ml.cloud.ibm.com|Tokyo (jp-tok)" \
                    "https://ca-tor.ml.cloud.ibm.com|Toronto (ca-tor)" \
                    "https://au-syd.ml.cloud.ibm.com|Sydney (au-syd)" \
                    "custom|Enter custom Watsonx URL")
                [ "$url_choice" = "custom" ] && url=$(prompt_for_input "Watsonx URL: " "https://us-south.ml.cloud.ibm.com")
                [ "$url_choice" != "custom" ] && url="$url_choice"
                echo ""
            fi
            if [ -z "${watsonx_project}" ]; then
                watsonx_project=$(prompt_for_input "Watsonx project ID: " "")
            fi
            ;;
        openshift_ai|rhel_ai)
            if [ -z "${url}" ]; then
                echo ""
                print_info "OpenShift AI / RHEL AI typically use in-cluster endpoints."
                url=$(prompt_for_input "API URL (or leave blank for default): " "")
            fi
            ;;
        *)
            if [ -z "${url}" ]; then
                url=$(prompt_for_input "API URL: " "https://api.openai.com/v1")
            fi
            ;;
    esac
    url="${url:-https://api.openai.com/v1}"

    if [[ ! "${url}" =~ ^https?:// ]]; then
        print_error "Invalid LLM URL (must match ^https?://...): ${url}"
        print_error "If you used the menu, re-run with the fixed script; or set LLM_URL to a full endpoint URL."
        exit 1
    fi

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
    if ! cat <<EOF | oc apply -f -
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
    then
        print_error "Failed to apply OLSConfig (see messages above)."
        exit 1
    fi

    print_info "✓ OLSConfig created"
    echo ""
    print_info "The operator will now deploy the Lightspeed service and create the ConsolePlugin."
    print_info "Wait 2-3 minutes, then run: ./02-verify-console-integration.sh"
    print_info ""
    print_info "The 'Ask OpenShift Lightspeed' button will appear in the YAML editor."
    echo ""
}

main "$@"
