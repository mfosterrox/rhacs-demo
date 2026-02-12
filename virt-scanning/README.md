# Virtual Machine Vulnerability Scanning Setup

This folder contains automated scripts for configuring Red Hat Advanced Cluster Security (RHACS) for virtual machine vulnerability management and deploying RHEL VMs with roxagent.

## Overview

RHACS can scan virtual machines running on OpenShift Virtualization for vulnerabilities. This requires:
1. RHACS platform configuration (feature flags, vsock support)
2. RHEL VMs with roxagent binary running inside
3. Proper network and subscription configuration

## Prerequisites

- OpenShift cluster with admin access
- RHACS installed (from basic-setup)
- OpenShift Virtualization operator installed
- `oc` CLI configured and authenticated

## Quick Start - Automated Workflow

Run the scripts in order for fully automated setup:

```bash
cd virt-scanning

# 1. Check prerequisites
./01-check-env.sh

# 2. Configure RHACS platform
./install.sh

# 3. Prepare VM image (cloud-init recommended)
./02-build-vm-image.sh

# 4. Deploy VM
./03-deploy-vm.sh
```

That's it! Your VM will automatically install roxagent on first boot and start scanning.

## Scripts

### Main Workflow (Run in Order)

#### `01-check-env.sh`

**Purpose:** Verify prerequisites before starting

Checks all 9 requirements for VM vulnerability scanning:
- ✓ Central deployment has `ROX_VIRTUAL_MACHINES=true`
- ✓ Sensor deployment has `ROX_VIRTUAL_MACHINES=true`
- ✓ Collector compliance container has `ROX_VIRTUAL_MACHINES=true`
- ✓ OpenShift Virtualization operator is installed
- ✓ HyperConverged resource has vsock support enabled
- ✓ Virtual machines have vsock configured
- ✓ VMs are running RHEL
- ⚠ VM network access (manual check)
- ✓ Metal nodes available (recommended)

**Usage:**
```bash
./01-check-env.sh
```

#### `install.sh`

**Purpose:** Configure RHACS and OpenShift platform

Configures the environment for VM vulnerability scanning:
1. Adds `ROX_VIRTUAL_MACHINES=true` to Central, Sensor, and Collector
2. Patches HyperConverged resource to enable vsock support
3. Provides VM configuration guidance

**Usage:**
```bash
./install.sh
```

#### `02-build-vm-image.sh`

**Purpose:** Prepare VM image with roxagent

**Automated workflow** that handles image preparation:
- **Cloud-init method (recommended)**: Creates Kubernetes Secret with roxagent configuration - no image building needed!
- **Custom image method**: Guides through building QCOW2 with pre-installed roxagent

**What it does:**
- Downloads roxagent from Red Hat mirror (v4.9.2)
- Creates systemd service for daemon mode (5-minute scan intervals)
- Configures environment variables (VSOCK port 818, 16KB max)
- Creates cloud-init Secret in cluster

**Usage:**
```bash
./02-build-vm-image.sh
# Select: 1 for cloud-init (recommended) or 2 for custom QCOW2
```

#### `03-deploy-vm.sh`

**Purpose:** Deploy VM to OpenShift cluster

**Fully automated deployment** that:
1. Creates DataVolume from RHEL base image
2. Deploys VM with vsock enabled
3. Attaches cloud-init configuration
4. Verifies deployment
5. Displays access information

**Configuration options** (environment variables):
```bash
export NAMESPACE="default"          # Target namespace
export VM_NAME="rhel-roxagent-vm"   # VM name
export VM_CPUS="2"                  # CPU cores
export VM_MEMORY="4Gi"              # Memory
export VM_DISK_SIZE="30Gi"          # Disk size
export STORAGE_CLASS="ocs-storagecluster-ceph-rbd"
export RHEL_IMAGE="registry.redhat.io/rhel9/rhel-guest-image:latest"
```

**Usage:**
```bash
# Use defaults
./03-deploy-vm.sh

# Or customize
VM_NAME="my-rhel-vm" VM_CPUS=4 VM_MEMORY=8Gi ./03-deploy-vm.sh
```

### Reference Files

#### `cloud-init-roxagent.yaml`

Standalone cloud-init configuration (for reference). The `02-build-vm-image.sh` script uses this automatically.

#### `vm-template-rhacm.yaml`

Complete VM template for manual RHACM deployment. Use the automated scripts instead for easier deployment.

#### `build-custom-image.sh`

Advanced script for building custom QCOW2 images. Called automatically by `02-build-vm-image.sh` when custom method is selected.

#### `IMAGE-BUILD-GUIDE.md`

Comprehensive reference guide covering manual and alternative approaches. Useful for understanding different options but **not needed for the automated workflow**.

## What Gets Configured

### Platform Configuration (install.sh)
- Central deployment: `ROX_VIRTUAL_MACHINES=true`
- Sensor deployment: `ROX_VIRTUAL_MACHINES=true`
- Collector daemonset compliance container: `ROX_VIRTUAL_MACHINES=true`
- HyperConverged resource: vsock feature gate enabled

