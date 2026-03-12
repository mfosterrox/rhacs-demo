#!/bin/bash

# Script: 04-deploy-sample-vms.sh
# Description: Deploy 4 sample VMs with different DNF packages for vulnerability scanning demonstration

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

# Configuration
readonly NAMESPACE="${NAMESPACE:-default}"
readonly VM_CPUS="${VM_CPUS:-2}"
readonly VM_MEMORY="${VM_MEMORY:-4Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-external-storagecluster-ceph-rbd}"
readonly RHEL_IMAGE="${RHEL_IMAGE:-registry.redhat.io/rhel9/rhel-guest-image:latest}"
readonly ROXAGENT_VERSION="${ROXAGENT_VERSION:-4.9.2}"
readonly ROXAGENT_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXAGENT_VERSION}/bin/linux/roxagent"
readonly AUTO_CONFIRM="${AUTO_CONFIRM:-false}"  # Skip confirmation prompts

# Subscription credentials (can be set via command-line arguments or environment)
RHEL_USERNAME="${RHEL_USERNAME:-}"
RHEL_PASSWORD="${RHEL_PASSWORD:-}"
RHEL_ORG="${RHEL_ORG:-}"
RHEL_ACTIVATION_KEY="${RHEL_ACTIVATION_KEY:-}"
SKIP_SUBSCRIPTION="${SKIP_SUBSCRIPTION:-false}"

# SSH keys from bastion host for VM access (virtctl ssh)
# Set VM_SSH_PUBKEY for raw key content, or VM_SSH_KEY_PATH for a key file
VM_SSH_KEY_PATH="${VM_SSH_KEY_PATH:-}"

# VM profiles with different package sets
declare -A VM_PROFILES=(
    ["webserver"]="httpd nginx php php-mysqlnd mod_ssl mod_security"
    ["database"]="postgresql postgresql-server postgresql-contrib mariadb mariadb-server"
    ["devtools"]="git gcc gcc-c++ make python3 python3-pip nodejs npm java-11-openjdk-devel maven"
    ["monitoring"]="grafana telegraf collectd collectd-utils net-snmp net-snmp-utils"
)

declare -A VM_DESCRIPTIONS=(
    ["webserver"]="Web Server (Apache, Nginx, PHP)"
    ["database"]="Database Server (PostgreSQL, MariaDB)"
    ["devtools"]="Development Tools (Git, GCC, Python, Node.js, Java)"
    ["monitoring"]="Monitoring Stack (Grafana, Telegraf, Collectd)"
)

# Enable strict mode AFTER array declarations to avoid issues with bash -u flag
set -euo pipefail

