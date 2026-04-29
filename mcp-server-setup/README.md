# StackRox MCP Server Setup

Deploy the [StackRox MCP](https://github.com/stackrox/stackrox-mcp) server to provide AI assistants (e.g., Cursor, Claude Code) with access to RHACS/StackRox via the Model Context Protocol.

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
5. Validates OpenShift Lightspeed MCP wiring (when OLSConfig is present): feature gate, MCP URL/transport, auth header mode, route reachability, and Lightspeed readiness

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ROX_CENTRAL_ADDRESS` | Yes* | RHACS Central URL (e.g., `https://central-stackrox.apps.cluster.com`). Auto-detected from cluster route if not set. |
| `ROX_API_TOKEN` | Recommended | API token for Central. Run `basic-setup/install.sh` first to generate. Without it, MCP uses passthrough auth (client must send token). |
| `RHACS_NAMESPACE` | No | RHACS namespace (default: `stackrox`) |
| `MCP_NAMESPACE` | No | MCP server namespace (default: `stackrox-mcp`) |
| `MCP_ROUTE_HOST` | No | Custom Route hostname (default: auto-assigned) |
| `LIGHTSPEED_VALIDATE` | No | Validate OpenShift Lightspeed integration during install (`true` by default). |
| `LIGHTSPEED_NAMESPACE` | No | OpenShift Lightspeed namespace (default: `openshift-lightspeed`). |
| `LIGHTSPEED_OLSCONFIG_NAME` | No | OLSConfig name to inspect (default: `cluster`). |
| `LIGHTSPEED_MCP_SERVER_NAME` | No | MCP server entry name in OLSConfig (default: `stackrox-mcp`). |

## Connecting Cursor to the MCP Server

After deployment, the script prints the Route URL. Add it to Cursor:

```bash
# HTTP transport (when MCP server is accessible via URL)
claude mcp add stackrox --transport http --url https://stackrox-mcp-stackrox-mcp.apps.example.com
```

Or configure in Cursor settings (MCP servers). The MCP server supports HTTP transport for remote clients.

## OpenShift Lightspeed Integration

OpenShift Lightspeed being installed is not enough by itself; the `OLSConfig` must include MCP settings.

Required `OLSConfig` fields:
- `spec.featureGates` includes `MCPServer`
- `spec.mcpServers` contains a `stackrox-mcp` entry
- MCP URL should target the in-cluster endpoint: `http://stackrox-mcp.stackrox-mcp:8080/mcp`

The install script now checks for these fields and prints a patch example if they are missing.

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
| `deployment.yaml` | Deployment (2 replicas, quay.io/stackrox-io/mcp:latest) |
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
