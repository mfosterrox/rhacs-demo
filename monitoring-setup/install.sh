#!/bin/bash
#
# RHACS Monitoring Setup Script
# Follows the official monitoring-examples installation flow
#

set -euo pipefail
oc project stackrox

echo "Installing Cluster Observability Operator..."
oc apply -f cluster-observability-operator/subscription.yaml

echo "Generating user certificates..."
cluster-observability-operator/generate-test-user-certificate.sh
export TLS_CERT=$(awk '{printf "%s\\n", $0}' tls.crt)

echo "Installing and configuring a monitoring stack instance..."
oc apply -f cluster-observability-operator/monitoring-stack.yaml
oc apply -f cluster-observability-operator/scrape-config.yaml

echo "Installing Perses and configuring the RHACS dashboard..."
oc apply -f perses/ui-plugin.yaml
oc apply -f perses/datasource.yaml
oc apply -f perses/dashboard.yaml

echo "Declaring a permission set and a role in RHACS..."
# This assumes declarative configuration mount is configured.
oc apply -f rhacs/declarative-configuration-configmap.yaml

echo "Creating a User-Certificate auth-provider..."
curl -k -X POST "$ROX_CENTRAL_URL/v1/authProviders" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  --data-raw "$(envsubst < rhacs/auth-provider.json.tpl)"

echo "Now configure the minimum role for the just created Monitoring auth provider in ACS UI or via /v1/groups API."