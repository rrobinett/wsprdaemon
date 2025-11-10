#!/bin/bash
#
# install-servers.sh - Install WSPRDAEMON server services
# Installs both wsprnet_scraper and wsprdaemon_server services
#
# Version: 1.3
# Last updated: 2025-11-09

set -e  # Exit on error

# Check if running interactively
if [[ -t 0 ]]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

echo "Installing WSPRDAEMON Server Services..."

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Check if wsprdaemon user exists
if ! id wsprdaemon &>/dev/null; then
    echo "ERROR: User 'wsprdaemon' does not exist"
    echo "Create it with: sudo useradd -r -s /bin/bash -d /home/wsprdaemon -m wsprdaemon"
    exit 1
fi

# Install system packages
echo "Installing required system packages..."
apt update
apt install -y python3 python3-venv python3-pip

# Create tmpfiles configuration for directory setup on boot
echo "Creating tmpfiles.d configuration..."
tee /etc/tmpfiles.d/wsprdaemon.conf > /dev/null << 'EOF'
# Type Path                    Mode User       Group      Age Argument
d      /var/log/wsprdaemon     0755 wsprdaemon wsprdaemon -   -
d      /var/lib/wsprdaemon     0755 wsprdaemon wsprdaemon -   -
d      /tmp/wsprdaemon         0755 wsprdaemon wsprdaemon -   -
d      /var/spool/wsprdaemon   0755 wsprdaemon wsprdaemon -   -
d      /etc/wsprdaemon         0755 wsprdaemon wsprdaemon -   -
EOF

# Create directories now
echo "Creating directory structure..."
systemd-tmpfiles --create /etc/tmpfiles.d/wsprdaemon.conf

# Setup Python virtual environment as wsprdaemon user
echo "Setting up Python virtual environment..."
WSPRDAEMON_HOME="/home/wsprdaemon"
VENV_PATH="$WSPRDAEMON_HOME/wsprdaemon/venv"

if [ -d "$VENV_PATH" ]; then
    echo "Virtual environment already exists at $VENV_PATH"
    if [[ "$INTERACTIVE" == true ]]; then
        read -p "Remove and recreate? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo -u wsprdaemon rm -rf "$VENV_PATH"
        else
            echo "Skipping venv creation..."
        fi
    else
        echo "Non-interactive mode: keeping existing venv"
    fi
fi

if [ ! -d "$VENV_PATH" ]; then
    echo "Creating virtual environment..."
    cd "$WSPRDAEMON_HOME/wsprdaemon"
    sudo -u wsprdaemon python3 -m venv venv
    
    echo "Installing Python packages..."
    sudo -u wsprdaemon bash -c "source venv/bin/activate && pip install --upgrade pip"
    sudo -u wsprdaemon bash -c "source venv/bin/activate && pip install clickhouse-connect requests numpy pandas"
fi

# Install Python scripts
echo "Installing Python scripts..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$SCRIPT_DIR/wsprnet_scraper.py" ]; then
    echo "ERROR: wsprnet_scraper.py not found in $SCRIPT_DIR"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/wsprdaemon_server.py" ]; then
    echo "ERROR: wsprdaemon_server.py not found in $SCRIPT_DIR"
    exit 1
fi

cp "$SCRIPT_DIR/wsprnet_scraper.py" /usr/local/bin/wsprnet_scraper.py
cp "$SCRIPT_DIR/wsprdaemon_server.py" /usr/local/bin/wsprdaemon_server.py
chmod 755 /usr/local/bin/wsprnet_scraper.py
chmod 755 /usr/local/bin/wsprdaemon_server.py

# Install wrapper scripts
echo "Installing wrapper scripts..."
if [ ! -f "$SCRIPT_DIR/wsprnet_scraper.sh" ]; then
    echo "ERROR: wsprnet_scraper.sh not found in $SCRIPT_DIR"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/wsprdaemon_server.sh" ]; then
    echo "ERROR: wsprdaemon_server.sh not found in $SCRIPT_DIR"
    exit 1
fi

