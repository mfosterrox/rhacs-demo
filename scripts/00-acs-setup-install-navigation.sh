#!/usr/bin/env bash
# Tied to: content/modules/ROOT/pages/00-acs-setup-install-navigation.adoc
# Runs all setup commands from the lab so the environment is ready for the next module.
#
# Required (or derived): oc logged in with admin; optionally ACS_PORTAL_PASSWORD, QUAY_ADMIN_PASSWORD.
# Script derives: ROX_CENTRAL_ADDRESS, QUAY_URL, TUTORIAL_HOME, APP_HOME when possible.

set -euo pipefail

# --- Optional env (used if set; otherwise derived or prompted) ---
# ACS_PORTAL_USERNAME, ACS_PORTAL_PASSWORD  - RHACS console login (for API token generation)
# QUAY_USER, QUAY_ADMIN_PASSWORD           - Quay admin (for login and repo)
# DEMO_APPLICATIONS_REPO                    - default: https://github.com/mfosterrox/demo-applications.git

REPO_URL="${DEMO_APPLICATIONS_REPO:-https://github.com/mfosterrox/demo-applications.git}"
CLONE_DIR="${HOME}/demo-applications"

# --- OpenShift admin verification ---
oc config use-context admin
oc whoami
oc get nodes -A

# --- ROX_CENTRAL_ADDRESS from OpenShift route ---
export ROX_CENTRAL_ADDRESS
ROX_CENTRAL_ADDRESS="$(oc -n stackrox get route central -o jsonpath='{.spec.host}' 2>/dev/null || true)"
if [[ -z "${ROX_CENTRAL_ADDRESS:-}" ]]; then
  echo "Could not get ROX_CENTRAL_ADDRESS from 'oc -n stackrox get route central'. Set it manually: export ROX_CENTRAL_ADDRESS=central-rox.apps...."
  exit 1
fi

# --- roxctl CLI ---
mkdir -p ~/.local/bin
curl -L -f -o ~/.local/bin/roxctl "https://mirror.openshift.com/pub/rhacs/assets/latest/bin/Linux/roxctl"
chmod +x ~/.local/bin/roxctl
export PATH="$HOME/.local/bin:${PATH:-}"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo "export ROX_CENTRAL_ADDRESS=\"${ROX_CENTRAL_ADDRESS}\"" >> ~/.bashrc
echo 'export GRPC_ENFORCE_ALPN_ENABLED=false' >> ~/.bashrc

# --- API token (use existing or generate) ---
if [[ -z "${ROX_API_TOKEN:-}" ]]; then
  ACS_ROUTE="${ACS_ROUTE:-https://${ROX_CENTRAL_ADDRESS}}"
  ACS_USER="${ACS_PORTAL_USERNAME:-admin}"
  ACS_PASS="${ACS_PORTAL_PASSWORD:-}"
  if [[ -z "${ACS_PASS}" ]]; then
    echo "Set ACS_PORTAL_PASSWORD (or ROX_API_TOKEN) to generate API token."
    exit 1
  fi
  ROX_API_TOKEN=$(curl -sk -u "${ACS_USER}:${ACS_PASS}" "${ACS_ROUTE}:443/v1/apitokens/generate" \
    -H 'Content-Type: application/json' \
    -d '{"name": "my-api-token", "role": "Admin"}' \
    | (jq -r .token 2>/dev/null || sed -n 's/.*"token":"\([^"]*\)".*/\1/p'))
fi
echo "export ROX_API_TOKEN=\"${ROX_API_TOKEN}\"" >> ~/.bashrc
echo "export ACS_ROUTE=\"https://${ROX_CENTRAL_ADDRESS}\"" >> ~/.bashrc
echo "export ACS_PORTAL_USERNAME=\"${ACS_PORTAL_USERNAME:-admin}\"" >> ~/.bashrc
echo "export ACS_PORTAL_PASSWORD=\"${ACS_PORTAL_PASSWORD:-}\"" >> ~/.bashrc
source ~/.bashrc 2>/dev/null || true

# --- Verify roxctl ---
roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" central whoami

# --- Clone demo applications ---
if [[ ! -d "${CLONE_DIR}/.git" ]]; then
  git clone "$REPO_URL" "$CLONE_DIR"
fi
cd "${HOME}"
export TUTORIAL_HOME="${CLONE_DIR}"
echo "export TUTORIAL_HOME=\"${TUTORIAL_HOME}\"" >> ~/.bashrc

