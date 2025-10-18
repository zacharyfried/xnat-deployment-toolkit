#!/bin/bash
################################################################################
# XNAT Complete Migration Script - 1.8.1 → 1.8.10.1 → 1.9.2
# Purpose: Deploy and upgrade XNAT with all fixes from 7TB+ production migration
# Platform: Ubuntu 22.04 LTS with PostgreSQL 12, Tomcat 9, Java 8
# Final Version: XNAT 1.9.2 (fully functional)
# Based on: Real migration completed May-June 2025
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration Variables
XNAT_VERSION_START="1.8.1"
XNAT_VERSION_INTERMEDIATE="1.8.10.1"
XNAT_VERSION_FINAL="1.9.2"
DB_NAME="xnat"
DB_USER="xnat"
DB_PASS="CHANGE_ME_STRONG_PASSWORD"  # CRITICAL: Set strong password
XNAT_HOME="/data/xnat/home"
XNAT_DATA="/data/xnat"
SITE_URL="http://localhost:8080"  # CRITICAL: Must match your hostname exactly
ADMIN_EMAIL="admin@example.org"

# Java memory settings (adjust based on available RAM)
HEAP_MIN="1024m"
HEAP_MAX="4096m"  # Increase for large datasets

################################################################################
# Helper Functions
################################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    exit 1
}

log_critical() {
    echo -e "${BLUE}[CRITICAL FIX]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
    fi
}

################################################################################
# Phase 0: Prerequisites Check
################################################################################

check_prerequisites() {
    log_info "Checking system prerequisites..."

    # Check Ubuntu version
    if ! grep -q "Ubuntu 22.04" /etc/os-release; then
        log_warn "This script is tested on Ubuntu 22.04 LTS. Other versions may have issues."
    fi

    # Check available memory
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt 16384 ]; then
        log_warn "System has less than 16GB RAM. Large datasets may cause issues."
    fi

    log_info "Prerequisites check complete"
}

################################################################################
# Phase 1: System Setup
################################################################################

setup_system() {
    log_info "Setting up system dependencies..."

    # Update package lists
    apt-get update

    # Install required packages
    apt-get install -y \
        openjdk-8-jdk \
        postgresql-12 \
        postgresql-client-12 \
        postgresql-contrib-12 \
        tomcat9 \
        tomcat9-admin \
        unzip \
        zip \
        curl \
        wget \
        nano \
        sudo \
        sed

    # CRITICAL: Set Java 8 as default (XNAT requires Java 8)
    update-alternatives --set java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java

    # Verify Java version
    JAVA_VER=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
    if [[ ! "$JAVA_VER" =~ ^1\.8\. ]]; then
        log_error "Java 8 is required but found: $JAVA_VER"
    fi

    log_info "System dependencies installed"
}

################################################################################
# Phase 2: User Creation (CRITICAL: Must be 'xnat' not 'tomcat')
################################################################################

create_xnat_user() {
    log_critical "Creating XNAT user (not tomcat - this is critical!)..."

    if id "xnat" &>/dev/null; then
        log_info "User 'xnat' already exists"
    else
        useradd -m -U -s /bin/bash xnat
        log_info "Created user 'xnat' with home directory"
    fi
}

################################################################################
# Phase 3: Storage Configuration with CRITICAL SYMLINK
################################################################################

setup_storage() {
    log_info "Setting up storage directories..."

    # Create main XNAT directories (matching production structure)
    mkdir -p ${XNAT_DATA}/archive
    mkdir -p ${XNAT_DATA}/cache
    mkdir -p ${XNAT_DATA}/cache_working
    mkdir -p ${XNAT_DATA}/prearchive
    mkdir -p ${XNAT_DATA}/build
    mkdir -p ${XNAT_DATA}/temp
    mkdir -p ${XNAT_HOME}/logs
    mkdir -p ${XNAT_HOME}/work
    mkdir -p ${XNAT_HOME}/config
    mkdir -p ${XNAT_HOME}/plugins

    # CRITICAL FIX #1: Create THE symlink that prevents 22-byte download bug
    log_critical "Creating /opt/xnat/data symlink - WITHOUT THIS, DOWNLOADS WILL FAIL!"
    mkdir -p /opt/xnat
    ln -sfn ${XNAT_DATA} /opt/xnat/data

    # Verify symlink exists and points correctly
    if [ ! -L "/opt/xnat/data" ]; then
        log_error "Failed to create critical symlink /opt/xnat/data - downloads will produce 22-byte files!"
    fi

    if [ "$(readlink -f /opt/xnat/data)" != "${XNAT_DATA}" ]; then
        log_error "Symlink /opt/xnat/data doesn't point to ${XNAT_DATA}"
    fi

    # Set ownership to xnat user
    chown -R xnat:xnat ${XNAT_DATA}
    chown -R xnat:xnat /opt/xnat

    log_info "Storage setup complete with critical symlink"
}

