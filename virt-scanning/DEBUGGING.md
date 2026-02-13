# Debugging RHACS VM Vulnerability Scanning

## Quick Start

Run the automated debug tool:
```bash
./debug-vm-scanning.sh
```

## Immediate Diagnostic Commands

### 1. Check if VMs are running and have VSOCK

```bash
# List all VMs and their status
oc get vm -n default

# Check VMI (VirtualMachineInstance) status and VSOCK CID
oc get vmi -n default

# Check specific VM for VSOCK CID
oc get vmi rhel-roxagent-vm -n default -o jsonpath='{.status.VSOCKCID}'

# Verify VM has autoattachVSOCK enabled
oc get vm rhel-roxagent-vm -n default -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}'
```

Expected: Each VMI should have a VSOCK CID (number like 3, 4, 5, etc.)

---

### 2. Check RHACS Feature Flags

```bash
# Central deployment
oc get deployment central -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'

# Sensor deployment  
oc get deployment sensor -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'

# Collector compliance container
oc get daemonset collector -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'
```

Expected: All should return `true`

If not, run: `./install.sh`

---

### 3. Check Inside a VM

```bash
# Access VM console
virtctl console rhel-roxagent-vm -n default
# Login as: cloud-user (no password initially)

# Inside VM:

# Check cloud-init status
cloud-init status

# Check if cloud-init finished
cat /var/log/cloud-init-output.log | tail -50

# Check roxagent binary exists
ls -la /opt/roxagent/roxagent

# Check roxagent service
sudo systemctl status roxagent

# Check roxagent logs
sudo journalctl -u roxagent -n 50

# Check if roxagent is running
ps aux | grep roxagent

# Run roxagent manually to see output
sudo /opt/roxagent/roxagent --verbose

# Check network connectivity
curl -I https://access.redhat.com

# Check RHEL subscription (required for DNF packages)
sudo subscription-manager status
```

---

### 4. Check Collector Logs

```bash
# Find collector pods
oc get pods -n stackrox -l app=collector

# Check compliance container logs for VM/VSOCK activity
oc logs -n stackrox -l app=collector -c compliance --tail=200 | grep -i "virtual\|vsock\|roxagent"

# Watch collector logs in real-time
oc logs -n stackrox -l app=collector -c compliance -f | grep -i "vm\|vsock"
```

Look for:
- VSOCK connection messages
- roxagent report messages
- VM scanning activity

---

### 5. Check Sensor Logs

```bash
# Find sensor pod
oc get pods -n stackrox -l app=sensor

# Check sensor logs for VM data
oc logs -n stackrox -l app=sensor --tail=100 | grep -i "virtual\|vm"
```

---

### 6. Verify VSOCK Feature Gate

```bash
# Check KubeVirt configuration
oc get kubevirt -n openshift-cnv -o yaml | grep -A 5 featureGates

# Should show VSOCK in the list
```

Expected output should include `- VSOCK`

---

## Common Issues and Fixes

### Issue: "Not available" in RHACS UI

**Likely causes:**
1. VMs still booting (takes 5-10 minutes)
2. Cloud-init still installing packages
3. roxagent hasn't completed first scan
4. VMs need RHEL subscription

**Fix:**
```bash
# Check if cloud-init is done
virtctl console rhel-webserver -n default
cloud-init status

# If it says "running", wait a few more minutes
# If it says "done", check roxagent:
sudo systemctl status roxagent
sudo journalctl -u roxagent -n 30
```

---

### Issue: roxagent service not starting

**Cause:** Cloud-init may have failed to download roxagent

**Fix:**
```bash
# Inside VM
sudo curl -k -L -o /opt/roxagent/roxagent \
  https://mirror.openshift.com/pub/rhacs/assets/4.9.2/bin/linux/roxagent

sudo chmod +x /opt/roxagent/roxagent

sudo systemctl restart roxagent
sudo systemctl status roxagent
```

---

### Issue: No VSOCK CID assigned

**Cause:** VSOCK feature gate not enabled or VM missing autoattachVSOCK

**Fix:**
```bash
# Check KubeVirt has VSOCK
oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].spec.configuration.developerConfiguration.featureGates}' | grep VSOCK

# If missing, run:
./install.sh

# Check VM has autoattachVSOCK
oc get vm rhel-webserver -n default -o jsonpath='{.spec.template.spec.domain.devices.autoattachVSOCK}'

# If false or missing, VM needs to be recreated
oc delete vm rhel-webserver -n default
./03-deploy-vm.sh  # or ./04-deploy-sample-vms.sh
```

---

### Issue: VMs need RHEL subscription

**Cause:** DNF packages require valid RHEL subscription to install