cp "$SCRIPT_DIR/wsprnet_scraper.sh" /usr/local/bin/wsprnet_scraper.sh
cp "$SCRIPT_DIR/wsprdaemon_server.sh" /usr/local/bin/wsprdaemon_server.sh
chmod 755 /usr/local/bin/wsprnet_scraper.sh
chmod 755 /usr/local/bin/wsprdaemon_server.sh

# Install systemd service files
echo "Installing systemd service files..."

# Install or use service files from script directory
if [ -f "$SCRIPT_DIR/wsprnet_scraper@.service" ]; then
    cp "$SCRIPT_DIR/wsprnet_scraper@.service" /etc/systemd/system/
else
    echo "Creating wsprnet_scraper@.service..."
    tee /etc/systemd/system/wsprnet_scraper@.service > /dev/null << 'EOF'
[Unit]
Description=WSPRNET Scraper Service (%i)
After=network.target clickhouse-server.service systemd-tmpfiles-setup.service
Wants=clickhouse-server.service
Requires=systemd-tmpfiles-setup.service

[Service]
Type=simple
User=wsprdaemon
Group=wsprdaemon

ExecStart=/usr/local/bin/wsprnet_scraper.sh /etc/wsprdaemon/%i.conf

Restart=on-failure
RestartSec=60

# Memory limits
MemoryMax=1G
MemoryHigh=768M

# Security hardening
NoNewPrivileges=true
PrivateTmp=false
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/wsprdaemon /tmp/wsprdaemon

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wsprnet-scraper-%i

[Install]
WantedBy=multi-user.target
EOF
fi

if [ -f "$SCRIPT_DIR/wsprdaemon_server@.service" ]; then
    cp "$SCRIPT_DIR/wsprdaemon_server@.service" /etc/systemd/system/
else
    echo "Creating wsprdaemon_server@.service..."
    tee /etc/systemd/system/wsprdaemon_server@.service > /dev/null << 'EOF'
[Unit]
Description=WSPRDAEMON Server (%i)
After=network.target clickhouse-server.service systemd-tmpfiles-setup.service
Wants=clickhouse-server.service
Requires=systemd-tmpfiles-setup.service

[Service]
Type=simple
User=wsprdaemon
Group=wsprdaemon

ExecStart=/usr/local/bin/wsprdaemon_server.sh /etc/wsprdaemon/%i.conf

Restart=on-failure
RestartSec=60

# Memory limits
MemoryMax=2G
MemoryHigh=1.5G

# Security hardening
NoNewPrivileges=true
PrivateTmp=false
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/wsprdaemon /var/lib/wsprdaemon /tmp/wsprdaemon /var/spool/wsprdaemon

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wsprdaemon-server-%i

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload

# Create default configuration files if they don't exist
if [ ! -f /etc/wsprdaemon/wsprnet.conf ]; then
    echo "Creating /etc/wsprdaemon/wsprnet.conf..."
    cat > /etc/wsprdaemon/wsprnet.conf << 'EOF'
# WSPRNET Scraper Configuration
WSPRNET_SESSION_FILE="/tmp/wsprdaemon/wsprnet_session"
WSPRNET_LOG_FILE="/var/log/wsprdaemon/wsprnet_scraper.log"
WSPRNET_VENV_PYTHON="/home/wsprdaemon/wsprdaemon/venv/bin/python3"
WSPRNET_SCRAPER_SCRIPT="/usr/local/bin/wsprnet_scraper.py"
WSPRNET_LOOP_INTERVAL=20
EOF
    chown wsprdaemon:wsprdaemon /etc/wsprdaemon/wsprnet.conf
    chmod 640 /etc/wsprdaemon/wsprnet.conf
fi

if [ ! -f /etc/wsprdaemon/wsprdaemon.conf ]; then
    echo "Creating /etc/wsprdaemon/wsprdaemon.conf..."
    cat > /etc/wsprdaemon/wsprdaemon.conf << 'EOF'
