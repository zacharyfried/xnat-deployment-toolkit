# XNAT Production Troubleshooting Guide

*Real-world issues encountered and resolved during 7TB+ neuroimaging archive migration*

## Critical Issue #1: Authentication Failures

### Symptom
- All users receive "Wrong username/password" error
- Logs show successful authentication but login fails
- Browser remains on login page after correct credentials

### Root Cause
Multiple authentication providers loading in wrong order, missing user roles in database, incorrect site URL configuration

### Solution
```bash
# 1. Check authentication provider order
ls -la /data/xnat/home/config/auth/
# Files load alphabetically - rename to control order

# 2. Verify user has assigned role
sudo -u postgres psql -d xnat
SELECT u.login, r.role FROM xdat_user u
LEFT JOIN xhbm_user_role r ON u.login = r.username
WHERE u.login = 'admin';

# 3. If no role, assign Administrator
INSERT INTO xhbm_user_role (created, disabled, enabled, timestamp, role, username)
VALUES (NOW(), '1969-12-31 19:00:00', true, NOW(), 'Administrator', 'admin');

# 4. Fix site URL to prevent HTTPS redirects
UPDATE xhbm_preference SET value = 'http://your-server:8080' WHERE name = 'siteUrl';
UPDATE xhbm_preference SET value = 'http' WHERE name = 'securityChannel';
\q

# 5. Restart Tomcat
sudo systemctl restart tomcat9
```

---

## Critical Issue #2: 22-Byte Empty ZIP Downloads

### Symptom
- Download appears to work but ZIP files are only 22 bytes
- ZIP files cannot be opened (corrupted)
- Same data downloads fine on old system

### Root Cause
Missing symlink prevents Java from creating lock files in archive directory

### Solution
```bash
# THE CRITICAL FIX - This symlink MUST exist
sudo ln -sfn /data/xnat /opt/xnat/data

# Verify symlink is correct
ls -la /opt/xnat/
# Must show: data -> /data/xnat

# If archive paths are wrong in database, also fix:
sudo -u postgres psql -d xnat
UPDATE xdat_resource SET path = REPLACE(path, '/opt/xnat/data/', '/data/xnat/')
WHERE path LIKE '/opt/xnat/data/%';
\q

# Restart and test
sudo systemctl restart tomcat9
```

---

## Critical Issue #3: Tomcat Fails to Start

### Symptom
- `systemctl status tomcat9` shows failed
- Logs show: `java.nio.file.NoSuchFileException: /opt/xnat/data/temp/`
- Or: Permission denied errors

### Root Cause
Missing temp directory or wrong ownership

### Solution
```bash
# Create all required directories
sudo mkdir -p /opt/xnat/data/temp
sudo mkdir -p /data/xnat/home/logs
sudo mkdir -p /data/xnat/home/work

# Fix ownership - MUST be xnat user, not tomcat
sudo chown -R xnat:xnat /data/xnat/
sudo chown -R xnat:xnat /opt/xnat/
sudo chown -R xnat:xnat /var/lib/tomcat9/
sudo chown -R xnat:xnat /var/log/tomcat9/

# Restart
sudo systemctl restart tomcat9
```

---

## Critical Issue #4: Database Connection Failures

### Symptom
- XNAT shows database connection errors
- PostgreSQL is running but XNAT cannot connect

### Root Cause
PostgreSQL authentication not configured for XNAT user

### Solution
```bash
# 1. Check PostgreSQL is running
sudo systemctl status postgresql

# 2. Test connection manually
PGPASSWORD=yourpass psql -h localhost -U xnat -d xnat -c "SELECT 1;"

# 3. If fails, fix authentication
sudo nano /etc/postgresql/12/main/pg_hba.conf

# Add these lines:
local   xnat    xnat    md5
host    xnat    xnat    127.0.0.1/32    md5

# 4. Restart PostgreSQL
sudo systemctl restart postgresql

# 5. Verify XNAT config has correct password
sudo cat /data/xnat/home/config/xnat-conf.properties | grep datasource
```

