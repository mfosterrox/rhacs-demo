# Virtual Machine Vulnerability Scanning

Automated setup for RHACS virtual machine vulnerability management with OpenShift Virtualization.

## Overview

RHACS can scan RHEL virtual machines for vulnerabilities using the roxagent binary and VSOCK communication.

## Prerequisites

- OpenShift cluster with admin access
- RHACS installed (run `basic-setup` first)
- OpenShift Virtualization operator installed
- `oc` CLI authenticated

## Quick Start

### Fully Automated Setup (NEW! ⚡)

**One command, complete demo with vulnerabilities in 15 minutes!**

```bash
cd virt-scanning

# 1. Configure credentials (one-time setup)
cp vm-config.env.example vm-config.env
vi vm-config.env  # Add your Red Hat subscription credentials

# 2. Run install
./install.sh

# That's it! Wait 15 minutes for complete setup with vulnerability data
```

**What happens automatically:**
1. ✅ Configure RHACS platform (Central, Sensor, Collector)
2. ✅ Enable VSOCK in OpenShift Virtualization  
3. ✅ Deploy 4 RHEL VMs with roxagent
4. ✅ **Auto-register VMs with Red Hat subscription**
5. ✅ **Auto-install DNF packages** (httpd, nginx, postgresql, etc.)
6. ✅ **Vulnerability data appears in RHACS automatically!**

📖 **See [AUTOMATED-SETUP.md](AUTOMATED-SETUP.md) for complete guide**

---

### Standard Setup (Without Package Installation)

Run without `vm-config.env` to deploy infrastructure only:

```bash
cd virt-scanning
./install.sh

# VMs will appear in RHACS but without packages/vulnerabilities
# Then optionally run: ./setup-demo-packages.sh to add packages
```

This will:
1. Configure RHACS platform (Central, Sensor, Collector) with ROX_VIRTUAL_MACHINES=true
2. Enable VSOCK in OpenShift Virtualization
3. Enable hostNetwork on Collector for VSOCK access
4. Deploy base RHEL VM with roxagent
5. Deploy 4 sample VMs (no packages installed)

### Manual Step-by-Step

Run the sub-scripts individually:

```bash
cd virt-scanning

# 1. Configure RHACS and enable VSOCK
./01-configure-rhacs.sh

# 2. Deploy base VM with roxagent (optional)
./02-deploy-base-vm.sh

# 3. Deploy 4 sample VMs with different packages (optional)
./03-deploy-sample-vms.sh
```

### Sample VMs for Demonstration

The `04-deploy-sample-vms.sh` script deploys 4 VMs with different DNF packages installed:

- **webserver**: Apache (httpd), Nginx, PHP - web server vulnerabilities
- **database**: PostgreSQL, MariaDB - database server packages  
- **devtools**: Git, GCC, Python, Node.js, Java - development tools
- **monitoring**: Grafana, Telegraf, Collectd - monitoring stack

Each VM automatically installs packages via DNF and runs roxagent for vulnerability scanning.

## What Gets Configured

### Platform (install.sh)
- Central: `ROX_VIRTUAL_MACHINES=true`
- Sensor: `ROX_VIRTUAL_MACHINES=true`
- Collector compliance container: `ROX_VIRTUAL_MACHINES=true`
- HyperConverged: VSOCK feature gate enabled

### VM Image (02-build-vm-image.sh)
- Creates Kubernetes Secret with cloud-init configuration
- Cloud-init downloads roxagent on first boot
- Installs systemd service for continuous scanning (5-minute intervals)
- Configures VSOCK environment variables

### VM Deployment (03-deploy-vm.sh)
- Deploys RHEL 9 VM with vsock enabled (`autoattachVSOCK: true`)
- Uses containerDisk for fast startup
- Attaches cloud-init for roxagent installation
- Configurable via environment variables

## Configuration Options

### Configuration Options

The install script runs fully automatically with no prompts. Control what gets deployed with environment variables:

```bash
# Default: configure RHACS + deploy both base VM and 4 sample VMs
./install.sh

# Deploy only sample VMs (skip base VM)
DEPLOY_BASE_VM=false ./install.sh

# Deploy only base VM (skip sample VMs)
DEPLOY_SAMPLE_VMS=false ./install.sh

# Only configure RHACS (no VMs)
DEPLOY_BASE_VM=false DEPLOY_SAMPLE_VMS=false ./install.sh
```

### Individual VM Deployment Options

Customize VM deployment with environment variables:

```bash
# Example: Deploy larger VM with custom name
VM_NAME="security-scan-vm" VM_CPUS=4 VM_MEMORY=8Gi ./03-deploy-vm.sh

# Available variables:
# - NAMESPACE (default: default)
# - VM_NAME (default: rhel-roxagent-vm)
# - VM_CPUS (default: 2)
# - VM_MEMORY (default: 4Gi)
# - VM_DISK_SIZE (default: 30Gi)
# - STORAGE_CLASS (default: auto-detected)
# - RHEL_IMAGE (default: registry.redhat.io/rhel9/rhel-guest-image:latest)
```

