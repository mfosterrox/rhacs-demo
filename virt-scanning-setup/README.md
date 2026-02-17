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

### One-Command Setup ⚡

```bash
cd virt-scanning
./install.sh
```

The script will:
1. **Prompt for your Red Hat subscription credentials**
2. Configure RHACS for VM scanning
3. Deploy 4 RHEL VMs with roxagent
4. **Automatically register VMs and install packages**
5. Start vulnerability scanning

**Time:** ~15 minutes for complete setup with vulnerability data

**What you get:**
- ✅ 4 VMs running with roxagent
- ✅ Packages automatically installed (httpd, nginx, postgresql, etc.)
- ✅ **Vulnerability data in RHACS immediately!**

📖 **See [DEMO-SETUP.md](DEMO-SETUP.md) for demo guide**

---

### What Happens Automatically

1. **RHACS Configuration:**
   - Feature flags enabled (Central, Sensor, Collector)
   - VSOCK enabled in OpenShift Virtualization
   - Collector configured for VSOCK communication

2. **VM Deployment:**
   - 4 RHEL VMs created (webserver, database, devtools, monitoring)
   - Cloud-init registers with Red Hat subscription
   - Packages installed via DNF automatically
   - roxagent starts scanning

3. **Vulnerability Scanning:**
   - roxagent scans packages every 5 minutes
   - Reports sent to RHACS via VSOCK
   - CVE data appears in RHACS UI

### Manual Step-by-Step

Run the sub-scripts individually:

```bash
cd virt-scanning-setup

# 1. Configure RHACS and enable VSOCK
./01-configure-rhacs.sh

# 2. Deploy 4 sample VMs with automatic subscription registration
./02-deploy-sample-vms.sh --username USER --password PASS

# OR with activation key
./02-deploy-sample-vms.sh --org ORG --activation-key KEY

# OR without subscription (manual registration required)
./02-deploy-sample-vms.sh --skip-subscription

# 3. Verify environment (optional)
./verify-env.sh
```

### Sample VMs for Demonstration

The `02-deploy-sample-vms.sh` script deploys 4 VMs with automatic subscription registration and package installation via cloud-init:

- **webserver**: Apache (httpd), Nginx, PHP - web server vulnerabilities
- **database**: PostgreSQL, MariaDB - database server packages  
- **devtools**: Git, GCC, Python, Node.js, Java - development tools
- **monitoring**: Grafana, Telegraf, Collectd - monitoring stack

When subscription credentials are provided, cloud-init automatically:
1. Registers the VM with Red Hat subscription-manager
2. Installs profile-specific packages
3. Restarts roxagent to scan new packages

Result: Vulnerability data appears in RHACS within 10 minutes!

## What Gets Configured

### RHACS Configuration (01-configure-rhacs.sh)
- Central: `ROX_VIRTUAL_MACHINES=true`
- Sensor: `ROX_VIRTUAL_MACHINES=true`
- Collector compliance container: `ROX_VIRTUAL_MACHINES=true`
- HyperConverged: VSOCK feature gate enabled

### VM Deployment (02-deploy-sample-vms.sh)
- Deploys 4 RHEL 9 VMs with vsock enabled (`autoattachVSOCK: true`)
- Uses containerDisk for fast startup
- Cloud-init downloads and configures roxagent
- Installs systemd service for continuous scanning (5-minute intervals)
- Creates helper script at `/root/install-packages.sh` for package installation

### VM Subscription & Packages (cloud-init)
Subscription registration and package installation happen automatically during VM first boot via cloud-init's `rh_subscription` module:

**Automatic (recommended):**
```bash
# Deploy with username/password
./02-deploy-sample-vms.sh --username myuser --password mypass

# Deploy with activation key
./02-deploy-sample-vms.sh --org 12345678 --activation-key my-key
```

