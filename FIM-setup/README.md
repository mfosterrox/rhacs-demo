# FIM (File Integrity Monitoring) Setup

This setup deploys a FIM policy to RHACS and triggers violations for demonstration.

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
./install-fim.sh
```

## What It Does

1. **Submits FIM policy** – Creates or updates the `FIM-basic-monitoring` policy in ACS that monitors:
   - `/etc/passwd` (any change)
   - `/etc/sudoers` (CREATE)
   - `/etc/sudoers.test` (CREATE) – used by the trigger loop

2. **Runs FIM trigger loop** – Uses `oc debug node/<worker>` to run a loop on a worker node that creates `/etc/sudoers.test` every ~60 seconds, triggering FIM violations in ACS.

## Manual Trigger (if auto-start fails)

```bash
# 1. Get a worker node name
oc get nodes -l node-role.kubernetes.io/worker

# 2. Debug into the node
oc debug node/<worker-node-name>

# 3. In the debug shell, run:
chroot /host

# 4. Paste and run the contents of fim-trigger-loop.sh
```

## Files

| File | Description |
|------|-------------|
| `fim-policy-basic.json` | FIM policy definition (monitors /etc/passwd, /etc/sudoers, /etc/sudoers.test) |
| `fim-trigger-loop.sh` | Loop script that creates /etc/sudoers.test every 60s |
| `install-fim.sh` | Main script – submits policy and starts trigger loop |

## View Violations

In RHACS UI: **Violations** → filter by policy **FIM-basic-monitoring**
