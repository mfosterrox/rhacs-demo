# Automated VM Vulnerability Scanning Setup

## TL;DR - Completely Automated Demo

```bash
# 1. Configure credentials
cp vm-config.env.example vm-config.env
vi vm-config.env  # Add your Red Hat credentials

# 2. Run install
./install.sh

# 3. Wait 10-15 minutes
# VMs will automatically:
# - Deploy and boot
# - Register with Red Hat subscription
# - Install packages
# - Start roxagent scanning
# - Report vulnerabilities to RHACS

# 4. View results
# Open RHACS UI → Platform Configuration → Virtual Machines
# You'll see 4 VMs with real vulnerability data!
```

---

## Configuration File Setup

### Step 1: Create Configuration File

```bash
cd /home/lab-user/rhacs-demo/virt-scanning
cp vm-config.env.example vm-config.env
```

### Step 2: Edit with Your Credentials

**Option A: Username/Password**
```bash
# vm-config.env
RH_USERNAME="your-username@redhat.com"
RH_PASSWORD="your-password"
INSTALL_PACKAGES="true"
```

**Option B: Organization ID + Activation Key**
```bash
# vm-config.env
RH_ORG_ID="12345678"
RH_ACTIVATION_KEY="your-activation-key"
INSTALL_PACKAGES="true"
```

### Step 3: Run Install Script

```bash
./install.sh
```

**That's it!** Everything is automated.

---

## What Happens During Deployment

### Without `vm-config.env` (Current Behavior):
1. ✅ VMs deploy
2. ✅ roxagent runs
3. ✅ VMs appear in RHACS
4. ❌ No packages installed
5. ❌ No vulnerability data

**Then you manually run:** `./setup-demo-packages.sh`

### With `vm-config.env` (New Automated Behavior):
1. ✅ VMs deploy
2. ✅ Cloud-init registers VMs with Red Hat subscription
3. ✅ Cloud-init installs DNF packages
4. ✅ roxagent runs and scans packages
5. ✅ **VMs appear in RHACS with vulnerability data immediately!**

No manual steps needed!

---

## Timeline

| Time | Event |
|------|-------|
| 0 min | `./install.sh` starts |
| 0-2 min | RHACS configuration applied |
| 2-5 min | VMs deploying |
| 5-8 min | Cloud-init running (registration + package install) |
| 8-10 min | roxagent first scan |
| 10-12 min | Vulnerability data appears in RHACS |

**Total time:** ~10-15 minutes for complete demo with vulnerability data

---

## VM Package Profiles

### rhel-webserver
```yaml
Packages: httpd nginx php php-mysqlnd mod_ssl mod_security
Use Case: Web application vulnerabilities
Expected CVEs: Common web server vulnerabilities
```

### rhel-database
```yaml
Packages: postgresql postgresql-server mariadb mariadb-server
Use Case: Database security scanning
Expected CVEs: Database-related vulnerabilities
```

### rhel-devtools
```yaml
Packages: git gcc python3 nodejs java-11-openjdk-devel maven
Use Case: Development tool vulnerabilities
Expected CVEs: Compiler and runtime vulnerabilities
```

### rhel-monitoring
```yaml
Packages: grafana telegraf collectd net-snmp
Use Case: Monitoring stack vulnerabilities
Expected CVEs: Monitoring tool vulnerabilities
```

---

## Configuration Options

### `vm-config.env` Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `RH_USERNAME` | If using username/password | Red Hat account username |
| `RH_PASSWORD` | If using username/password | Red Hat account password |
| `RH_ORG_ID` | If using org/key | Red Hat organization ID |
| `RH_ACTIVATION_KEY` | If using org/key | Activation key name |
| `INSTALL_PACKAGES` | Yes | Set to `"true"` to enable automated package installation |

### Security Notes

⚠️ **`vm-config.env` contains sensitive credentials!**

- File is `.gitignore`'d (won't be committed)
- Credentials are embedded in cloud-init secrets in OpenShift
- Secrets are stored in the `default` namespace
- VMs receive credentials at boot time only

**Never commit `vm-config.env` to git!**

---

## Verification

### Check Configuration is Loaded

```bash
./install.sh
# Look for output:
# [INFO] Loading configuration from vm-config.env
# [INFO] Deployment Configuration:
#   • Package installation: true
#   • Auth method: Username/Password
#   • Username: your-username@redhat.com
```

### Check VMs Registered

