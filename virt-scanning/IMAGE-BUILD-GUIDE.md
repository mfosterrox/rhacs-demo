# Building RHEL Images with RHACS roxagent

This guide covers multiple approaches for creating RHEL VM images with the RHACS roxagent binary pre-installed for vulnerability scanning.

## Overview

To enable RHACS vulnerability scanning on VMs, you need:
1. The `roxagent` binary running inside the VM
2. VM configured with vsock support (`autoattachVSOCK: true`)
3. RHACS components configured with `ROX_VIRTUAL_MACHINES=true`

## Recommended Approach: Cloud-init (Easiest)

**Best for:** RHACM deployments, quick testing, easy updates

This method uses a standard RHEL image with cloud-init to install roxagent on first boot.

### Files Provided
- `cloud-init-roxagent.yaml` - Standalone cloud-init configuration
- `vm-template-rhacm.yaml` - Complete VM template with cloud-init

### Steps

1. **Use the provided VM template:**
   ```bash
   oc apply -f vm-template-rhacm.yaml
   ```

2. **Or integrate cloud-init into existing VM:**
   ```yaml
   volumes:
     - name: cloudinitdisk
       cloudInitNoCloud:
         secretRef:
           name: rhel-roxagent-cloudinit
   ```

3. **Deploy via RHACM:**
   - Import `vm-template-rhacm.yaml` as an application
   - Use placement rules to target specific clusters
   - VM will auto-configure on first boot

### What cloud-init does:
- Downloads roxagent from Red Hat mirror
- Creates systemd service for continuous scanning
- Configures environment variables
- Enables and starts the service automatically

### Advantages:
✅ No custom image building required  
✅ Easy to update roxagent version (change URL in cloud-init)  
✅ Works with any RHEL base image  
✅ Fully compatible with RHACM  
✅ Transparent and auditable (all in YAML)  

### Disadvantages:
❌ Requires internet access on first boot  
❌ Slightly slower first boot  
❌ roxagent not available immediately  

---

## Option 2: Image Builder / Composer (Production)

**Best for:** Production environments, air-gapped clusters, compliance

Red Hat Image Builder creates official, reproducible custom images.

### Prerequisites
- RHEL 8+ system with Image Builder
- Valid RHEL subscription

### Steps

1. **Install Image Builder:**
   ```bash
   sudo dnf install osbuild-composer composer-cli cockpit-composer
   sudo systemctl enable --now osbuild-composer.socket
   ```

2. **Create blueprint:**
   ```bash
   cat > rhel-roxagent.toml <<'EOF'
   name = "rhel-roxagent"
   description = "RHEL with RHACS roxagent"
   version = "1.0.0"
   
   [[packages]]
   name = "curl"
   version = "*"
   
   [[packages]]
   name = "systemd"
   version = "*"
   
   [[customizations.files]]
   path = "/opt/roxagent/roxagent"
   mode = "0755"
   user = "root"
   group = "root"
   data = "https://mirror.openshift.com/pub/rhacs/assets/4.9.2/bin/linux/roxagent"
   
   [[customizations.services]]
   enabled = ["roxagent"]
   
   [customizations.services.roxagent]
   type = "simple"
   exec_start = "/opt/roxagent/roxagent --daemon --index-interval=5m"
   description = "RHACS VM Vulnerability Agent"
   EOF
   ```

3. **Build image:**
   ```bash
   composer-cli blueprints push rhel-roxagent.toml
   composer-cli compose start rhel-roxagent qcow2
   composer-cli compose status
   composer-cli compose image <UUID>
   ```

4. **Upload to OpenShift:**
   ```bash
   virtctl image-upload dv rhel-roxagent \
     --size=30Gi \
     --image-path=<UUID>-image.qcow2 \
     --storage-class=ocs-storagecluster-ceph-rbd
   ```

### Advantages:
✅ Official Red Hat tooling  
✅ Fully supported  
✅ Reproducible builds  
✅ No internet required at VM boot  
✅ roxagent ready immediately  

### Disadvantages:
❌ Requires Image Builder infrastructure  
❌ More complex setup  
❌ Updates require rebuilding image  

---

## Option 3: Manual QCOW2 Customization (Advanced)

**Best for:** Custom requirements, one-off builds, testing

Use `virt-customize` to modify existing RHEL QCOW2 images.

### Prerequisites
- `libguestfs-tools` package
- Existing RHEL QCOW2 image

### Steps

1. **Run the provided script:**
   ```bash
   ./build-custom-image.sh
   ```

2. **Or manually customize:**
   ```bash
   # Download roxagent
   curl -L -o roxagent \
     https://mirror.openshift.com/pub/rhacs/assets/4.9.2/bin/linux/roxagent
   
   # Customize image
   virt-customize -a rhel9.qcow2 \
     --mkdir /opt/roxagent \
     --copy-in roxagent:/opt/roxagent/ \
     --chmod 0755:/opt/roxagent/roxagent \
     --run-command "systemctl enable roxagent.service" \
     --selinux-relabel
   ```

3. **Upload to OpenShift** (see Image Builder steps above)

