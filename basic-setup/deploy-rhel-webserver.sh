#!/usr/bin/env bash
# Create the RHACS demo RHEL guest on a worker node.
#
# The guest is rhel-webserver in the rhel-webserver namespace. Cloud-init runs
# scripts/init-vm.sh, which installs the RHACS 5.0.0 roxagent. That userdata
# is stored in Secret rhel-webserver-cloudinit. KubeVirt rejects inline
# cloudInitNoCloud userData larger than 2048 bytes, and the init script
# exceeds that limit. Scheduling requires a Ready worker that is not a
# control-plane or master node. This script does not fall back to the
# control plane.
#
# If the guest is already running on a worker, it is left in place. If it is
# on a control-plane node, it is deleted and created again on a worker.
#
# Satellite credential order (the activation key is never printed):
#   1. Secret rhacs-vm-satellite in namespace rhel-webserver
#   2. RHACS_VM_SATELLITE_URL, RHACS_VM_SATELLITE_ORG, RHACS_VM_SATELLITE_ACTIVATIONKEY
#   3. Cloud-init userData already stored on an existing rhel-webserver VM
#   4. Built-in demosat registration previously used for this guest
#
# Guest password: ROX_PASSWORD, or the central-htpasswd secret when that is unset.
# Skip: SKIP_RHEL_VM=1

set -euo pipefail

_RHACS_DEMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "${_RHACS_DEMO_ROOT}/setup-rerun-hint.sh"
setup_rerun_register "${BASH_SOURCE[0]}" "$@"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

die() {
    print_error "$*"
    setup_rerun_hint_print
    exit 1
}

error_handler() {
    print_error "Script failed at line $2 (exit code: $1)"
    setup_rerun_hint_print
    exit "$1"
}
trap 'error_handler $? $LINENO' ERR

VM_NAME="${RHACS_VM_NAME:-rhel-webserver}"
VM_NAMESPACE="${RHACS_VM_NAMESPACE:-rhel-webserver}"
SECRET_NAME="${RHACS_VM_SATELLITE_SECRET:-rhacs-vm-satellite}"
CLOUDINIT_SECRET_NAME="${RHACS_VM_CLOUDINIT_SECRET:-${VM_NAME}-cloudinit}"
# Temporary fallback when provision did not publish Satellite credentials.
DEFAULT_SAT_URL="demosat-ha.infra.demo.redhat.com"
DEFAULT_SAT_ORG="Red_Hat_RHDP_Labs"
DEFAULT_SAT_KEY="demosat-smt-lb1161-wolfgang"
DATASOURCE_NAME="${RHACS_VM_DATASOURCE:-rhel10}"
DATASOURCE_NAMESPACE="${RHACS_VM_DATASOURCE_NAMESPACE:-openshift-virtualization-os-images}"
MANIFEST=""
CLOUDINIT_MANIFEST=""
SAT_URL=""
SAT_ORG=""
SAT_KEY=""
SAT_SOURCE=""

cleanup() {
    if [ -n "${MANIFEST}" ] && [ -f "${MANIFEST}" ]; then
        rm -f "${MANIFEST}"
    fi
    if [ -n "${CLOUDINIT_MANIFEST}" ] && [ -f "${CLOUDINIT_MANIFEST}" ]; then
        rm -f "${CLOUDINIT_MANIFEST}"
    fi
}
trap cleanup EXIT

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

list_eligible_workers() {
    oc get nodes -o json | jq -r '
        .items[]
        | select(.metadata.labels["node-role.kubernetes.io/worker"] != null)
        | select(.metadata.labels["node-role.kubernetes.io/control-plane"] == null)
        | select(.metadata.labels["node-role.kubernetes.io/master"] == null)
        | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
        | .metadata.name
    '
}

node_is_control_plane() {
    local node="$1"
    local role
    role="$(oc get node "${node}" -o json | jq -r '
        if (.metadata.labels["node-role.kubernetes.io/control-plane"] != null
            or .metadata.labels["node-role.kubernetes.io/master"] != null)
        then "yes" else "no" end
    ')"
    [ "${role}" = "yes" ]
}

