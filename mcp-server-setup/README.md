# StackRox MCP Server Setup

Deploy the [StackRox MCP](https://github.com/stackrox/stackrox-mcp) server to provide AI assistants with access to RHACS/StackRox via the Model Context Protocol.

## Overview

The StackRox MCP server exposes RHACS data to MCP clients through tools for:
- **Vulnerability management** – query vulnerabilities, images, deployments
- **Configuration management** – manage RHACS configuration

Deployment uses **Kubernetes manifests** (no Helm required).

## Prerequisites

- OpenShift cluster with **RHACS installed** (run `basic-setup/install.sh` first)
- `oc` CLI authenticated

## Quick Start

From the **project root**:

```bash
./mcp-server-setup/install.sh
```

Or from **within this folder**:

```bash
cd mcp-server-setup
./install.sh
```

**What happens:**
1. Applies Kubernetes manifests from `manifests/` (based on [stackrox-mcp](https://github.com/stackrox/stackrox-mcp) commit `779f4a0`)
2. Deploys the MCP server to `stackrox-mcp` namespace
3. Creates an OpenShift Route for external access
4. Configures connection to RHACS Central (auto-detected or from `ROX_CENTRAL_ADDRESS`)
5. When OpenShift Lightspeed is present, merge-patches `OLSConfig` to enable the **MCPServer** feature gate and register this MCP endpoint (optional; on by default — see `LIGHTSPEED_PATCH_OLSCONFIG`)
6. Validates OpenShift Lightspeed MCP wiring (when OLSConfig is present): feature gate, MCP URL/transport, auth header mode, route reachability, and Lightspeed readiness

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ROX_CENTRAL_ADDRESS` | Yes* | RHACS Central URL (e.g., `https://central-stackrox.apps.cluster.com`). Auto-detected from cluster route if not set. |
| `ROX_API_TOKEN` | Recommended | API token for Central. Run `basic-setup/install.sh` first to generate. Without it, MCP uses passthrough auth (client must send token). |
| `RHACS_NAMESPACE` | No | RHACS namespace (default: `stackrox`) |
| `MCP_NAMESPACE` | No | MCP server namespace (default: `stackrox-mcp`) |
| `MCP_ROUTE_HOST` | No | Custom Route hostname (default: auto-assigned) |
| `LIGHTSPEED_VALIDATE` | No | Validate OpenShift Lightspeed integration during install (`true` by default). |
| `LIGHTSPEED_PATCH_OLSCONFIG` | No | Merge-patch `olsconfig` with `spec.featureGates: [MCPServer]` and an MCP server entry (`true` by default). Set `false` if you manage `OLSConfig` via GitOps. |
| `LIGHTSPEED_RESTART_AFTER_PATCH` | No | After a successful patch, restart `deployment/lightspeed-app-server` (`true` by default). |
| `LIGHTSPEED_MCP_URL_STYLE` | No | URL written into `OLSConfig.spec.mcpServers`: `internal` (`http://stackrox-mcp.<namespace>:8080/mcp`) or `route` (HTTPS Route hostname). Default: `internal`. Use `route` for the same style as a manual `oc patch` that points at the MCP Route. |
| `LIGHTSPEED_MCP_OLS_URL` | No | Explicit MCP URL for Lightspeed (overrides `LIGHTSPEED_MCP_URL_STYLE`). |
| `LIGHTSPEED_NAMESPACE` | No | OpenShift Lightspeed namespace (default: `openshift-lightspeed`). |
| `LIGHTSPEED_OLSCONFIG_NAME` | No | OLSConfig name to inspect (default: `cluster`). |
| `LIGHTSPEED_MCP_SERVER_NAME` | No | MCP server entry `name` in `OLSConfig.spec.mcpServers` (default: `stackrox-mcp`). Use e.g. `StackRox MCP Server` if you want the Lightspeed UI label to match a manual patch; validation uses this same value. |

## MCP Client Configuration

After deployment, the script prints the MCP endpoint URL:

```bash
# Example endpoint format
https://stackrox-mcp-stackrox-mcp.apps.example.com/mcp
```

Configure your MCP client to use HTTP transport with that endpoint.

## OpenShift Lightspeed Integration

OpenShift Lightspeed being installed is not enough by itself; the `OLSConfig` must include MCP settings (`spec.featureGates` includes **MCPServer**, and `spec.mcpServers` lists this server).

By default, `install.sh` applies an **idempotent** merge patch (adds `MCPServer` without removing other feature gates; upserts the MCP entry by `LIGHTSPEED_MCP_SERVER_NAME`). With static Central auth it also wires an `Authorization` header from the secret created in the Lightspeed namespace.

For the same shape as a minimal manual patch (HTTPS Route URL and a display-style name), run:

```bash
export LIGHTSPEED_MCP_URL_STYLE=route
export LIGHTSPEED_MCP_SERVER_NAME='StackRox MCP Server'
./mcp-server-setup/install.sh
```

Recommended URL for same-cluster traffic is still the in-cluster service URL (`LIGHTSPEED_MCP_URL_STYLE=internal`, the default).

The install script validates MCP wiring after patching and still prints a manual `oc patch` example if `OLSConfig` cannot be read or updated.

## Verification

```bash
# Check deployment
oc get deployment -n stackrox-mcp
oc get pods -n stackrox-mcp

# Check route
oc get route -n stackrox-mcp

# Test health endpoint
curl -k https://$(oc get route stackrox-mcp -n stackrox-mcp -o jsonpath='{.spec.host}')/health
# Expected: {"status":"ok"}

# Run smoke test script
./mcp-server-setup/test-mcp-server.sh
```

## Manifests

The `manifests/` directory contains Kubernetes resources:

| File | Description |
|------|-------------|
| `namespace.yaml` | Creates `stackrox-mcp` namespace |
| `serviceaccount.yaml` | Service account for the deployment |
| `configmap.yaml.template` | Config template (Central URL, auth type) |
| `deployment.yaml` | Deployment (1 replica, quay.io/stackrox-io/mcp:latest) |
| `service.yaml` | ClusterIP service on port 8080 |
| `route.yaml` | OpenShift Route for external access |

The install script substitutes `ROX_CENTRAL_ADDRESS`, `ROX_API_TOKEN`, and `MCP_NAMESPACE` before applying.

### Setup Scripts

| Script | Description |
|--------|-------------|
| `install.sh` | Main deployment plus OpenShift Lightspeed integration validation |
| `test-mcp-server.sh` | Smoke test for deployment and `/health` route response |

## References

- [StackRox MCP GitHub](https://github.com/stackrox/stackrox-mcp) (commit [779f4a0](https://github.com/stackrox/stackrox-mcp/tree/779f4a0c1af4c4bfbe340a918f8f3c658e153538))
- [StackRox MCP Configuration](https://github.com/stackrox/stackrox-mcp#configuration)
