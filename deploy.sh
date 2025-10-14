#!/bin/bash
################################################################################
# XNAT 1.8.1 Production Deployment Script
# Purpose: Deploy XNAT neuroimaging platform on Ubuntu 22.04 with PostgreSQL/Tomcat
# Author: Zachary Fried
# Version: 2.3
################################################################################

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration Variables (REDACTED - Replace with your values)
XNAT_VERSION="1.8.1"
DB_NAME="xnat"
DB_USER="xnat"
DB_PASS="CHANGE_ME"  # TODO: Set strong password
XNAT_HOME="/data/xnat/home"
XNAT_DATA="/data/xnat"
SITE_URL="http://localhost:8080"  # TODO: Set your actual hostname
ADMIN_EMAIL="admin@example.org"    # TODO: Set admin email

# Java memory settings (adjust based on available RAM)
HEAP_MIN="1024m"
HEAP_MAX="4096m"

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

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
    fi
}

check_prerequisites() {
    log_info "Checking system prerequisites..."

    # Check Ubuntu version
    if ! grep -q "Ubuntu 22.04" /etc/os-release; then
        log_warn "This script is tested on Ubuntu 22.04. Proceed with caution."
    fi

    # Check available memory
    TOTAL_MEM=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$TOTAL_MEM" -lt 8192 ]; then
        log_warn "System has less than 8GB RAM. XNAT may run slowly."
    fi

    # Check disk space
    AVAILABLE_SPACE=$(df -BG /data 2>/dev/null | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ -z "$AVAILABLE_SPACE" ] || [ "$AVAILABLE_SPACE" -lt 50 ]; then
        log_warn "Less than 50GB available in /data. Ensure adequate storage for imaging data."
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
        curl \
        wget \
        nano \
        sudo

    # Set Java 8 as default
    update-alternatives --set java /usr/lib/jvm/java-8-openjdk-amd64/jre/bin/java

    log_info "System dependencies installed"
}

################################################################################
# Phase 2: User Creation
################################################################################

create_xnat_user() {
    log_info "Creating XNAT user..."

    # Check if user exists
    if id "xnat" &>/dev/null; then
        log_info "User 'xnat' already exists"
    else
        useradd -m -U -s /bin/bash xnat
        log_info "Created user 'xnat'"
    fi
}

################################################################################
# Phase 3: Storage Configuration
################################################################################

setup_storage() {
    log_info "Setting up storage directories..."

    # Create main XNAT directories
    mkdir -p ${XNAT_DATA}/home
    mkdir -p ${XNAT_DATA}/archive
    mkdir -p ${XNAT_DATA}/prearchive
    mkdir -p ${XNAT_DATA}/cache
    mkdir -p ${XNAT_DATA}/build
    mkdir -p ${XNAT_DATA}/temp
    mkdir -p ${XNAT_HOME}/logs
    mkdir -p ${XNAT_HOME}/work
    mkdir -p ${XNAT_HOME}/config
    mkdir -p ${XNAT_HOME}/plugins

    # CRITICAL: Create the symlink that prevents 22-byte download bug
    log_info "Creating critical symlink for download functionality..."
    mkdir -p /opt/xnat
    ln -sfn ${XNAT_DATA} /opt/xnat/data

    # Verify symlink
    if [ ! -L "/opt/xnat/data" ]; then
        log_error "Failed to create critical symlink /opt/xnat/data"
    fi

    # Set ownership
    chown -R xnat:xnat ${XNAT_DATA}
    chown -R xnat:xnat /opt/xnat

    log_info "Storage setup complete"
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

    # Configure authentication
    PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1)
    PG_CONFIG="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

    # Backup original config
    cp ${PG_CONFIG} ${PG_CONFIG}.backup

    # Add XNAT authentication rules
    if ! grep -q "xnat" ${PG_CONFIG}; then
        echo "# XNAT authentication" >> ${PG_CONFIG}
        echo "local   ${DB_NAME}    ${DB_USER}    md5" >> ${PG_CONFIG}
        echo "host    ${DB_NAME}    ${DB_USER}    127.0.0.1/32    md5" >> ${PG_CONFIG}
    fi

    # Restart PostgreSQL
    systemctl restart postgresql

    log_info "Database setup complete"
}

################################################################################
# Phase 5: Tomcat Configuration
################################################################################

setup_tomcat() {
    log_info "Configuring Tomcat 9..."

    # Stop Tomcat if running
    systemctl stop tomcat9 || true

    # Change ownership to xnat user
    chown -R xnat:xnat /var/lib/tomcat9/
    chown -R xnat:xnat /etc/tomcat9/
    chown -R xnat:xnat /var/log/tomcat9/

    # Create systemd override
    mkdir -p /etc/systemd/system/tomcat9.service.d/

    cat > /etc/systemd/system/tomcat9.service.d/override.conf <<EOF
[Service]
Environment="JAVA_HOME=/usr/lib/jvm/java-8-openjdk-amd64"
Environment="JAVA_OPTS=-Xms${HEAP_MIN} -Xmx${HEAP_MAX} -XX:+UseG1GC -Djava.awt.headless=true -Dxnat.home=${XNAT_HOME} -Djava.io.tmpdir=/opt/xnat/data/temp"
Environment="XNAT_HOME=${XNAT_HOME}"
Environment="CATALINA_TMPDIR=/opt/xnat/data/temp"
ReadWritePaths=/opt/xnat/data/ ${XNAT_DATA}/
User=xnat
Group=xnat
EOF

    # Reload systemd
    systemctl daemon-reload
    systemctl enable tomcat9

    log_info "Tomcat configuration complete"
}

