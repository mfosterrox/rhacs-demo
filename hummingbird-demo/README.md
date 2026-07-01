# Project Hummingbird demo (RHACS 4.11)

Canonical source lives in **[demo-applications](https://github.com/mfosterrox/demo-applications)**:

| Path | Purpose |
|------|---------|
| `image-builds/hi-python-demo/` | Multi-stage Dockerfile (HI builder → HI runtime) |
| `k8s-deployment-manifests/hummingbird-demo/` | Base + layered deployments, service, route |

## Deploy

Hummingbird deploys with the rest of the demo applications (script 04):

```bash
bash basic-setup/04-deploy-applications.sh
bash basic-setup/09-deploy-hummingbird-demo.sh   # RHACS base image registration + UI guidance
```

Build and push the layered image from demo-applications (same as other demo apps):

```bash
cd demo-applications
make build COMPONENT=hi-python-demo
make push-images   # or your usual push target
```

## Workloads

| Deployment | Image | Purpose |
|------------|-------|---------|
| `hi-python-base` | `registry.access.redhat.com/hi/python:3.13` | Base hardened image only |
| `hi-python-layered` | `quay.io/mfoster/hi-python-demo:0.1.0` | App layer on HI base |

View in **RHACS → Vulnerability Management → Workloads** → namespace `hummingbird-demo`.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `HI_LAYERED_IMAGE` | `quay.io/mfoster/hi-python-demo:0.1.0` | Shown in script 09 guidance |
| `HUMMINGBIRD_NAMESPACE` | `hummingbird-demo` | Target namespace |
| `SKIP_HUMMINGBIRD_DEMO` | `0` | Skip script 09 |

## References

- [Project Hummingbird docs](https://hummingbird-project.io/docs/using/overview/)