# WSPRDAEMON Server Configuration
WSPRDAEMON_UPLOAD_DIR="/var/lib/wsprdaemon/uploads"
WSPRDAEMON_LOG_FILE="/var/log/wsprdaemon/wsprdaemon_server.log"
WSPRDAEMON_VENV_PYTHON="/home/wsprdaemon/wsprdaemon/venv/bin/python3"
WSPRDAEMON_SERVER_SCRIPT="/usr/local/bin/wsprdaemon_server.py"
WSPRDAEMON_LOOP_INTERVAL=60
EOF
    chown wsprdaemon:wsprdaemon /etc/wsprdaemon/wsprdaemon.conf
    chmod 640 /etc/wsprdaemon/wsprdaemon.conf
fi

# Check for ClickHouse config
if [ ! -f /etc/wsprdaemon/clickhouse.conf ]; then
    echo ""
    echo "WARNING: /etc/wsprdaemon/clickhouse.conf does not exist"
    echo "Create it with your ClickHouse credentials:"
    echo ""
    echo "cat > /etc/wsprdaemon/clickhouse.conf << 'EOF'"
    echo "CLICKHOUSE_HOST=\"localhost\""
    echo "CLICKHOUSE_PORT=\"9000\""
    echo "CLICKHOUSE_USER=\"chadmin\""
    echo "CLICKHOUSE_PASSWORD=\"\""
    echo "CLICKHOUSE_DATABASE=\"wsprnet\""
    echo "EOF"
    echo ""
    echo "Then set permissions:"
    echo "sudo chown wsprdaemon:wsprdaemon /etc/wsprdaemon/clickhouse.conf"
    echo "sudo chmod 600 /etc/wsprdaemon/clickhouse.conf"
    echo ""
fi