```bash
# Inside a VM (wait 5-10 minutes after deployment)
virtctl console rhel-webserver -n default
# Login: cloud-user / redhat

sudo subscription-manager status
# Should show: "Overall Status: Current"

sudo dnf list installed | head -20
# Should show installed packages (httpd, nginx, php, etc.)
```

### Check RHACS Shows Vulnerability Data

```bash
./check-vm-status.sh
# Or open RHACS UI
```

**Expected output:**
- VMs visible
- "Scanned packages" shows package count (not "Not available")
- CVEs by severity shows numbers
- Last updated timestamp recent

---

## Troubleshooting

### Problem: "Package installation enabled but NO credentials provided!"

**Solution:**
```bash
# Create vm-config.env with your credentials
cp vm-config.env.example vm-config.env
vi vm-config.env
```

### Problem: VMs deployed but no packages installed

**Check cloud-init logs inside VM:**
```bash
virtctl console rhel-webserver -n default
sudo tail -100 /var/log/cloud-init-output.log | grep -i "subscription\|register\|dnf"
```

**Common issues:**
- Incorrect credentials
- Network connectivity issues
- Subscription not active

### Problem: Packages installed but no vulnerabilities in RHACS

**Check roxagent:**
```bash
# Inside VM
sudo systemctl status roxagent
sudo journalctl -u roxagent -n 50

# Should show scan completed and report sent
```

**Check Collector:**
```bash
# On bastion
./check-vm-status.sh
# Look for VSOCK connections in Collector logs
```

---

## Comparison: Manual vs Automated

### Manual Setup (Old Way)
```bash
# Step 1: Deploy infrastructure
./install.sh
# Wait 10 minutes

# Step 2: Generate package scripts  
./setup-demo-packages.sh
# Enter credentials

# Step 3: For each of 4 VMs:
virtctl console rhel-webserver -n default
# Copy/paste script
# Repeat for each VM
# 10-15 minutes per VM

# Total time: 40-60 minutes
```

### Automated Setup (New Way)
```bash
# Step 1: Configure once
cp vm-config.env.example vm-config.env
vi vm-config.env

# Step 2: Deploy everything
./install.sh
# Wait 10-15 minutes

# Total time: 10-15 minutes
```

**Time savings: 30-45 minutes!**

---

## Advanced Configuration

### Custom Package Sets

Edit `03-deploy-sample-vms.sh`:

```bash
declare -A VM_PROFILES=(
    ["webserver"]="httpd nginx php custom-package-1"
    ["database"]="postgresql mariadb custom-db"
    # ...
)
```

### Different RHEL Version

```bash
# In install.sh or export before running
export RHEL_IMAGE="registry.redhat.io/rhel8/rhel-guest-image:latest"
```

### Disable Package Installation

```bash
# In vm-config.env
INSTALL_PACKAGES="false"

# Or export before running
export INSTALL_PACKAGES=false
./install.sh
```

---

## Demo Script

### For Customers/Presentations

1. **Show the configuration:**
   ```bash
   cat vm-config.env.example
   # "Just add your Red Hat credentials here"
   ```

2. **Run the install:**
   ```bash
   ./install.sh
   # "One command deploys everything"
   ```

3. **Show progress:**
   ```bash
   oc get vmi -n default -w
   # "VMs are deploying"
   ```

4. **Show cloud-init working:**
   ```bash
   virtctl console rhel-webserver -n default
   sudo tail -f /var/log/cloud-init-output.log
   # Watch subscription registration and package installation live
   ```

5. **Show RHACS UI:**
   ```bash
   # Platform Configuration → Virtual Machines
   # Point out:
   # - All 4 VMs visible
   # - Packages scanned
   # - CVE counts
   # - Recent updates
   ```

6. **Demonstrate continuous scanning:**
   ```bash
   # Inside a VM
   sudo dnf install curl
   # Wait 2-3 minutes
   # Show new vulnerabilities appear in RHACS
   ```

---

## Files Reference

| File | Purpose |
|------|---------|
| `vm-config.env.example` | Template with all options |
| `vm-config.env` | Your credentials (create this, gitignored) |
| `install.sh` | Main orchestrator (reads vm-config.env) |
| `03-deploy-sample-vms.sh` | VM deployment (uses config) |
| `AUTOMATED-SETUP.md` | This guide |

---

**Remember:**
- ✅ `vm-config.env` = Automated package installation
- ❌ No `vm-config.env` = Manual package installation needed
- Both work, automated is faster for demos!
