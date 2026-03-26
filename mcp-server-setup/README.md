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
5. **If OpenShift Lightspeed is installed:** configures MCP integration automatically

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `ROX_CENTRAL_ADDRESS` | Yes* | RHACS Central URL (e.g., `https://central-stackrox.apps.cluster.com`). Auto-detected from cluster route if not set. |
| `ROX_API_TOKEN` | Recommended | API token for Central. Run `basic-setup/install.sh` first to generate. Without it, MCP uses passthrough auth (client must send token). |
| `RHACS_NAMESPACE` | No | RHACS namespace (default: `stackrox`) |
| `MCP_NAMESPACE` | No | MCP server namespace (default: `stackrox-mcp`) |
| `MCP_ROUTE_HOST` | No | Custom Route hostname (default: auto-assigned) |

## Connecting Cursor to the MCP Server

After deployment, the script prints the Route URL. Add it to Cursor:

```bash
# HTTP transport (when MCP server is accessible via URL)
claude mcp add stackrox --transport http --url https://stackrox-mcp-stackrox-mcp.apps.example.com
```

Or configure in Cursor settings (MCP servers). The MCP server supports HTTP transport for remote clients.

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
```

## OpenShift Lightspeed Integration

When OpenShift Lightspeed is installed and `ROX_API_TOKEN` is set, the install script automatically configures the integration:

1. Creates `stackrox-mcp-authorization-header` secret in `openshift-lightspeed` namespace
2. Patches `OLSConfig` to add `MCPServer` feature gate and StackRox MCP server

**Prerequisites:**
- OpenShift Lightspeed installed (`./lightspeed-setup/install.sh`)
- OLSConfig created with LLM provider
- `ROX_API_TOKEN` set (run `basic-setup/install.sh` first)

**Manual configuration** (if install.sh skips it):

```bash
./mcp-server-setup/02-configure-lightspeed-integration.sh
```

**Test:** In OpenShift Lightspeed, try: *"List all clusters secured by StackRox"*

Based on [StackRox MCP OpenShift Lightspeed Integration Guide](https://github.com/stackrox/stackrox-mcp) (tested with Lightspeed 1.0.8).

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
| `install.sh` | Main deployment + optional Lightspeed integration |
| `02-configure-lightspeed-integration.sh` | Configure StackRox MCP in OpenShift Lightspeed OLSConfig |

## References

- [StackRox MCP GitHub](https://github.com/stackrox/stackrox-mcp) (commit [779f4a0](https://github.com/stackrox/stackrox-mcp/tree/779f4a0c1af4c4bfbe340a918f8f3c658e153538))
- [StackRox MCP Configuration](https://github.com/stackrox/stackrox-mcp#configuration)