## Verification

### Check environment is ready
```bash
./01-check-env.sh
```

### Access VM and verify roxagent
```bash
# Console access
virtctl console rhel-roxagent-vm -n default

# Inside VM - check roxagent service
systemctl status roxagent
journalctl -u roxagent -f

# Check roxagent logs for scan results
journalctl -u roxagent --since "5 minutes ago"
```

### Verify vsock configuration
```bash
# Check VM has vsock enabled
oc get vm rhel-roxagent-vm -n default -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}'
# Should return: true

# Check VSOCK CID assigned
oc get vmi rhel-roxagent-vm -n default -o jsonpath='{.status.VSOCKCID}'
# Should return a number like: 123
```

### Check RHACS integration
```bash
# View VMs in RHACS (requires UI or API access)
# Platform Configuration → Clusters → Virtual Machines
```

## Expected Timeline

- **0-1 min**: VM boots
- **1-3 min**: Cloud-init downloads and installs roxagent
- **3-5 min**: First vulnerability scan completes
- **5+ min**: Vulnerabilities appear in RHACS UI

## VM Requirements

VMs deployed by these scripts automatically meet requirements:

1. ✅ Run RHEL 9
2. ✅ Have vsock enabled
3. ✅ Run roxagent in daemon mode
4. ⚠️ **Must have valid RHEL subscription** (configure inside VM)
5. ✅ Have network access (for roxagent download and CPE mappings)

### Activating RHEL Subscription (Required)

After VM boots, activate RHEL:

```bash
# Inside VM console
subscription-manager register --username <rh-username> --password <rh-password>
subscription-manager attach --auto

# Verify
subscription-manager status
```

## Files

### Core Workflow Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | **Main script** - orchestrates complete setup |
| `01-configure-rhacs.sh` | Configure RHACS components and enable VSOCK |
| `02-deploy-base-vm.sh` | Deploy single VM with roxagent |
| `03-deploy-sample-vms.sh` | Deploy 4 demo VMs with different DNF packages |

### Reference Files

| File | Purpose |
|------|---------|
| `vm-template-rhacm.yaml` | Complete VM template for manual RHACM deployment |

## Understanding DNF Package Scanning

**Important**: RHACS only scans vulnerabilities in DNF packages from Red Hat repositories.

- ✅ **Scanned**: Packages installed via `dnf install` (tracked in DNF database)
- ❌ **Not scanned**: System packages pre-installed in the VM image
- ❌ **Not scanned**: Manually compiled binaries or tarballs

### Why DNF packages matter

The `04-deploy-sample-vms.sh` script uses cloud-init to install packages via DNF:

```bash
# Inside cloud-init
packages:
  - httpd
  - nginx
  - postgresql
```

This ensures RHACS can detect and report vulnerabilities. Pre-installed system packages are not tracked by the DNF database and won't appear in vulnerability reports.

## Troubleshooting

### VM not starting

```bash
# Check VM status
oc get vm rhel-roxagent-vm -n default
oc get vmi rhel-roxagent-vm -n default

# Check events
oc get events -n default | grep rhel-roxagent-vm
```

### roxagent not running

```bash
# Inside VM
systemctl status roxagent

# Check cloud-init logs
cloud-init status
tail -f /var/log/cloud-init-output.log

# Manually trigger scan
/opt/roxagent/roxagent --verbose
```

### VSOCK not enabled

```bash
# Verify VSOCK feature gate
oc get kubevirt kubevirt-kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' | grep VSOCK

# Re-run platform configuration
./install.sh
```

### VMs not appearing in RHACS

1. Verify feature flags on RHACS components:
   ```bash
   oc get deployment central -n stackrox \
     -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'
   ```

2. Check Collector logs:
   ```bash
   oc logs -n stackrox daemonset/collector -c compliance | grep -i "virtual\|vsock"
   ```

3. Verify RHEL subscription inside VM

## Architecture

```
┌─────────────────────────────────────┐
│ RHACS Central/Sensor/Collector      │
│ ROX_VIRTUAL_MACHINES=true           │
└───────────────┬─────────────────────┘
                │
                │ VSOCK (port 818)
                │
┌───────────────▼─────────────────────┐
│ RHEL VM                             │
│ - vsock enabled                     │
│ - roxagent daemon (5min scans)      │
│ - Reports vulnerabilities to RHACS  │
└─────────────────────────────────────┘
```

## References

- [RHACS VM Scanning Docs](https://docs.openshift.com/acs/)
- [OpenShift Virtualization](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
- [KubeVirt VSOCK](https://kubevirt.io/user-guide/virtual_machines/vsock/)
- [roxagent Downloads](https://mirror.openshift.com/pub/rhacs/assets/)