################################################################################
# Phase 4: PostgreSQL Setup
################################################################################

setup_database() {
    log_info "Setting up PostgreSQL database..."

    # Start PostgreSQL
    systemctl start postgresql
    systemctl enable postgresql

    # Create database and user
    sudo -u postgres psql <<EOF
-- Drop if exists (for re-runs)
DROP DATABASE IF EXISTS ${DB_NAME};
DROP USER IF EXISTS ${DB_USER};

-- Create user and database
CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';
CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

    # Configure PostgreSQL authentication
    PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oP '\d+' | head -1)
    PG_CONFIG="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

    # Backup original config
    cp ${PG_CONFIG} ${PG_CONFIG}.backup

    # Add XNAT authentication rules
    if ! grep -q "xnat" ${PG_CONFIG}; then
        echo "# XNAT authentication rules" >> ${PG_CONFIG}
        echo "local   ${DB_NAME}    ${DB_USER}    md5" >> ${PG_CONFIG}
        echo "host    ${DB_NAME}    ${DB_USER}    127.0.0.1/32    md5" >> ${PG_CONFIG}
        echo "host    ${DB_NAME}    ${DB_USER}    ::1/128         md5" >> ${PG_CONFIG}
    fi

    # Restart PostgreSQL to apply changes
    systemctl restart postgresql

    log_info "Database setup complete"
}

################################################################################
# Phase 5: Tomcat Configuration (CRITICAL: User and permissions)
################################################################################

setup_tomcat() {
    log_info "Configuring Tomcat 9..."

    # Stop Tomcat if running
    systemctl stop tomcat9 || true

    # CRITICAL: Change ALL Tomcat ownership to xnat user
    log_critical "Setting Tomcat ownership to xnat user (prevents permission errors)..."
    chown -R xnat:xnat /var/lib/tomcat9/
    chown -R xnat:xnat /etc/tomcat9/
    chown -R xnat:xnat /var/log/tomcat9/
    chown -R xnat:xnat /var/cache/tomcat9/

    # Create systemd override with critical settings
    mkdir -p /etc/systemd/system/tomcat9.service.d/

    cat > /etc/systemd/system/tomcat9.service.d/override.conf <<EOF
[Service]
# CRITICAL: Run as xnat user, not tomcat
User=xnat
Group=xnat

# Java configuration
Environment="JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64"
Environment="JAVA_OPTS=-Xms${HEAP_MIN} -Xmx${HEAP_MAX} -XX:+UseG1GC -Djava.awt.headless=true"

# XNAT configuration
Environment="XNAT_HOME=${XNAT_HOME}"
Environment="xnat.home=${XNAT_HOME}"

# Temp directory configuration
Environment="CATALINA_TMPDIR=/opt/xnat/data/temp"
Environment="java.io.tmpdir=/opt/xnat/data/temp"

# CRITICAL: Allow read/write to XNAT directories (prevents permission denied)
ReadWritePaths=/opt/xnat/data/ ${XNAT_DATA}/ ${XNAT_HOME}/
EOF

    # Reload systemd configuration
    systemctl daemon-reload
    systemctl enable tomcat9

    log_info "Tomcat configuration complete"
}

################################################################################
# Phase 6: Initial XNAT 1.8.1 Deployment
################################################################################

