# Cloud-init and VM Manifests for RHACS VM Scanning Demo

Standalone cloud-init userdata and VirtualMachine manifests for deploying sample VMs used in the RHACS VM scanning demo. These files mirror what `02-deploy-sample-vms.sh` generates.

## Contents

| File | Description |
|------|-------------|
| `cloud-init-userdata-webserver.yaml` | Cloud-init for Web Server VM (Apache, Nginx, PHP) |
| `cloud-init-userdata-database.yaml` | Cloud-init for Database VM (PostgreSQL, MariaDB) |
| `cloud-init-userdata-devtools.yaml` | Cloud-init for Dev Tools VM (Git, GCC, Python, Node.js, Java) |
| `cloud-init-userdata-monitoring.yaml` | Cloud-init for Monitoring VM (Grafana, Telegraf, Collectd) |
| `vm-webserver.yaml` | VirtualMachine manifest for webserver |
| `vm-database.yaml` | VirtualMachine manifest for database |
| `vm-devtools.yaml` | VirtualMachine manifest for devtools |
| `vm-monitoring.yaml` | VirtualMachine manifest for monitoring |

## Prerequisites

- OpenShift cluster with OpenShift Virtualization installed
- VSOCK enabled (see `install.sh`)
- RHACS configured for VM scanning (see `01-configure-rhacs.sh`)
- `oc` logged in with cluster-admin or sufficient permissions

## Quick Start

### 1. Create namespace (optional)

```bash
export NAMESPACE=default  # or your preferred namespace
oc create namespace $NAMESPACE
```

### 2. Create cloud-init secrets

```bash
cd virt-scanning-setup/cloud-init

oc create secret generic cloudinit-webserver \
  --from-file=userdata=cloud-init-userdata-webserver.yaml \
  -n $NAMESPACE

oc create secret generic cloudinit-database \
  --from-file=userdata=cloud-init-userdata-database.yaml \
  -n $NAMESPACE

oc create secret generic cloudinit-devtools \
  --from-file=userdata=cloud-init-userdata-devtools.yaml \
  -n $NAMESPACE

oc create secret generic cloudinit-monitoring \
  --from-file=userdata=cloud-init-userdata-monitoring.yaml \
  -n $NAMESPACE
```

### 3. Apply VM manifests

If using a non-default namespace, update the `namespace` field in each VM YAML or use `oc apply -f` with `-n`:

```bash
# Option A: Apply with namespace override
oc apply -f vm-webserver.yaml -n $NAMESPACE
oc apply -f vm-database.yaml -n $NAMESPACE
oc apply -f vm-devtools.yaml -n $NAMESPACE
oc apply -f vm-monitoring.yaml -n $NAMESPACE

# Option B: Edit namespace in files first, then apply
sed -i "s/namespace: default/namespace: $NAMESPACE/g" vm-*.yaml
oc apply -f vm-webserver.yaml -f vm-database.yaml -f vm-devtools.yaml -f vm-monitoring.yaml
```

## Customization

### SSH keys for virtctl ssh (required)

VMs use **key-based auth only** (no password). You must inject your bastion's SSH public key before creating secrets.

**Option A – Edit the file:** Replace `REPLACE_WITH_YOUR_SSH_PUBLIC_KEY` in each cloud-init file with your public key content.

**Option B – Inject via sed when creating the secret:**

```bash
sed "s|REPLACE_WITH_YOUR_SSH_PUBLIC_KEY|$(cat ~/.ssh/id_ed25519.pub)|" cloud-init-userdata-webserver.yaml | \
  oc create secret generic cloudinit-webserver --from-file=userdata=/dev/stdin -n $NAMESPACE
```

### RHEL subscription

The cloud-init files install the roxagent and create `/root/install-packages.sh`. Package installation requires RHEL subscription. Options:

1. **Use the deploy script** (`02-deploy-sample-vms.sh`) with `RHEL_USERNAME`/`RHEL_PASSWORD` or `RHEL_ORG`/`RHEL_ACTIVATION_KEY` to inject subscription registration into cloud-init.
2. **Manual**: After VM boots, log in via console, register with `subscription-manager`, then run `/root/install-packages.sh`.

### VM resources

Edit the VM manifests to change:

- `spec.template.spec.domain.cpu.cores` (default: 2)
- `spec.template.spec.resources.requests.memory` (default: 4Gi)
- `spec.template.spec.volumes[0].containerDisk.image` (default: `registry.redhat.io/rhel9/rhel-guest-image:latest`)

## Accessing VMs

- **Console**: OpenShift Console → Workloads → Virtualization → VirtualMachines → select VM → Console
- **SSH** (if keys injected): `virtctl ssh cloud-user@vmi/rhel-webserver -n $NAMESPACE` (KubeVirt v1.6+ syntax)

## Relationship to 02-deploy-sample-vms.sh

The deploy script generates equivalent cloud-init dynamically (including optional subscription and SSH keys) and applies the same VM structure. These standalone files are useful when:

- You want to review or modify cloud-init before deployment
- You prefer GitOps / declarative manifests
- You need to deploy without running the bash script