################################################################################
# Phase 6: XNAT Deployment
################################################################################

deploy_xnat() {
    log_info "Deploying XNAT ${XNAT_VERSION}..."

    # Download XNAT WAR if not exists
    WAR_FILE="${XNAT_DATA}/build/xnat-web-${XNAT_VERSION}.war"
    if [ ! -f "${WAR_FILE}" ]; then
        log_info "Downloading XNAT ${XNAT_VERSION}..."
        wget -O ${WAR_FILE} \
            "https://api.bitbucket.org/2.0/repositories/xnatdev/xnat-web/downloads/xnat-web-${XNAT_VERSION}.war"
    fi

    # Deploy as ROOT application
    cp ${WAR_FILE} /var/lib/tomcat9/webapps/ROOT.war
    chown xnat:xnat /var/lib/tomcat9/webapps/ROOT.war

    # Create XNAT configuration
    cat > ${XNAT_HOME}/config/xnat-conf.properties <<EOF
# XNAT Configuration
datasource.driver=org.postgresql.Driver
datasource.url=jdbc:postgresql://localhost/${DB_NAME}
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

    log_info "XNAT deployment complete"
}

################################################################################
# Phase 7: Start Services
################################################################################

start_services() {
    log_info "Starting services..."

    # Start Tomcat
    systemctl start tomcat9

    log_info "Waiting for XNAT to initialize (this may take 2-3 minutes)..."

    # Wait for XNAT to be ready
    COUNTER=0
    MAX_WAIT=180
    while [ $COUNTER -lt $MAX_WAIT ]; do
        if curl -s -o /dev/null -w "%{http_code}" ${SITE_URL}/xnat/ | grep -q "302\|200"; then
            log_info "XNAT is ready!"
            break
        fi
        sleep 5
        COUNTER=$((COUNTER + 5))
        echo -n "."
    done
    echo ""

    if [ $COUNTER -ge $MAX_WAIT ]; then
        log_error "XNAT failed to start. Check logs: tail -f /var/log/tomcat9/catalina.out"
    fi
}

################################################################################
# Phase 8: Post-Deployment Fixes
################################################################################

apply_critical_fixes() {
    log_info "Applying critical production fixes..."

    # Fix 1: Ensure symlink chain is complete
    if [ ! -L "/opt/xnat/data" ]; then
        ln -sfn ${XNAT_DATA} /opt/xnat/data
        log_info "Created critical symlink"
    fi

    # Fix 2: Set database preferences to prevent HTTPS loops
    log_info "Configuring database settings..."
    PGPASSWORD=${DB_PASS} psql -h localhost -U ${DB_USER} -d ${DB_NAME} <<EOF 2>/dev/null || true
-- Update site URL to use HTTP
UPDATE xhbm_preference SET value = '${SITE_URL}' WHERE name = 'siteUrl';
UPDATE xhbm_preference SET value = 'http' WHERE name = 'securityChannel';
EOF

    # Fix 3: Create required temp directories
    mkdir -p /opt/xnat/data/temp
    mkdir -p ${XNAT_HOME}/logs
    chown -R xnat:xnat /opt/xnat/data/temp
    chown -R xnat:xnat ${XNAT_HOME}/logs

    log_info "Critical fixes applied"
}

################################################################################
# Phase 9: Verification
################################################################################

verify_installation() {
    log_info "Verifying installation..."

    ERRORS=0

    # Check services
    if ! systemctl is-active --quiet postgresql; then
        log_warn "PostgreSQL is not running"
        ERRORS=$((ERRORS + 1))
    fi

    if ! systemctl is-active --quiet tomcat9; then
        log_warn "Tomcat is not running"
        ERRORS=$((ERRORS + 1))
    fi

    # Check critical symlink
    if [ ! -L "/opt/xnat/data" ]; then
        log_warn "Critical symlink missing"
        ERRORS=$((ERRORS + 1))
    fi

    # Check XNAT response
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" ${SITE_URL}/xnat/)
    if [ "$HTTP_CODE" != "302" ] && [ "$HTTP_CODE" != "200" ]; then
        log_warn "XNAT not responding (HTTP $HTTP_CODE)"
        ERRORS=$((ERRORS + 1))
    fi

    if [ $ERRORS -eq 0 ]; then
        log_info "✓ All checks passed!"
    else
        log_warn "Installation completed with $ERRORS warning(s)"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    echo "=================================="
    echo "XNAT ${XNAT_VERSION} Deployment Script"
    echo "=================================="
    echo ""

    check_root
    check_prerequisites

    log_info "Starting XNAT deployment..."

    setup_system
    create_xnat_user
    setup_storage
    setup_database
    setup_tomcat
    deploy_xnat
    start_services
    apply_critical_fixes
    verify_installation

    echo ""
    echo "=================================="
    echo "DEPLOYMENT COMPLETE"
    echo "=================================="
    echo ""
    echo "XNAT is available at: ${SITE_URL}/xnat/"
    echo ""
    echo "Default credentials:"
    echo "  Username: admin"
    echo "  Password: admin"
    echo ""
    echo "IMPORTANT: Change the admin password immediately!"
    echo ""
    echo "To monitor logs:"
    echo "  tail -f /var/log/tomcat9/catalina.out"
    echo "  tail -f ${XNAT_HOME}/logs/xnat.log"
    echo ""
    echo "For troubleshooting, see TROUBLESHOOTING.md"
    echo ""
}

# Run main function
main "$@"