### VM Configuration (03-deploy-vm.sh)
Each deployed VM includes:
- **vsock enabled**: `autoattachVSOCK: true` (required for RHACS communication)
- **Cloud-init configuration**: Downloads and installs roxagent on first boot
- **Systemd service**: Runs roxagent in daemon mode with 5-minute scan intervals
- **Environment variables**: VSOCK port 818, 16KB max connection size
- **Auto-start**: roxagent starts automatically on boot

## Architecture

### Automated Workflow
```
┌─────────────────────────────────────────────────┐
│ 1. Check Prerequisites (01-check-env.sh)        │
│    - Verify operators, feature flags, vsock     │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│ 2. Configure Platform (install.sh)              │
│    - Enable ROX_VIRTUAL_MACHINES on RHACS       │
│    - Enable vsock on HyperConverged             │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│ 3. Prepare Image (02-build-vm-image.sh)         │
│    - Cloud-init: Create K8s Secret              │
│    - Custom: Build QCOW2 with roxagent          │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│ 4. Deploy VM (03-deploy-vm.sh)                  │
│    - Create DataVolume + VM                     │
│    - Auto-install roxagent via cloud-init       │
│    - Start continuous scanning                  │
└─────────────────────────────────────────────────┘
```

### VM Requirements

VMs deployed by these scripts automatically meet requirements:

1. ✅ **Run Red Hat Enterprise Linux (RHEL)** - Uses RHEL 9 guest image
2. ⚠ **Have valid RHEL subscription** - Must be configured by user
3. ✅ **Have network access** - For roxagent download and CPE mappings
4. ✅ **Have vsock enabled** - Automatically set by deployment script
5. ✅ **Run roxagent binary** - Installed via cloud-init on first boot

## Infrastructure Recommendations

- **Metal nodes** are recommended to host VMs for optimal performance
- VMs can run on standard nodes but may experience performance degradation

## Verification

### After Deployment

```bash
# 1. Check environment is fully configured
./01-check-env.sh

# 2. Access VM console
virtctl console rhel-roxagent-vm -n default

# 3. Inside VM, check roxagent service
systemctl status roxagent
journalctl -u roxagent -f

# 4. Verify vsock configuration
oc get vm rhel-roxagent-vm -n default -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}'
# Expected: true

# 5. Check RHACS sees the VM
oc logs -n stackrox deployment/central | grep -i "virtual machine"
```

### Expected Timeline
- **0-2 minutes**: VM boots, cloud-init starts
- **2-3 minutes**: roxagent downloaded and installed
- **3-5 minutes**: First scan completes
- **5+ minutes**: Vulnerabilities appear in RHACS UI

## Troubleshooting

### VMs not appearing in RHACS

1. Verify feature flags are set:
   ```bash
   oc get deployment central -n stackrox -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'
   ```

2. Check VM has vsock enabled:
   ```bash
   oc get vm <vm-name> -n <namespace> -o yaml | grep autoattachVSOCK
   ```

3. Verify VM is running RHEL:
   ```bash
   oc get vm <vm-name> -n <namespace> -o yaml | grep -i rhel
   ```

### Vulnerabilities not detected

1. Ensure VM has valid RHEL subscription:
   ```bash
   # Inside the VM
   subscription-manager status
   ```

2. Check VM can reach Red Hat repositories:
   ```bash
   # Inside the VM
   curl -I https://access.redhat.com
   ```

3. Review Collector logs:
   ```bash
   oc logs -n stackrox daemonset/collector -c compliance | grep -i "virtual\|vsock"
   ```

### roxagent not running

```bash
# Inside VM
systemctl status roxagent
journalctl -u roxagent -n 50
```

### Cloud-init failed

```bash
# Inside VM
cloud-init status
cloud-init analyze show
tail -f /var/log/cloud-init.log
```

### HyperConverged patching fails

If the HyperConverged patch fails, you may need to adjust the feature gate fields based on your OpenShift Virtualization version. Check the HyperConverged CRD:

```bash
oc get crd hyperconvergeds.hco.kubevirt.io -o yaml
```

## References

- [RHACS Virtual Machine Scanning Documentation](https://docs.openshift.com/acs/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
- [VSOCK Support in KubeVirt](https://kubevirt.io/)
- [roxagent Downloads](https://mirror.openshift.com/pub/rhacs/assets/)
- [RHEL Image Builder](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/composing_a_customized_rhel_system_image/)
- [RHACM VM Management](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/)

## Support

For issues or questions:
1. Run `01-check-env.sh` to diagnose configuration
2. Check RHACS and OpenShift Virtualization operator logs
3. Verify all prerequisites are met
4. Consult RHACS and OpenShift Virtualization documentation
5. See `IMAGE-BUILD-GUIDE.md` for image building troubleshooting
