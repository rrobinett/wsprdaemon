#!/bin/bash
set -e

echo "Installing WSPRDAEMON Reflector as systemd service..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (use sudo)" 
   exit 1
fi

# Check if running on WD00
if [[ ${HOSTNAME} != "WD00" ]]; then
    echo "WARNING: This service should only run on WD00"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Create data directories
echo "Creating data directories..."
mkdir -p /var/lib/wsprdaemon/reflector
mkdir -p /var/log/wsprdaemon
mkdir -p /var/spool/wsprdaemon/reflector

# Set ownership
chown -R wsprdaemon:wsprdaemon /var/lib/wsprdaemon
chown -R wsprdaemon:wsprdaemon /var/log/wsprdaemon
chown -R wsprdaemon:wsprdaemon /var/spool/wsprdaemon

# Install wrapper script
echo "Installing wrapper script..."
install -m 755 wsprdaemon_reflector.sh /usr/local/bin/

# Install service file
echo "Installing systemd service file..."
install -m 644 wsprdaemon_reflector@.service /etc/systemd/system/

# Create configuration files if they don't exist
if [[ ! -f /etc/wsprdaemon/reflector.conf ]]; then
    echo "Creating /etc/wsprdaemon/reflector.conf..."
    sudo mkdir -p $(dirname /etc/wsprdaemon/reflector.conf)
    sudo chown wsprdaemon:wsprdaemon $(dirname /etc/wsprdaemon/reflector.conf)
    sudo chmod g+w $(dirname /etc/wsprdaemon/reflector.conf)
    cat > /etc/wsprdaemon/reflector.conf <<'EOF'
#!/bin/bash
# WSPRDAEMON Reflector Configuration

# Paths
STATE_FILE="/var/lib/wsprdaemon/reflector/state.json"
QUEUE_BASE_DIR="/var/spool/wsprdaemon/reflector"
LOG_FILE="/var/log/wsprdaemon/wsprdaemon_reflector.log"
LOG_MAX_MB="10"

# Python environment
VENV_PYTHON="/home/wsprdaemon/wsprdaemon/venv/bin/python3"
REFLECTOR_SCRIPT="/home/wsprdaemon/wsprdaemon/wsprdaemon_reflector.py"
REFLECTOR_CONFIG="/etc/wsprdaemon/reflector_destinations.json"

# Runtime settings
VERBOSITY="1"
EOF
    chmod 644 /etc/wsprdaemon/reflector.conf
fi

if [[ ! -f /etc/wsprdaemon/reflector_destinations.json ]]; then
    echo "Creating /etc/wsprdaemon/reflector_destinations.json..."
    cat > /etc/wsprdaemon/reflector_destinations.json <<'EOF'
{
  "scan_interval": 10,
  "rsync_interval": 5,
  "cleanup_interval": 60,
  "rsync_bandwidth_limit": 20000,
  "rsync_timeout": 300,
  "max_retries": 3,
  "state_file": "/var/lib/wsprdaemon/reflector/state.json",
  "queue_base_dir": "/var/spool/wsprdaemon/reflector",
  "destinations": [
    {
      "name": "WD1",
      "user": "wsprdaemon",
      "host": "WD1",
      "path": "/var/spool/wsprdaemon/from-wd00"
    },
    {
      "name": "WD2",
      "user": "wsprdaemon",
      "host": "WD2",
      "path": "/var/spool/wsprdaemon/from-wd00"
    }
  ]
}
EOF
    chmod 644 /etc/wsprdaemon/reflector_destinations.json
    echo "WARNING: Edit /etc/wsprdaemon/reflector_destinations.json to configure your destinations!"
fi

# Setup SSH keys if not present
if [[ ! -f /home/wsprdaemon/.ssh/id_rsa ]]; then
    echo ""
    echo "WARNING: SSH keys not found for wsprdaemon user"
    echo "You need to setup passwordless SSH to destination servers:"
    echo "  1. sudo -u wsprdaemon ssh-keygen -t rsa -N '' -f /home/wsprdaemon/.ssh/id_rsa"
    echo "  2. sudo -u wsprdaemon ssh-copy-id wsprdaemon@WD1"
    echo "  3. sudo -u wsprdaemon ssh-copy-id wsprdaemon@WD2"
    echo ""
fi

# Reload systemd
echo "Reloading systemd..."
systemctl daemon-reload

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "1. Edit /etc/wsprdaemon/reflector_destinations.json and configure your destinations"
echo "2. Setup SSH keys for passwordless rsync (see above)"
echo "3. Test the reflector manually:"
echo "     sudo -u wsprdaemon /usr/local/bin/wsprdaemon_reflector.sh /etc/wsprdaemon/reflector.conf"
echo "4. Enable service: sudo systemctl enable wsprdaemon_reflector@reflector"
echo "5. Start service: sudo systemctl start wsprdaemon_reflector@reflector"
echo "6. Check status: sudo systemctl status wsprdaemon_reflector@reflector"
echo "7. View logs: sudo journalctl -u wsprdaemon_reflector@reflector -f"