node_is_eligible_worker() {
    local node="$1"
    local role
    role="$(oc get node "${node}" -o json | jq -r '
        if (.metadata.labels["node-role.kubernetes.io/worker"] != null
            and .metadata.labels["node-role.kubernetes.io/control-plane"] == null
            and .metadata.labels["node-role.kubernetes.io/master"] == null)
        then "yes" else "no" end
    ')"
    [ "${role}" = "yes" ]
}

vm_exists() {
    oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" >/dev/null 2>&1
}

vmi_node() {
    oc get vmi "${VM_NAME}" -n "${VM_NAMESPACE}" -o jsonpath='{.status.nodeName}' 2>/dev/null || true
}

vm_has_worker_affinity() {
    oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" -o json | jq -e '
        .spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[]?
        | .matchExpressions as $expressions
        | ([$expressions[] | select(.key == "node-role.kubernetes.io/worker" and .operator == "Exists")] | length > 0)
          and ([$expressions[] | select(.key == "node-role.kubernetes.io/control-plane" and .operator == "DoesNotExist")] | length > 0)
          and ([$expressions[] | select(.key == "node-role.kubernetes.io/master" and .operator == "DoesNotExist")] | length > 0)
    ' >/dev/null
}

clear_satellite() {
    SAT_URL=""
    SAT_ORG=""
    SAT_KEY=""
    SAT_SOURCE=""
}

satellite_complete() {
    [ -n "${SAT_URL}" ] && [ -n "${SAT_ORG}" ] && [ -n "${SAT_KEY}" ]
}

normalize_satellite() {
    SAT_URL="$(trim "${SAT_URL}")"
    SAT_ORG="$(trim "${SAT_ORG}")"
    SAT_KEY="$(trim "${SAT_KEY}")"
    SAT_URL="${SAT_URL#https://}"
    SAT_URL="${SAT_URL#http://}"
    SAT_URL="${SAT_URL%%/*}"
}

secret_field() {
    local field="$1"
    oc get secret "${SECRET_NAME}" -n "${VM_NAMESPACE}" -o json | jq -r --arg field "${field}" '
        .data[$field] // "" | if . == "" then "" else @base64d end
    '
}

load_satellite_from_secret() {
    clear_satellite
    if ! oc get secret "${SECRET_NAME}" -n "${VM_NAMESPACE}" >/dev/null 2>&1; then
        return 1
    fi
    SAT_URL="$(secret_field url)"
    SAT_ORG="$(secret_field org)"
    SAT_KEY="$(secret_field activationkey)"
    normalize_satellite
    if satellite_complete; then
        SAT_SOURCE="secret ${SECRET_NAME}"
        return 0
    fi
    clear_satellite
    return 1
}

load_satellite_from_env() {
    clear_satellite
    SAT_URL="${RHACS_VM_SATELLITE_URL:-}"
    SAT_ORG="${RHACS_VM_SATELLITE_ORG:-}"
    SAT_KEY="${RHACS_VM_SATELLITE_ACTIVATIONKEY:-}"
    normalize_satellite
    if satellite_complete; then
        SAT_SOURCE="environment"
        return 0
    fi
    clear_satellite
    return 1
}

read_vm_userdata() {
    local inline="" secret_name=""
    inline="$(oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" -o json | jq -r '
        .spec.template.spec.volumes[]?
        | select(.name == "cloudinitdisk")
        | .cloudInitNoCloud.userData // empty
    ')"
    if [ -n "${inline}" ]; then
        printf '%s' "${inline}"
        return 0
    fi
    secret_name="$(oc get vm "${VM_NAME}" -n "${VM_NAMESPACE}" -o json | jq -r '
        .spec.template.spec.volumes[]?
        | select(.name == "cloudinitdisk")
        | .cloudInitNoCloud.userDataSecretRef.name // empty
    ')"
    if [ -z "${secret_name}" ]; then
        return 1
    fi
    oc get secret "${secret_name}" -n "${VM_NAMESPACE}" -o json 2>/dev/null | jq -r '
        .data.userdata // "" | if . == "" then "" else @base64d end
    '
}

