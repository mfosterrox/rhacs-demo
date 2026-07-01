# Project Hummingbird demo (RHACS 4.11)

Canonical source for this demo lives in **[demo-applications](https://github.com/mfosterrox/demo-applications)**:

| Path | Purpose |
|------|---------|
| `image-builds/hi-python-demo/` | Multi-stage Dockerfile (HI builder → HI runtime) |
| `k8s-deployment-manifests/hummingbird-demo/` | Namespace, base deployment, BuildConfig, layered deployment, route |

## Deploy with the rest of the demo apps

```bash
# Applies all demo-applications manifests (including hummingbird-demo) and builds the layered image
bash basic-setup/04-deploy-applications.sh

# Or run the Hummingbird-specific script (re-applies manifests, builds, registers base image in RHACS)
bash basic-setup/09-deploy-hummingbird-demo.sh
```

## What gets deployed

| Workload | Image | Purpose |
|----------|-------|---------|
| `hi-python-base` | `registry.access.redhat.com/hi/python:3.13` | Base hardened image only |
| `hi-python-layered` | Built `ImageStreamTag` `hi-python-demo:latest` | App layer on top of HI base |

After deploy, open **RHACS → Vulnerability Management → Workloads** and filter namespace `hummingbird-demo` to compare base vs layered CVEs.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEMO_APPS_DIR` | `~/demo-applications` | Clone location for demo-applications |
| `HUMMINGBIRD_NAMESPACE` | `hummingbird-demo` | Target namespace |
| `HUMMINGBIRD_BUILD_ON_CLUSTER` | `1` | Run `oc start-build` from `image-builds/hi-python-demo` |
| `SKIP_HUMMINGBIRD_DEMO` | `0` | Skip script 09 |
| `SKIP_HUMMINGBIRD_BUILD` | `0` | Skip build step in script 04 |

## Local image build (optional)

```bash
cd ~/demo-applications
make build COMPONENT=hi-python-demo
```

## References

- [Project Hummingbird docs](https://hummingbird-project.io/docs/using/overview/)
- [Red Hat Hardened Images](https://catalog.redhat.com/software/containers/explore?search=hardened)
