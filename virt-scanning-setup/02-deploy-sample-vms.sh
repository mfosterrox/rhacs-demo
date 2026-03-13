#!/bin/bash

# Script: 02-deploy-sample-vms.sh
# Description: Deploy a simple webserver VM into OpenShift

set -euo pipefail

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
_namespace="${NAMESPACE:-default}"
_namespace="$(printf '%s' "${_namespace}" | tr -d '\n\r')"
_namespace="${_namespace:-default}"
[[ "${_namespace}" == "openshift-cnv" ]] && _namespace="default"
readonly NAMESPACE="${_namespace}"
readonly VM_NAME="rhel-webserver"
readonly VM_CPUS="${VM_CPUS:-2}"
readonly VM_MEMORY="${VM_MEMORY:-4Gi}"
readonly RHEL_IMAGE="${RHEL_IMAGE:-registry.redhat.io/rhel9/rhel-guest-image:latest}"
readonly ROXAGENT_VERSION="${ROXAGENT_VERSION:-4.9.2}"
readonly ROXAGENT_URL="https://mirror.openshift.com/pub/rhacs/assets/${ROXAGENT_VERSION}/bin/linux/roxagent"
readonly AUTO_CONFIRM="${AUTO_CONFIRM:-false}"

#================================================================
# Check prerequisites
#================================================================
check_prerequisites() {
    print_step "Checking prerequisites..."

    if ! oc get namespace openshift-cnv >/dev/null 2>&1; then
        print_error "OpenShift Virtualization not installed"
        return 1
    fi

    local kubevirt_name
    kubevirt_name=$(oc get kubevirt -n openshift-cnv -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${kubevirt_name}" ]; then
        print_error "KubeVirt not found"
        return 1
    fi

    local vsock_enabled
    vsock_enabled=$(oc get kubevirt "${kubevirt_name}" -n openshift-cnv \
        -o jsonpath='{.spec.configuration.developerConfiguration.featureGates}' 2>/dev/null | grep -o "VSOCK" || echo "")

    if [ -z "${vsock_enabled}" ]; then
        print_error "VSOCK not enabled. Run: ./01-configure-rhacs.sh first"
        return 1
    fi

    print_info "✓ Prerequisites met"
}

#================================================================
# Generate cloud-init for webserver VM
#================================================================
generate_cloudinit() {
    cat <<EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}.local

users:
  - name: user
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: '\$6\$rhel9\$m89er/tVO6eGZRrFxq/flsNZJGfaozve4SkHdEWCWQs1NAzqC0Xg2ed5vyNu7WY7RGt3gV/FMf6cwaq5g/wbg0'
EOF

    cat <<EOF
runcmd:
  # Wait for network
  - until ping -c 1 8.8.8.8 &> /dev/null; do sleep 2; done
  # roxagent for RHACS
  - mkdir -p /opt/roxagent && chmod 755 /opt/roxagent
  - curl -k -L -o /opt/roxagent/roxagent "${ROXAGENT_URL}" && chmod +x /opt/roxagent/roxagent
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
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF
  - systemctl daemon-reload && systemctl enable roxagent && systemctl start roxagent

  # Create install script for manual package install (run after: sudo subscription-manager register ...)
  - |
    cat > /root/install-packages.sh <<'PKG_SCRIPT'
#!/bin/bash
# Run after: sudo subscription-manager register --username USER --password PASS --auto-attach
dnf install -y httpd
systemctl enable httpd && systemctl start httpd
echo '<h1>RHACS VM Demo</h1>' > /var/www/html/index.html
firewall-cmd --permanent --add-service=http || true
firewall-cmd --reload || true
systemctl restart roxagent
PKG_SCRIPT
  - chmod +x /root/install-packages.sh
EOF

    cat <<EOF

final_message: "VM ${VM_NAME} is ready. Console: virtctl console ${VM_NAME} -n ${NAMESPACE}"
EOF
}