load_satellite_from_vm() {
    local userdata=""
    clear_satellite
    if ! vm_exists; then
        return 1
    fi
    userdata="$(read_vm_userdata || true)"
    if [ -z "${userdata}" ]; then
        return 1
    fi
    if [[ "${userdata}" =~ https://([^[:space:]/]+)/pub/katello-ca-consumer-latest\.noarch\.rpm ]]; then
        SAT_URL="${BASH_REMATCH[1]}"
    fi
    if [[ "${userdata}" =~ --activationkey=\"([^\"]+)\" ]]; then
        SAT_KEY="${BASH_REMATCH[1]}"
    fi
    if [[ "${userdata}" =~ --org=\"([^\"]+)\" ]]; then
        SAT_ORG="${BASH_REMATCH[1]}"
    fi
    normalize_satellite
    if satellite_complete; then
        SAT_SOURCE="existing virtual machine cloud-init"
        return 0
    fi
    clear_satellite
    return 1
}

load_satellite_defaults() {
    clear_satellite
    SAT_URL="${DEFAULT_SAT_URL}"
    SAT_ORG="${DEFAULT_SAT_ORG}"
    SAT_KEY="${DEFAULT_SAT_KEY}"
    normalize_satellite
    if satellite_complete; then
        SAT_SOURCE="built-in demosat defaults"
        return 0
    fi
    clear_satellite
    return 1
}

resolve_satellite() {
    if load_satellite_from_secret; then
        return 0
    fi
    if load_satellite_from_env; then
        return 0
    fi
    if load_satellite_from_vm; then
        return 0
    fi
    if load_satellite_defaults; then
        return 0
    fi
    clear_satellite
    return 1
}

assert_embeddable() {
    local label="$1"
    local value="$2"
    if [[ "${value}" == *$'\n'* || "${value}" == *'"'* || "${value}" == *'$'* || "${value}" == *'`'* || "${value}" == *'\'* ]]; then
        die "Refusing to embed Satellite ${label}: unsupported character."
    fi
}

subscription_name() {
    local guid="${GUID:-}"
    if [[ "${guid}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        printf '%s' "${VM_NAME}-${guid}"
    else
        printf '%s' "${VM_NAME}"
    fi
}

resolve_vm_password() {
    local password=""
    local ns="${RHACS_NAMESPACE:-stackrox}"
    if [ -n "${ROX_PASSWORD:-}" ]; then
        printf '%s' "${ROX_PASSWORD}"
        return 0
    fi
    password="$(oc get secret central-htpasswd -n "${ns}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [ -n "${password}" ]; then
        printf '%s' "${password}"
        return 0
    fi
    return 1
}

build_userdata() {
    local password="$1"
    local sat_url="$2"
    local sat_org="$3"
    local sat_key="$4"
    local init_b64="$5"
    local guest_name="$6"
    local pass_json
    pass_json="$(jq -rn --arg p "${password}" '$p | @json')"

    cat <<EOF
#cloud-config
users:
  - name: rhel
    groups: wheel
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
    plain_text_passwd: ${pass_json}
chpasswd:
  expire: false
ssh_pwauth: true
runcmd:
EOF
    if [ -n "${sat_url}" ]; then
        cat <<EOF
  - curl -k -o /tmp/katello-ca-consumer-latest.noarch.rpm https://${sat_url}/pub/katello-ca-consumer-latest.noarch.rpm
  - rpm -Uvh /tmp/katello-ca-consumer-latest.noarch.rpm
  - |
    subscription-manager register \\
      --activationkey="${sat_key}" \\
      --org="${sat_org}" \\
      --name="${guest_name}" \\
      --force
  - subscription-manager release --set=10
  - |
    subscription-manager repos \\
    --enable=rhel-10-for-x86_64-baseos-rpms \\
    --enable=rhel-10-for-x86_64-appstream-rpms
EOF
    fi
    cat <<EOF
  - echo '${init_b64}' | base64 -d > /tmp/init.sh
  - chmod +x /tmp/init.sh
  - /tmp/init.sh
  - echo "Setup complete"
EOF
}

write_cloudinit_secret() {
    local userdata="$1"
    local dest="$2"
    jq -n \
        --arg userdata "${userdata}" \
        --arg name "${CLOUDINIT_SECRET_NAME}" \
        --arg ns "${VM_NAMESPACE}" \
        --arg app "${VM_NAME}" '
        {
            apiVersion: "v1",
            kind: "Secret",
            metadata: {
                name: $name,
                namespace: $ns,
                labels: {
                    app: $app,
                    "app.kubernetes.io/part-of": "rhacs-demo",
                    "app.kubernetes.io/component": "vm-cloudinit"
                }
            },
            type: "Opaque",
            stringData: {userdata: $userdata}
        }
    ' > "${dest}"
    chmod 600 "${dest}"
}

write_manifest() {
    local dest="$1"
    jq -n --arg name "${VM_NAME}" --arg ns "${VM_NAMESPACE}" --arg datasource "${DATASOURCE_NAME}" --arg datasource_ns "${DATASOURCE_NAMESPACE}" --arg cloudinit_secret "${CLOUDINIT_SECRET_NAME}" '
        def worker_affinity:
            {
                nodeAffinity: {
                    requiredDuringSchedulingIgnoredDuringExecution: {
                        nodeSelectorTerms: [
                            {
                                matchExpressions: [
                                    {key: "node-role.kubernetes.io/worker", operator: "Exists"},
                                    {key: "node-role.kubernetes.io/control-plane", operator: "DoesNotExist"},
                                    {key: "node-role.kubernetes.io/master", operator: "DoesNotExist"}
                                ]
                            }
                        ]
                    }
                }
            };
        {
            apiVersion: "kubevirt.io/v1",
            kind: "VirtualMachine",
            metadata: {
                name: $name,
                namespace: $ns,
                labels: {app: $name}
            },
            spec: {
                dataVolumeTemplates: [
                    {
                        metadata: {name: ($name + "-volume")},
                        spec: {
                            sourceRef: {
                                kind: "DataSource",
                                name: $datasource,
                                namespace: $datasource_ns
                            },
                            storage: {resources: {requests: {storage: "30Gi"}}},
                            nodePlacement: {affinity: worker_affinity}
                        }
                    }
                ],
                runStrategy: "Always",
                template: {
                    metadata: {
                        labels: {
                            "network.kubevirt.io/headlessService": "headless",
                            "kubevirt.io/domain": $name,
                            "kubevirt.io/size": "small"
                        }
                    },
                    spec: {
                        architecture: "amd64",
                        affinity: worker_affinity,
                        domain: {
                            cpu: {cores: 1, sockets: 1, threads: 1},
                            memory: {guest: "2Gi"},
                            devices: {
                                autoattachVSOCK: true,
                                disks: [
                                    {name: "rootdisk", bootOrder: 1},
                                    {name: "cloudinitdisk", disk: {bus: "virtio"}}
                                ],
                                interfaces: [
                                    {masquerade: {}, model: "virtio", name: "default"}
                                ],
                                rng: {}
                            },
                            features: {acpi: {}, smm: {enabled: true}},
                            firmware: {bootloader: {efi: {}}},
                            machine: {type: "pc-q35-rhel9.6.0"},
                            resources: {}
                        },
                        networks: [{name: "default", pod: {}}],
                        subdomain: "headless",
                        volumes: [
                            {name: "rootdisk", dataVolume: {name: ($name + "-volume")}},
                            {name: "cloudinitdisk", cloudInitNoCloud: {userDataSecretRef: {name: $cloudinit_secret}}}
                        ]
                    }
                }
            }
        }
    ' > "${dest}"
    chmod 600 "${dest}"
}

delete_existing_vm() {
    print_warn "Removing VirtualMachine ${VM_NAME} so it can be created on a worker."
    oc delete vm "${VM_NAME}" -n "${VM_NAMESPACE}" --wait=true --timeout=180s
    oc delete dv "${VM_NAME}-volume" -n "${VM_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=180s
    oc delete pvc "${VM_NAME}-volume" -n "${VM_NAMESPACE}" --ignore-not-found=true --wait=true --timeout=180s
}

wait_for_worker_schedule() {
    local deadline=$((SECONDS + 120))
    local node="" pod="" node_name=""
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        node="$(vmi_node)"
        if [ -n "${node}" ]; then
            if node_is_control_plane "${node}"; then
                die "rhel-webserver scheduled on control-plane node ${node}."
            fi
            print_info "rhel-webserver is scheduled on worker ${node}."
            print_info "Cloud-init installs roxagent 5.0.0 in the guest. The first inventory can take several minutes after the guest is Running."
            return 0
        fi
        while IFS=$'\t' read -r pod node_name; do
            [ -n "${node_name}" ] || continue
            if node_is_control_plane "${node_name}"; then
                die "Pod ${pod} is on control-plane node ${node_name}."
            fi
        done < <(oc get pods -n "${VM_NAMESPACE}" -o json | jq -r --arg name "${VM_NAME}" '
            .items[]
            | select(.spec.nodeName != null)
            | select(.metadata.name | contains($name))
            | [.metadata.name, .spec.nodeName]
            | @tsv
        ')
        sleep 5
    done
    print_info "rhel-webserver is created with worker-only scheduling. Disk import is still running, so the guest is not scheduled yet."
    print_info "It will not run on the control plane. Cloud-init installs roxagent 5.0.0 after the guest boots."
}

ensure_namespace() {
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${VM_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: rhacs-demo
    app.kubernetes.io/component: vm-credentials
EOF
}

main() {
    if [ "${SKIP_RHEL_VM:-0}" = "1" ]; then
        print_info "Skipping RHEL virtual machine (SKIP_RHEL_VM=1)"
        return 0
    fi

    print_step "Creating rhel-webserver on a worker node"
    command -v oc >/dev/null 2>&1 || die "oc is required."
    command -v jq >/dev/null 2>&1 || die "jq is required."
    oc whoami >/dev/null 2>&1 || die "Not logged into a cluster. Run oc login."

    if [ -z "$(list_eligible_workers)" ]; then
        die "No Ready worker node without control-plane or master labels. Refusing to place rhel-webserver on the control plane."
    fi
    if ! oc get "datasource.cdi.kubevirt.io" "${DATASOURCE_NAME}" -n "${DATASOURCE_NAMESPACE}" >/dev/null 2>&1; then
        die "DataSource ${DATASOURCE_NAME} was not found in ${DATASOURCE_NAMESPACE}. OpenShift Virtualization golden images are required."
    fi

    if vm_exists; then
        local node=""
        node="$(vmi_node)"
        if [ -n "${node}" ] && node_is_eligible_worker "${node}"; then
            print_info "rhel-webserver is already running on worker ${node}. Leaving it in place."
            return 0
        fi
        if [ -z "${node}" ] && vm_has_worker_affinity; then
            print_info "rhel-webserver already requires a worker node and is not scheduled yet. Leaving it in place."
            return 0
        fi
        if [ -n "${node}" ]; then
            print_warn "rhel-webserver is on ${node}, which is not a worker without a control-plane role. Recreating it on a worker."
        else
            print_warn "rhel-webserver has no worker-only placement. Recreating it on a worker."
        fi
    fi

    if ! resolve_satellite; then
        print_warn "No Satellite credentials found. The guest will still install roxagent 5.0.0, but package installation and the CVE list need Satellite."
    else
        print_info "Satellite registration will run at first boot (source: ${SAT_SOURCE})."
        assert_embeddable "URL" "${SAT_URL}"
        assert_embeddable "org" "${SAT_ORG}"
        assert_embeddable "activation key" "${SAT_KEY}"
    fi

    if vm_exists; then
        delete_existing_vm
    fi

    local password="" init_b64="" guest_name="" userdata=""
    if ! password="$(resolve_vm_password)"; then
        die "Set ROX_PASSWORD to the RHACS admin password. That password is also the rhel guest password."
    fi
    if [ ! -f "${_RHACS_DEMO_ROOT}/scripts/init-vm.sh" ]; then
        die "Missing ${_RHACS_DEMO_ROOT}/scripts/init-vm.sh"
    fi
    init_b64="$(base64 < "${_RHACS_DEMO_ROOT}/scripts/init-vm.sh" | tr -d '\n')"
    guest_name="$(subscription_name)"
    userdata="$(build_userdata "${password}" "${SAT_URL}" "${SAT_ORG}" "${SAT_KEY}" "${init_b64}" "${guest_name}")"

    ensure_namespace
    CLOUDINIT_MANIFEST="$(mktemp)"
    MANIFEST="$(mktemp)"
    write_cloudinit_secret "${userdata}" "${CLOUDINIT_MANIFEST}"
    write_manifest "${MANIFEST}"
    oc apply -f "${CLOUDINIT_MANIFEST}" >/dev/null
    print_info "Stored cloud-init in Secret ${CLOUDINIT_SECRET_NAME}."
    oc apply -f "${MANIFEST}" >/dev/null
    print_info "Applied VirtualMachine ${VM_NAME} in ${VM_NAMESPACE}."
    wait_for_worker_schedule
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