deploy_xnat_initial() {
    log_info "Deploying XNAT ${XNAT_VERSION_START}..."

    # Download XNAT 1.8.1 if not exists
    WAR_FILE="/tmp/xnat-web-${XNAT_VERSION_START}.war"
    if [ ! -f "${WAR_FILE}" ]; then
        log_info "Downloading XNAT ${XNAT_VERSION_START} WAR file..."
        wget -O ${WAR_FILE} \
            "https://api.bitbucket.org/2.0/repositories/xnatdev/xnat-web/downloads/xnat-web-${XNAT_VERSION_START}.war"
    fi

    # Remove old deployments
    rm -rf /var/lib/tomcat9/webapps/ROOT*

    # Deploy as ROOT application
    cp ${WAR_FILE} /var/lib/tomcat9/webapps/ROOT.war
    chown xnat:xnat /var/lib/tomcat9/webapps/ROOT.war

    # Create XNAT configuration file
    cat > ${XNAT_HOME}/config/xnat-conf.properties <<EOF
# XNAT Configuration - Generated by migration script
datasource.driver=org.postgresql.Driver
datasource.url=jdbc:postgresql://localhost:5432/${DB_NAME}
datasource.username=${DB_USER}
datasource.password=${DB_PASS}

hibernate.dialect=org.hibernate.dialect.PostgreSQL9Dialect
hibernate.hbm2ddl.auto=update
hibernate.show_sql=false
hibernate.cache.use_second_level_cache=true
hibernate.cache.use_query_cache=true

# CRITICAL: Prevent HTTPS redirect issues
xnat.url=${SITE_URL}
EOF

    chown xnat:xnat ${XNAT_HOME}/config/xnat-conf.properties
    chmod 600 ${XNAT_HOME}/config/xnat-conf.properties

    log_info "XNAT ${XNAT_VERSION_START} deployment prepared"
}

################################################################################
# Phase 7: Authentication Configuration
################################################################################

setup_authentication() {
    log_info "Configuring authentication providers..."

    # CRITICAL: XNAT loads providers alphabetically by filename, not by config!
    # Database auth must load before LDAP or admin accounts won't work

    mkdir -p ${XNAT_HOME}/config/auth

    # Create database provider with 01- prefix to load first
    cat > ${XNAT_HOME}/config/auth/01-localdb-provider.properties <<EOF
# Database Authentication Provider
# MUST load before LDAP (hence 01- prefix)
name=Database
id=localdb
order=1
enabled=true
visible=true
type=db
EOF

    # Create LDAP provider with 02- prefix to load second
    cat > ${XNAT_HOME}/config/auth/02-ldap-provider.properties <<EOF
# LDAP Authentication Provider
# Loads after database authentication
name=LDAP
id=ldap1
order=2
enabled=true
visible=true
type=ldap
# Add your LDAP configuration here if needed
EOF

    chown -R xnat:xnat ${XNAT_HOME}/config/auth
    log_info "Authentication providers configured with correct load order"
}

################################################################################
# Phase 8: Start Services and Initial Setup
################################################################################

start_initial_services() {
    log_info "Starting Tomcat for initial XNAT setup..."

    systemctl start tomcat9

    log_info "Waiting for XNAT to initialize (this takes 2-3 minutes)..."

    COUNTER=0
    MAX_WAIT=240
    while [ $COUNTER -lt $MAX_WAIT ]; do
        if curl -s -o /dev/null -w "%{http_code}" ${SITE_URL}/ 2>/dev/null | grep -q "302\|200"; then
            echo ""
            log_info "XNAT ${XNAT_VERSION_START} is responding!"
            break
        fi
        sleep 5
        COUNTER=$((COUNTER + 5))
        echo -n "."
    done
    echo ""

    if [ $COUNTER -ge $MAX_WAIT ]; then
        log_error "XNAT failed to start. Check: tail -f /var/log/tomcat9/catalina.out"
    fi

    # Give XNAT time to fully initialize database
    log_info "Waiting for database initialization..."
    sleep 30
}

################################################################################
# Phase 9: Apply Critical Production Fixes
################################################################################

