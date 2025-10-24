#!/bin/bash
# WSPRNET Scraper Installation Script
# Installs wsprnet_scraper service and dependencies

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo_error "This script must be run as root (use sudo)"
   exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo_info "Installation directory: $SCRIPT_DIR"

# Configuration
INSTALL_USER="wsprdaemon"
INSTALL_GROUP="wsprdaemon"
VENV_DIR="/home/$INSTALL_USER/wsprdaemon/venv"
CONFIG_DIR="/etc/wsprdaemon"
LOG_DIR="/var/log/wsprdaemon"
LIB_DIR="/var/lib/wsprdaemon"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

echo_info "============================================"
echo_info "WSPRNET Scraper Installation"
echo_info "============================================"

# Step 1: Check if user exists
echo_info "Step 1: Checking user $INSTALL_USER..."
if id "$INSTALL_USER" &>/dev/null; then
    echo_info "User $INSTALL_USER already exists"
else
    echo_info "Creating user $INSTALL_USER..."
    useradd -r -m -d /home/$INSTALL_USER -s /bin/bash $INSTALL_USER
    echo_info "User $INSTALL_USER created"
fi

# Step 2: Install system dependencies
echo_info "Step 2: Installing system dependencies..."
apt-get update
apt-get install -y python3 python3-pip python3-venv

# Step 3: Create Python virtual environment
echo_info "Step 3: Setting up Python virtual environment..."
if [[ ! -d "$VENV_DIR" ]]; then
    echo_info "Creating virtual environment at $VENV_DIR..."
    sudo -u $INSTALL_USER python3 -m venv $VENV_DIR
    echo_info "Virtual environment created"
else
    echo_info "Virtual environment already exists"
fi

# Step 4: Install Python dependencies
echo_info "Step 4: Installing Python dependencies..."
sudo -u $INSTALL_USER $VENV_DIR/bin/pip install --upgrade pip
sudo -u $INSTALL_USER $VENV_DIR/bin/pip install \
    requests \
    clickhouse-connect \
    numpy

echo_info "Python dependencies installed"

# Step 5: Create directories
echo_info "Step 5: Creating directories..."
mkdir -p $CONFIG_DIR
mkdir -p $LOG_DIR
mkdir -p $LIB_DIR

chown -R $INSTALL_USER:$INSTALL_GROUP $LOG_DIR
chown -R $INSTALL_USER:$INSTALL_GROUP $LIB_DIR

echo_info "Directories created"

# Step 6: Install scripts
echo_info "Step 6: Installing scripts..."

if [[ -f "$SCRIPT_DIR/wsprnet_scraper.py" ]]; then
    cp "$SCRIPT_DIR/wsprnet_scraper.py" "$BIN_DIR/wsprnet_scraper.py"
    chmod 755 "$BIN_DIR/wsprnet_scraper.py"
    echo_info "Installed wsprnet_scraper.py"
else
    echo_error "wsprnet_scraper.py not found in $SCRIPT_DIR"
    exit 1
fi

if [[ -f "$SCRIPT_DIR/wsprnet_scraper.sh" ]]; then
    cp "$SCRIPT_DIR/wsprnet_scraper.sh" "$BIN_DIR/wsprnet_scraper.sh"
    chmod 755 "$BIN_DIR/wsprnet_scraper.sh"
    echo_info "Installed wsprnet_scraper.sh"
else
    echo_error "wsprnet_scraper.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Step 7: Install systemd service
echo_info "Step 7: Installing systemd service..."

if [[ -f "$SCRIPT_DIR/wsprnet_scraper@.service" ]]; then
    cp "$SCRIPT_DIR/wsprnet_scraper@.service" "$SYSTEMD_DIR/wsprnet_scraper@.service"
    chmod 644 "$SYSTEMD_DIR/wsprnet_scraper@.service"
    systemctl daemon-reload
    echo_info "Installed systemd service"
else
    echo_error "wsprnet_scraper@.service not found in $SCRIPT_DIR"
    exit 1
fi

# Step 8: Install config files (only if they don't exist)
echo_info "Step 8: Installing configuration files..."

if [[ ! -f "$CONFIG_DIR/wsprnet.conf" ]]; then
    if [[ -f "$SCRIPT_DIR/wsprnet.conf.example" ]]; then
        cp "$SCRIPT_DIR/wsprnet.conf.example" "$CONFIG_DIR/wsprnet.conf"
        chmod 644 "$CONFIG_DIR/wsprnet.conf"
        echo_info "Installed wsprnet.conf (edit this file to configure)"
    else
        echo_warn "wsprnet.conf.example not found, skipping"
    fi
else
    echo_info "wsprnet.conf already exists, not overwriting"
fi

if [[ ! -f "$CONFIG_DIR/clickhouse.conf" ]]; then
    if [[ -f "$SCRIPT_DIR/clickhouse.conf.example" ]]; then
        cp "$SCRIPT_DIR/clickhouse.conf.example" "$CONFIG_DIR/clickhouse.conf"
        chmod 600 "$CONFIG_DIR/clickhouse.conf"
        chown root:root "$CONFIG_DIR/clickhouse.conf"
        echo_info "Installed clickhouse.conf (edit this file to configure)"
    else
        echo_warn "clickhouse.conf.example not found, skipping"
    fi
else
    echo_info "clickhouse.conf already exists, not overwriting"
fi

# Step 9: Summary
echo_info "============================================"
echo_info "Installation Complete!"
echo_info "============================================"
echo_info ""
echo_info "Next steps:"
echo_info "1. Edit configuration files:"
echo_info "   - $CONFIG_DIR/clickhouse.conf"
echo_info "   - $CONFIG_DIR/wsprnet.conf"
echo_info ""
echo_info "2. If you need WSPRNET credentials, add them to wsprnet.conf:"
echo_info "   WSPRNET_USERNAME=\"your_username\""
echo_info "   WSPRNET_PASSWORD=\"your_password\""
echo_info ""
echo_info "3. Enable and start the service:"
echo_info "   sudo systemctl enable wsprnet_scraper@wsprnet.service"
echo_info "   sudo systemctl start wsprnet_scraper@wsprnet.service"
echo_info ""
echo_info "4. Check service status:"
echo_info "   sudo systemctl status wsprnet_scraper@wsprnet.service"
echo_info "   sudo journalctl -u wsprnet_scraper@wsprnet.service -f"
echo_info ""
echo_info "5. View logs:"
echo_info "   tail -f $LOG_DIR/wsprnet_scraper.log"
echo_info ""
