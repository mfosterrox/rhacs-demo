# RHACS VM Vulnerability Scanning - Quick Start

## One Command Setup

```bash
cd /home/lab-user/rhacs-demo/virt-scanning
./install.sh
```

### What It Does:
1. **Prompts for Red Hat credentials** (username/password)
2. Configures RHACS for VM scanning
3. Deploys 4 VMs with packages automatically
4. Starts vulnerability scanning

### Time: 15 minutes

---

## What You'll Be Asked

```
Red Hat Username: [your-username@redhat.com]
Red Hat Password: [your-password]
```

**That's it!** The script does the rest automatically.

---

## Expected Output

```
╔════════════════════════════════════════════════════════════╗
║     RHACS Virtual Machine Vulnerability Scanning Setup    ║
╚════════════════════════════════════════════════════════════╝

This automated script will:
  1. Prompt for Red Hat subscription credentials
  2. Configure RHACS for VM scanning
  3. Enable VSOCK in OpenShift Virtualization
  4. Deploy 4 RHEL VMs with packages installed
  5. Start vulnerability scanning automatically

Sample VMs (with packages):
  • rhel-webserver: httpd, nginx, php
  • rhel-database: postgresql, mariadb
  • rhel-devtools: git, gcc, python, nodejs
  • rhel-monitoring: grafana, telegraf, net-snmp

⏱️  Total time: ~15 minutes

════════════════════════════════════════════════════════════
Red Hat Subscription Credentials
════════════════════════════════════════════════════════════

VMs will automatically register and install packages during deployment
Credentials are used only during VM setup (stored in cloud-init secrets)

Red Hat Username: your-username
Red Hat Password: ********
✓ Credentials received

...setup continues automatically...
```

---

## After Setup Completes

### Check VMs
```bash
oc get vmi -n default
```

### Check Status
```bash
./check-vm-status.sh
```

### View in RHACS UI
1. Get URL: `oc get route central -n stackrox -o jsonpath='{.spec.host}'`
2. Navigate to: **Platform Configuration → Clusters → Virtual Machines**
3. See your 4 VMs with vulnerability data!

---

## File Structure (Simplified)

```
virt-scanning/
├── install.sh                  ← Run this!
├── 01-configure-rhacs.sh      (called by install.sh)
├── 03-deploy-sample-vms.sh    (called by install.sh)
├── check-vm-status.sh         (run after setup)
├── debug-vm-scanning.sh       (if troubleshooting needed)
├── collect-logs.sh            (gather logs)
├── README.md                  (full documentation)
├── DEMO-SETUP.md              (demo guide)
├── DEBUGGING.md               (troubleshooting)
└── vm-template-rhacm.yaml     (RHACM template)
```

**10 files total** - everything you need, nothing you don't!

---

## Troubleshooting

### VMs not showing data?
```bash
./debug-vm-scanning.sh
```

### Want to see logs?
```bash
./collect-logs.sh
```

### Need more help?
See **DEBUGGING.md**

---

## That's It!

**Simple.** **Fast.** **Automated.** 

🚀 One command gets you a complete VM vulnerability scanning demo!
