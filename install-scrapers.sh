#!/bin/bash
set -e

echo "Installing WSPRDAEMON Scrapers as systemd template services..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

# Create configuration directory
echo "Creating /etc/wsprdaemon..."
mkdir -p /etc/wsprdaemon

# Create data directories
echo "Creating data directories..."
mkdir -p /var/lib/wsprdaemon/wsprnet
mkdir -p /var/lib/wsprdaemon/wsprdaemon
mkdir -p /var/log/wsprdaemon
mkdir -p /var/spool/wsprdaemon/from-wd0
mkdir -p /var/spool/wsprdaemon/from-wd00

# Set ownership
chown -R wsprdaemon:wsprdaemon /var/lib/wsprdaemon
chown -R wsprdaemon:wsprdaemon /var/log/wsprdaemon
chown -R wsprdaemon:wsprdaemon /var/spool/wsprdaemon

# Install wrapper scripts
echo "Installing wrapper scripts..."
install -m 755 wsprnet_scraper.sh /usr/local/bin/
install -m 755 wsprdaemon_server.sh /usr/local/bin/

# Install service files
echo "Installing systemd service files..."
install -m 644 wsprnet_scraper@.service /etc/systemd/system/
install -m 644 wsprdaemon_server@.service /etc/systemd/system/

# Create sample configuration files if they don't exist
if [[ ! -f /etc/wsprdaemon/wsprnet.conf ]]; then
    echo "Creating /etc/wsprdaemon/wsprnet.conf..."
    cat > /etc/wsprdaemon/wsprnet.conf <<'EOF'
#!/bin/bash
# WSPRNET Scraper Configuration

# WSPRNET.org credentials
WSPRNET_USERNAME="CHANGEME"
WSPRNET_PASSWORD="CHANGEME"

# ClickHouse credentials
CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="8123"
CLICKHOUSE_DEFAULT_PASSWORD="CHANGEME"
CLICKHOUSE_ADMIN_USER="wsprnet-admin"
CLICKHOUSE_ADMIN_PASSWORD="CHANGEME"
CLICKHOUSE_READONLY_USER="wsprnet-reader"
CLICKHOUSE_READONLY_PASSWORD="CHANGEME"

# Paths
SESSION_FILE="/var/lib/wsprdaemon/wsprnet/session.json"
LOG_FILE="/var/log/wsprdaemon/wsprnet_scraper.log"
LOG_MAX_MB="10"

# Python environment
VENV_PYTHON="/home/wsprdaemon/wsprdaemon/venv/bin/python3"
SCRAPER_SCRIPT="/home/wsprdaemon/wsprdaemon/wsprnet_scraper.py"

# Runtime settings
LOOP_INTERVAL="120"
EOF
    chmod 640 /etc/wsprdaemon/wsprnet.conf
    chown root:wsprdaemon /etc/wsprdaemon/wsprnet.conf
    echo "WARNING: Edit /etc/wsprdaemon/wsprnet.conf and set your credentials!"
fi

if [[ ! -f /etc/wsprdaemon/wsprdaemon.conf ]]; then
    echo "Creating /etc/wsprdaemon/wsprdaemon.conf..."
    cat > /etc/wsprdaemon/wsprdaemon.conf <<'EOF'
#!/bin/bash
# WSPRDAEMON Server Configuration

# ClickHouse credentials
CLICKHOUSE_HOST="localhost"
CLICKHOUSE_PORT="8123"
CLICKHOUSE_DEFAULT_PASSWORD="CHANGEME"
CLICKHOUSE_ADMIN_USER="wsprdaemon-admin"
CLICKHOUSE_ADMIN_PASSWORD="CHANGEME"
CLICKHOUSE_READONLY_USER="wsprdaemon-reader"
CLICKHOUSE_READONLY_PASSWORD="CHANGEME"

# Paths
LOG_FILE="/var/log/wsprdaemon/wsprdaemon_server.log"
LOG_MAX_MB="10"

# Python environment
VENV_PYTHON="/home/wsprdaemon/wsprdaemon/venv/bin/python3"
SCRAPER_SCRIPT="/home/wsprdaemon/wsprdaemon/wsprdaemon_server.py"

# Runtime settings
LOOP_INTERVAL="10"
EOF
    chmod 640 /etc/wsprdaemon/wsprdaemon.conf
    chown root:wsprdaemon /etc/wsprdaemon/wsprdaemon.conf
    echo "WARNING: Edit /etc/wsprdaemon/wsprdaemon.conf and set your credentials!"
fi

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "Installation complete!"
echo ""
echo "Configuration files created in /etc/wsprdaemon/"
echo "Wrapper scripts installed in /usr/local/bin/"
echo "Service templates installed in /etc/systemd/system/"
echo ""
echo "Next steps:"
echo "1. Edit /etc/wsprdaemon/wsprnet.conf and set credentials"
echo "2. Edit /etc/wsprdaemon/wsprdaemon.conf and set credentials"
echo "3. Enable services:"
echo "     sudo systemctl enable wsprnet_scraper@wsprnet"
echo "     sudo systemctl enable wsprdaemon_server@wsprdaemon"
echo "4. Start services:"
echo "     sudo systemctl start wsprnet_scraper@wsprnet"
echo "     sudo systemctl start wsprdaemon_server@wsprdaemon"
echo "5. Check status:"
echo "     sudo systemctl status wsprnet_scraper@wsprnet"
echo "     sudo systemctl status wsprdaemon_server@wsprdaemon"
echo ""
echo "You can create additional instances with different configs:"
echo "     cp /etc/wsprdaemon/wsprnet.conf /etc/wsprdaemon/wsprnet-backup.conf"
echo "     systemctl start wsprnet_scraper@wsprnet-backup"