# Function to check ClickHouse network configuration
check_clickhouse_network_config() {
    local config_file="/etc/clickhouse-server/config.d/network.xml"
    
    echo ""
    echo ">>> Checking ClickHouse network configuration..."
    
    # Check if ClickHouse is installed
    if ! command -v clickhouse-server &> /dev/null; then
        echo "⚠️  ClickHouse not installed - skipping network check"
        return 0
    fi
    
    if [[ ! -f "$config_file" ]]; then
        echo "✅ No custom network config - using ClickHouse defaults"
        return 0
    fi
    
    # Extract listen_host entries
    local listen_hosts
    listen_hosts=$(grep -oP '(?<=<listen_host>)[^<]+' "$config_file" 2>/dev/null || true)
    
    if [[ -z "$listen_hosts" ]]; then
        echo "✅ No listen_host entries in network config"
        return 0
    fi
    
    # Check if any specific IPs are configured (not 0.0.0.0 or ::)
    local has_specific_ips=false
    local missing_ips=()
    
    while IFS= read -r ip; do
        # Skip empty lines
        [[ -z "$ip" ]] && continue
        
        # Skip wildcard addresses
        if [[ "$ip" == "0.0.0.0" || "$ip" == "::" || "$ip" == "127.0.0.1" || "$ip" == "::1" ]]; then
            continue
        fi
        
        has_specific_ips=true
        
        # Check if IP exists on system
        if ! ip addr show | grep -q "$ip"; then
            missing_ips+=("$ip")
        fi
    done <<< "$listen_hosts"
    
    if [[ ${#missing_ips[@]} -gt 0 ]]; then
        echo ""
        echo "⚠️  WARNING: ClickHouse configured to bind to IPs not currently available:"
        printf '    %s\n' "${missing_ips[@]}"
        echo ""
        echo "This will cause ClickHouse to fail at boot if these interfaces (VPN/WireGuard)"
        echo "are not available yet. ClickHouse services will enter a restart loop until"
        echo "the interfaces become available."
        echo ""
        echo "Recommendation: Use 0.0.0.0 to bind to all interfaces, which will work"
        echo "regardless of which interfaces are up at boot time."
        echo ""
        echo "Suggested fix:"
        echo ""
        echo "sudo tee $config_file << 'EOF'"
        echo "<clickhouse>"
        echo "    <listen_host>0.0.0.0</listen_host>"
        echo "</clickhouse>"
        echo "EOF"
        echo ""
        
        if [[ "$INTERACTIVE" == true ]]; then
            read -p "Apply this fix now? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
                echo "Backed up to ${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
                tee "$config_file" > /dev/null << 'EOF'
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
</clickhouse>
EOF
                echo "✅ Network config updated to use 0.0.0.0"
                echo "   ClickHouse will now bind to all interfaces"
                
                # Restart ClickHouse if it's running
                if systemctl is-active --quiet clickhouse-server; then
                    echo "   Restarting ClickHouse..."
                    systemctl restart clickhouse-server
                    sleep 2
                    if systemctl is-active --quiet clickhouse-server; then
                        echo "   ✅ ClickHouse restarted successfully"
                    else
                        echo "   ⚠️  ClickHouse failed to restart - check logs"
                    fi
                fi
            else
                echo "Skipping fix - you can apply it manually later if needed"
            fi
        else
            echo "Non-interactive mode: skipping ClickHouse network fix"
            echo "Apply the fix manually if needed"
        fi
    elif [[ "$has_specific_ips" == true ]]; then
        echo "✅ All configured specific IPs are currently available on the system"
        echo "   However, if these are VPN/WireGuard IPs, consider using 0.0.0.0"
        echo "   to avoid boot-time failures when interfaces aren't ready yet"
    else
        echo "✅ Using wildcard addresses (0.0.0.0 or ::) - good for boot reliability"
    fi
}

# Function to restart services if needed
restart_services_if_needed() {
    local services_changed=false
    local services_to_restart=()
    
    echo ""
    echo ">>> Checking if services need restart..."
    
    # Check if services are running
    if systemctl is-active --quiet wsprnet_scraper@wsprnet.service; then
        services_to_restart+=("wsprnet_scraper@wsprnet.service")
        services_changed=true
    fi
    
    if systemctl is-active --quiet wsprdaemon_server@wsprdaemon.service; then
        services_to_restart+=("wsprdaemon_server@wsprdaemon.service")
        services_changed=true
    fi
    
    if [[ "$services_changed" == false ]]; then
        echo "No services currently running"
        return 0
    fi
    
    echo "Found running services:"
    printf '  - %s\n' "${services_to_restart[@]}"
    echo ""
    echo "Scripts and/or service files have been updated."
    
    if [[ "$INTERACTIVE" == true ]]; then
        read -p "Restart services to apply changes? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for service in "${services_to_restart[@]}"; do
                echo "Restarting $service..."
                systemctl restart "$service"
                sleep 1
                if systemctl is-active --quiet "$service"; then
                    echo "  ✅ $service restarted successfully"
                else
                    echo "  ⚠️  $service failed to restart - check logs"
                fi
            done
        else
            echo "⚠️  Services NOT restarted - changes will take effect on next restart"
        fi
    else
        echo "Non-interactive mode: NOT restarting services automatically"
        echo "⚠️  Manual restart required:"
        for service in "${services_to_restart[@]}"; do
            echo "   sudo systemctl restart $service"
        done
    fi
}

# Run the ClickHouse network check
check_clickhouse_network_config

# Check and restart services if needed
restart_services_if_needed

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Create /etc/wsprdaemon/clickhouse.conf with your ClickHouse credentials (if not done)"
echo "2. Enable and start the services (if not already running):"
echo "   sudo systemctl enable wsprnet_scraper@wsprnet.service"
echo "   sudo systemctl enable wsprdaemon_server@wsprdaemon.service"
echo "   sudo systemctl start wsprnet_scraper@wsprnet.service"
echo "   sudo systemctl start wsprdaemon_server@wsprdaemon.service"
echo ""
echo "3. Check service status:"
echo "   sudo systemctl status wsprnet_scraper@wsprnet.service"
echo "   sudo systemctl status wsprdaemon_server@wsprdaemon.service"
echo ""
echo "4. View logs:"
echo "   sudo journalctl -u wsprnet_scraper@wsprnet.service -f"
echo "   sudo journalctl -u wsprdaemon_server@wsprdaemon.service -f"
echo ""
