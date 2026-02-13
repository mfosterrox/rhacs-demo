#!/bin/bash

# Script: setup-demo-packages.sh
# Description: Quick setup script to install packages in VMs for RHACS vulnerability demo
# This generates ready-to-use commands for each VM

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_header() { echo -e "${BOLD}${CYAN}$*${NC}"; }
print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }

clear
print_header "╔════════════════════════════════════════════════════════════╗"
print_header "║      RHACS VM Vulnerability Scanning - Demo Setup         ║"
print_header "╚════════════════════════════════════════════════════════════╝"
echo ""

echo "This script generates commands to install packages in your VMs."
echo "You'll need Red Hat subscription credentials."
echo ""

# Get credentials
read -p "Red Hat Username: " RH_USER
read -sp "Red Hat Password: " RH_PASS
echo ""
echo ""

# Create output directory
OUTPUT_DIR="/tmp/vm-registration-scripts"
mkdir -p "$OUTPUT_DIR"

print_info "Generating registration scripts..."
echo ""

# Define VM packages
declare -A VM_PACKAGES=(
    ["rhel-webserver"]="httpd nginx php"
    ["rhel-database"]="postgresql mariadb"
    ["rhel-devtools"]="git gcc python3"
    ["rhel-monitoring"]="net-snmp"
)

# Generate script for each VM
for vm_name in "${!VM_PACKAGES[@]}"; do
    script_file="${OUTPUT_DIR}/${vm_name}-setup.sh"
    packages="${VM_PACKAGES[$vm_name]}"
    
    cat > "$script_file" << 'EOFSCRIPT'
#!/bin/bash
# Run this inside the VM

set -e

echo "========================================="
echo "Setting up VMNAME"
echo "========================================="
echo ""

# Register with Red Hat
echo "[1/4] Registering with Red Hat subscription..."
sudo subscription-manager register \
  --username 'RHUSER' \
  --password 'RHPASS' \
  --auto-attach

# Update repos
echo ""
echo "[2/4] Updating package repositories..."
sudo dnf clean all
sudo dnf makecache -y

# Install packages
echo ""
echo "[3/4] Installing packages: PACKAGES"
sudo dnf install -y PACKAGES

# Restart roxagent
echo ""
echo "[4/4] Restarting roxagent for immediate scan..."
sudo systemctl restart roxagent

echo ""
echo "========================================="
echo "✓ Setup complete for VMNAME!"
echo "✓ roxagent will scan and report to RHACS in 1-2 minutes"
echo "========================================="
EOFSCRIPT
    
    # Replace placeholders (compatible with both GNU and BSD sed)
    if sed --version &>/dev/null 2>&1; then
        # GNU sed
        sed -i "s/VMNAME/${vm_name}/g" "$script_file"
        sed -i "s/RHUSER/${RH_USER}/g" "$script_file"
        sed -i "s/RHPASS/${RH_PASS}/g" "$script_file"
        sed -i "s/PACKAGES/${packages}/g" "$script_file"
    else
        # BSD sed (macOS)
        sed -i "" "s/VMNAME/${vm_name}/g" "$script_file"
        sed -i "" "s/RHUSER/${RH_USER}/g" "$script_file"
        sed -i "" "s/RHPASS/${RH_PASS}/g" "$script_file"
        sed -i "" "s/PACKAGES/${packages}/g" "$script_file"
    fi
    
    chmod +x "$script_file"
    
    print_info "✓ Created: $script_file"
done

echo ""
print_header "═══════════════════════════════════════════════════════════"
print_header "            Scripts Generated Successfully!                "
print_header "═══════════════════════════════════════════════════════════"
echo ""

print_info "Next steps - Run these commands for each VM:"
echo ""

for vm_name in rhel-webserver rhel-database rhel-devtools rhel-monitoring; do
    echo -e "${BOLD}# ${vm_name}:${NC}"
    echo "virtctl console ${vm_name} -n default"
    echo "# Login: cloud-user / redhat"
    echo "# Then copy/paste this entire script:"
    echo "cat ${OUTPUT_DIR}/${vm_name}-setup.sh"
    echo "# Or manually run the commands from that file"
    echo ""
done

print_info "Alternative - Copy script content into each VM:"
echo ""
for vm_name in rhel-webserver rhel-database rhel-devtools rhel-monitoring; do
    echo "cat ${OUTPUT_DIR}/${vm_name}-setup.sh"
    echo ""
done

echo ""
print_header "After running in all VMs:"
echo "• Wait 2-3 minutes for scanning"
echo "• Check RHACS UI: Platform Configuration → Virtual Machines"
echo "• Run: ./check-vm-status.sh"
echo ""

print_info "Scripts location: ${OUTPUT_DIR}/"
echo ""