**What happens on first boot:**
1. cloud-init registers VM with Red Hat subscription-manager
2. Packages install automatically based on VM profile
3. roxagent starts and begins scanning
4. Vulnerability data appears in RHACS within 10 minutes

**Manual (if deployed without subscription):**
```bash
# Deploy without subscription
./02-deploy-sample-vms.sh --skip-subscription

# Then inside each VM console:
sudo subscription-manager register --username USER --password PASS --auto-attach
sudo /root/install-packages.sh
```

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
4. ⚠️ **Must have valid RHEL subscription** (automated via cloud-init)
5. ✅ Have network access (for roxagent download and CPE mappings)

### Activating RHEL Subscription (Automated via cloud-init)

**Best approach: Provide credentials during VM deployment**

```bash
# Subscription registers automatically on first boot
./02-deploy-sample-vms.sh --username USER --password PASS

# Or with activation key
./02-deploy-sample-vms.sh --org ORG --activation-key KEY
```

**Alternative: Manual registration inside VM**

```bash
# If VMs were deployed without subscription
virtctl console rhel-webserver -n default
sudo subscription-manager register --username <rh-username> --password <rh-password> --auto-attach
sudo /root/install-packages.sh
```

## Files

### Core Workflow Scripts

| Script | Purpose |
|--------|---------|
| `install.sh` | **Main script** - orchestrates complete setup with subscription prompts |
| `01-configure-rhacs.sh` | Configure RHACS components and enable VSOCK |
| `02-deploy-sample-vms.sh` | Deploy 4 demo VMs with automatic subscription registration via cloud-init |
| `verify-env.sh` | Verify RHACS VM scanning environment |

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

When subscription credentials are provided, cloud-init automatically installs packages via DNF:

```yaml
# Inside cloud-init
rh_subscription:
  username: "user"
  password: "pass"
  auto-attach: true

runcmd:
  - dnf install -y httpd nginx postgresql mariadb
  - systemctl restart roxagent
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

### Collector → Sensor connectivity issues

**Symptoms**: Collector logs show `i/o timeout` or `connection refused` when trying to reach sensor:
```
virtualmachines/relay: Error sending index report to sensor: 
  rpc error: code = Unavailable desc = connection error: 
  desc = "transport: Error while dialing: dial tcp 172.231.132.191:443: i/o timeout"
```

**Root Cause**: When collector uses `hostNetwork: true` (required for VSOCK access), it may not be able to reach ClusterIP services depending on the CNI configuration.

**Solution**: The configure script automatically:
1. Configures sensor with `hostPort: 8443` so it's reachable from host network
2. Updates collector to reach sensor via `localhost:8443`

To apply the fix:
```bash
./01-configure-rhacs.sh
```

**Verify the fix**:
```bash
# Check sensor hostPort
oc get deployment sensor -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[0].ports[?(@.name=="api")]}'

# Check collector endpoint configuration
oc get daemonset collector -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="GRPC_SERVER")].value}'

# Should show: localhost:8443

# Check collector logs for successful connections
COLLECTOR_POD=$(oc get pods -n stackrox -l app=collector -o jsonpath='{.items[0].metadata.name}')
oc logs $COLLECTOR_POD -n stackrox -c compliance --tail=50 | grep "Handling vsock connection"
```

### Comprehensive environment check

Run the automated check script to verify all configuration:
```bash
./01-check-env.sh
```

This will verify:
- ✓ RHACS components running
- ✓ Feature flags configured
- ✓ Collector networking (hostNetwork, dnsPolicy)
- ✓ Sensor hostPort configuration
- ✓ Collector → Sensor connectivity
- ✓ VSOCK connections from VMs

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

sudo subscription-manager register --username mfoster@redhat.com --password '_.vLx4eVbKde!_ARpprJ' --auto-attach
sudo subscription-manager repos --enable rhel-9-for-x86_64-baseos-rpms --enable rhel-9-for-x86_64-appstream-rpms
sudo dnf install -y httpd nginx php
sudo systemctl restart roxagent