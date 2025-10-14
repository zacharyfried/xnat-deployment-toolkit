# XNAT Deployment Toolkit

Spent a week debugging why 135 researchers couldn't access their brain scans after a server migration. Fixed it. Here's how.

## What Happened

Our neuroimaging lab's XNAT server (7TB of MRI data, 6,500+ scanning sessions) completely broke during an Ubuntu upgrade. Users got "wrong password" errors, downloads produced 22-byte empty files instead of gigabytes of brain scans, and the database was corrupted. The vendor docs were useless.

## What I Fixed

Started with the authentication system - turns out XNAT loads auth providers alphabetically (seriously?), so `ldap-provider.properties` was hijacking all login attempts before checking the actual user database. Renamed the files to control load order.

But users still couldn't log in. Dug through PostgreSQL and found the user_role table was empty - the migration had wiped all permissions. Manually rebuilt role assignments with SQL inserts.

The download bug was weirder. Files existed, permissions were fine, but every download was exactly 22 bytes. After tracing through the Java stack traces, discovered XNAT hardcodes `/opt/xnat/data` in its file locking mechanism but our data lived in `/data/xnat`. One symlink fixed six hours of debugging.

Also had to:
- Rewrite the Tomcat systemd service (Ubuntu 22.04 changed how user isolation works)
- Fix HTTPS redirect loops by updating database URLs
- Create missing temp directories that nobody documented

## Tech Stack

Built and debugged on: Ubuntu 22.04, PostgreSQL 12, Tomcat 9, Java 8, ZFS storage

The deployment script (`deploy.sh`) includes all the fixes I discovered. The troubleshooting guide has the actual commands that saved me.

## Results

Got everyone back online without losing data. The senior admin who'd been fighting this for three days bought me coffee. Learned the hard way that "working in dev" means nothing when you're dealing with 7TB of production data and symlinks.

If you're hiring someone who can figure out why your app is broken when the logs lie and the docs are wrong, let's talk.

---

*Note: Sensitive info redacted. This was real production work at a research institution.*