# XNAT Migration Toolkit

**Debugged and deployed XNAT 1.8.1 neuroimaging platform for a 7TB+ research archive, resolving critical infrastructure failures that blocked 135 users from accessing 6,500+ brain imaging sessions.**

## The Challenge

A production neuroimaging research platform failed during migration to Ubuntu 22.04, leaving researchers unable to access critical brain scan data. The system exhibited multiple cascading failures:
- Authentication system returning "wrong password" for all 135 users
- Download functionality producing corrupted 22-byte files instead of gigabyte-sized imaging datasets
- Database corruption preventing user role assignments
- Tomcat/Java integration failures with modern systemd
- ZFS storage pool permission conflicts

## The Solution

Through systematic debugging and root cause analysis, I identified and resolved five interconnected issues:

1. **Fixed authentication hierarchy** - Discovered XNAT was loading authentication providers alphabetically instead of by configuration priority, causing all logins to fail against the wrong backend
2. **Restored download functionality** - Traced 22-byte file corruption to missing symlink chain (`/opt/xnat/data → /data/xnat`) that broke Java's file locking mechanism
3. **Repaired database corruption** - Manually reconstructed user role tables and corrected site URL redirects causing HTTPS loops
4. **Modernized systemd integration** - Rewrote Tomcat service configuration for proper user isolation and memory management
5. **Implemented ZFS permissions model** - Designed ownership structure compatible with both XNAT's Java processes and Ubuntu's security model

## Technical Skills Demonstrated

### Linux System Administration
- Debugged complex systemd service dependencies and override configurations
- Traced system calls to identify file permission issues across symlink chains
- Configured PostgreSQL 12 authentication and connection pooling
- Managed 7TB+ ZFS storage pools with snapshot-based rollback capability

### Application Deployment
- Deployed Tomcat 9 with custom JVM heap configuration (4GB) for medical imaging workloads
- Integrated 6 production plugins including DICOM viewers and LDAP authentication
- Configured dual-authentication system (database + LDAP) for 135 users

### Troubleshooting & Debugging
- Analyzed multi-gigabyte Tomcat/Java stack traces to identify root causes
- Correlated authentication logs across 3 systems (XNAT, PostgreSQL, LDAP)
- Used `strace` and `lsof` to debug file locking issues in production
- Implemented comprehensive logging strategy for production monitoring

### Database Administration
- Restored PostgreSQL database from 500MB+ dump files
- Manually repaired corrupted user role assignments via SQL
- Optimized database configuration for medical imaging metadata (70 projects, 6,547 sessions)

## Repository Contents

### `deploy.sh` - Production Deployment Script
Complete automation script that deploys XNAT with all discovered fixes:
- Pre-flight checks for system requirements
- ZFS dataset creation with proper mount points
- PostgreSQL installation and configuration
- Tomcat 9 setup with systemd integration
- XNAT deployment with critical symlink creation
- Post-deployment verification suite

### `TROUBLESHOOTING.md` - Production Issues Guide
Real-world troubleshooting guide covering:
- Authentication failures and resolution paths
- Download corruption root causes and fixes
- Database integrity verification procedures
- Performance tuning for large imaging datasets

## Impact

- **Restored access** for 135 researchers to 7TB+ of neuroimaging data
- **Eliminated downtime** by implementing rollback procedures using ZFS snapshots
- **Prevented data loss** through careful migration preserving 6,547 imaging sessions
- **Improved reliability** with comprehensive monitoring and diagnostic tooling

## Technologies

`Linux (Ubuntu 22.04)` `PostgreSQL 12` `Tomcat 9` `Java 8` `ZFS` `systemd` `LDAP` `Bash Scripting`

## Usage

While this toolkit documents a specific production migration, the deployment script can be adapted for similar XNAT installations:

```bash
# Review and customize configuration
vim deploy.sh

# Run deployment (requires root)
sudo ./deploy.sh

# Verify installation
curl http://localhost:8080/xnat/
```

## Lessons Learned

This project reinforced the importance of:
- **Systematic debugging** - Each "simple" issue had multiple contributing factors
- **Production empathy** - Understanding user impact drives better solutions
- **Documentation discipline** - Detailed notes enabled successful rollback and retry
- **Testing at scale** - 22-byte files worked in test; 7TB datasets revealed the symlink issue

---

*This toolkit represents real production work completed during a critical system migration. All sensitive information has been redacted while preserving technical accuracy.*