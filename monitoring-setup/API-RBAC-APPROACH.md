# RHACS Monitoring - API-Based RBAC Configuration

## Change Summary

The monitoring setup has been updated to use **API-based RBAC configuration** instead of declarative configuration for more reliable automation.

## Why This Change Was Made

### Problem with Declarative Configuration

When using declarative configuration via ConfigMap, we encountered:

```
declarativeconfig: Info: Declarative configuration directory does not exist, no reconciliation will be done
```

**Root Cause**: 
- Declarative config requires ConfigMap to be mounted as a volume in Central pod
- With Operator-managed installations, mounting requires Central CR updates
- The operator may not immediately apply the mount
- Even after patching Central CR, the directory wasn't available
- Results in token validation failures: `credentials not found: token-based: cannot extract identity: token validation failed`

### Solution: Direct API Configuration

Instead of relying on declarative config, we now:
1. Create RBAC resources directly via RHACS API
2. Immediate effect (no restart required)
3. More reliable for automation
4. Easier to debug

## What Changed

### Updated Script: `04-deploy-monitoring-stack.sh`

#### Old Approach (Declarative Config)
```bash
# Created ConfigMap with YAML definitions
oc apply -f declarative-configuration-configmap.yaml

# Expected Central to:
# 1. Detect ConfigMap
# 2. Mount it as volume
# 3. Process YAML files
# 4. Create Permission Set, Role, Auth Provider

# ❌ Issue: Directory never mounted, config never processed
```

#### New Approach (API-Based)
```bash
# Directly creates resources via API
curl -k -u "admin:${password}" -X POST \
  "https://${central_url}/v1/permissionsets" \
  -d '{ "name": "Prometheus Server", ... }'

curl -k -u "admin:${password}" -X POST \
  "https://${central_url}/v1/roles" \
  -d '{ "name": "Prometheus Server", ... }'

curl -k -u "admin:${password}" -X POST \
  "https://${central_url}/v1/groups/attributes" \
  -d '{ "roleName": "Prometheus Server", ... }'

# ✅ Immediate: Resources created instantly, no restart needed
```

### Script Now Accepts Password

**Usage options:**

1. **Pass as argument** (recommended):
   ```bash
   ./04-deploy-monitoring-stack.sh <password>
   ./install.sh <password>
   ```

2. **Environment variable**:
   ```bash
   export ROX_PASSWORD="your-password"
   ./install.sh
   ```

3. **Auto-retrieve from cluster**:
   ```bash
   # Script automatically tries:
   oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d
   ./install.sh
   ```

## API Endpoints Used

### 1. Create Permission Set
```
POST /v1/permissionsets
```
Creates a permission set with read access to resources needed for metrics.

### 2. Create Role
```
POST /v1/roles
```
Creates a role that binds the permission set with unrestricted scope.

### 3. Configure Auth Provider
```
POST /v1/groups/attributes
```
Maps the Kubernetes service account to the role using group attributes.

## RBAC Resources Created

### Permission Set: "Prometheus Server"
- **Administration**: READ_ACCESS
- **Alert**: READ_ACCESS  
- **Cluster**: READ_ACCESS
- **Deployment**: READ_ACCESS
- **Image**: READ_ACCESS
- **Integration**: READ_ACCESS (required for /metrics endpoint)
- **Namespace**: READ_ACCESS
- **Node**: READ_ACCESS
- **WorkflowAdministration**: READ_ACCESS

### Role: "Prometheus Server"
- Links to Permission Set
- Access Scope: Unrestricted
- Allows viewing all clusters and namespaces

### Auth Provider Mapping
- Service Account: `system:serviceaccount:stackrox:sample-stackrox-prometheus`
- Mapped to Role: "Prometheus Server"
- Authentication method: Kubernetes service account token

## Verification

After running the updated script:

```bash
# 1. Check Permission Set exists
ROX_PASSWORD=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d)
CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')

curl -k -s -u "admin:${ROX_PASSWORD}" "https://${CENTRAL_URL}/v1/permissionsets" | \
  jq '.permissionSets[] | select(.name=="Prometheus Server")'

# 2. Check Role exists
curl -k -s -u "admin:${ROX_PASSWORD}" "https://${CENTRAL_URL}/v1/roles" | \
  jq '.roles[] | select(.name=="Prometheus Server")'

# 3. Test metrics endpoint with service account token
SA_TOKEN=$(oc get secret sample-stackrox-prometheus-tls -n stackrox -o jsonpath='{.data.token}' | base64 -d)
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "https://${CENTRAL_URL}/metrics" | head -20

# Should return metrics like:
# rox_central_cfg_total_policies{Enabled="true"} 45
# rox_central_health_cluster_info{...} 1
```