#================================================================
# Deploy VM
#================================================================
deploy_vm() {
    print_step "Deploying VM: ${VM_NAME}"

    if oc get vm "${VM_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        print_warn "VM '${VM_NAME}' already exists - skipping"
        print_info "To recreate: oc delete vm ${VM_NAME} -n ${NAMESPACE}"
        return 0
    fi

    local secret_name="cloudinit-webserver"
    print_info "Creating cloud-init secret..."

    local cloudinit_content
    cloudinit_content=$(generate_cloudinit)

    local tmp_secret
    tmp_secret=$(mktemp)
    oc create secret generic "${secret_name}" \
        --from-literal=userdata="${cloudinit_content}" \
        -n "${NAMESPACE}" \
        --dry-run=client -o yaml > "${tmp_secret}"
    oc apply -f "${tmp_secret}" -n "${NAMESPACE}"
    rm -f "${tmp_secret}"

    print_info "Creating VirtualMachine..."

    local tmp_vm
    tmp_vm=$(mktemp)
    cat > "${tmp_vm}" <<VMYAML
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${VM_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: rhacs-vm-scanning
    profile: webserver
spec:
  runStrategy: Always
  template:
    metadata:
      labels:
        app: rhacs-vm-scanning
        profile: webserver
        kubevirt.io/vm: ${VM_NAME}
    spec:
      domain:
        cpu:
          cores: ${VM_CPUS}
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
            memory: ${VM_MEMORY}
      networks:
      - name: default
        pod: {}
      volumes:
      - name: containerdisk
        containerDisk:
          image: ${RHEL_IMAGE}
      - name: cloudinitdisk
        cloudInitNoCloud:
          secretRef:
            name: ${secret_name}
VMYAML
    oc apply -f "${tmp_vm}"
    rm -f "${tmp_vm}"

    print_info "✓ VM '${VM_NAME}' deployed"
}

#================================================================
# Create Service and Route for webserver
#================================================================
create_webserver_route() {
    print_step "Creating Service and Route for webserver..."

    local service_name="rhel-webserver-http"
    local route_name="rhel-webserver"

    oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${service_name}
  namespace: ${NAMESPACE}
  labels:
    app: rhacs-vm-scanning
spec:
  selector:
    kubevirt.io/vm: ${VM_NAME}
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${route_name}
  namespace: ${NAMESPACE}
  labels:
    app: rhacs-vm-scanning
spec:
  to:
    kind: Service
    name: ${service_name}
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

    print_info "✓ Service and Route created"
    sleep 2
    local route_url
    route_url=$(oc get route "${route_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -n "${route_url}" ]; then
        echo ""
        print_info "Webserver URL: https://${route_url}"
        echo ""
    fi
}

#================================================================
# Parse arguments
#================================================================
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                cat <<EOF
Usage: $0 [OPTIONS]

Deploy a simple webserver VM into OpenShift.

Console: virtctl console ${VM_NAME} -n ${NAMESPACE} (user/redhat)
Then: sudo subscription-manager register ... && sudo /root/install-packages.sh

EOF
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

#================================================================
# Main
#================================================================
main() {
    parse_arguments "$@"

    echo ""
    echo "=========================================="
    echo "  Deploy Webserver VM"
    echo "=========================================="
    echo ""

    check_prerequisites
    echo ""

    if [ "${AUTO_CONFIRM}" != "true" ]; then
        read -p "Deploy webserver VM? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Cancelled"
            exit 0
        fi
        echo ""
    fi

    deploy_vm
    echo ""
    create_webserver_route || print_warn "Route creation failed (non-fatal)"
    echo ""

    print_info "✓ Deployment complete!"
    echo ""
    print_info "VM will be ready in ~3-5 minutes."
    echo ""
    print_info "Console access, then run:"
    echo ""
    echo "  virtctl console ${VM_NAME} -n ${NAMESPACE}"
    echo "  (login: user / redhat)"
    echo ""
    echo "  sudo subscription-manager register --username <user> --password <pass> --auto-attach"
    echo "  sudo /root/install-packages.sh"
    echo ""
    print_info "Status: oc get vmi -n ${NAMESPACE}"
    echo ""
}

main "$@"
