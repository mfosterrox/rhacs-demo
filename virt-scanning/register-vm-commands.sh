#!/bin/bash

# Helper script to generate VM registration and package installation commands

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${CYAN}=== RHEL VM Registration and Package Installation Commands ===${NC}"
echo ""
echo "Run these commands IN EACH VM via virtctl console"
echo ""

# Get credentials
echo -e "${GREEN}Enter your Red Hat subscription credentials:${NC}"
read -p "Username: " RH_USERNAME
read -sp "Password: " RH_PASSWORD
echo ""
echo ""

# Generate commands for each VM
declare -A VM_PACKAGES=(
    ["rhel-webserver"]="httpd nginx php php-mysqlnd mod_ssl"
    ["rhel-database"]="postgresql postgresql-server mariadb mariadb-server"
    ["rhel-devtools"]="git gcc make python3 python3-pip nodejs java-11-openjdk-devel"
    ["rhel-monitoring"]="net-snmp prometheus2"
)

for vm_name in rhel-webserver rhel-database rhel-devtools rhel-monitoring; do
    packages="${VM_PACKAGES[$vm_name]}"
    
    echo -e "${BOLD}=== ${vm_name} ===${NC}"
    echo ""
    echo "# 1. Access VM console:"
    echo "virtctl console ${vm_name} -n default"
    echo "# Login: cloud-user / redhat"
    echo ""
    echo "# 2. Register with Red Hat:"
    echo "sudo subscription-manager register --username '${RH_USERNAME}' --password '${RH_PASSWORD}' --auto-attach"
    echo ""
    echo "# 3. Install packages:"
    echo "sudo dnf install -y ${packages}"
    echo ""
    echo "# 4. Restart roxagent:"
    echo "sudo systemctl restart roxagent"
    echo ""
    echo "# 5. Exit console (Ctrl+])"
    echo ""
    echo "---"
    echo ""
done

echo -e "${GREEN}After running commands in all VMs:${NC}"
echo "• Wait 2-3 minutes"
echo "• Check RHACS UI for vulnerabilities"
echo "• Run: ./check-vm-status.sh"
echo ""
