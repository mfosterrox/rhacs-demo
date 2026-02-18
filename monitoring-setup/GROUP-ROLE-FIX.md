# Group Role Assignment Fix

## Problem
When testing metrics endpoint with client certificate authentication:
```bash
curl --cert client.crt --key client.key -k $ROX_CENTRAL_URL/metrics
```

Error received:
```
access for this user is not authorized: no valid role, please contact your system administrator
```

## Root Cause
The group mapping for the "Monitoring" auth provider was either:
1. Not being created successfully
2. Being created with the wrong role name ("Admin" instead of "Prometheus Server")
3. Failing silently without proper error reporting

## Solution Applied

### 1. Fixed Role Name Consistency
All scripts and configurations now use **"Prometheus Server"** role (defined in declarative configuration):

**Files Updated:**
- `monitoring-examples/rhacs/admin-group.json.tpl` - Uses "Prometheus Server" ✓
- `03-configure-rhacs-auth.sh` - Creates group with "Prometheus Server" ✓
- `troubleshoot-auth.sh` - Uses "Prometheus Server" for fallback group ✓
- `README.md` - Documentation updated to reflect correct role ✓

### 2. Enhanced Error Handling in `03-configure-rhacs-auth.sh`

**Before:**
- Silent failures when group creation failed
- No verification that group was created
- Limited feedback on what went wrong

**After:**
- Displays the group creation payload for debugging
- Checks HTTP status code (200, 409, etc.)
- Verifies group exists via API after creation
- Provides detailed manual fix instructions if automated creation fails
- Exits with error if group creation fails (prevents incomplete setup)

**New Logic:**
```bash
# Wait for auth provider to initialize
sleep 2

# Show what we're sending
log "Group payload: $GROUP_PAYLOAD"

# Create group and capture HTTP status
GROUP_RESPONSE=$(curl -k -s -w "\n%{http_code}" ...)
HTTP_CODE=$(echo "$GROUP_RESPONSE" | tail -1)

# Check success
if [ "$HTTP_CODE" = "200" ]; then
  log "✓ Group created successfully"
elif [ "$HTTP_CODE" = "409" ]; then
  log "✓ Group already exists"
else
  error "Group creation failed (HTTP $HTTP_CODE)"
  # Verify if group exists via API
  # Provide manual fix instructions
  exit 1
fi
```

### 3. Added Metrics Endpoint Testing in `install.sh`

**New Verification:**
```bash
# Test auth status
AUTH_TEST=$(curl --cert client.crt --key client.key $ROX_CENTRAL_URL/v1/auth/status)

if [ success ]; then
  # Also test metrics endpoint!
  METRICS_TEST=$(curl --cert client.crt --key client.key $ROX_CENTRAL_URL/metrics)
  
  if [ "access...not authorized" ]; then
    error "Metrics endpoint access denied: no valid role"
    error "Run troubleshooting script"
  elif [ metrics_data ]; then
    log "✓ Metrics endpoint access successful!"
  fi
fi
```

### 4. Declarative Configuration Role Definition

The role is defined in `declarative-configuration-configmap.yaml`:

```yaml
---
name: Prometheus Server
description: Sample permission set for Prometheus server access
resources:
- resource: Administration
  access: READ_ACCESS
- resource: Alert
  access: READ_ACCESS
# ... more resources

---
name: Prometheus Server
description: Sample role for Prometheus server access
accessScope: Unrestricted
permissionSet: Prometheus Server
```

## How to Verify the Fix

### 1. Check Auth Provider
```bash
ROX_ENDPOINT="${ROX_CENTRAL_URL#https://}"
roxctl -e "$ROX_ENDPOINT" --token "$ROX_API_TOKEN" \
  central userpki list --insecure-skip-tls-verify
```

Should show:
```
Provider: Monitoring
  ID: <auth-provider-id>
  Enabled: true
  Minimum access role: "Prometheus Server"
```

### 2. Check Groups
```bash
curl -k -H "Authorization: Bearer $ROX_API_TOKEN" \
  "$ROX_CENTRAL_URL/v1/groups" | jq '.groups[] | select(.props.authProviderId=="<auth-provider-id>")'
```

Should show:
```json
{
  "props": {
    "authProviderId": "<auth-provider-id>",
    "key": "",
    "value": ""
  },
  "roleName": "Prometheus Server"
}
```

### 3. Test Authentication
```bash
cd monitoring-setup
curl --cert client.crt --key client.key -k $ROX_CENTRAL_URL/v1/auth/status
```

Should return user info (not "credentials not found")

### 4. Test Metrics Access
```bash
curl --cert client.crt --key client.key -k $ROX_CENTRAL_URL/metrics | head -20
```

Should return Prometheus metrics (not "access...not authorized")

## Manual Fix (If Automated Creation Fails)

### Via RHACS UI:
1. Go to: **Platform Configuration** → **Access Control** → **Groups**
2. Click **Create Group**
3. Fill in:
   - **Auth Provider**: Monitoring
   - **Key**: (leave empty)
   - **Value**: (leave empty)
   - **Role**: Prometheus Server
4. Click **Save**

### Via API:
```bash
# Get auth provider ID
AUTH_PROVIDER_ID=$(curl -k -s -H "Authorization: Bearer $ROX_API_TOKEN" \
  "$ROX_CENTRAL_URL/v1/authProviders" | \
  grep -B2 '"name":"Monitoring"' | grep '"id"' | cut -d'"' -f4)

# Create group
curl -k -X POST "$ROX_CENTRAL_URL/v1/groups" \
  -H "Authorization: Bearer $ROX_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"props\":{\"authProviderId\":\"$AUTH_PROVIDER_ID\",\"key\":\"\",\"value\":\"\"},\"roleName\":\"Prometheus Server\"}"
```

### Using Troubleshoot Script:
```bash
cd monitoring-setup
./troubleshoot-auth.sh
```

The script will:
- Verify auth provider exists
- Check for existing groups
- Create missing group if needed
- Test authentication
- Provide specific guidance

## Changes Summary

| File | Change | Status |
|------|--------|--------|
| `admin-group.json.tpl` | Role: "Prometheus Server" | ✓ Fixed |
| `03-configure-rhacs-auth.sh` | Enhanced error handling, verification | ✓ Fixed |
| `troubleshoot-auth.sh` | Use "Prometheus Server" role | ✓ Fixed |
| `install.sh` | Added metrics endpoint testing | ✓ Fixed |
| `README.md` | Updated documentation | ✓ Fixed |

## Testing Checklist

After running `./install.sh`, verify:

- [ ] Auth provider "Monitoring" exists
- [ ] Auth provider shows role "Prometheus Server"  
- [ ] Group exists for auth provider ID
- [ ] Group has roleName "Prometheus Server"
- [ ] `/v1/auth/status` endpoint works with client cert
- [ ] `/metrics` endpoint works with client cert (returns metrics, not error)
- [ ] Prometheus can scrape metrics from RHACS Central

## Troubleshooting

If metrics endpoint still fails after fix:

1. **Wait 30 seconds** - Auth changes need time to propagate
2. **Run troubleshoot script**: `./troubleshoot-auth.sh`
3. **Check declarative config**: `oc get cm sample-stackrox-prometheus-declarative-configuration -n stackrox -o yaml`
4. **Verify Central has declarative config mounted**: `oc get deployment central -n stackrox -o yaml | grep declarative`
5. **Check Central logs**: `oc logs -n stackrox deployment/central | grep -i declarative`
6. **Restart Central** (if declarative config was just added): `oc rollout restart deployment/central -n stackrox`
