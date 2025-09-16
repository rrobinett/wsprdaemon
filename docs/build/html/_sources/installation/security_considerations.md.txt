# Security Considerations

*Security best practices and considerations for WsprDaemon installations*

This guide covers security aspects that system administrators and operators should understand when deploying and maintaining WsprDaemon installations.

## User Protection Philosophy

WsprDaemon is designed with a **user-first security model** that prioritizes protecting amateur radio operators over developer convenience. The system absorbs technical complexity to minimize security configuration burden on end users.

### Core Security Principles
- **No Direct Internet Exposure**: Client devices never accept inbound connections
- **Zero Configuration Security**: Users don't manage firewalls, VPNs, or certificates
- **Liability Protection**: Amateur radio operators protected from internet-based attacks
- **Defense in Depth**: Multiple security layers provide comprehensive protection

## Remote Access Security

### Remote Access Channel (RAC) System
WsprDaemon includes an optional secure remote access system for developer support and maintenance.

**Security Model:**
- **Reverse Tunnels**: Client devices initiate outbound connections only
- **Central Proxy**: All access goes through secured proxy server (wd0.wsprdaemon.org)
- **VPN Required**: WireGuard VPN required for any proxy access
- **Firewall Protected**: Digital Ocean firewall blocks unauthorized traffic

**User Control:**
```bash
# RAC is completely optional - users must explicitly enable
REMOTE_ACCESS_CHANNEL=123        # Unique channel number
REMOTE_ACCESS_ID="MyStation-Pi4" # Descriptive identifier
```

### Access Control Layers
1. **Digital Ocean Firewall**: Perimeter defense
2. **WireGuard VPN**: Encrypted access control (port 51820)
3. **SSH Key Authentication**: Developer access verification
4. **Application Permissions**: Service-level isolation
5. **Audit Logging**: All connections tracked

## Data Protection

### Sensitive Information Handling
WsprDaemon configurations may contain sensitive data that requires protection:

**Configuration Secrets:**
- KiwiSDR passwords
- wsprnet.org credentials  
- GPS coordinates and station information
- Network configuration details

**Protection Mechanisms:**
```bash
# Environment variable substitution for secrets
KIWI_PASSWORD="${KIWI_PASSWORD:-$(cat /etc/wsprdaemon/kiwi_password)}"

# Secure file permissions
chmod 600 /etc/wsprdaemon/secrets
chown wsprdaemon:wsprdaemon /etc/wsprdaemon/secrets

# Configuration file protection
chmod 640 wsprdaemon.conf
chown wsprdaemon:wsprdaemon wsprdaemon.conf
```

### Data Integrity Protection
- **Automatic Backups**: Configurations backed up before changes
- **Validation**: Receiver definitions and schedules validated before use
- **Graceful Handling**: Malformed configurations handled without system compromise
- **Recovery**: Corrupted state files automatically recovered

## System Hardening

### Service Isolation
```bash
# WsprDaemon runs as dedicated user 'wsprdaemon'
# Separate from root/pi user for security
# Limited privileges for system operations

# Check service user
id wsprdaemon
groups wsprdaemon
```

### SSH Security
```bash
# SSH hardening recommendations
# /etc/ssh/sshd_config
PasswordAuthentication no
PermitRootLogin no
AllowUsers wsprdaemon
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Restart SSH after changes
sudo systemctl restart ssh
```

### Firewall Configuration
```bash
# Basic UFW setup for WsprDaemon
sudo ufw allow ssh
sudo ufw allow from 192.168.0.0/16 to any port 8081  # KA9Q-web (local network only)
sudo ufw allow from 192.168.0.0/16 to any port 8073  # KiwiSDR web (local network only)
sudo ufw enable

# Check firewall status
sudo ufw status verbose
```

### Automatic Security Updates
```bash
# Enable unattended upgrades for security patches
sudo apt install unattended-upgrades
sudo dpkg-reconfigure unattended-upgrades

# Configure automatic security updates
# /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
```

## Network Security

### Attack Surface Reduction
**Current Risks:**
- SSH access enabled by default on Pi systems
- Weak default passwords on Pi installations
- Unpatched systems
- Unnecessary services running

**Mitigations:**
```bash
# Disable unnecessary services
sudo systemctl disable bluetooth
sudo systemctl disable wifi-powersave
sudo systemctl disable avahi-daemon  # If not needed

# Check running services
systemctl list-units --type=service --state=running
```

### Network Segmentation
```bash
# Isolate SDR devices on separate network segment if possible
# Example: 192.168.100.0/24 for SDR devices
# Example: 192.168.1.0/24 for management

# Route only necessary traffic between segments
# Block direct internet access from SDR segment
```

## Monitoring and Alerting

