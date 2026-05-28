# XNAT Troubleshooting Guide

Operational fixes from a 7TB+ production migration of an XNAT imaging platform.

## Quick Diagnosis

| Symptom | Likely Cause | Jump To |
|---------|--------------|---------|
| Downloads produce 22-byte files | Missing symlink + path issues | [22-Byte Downloads](#critical-issue-22-byte-empty-downloads) |
| "Authentication successful" but stays on login | 3 separate issues | [Authentication Triple Failure](#critical-issue-authentication-triple-failure) |
| Browser redirects to HTTPS/production URL | Database has production settings | [HTTPS Redirect Loop](#critical-issue-https-redirect-loop) |
| XNAT 1.8.10.1 won't deploy | PreResources bug in WAR | [WAR File Bug](#critical-issue-war-file-bug-18101-specific) |
| Permission denied everywhere | Wrong user + systemd restrictions | [Permission Errors](#critical-issue-permission-errors) |
| Plugins break on 1.9.2 | Hibernate 5 incompatibility | [Plugin Compatibility](#plugin-compatibility-issues-192) |

---

## Critical Issue: 22-Byte Empty Downloads

### The Mystery
Every download produced exactly 22 bytes - just an empty ZIP header. Files existed, permissions appeared correct, but nothing downloaded.

### What's Actually Happening
1. XNAT tries to create lock files (`.scan_catalog.xml.lock`) during downloads
2. It hardcodes the path `/opt/xnat/data/` for these operations
3. Your data lives in `/data/xnat/`
4. Java FileWriter fails with "Read-only file system" (even though it's not read-only)
5. XNAT generates an empty catalog, creates empty ZIP

### The Fix (Two Parts)

**Part 1: The Critical Symlink**
```bash
# THIS SYMLINK IS MANDATORY - NOT OPTIONAL
sudo ln -sfn /data/xnat /opt/xnat/data

# Verify it exists and points correctly
ls -la /opt/xnat/data
# Must show: data -> /data/xnat
```

**Part 2: Fix Archive Specification**
```bash
# Wait for XNAT to generate this file first (after initial setup)
cd /data/xnat/cache_working/

# Check how many wrong paths exist
grep -c "/opt/xnat/data/" archive_specification.xml
# Large deployments may contain hundreds of generated path references.

# Backup and fix
sudo cp archive_specification.xml archive_specification.xml.backup
sudo sed -i 's|/opt/xnat/data/|/data/xnat/|g' archive_specification.xml

# Restart Tomcat
sudo systemctl restart tomcat9
```

### Verification
Download a scan - should be megabytes/gigabytes, not 22 bytes!

---

## Critical Issue: Authentication Triple Failure

### The Problem
Users got "authentication successful" in logs but remained on login screen. Three separate issues conspired to break login.

### Issue #1: Provider Load Order
XNAT loads providers **alphabetically by filename**, ignoring config:
- `ldap1-provider.properties` loads before `localdb-provider.properties`
- Admin accounts exist in database, not LDAP
- LDAP tries first, fails, never tries database

**Fix:**
```bash
cd /data/xnat/home/config/auth/

# Rename to control load order
mv localdb-provider.properties 01-localdb-provider.properties
mv ldap1-provider.properties 02-ldap-provider.properties

# Add explicit ordering (belt and suspenders)
echo "order=1" >> 01-localdb-provider.properties
echo "order=2" >> 02-ldap-provider.properties
```

### Issue #2: Missing Role Assignments
The `xhbm_user_role` table was empty after migration!

**Fix:**
```bash
sudo -u postgres psql -d xnat <<EOF
-- Check current roles
SELECT * FROM xhbm_user_role WHERE username='admin';

-- Add Administrator role
INSERT INTO xhbm_user_role
  (role, username, enabled, timestamp, created, disabled)
VALUES
  ('Administrator', 'admin', true, NOW(), NOW(), '1969-12-31 19:00:00');
EOF
```

### Issue #3: Wrong Site URL
Database contained the old production `siteUrl`, causing redirect failures.

**Fix:**
```bash
sudo -u postgres psql -d xnat <<EOF
UPDATE xhbm_preference SET value = 'http://xnat-vm.example.org:8080'
  WHERE name = 'siteUrl';
UPDATE xhbm_preference SET value = 'http'
  WHERE name = 'securityChannel';
EOF
```

### Success Indicator
```
YYYY-MM-DD HH:MM:SS - admin POST Authentication SUCCESS
YYYY-MM-DD HH:MM:SS - admin GET SCREEN: Index
```

---

## Critical Issue: HTTPS Redirect Loop

### Symptom
Browser redirects to an old production hostname or `https://localhost:8443`, connection fails.

### Root Cause
Production database dump contains production URLs and HTTPS security settings.

### Complete Fix
```bash
sudo -u postgres psql -d xnat <<EOF
-- Check current values
SELECT name, value FROM xhbm_preference
WHERE name IN ('siteUrl', 'siteURL', 'securityChannel');

-- Fix all URL references
UPDATE xhbm_preference SET value = 'http://localhost:8080'
  WHERE name = 'siteUrl';
UPDATE xhbm_preference SET value = 'http://localhost:8080'
  WHERE name = 'siteURL';  -- Yes, both cases exist!
UPDATE xhbm_preference SET value = 'http'
  WHERE name = 'securityChannel';
EOF

sudo systemctl restart tomcat9
```

---

## Critical Issue: WAR File Bug (1.8.10.1 Specific)

### The Problem
XNAT 1.8.10.1 ships with broken `context.xml`. Uses `PreResources` which loads plugins before app classes, causing deployment failure.

### The Fix
```bash
# Extract WAR
cd /tmp
mkdir xnat-fix
cd xnat-fix
jar xf /path/to/xnat-web-1.8.10.1.war

# Check the problem
grep "PreResources" META-INF/context.xml

# Fix it
sed -i 's/PreResources/PostResources/g' META-INF/context.xml

# Repack (note: M flag = no manifest)
jar cfM /tmp/xnat-web-1.8.10.1-fixed.war .

# Deploy fixed version
sudo cp /tmp/xnat-web-1.8.10.1-fixed.war /var/lib/tomcat9/webapps/ROOT.war
sudo chown xnat:xnat /var/lib/tomcat9/webapps/ROOT.war
sudo systemctl restart tomcat9
```

### Why This Matters
- `PreResources`: Plugins load BEFORE app → class conflicts
- `PostResources`: Plugins load AFTER app → correct behavior

---

## Critical Issue: Permission Errors

### The Problem
Permission denied errors everywhere, even with correct file permissions.

### Root Cause #1: Wrong User
MUST use `xnat` user, NOT `tomcat` user!

### Root Cause #2: Systemd Restrictions
Ubuntu 22.04's systemd restricts filesystem access.

### Complete Fix
```bash
# Fix ownership (EVERYTHING must be xnat:xnat)
sudo chown -R xnat:xnat /data/xnat/
sudo chown -R xnat:xnat /opt/xnat/
sudo chown -R xnat:xnat /var/lib/tomcat9/
sudo chown -R xnat:xnat /var/log/tomcat9/
sudo chown -R xnat:xnat /var/cache/tomcat9/
sudo chown -R xnat:xnat /etc/tomcat9/

# Create systemd override
sudo mkdir -p /etc/systemd/system/tomcat9.service.d/
sudo cat > /etc/systemd/system/tomcat9.service.d/override.conf <<'EOF'
[Service]
User=xnat
Group=xnat
ReadWritePaths=/opt/xnat/data/ /data/xnat/
Environment="JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64"
Environment="XNAT_HOME=/data/xnat/home"
EOF

# Apply changes
sudo systemctl daemon-reload
sudo systemctl restart tomcat9
```

---

## Plugin Compatibility Issues (1.9.2)

### What Broke
Upgrading to XNAT 1.9.2 broke critical plugins due to Hibernate 4→5 upgrade:

1. **Container Service 3.4.3**:
   - Error: `HHH000474: Ambiguous persistent property methods`
   - Need: Version 3.6.0+ (not released at time)

2. **OHIF Viewer 3.0.1**:
   - Need: Version 3.7.0+ (not released at time)

3. **LDAP Auth Plugin**:
   - ✅ Version 1.1.0 worked!

### Temporary Solution
```bash
# Remove incompatible plugins to allow XNAT to start
cd /data/xnat/home/plugins/
mv container-service-3.4.3-fat.jar /tmp/
mv ohif-viewer-3.0.1-XNAT-1.8.0.jar /tmp/

sudo systemctl restart tomcat9
```

Core XNAT works but without container workflows or web viewing.

---

## Database Migration Issues

### Missing Role Assignments After Restore
```bash
# The migration strips roles - fix manually
sudo -u postgres psql -d xnat <<EOF
-- Fix admin
INSERT INTO xhbm_user_role
  (role, username, enabled, timestamp, created, disabled)
VALUES
  ('Administrator', 'admin', true, NOW(), NOW(), '1969-12-31 19:00:00')
ON CONFLICT DO NOTHING;

-- Check other users
SELECT u.username, r.role
FROM xdat_user u
LEFT JOIN xhbm_user_role r ON u.username = r.username
ORDER BY u.username;
EOF
```

---

## Diagnostic Commands

### The Essential Health Check
```bash
# 1. Services running?
systemctl status postgresql tomcat9

# 2. Critical symlink exists?
ls -la /opt/xnat/data
# Must show: data -> /data/xnat

# 3. XNAT responding?
curl -I http://localhost:8080/

# 4. Can you authenticate?
curl -u admin:REPLACE_WITH_PASSWORD http://localhost:8080/xnat/data/projects

# 5. Check for errors
tail -100 /var/log/tomcat9/catalina.out | grep ERROR

# 6. Test download (the real test!)
# Login and download a scan - should be > 22 bytes!
```

---

## Emergency Recovery

### Using ZFS Snapshots (The Lifesaver)
```bash
# Stop everything
sudo systemctl stop tomcat9 postgresql

# Rollback to pre-migration snapshots
sudo zfs rollback tank/xnat_archive@premigration
sudo zfs rollback tank/xnat_cache@premigration
sudo zfs rollback tank/xnat_main@premigration
sudo zfs rollback tank/xnat_prearchive@premigration

# Restore database
sudo -u postgres dropdb xnat
sudo -u postgres createdb -O xnat xnat
sudo -u postgres pg_restore -d xnat /backup/xnat_backup.dump

# Reapply critical fixes
sudo ln -sfn /data/xnat /opt/xnat/data

# Start services
sudo systemctl start postgresql tomcat9
```

---

## Prevention Checklist

Before declaring victory:

- [ ] `/opt/xnat/data` symlink exists and points to `/data/xnat`
- [ ] Admin can login (not just authenticate)
- [ ] Regular user can login
- [ ] Download produces real files (not 22 bytes)
- [ ] No HTTPS redirects happening
- [ ] Expected projects visible
- [ ] Expected users can authenticate
- [ ] No ERROR in last 100 lines of catalina.out
- [ ] Created ZFS snapshot of working state

---

## Key Lessons

1. **The symlink is not optional** - Without `/opt/xnat/data → /data/xnat`, downloads fail
2. **Three things must align for auth** - Provider order, role assignments, site URL
3. **Database migrations lose roles** - Always check `xhbm_user_role` table
4. **XNAT ships with bugs** - The 1.8.10.1 PreResources issue is real
5. **Plugin ecosystem lags major versions** - 1.9.2 released before plugins ready
6. **ZFS snapshots save lives** - Used them multiple times during troubleshooting

---

*Every solution here fixed a real problem during an actual production migration. Institutional details have been abstracted.*