apply_critical_fixes() {
    log_info "Applying critical production fixes..."

    # FIX #1: Database preferences to prevent HTTPS redirect loop
    log_critical "Fixing database URLs to prevent HTTPS redirect loops..."
    PGPASSWORD=${DB_PASS} psql -h localhost -U ${DB_USER} -d ${DB_NAME} <<EOF 2>/dev/null || true
-- Fix site URL and security channel
UPDATE xhbm_preference SET value = '${SITE_URL}' WHERE name = 'siteUrl';
UPDATE xhbm_preference SET value = 'http' WHERE name = 'securityChannel';
UPDATE xhbm_preference SET value = '${SITE_URL}' WHERE name = 'siteURL';

-- Ensure admin email is set
UPDATE xhbm_preference SET value = '${ADMIN_EMAIL}' WHERE name = 'adminEmail';
EOF

    # FIX #2: Archive specification paths (prevents 22-byte downloads)
    # XNAT generates this file with incorrect paths that must be fixed
    if [ -f "${XNAT_DATA}/cache_working/archive_specification.xml" ]; then
        log_critical "Fixing archive specification paths (306+ incorrect paths in production)..."
        # Backup original
        cp ${XNAT_DATA}/cache_working/archive_specification.xml \
           ${XNAT_DATA}/cache_working/archive_specification.xml.backup

        # Replace all incorrect paths
        sed -i "s|/opt/xnat/data/|${XNAT_DATA}/|g" \
            ${XNAT_DATA}/cache_working/archive_specification.xml
        log_info "Fixed archive specification paths"
    fi

    # FIX #3: Create cache directories with correct permissions
    mkdir -p ${XNAT_DATA}/cache/GENERATED
    mkdir -p ${XNAT_DATA}/cache_working
    chown -R xnat:xnat ${XNAT_DATA}/cache*

    # FIX #4: Ensure temp directory exists and is writable
    mkdir -p /opt/xnat/data/temp
    chown xnat:xnat /opt/xnat/data/temp
    chmod 755 /opt/xnat/data/temp

    log_info "Critical fixes applied"
}

################################################################################
# Phase 10: Upgrade to XNAT 1.8.10.1
################################################################################

upgrade_to_18101() {
    log_info "Upgrading to XNAT ${XNAT_VERSION_INTERMEDIATE}..."

    # Stop Tomcat
    systemctl stop tomcat9

    # Download XNAT 1.8.10.1
    WAR_FILE="/tmp/xnat-web-${XNAT_VERSION_INTERMEDIATE}.war"
    if [ ! -f "${WAR_FILE}" ]; then
        log_info "Downloading XNAT ${XNAT_VERSION_INTERMEDIATE}..."
        curl -k -L -o ${WAR_FILE} \
            "https://api.bitbucket.org/2.0/repositories/xnatdev/xnat-web/downloads/xnat-web-${XNAT_VERSION_INTERMEDIATE}.war"
    fi

    # CRITICAL: Fix the PreResources bug in 1.8.10.1
    log_critical "Fixing PreResources bug in XNAT ${XNAT_VERSION_INTERMEDIATE} WAR file..."

    # Create temp directory for fix
    TEMP_FIX="/tmp/xnat-fix-$$"
    mkdir -p ${TEMP_FIX}
    cd ${TEMP_FIX}

    # Extract WAR
    jar xf ${WAR_FILE}

    # Fix context.xml (PreResources -> PostResources)
    if grep -q "PreResources" META-INF/context.xml; then
        log_info "Found PreResources bug, fixing..."
        sed -i 's/PreResources/PostResources/g' META-INF/context.xml
    fi

    # Repack WAR
    jar cfM ${WAR_FILE}.fixed .
    mv ${WAR_FILE}.fixed ${WAR_FILE}

    # Clean up
    cd /
    rm -rf ${TEMP_FIX}

    # Deploy fixed WAR
    rm -rf /var/lib/tomcat9/webapps/ROOT*
    cp ${WAR_FILE} /var/lib/tomcat9/webapps/ROOT.war
    chown xnat:xnat /var/lib/tomcat9/webapps/ROOT.war

    # Start Tomcat
    systemctl start tomcat9

    log_info "Waiting for XNAT ${XNAT_VERSION_INTERMEDIATE} to start..."
    sleep 60

    # Wait for XNAT to be ready
    COUNTER=0
    MAX_WAIT=180
    while [ $COUNTER -lt $MAX_WAIT ]; do
        if curl -s -o /dev/null -w "%{http_code}" ${SITE_URL}/ 2>/dev/null | grep -q "302\|200"; then
            log_info "XNAT ${XNAT_VERSION_INTERMEDIATE} upgrade successful!"
            break
        fi
        sleep 5
        COUNTER=$((COUNTER + 5))
    done

    if [ $COUNTER -ge $MAX_WAIT ]; then
        log_error "XNAT ${XNAT_VERSION_INTERMEDIATE} failed to start after upgrade"
    fi

    # Reapply critical fixes (paths may need updating again)
    apply_critical_fixes
}

