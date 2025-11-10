#!/bin/bash
# WSPRNET Scraper v2.2.4 Installation Script
# Complete setup with cache directory, backup, and verification

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCRAPER_FILE="${SCRIPT_DIR}/wsprnet_scraper.py"
INSTALL_PATH="/usr/local/bin/wsprnet_scraper.py"
CACHE_DIR="/var/lib/wsprnet/cache"
SERVICE_NAME="wsprnet_scraper@wsprnet.service"
LOG_FILE="/var/log/wsprdaemon/wsprnet_scraper.log"

echo "======================================================================="
echo "WSPRNET Scraper v2.2.4 Installation"
echo "======================================================================="
echo ""
echo "Features:"
echo "  ✓ Always-cache architecture (download → cache → insert)"
echo "  ✓ Separate threads (download + insert)"
echo "  ✓ Thread-safe ClickHouse connections"
echo "  ✓ Gap detection (between & within downloads)"
echo "  ✓ Automatic sorting of descending order data"
echo "  ✓ Survives ClickHouse restarts and Linux reboots"
echo ""

# Check if running as root or with sudo
if [[ $EUID -eq 0 ]]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Step 1: Verify scraper file exists
echo "Step 1: Verifying wsprnet_scraper.py exists..."
if [[ ! -f "${SCRAPER_FILE}" ]]; then
    echo "ERROR: wsprnet_scraper.py not found at ${SCRAPER_FILE}"
    echo "Please ensure wsprnet_scraper.py is in the same directory as this script"
    exit 1
fi

# Check version
VERSION=$(grep "^VERSION = " "${SCRAPER_FILE}" | head -1 | cut -d'"' -f2)
echo "✓ Found wsprnet_scraper.py version ${VERSION}"
echo ""

# Step 2: Stop service
echo "Step 2: Stopping service..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    $SUDO systemctl stop "${SERVICE_NAME}"
    echo "✓ Service stopped"
else
    echo "! Service was not running"
fi
echo ""

# Step 3: Backup existing version
echo "Step 3: Backing up existing version..."
if [[ -f "${INSTALL_PATH}" ]]; then
    BACKUP_PATH="${INSTALL_PATH}.backup_$(date +%Y%m%d_%H%M%S)"
    $SUDO cp "${INSTALL_PATH}" "${BACKUP_PATH}"
    
    OLD_VERSION=$($SUDO grep "^VERSION = " "${INSTALL_PATH}" | head -1 | cut -d'"' -f2 || echo "unknown")
    echo "✓ Backed up version ${OLD_VERSION} to ${BACKUP_PATH}"
else
    echo "! No existing version to backup (fresh install)"
fi
echo ""

# Step 4: Create cache directory
echo "Step 4: Setting up cache directory..."
if [[ ! -d "${CACHE_DIR}" ]]; then
    $SUDO mkdir -p "${CACHE_DIR}"
    echo "✓ Created ${CACHE_DIR}"
fi

# Set ownership to wsprdaemon user
if id "wsprdaemon" &>/dev/null; then
    $SUDO chown wsprdaemon:wsprdaemon "${CACHE_DIR}"
    echo "✓ Set ownership to wsprdaemon:wsprdaemon"
else
    echo "! Warning: wsprdaemon user not found, cache directory owned by root"
fi

$SUDO chmod 755 "${CACHE_DIR}"
echo "✓ Set permissions to 755"
echo ""

# Step 5: Install new version
echo "Step 5: Installing v${VERSION}..."
$SUDO cp "${SCRAPER_FILE}" "${INSTALL_PATH}"
$SUDO chmod 755 "${INSTALL_PATH}"
echo "✓ Installed to ${INSTALL_PATH}"
echo ""

# Step 6: Verify Python syntax
echo "Step 6: Verifying Python syntax..."
if python3 -m py_compile "${INSTALL_PATH}"; then
    echo "✓ Syntax check passed"
else
    echo "✗ Syntax error in Python file!"
    echo "Installation failed - restoring backup"
    if [[ -f "${BACKUP_PATH}" ]]; then
        $SUDO cp "${BACKUP_PATH}" "${INSTALL_PATH}"
    fi
    exit 1
fi
echo ""

# Step 7: Start service
echo "Step 7: Starting service..."
$SUDO systemctl start "${SERVICE_NAME}"
sleep 3
echo ""

# Step 8: Check service status
echo "Step 8: Checking service status..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
    echo "✓ Service is running"
    $SUDO systemctl status "${SERVICE_NAME}" --no-pager -l | head -15
else
    echo "✗ Service failed to start!"
    echo ""
    echo "Checking logs for errors:"
    $SUDO journalctl -u "${SERVICE_NAME}" -n 30 --no-pager
    exit 1
fi
echo ""

# Step 9: Verify version in logs
echo "Step 9: Verifying version in logs..."
sleep 2
if $SUDO grep -q "version ${VERSION}" "${LOG_FILE}" 2>/dev/null; then
    echo "✓ Version ${VERSION} confirmed in logs"
    $SUDO grep "version ${VERSION}" "${LOG_FILE}" | tail -1
else
    echo "! Could not verify version in logs yet (may take a few seconds)"
fi
echo ""

# Step 10: Show recent logs
echo "Step 10: Recent log entries..."
if [[ -f "${LOG_FILE}" ]]; then
    $SUDO tail -20 "${LOG_FILE}"
else
    echo "! Log file not found at ${LOG_FILE}"
fi
echo ""

echo "======================================================================="
echo "Installation Complete!"
echo "======================================================================="
echo ""
echo "Installed: wsprnet_scraper.py v${VERSION}"
echo "Location: ${INSTALL_PATH}"
echo "Cache: ${CACHE_DIR}"
echo "Service: ${SERVICE_NAME}"
echo ""
echo "Monitoring Commands:"
echo "  Watch logs:      sudo tail -f ${LOG_FILE}"
echo "  Watch gaps:      sudo tail -f ${LOG_FILE} | grep -i gap"
echo "  Service status:  sudo systemctl status ${SERVICE_NAME}"
echo "  Cache files:     ls -lh ${CACHE_DIR}"
echo ""
echo "Expected behavior:"
echo "  - Downloads cache to ${CACHE_DIR}"
echo "  - Insert thread processes cached files"
echo "  - Gap detection reports missing spots"
echo "  - No false 'gap of 1' warnings"
echo "  - Survives ClickHouse restarts"
echo ""

# Check for any immediate errors
echo "Checking for startup errors..."
sleep 3
if $SUDO grep -i "error\|traceback" "${LOG_FILE}" 2>/dev/null | tail -5 | grep -q .; then
    echo ""
    echo "⚠ Warning: Errors detected in recent logs:"
    $SUDO grep -i "error\|traceback" "${LOG_FILE}" | tail -5
    echo ""
    echo "Monitor logs with: sudo tail -f ${LOG_FILE}"
else
    echo "✓ No errors detected in recent logs"
fi
echo ""

# Show cache status
echo "Cache status:"
CACHE_COUNT=$(ls -1 "${CACHE_DIR}"/spots_*.json 2>/dev/null | wc -l)
echo "  Files in cache: ${CACHE_COUNT}"
if [[ ${CACHE_COUNT} -eq 0 ]]; then
    echo "  Status: Healthy (cache empty, insert keeping up)"
elif [[ ${CACHE_COUNT} -lt 5 ]]; then
    echo "  Status: Normal (small backlog)"
else
    echo "  Status: Backlog (${CACHE_COUNT} files pending)"
    echo "  This is normal after ClickHouse restart or during initial catch-up"
fi
echo ""

echo "Installation script completed successfully!"