# --- Deploy vulnerable workshop apps ---
oc apply -f "$TUTORIAL_HOME/k8s-deployment-manifests/" --recursive
oc apply -f "$TUTORIAL_HOME/skupper-demo/" --recursive
oc get deployments -l demo=roadshow -A

# --- Optional: image scan (patient-portal-frontend) ---
roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" image scan \
  --image=quay.io/skupper/patient-portal-frontend:latest \
  --severity CRITICAL,IMPORTANT --force -o table || true

# --- Quay URL and user ---
export QUAY_URL
QUAY_URL=$(oc -n quay get route quay-quay -o jsonpath='{.spec.host}' 2>/dev/null || true)
if [[ -z "${QUAY_URL:-}" ]]; then
  echo "Could not get QUAY_URL from 'oc -n quay get route quay-quay'. Set QUAY_URL manually."
  exit 1
fi
export QUAY_USER="${QUAY_USER:-${QUAY_ADMIN_USERNAME:-quayadmin}}"
echo "export QUAY_URL=\"${QUAY_URL}\"" >> ~/.bashrc
echo "export QUAY_USER=\"${QUAY_USER}\"" >> ~/.bashrc

# --- Podman (install if missing) ---
if ! command -v podman &>/dev/null; then
  sudo dnf install -y podman || true
fi
podman --version

# --- Podman login to Quay ---
QUAY_PASS="${QUAY_ADMIN_PASSWORD:-${QUAY_PASSWORD:-}}"
if [[ -z "${QUAY_PASS}" ]]; then
  echo "Set QUAY_ADMIN_PASSWORD (or QUAY_PASSWORD) for podman login."
  exit 1
fi
podman login "$QUAY_URL" -u "$QUAY_USER" -p "$QUAY_PASS"

# --- Golden image ---
podman pull python:3.12-alpine
podman tag docker.io/library/python:3.12-alpine "$QUAY_URL/$QUAY_USER/python-alpine-golden:0.1"
podman images
podman push "$QUAY_URL/$QUAY_USER/python-alpine-golden:0.1"

# --- Frontend app: list and inspect ---
ls "$TUTORIAL_HOME/image-builds/frontend/"
cat "$TUTORIAL_HOME/image-builds/frontend/Dockerfile"

# --- Update Dockerfile FROM to golden image ---
sed -i.bak "s|^FROM python:3\.12-alpine AS \(\w\+\)|FROM $QUAY_URL/$QUAY_USER/python-alpine-golden:0.1 AS \1|" "$TUTORIAL_HOME/image-builds/frontend/Dockerfile"
cat "$TUTORIAL_HOME/image-builds/frontend/Dockerfile"

# --- Build and push frontend image ---
cd "$TUTORIAL_HOME/image-builds/frontend/"
podman build -t "$QUAY_URL/$QUAY_USER/frontend:0.1" .
podman push "$QUAY_URL/$QUAY_USER/frontend:0.1" --remove-signatures

# --- Quay integration in RHACS (so scan can pull from Quay) ---
curl -sk -X POST "https://${ROX_CENTRAL_ADDRESS}:443/v1/imageintegrations" \
  -H "Authorization: Bearer ${ROX_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Quay Workshop Registry",
    "type": "quay",
    "categories": ["REGISTRY"],
    "quay": {
      "endpoint": "'"$QUAY_URL"'",
      "insecure": true
    }
  }' || true

# --- Verify scan of frontend image ---
roxctl --insecure-skip-tls-verify -e "${ROX_CENTRAL_ADDRESS}:443" image scan \
  --image="$QUAY_URL/$QUAY_USER/frontend:0.1" --force -o table || true

# --- APP_HOME and deploy frontend with custom image ---
export APP_HOME="$TUTORIAL_HOME/skupper-demo"
echo "export APP_HOME=\"${APP_HOME}\"" >> ~/.bashrc

sed -i.bak "s|quay.io/skupper/patient-portal-frontend:latest|$QUAY_URL/$QUAY_USER/frontend:0.1|g" "$APP_HOME/frontend.yml"
cat "$APP_HOME/frontend.yml"

oc apply -f "$APP_HOME/frontend.yml"
oc get pods -n patient-portal

echo "Setup complete. Environment ready for next module (Visibility and Navigation)."
