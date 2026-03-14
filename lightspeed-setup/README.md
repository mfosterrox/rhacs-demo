# OpenShift Lightspeed Setup

Automated installation of Red Hat OpenShift Lightspeed with integration into the OpenShift web console.

## Overview

OpenShift Lightspeed is a generative AI-based virtual assistant integrated into the OpenShift web console. It uses natural language to help you create and manage OpenShift resources. This setup installs the OpenShift Lightspeed Operator and ensures the console plugin is enabled.

**Console integration features:**
- **"Ask OpenShift Lightspeed"** button in the YAML Editor
- AI-powered assistance for creating and editing Kubernetes/OpenShift resources
- "Import to Console" for applying generated YAML directly

## Prerequisites

- **OpenShift 4.15+** cluster
- **x86_64 architecture** (operator not available on ARM)
- **cluster-admin** access
- **LLM provider** (must be configured separately):
  - Red Hat OpenShift AI
  - Red Hat Enterprise Linux AI
  - IBM watsonx
  - Microsoft Azure OpenAI
  - OpenAI

## Quick Start

From the **project root**:

```bash
./lightspeed-setup/install.sh
```

Or from **within this folder**:

```bash
cd lightspeed-setup
./install.sh
```

**What happens:**
1. Installs the OpenShift Lightspeed Operator from OperatorHub
2. Enables the Lightspeed console plugin (after OLSConfig is created)
3. Operator deploys to `openshift-lightspeed` namespace

**Important:** The "Ask OpenShift Lightspeed" button only appears **after** you create OLSConfig with your LLM provider. The operator creates the ConsolePlugin when OLSConfig exists.

**Time:** ~5 minutes for operator; add 2-3 min after OLSConfig for console integration

## Setup Scripts

| Script | Description |
|--------|-------------|
| `install.sh` | Main orchestrator - runs all setup scripts |
| `01-install-lightspeed-operator.sh` | Installs OpenShift Lightspeed Operator via OLM |
| `02-verify-console-integration.sh` | Enables Lightspeed ConsolePlugin in OpenShift console |
| `03-create-olsconfig.sh` | Creates OLSConfig + credentials secret (triggers ConsolePlugin) |

## Configuring an LLM Provider (Required for Console Integration)

The operator does **not** install an LLM provider. You must create an `OLSConfig` custom resource. **This is required for the "Ask OpenShift Lightspeed" button to appear**—the ConsolePlugin is only created after OLSConfig exists.

### Quick: Use the helper script (interactive)

```bash
# Prompts for API token, provider type, model, and URL
./03-create-olsconfig.sh

# Or non-interactive with env vars
export OPENAI_API_KEY='sk-your-key-here'
./03-create-olsconfig.sh

# Wait 2-3 minutes, then enable console integration
./02-verify-console-integration.sh
```

### Manual: Create a credentials secret

```bash
# Example: OpenAI API token
oc create secret generic llm-credentials \
  -n openshift-lightspeed \
  --from-literal=apitoken="your-api-token-here"
```

### 2. Create OLSConfig

Create an `OLSConfig` resource referencing your secret. Example for OpenAI:

```yaml
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
  namespace: openshift-lightspeed
spec:
  llm:
    providers:
      - name: openai
        type: openai
        url: https://api.openai.com/v1
        credentialsSecretRef:
          name: llm-credentials
        models:
          - name: gpt-4o-mini
  ols:
    defaultProvider: openai
    defaultModel: gpt-4o-mini
```

Apply it:

```bash
oc apply -f olsconfig.yaml
```

### Supported LLM Providers

| Provider | Type | Notes |
|----------|------|-------|
| OpenAI | `openai` | API key in `apitoken` |
| Azure OpenAI | `azure_openai` | Requires `url`, `apiVersion`, `deploymentName` |
| OpenShift AI | `openshift_ai` | Uses in-cluster OpenShift AI |
| RHEL AI | `rhel_ai` | Red Hat Enterprise Linux AI |
| IBM watsonx | `watsonx` | Requires `projectID` |

See [Red Hat OpenShift Lightspeed Configuration](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/index) for full OLSConfig API reference.

## Verification

### Check operator installation

```bash
oc get csv -n openshift-lightspeed
oc get pods -n openshift-lightspeed
```

### Check console plugin

```bash
oc get consoleplugins
oc get consoles.operator.openshift.io cluster -o jsonpath='{.spec.plugins[*]}'
```

### Access Lightspeed in the console

1. Log into the OpenShift web console
2. Navigate to any resource (e.g. Workloads → Deployments)
3. Click **Create** or **Edit** to open the YAML editor
4. Look for the **"Ask OpenShift Lightspeed"** button
5. Click it to open the AI chat interface

## Individual Script Execution

Run scripts individually for testing or troubleshooting:

```bash
# Install operator only
./01-install-lightspeed-operator.sh

# Enable console integration only (after operator is installed)
./02-verify-console-integration.sh
```

## Troubleshooting

### "AllNamespaces InstallModeType not supported" error

The OpenShift Lightspeed Operator does not support cluster-wide (AllNamespaces) installation. The install script uses `targetNamespaces: [openshift-lightspeed]` so the operator only watches its own namespace.

If you previously had a failed install, clean up and re-run:

```bash
oc delete subscription lightspeed-operator -n openshift-lightspeed --ignore-not-found
oc delete operatorgroup lightspeed-operator-group -n openshift-lightspeed --ignore-not-found
# Wait for CSV to be removed, or delete the namespace for a clean slate:
# oc delete namespace openshift-lightspeed
./lightspeed-setup/install.sh
```

### Operator not found in OperatorHub

- **OpenShift version**: Lightspeed requires OpenShift 4.15+
- **Architecture**: Operator is x86_64 only (not available on ARM/M1)
- **Catalog**: Ensure `redhat-operators` catalog is available:
  ```bash
  oc get catalogsource -n openshift-marketplace
  ```

### Console plugin not appearing

1. Wait a few minutes after operator installation
2. Some operators create the ConsolePlugin only after OLSConfig exists
3. Manually enable: `./02-verify-console-integration.sh`
4. Refresh the browser (hard refresh: Ctrl+Shift+R)

### Lightspeed chat not working

- Verify OLSConfig is created and has no errors: `oc get olsconfig -A`
- Check operator logs: `oc logs -n openshift-lightspeed -l control-plane=controller-manager -f`
- Ensure LLM provider credentials are valid

## References

- [Red Hat OpenShift Lightspeed Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/)
- [Get Started with OpenShift Lightspeed](https://developers.redhat.com/learn/openshift/get-started-red-hat-openshift-lightspeed)
- [OpenShift Lightspeed Operator (GitHub)](https://github.com/openshift/lightspeed-operator)
- [OpenShift Lightspeed Console Plugin (GitHub)](https://github.com/openshift/lightspeed-console)
