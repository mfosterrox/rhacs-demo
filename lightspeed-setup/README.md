# OpenShift Lightspeed helpers

## Anthropic Console API keys (product docs)

API keys come from **[Anthropic Console](https://console.anthropic.com/)**, not from the Claude app:

1. Sign in at [console.anthropic.com](https://console.anthropic.com/)
2. Open **API Keys** in the sidebar → **Create Key**, name it, and copy it once (it is only shown at creation).

That key authenticates HTTP requests to Anthropic’s API (for example the Messages API under **`https://api.anthropic.com/v1/messages`**).

For a **generic** workload on OpenShift you might store it like this (key name is up to your deployment):

```bash
oc create secret generic anthropic-api-key \
  --from-literal=ANTHROPIC_API_KEY=sk-ant-api03-...
```

**OpenShift Lightspeed** stores the token in the **`openshift-lightspeed`** namespace using the data key **`apitoken`** (per Red Hat’s LLM provider pattern), not `ANTHROPIC_API_KEY`.

**1. Create the API credential secret** (replace the placeholder with your key from the Console):

```bash
oc create secret generic anthropic-api-keys \
  --namespace openshift-lightspeed \
  --from-literal=apitoken='<YOUR_ANTHROPIC_API_KEY>'
```

**2. Define the provider** in the **`OLSConfig`** custom resource (`spec.llm.providers`, plus **`spec.ols.defaultProvider`** / **`defaultModel`** as needed). The exact `type` and `url` values depend on your OpenShift Lightspeed version and [OLSConfig API](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/olsconfig-api) — for example **`google_vertex_anthropic`** (Claude on Google Vertex) or **`bam`**, with `credentialsSecretRef.name` set to the secret you created (e.g. **`anthropic-api-keys`**).

This repo’s `configure-claude-default.sh` creates/updates a secret named **`anthropic-api-keys`** with key **`apitoken`** by default, then merge-patches **`OLSConfig`** to reference it (see backends below). Override the name with **`LIGHTSPEED_SECRET_NAME`** if needed.

---

## `configure-claude-default.sh`

Sets **`spec.ols.defaultProvider`** and **`spec.ols.defaultModel`** so the console defaults to your Claude-capable provider, and adds or updates an LLM provider entry under **`spec.llm.providers`**.

If you run the script with no `--backend` and no **`LIGHTSPEED_CLAUDE_BACKEND`**, it **auto-selects** the backend when possible:

- **`vertex`** when **`GCP_VERTEX_PROJECT`** and a readable **`GOOGLE_APPLICATION_CREDENTIALS`** file are set  
- **`bam`** when **`LIGHTSPEED_BAM_URL`** is set  

Otherwise it prints a short usage summary (instead of failing with only “GCP project required”).

This script supports the provider types Lightspeed can reconcile today:

| Backend | When to use | Credentials |
|--------|-------------|----------------|
| **`vertex`** | Claude on **Google Cloud Vertex AI** | GCP **service account JSON** (`GOOGLE_APPLICATION_CREDENTIALS`). Set **`GCP_VERTEX_PROJECT`** and optionally **`GCP_VERTEX_LOCATION`**. |
| **`bam`** | Host-provided **BAM**-style HTTPS endpoint (`type: bam` in `OLSConfig`) | Bearer/API token stored under secret key **`apitoken`**. Set **`LIGHTSPEED_BAM_URL`** to that service’s base URL (from your product docs, not `api.anthropic.com` unless explicitly supported). |

Lightspeed LLM secrets use the data key **`apitoken`** per [Configure OpenShift Lightspeed](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index).

### Examples

**Google Vertex Claude** (recommended if you use GCP):

```bash
export GCP_VERTEX_PROJECT="my-gcp-project"
export GCP_VERTEX_LOCATION="us-central1"
export GOOGLE_APPLICATION_CREDENTIALS="$HOME/gcp-sa.json"
export CLAUDE_MODEL="claude-sonnet-4-20250514"
./lightspeed-setup/configure-claude-default.sh --backend vertex
```

**IBM BAM** (URL comes from your IBM / environment documentation):

```bash
export LIGHTSPEED_BAM_URL="https://your-bam-endpoint.example/v1"
export CLAUDE_API_KEY="..."   # or paste when prompted
./lightspeed-setup/configure-claude-default.sh --backend bam
```

**Only change the default provider/model** (provider already exists in `OLSConfig`):

```bash
./lightspeed-setup/configure-claude-default.sh --defaults-only \
  --provider-name myClaude --model claude-sonnet-4-20250514
```

**Making Claude the default when you already use Azure (like `defaultProvider: Azure`, `defaultModel: gpt-4`):**

1. Add your Claude/Anthropic provider under **`spec.llm.providers`** (Console or YAML) and the **`anthropic-api-keys`** secret with **`apitoken`**, following Red Hat / Anthropic docs for your OLS version.
2. Flip only the defaults so Lightspeed stops preferring GPT — use the **`name`** of that provider and a **`model`** id that appears under it:

```bash
./lightspeed-setup/configure-claude-default.sh --defaults-only \
  --provider-name Anthropic \
  --model 'claude-3-5-sonnet-20241022'
```

Adjust **`--provider-name`** and **`--model`** to match exactly what you put in `OLSConfig` (they must match **`spec.llm.providers[].name`** and a **`models[].name`**). Your existing **Azure** entry stays; only **`spec.ols.defaultProvider`** / **`defaultModel`** change, which is enough for Claude to become the default.

### Environment variables

| Variable | Description |
|----------|-------------|
| `CLAUDE_API_KEY` / `ANTHROPIC_API_KEY` | Token for `--backend bam` (non-interactive) |
| `LIGHTSPEED_BAM_URL` | Required for `bam` |
| `GCP_VERTEX_PROJECT`, `GCP_VERTEX_LOCATION` | Required for `vertex` |
| `GOOGLE_APPLICATION_CREDENTIALS` | Path to GCP service account JSON for `vertex` |
| `CLAUDE_PROVIDER_NAME` | Provider name in OLSConfig (default `claude`) |
| `CLAUDE_MODEL` | Model id (default `claude-sonnet-4-20250514`) |
| `LIGHTSPEED_NAMESPACE` | Default `openshift-lightspeed` |
| `LIGHTSPEED_OLSCONFIG_NAME` | Default `cluster` |
| `LIGHTSPEED_SECRET_NAME` | Secret for credentials (default **`anthropic-api-keys`**, key **`apitoken`**) |
| `LIGHTSPEED_RESTART` | Restart `lightspeed-app-server` after patch (default `true`) |

### References

- [OLSConfig API reference](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/olsconfig-api)
- [Configure OpenShift Lightspeed](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index)