################################################################################
# Phase 11: Upgrade to XNAT 1.9.2
################################################################################

upgrade_to_192() {
    log_info "Upgrading to XNAT ${XNAT_VERSION_FINAL}..."

    # Stop Tomcat
    systemctl stop tomcat9

    # Backup plugins (some may not be compatible)
    log_warn "Backing up plugins (some may be incompatible with 1.9.2)..."
    mkdir -p /root/plugin-backups-${XNAT_VERSION_INTERMEDIATE}
    cp ${XNAT_HOME}/plugins/*.jar /root/plugin-backups-${XNAT_VERSION_INTERMEDIATE}/ 2>/dev/null || true

    # Download XNAT 1.9.2
    WAR_FILE="/tmp/xnat-web-${XNAT_VERSION_FINAL}.war"
    if [ ! -f "${WAR_FILE}" ]; then
        log_info "Downloading XNAT ${XNAT_VERSION_FINAL}..."
        wget --no-check-certificate -O ${WAR_FILE} \
            "https://github.com/NrgXnat/xnat-web/releases/download/${XNAT_VERSION_FINAL}/xnat-web-${XNAT_VERSION_FINAL}.war"
    fi

    # Deploy 1.9.2
    rm -rf /var/lib/tomcat9/webapps/ROOT*
    cp ${WAR_FILE} /var/lib/tomcat9/webapps/ROOT.war
    chown xnat:xnat /var/lib/tomcat9/webapps/ROOT.war

    # Handle plugin compatibility
    log_warn "Note: Container Service and OHIF Viewer plugins may be incompatible with 1.9.2"
    log_warn "Core XNAT will work perfectly with built-in features"

    # Start Tomcat
    systemctl start tomcat9

    log_info "Waiting for XNAT ${XNAT_VERSION_FINAL} to start (database migration may take time)..."
    sleep 90

    # Wait for XNAT to be ready
    COUNTER=0
    MAX_WAIT=300
    while [ $COUNTER -lt $MAX_WAIT ]; do
        if curl -s -o /dev/null -w "%{http_code}" ${SITE_URL}/ 2>/dev/null | grep -q "302\|200"; then
            log_info "XNAT ${XNAT_VERSION_FINAL} upgrade successful!"
            break
        fi
        sleep 5
        COUNTER=$((COUNTER + 5))
    done

    if [ $COUNTER -ge $MAX_WAIT ]; then
        log_error "XNAT ${XNAT_VERSION_FINAL} failed to start after upgrade"
    fi

    # Reapply critical fixes one more time
    apply_critical_fixes
}

################################################################################
# Phase 12: Fix User Roles (if migrating existing database)
################################################################################

fix_user_roles() {
    log_info "Checking user role assignments..."

    # This is only needed if you restored a database dump
    read -p "Did you restore from a database dump? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_critical "Fixing user role assignments..."

        PGPASSWORD=${DB_PASS} psql -h localhost -U ${DB_USER} -d ${DB_NAME} <<EOF
-- Ensure admin user has Administrator role
-- Adjust username as needed for your admin account
INSERT INTO xhbm_user_role (role, username, enabled, timestamp, created, disabled)
VALUES ('Administrator', 'admin', true, NOW(), NOW(), '1969-12-31 19:00:00')
ON CONFLICT DO NOTHING;
EOF

        log_info "User roles fixed"
    fi
}

################################################################################
# Phase 13: Verification
################################################################################

verify_installation() {
    log_info "Verifying installation..."

    ERRORS=0
    WARNINGS=0

    # Check critical symlink
    if [ ! -L "/opt/xnat/data" ]; then
        log_error "CRITICAL: Symlink /opt/xnat/data missing - downloads will fail!"
        ERRORS=$((ERRORS + 1))
    else
        log_info "✓ Critical symlink exists"
    fi

    # Check services
    if ! systemctl is-active --quiet postgresql; then
        log_warn "PostgreSQL is not running"
        WARNINGS=$((WARNINGS + 1))
    else
        log_info "✓ PostgreSQL running"
    fi

    if ! systemctl is-active --quiet tomcat9; then
        log_warn "Tomcat is not running"
        WARNINGS=$((WARNINGS + 1))
    else
        log_info "✓ Tomcat running"
    fi

    # Check XNAT response
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" ${SITE_URL}/ 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "200" ]; then
        log_info "✓ XNAT ${XNAT_VERSION_FINAL} responding (HTTP $HTTP_CODE)"
    else
        log_warn "XNAT not responding properly (HTTP $HTTP_CODE)"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check database connectivity
    if PGPASSWORD=${DB_PASS} psql -h localhost -U ${DB_USER} -d ${DB_NAME} -c "SELECT 1" &>/dev/null; then
        log_info "✓ Database connection successful"
    else
        log_warn "Database connection failed"
        WARNINGS=$((WARNINGS + 1))
    fi

    echo ""
    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        log_info "✅ All checks passed! XNAT ${XNAT_VERSION_FINAL} is fully operational!"
    elif [ $ERRORS -gt 0 ]; then
        log_error "Installation failed with $ERRORS critical error(s)"
    else
        log_warn "Installation completed with $WARNINGS warning(s)"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    echo "=========================================="
    echo "XNAT Complete Migration: ${XNAT_VERSION_START} → ${XNAT_VERSION_INTERMEDIATE} → ${XNAT_VERSION_FINAL}"
    echo "Based on production 7TB+ migration"
    echo "=========================================="
    echo ""

    check_root
    check_prerequisites

    # Ask deployment type
    echo "Select deployment option:"
    echo "1) Fresh installation (start from 1.8.1 and upgrade)"
    echo "2) Upgrade existing 1.8.1 to 1.8.10.1"
    echo "3) Upgrade existing 1.8.10.1 to 1.9.2"
    echo "4) Complete migration (1.8.1 → 1.8.10.1 → 1.9.2)"
    read -p "Enter choice [1-4]: " choice

    case $choice in
        1)
            log_info "Starting fresh XNAT installation and upgrade path..."
            setup_system
            create_xnat_user
            setup_storage
            setup_database
            setup_tomcat
            deploy_xnat_initial
            setup_authentication
            start_initial_services
            apply_critical_fixes
            fix_user_roles
            verify_installation
            ;;
        2)
            log_info "Upgrading existing XNAT 1.8.1 to 1.8.10.1..."
            upgrade_to_18101
            verify_installation
            ;;
        3)
            log_info "Upgrading existing XNAT 1.8.10.1 to 1.9.2..."
            upgrade_to_192
            verify_installation
            ;;
        4)
            log_info "Performing complete migration path..."
            setup_system
            create_xnat_user
            setup_storage
            setup_database
            setup_tomcat
            deploy_xnat_initial
            setup_authentication
            start_initial_services
            apply_critical_fixes
            fix_user_roles
            log_info "XNAT 1.8.1 installed, proceeding to upgrades..."
            upgrade_to_18101
            log_info "XNAT 1.8.10.1 installed, proceeding to final upgrade..."
            upgrade_to_192
            verify_installation
            ;;
        *)
            log_error "Invalid choice"
            ;;
    esac

    echo ""
    echo "=========================================="
    echo "DEPLOYMENT COMPLETE"
    echo "=========================================="
    echo ""
    echo "XNAT URL: ${SITE_URL}/"
    echo "Version: ${XNAT_VERSION_FINAL}"
    echo ""
    echo "CRITICAL REMINDERS:"
    echo "1. The symlink /opt/xnat/data MUST exist or downloads fail"
    echo "2. Check authentication provider order if login fails"
    echo "3. Verify user roles if using existing database"
    echo "4. Update site URL in database if hostname changes"
    echo ""
    echo "Note on plugins:"
    echo "- LDAP auth plugin works with 1.9.2"
    echo "- Container Service needs version 3.6.0+ for 1.9.2 (may not be released yet)"
    echo "- OHIF Viewer needs version 3.7.0+ for 1.9.2 (may not be released yet)"
    echo "- Core XNAT functionality works perfectly without these plugins"
    echo ""
    echo "Monitor logs:"
    echo "  tail -f /var/log/tomcat9/catalina.out"
    echo "  tail -f ${XNAT_HOME}/logs/xnat.log"
    echo ""
    echo "For troubleshooting, see TROUBLESHOOTING.md"
    echo ""
}

# Run main function
main "$@"