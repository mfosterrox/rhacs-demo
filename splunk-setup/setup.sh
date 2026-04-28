#!/usr/bin/env bash
#
# Deploy a single-node Splunk Enterprise instance in OpenShift.
#
# Usage:
#   ./setup.sh
#
# Optional environment variables:
#   SPLUNK_NAMESPACE        Namespace to deploy into (default: splunk)
#   SPLUNK_NAME             Base name for deployment resources (default: splunk)
#   SPLUNK_STORAGE_SIZE     PVC size for index data (default: 20Gi)
#   SPLUNK_PASSWORD         Admin password (default: generated)
#   SPLUNK_IMAGE            Splunk container image (default: splunk/splunk:latest)
#   SPLUNK_ROUTE_TERMINATION Route type: edge|passthrough|reencrypt (default: edge)
#

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
print_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        print_error "Required command not found: ${cmd}"
        exit 1
    fi
}

generate_password() {
    # 20 chars, includes upper/lower/digit and safe specials for shell/env usage.
    local raw
    raw="$(LC_ALL=C tr -dc 'A-Za-z0-9@#%+=' </dev/urandom | head -c 20)"
    printf 'Rhacs%s1!' "${raw}"
}

print_deploy_diagnostics() {
    local namespace="$1"
    local name="$2"
    print_warn "Deployment diagnostics for ${namespace}/${name}:"
    oc -n "${namespace}" get deploy "${name}" -o wide || true
    oc -n "${namespace}" get rs -l "app=${name}" || true
    oc -n "${namespace}" get pods -l "app=${name}" -o wide || true
    # Use grep (not rg) because bastion hosts may not include ripgrep.
    oc -n "${namespace}" get events --sort-by=.lastTimestamp | grep -Ei "${name}|failed|forbidden|scc|denied" || true
    print_warn "If you see SCC/anyuid errors, run:"
    print_warn "  oc adm policy add-scc-to-user anyuid -z ${name}-sa -n ${namespace}"
}

main() {
    require_cmd oc

    if ! oc whoami >/dev/null 2>&1; then
        print_error "You are not logged in to OpenShift. Run: oc login"
        exit 1
    fi

    local namespace="${SPLUNK_NAMESPACE:-splunk}"
    local name="${SPLUNK_NAME:-splunk}"
    local storage_size="${SPLUNK_STORAGE_SIZE:-20Gi}"
    local image="${SPLUNK_IMAGE:-splunk/splunk:latest}"
    local route_termination="${SPLUNK_ROUTE_TERMINATION:-edge}"
    local password="${SPLUNK_PASSWORD:-}"

    if [ -z "${password}" ]; then
        password="$(generate_password)"
        print_warn "SPLUNK_PASSWORD not set. Generated a password for this deployment."
    fi

    print_step "Deploying Splunk in OpenShift namespace '${namespace}'"

    oc get namespace "${namespace}" >/dev/null 2>&1 || oc create namespace "${namespace}"

    print_step "Creating service account and granting SCC (anyuid)"
    oc -n "${namespace}" create serviceaccount "${name}-sa" --dry-run=client -o yaml | oc apply -f -
    if ! oc adm policy add-scc-to-user anyuid -z "${name}-sa" -n "${namespace}" >/dev/null 2>&1; then
        print_warn "Could not grant anyuid SCC automatically (insufficient permissions?)."
        print_warn "If rollout fails with SCC errors, grant it as a cluster admin:"
        print_warn "  oc adm policy add-scc-to-user anyuid -z ${name}-sa -n ${namespace}"
    fi

    print_step "Creating/updating Splunk secret"
    oc -n "${namespace}" create secret generic "${name}-auth" \
        --from-literal=password="${password}" \
        --dry-run=client -o yaml | oc apply -f -

    print_step "Applying PVC, Deployment, Service, and Route"
    cat <<EOF | oc -n "${namespace}" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}-var
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${storage_size}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${name}
  labels:
    app: ${name}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${name}
  template:
    metadata:
      labels:
        app: ${name}
    spec:
      securityContext:
        fsGroup: 41812
      serviceAccountName: ${name}-sa
      containers:
        - name: splunk
          image: ${image}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8000
              name: web
            - containerPort: 8088
              name: hec
            - containerPort: 8089
              name: mgmt
            - containerPort: 9997
              name: s2s
          env:
            - name: SPLUNK_GENERAL_TERMS
              value: "--accept-sgt-current-at-splunk-com"
            - name: SPLUNK_START_ARGS
              value: "--accept-license"
            - name: SPLUNK_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${name}-auth
                  key: password
          volumeMounts:
            - name: var
              mountPath: /opt/splunk/var
          readinessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 45
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 12
          livenessProbe:
            tcpSocket:
              port: 8000
            initialDelaySeconds: 90
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 6
      volumes:
        - name: var
          persistentVolumeClaim:
            claimName: ${name}-var
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
spec:
  selector:
    app: ${name}
  ports:
    - name: web
      port: 8000
      targetPort: web
    - name: hec
      port: 8088
      targetPort: hec
    - name: mgmt
      port: 8089
      targetPort: mgmt
    - name: s2s
      port: 9997
      targetPort: s2s
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${name}-web
spec:
  to:
    kind: Service
    name: ${name}
  port:
    targetPort: web
  tls:
    termination: ${route_termination}
EOF

    print_step "Waiting for Splunk deployment rollout"
    if ! oc -n "${namespace}" rollout status "deployment/${name}" --timeout=10m; then
        print_error "Splunk deployment rollout did not complete."
        print_deploy_diagnostics "${namespace}" "${name}"
        exit 1
    fi

    local route_host
    route_host="$(oc -n "${namespace}" get route "${name}-web" -o jsonpath='{.spec.host}')"

    print_info "Splunk deployment is ready."
    print_info "Namespace: ${namespace}"
    print_info "Splunk Web URL: https://${route_host}"
    print_info "Username: admin"
    print_info "Password: ${password}"
    echo ""
    print_info "RHACS SIEM tip: use Splunk HEC on port 8088 with a token created in Splunk."
    print_info "If using in-cluster endpoint, use: http://${name}.${namespace}.svc.cluster.local:8088"
}

main "$@"