### Security Event Monitoring
```bash
# Monitor authentication attempts
sudo journalctl -u ssh -f | grep -E "(Failed|Accepted)"

# Check for unusual network connections
sudo netstat -tulpn | grep -E ":22|:8073|:8081"

# Monitor system resource usage
./wsprdaemon.sh -s | grep -E "(ERROR|WARNING|CRITICAL)"
```

### Automated Health Checks
```bash
# System health monitoring script
#!/bin/bash
# /usr/local/bin/wd-security-check.sh

# Check SSH configuration
if grep -q "PasswordAuthentication yes" /etc/ssh/sshd_config; then
    echo "WARNING: Password authentication enabled"
fi

# Check firewall status
if ! sudo ufw status | grep -q "Status: active"; then
    echo "WARNING: Firewall not active"
fi

# Check for failed login attempts
FAILED_LOGINS=$(sudo journalctl -u ssh --since "1 hour ago" | grep -c "Failed password")
if [ "$FAILED_LOGINS" -gt 10 ]; then
    echo "WARNING: $FAILED_LOGINS failed login attempts in last hour"
fi

# Check WsprDaemon service status
if ! ./wsprdaemon.sh -s | grep -q "RUNNING"; then
    echo "WARNING: WsprDaemon service issues detected"
fi
```

## Backup and Recovery

### Configuration Backup
```bash
# Automatic backup before changes
backup_config() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    cp wsprdaemon.conf "wsprdaemon.conf.backup.$timestamp"
    echo "Configuration backed up to wsprdaemon.conf.backup.$timestamp"
}

# System state backup
create_system_backup() {
    local backup_file="/tmp/wd-backup-$(date +%Y%m%d).tar.gz"
    tar -czf "$backup_file" \
        wsprdaemon.conf \
        /var/log/wsprdaemon/ \
        ~/.ssh/authorized_keys \
        /etc/systemd/system/wsprdaemon.service
    echo "System backup created: $backup_file"
}
```

### Recovery Procedures
```bash
# Restore from backup
restore_config() {
    local backup_file="$1"
    if [ -f "$backup_file" ]; then
        cp "$backup_file" wsprdaemon.conf
        echo "Configuration restored from $backup_file"
        ./wsprdaemon.sh -s  # Validate restored configuration
    fi
}

# Emergency recovery
emergency_reset() {
    echo "Performing emergency reset..."
    ./wsprdaemon.sh -z  # Stop all services
    cp wd_template.conf wsprdaemon.conf  # Reset to template
    echo "System reset to default configuration"
}
```

## Developer Access Security

### RAC System Security Controls
- **Explicit Activation**: RAC must be explicitly enabled by user
- **Unique Channels**: Each installation gets unique RAC number
- **Centralized Logging**: All access attempts logged on proxy server
- **Time Limits**: Developer sessions can be time-limited
- **User Notification**: Users can monitor access in logs

### Developer Responsibilities
- **Minimal Changes**: Make only necessary modifications during support
- **Documentation**: Document any configuration changes made
- **Read-Only Operations**: Use read-only commands when possible
- **Privacy Respect**: Respect user privacy and data confidentiality

### Audit Trail
```bash
# RAC connection logging
tail -f /var/log/wsprdaemon/rac-access.log

# Configuration change tracking
git log --oneline wsprdaemon.conf

# Service modification logging  
journalctl -u wsprdaemon -f
```

## Implementation Priorities

### Phase 1: Immediate Security (High Priority)
1. **SSH Hardening**: Disable password authentication, restrict users
2. **Firewall Setup**: Enable UFW with minimal required ports
3. **Automatic Updates**: Enable unattended security updates
4. **Configuration Protection**: Secure file permissions

### Phase 2: Enhanced Monitoring (Medium Priority)
1. **Security Monitoring**: Automated security event detection
2. **Health Checks**: Regular system security validation
3. **Backup Automation**: Automated configuration and system backups
4. **Alert System**: Notification system for security events

### Phase 3: Advanced Security (Long-term)
1. **Network Segmentation**: Isolate SDR devices from internet
2. **Certificate Management**: TLS for all web interfaces
3. **Intrusion Detection**: Automated attack detection and response
4. **Compliance Logging**: Extended audit logging and retention

## Security Best Practices Summary

### For System Administrators
- Enable automatic security updates
- Use SSH keys instead of passwords
- Configure firewall with minimal required ports
- Monitor logs for security events
- Keep regular configuration backups

### For End Users
- Use strong, unique passwords for all accounts
- Enable RAC only when needed for support
- Keep systems updated and patched
- Report suspicious activity to administrators
- Follow configuration templates and guidelines

### For Developers
- Use RAC system for remote access only when necessary
- Document all changes made during support sessions
- Respect user privacy and system security
- Follow principle of least privilege
- Maintain audit trail of all activities

This security model ensures that WsprDaemon installations remain secure while providing the flexibility needed for amateur radio operations and development support.