### Advantages:
✅ Full control over image  
✅ Can include custom configurations  
✅ Works offline  
✅ Fast for testing  

### Disadvantages:
❌ Requires libguestfs  
❌ Manual process  
❌ Harder to maintain  

---

## Option 4: Bootable Container (Modern)

**Best for:** Cloud-native workflows, GitOps, modern infrastructure

Use `bootc` to create bootable containers with roxagent.

### Prerequisites
- Podman or buildah
- RHEL 9.4+ or Fedora CoreOS

### Steps

1. **Create Containerfile:**
   ```dockerfile
   FROM registry.redhat.io/rhel9/rhel-bootc:latest
   
   # Install roxagent
   RUN curl -L -o /usr/local/bin/roxagent \
       https://mirror.openshift.com/pub/rhacs/assets/4.9.2/bin/linux/roxagent && \
       chmod +x /usr/local/bin/roxagent
   
   # Create systemd service
   COPY roxagent.service /etc/systemd/system/
   RUN systemctl enable roxagent.service
   
   # Configure environment
   ENV ROX_VIRTUAL_MACHINES_VSOCK_PORT=818
   ENV ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384
   ```

2. **Build and push:**
   ```bash
   podman build -t quay.io/yourorg/rhel-roxagent:latest .
   podman push quay.io/yourorg/rhel-roxagent:latest
   ```

3. **Deploy in OpenShift Virtualization:**
   ```yaml
   volumes:
     - name: rootdisk
       containerDisk:
         image: quay.io/yourorg/rhel-roxagent:latest
   ```

### Advantages:
✅ Cloud-native workflow  
✅ Version controlled  
✅ Easy updates (just rebuild)  
✅ Integrates with CI/CD  
✅ Small, efficient  

### Disadvantages:
❌ Newer technology (RHEL 9.4+)  
❌ Requires container registry  
❌ Learning curve  

---

## Deploying via RHACM

Regardless of which image method you choose, deploy via RHACM using:

### Application Model

```yaml
apiVersion: app.k8s.io/v1beta1
kind: Application
metadata:
  name: rhacs-scanning-vms
  namespace: rhacm-apps
spec:
  componentKinds:
    - group: kubevirt.io
      kind: VirtualMachine
  selector:
    matchLabels:
      app: rhacs-scanning
---
apiVersion: apps.open-cluster-management.io/v1
kind: PlacementRule
metadata:
  name: rhacs-vm-placement
  namespace: rhacm-apps
spec:
  clusterConditions:
    - type: ManagedClusterConditionAvailable
      status: "True"
  clusterSelector:
    matchLabels:
      environment: production
      rhacs: enabled
```

### Policy for VM Configuration

```yaml
apiVersion: policy.open-cluster-management.io/v1
kind: Policy
metadata:
  name: vm-vsock-required
  namespace: rhacm-policies
spec:
  remediationAction: enforce
  disabled: false
  policy-templates:
    - objectDefinition:
        apiVersion: policy.open-cluster-management.io/v1
        kind: ConfigurationPolicy
        metadata:
          name: vsock-enabled
        spec:
          severity: high
          object-templates:
            - complianceType: musthave
              objectDefinition:
                apiVersion: kubevirt.io/v1
                kind: VirtualMachine
                spec:
                  template:
                    spec:
                      domain:
                        devices:
                          autoattachVSOCK: true
```

---

## Verification

After deploying VMs with any method:

1. **Check roxagent service inside VM:**
   ```bash
   virtctl console <vm-name>
   # Inside VM:
   systemctl status roxagent
   journalctl -u roxagent -f
   ```

2. **Verify vsock configuration:**
   ```bash
   oc get vm <vm-name> -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}'
   # Should return: true
   ```

3. **Check RHACS sees the VM:**
   ```bash
   # In RHACS UI: Platform Configuration → Clusters → Virtual Machines
   ```

---

## Recommendation Matrix

| Scenario | Recommended Method | Why |
|----------|-------------------|-----|
| Quick testing | Cloud-init | Fastest setup, no building |
| RHACM deployment | Cloud-init | Best integration, easy updates |
| Production | Image Builder | Supported, reproducible |
| Air-gapped | Image Builder | No internet needed at boot |
| Custom configs | Manual QCOW2 | Full control |
| Modern infra | Bootable Container | Cloud-native, version control |

---

## Troubleshooting

### roxagent not running
```bash
# Inside VM
systemctl status roxagent
journalctl -u roxagent -n 50
```

### VM not detected by RHACS
1. Verify feature flags: `./01-check-env.sh`
2. Check vsock: `oc get vm -o yaml | grep autoattachVSOCK`
3. Review Collector logs: `oc logs -n stackrox ds/collector -c compliance`

### Cloud-init failed
```bash
# Inside VM
cloud-init status
cloud-init analyze show
tail -f /var/log/cloud-init.log
```

---

## References

- roxagent download: https://mirror.openshift.com/pub/rhacs/assets/
- RHEL Image Builder: https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/composing_a_customized_rhel_system_image/
- OpenShift Virtualization: https://docs.openshift.com/container-platform/latest/virt/about-virt.html
- RHACM: https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/
