# Virtual Machine Vulnerability Scanning Setup

This folder contains scripts and tools for configuring Red Hat Advanced Cluster Security (RHACS) for virtual machine vulnerability management and building RHEL VM images with roxagent.

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

## Quick Start

### For RHACM Deployments (Recommended)

The easiest way to deploy VMs with roxagent:

1. **Configure RHACS platform:**
   ```bash
   cd virt-scanning
   ./install.sh
   ```

2. **Deploy VM with cloud-init:**
   ```bash
   oc apply -f vm-template-rhacm.yaml
   ```

That's it! The VM will auto-configure roxagent on first boot.

### For Custom Images

If you need pre-built images with roxagent:

1. See `IMAGE-BUILD-GUIDE.md` for detailed options
2. Quick build: `./build-custom-image.sh`
3. Upload to OpenShift and deploy

## Files

### Setup Scripts

#### `install.sh`

Configures RHACS and OpenShift Virtualization for VM vulnerability scanning.

**What it does:**
1. Adds `ROX_VIRTUAL_MACHINES=true` feature flag to Central deployment
2. Adds `ROX_VIRTUAL_MACHINES=true` feature flag to Sensor deployment
3. Adds `ROX_VIRTUAL_MACHINES=true` to Collector daemonset compliance container
4. Patches HyperConverged resource to enable vsock support
5. Displays instructions for configuring individual VMs

**Usage:**
```bash
cd virt-scanning
./install.sh
```

#### `01-check-env.sh`

Verifies all prerequisites for VM vulnerability scanning are met.

**What it checks:**
1. ✓ Central deployment has `ROX_VIRTUAL_MACHINES=true`
2. ✓ Sensor deployment has `ROX_VIRTUAL_MACHINES=true`
3. ✓ Collector compliance container has `ROX_VIRTUAL_MACHINES=true`
4. ✓ OpenShift Virtualization operator is installed
5. ✓ HyperConverged resource has vsock support enabled
6. ✓ Virtual machines have vsock configured (`autoattachVSOCK: true`)
7. ✓ VMs are running RHEL (where detectable)
8. ⚠ VM network access (manual verification required)
9. ✓ Metal nodes available (recommended)

**Usage:**
```bash
cd virt-scanning
./01-check-env.sh
```

### VM Image Building

#### `cloud-init-roxagent.yaml`

**Recommended approach** - Cloud-init configuration for installing roxagent on any RHEL VM.

- Downloads roxagent from Red Hat mirror on first boot
- Creates systemd service for continuous scanning
- No custom image building required
- Perfect for RHACM deployments

#### `vm-template-rhacm.yaml`

Complete VM template ready for RHACM deployment with:
- vsock support enabled
- Cloud-init configuration embedded
- Multiple storage backend options
- Proper resource sizing

**Usage:**
```bash
oc apply -f vm-template-rhacm.yaml
```

#### `build-custom-image.sh`

Interactive script for building custom RHEL QCOW2 images with roxagent pre-installed.

**What it does:**
- Guides you through image customization options
- Downloads roxagent binary
- Uses `virt-customize` to inject roxagent into QCOW2
- Creates systemd service
- Produces uploadable image

**Usage:**
```bash
./build-custom-image.sh
```

#### `IMAGE-BUILD-GUIDE.md`

Comprehensive guide covering **4 different approaches** for building RHEL images with roxagent:

1. **Cloud-init** (Recommended) - No image building, uses standard RHEL + cloud-init
2. **Image Builder** (Production) - Official Red Hat tool for custom images
3. **Manual QCOW2** (Advanced) - Direct image customization with libguestfs
4. **Bootable Container** (Modern) - Cloud-native approach with bootc

Includes deployment instructions for RHACM and troubleshooting guidance.

## VM Configuration

After running `install.sh`, each VM must be configured with vsock support:

### Option 1: Patch existing VM
```bash
oc patch vm <vm-name> -n <namespace> --type=merge -p '
{
  "spec": {
    "template": {
      "spec": {
        "domain": {
          "devices": {
            "autoattachVSOCK": true
          }
        }
      }
    }
  }
}'
```

### Option 2: Add to VM YAML
```yaml
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: my-rhel-vm
spec:
  template:
    spec:
      domain:
        devices:
          autoattachVSOCK: true
        # ... other config
```

## VM Requirements

For vulnerability scanning to work, VMs must:

1. **Run Red Hat Enterprise Linux (RHEL)** - Other OSes are not currently supported
2. **Have valid RHEL subscription** - Required for vulnerability data
3. **Have network access** - To download repository-to-CPE mappings
4. **Have vsock enabled** - `spec.domain.devices.autoattachVSOCK: true`
5. **Run roxagent binary** - Either via cloud-init or pre-installed in image

### roxagent Installation Options

| Method | Best For | Setup Time | Update Ease |
|--------|----------|------------|-------------|
| Cloud-init | RHACM, testing | 5 min | Very easy |
| Image Builder | Production | 30 min | Moderate |
| Manual QCOW2 | Custom needs | 15 min | Hard |
| Bootable Container | Modern infra | 20 min | Very easy |

See `IMAGE-BUILD-GUIDE.md` for detailed comparison.

## Infrastructure Recommendations

- **Metal nodes** are recommended to host VMs for optimal performance
- VMs can run on standard nodes but may experience performance degradation

## Verification

After configuration, verify the setup:

```bash
# Run environment check
./01-check-env.sh

# Check RHACS sees the VMs
oc logs -n stackrox deployment/central | grep -i "virtual machine"

# Check individual VM configuration
oc get vm <vm-name> -n <namespace> -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}'
```

Expected output should be `true` for VMs with vsock enabled.

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
