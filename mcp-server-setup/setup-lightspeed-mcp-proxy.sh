#!/usr/bin/env bash

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_NAMESPACE="${MCP_NAMESPACE:-stackrox-mcp}"
PROXY_NAME="${LIGHTSPEED_MCP_PROXY_NAME:-stackrox-mcp-lightspeed-proxy}"
UPSTREAM_SERVICE="${LIGHTSPEED_MCP_PROXY_UPSTREAM_SERVICE:-stackrox-mcp}"
UPSTREAM_PORT="${LIGHTSPEED_MCP_PROXY_UPSTREAM_PORT:-8080}"
PROXY_IMAGE="${LIGHTSPEED_MCP_PROXY_IMAGE:-registry.access.redhat.com/ubi9/nginx-124:latest}"
MCP_OC_REQUEST_TIMEOUT="${MCP_OC_REQUEST_TIMEOUT:-60s}"

mcp_oc() {
    command oc --request-timeout="${MCP_OC_REQUEST_TIMEOUT}" "$@"
}

main() {
    print_step "Deploying Lightspeed MCP compatibility proxy"

    if ! mcp_oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift. Run: oc login"
        exit 1
    fi

    if ! mcp_oc get namespace "${MCP_NAMESPACE}" &>/dev/null; then
        print_error "Namespace ${MCP_NAMESPACE} not found"
        exit 1
    fi

    if ! mcp_oc get service "${UPSTREAM_SERVICE}" -n "${MCP_NAMESPACE}" &>/dev/null; then
        print_error "Upstream service ${UPSTREAM_SERVICE} not found in ${MCP_NAMESPACE}"
        exit 1
    fi

    # The Lightspeed MCP client currently issues GET /mcp. StackRox MCP serves SSE on /sse.
    # This proxy maps GET /mcp -> /sse while keeping POST/DELETE on /mcp unchanged.
    cat <<EOF | mcp_oc apply -n "${MCP_NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${PROXY_NAME}-nginx
data:
  nginx.conf: |
    events {}
    http {
      map \$request_method \$mcp_target_path {
        default /mcp;
        GET /sse;
      }

      server {
        listen 8080;

        location = /mcp {
          proxy_http_version 1.1;
          proxy_buffering off;
          proxy_set_header Host \$host;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \$scheme;
          proxy_pass http://${UPSTREAM_SERVICE}.${MCP_NAMESPACE}.svc.cluster.local:${UPSTREAM_PORT}\$mcp_target_path;
        }

        location / {
          proxy_http_version 1.1;
          proxy_buffering off;
          proxy_set_header Host \$host;
          proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto \$scheme;
          proxy_pass http://${UPSTREAM_SERVICE}.${MCP_NAMESPACE}.svc.cluster.local:${UPSTREAM_PORT};
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PROXY_NAME}
  labels:
    app.kubernetes.io/name: ${PROXY_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${PROXY_NAME}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${PROXY_NAME}
    spec:
      containers:
        - name: nginx
          image: ${PROXY_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
              name: http
          readinessProbe:
            httpGet:
              path: /mcp
              port: http
            initialDelaySeconds: 3
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /mcp
              port: http
            initialDelaySeconds: 10
            periodSeconds: 15
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/nginx.conf
              subPath: nginx.conf
              readOnly: true
      volumes:
        - name: nginx-conf
          configMap:
            name: ${PROXY_NAME}-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: ${PROXY_NAME}
  labels:
    app.kubernetes.io/name: ${PROXY_NAME}
spec:
  selector:
    app.kubernetes.io/name: ${PROXY_NAME}
  ports:
    - name: http
      port: 8080
      targetPort: http
      protocol: TCP
EOF

    mcp_oc rollout status deployment/"${PROXY_NAME}" -n "${MCP_NAMESPACE}" --timeout=120s >/dev/null || {
        print_warn "Proxy deployment rollout did not complete within timeout"
    }

    print_info "✓ Proxy service is available at: http://${PROXY_NAME}.${MCP_NAMESPACE}.svc.cluster.local:8080/mcp"
}

main "$@"
