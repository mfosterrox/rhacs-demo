# FAM (File Activity Monitoring) Setup

This setup enables file activity monitoring on the SecuredCluster, submits FAM policies to RHACS via the API, and documents how to trigger violations for demonstration.

## Prerequisites

- OpenShift cluster with RHACS (ACS) installed
- `oc` logged in
- `ROX_API_TOKEN` set (from basic-setup or RHACS UI → Platform Configuration → Integrations → API Token)
- `jq` installed

## Quick Start

```bash
# Set credentials (if not in ~/.bashrc)
export ROX_API_TOKEN='your-api-token'
# ROX_CENTRAL_URL is auto-detected from cluster route

# Run the install script
./install.sh
```

After policies and the default-namespace CronJob, **`install.sh` step 4** runs **`oc exec`** into **`deployment/mastercard-processor`** in namespace **`payments`** (if that object exists) and runs **`touch /etc/passwd`** so **fam-basic-deploy-monitoring** can fire without manual exec.

- Skip that step: `FAM_SKIP_WORKLOAD_EXEC=1 ./install.sh`
- Point at another workload: `FAM_EXEC_NAMESPACE=myproject FAM_EXEC_WORKLOAD=deployment/myapp ./install.sh`
- Multi-container pods: `FAM_EXEC_CONTAINER=app ./install.sh`

## What It Does

1. **Enables file activity monitoring** – Patches the SecuredCluster so `fileActivityMonitoring.mode` is `Enabled`.
2. **Submits FAM policies** – Creates or updates:
   - `fam-basic-node-monitoring` – monitors `/etc/passwd` for node-level modifications (NODE_EVENT)
   - `fam-basic-deploy-monitoring` – monitors deployments for changes to `/etc/passwd`
3. **Applies a demo CronJob** – `fam-cron-alert.yaml` creates `rhacs-fam-trigger`, which periodically runs commands that touch/read `/etc/passwd` inside a **CronJob pod** in `default` (good for quick checks; RHACS may attribute this differently than your app).

4. **Optional one-shot `oc exec`** – If **`deployment/mastercard-processor`** exists in **`payments`**, runs `touch /etc/passwd` in that pod for a **deploy**-scoped FAM demo (overridable / skippable via env; see Quick Start).

### CronJob that execs into your app (DEPLOYMENT_EVENT demos)

For alerts like **fam-basic-deploy-monitoring** on a real workload (for example `deployment/mastercard-processor` in project `payments`), apply **`fam-cron-exec-target.yaml`** after editing namespaces and env to match your cluster:

```bash
# Edit all `namespace: payments` fields and CronJob env (TARGET_*) if needed, then:
oc apply -f fam-cron-exec-target.yaml
```

That CronJob runs `oc exec` into the target workload and runs `touch /etc/passwd` **inside that container** every 10 minutes (requires pulls for `registry.redhat.io/openshift4/ose-cli-rhel9`).

## Trigger violations (run after install)

```bash
# 1. Start a debug session on a worker node
oc debug node/<worker-node-name>

# 2. Inside the debug pod, run:
chroot /host
touch /etc/passwd    # Triggers fam-basic-node-monitoring
```

## Note on Policy-as-Code

These policies use `eventSource: NODE_EVENT` (node-level) or `DEPLOYMENT_EVENT` (deployment-level). The SecurityPolicy CR only supports `NOT_APPLICABLE`, `DEPLOYMENT_EVENT`, and `AUDIT_LOG_EVENT`. Policies that rely on node-level file activity must be submitted via the RHACS API (as this script does).

## Files

| File | Description |
|------|-------------|
| `fam-basic-node-monitoring.json` | FAM policy for node events (submitted via API) |
| `fam-basic-deploy-monitoring.json` | FAM policy for deployment events (submitted via API) |
| `fam-cron-alert.yaml` | CronJob `rhacs-fam-trigger` – periodic trigger inside a dedicated pod (`install.sh`) |
| `fam-cron-exec-target.yaml` | SA + Role + CronJob `rhacs-fam-exec-trigger` – `oc exec` into a chosen deployment/pod (`oc apply` manually after editing NS/target) |
| `install.sh` | Main script – enables file activity monitoring, submits policies, applies `fam-cron-alert.yaml`, prints manual trigger steps |

## View violations

In RHACS UI: **Violations** → filter by policy **fam-basic-node-monitoring**

### Renaming from older demos

If you previously installed policies named `fim-basic-*`, those remain in Central until removed. This repo now ships **`fam-basic-*`** policy names and files; run `install.sh` to create or update the new policies.