**Fix:**
```bash
# Inside each VM
sudo subscription-manager register --username YOUR_RH_USERNAME --password YOUR_RH_PASSWORD
sudo subscription-manager attach --auto
sudo subscription-manager status

# Verify repos are enabled
sudo dnf repolist
```

---

### Issue: Collector not receiving data

**Cause:** Feature flags not set or Collector needs restart

**Fix:**
```bash
# Verify feature flags (should all return "true")
oc get deployment central -n stackrox \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'

# If not "true", run:
./install.sh

# Restart collector to pick up changes
oc rollout restart daemonset/collector -n stackrox

# Wait for collector to restart
oc rollout status daemonset/collector -n stackrox

# Check logs
oc logs -n stackrox -l app=collector -c compliance --tail=50
```

---

## Step-by-Step Debug Process

### Step 1: Verify RHACS Configuration (2 minutes)

```bash
# Run all feature flag checks
./debug-vm-scanning.sh | head -50
```

All three should show `true`. If not, run `./install.sh`

---

### Step 2: Verify VMs Have VSOCK (1 minute)

```bash
# Check all VMs
oc get vmi -n default

# Each VM should have:
# - STATUS: Running
# - A VSOCK CID (number)
```

---

### Step 3: Check One VM in Detail (5 minutes)

```bash
# Pick one VM to debug
VM_NAME="rhel-webserver"

# Access console
virtctl console ${VM_NAME} -n default

# Inside VM, run these commands:
cloud-init status
sudo systemctl status roxagent
sudo journalctl -u roxagent -n 30
sudo /opt/roxagent/roxagent --verbose
```

---

### Step 4: Check Collector Logs (2 minutes)

```bash
# Watch for VSOCK/VM activity
oc logs -n stackrox -l app=collector -c compliance --tail=100 | grep -E "vsock|roxagent|virtual"
```

Look for messages like:
- "VSOCK connection established"
- "Received roxagent report"
- "Processing VM vulnerability data"

---

### Step 5: Wait and Verify (10-15 minutes)

If everything looks good but still "Not available":
- Wait 10-15 minutes for full boot cycle
- roxagent scans every 5 minutes
- First scan can take longer due to package installation

Check RHACS UI: Platform Configuration → Virtual Machines

---

## Timeline Expectations

| Time | Expected Status |
|------|----------------|
| 0-2 min | VM created, booting |
| 2-5 min | Cloud-init running, downloading roxagent |
| 5-8 min | Installing DNF packages |
| 8-10 min | roxagent service starts, first scan begins |
| 10-15 min | First scan completes, data appears in RHACS |
| 15+ min | Subsequent scans every 5 minutes |

---

## Quick Health Check Script

Run this to check everything at once:

```bash
#!/bin/bash

echo "=== RHACS Feature Flags ==="
oc get deployment central -n stackrox -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'
echo " (Central)"
oc get deployment sensor -n stackrox -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'
echo " (Sensor)"
oc get daemonset collector -n stackrox -o jsonpath='{.spec.template.spec.containers[?(@.name=="compliance")].env[?(@.name=="ROX_VIRTUAL_MACHINES")].value}'
echo " (Collector)"

echo ""
echo "=== VSOCK Feature Gate ==="
oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].spec.configuration.developerConfiguration.featureGates}' | grep VSOCK

echo ""
echo "=== VMs with VSOCK CIDs ==="
for vm in $(oc get vm -n default -o jsonpath='{.items[*].metadata.name}'); do
  cid=$(oc get vmi $vm -n default -o jsonpath='{.status.VSOCKCID}' 2>/dev/null || echo "N/A")
  phase=$(oc get vmi $vm -n default -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotRunning")
  echo "$vm: $phase (CID: $cid)"
done

echo ""
echo "=== Recent Collector Activity ==="
oc logs -n stackrox -l app=collector -c compliance --tail=50 | grep -i "vsock\|roxagent" | tail -10
```

---

## Getting Help

If issues persist after following this guide:

1. Collect logs:
```bash
# Collector logs
oc logs -n stackrox -l app=collector -c compliance --tail=500 > collector-logs.txt

# Sensor logs
oc logs -n stackrox -l app=sensor --tail=500 > sensor-logs.txt

# VM details
oc get vmi -n default -o yaml > vm-details.yaml

# roxagent logs from inside VM
virtctl console rhel-webserver -n default
sudo journalctl -u roxagent --no-pager > /tmp/roxagent.log
exit
oc cp default/rhel-webserver:/tmp/roxagent.log ./roxagent.log
```

2. Check RHACS documentation:
   - [VM Vulnerability Management](https://docs.openshift.com/acs/)

3. Verify versions match:
   - roxagent: 4.9.2
   - RHACS: 4.x
