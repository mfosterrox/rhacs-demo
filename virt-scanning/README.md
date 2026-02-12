# Virtual Machine Vulnerability Scanning Setup

This folder contains scripts to configure Red Hat Advanced Cluster Security (RHACS) for virtual machine vulnerability management.

## Overview

RHACS can scan virtual machines running on OpenShift Virtualization for vulnerabilities. This feature requires specific configuration on both RHACS components and the OpenShift Virtualization platform.

## Prerequisites

Before running these scripts, ensure you have:

- OpenShift cluster with admin access
- RHACS installed (from basic-setup)
- OpenShift Virtualization operator installed
- `oc` CLI configured and authenticated

## Scripts

### `install.sh`

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

### `01-check-env.sh`

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

### HyperConverged patching fails

If the HyperConverged patch fails, you may need to adjust the feature gate fields based on your OpenShift Virtualization version. Check the HyperConverged CRD:

```bash
oc get crd hyperconvergeds.hco.kubevirt.io -o yaml
```

## References

- [RHACS Virtual Machine Scanning Documentation](https://docs.openshift.com/acs/)
- [OpenShift Virtualization Documentation](https://docs.openshift.com/container-platform/latest/virt/about-virt.html)
- [VSOCK Support in KubeVirt](https://kubevirt.io/)

## Support

For issues or questions:
1. Run `01-check-env.sh` to diagnose configuration
2. Check RHACS and OpenShift Virtualization operator logs
3. Verify all prerequisites are met
4. Consult RHACS and OpenShift Virtualization documentation
