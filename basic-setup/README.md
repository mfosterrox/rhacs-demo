# RHACS Demo Basic Setup

This folder contains the core installation and configuration scripts for the RHACS demo environment.

## Overview

The `install.sh` script orchestrates the execution of all numbered setup scripts in sequence, providing a complete RHACS demo environment configuration.

## Installation

From the **project root**, run:

```bash
./install.sh [PASSWORD]
```

Or from **within this folder**:

```bash
cd basic-setup
./install.sh [PASSWORD]
```

## Setup Scripts

The following scripts are executed in numerical order:

| Script | Description |
|--------|-------------|
| `install.sh` | Main orchestrator - runs all numbered scripts in sequence |
| `01-verify-rhacs-install.sh` | Verifies RHACS installation, checks version, ensures TLS encryption |
| `02-compliance-operator-install.sh` | Installs Red Hat Compliance Operator for compliance scanning |
| `03-deploy-applications.sh` | Deploys demo applications from mfosterrox/demo-applications repo |
| `04-configure-rhacs-settings.sh` | Configures RHACS via API (metrics, retention, platform components) |
| `05-setup-co-scan-schedule.sh` | Creates automated compliance scan schedules |

## What Gets Configured

### RHACS Settings (Script 04)
- **Telemetry**: Enabled for product improvement
- **Metrics Collection**: 1-minute gathering period for:
  - Image vulnerabilities (CVE, deployment, namespace severity)
  - Policy violations (deployment, namespace severity)
  - Node vulnerabilities (component, CVE, node severity)
- **Retention Policies**:
  - 7-day alert retention
  - 30-day runtime retention
  - 90-day vulnerability request retention
  - 7-day report retention
- **Platform Components**: Red Hat layered products properly recognized
- **Vulnerability Exceptions**: Configurable expiry options (14, 30, 60, 90 days)

### Compliance Scanning (Script 05)
- Daily compliance scans at 12:00 PM
- Multiple compliance profiles:
  - ocp4-cis, ocp4-cis-node
  - ocp4-moderate, ocp4-moderate-node
  - ocp4-high, ocp4-high-node
  - ocp4-pci-dss, ocp4-pci-dss-node
  - ocp4-nerc-cip, ocp4-nerc-cip-node
  - ocp4-e8, ocp4-stig-node

## Requirements

### Environment Variables

The install script checks for required variables in this order:
1. Command-line arguments (highest priority)
2. Current environment variables
3. Variables in `~/.bashrc`
4. Auto-detection from cluster

#### Required
- `ROX_PASSWORD` - RHACS admin password (can be passed as argument)
- `ROX_CENTRAL_URL` - RHACS Central URL (auto-detected if not provided)

#### Optional
- `RHACS_NAMESPACE` - RHACS namespace (default: `stackrox`)
- `RHACS_ROUTE_NAME` - Route name (default: `central`)
- `RHACS_VERSION` - Target version (default: `4.9.2`)

### Cluster Access
- Must be logged into OpenShift cluster via `oc login`
- Requires cluster-admin or equivalent permissions

## Individual Script Execution

You can run individual scripts for testing or troubleshooting:

```bash
# Verify RHACS
bash basic-setup/01-verify-rhacs-install.sh

# Configure RHACS settings only
bash basic-setup/04-configure-rhacs-settings.sh

# Setup compliance scanning only
bash basic-setup/05-setup-co-scan-schedule.sh
```

**Note**: Individual scripts assume RHACS is already installed and accessible.

## Troubleshooting

### Missing Variables
If scripts fail due to missing variables:

```bash
# Add to ~/.bashrc
export ROX_CENTRAL_URL="https://central-stackrox.apps.your-cluster.com"
export ROX_PASSWORD="your-admin-password"
export RHACS_NAMESPACE="stackrox"

# Reload
source ~/.bashrc
```

### RHACS Not Ready
If RHACS is not ready:

```bash
# Check RHACS status
oc get deployment central -n stackrox
oc get pods -n stackrox

# Wait for Central to be ready
oc wait --for=condition=available --timeout=300s deployment/central -n stackrox
```

### API Token Generation Fails
If token generation fails:

```bash
# Verify password is correct
oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d

# Test API access manually
curl -k -u "admin:YOUR_PASSWORD" \
  https://your-central-url/v1/apitokens/generate \
  -X POST -H "Content-Type: application/json" \
  -d '{"name":"test","roles":["Admin"]}'
```

## Related Documentation

- **Main README**: `../README.adoc` - Project overview and getting started
- **Monitoring Setup**: `../monitoring/README.md` - Detailed monitoring configuration
- **Dashboard Setup**: `../DASHBOARD_SETUP_GUIDE.md` - OpenShift dashboard setup guide

## Monitoring

For monitoring and dashboard setup, see the root-level script:
```bash
# From project root
./setup-openshift-dashboard.sh
```

This is separate from the basic setup and configures:
- Cluster Observability Operator
- Perses dashboards in OpenShift console
- Prometheus scraping with proper authentication

See `../DASHBOARD_SETUP_GUIDE.md` for details.