## Benefits of API Approach

### 1. **Reliability**
- ✅ Immediate effect
- ✅ No dependency on Central CR or operator reconciliation
- ✅ No need to mount ConfigMaps
- ✅ Works with all installation methods

### 2. **Debuggability**
- ✅ Clear API responses show success/failure
- ✅ Can verify resources immediately
- ✅ No need to check Central logs for declarative config processing

### 3. **Flexibility**
- ✅ Can be run independently
- ✅ Idempotent (checks if resources already exist)
- ✅ Easy to update or recreate

### 4. **Automation-Friendly**
- ✅ Scriptable with clear error handling
- ✅ No waiting for reconciliation loops
- ✅ Testable immediately after creation

## Comparison

| Aspect | Declarative Config | API-Based (New) |
|--------|-------------------|-----------------|
| Setup time | Requires Central restart + reconciliation | Immediate |
| Reliability | Depends on ConfigMap mounting | Direct, always works |
| Debugging | Check Central logs, volume mounts | API responses, clear errors |
| Installation methods | Operator-specific configuration | Works with all methods |
| Verification | Wait and check logs | Test immediately |
| Failure mode | Silent (directory not found) | Clear API error messages |

## Migration from Old Approach

If you previously used declarative configuration:

### Remove Old ConfigMap (Optional)
```bash
oc delete configmap sample-stackrox-prometheus-declarative-configuration -n stackrox
```

### Remove from Central CR (Optional)
```bash
CENTRAL_CR=$(oc get central -n stackrox -o jsonpath='{.items[0].metadata.name}')
oc patch central ${CENTRAL_CR} -n stackrox --type=json -p='[
  {"op": "remove", "path": "/spec/central/declarativeConfiguration"}
]'
```

### Run Updated Script
```bash
cd monitoring-setup
export ROX_API_TOKEN="your-token"
./install.sh <password>
```

## Testing

Complete test sequence:

```bash
cd monitoring-setup

# Run with password
./install.sh <your-admin-password>

# Verify RBAC was created
ROX_PASSWORD=$(oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d)
CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')

# Check Permission Set
curl -k -s -u "admin:${ROX_PASSWORD}" "https://${CENTRAL_URL}/v1/permissionsets" | \
  jq '.permissionSets[] | select(.name=="Prometheus Server") | {name, description}'

# Check Role  
curl -k -s -u "admin:${ROX_PASSWORD}" "https://${CENTRAL_URL}/v1/roles" | \
  jq '.roles[] | select(.name=="Prometheus Server") | {name, permissionSetId}'

# Test metrics endpoint
SA_TOKEN=$(oc get secret sample-stackrox-prometheus-tls -n stackrox -o jsonpath='{.data.token}' | base64 -d)
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "https://${CENTRAL_URL}/metrics" | grep "rox_central"
```

## Troubleshooting

### "credentials not found: basic: cannot extract identity"

This means the admin password is incorrect or the admin user doesn't exist.

**Fix:**
```bash
# Get the correct password
oc get secret central-htpasswd -n stackrox -o jsonpath='{.data.password}' | base64 -d

# Use it in the script
./install.sh <correct-password>
```

### "token validation failed" after script completes

Wait 30 seconds and test again - sometimes RHACS takes a moment to activate the auth provider.

```bash
sleep 30
SA_TOKEN=$(oc get secret sample-stackrox-prometheus-tls -n stackrox -o jsonpath='{.data.token}' | base64 -d)
CENTRAL_URL=$(oc get route central -n stackrox -o jsonpath='{.spec.host}')
curl -k -H "Authorization: Bearer ${SA_TOKEN}" "https://${CENTRAL_URL}/metrics" | head -20
```

### Permission Set already exists

This is fine - the script detects existing resources. The role mapping might need to be recreated:

```bash
# Delete and recreate
cd monitoring-setup
bash 04-deploy-monitoring-stack.sh <password>
```

## Conclusion

The API-based approach is more reliable, immediate, and easier to debug than declarative configuration. This change improves the automation reliability while following the same RBAC model documented in Red Hat's best practices.
