# RHACS VM Vulnerability Scanning - Demo Setup Guide

## Quick Start (Complete Demo)

### Step 1: Deploy VMs with roxagent
```bash
cd /home/lab-user/rhacs-demo/virt-scanning
./install.sh
```
**Time:** 5-10 minutes  
**Result:** 4 VMs running with roxagent scanning

### Step 2: Install Packages for Vulnerability Data (OPTIONAL)
```bash
./setup-demo-packages.sh
```
**Time:** 10-15 minutes (manual copy/paste per VM)  
**Result:** VMs registered with RHEL subscription + packages installed

### Step 3: View Results
```bash
./check-vm-status.sh
```
**Or open RHACS UI:**
- Navigate to: Platform Configuration → Clusters → Virtual Machines
- You'll see all 4 VMs with vulnerability data

---

## What You Get

### After Step 1 (install.sh):
✅ VMs appear in RHACS  
✅ roxagent running and scanning  
✅ **No vulnerability data** (no packages installed yet)

### After Step 2 (setup-demo-packages.sh):
✅ VMs registered with Red Hat subscription  
✅ Packages installed via DNF:
- **rhel-webserver**: httpd, nginx, php
- **rhel-database**: postgresql, mariadb
- **rhel-devtools**: git, gcc, python3
- **rhel-monitoring**: net-snmp

✅ **Real vulnerability data** visible in RHACS

---

## Package Installation Options

### Option A: setup-demo-packages.sh (RECOMMENDED)
**Simple and reliable** - generates ready-to-use scripts

```bash
./setup-demo-packages.sh
# Enter Red Hat credentials
# Scripts generated in /tmp/vm-registration-scripts/

# Then for each VM:
virtctl console rhel-webserver -n default
# Login: cloud-user / redhat
# Copy/paste the generated script content
```

### Option B: 04-register-vms.sh (Advanced)
**Fully automated** - requires `expect` package

```bash
./04-register-vms.sh
# Enter credentials
# Sits back and waits
```

### Option C: Manual Commands
**For understanding the process**

```bash
./register-vm-commands.sh
# Displays commands to run in each VM manually
```

---

## Demo Credentials

### VM Access:
- **User:** `cloud-user`
- **Password:** `redhat`

### Red Hat Subscription:
- Required for package installation
- Not required for VM scanning infrastructure
- VMs will appear in RHACS without subscription
- Packages + vulnerabilities require subscription

---

## Troubleshooting

### Check VM Status
```bash
./check-vm-status.sh
```

### View VM Console
```bash
virtctl console rhel-webserver -n default
# Exit with: Ctrl+]
```

### Check roxagent Status (inside VM)
```bash
sudo systemctl status roxagent
sudo journalctl -u roxagent -f
```

### Check RHACS Collector Logs
```bash
COLLECTOR_POD=$(oc get pods -n stackrox -l app=collector -o jsonpath='{.items[0].metadata.name}')
oc logs -n stackrox $COLLECTOR_POD -c compliance --tail=100 | grep -i vsock
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                   RHEL VMs                          │
│  ┌─────────────────────────────────────────┐       │
│  │  roxagent (daemon mode)                 │       │
│  │  • Scans DNF packages every 5 minutes   │       │
│  │  • Sends reports via VSOCK (port 818)   │       │
│  └─────────────────────────────────────────┘       │
└────────────────────┬────────────────────────────────┘
                     │ VSOCK
                     ↓
┌─────────────────────────────────────────────────────┐
│         Collector (DaemonSet)                       │
│  • hostNetwork: true (access host VSOCK)            │
│  • Listens on VSOCK port 818                        │
│  • Receives vulnerability reports                   │
└────────────────────┬────────────────────────────────┘
                     │ gRPC
                     ↓
┌─────────────────────────────────────────────────────┐
│         Sensor (Deployment)                         │
│  • Processes VM vulnerability data                  │
│  • Forwards to Central                              │
└────────────────────┬────────────────────────────────┘
                     │ gRPC
                     ↓
┌─────────────────────────────────────────────────────┐
│         Central (Deployment)                        │
│  • Stores and displays vulnerability data           │
│  • Web UI: Platform Configuration → VMs             │
└─────────────────────────────────────────────────────┘
```

---

## Key Configuration

### Feature Flags (all set to `true`):
- `ROX_VIRTUAL_MACHINES` on Central
- `ROX_VIRTUAL_MACHINES` on Sensor  
- `ROX_VIRTUAL_MACHINES` on Collector (compliance container)

### VSOCK Configuration:
- KubeVirt feature gate: `VSOCK` enabled
- VMs: `spec.domain.devices.autoattachVSOCK: true`
- Collector: `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet`

### roxagent Configuration:
- `ROX_VIRTUAL_MACHINES_VSOCK_PORT=818`
- `ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384`
- Scan interval: 5 minutes (`--index-interval=5m`)

---

## Files Reference

| Script | Purpose | Time | Interactive |
|--------|---------|------|-------------|
| `install.sh` | Main setup - deploys everything | 10 min | No |
| `setup-demo-packages.sh` | Generate package install scripts | 15 min | Yes (copy/paste) |
| `04-register-vms.sh` | Automated package installation | 15 min | No (needs expect) |
| `register-vm-commands.sh` | Show manual commands | 1 min | Display only |
| `check-vm-status.sh` | Quick status check | 10 sec | No |
| `debug-vm-scanning.sh` | Comprehensive debugging | 2 min | No |
| `collect-logs.sh` | Gather all logs for support | 1 min | No |

---

## Success Criteria

✅ **VMs Running:**
```bash
oc get vmi -n default
# Should show 4 VMs in "Running" state
```

✅ **roxagent Active:**
```bash
virtctl console rhel-webserver -n default
sudo systemctl status roxagent
# Should show "active (running)"
```

✅ **RHACS Showing VMs:**
- Open RHACS UI → Platform Configuration → Virtual Machines
- Should see 4 VMs listed

✅ **Vulnerability Data (if packages installed):**
- CVEs by severity column should show numbers
- "Scanned packages" should show package count
- Click on VM to see detailed vulnerability list

---

## Timeline

| Event | Time | What Happens |
|-------|------|--------------|
| `install.sh` starts | 0 min | VMs begin deployment |
| VMs boot | 3-5 min | Cloud-init runs, roxagent downloads |
| First roxagent scan | 5 min | Empty scan (no packages) |
| VMs appear in RHACS | 5-7 min | Central displays VMs |
| Packages installed | Variable | Manual step with subscription |
| Vulnerabilities appear | +2 min | After package install + next scan |

---

## Additional Resources

- **README.md** - Comprehensive documentation
- **DEBUGGING.md** - Troubleshooting guide with detailed steps
- **vm-template-rhacm.yaml** - Template for RHACM deployments

---

## Demo Tips

1. **Start with infrastructure first**
   - Show VMs appearing in RHACS (proves infrastructure works)
   - Then install packages (shows vulnerability detection)

2. **Explain the "No packages" state**
   - VMs don't have RHEL subscription by default
   - This is expected and demonstrates roxagent works even without packages

3. **Show real-time scanning**
   - Install packages in one VM
   - Watch vulnerabilities appear after 2-3 minutes
   - Demonstrates continuous monitoring

4. **Highlight automation**
   - One `install.sh` command deploys entire infrastructure
   - No manual configuration needed
   - Production-ready setup

---

**Last Updated:** February 2026  
**RHACS Version:** 4.9.2  
**OpenShift Virtualization:** 1.6+
