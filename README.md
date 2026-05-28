# XNAT Deployment Toolkit

Deployment and operations toolkit for migrating XNAT-based research infrastructure with reproducible setup, upgrade, and troubleshooting steps.

## Overview

This repository documents and automates a production-style migration of an XNAT neuroimaging platform to new Linux infrastructure. The work centered on moving a multi-terabyte imaging archive and PostgreSQL-backed XNAT application while preserving researcher access, authentication behavior, and download reliability.

The migration was validated first on a dedicated VM, then promoted to production only after the major failure modes had been reproduced and fixed. That test-first approach surfaced several undocumented XNAT behaviors around authentication provider order, generated archive paths, Tomcat permissions, and version-specific WAR file compatibility.

## What I Built

- A Bash deployment script for provisioning XNAT on Ubuntu with PostgreSQL, Tomcat, Java, filesystem layout, and XNAT configuration.
- A repeatable upgrade path from XNAT 1.8.1 through 1.8.10.1 to 1.9.2.
- Operational fixes for authentication order, user-role restoration, generated archive paths, Tomcat systemd restrictions, and a version-specific WAR file issue.
- Troubleshooting documentation for the migration issues that were most likely to break production use.

## Impact

- Migrated a 7TB+ imaging platform to new infrastructure.
- Validated the migration on a full VM test environment before production cutover.
- Avoided researcher-facing downtime during production deployment.
- Preserved core XNAT functionality while documenting plugin compatibility limits for later follow-up.

Specific institutional details have been abstracted. Hostnames, credentials, and internal paths are represented with placeholders where appropriate.

## Repository Contents

```text
.
|-- deploy.sh            # Deployment and upgrade automation
`-- TROUBLESHOOTING.md   # Operational fixes and diagnostics from testing
```

## Technical Highlights

### Authentication

XNAT loads authentication providers alphabetically by filename. The deployment script prefixes database and LDAP provider files so local administrator accounts are checked before LDAP-backed accounts.

### Storage Paths

Testing showed that XNAT can generate or expect `/opt/xnat/data` paths even when the archive is mounted elsewhere. The script creates the required symlink and documents the archive specification update needed to prevent empty ZIP downloads.

### Tomcat Permissions

The script configures Tomcat to run as the `xnat` user and adds systemd `ReadWritePaths` entries for the XNAT data directories. This avoids filesystem access failures on Ubuntu 22.04.

### Upgrade Compatibility

The migration path includes a fix for an XNAT 1.8.10.1 WAR packaging issue where `PreResources` must be changed to `PostResources` in `META-INF/context.xml` before deployment on Tomcat 9.

## Usage

Review and customize the configuration variables at the top of `deploy.sh` before running anything on a real host:

```bash
DB_NAME="xnat"
DB_USER="xnat"
DB_PASS="CHANGE_ME_STRONG_PASSWORD"
XNAT_HOME="/data/xnat/home"
XNAT_DATA="/data/xnat"
SITE_URL="http://localhost:8080"
ADMIN_EMAIL="admin@example.org"
```

Then run the script as root on an Ubuntu 22.04 host:

```bash
sudo ./deploy.sh
```

The script offers four modes:

1. Fresh installation
2. Upgrade existing XNAT 1.8.1 to 1.8.10.1
3. Upgrade existing XNAT 1.8.10.1 to 1.9.2
4. Complete migration path from 1.8.1 to 1.9.2

## Safety Notes

- Read the script before running it. It installs packages, creates users, changes Tomcat ownership, writes systemd overrides, and modifies XNAT configuration.
- Use a test VM before touching production infrastructure.
- Take filesystem and database backups before any migration or upgrade.
- Replace all placeholder credentials and URLs.
- Confirm plugin compatibility before upgrading to XNAT 1.9.x.

## Related Documentation

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the specific failure modes found during testing and the commands used to diagnose or fix them.