#================================================================
# Check prerequisites
#================================================================
check_prerequisites() {
    print_step "Checking prerequisites..."
    
    # Check OpenShift Virtualization
    if ! oc get namespace openshift-cnv >/dev/null 2>&1; then
        print_error "OpenShift Virtualization not installed"
        return 1
    fi
    
    # Check VSOCK is enabled
    local kubevirt_name=$(oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${kubevirt_name}" ]; then
        print_error "KubeVirt not found"
        return 1
    fi
    
    local vsock_enabled=$(oc get kubevirt "${kubevirt_name}" -n openshift-cnv \
        -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | grep -o "VSOCK" || echo "")
    
    if [ -z "${vsock_enabled}" ]; then
        print_error "VSOCK not enabled"
        print_info "Run: ./install.sh first"
        return 1
    fi
    
    # Auto-detect storage class
    if ! oc get storageclass "${STORAGE_CLASS}" >/dev/null 2>&1; then
        print_warn "Storage class not found: ${STORAGE_CLASS}"
        print_info "Auto-detecting best available storage class..."
        
        local default_sc=$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null | awk '{print $1}')
        
        if [ -n "${default_sc}" ]; then
            STORAGE_CLASS="${default_sc}"
            print_info "Using default storage class: ${STORAGE_CLASS}"
        else
            local ocs_sc=$(oc get storageclass -o name 2>/dev/null | grep -E 'ocs.*ceph-rbd|odf.*ceph-rbd' | head -1 | sed 's|storageclass.storage.k8s.io/||')
            
            if [ -n "${ocs_sc}" ]; then
                STORAGE_CLASS="${ocs_sc}"
                print_info "Using OCS/ODF storage class: ${STORAGE_CLASS}"
            else
                local first_sc=$(oc get storageclass -o name 2>/dev/null | head -1 | sed 's|storageclass.storage.k8s.io/||')
                
                if [ -n "${first_sc}" ]; then
                    STORAGE_CLASS="${first_sc}"
                    print_info "Using first available storage class: ${STORAGE_CLASS}"
                else
                    print_error "No storage classes found"
                    return 1
                fi
            fi
        fi
    fi
    
    # Check SSH public key (optional; enables virtctl ssh; passwordless console always works)
    local ssh_key_file=""
    if [ -n "${VM_SSH_PUBKEY:-}" ]; then
        ssh_key_file="(VM_SSH_PUBKEY)"
    elif [ -n "${VM_SSH_KEY_PATH:-}" ] && [ -f "${VM_SSH_KEY_PATH}" ]; then
        ssh_key_file="${VM_SSH_KEY_PATH}"
    elif [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
        ssh_key_file="${HOME}/.ssh/id_ed25519.pub"
    elif [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
        ssh_key_file="${HOME}/.ssh/id_rsa.pub"
    fi
    if [ -z "${ssh_key_file}" ]; then
        # No key - generate one for virtctl ssh; console will use passwordless
        print_info "No SSH key found; generating ed25519 key for virtctl ssh..."
        mkdir -p "${HOME}/.ssh"
        chmod 700 "${HOME}/.ssh"
        ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519" -N "" -C "rhacs-vm-bastion"
        ssh_key_file="${HOME}/.ssh/id_ed25519.pub"
        print_info "Generated ${ssh_key_file}"
    fi
    print_info "Using SSH key: ${ssh_key_file} (console: cloud-user + Enter for password)"
    
    print_info "✓ Prerequisites met"
}

#================================================================
# Generate cloud-init for VM with specific packages
#================================================================
generate_cloudinit() {
    local vm_profile=$1
    local packages="${VM_PROFILES[$vm_profile]}"
    
    # Collect SSH public keys from bastion host for virtctl ssh (key-based login)
    local ssh_key_file=""
    if [ -n "${VM_SSH_PUBKEY:-}" ]; then
        ssh_key_file="/tmp/vm_ssh_pubkey_$$"
        echo "${VM_SSH_PUBKEY:-}" > "${ssh_key_file}"
    elif [ -n "${VM_SSH_KEY_PATH:-}" ] && [ -f "${VM_SSH_KEY_PATH}" ]; then
        ssh_key_file="${VM_SSH_KEY_PATH}"
    elif [ -f "${HOME}/.ssh/id_ed25519.pub" ]; then
        ssh_key_file="${HOME}/.ssh/id_ed25519.pub"
    elif [ -f "${HOME}/.ssh/id_rsa.pub" ]; then
        ssh_key_file="${HOME}/.ssh/id_rsa.pub"
    fi
    
    # Key optional: if present, enables virtctl ssh; otherwise console passwordless only
    if [ -n "${ssh_key_file}" ] && [ -f "${ssh_key_file}" ]; then
        :  # Will inject keys below
    else
        ssh_key_file=""
    fi
    
    # Start cloud-init
    cat <<EOF
#cloud-config
hostname: rhel-${vm_profile}
fqdn: rhel-${vm_profile}.local

users:
  - name: cloud-user
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
EOF
    if [ -n "${ssh_key_file}" ] && [ -f "${ssh_key_file}" ]; then
        echo "    ssh_authorized_keys:"
        while read -r key; do
            [ -n "${key}" ] && echo "      - ${key}"
        done < "${ssh_key_file}"
        [ "${ssh_key_file}" = "/tmp/vm_ssh_pubkey_$$" ] && rm -f "${ssh_key_file}"
    fi
    cat <<EOF

EOF

    # Add subscription registration if credentials provided
    if [ "${SKIP_SUBSCRIPTION}" != "true" ]; then
        if [ -n "${RHEL_USERNAME}" ] && [ -n "${RHEL_PASSWORD}" ]; then
            cat <<EOF
rh_subscription:
  username: "${RHEL_USERNAME}"
  password: "${RHEL_PASSWORD}"
  auto-attach: true

EOF
        elif [ -n "${RHEL_ORG}" ] && [ -n "${RHEL_ACTIVATION_KEY}" ]; then
            cat <<EOF
rh_subscription:
  activation-key: "${RHEL_ACTIVATION_KEY}"
  org: "${RHEL_ORG}"

EOF
        fi
    fi

    # Continue with runcmd
    cat <<EOF
runcmd:
  # Enable PAM nullok and passwordless for console access (fallback when SSH key fails)
  - |
    authselect enable-feature with-nullok 2>/dev/null || \
    for f in /etc/pam.d/system-auth /etc/pam.d/password-auth; do
      [ -f "\$f" ] && grep -q 'pam_unix.so' "\$f" && ! grep -q 'nullok' "\$f" && \
        sed -i '/pam_unix\.so/s/pam_unix\.so/& nullok/' "\$f"
    done
  - passwd -d cloud-user
  # SSH: allow both key and password auth (key for virtctl ssh, passwordless for console)
  - sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config
  - grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
  - grep -q '^PasswordAuthentication' /etc/ssh/sshd_config || echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config
  - grep -q '^PermitEmptyPasswords' /etc/ssh/sshd_config || echo 'PermitEmptyPasswords yes' >> /etc/ssh/sshd_config
  - systemctl restart sshd
  # Wait for network
  - until ping -c 1 8.8.8.8 &> /dev/null; do sleep 2; done
  
  # Create roxagent directory
  - mkdir -p /opt/roxagent
  - chmod 755 /opt/roxagent
  
  # Download roxagent binary (standalone, no package dependencies)
  - |
    echo "Downloading roxagent ${ROXAGENT_VERSION}..."
    curl -k -L -o /opt/roxagent/roxagent "${ROXAGENT_URL}"
    chmod +x /opt/roxagent/roxagent
  
  # Create systemd service for roxagent
  - |
    cat > /etc/systemd/system/roxagent.service <<'SYSTEMD_EOF'
    [Unit]
    Description=StackRox VM Agent for vulnerability scanning
    After=network-online.target
    Wants=network-online.target
    
    [Service]
    Type=simple
    ExecStart=/opt/roxagent/roxagent --daemon --index-interval=5m --verbose
    Restart=always
    RestartSec=10
    Environment="ROX_VIRTUAL_MACHINES_VSOCK_PORT=818"
    Environment="ROX_VIRTUAL_MACHINES_VSOCK_CONN_MAX_SIZE_KB=16384"
    StandardOutput=journal
    StandardError=journal
    
    [Install]
    WantedBy=multi-user.target
    SYSTEMD_EOF
  
  # Enable and start roxagent service
  - systemctl daemon-reload
  - systemctl enable roxagent
  - systemctl start roxagent
EOF

    # Add package installation if subscription is configured
    if [ "${SKIP_SUBSCRIPTION}" != "true" ] && { [ -n "${RHEL_USERNAME}" ] || [ -n "${RHEL_ORG}" ]; }; then
        cat <<EOF
  
  # Install packages for this profile (after subscription)
  - |
    echo "Installing packages for ${vm_profile} profile..."
    dnf install -y ${packages}
    echo "Packages installed. Restarting roxagent to scan new packages..."
    systemctl restart roxagent
EOF

        # Add webserver-specific configuration
        if [ "${vm_profile}" = "webserver" ]; then
            cat <<EOF
    
    # Start httpd service for webserver profile
    echo "Starting web server services..."
    systemctl enable httpd
    systemctl start httpd
    
    # Create a simple index page
    cat > /var/www/html/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
    <title>RHACS VM Scanning Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; background: #f5f5f5; }
        .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 800px; margin: 0 auto; }
        h1 { color: #cc0000; }
        .status { background: #d4edda; padding: 15px; border-radius: 5px; margin: 20px 0; border-left: 4px solid #28a745; }
        .info { background: #d1ecf1; padding: 15px; border-radius: 5px; margin: 20px 0; border-left: 4px solid #17a2b8; }
        code { background: #f8f9fa; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🛡️ RHACS VM Scanning Demo</h1>
        <div class="status">
            <strong>✓ Status:</strong> Webserver VM is running!
        </div>
        <div class="info">
            <h2>VM Information</h2>
            <p><strong>Profile:</strong> Web Server</p>
            <p><strong>Hostname:</strong> rhel-webserver</p>
            <p><strong>Packages:</strong> Apache (httpd), Nginx, PHP</p>
            <p><strong>Purpose:</strong> Vulnerability scanning demonstration</p>
        </div>
        <h2>About This Demo</h2>
        <p>This is a RHEL 9 virtual machine running inside OpenShift Virtualization.</p>
        <p>Red Hat Advanced Cluster Security (RHACS) is scanning this VM for vulnerabilities using the roxagent binary.</p>
        
        <h3>Installed Packages:</h3>
        <ul>
            <li>Apache HTTP Server (httpd)</li>
            <li>Nginx</li>
            <li>PHP with MySQL extensions</li>
            <li>mod_ssl, mod_security</li>
        </ul>
        
        <h3>How to Check Results:</h3>
        <ol>
            <li>Open RHACS Central UI</li>
            <li>Navigate to: <code>Platform Configuration → Clusters → Virtual Machines</code></li>
            <li>View vulnerabilities: <code>Vulnerability Management → Workload CVEs</code></li>
        </ol>
        
        <p style="margin-top: 30px; color: #666; font-size: 0.9em;">
            <strong>Demo Setup:</strong> This VM was deployed using OpenShift Virtualization and is being monitored by RHACS for security vulnerabilities.
        </p>
    </div>
</body>
</html>
HTMLEOF
    
    # Allow http traffic through firewall
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --reload || true
    
    echo "✓ Web server configured and accessible"
EOF
        fi

        cat <<EOF
  
  # Log completion with packages
  - echo "VM profile '${vm_profile}' configured with packages"
  - echo "roxagent service running with vulnerability data"

final_message: "RHEL VM '${vm_profile}' is ready with packages. roxagent scanning."
EOF
    else
        # No subscription - create install script for manual use
        cat <<EOF
  
  # Create package install script for later use (no subscription provided)
  - |
    cat > /root/install-packages.sh <<'PKG_SCRIPT'
    #!/bin/bash
    # Run this after registering subscription
    echo "Installing packages for ${vm_profile} profile..."
    dnf install -y ${packages}
EOF

        # Add webserver-specific configuration for manual script too
        if [ "${vm_profile}" = "webserver" ]; then
            cat <<EOF
    
    # Start httpd service for webserver profile
    echo "Starting web server services..."
    systemctl enable httpd
    systemctl start httpd
    
    # Create a simple index page
    cat > /var/www/html/index.html <<'HTMLEOF2'
<!DOCTYPE html>
<html>
<head>
    <title>RHACS VM Scanning Demo</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 50px; background: #f5f5f5; }
        .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); max-width: 800px; margin: 0 auto; }
        h1 { color: #cc0000; }
        .status { background: #d4edda; padding: 15px; border-radius: 5px; margin: 20px 0; border-left: 4px solid #28a745; }
        .info { background: #d1ecf1; padding: 15px; border-radius: 5px; margin: 20px 0; border-left: 4px solid #17a2b8; }
        code { background: #f8f9fa; padding: 2px 6px; border-radius: 3px; font-family: monospace; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🛡️ RHACS VM Scanning Demo</h1>
        <div class="status">
            <strong>✓ Status:</strong> Webserver VM is running!
        </div>
        <div class="info">
            <h2>VM Information</h2>
            <p><strong>Profile:</strong> Web Server</p>
            <p><strong>Hostname:</strong> rhel-webserver</p>
            <p><strong>Packages:</strong> Apache (httpd), Nginx, PHP</p>
            <p><strong>Purpose:</strong> Vulnerability scanning demonstration</p>
        </div>
        <h2>About This Demo</h2>
        <p>This is a RHEL 9 virtual machine running inside OpenShift Virtualization.</p>
        <p>Red Hat Advanced Cluster Security (RHACS) is scanning this VM for vulnerabilities using the roxagent binary.</p>
        
        <h3>Installed Packages:</h3>
        <ul>
            <li>Apache HTTP Server (httpd)</li>
            <li>Nginx</li>
            <li>PHP with MySQL extensions</li>
            <li>mod_ssl, mod_security</li>
        </ul>
        
        <h3>How to Check Results:</h3>
        <ol>
            <li>Open RHACS Central UI</li>
            <li>Navigate to: <code>Platform Configuration → Clusters → Virtual Machines</code></li>
            <li>View vulnerabilities: <code>Vulnerability Management → Workload CVEs</code></li>
        </ol>
        
        <p style="margin-top: 30px; color: #666; font-size: 0.9em;">
            <strong>Demo Setup:</strong> This VM was deployed using OpenShift Virtualization and is being monitored by RHACS for security vulnerabilities.
        </p>
    </div>
</body>
</html>
HTMLEOF2
    
    # Allow http traffic through firewall
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --reload || true
    
    echo "✓ Web server configured and accessible"
EOF
        fi

        cat <<EOF
    
    echo "Packages installed. Restarting roxagent to scan new packages..."
    systemctl restart roxagent
    PKG_SCRIPT
  
  - chmod +x /root/install-packages.sh
  
  # Log completion without packages
  - echo "VM profile '${vm_profile}' configured (no packages installed)"
  - echo "roxagent service started"
  - echo "To install packages: Register subscription and run /root/install-packages.sh"

final_message: "RHEL VM '${vm_profile}' is ready. Register subscription to install packages."
EOF
    fi
}

#================================================================
# Deploy a single VM
#================================================================
deploy_vm() {
    local vm_profile=$1
    local vm_name="rhel-${vm_profile}"
    local description="${VM_DESCRIPTIONS[$vm_profile]}"
    
    print_step "Deploying VM: ${vm_name}"
    print_info "Profile: ${description}"
    
    # Check if VM already exists
    if oc get vm "${vm_name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_warn "VM '${vm_name}' already exists - skipping creation"
        print_info "To recreate, first delete with: oc delete vm ${vm_name} -n ${NAMESPACE}"
        return 0
    fi
    
    # Create cloud-init secret
    local secret_name="cloudinit-${vm_profile}"
    print_info "Creating cloud-init secret: ${secret_name}"
    
    local cloudinit_content
    cloudinit_content=$(generate_cloudinit "${vm_profile}")
    
    local tmp_secret
    tmp_secret=$(mktemp)
    oc create secret generic "${secret_name}" \
        --from-literal=userdata="${cloudinit_content}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml > "${tmp_secret}"
    oc apply -f "${tmp_secret}" -n "${NAMESPACE}"
    rm -f "${tmp_secret}"
    
    # Deploy VM
    print_info "Creating VirtualMachine resource..."
    
    local tmp_vm
    tmp_vm=$(mktemp)
    cat > "${tmp_vm}" <<'VMYAML'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: __VM_NAME__
  namespace: __NAMESPACE__
  labels:
    app: rhacs-vm-scanning
    profile: __VM_PROFILE__
    roxagent: enabled
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: rhacs-vm-scanning
        profile: __VM_PROFILE__
        roxagent: enabled
        kubevirt.io/vm: __VM_NAME__
    spec:
      domain:
        cpu:
          cores: __VM_CPUS__
        devices:
          autoattachVSOCK: true
          disks:
          - name: containerdisk
            disk:
              bus: virtio
          - name: cloudinitdisk
            disk:
              bus: virtio
          interfaces:
          - name: default
            masquerade: {}
        resources:
          requests:
            memory: __VM_MEMORY__
      networks:
      - name: default
        pod: {}
      volumes:
      - name: containerdisk
        containerDisk:
          image: __RHEL_IMAGE__
      - name: cloudinitdisk
        cloudInitNoCloud:
          secretRef:
            name: __SECRET_NAME__
VMYAML
    sed -e "s|__VM_NAME__|${vm_name}|g" \
        -e "s|__NAMESPACE__|${NAMESPACE}|g" \
        -e "s|__VM_PROFILE__|${vm_profile}|g" \
        -e "s|__VM_CPUS__|${VM_CPUS}|g" \
        -e "s|__VM_MEMORY__|${VM_MEMORY}|g" \
        -e "s|__RHEL_IMAGE__|${RHEL_IMAGE}|g" \
        -e "s|__SECRET_NAME__|${secret_name}|g" "${tmp_vm}" > "${tmp_vm}.subst"
    mv "${tmp_vm}.subst" "${tmp_vm}"
    oc apply -f "${tmp_vm}"
    rm -f "${tmp_vm}"
    
    print_info "✓ VM '${vm_name}' deployed"
}

#================================================================
# Create Service and Route for webserver VM
#================================================================
create_webserver_route() {
    print_step "Configuring webserver route..."
    
    local vm_name="rhel-webserver"
    local service_name="rhel-webserver-http"
    local route_name="rhel-webserver"
    
    # Create Service to expose port 80
    print_info "Creating Service for webserver..."
    
    local tmp_svc
    tmp_svc=$(mktemp)
    cat > "${tmp_svc}" <<'SVCYAML'
apiVersion: v1
kind: Service
metadata:
  name: __SERVICE_NAME__
  namespace: __NAMESPACE__
  labels:
    app: rhacs-vm-scanning
    profile: webserver
spec:
  selector:
    kubevirt.io/vm: __VM_NAME__
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
SVCYAML
    sed -e "s|__SERVICE_NAME__|${service_name}|g" \
        -e "s|__NAMESPACE__|${NAMESPACE}|g" \
        -e "s|__VM_NAME__|${vm_name}|g" "${tmp_svc}" > "${tmp_svc}.subst"
    mv "${tmp_svc}.subst" "${tmp_svc}"
    oc apply -f "${tmp_svc}"
    rm -f "${tmp_svc}"
    
    if [ $? -eq 0 ]; then
        print_info "✓ Service created: ${service_name}"
    else
        print_error "Failed to create Service"
        return 1
    fi
    
    # Create Route
    print_info "Creating Route for webserver..."
    
    local tmp_route
    tmp_route=$(mktemp)
    cat > "${tmp_route}" <<'ROUTEYAML'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: __ROUTE_NAME__
  namespace: __NAMESPACE__
  labels:
    app: rhacs-vm-scanning
    profile: webserver
spec:
  to:
    kind: Service
    name: __SERVICE_NAME__
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
ROUTEYAML
    sed -e "s|__ROUTE_NAME__|${route_name}|g" \
        -e "s|__NAMESPACE__|${NAMESPACE}|g" \
        -e "s|__SERVICE_NAME__|${service_name}|g" "${tmp_route}" > "${tmp_route}.subst"
    mv "${tmp_route}.subst" "${tmp_route}"
    oc apply -f "${tmp_route}"
    rm -f "${tmp_route}"
    
    if [ $? -eq 0 ]; then
        print_info "✓ Route created: ${route_name}"
        
        # Wait a moment for route to be ready
        sleep 2
        
        # Get the route URL
        local route_url=$(oc get route "${route_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
        
        if [ -n "${route_url}" ]; then
            echo ""
            print_info "=========================================="
            print_info "✓ Webserver is accessible at:"
            echo "  https://${route_url}"
            print_info "=========================================="
            echo ""
            print_warn "Note: It may take 5-10 minutes for:"
            echo "  • VM to boot"
            echo "  • Packages to install (if subscription configured)"
            echo "  • Apache/Nginx to start"
            echo ""
            print_info "Test with: curl -k https://${route_url}"
        fi
    else
        print_error "Failed to create Route"
        return 1
    fi
}

#================================================================
# Wait for all VMs to be ready
#================================================================
wait_for_vms() {
    print_step "Checking VM status..."
    
    local ready_count=0
    local total_count=4  # We know we're deploying 4 VMs
    
    # Quick check if VMs are already running
    for profile in webserver database devtools monitoring; do
        local vm_name="rhel-${profile}"
        
        if oc get vmi "${vm_name}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            local phase=$(oc get vmi "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [ "${phase}" == "Running" ]; then
                ready_count=$((ready_count + 1))
            fi
        fi
    done
    
    print_info "VMs in Running state: ${ready_count}/${total_count}"
    
    if [ ${ready_count} -eq ${total_count} ]; then
        print_info "✓ All VMs are running"
    else
        print_warn "Some VMs still starting (${ready_count}/${total_count} running)"
        print_info "VMs will continue booting in the background"
        print_info "This is normal - VMs take 5-10 minutes to fully initialize"
    fi
    
    # Always return success - deployment is complete even if VMs are still booting
    return 0
}

#================================================================
# Display VM information
#================================================================
display_vm_info() {
    print_step "Virtual Machine Information"
    
    echo ""
    printf "%-20s %-15s %-10s %-15s\n" "VM NAME" "PROFILE" "STATUS" "VSOCK CID"
    printf "%-20s %-15s %-10s %-15s\n" "--------" "-------" "------" "---------"
    
    for profile in "${!VM_PROFILES[@]}"; do
        local vm_name="rhel-${profile}"
        local phase=$(oc get vmi "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        local vsock_cid=$(oc get vmi "${vm_name}" -n "${NAMESPACE}" -o jsonpath='{.status.VSOCKCID}' 2>/dev/null || echo "N/A")
        
        printf "%-20s %-15s %-10s %-15s\n" "${vm_name}" "${profile}" "${phase}" "${vsock_cid}"
    done
    
    echo ""
    print_info "SSH into VMs: virtctl ssh -i ~/.ssh/id_ed25519 cloud-user@vmi/<vm-name> -n ${NAMESPACE}"
    print_info "Check roxagent status inside VM: systemctl status roxagent"
    print_info "View installed DNF packages: dnf list installed"
    print_info "Monitor RHACS: Platform Configuration → Clusters → Virtual Machines"
}

#================================================================
# Parse command-line arguments
#================================================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --username)
                RHEL_USERNAME="$2"
                shift 2
                ;;
            --password)
                RHEL_PASSWORD="$2"
                shift 2
                ;;
            --org)
                RHEL_ORG="$2"
                shift 2
                ;;
            --activation-key)
                RHEL_ACTIVATION_KEY="$2"
                shift 2
                ;;
            --skip-subscription)
                SKIP_SUBSCRIPTION=true
                shift
                ;;
            -h|--help)
                cat <<EOF
Usage: $0 [OPTIONS]

Deploy 4 sample RHEL VMs with roxagent for RHACS vulnerability scanning.

Subscription Options (choose one):
  --username USER         Red Hat customer portal username
  --password PASS         Red Hat customer portal password
  
  OR
  
  --org ORG              Organization ID
  --activation-key KEY   Activation key
  
  --skip-subscription    Skip subscription registration (VMs won't have packages)

Other Options:
  -h, --help            Show this help

Environment Variables:
  NAMESPACE            VM namespace (default: default)
  VM_CPUS              VM CPU count (default: 2)
  VM_MEMORY            VM memory (default: 4Gi)
  STORAGE_CLASS        Storage class for VM disks (auto-detected)
  RHEL_USERNAME        Red Hat username (alternative to --username)
  RHEL_PASSWORD        Red Hat password (alternative to --password)
  RHEL_ORG             Organization ID (alternative to --org)
  RHEL_ACTIVATION_KEY  Activation key (alternative to --activation-key)
  AUTO_CONFIRM         Skip confirmation prompts (default: false)

Examples:
  # Deploy with username/password (recommended for demo)
  $0 --username myuser --password mypass

  # Deploy with activation key
  $0 --org 12345678 --activation-key my-key

  # Deploy without subscription (VMs won't install packages)
  $0 --skip-subscription

  # Use environment variables
  export RHEL_USERNAME="myuser" RHEL_PASSWORD="mypass"
  $0

What Gets Deployed:
  • rhel-webserver   - Apache, Nginx, PHP (accessible via Route!)
  • rhel-database    - PostgreSQL, MariaDB
  • rhel-devtools    - Git, GCC, Python, Node.js, Java
  • rhel-monitoring  - Grafana, Telegraf, Collectd

With subscription credentials, packages are installed automatically via cloud-init!

The webserver VM includes:
  ✓ OpenShift Service and Route (HTTPS with TLS)
  ✓ Apache HTTP Server enabled and started
  ✓ Custom demo HTML page
  ✓ Accessible from browser immediately after packages install

EOF
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done
}

#================================================================
# Main execution
#================================================================
main() {
    # Parse command-line arguments
    parse_arguments "$@"
    
    echo ""
    echo "=========================================="
    echo "  RHACS VM Vulnerability Scanning Demo"
    echo "  Deploy Sample VMs"
    echo "=========================================="
    echo ""
    
    check_prerequisites
    
    echo ""
    print_step "VM Profiles to Deploy:"
    for profile in "${!VM_PROFILES[@]}"; do
        echo "  • ${profile}: ${VM_DESCRIPTIONS[$profile]}"
    done
    
    echo ""
    
    # Display subscription status
    if [ "${SKIP_SUBSCRIPTION}" = "true" ]; then
        print_warn "Subscription: Disabled"
        print_info "  VMs will NOT install packages automatically"
        print_info "  You'll need to register and install packages manually"
    elif [ -n "${RHEL_USERNAME}" ] && [ -n "${RHEL_PASSWORD}" ]; then
        print_info "✓ Subscription: Username/Password provided"
        print_info "  VMs will automatically register and install packages"
        print_info "  User: ${RHEL_USERNAME}"
    elif [ -n "${RHEL_ORG}" ] && [ -n "${RHEL_ACTIVATION_KEY}" ]; then
        print_info "✓ Subscription: Activation key provided"
        print_info "  VMs will automatically register and install packages"
        print_info "  Org: ${RHEL_ORG}"
    else
        print_warn "⚠ No subscription credentials provided"
        print_info "  VMs will boot but won't install packages"
        print_info "  To enable automatic package installation:"
        echo "    --username USER --password PASS"
        echo "    OR"
        echo "    --org ORG --activation-key KEY"
        echo ""
        if [ "${AUTO_CONFIRM}" != "true" ]; then
            read -p "Continue without subscription? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                print_info "Deployment cancelled"
                exit 0
            fi
        fi
    fi
    
    echo ""
    
    if [ "${AUTO_CONFIRM}" != "true" ]; then
        read -p "Deploy all 4 VMs? (y/N): " -n 1 -r
        echo
        
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Deployment cancelled"
            exit 0
        fi
        echo ""
    else
        print_info "Auto-confirm enabled: deploying all 4 VMs"
        echo ""
    fi
    
    # Deploy each VM
    for profile in webserver database devtools monitoring; do
        deploy_vm "${profile}" || true  # Continue even if one fails
        echo ""
    done
    
    # Create route for webserver VM
    echo ""
    create_webserver_route || print_warn "Failed to create webserver route (non-fatal)"
    
    echo ""
    print_info "✓ Sample VM deployment complete!"
    print_info "VMs are now starting in the background..."
    echo ""
    
    if [ "${SKIP_SUBSCRIPTION}" != "true" ] && { [ -n "${RHEL_USERNAME}" ] || [ -n "${RHEL_ORG}" ]; }; then
        print_info "Cloud-init will (this takes 5-10 minutes):"
        echo "  1. Create cloud-user with passwordless login"
        echo "  2. Register Red Hat subscription"
        echo "  3. Install profile-specific packages"
        echo "  4. Download and start roxagent"
        echo ""
        print_info "✓ VMs will have vulnerability data automatically!"
        echo ""
        print_info "Timeline:"
        echo "  • 0-3 min:   VMs booting, cloud-init starting"
        echo "  • 3-7 min:   Subscription registering, packages installing"
        echo "  • 7-10 min:  roxagent scanning packages"
        echo "  • 10+ min:   Vulnerability data visible in RHACS UI"
        echo ""
        print_info "Check VM status:"
        echo "  $ oc get vmi -n ${NAMESPACE}"
        echo ""
        print_info "Access webserver via route:"
        local route_url=$(oc get route rhel-webserver -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
        if [ -n "${route_url}" ]; then
            echo "  https://${route_url}"
        else
            echo "  (Route will be available once created)"
        fi
        echo ""
        print_info "SSH into VM (key-based; virtctl ssh does not support password):"
        echo "  $ virtctl ssh -i ~/.ssh/id_ed25519 cloud-user@vmi/rhel-webserver -n ${NAMESPACE}"
        echo ""
        print_warn "If SSH fails, use console: virtctl console rhel-webserver -n ${NAMESPACE} (login: cloud-user, password: Enter)"
        print_warn "Or recreate VMs to pick up bastion key: oc delete vm rhel-webserver rhel-database rhel-devtools rhel-monitoring -n ${NAMESPACE} && $0"
        echo ""
        print_info "Monitor RHACS:"
        echo "  Platform Configuration → Clusters → Virtual Machines"
        echo "  Vulnerability Management → Workload CVEs"
    else
        print_info "Cloud-init will:"
        echo "  • Create cloud-user with SSH key auth (bastion key)"
        echo "  • Download and start roxagent"
        echo ""
        print_warn "⚠ No subscription configured - packages NOT installed"
        echo ""
        print_info "VMs will boot in 3-5 minutes"
        echo ""
        print_info "Access webserver via route:"
        local route_url=$(oc get route rhel-webserver -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
        if [ -n "${route_url}" ]; then
            echo "  https://${route_url}"
        else
            echo "  (Route created: rhel-webserver)"
        fi
        echo ""
        print_info "To add vulnerability data:"
        echo ""
        echo "  1. SSH into VM:"
        echo "     $ virtctl ssh -i ~/.ssh/id_ed25519 cloud-user@vmi/rhel-webserver -n ${NAMESPACE}"
        echo ""
        echo "  2. Register subscription:"
        echo "     $ sudo subscription-manager register --username USER --password PASS"
        echo "     $ sudo subscription-manager attach --auto"
        echo ""
        echo "  3. Install packages (this will also start httpd):"
        echo "     $ sudo /root/install-packages.sh"
        echo ""
        print_info "Or re-deploy with subscription credentials:"
        echo "  $ $0 --username USER --password PASS"
    fi
}

main "$@"
