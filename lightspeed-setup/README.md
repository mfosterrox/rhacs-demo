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

**Manual secret (optional — the walkthrough script can create this for you):**

```bash
oc create secret generic anthropic-api-keys \
  --namespace openshift-lightspeed \
  --from-literal=apitoken='<YOUR_ANTHROPIC_API_KEY>'
```

### Anthropic (Claude) and supported LLM backends

Red Hat documents **official** OpenShift Lightspeed LLM integrations such as **OpenAI**, **Azure OpenAI**, **IBM watsonx**, and **Red Hat OpenShift AI / RHEL AI** (OpenAI-compatible **`/v1`** endpoints). See [Configuring and deploying OpenShift Lightspeed](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/ols-configuring-openshift-lightspeed).

**Anthropic’s hosted API** (`https://api.anthropic.com`, Messages API) is **not the same wire format** as the **OpenAI Chat Completions** API. The **`openai`** (and typical **`*_vllm`**) provider types in **`OLSConfig`** expect an **OpenAI-compatible** HTTP surface. So you **cannot** reliably set **`type: openai`** and **`url: https://api.anthropic.com/v1`** and expect Lightspeed to work—those paths and payloads differ.

What you **can** do:

| Goal | What to add |
|------|----------------|
| **Use your Anthropic Console API key with Claude models** | Usually run an **OpenAI-compatible gateway** on the cluster (or reachable URL) that **translates** OpenAI-style requests to Anthropic—e.g. **LiteLLM**, or another adapter your organization approves. Point **`OLSConfig`** at the **gateway’s** base URL (must end with **`/v1`** per Red Hat’s examples), **`type: openai`** (or the type your gateway matches), **`credentialsSecretRef`** to a Secret whose **`apitoken`** the gateway accepts (or configure the gateway with the Anthropic key separately—follow that product’s docs). |
| **Use Claude without a custom proxy** | Use a **supported** backend that exposes Claude through Lightspeed’s typed providers—commonly **Claude on Google Vertex AI** (**`google_vertex_anthropic`**) with a **GCP service account JSON** (not the Anthropic Console key alone), or a **`bam`** endpoint your vendor documents. |

**Minimum checklist** (any path):

1. **API key** from [Anthropic Console](https://console.anthropic.com/) when you need Anthropic’s cloud API (often via a proxy or gateway).
2. **Secret** in **`openshift-lightspeed`** with **`stringData.apitoken`** (name is flexible; **`anthropic-api-keys`** is a common choice).
3. **`OLSConfig`** **`cluster`**: **`spec.llm.providers`** (correct **`type`**, **`url`**, **`credentialsSecretRef`**, **`models`**) and **`spec.ols.defaultProvider`** / **`defaultModel`**.
4. **Apply**, restart/reconcile as needed, **`oc get pods -n openshift-lightspeed`**, test the console assistant.

The interactive script in this folder (**`configure-claude-default.sh`**) helps with **Vertex**-style and **BAM**-style providers; it does **not** deploy LiteLLM or other proxies.

---

## `configure-claude-default.sh` (interactive walkthrough)

**First-time use:** run it with **no arguments**. It asks a few questions and updates **`OLSConfig`** so **Claude becomes the default** model in the console.

```bash
cd /path/to/rhacs-demo
./lightspeed-setup/configure-claude-default.sh
```

**What you’ll see:**

1. **Option 1 — Default only** — Choose this if Claude is **already** configured under **`spec.llm.providers`**. The script only sets **`spec.ols.defaultProvider`** and **`spec.ols.defaultModel`** (your existing Azure provider stays).

2. **Option 2 — Add provider** — The script creates/updates the **`apitoken`** secret (default name **`anthropic-api-keys`**) and adds a provider entry. You pick:
   - **A)** Google Vertex AI (GCP project, region, path to service account JSON), or  
   - **B)** BAM-style endpoint (HTTPS base URL + API token).

Optional: **`./configure-claude-default.sh --help`** shows a short reminder.

### Making Claude the default when you already use Azure

If **`defaultProvider: Azure`** and **`defaultModel: gpt-4`** are set but you’ve **already added** a Claude provider (and secret) in the console or YAML, run the script and choose **1**. Enter the **exact** provider **`name`** and **`model`** from `OLSConfig` (same spelling as in **`spec.llm.providers`**).

### Environment variables (optional)

The walkthrough is interactive. For **token-only automation** (e.g. CI), you can **`export CLAUDE_API_KEY`** or **`ANTHROPIC_API_KEY`** before option **2 / B** so the script does not prompt for the token.

| Variable | Description |
|----------|-------------|
| `CLAUDE_API_KEY` / `ANTHROPIC_API_KEY` | Optional; used when creating the BAM secret if set |
| `LIGHTSPEED_NAMESPACE` | Default `openshift-lightspeed` |
| `LIGHTSPEED_OLSCONFIG_NAME` | Default `cluster` |
| `LIGHTSPEED_RESTART` | Restart `lightspeed-app-server` after patch (default `true`) |

### References

- [OLSConfig API reference](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/olsconfig-api)
- [Configure OpenShift Lightspeed](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index)
