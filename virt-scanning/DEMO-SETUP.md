# RHACS VM Vulnerability Scanning - Demo Setup

## Quick Start

```bash
cd /home/lab-user/rhacs-demo/virt-scanning
./install.sh
```

**That's it!** The script will:
1. Prompt for your Red Hat subscription credentials
2. Configure RHACS for VM scanning
3. Deploy 4 RHEL VMs with packages automatically installed
4. Start vulnerability scanning

**Time:** ~15 minutes total

---

## What Gets Deployed

### 4 RHEL VMs with Packages:

| VM | Packages | Use Case |
|----|----------|----------|
| **rhel-webserver** | httpd, nginx, php | Web server vulnerabilities |
| **rhel-database** | postgresql, mariadb | Database vulnerabilities |
| **rhel-devtools** | git, gcc, python, nodejs | Development tool vulnerabilities |
| **rhel-monitoring** | grafana, telegraf, net-snmp | Monitoring vulnerabilities |

### RHACS Configuration:
- ✅ Feature flags enabled (Central, Sensor, Collector)
- ✅ VSOCK enabled in OpenShift Virtualization
- ✅ Collector configured for VSOCK communication
- ✅ roxagent running in each VM

---

## Timeline

| Time | Event |
|------|-------|
| 0 min | `./install.sh` starts, prompts for credentials |
| 0-2 min | RHACS configuration |
| 2-5 min | VMs deploying |
| 5-10 min | Cloud-init: registration + package installation |
| 10-12 min | roxagent first scan |
| 12-15 min | Vulnerability data appears in RHACS |

---

## Viewing Results

### Check VM Status
```bash
# Quick status check
./check-vm-status.sh

# Watch VMs boot
oc get vmi -n default -w

# Check inside a VM
virtctl console rhel-webserver -n default
# Login: cloud-user / redhat
sudo systemctl status roxagent
sudo journalctl -u roxagent -n 50
```

### RHACS UI
1. Get Central URL:
   ```bash
   oc get route central -n stackrox -o jsonpath='{.spec.host}'
   ```

2. Navigate to: **Platform Configuration → Clusters → Virtual Machines**

3. You should see:
   - All 4 VMs listed
   - Package counts
   - CVE counts by severity
   - Last updated timestamps

---

## Demo Flow

### 1. Show the Simple Setup
```bash
./install.sh
# "Just enter credentials - that's it!"
```

### 2. Explain What's Happening
- VMs boot with cloud-init
- Automatically register with Red Hat
- Install packages via DNF
- roxagent scans packages
- Reports to RHACS via VSOCK

### 3. Show Live Progress
```bash
# Watch VMs appear
oc get vmi -n default -w

# Watch cloud-init logs (inside VM)
virtctl console rhel-webserver -n default
sudo tail -f /var/log/cloud-init-output.log
```

### 4. Show RHACS UI
- Point out the 4 VMs
- Show CVE counts
- Click into a VM to see details
- Highlight continuous scanning

### 5. Demonstrate Continuous Scanning (Optional)
```bash
# Inside a VM
sudo dnf install curl wget
# Wait 2-3 minutes
# Show new vulnerabilities appear in RHACS
```

---

## Troubleshooting

### No Vulnerability Data?

**Check if packages installed:**
```bash
virtctl console rhel-webserver -n default
sudo dnf list installed | head -20
```

**Check if roxagent is running:**
```bash
sudo systemctl status roxagent
sudo journalctl -u roxagent -n 50
```

**Check RHACS Collector logs:**
```bash
./check-vm-status.sh
# Look for VSOCK connection logs
```

### VMs Not Appearing in RHACS?

```bash
# Check feature flags
oc get deployment central -n stackrox -o yaml | grep ROX_VIRTUAL_MACHINES
oc get deployment sensor -n stackrox -o yaml | grep ROX_VIRTUAL_MACHINES
oc get daemonset collector -n stackrox -o yaml | grep ROX_VIRTUAL_MACHINES

# Check VSOCK enabled
oc get kubevirt -n openshift-cnv -o yaml | grep VSOCK

# Check Collector networking
oc get daemonset collector -n stackrox -o yaml | grep hostNetwork
```

### Run Comprehensive Diagnostics
```bash
./debug-vm-scanning.sh
```

---

## Architecture Overview

```
┌─────────────────────────────────────┐
│          RHEL VMs (4)              │
│  ┌─────────────────────────────┐   │
│  │ roxagent (daemon)           │   │
│  │ • Scans packages (5 min)    │   │
│  │ • Sends via VSOCK           │   │
│  └─────────────────────────────┘   │
└──────────────┬──────────────────────┘
               │ VSOCK (port 818)
               ↓
┌─────────────────────────────────────┐
│   Collector (DaemonSet)             │
│  • hostNetwork: true                │
│  • Receives reports                 │
└──────────────┬──────────────────────┘
               │ gRPC
               ↓
┌─────────────────────────────────────┐
│   Sensor → Central                  │
│  • Processes + stores data          │
│  • Web UI displays VMs              │
└─────────────────────────────────────┘
```

---

## Key Points for Demos

1. **One Command Setup**
   - No manual VM configuration
   - Credentials entered once
   - Everything automated

2. **Production Ready**
   - Proper VSOCK configuration
   - DNS resolution fixed
   - Continuous scanning

3. **Real Vulnerability Data**
   - Actual packages from Red Hat repos
   - Real CVEs discovered
   - Continuous updates

4. **Scalable**
   - Easy to add more VMs
   - Same pattern for any RHEL VM
   - Works with RHACM

---

## Files Reference

| File | Purpose |
|------|---------|
| `install.sh` | Main setup script (prompts for credentials) |
| `01-configure-rhacs.sh` | RHACS + VSOCK configuration |
| `03-deploy-sample-vms.sh` | VM deployment with packages |
| `check-vm-status.sh` | Quick status check |
| `debug-vm-scanning.sh` | Comprehensive diagnostics |
| `collect-logs.sh` | Gather logs for support |
| `README.md` | Full documentation |
| `DEBUGGING.md` | Detailed troubleshooting |

---

## Success Criteria

✅ **VMs Deployed:**
```bash
oc get vmi -n default
# Should show 4 VMs in "Running" state
```

✅ **Packages Installed:**
```bash
virtctl console rhel-webserver -n default
sudo dnf list installed | wc -l
# Should show >100 packages
```

✅ **roxagent Running:**
```bash
sudo systemctl status roxagent
# Should show "active (running)"
```

✅ **VMs in RHACS:**
- Open RHACS UI
- Navigate to Platform Configuration → Virtual Machines
- See all 4 VMs with CVE counts

---

**Demo Time:** 15 minutes setup + 5 minutes presentation = 20 minutes total
