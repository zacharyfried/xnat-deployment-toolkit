# XNAT Migration Toolkit

Successfully migrated a 7TB+ neuroimaging platform to new infrastructure. Built and tested on a dedicated VM before production deployment, ensuring zero downtime for researchers.

## Project Overview

Our research facility needed to migrate their XNAT neuroimaging platform to new infrastructure. XNAT is specialized software for managing MRI and CT scan data with integrated viewing and analysis capabilities. The production system had been running for several years with thousands of imaging sessions across dozens of research projects.

As the Linux administrator, I was responsible for setting up the new environment, migrating all data, and ensuring everything worked perfectly before switching over. I built the entire system on a test VM first, which allowed me to identify and resolve multiple undocumented issues before they could affect any users.

## Technical Approach

The migration involved moving over 7TB of imaging data and a PostgreSQL database with 100+ user accounts to a fresh Ubuntu 22.04 installation. Rather than risk any production impact, I:

1. Set up a complete test environment on a new VM
2. Migrated all data using ZFS snapshots (providing integrity checks and rollback capability)
3. Systematically identified and resolved configuration issues
4. Validated everything worked correctly
5. Only then deployed to production

This approach meant zero downtime and zero user impact. The challenges I encountered and solved during the test phase would have caused significant problems if discovered during a production migration.

## Technical Challenges Resolved

### Authentication Configuration

During testing, I discovered that XNAT's authentication system had several non-obvious requirements. The software loads authentication providers alphabetically by filename, not by configuration settings. This meant LDAP providers were being checked before local database providers, which would have prevented admin accounts from working.

Additionally, the database migration process didn't preserve user role assignments, and the migrated database contained URLs pointing to the old production server. I identified these issues in the test environment and built fixes into my deployment process.

### File System Integration

Testing revealed that XNAT hardcodes certain paths in its file operations. Despite our data being properly mounted at `/data/xnat`, the software expected a path at `/opt/xnat/data` for creating lock files during downloads. Without the proper symbolic link, all file downloads would produce empty 22-byte ZIP files.

I also discovered that XNAT's configuration generator created hundreds of incorrect path references that needed to be corrected. Finding this in testing saved significant troubleshooting time.

### Software Compatibility

When testing the upgrade path from 1.8.1 to 1.8.10.1, I found that the official WAR file contained a configuration error. The context.xml specified `PreResources` instead of `PostResources`, which would cause deployment failures in Tomcat 9. I documented the fix and incorporated it into the deployment process.

## Migration Results

The systematic testing approach paid off. When we deployed to production:

- All data migrated successfully (zero loss)
- Users experienced no downtime
- Authentication worked immediately
- File downloads functioned correctly
- System upgraded cleanly to XNAT 1.9.2

The final production system runs on Ubuntu 22.04 with PostgreSQL 12, Tomcat 9, and Java 8. While some third-party plugins had compatibility issues with 1.9.2, the core XNAT functionality works perfectly with the built-in features meeting all requirements.

## Repository Contents

This repository contains the automation and documentation I developed during the project:

**deploy.sh** - Production-ready deployment script with all necessary configurations and fixes built in

**TROUBLESHOOTING.md** - Comprehensive documentation of potential issues and their solutions

The deployment script incorporates everything I learned during testing:
- Creates required symbolic links
- Configures authentication providers correctly
- Sets proper database parameters
- Corrects path specifications
- Handles WAR file modifications for upgrades

## Value Delivered

By thoroughly testing on a VM first, I:
- Prevented any production downtime
- Identified issues that weren't documented anywhere
- Created repeatable deployment process
- Built institutional knowledge for future migrations

The careful preparation meant that when we did the actual production deployment, everything worked on the first try. Researchers never experienced any interruption to their work.

---

*Work performed for a research institution. Specific details appropriately abstracted.*