---

## Critical Issue #5: HTTPS Redirect Loop

### Symptom
- Browser redirects to https://server:8443/xnat/
- Connection refused on port 8443
- Cannot access XNAT interface

### Root Cause
Database contains HTTPS URLs from production system

### Solution
```bash
# Fix in database
sudo -u postgres psql -d xnat

-- Check current values
SELECT name, value FROM xhbm_preference
WHERE name IN ('siteUrl', 'securityChannel');

-- Update to HTTP
UPDATE xhbm_preference SET value = 'http://your-server:8080'
WHERE name = 'siteUrl';

UPDATE xhbm_preference SET value = 'http'
WHERE name = 'securityChannel';

\q

# Restart Tomcat
sudo systemctl restart tomcat9
```

---

## Performance Issues

### High Memory Usage
```bash
# Check current heap settings
ps aux | grep tomcat | grep Xmx

# Adjust in systemd override
sudo nano /etc/systemd/system/tomcat9.service.d/override.conf
# Modify: Environment="JAVA_OPTS=-Xms2048m -Xmx8192m ..."

sudo systemctl daemon-reload
sudo systemctl restart tomcat9
```

### Slow Database Queries
```bash
# Analyze and vacuum PostgreSQL
sudo -u postgres psql -d xnat
ANALYZE;
VACUUM FULL;
\q

# Check for missing indexes
sudo -u postgres psql -d xnat
SELECT schemaname, tablename, indexname
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename;
\q
```

---

## Diagnostic Commands

### Check Service Status
```bash
# Quick health check
sudo systemctl status postgresql tomcat9

# Check ports
sudo ss -tlpn | grep -E '8080|5432'

# Check disk space
df -h /data/xnat

# Check file counts
find /data/xnat/archive -type f | wc -l
```

### Monitor Logs
```bash
# Tomcat main log
sudo tail -f /var/log/tomcat9/catalina.out

# XNAT security log
sudo tail -f /data/xnat/home/logs/security.log

# PostgreSQL log
sudo tail -f /var/log/postgresql/postgresql-12-main.log
```

### Test XNAT Endpoints
```bash
# Test basic connectivity
curl -I http://localhost:8080/xnat/

# Test API (requires auth)
curl -u admin:password http://localhost:8080/xnat/data/projects
```

---

## Emergency Recovery

### Full System Rollback
```bash
# If using ZFS snapshots
sudo zfs rollback tank/xnat_archive@premigration
sudo zfs rollback tank/xnat_main@premigration

# Database restore
sudo -u postgres dropdb xnat
sudo -u postgres createdb xnat
sudo -u postgres pg_restore -d xnat /backup/xnat_backup.dump

# Restart services
sudo systemctl restart postgresql tomcat9
```

### Clear Tomcat Cache
```bash
# Stop Tomcat
sudo systemctl stop tomcat9

# Clear work directory
sudo rm -rf /var/lib/tomcat9/work/*
sudo rm -rf /var/lib/tomcat9/webapps/ROOT/

# Redeploy
sudo cp /data/xnat/build/xnat-web-1.8.1.war /var/lib/tomcat9/webapps/ROOT.war
sudo chown xnat:xnat /var/lib/tomcat9/webapps/ROOT.war

# Start Tomcat
sudo systemctl start tomcat9
```

---

## Prevention Checklist

Before declaring migration complete:

- [ ] Test admin login works
- [ ] Test regular user login works
- [ ] Download a scan as ZIP (verify size > 1KB)
- [ ] Open downloaded ZIP and verify contents
- [ ] Check no HTTPS redirects occurring
- [ ] Verify all projects are visible
- [ ] Test DICOM viewer loads images
- [ ] Check logs for any ERROR messages
- [ ] Document all custom configurations
- [ ] Create snapshot/backup of working state

---

*This guide is based on actual production issues encountered during XNAT 1.8.1 migration. Each solution has been tested and verified in production.*