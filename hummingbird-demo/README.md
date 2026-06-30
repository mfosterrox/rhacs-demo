# Project Hummingbird (Red Hat Hardened Images) Demo

Demonstrates RHACS 4.11 hardened image scanning with VEX metadata and base vs application layer separation.

## Workloads

| Deployment | Image | Purpose |
|------------|-------|---------|
| `hi-python-base` | `registry.access.redhat.com/hi/python:3.13` | Scan hardened base only |
| `hi-python-layered` | Built from `Dockerfile` (HI Python + Flask app layer) | Compare app-layer CVEs on trusted base |

## Setup

Run via `basic-setup/install.sh` (script 09) or standalone:

```bash
export ROX_API_TOKEN='...'
bash basic-setup/09-deploy-hummingbird-demo.sh
```

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HUMMINGBIRD_NAMESPACE` | `hummingbird-demo` | Target namespace |
| `HI_BASE_IMAGE` | `registry.access.redhat.com/hi/python:3.13` | Base hardened image |
| `HI_LAYERED_IMAGE` | _(built in-cluster)_ | Override with pre-built layered image |
| `SKIP_HUMMINGBIRD_DEMO` | `0` | Set to `1` to skip |
| `HUMMINGBIRD_BUILD_ON_CLUSTER` | `1` | Binary build from this directory |

## Tekton pipeline

```bash
tkn pipeline start rox-hi-pipeline -n pipeline-demo
```

## References

- [Project Hummingbird docs](https://hummingbird-project.io/docs/using/overview/)
- [RHACS 4.11 release notes — hardened image scanning](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/release_notes/release-notes-411)
