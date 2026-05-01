# OpenShift Lightspeed helpers

## `configure-claude-default.sh`

Sets **`spec.ols.defaultProvider`** and **`spec.ols.defaultModel`** so the console defaults to your Claude-capable provider, and adds or updates an LLM provider entry under **`spec.llm.providers`**.

OLSConfig does **not** define a standalone “Anthropic console API” provider. Claude is configured through supported provider types. This script supports:

| Backend | When to use | Credentials |
|--------|-------------|----------------|
| **`vertex`** (default) | Claude on **Google Cloud Vertex AI** | GCP **service account JSON** file (`GOOGLE_APPLICATION_CREDENTIALS`). Set `GCP_VERTEX_PROJECT` and optionally `GCP_VERTEX_LOCATION`. |
| **`bam`** | **IBM BAM** (or another endpoint your cluster expects with `type: bam`) | API token in secret key **`apitoken`**. Set **`LIGHTSPEED_BAM_URL`** to your provider base URL. |

Secret key name for tokens follows Red Hat docs: **`apitoken`**.

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
| `LIGHTSPEED_SECRET_NAME` | Secret for credentials (default `lightspeed-claude-credentials`) |
| `LIGHTSPEED_RESTART` | Restart `lightspeed-app-server` after patch (default `true`) |

### References

- [OLSConfig API reference](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html/configure/olsconfig-api)
- [Configure OpenShift Lightspeed](https://docs.redhat.com/en/documentation/red_hat_openshift_lightspeed/1.0/html-single/configure/index)
