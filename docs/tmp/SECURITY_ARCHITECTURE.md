# WsprDaemon Security Architecture

*Security design and threat model for WsprDaemon remote access system*

**Date**: September 2025  
**Purpose**: Security documentation for system administrators and developers  
**Scope**: Remote access security, user protection, and threat mitigation

## User Profile and Security Requirements

**Target Users**: Amateur radio operators with varying technical backgrounds who:
- May have limited Linux command line experience
- Prefer simplified configuration management
- Benefit from automated system protection and maintenance
- Require reliable data propagation to servers

**Developer Requirements**: 
- Remote access for debugging and maintenance
- Advanced development tools (VS Code, debuggers)
- Secure access to user systems for support

## Current Security Model

### Remote Access Channel (RAC) System
**Purpose**: Controlled developer access to user systems through central proxy

**Architecture**:
- Central proxy server: `vpn.wsprdaemon.org:35735`
- Unique RAC channels (0-1000+) per installation
- SSH tunneling via `frpc` (Fast Reverse Proxy Client)
- Port mapping: RAC channel → SSH port (35800+)

**Security Controls**:
- Optional RAC activation (must be explicitly enabled)
- Unique channel assignment prevents conflicts
- Centralized access logging and monitoring
- Requires user consent and configuration

### User Protection Mechanisms

#### Configuration Safety
```bash
# Template-based configuration prevents user editing
cp wd_template.conf wsprdaemon.conf
# Validation before activation
./wsprdaemon.sh -s  # Status check before start
```

#### Data Integrity Protection
- Automatic backup of configurations before changes
- Validation of receiver definitions and schedules
- Graceful handling of malformed configurations
- Recovery from corrupted state files

#### Service Isolation
```bash
# WsprDaemon runs as dedicated user 'wsprdaemon'
# Separate from root/pi user for security
# Limited privileges for system operations
```

## Recommended Security Enhancements

### 1. Configuration Management
**Problem**: Users cannot safely edit configuration files
**Solution**: Web-based configuration interface

```bash
# Secure configuration validator
./scripts/validate-config.sh wsprdaemon.conf
# Web UI for configuration (future enhancement)
# Read-only filesystem for critical system files
```

### 2. Automatic Updates and Monitoring
**Problem**: Users cannot maintain systems
**Solution**: Automated maintenance with safety checks

```bash
# Automatic updates with rollback capability
# Health monitoring with automatic recovery
# Remote diagnostics without user intervention
```

### 3. Attack Surface Reduction
**Current Risks**:
- SSH access enabled by default on Pi systems
- Weak default passwords on Pi installations
- Unpatched systems

**Mitigations**:
```bash
# SSH hardening
PasswordAuthentication no
PermitRootLogin no
AllowUsers wsprdaemon

# Automatic security updates
unattended-upgrades configuration

# Network segmentation for SDR devices
```

### 4. Data Protection
**Sensitive Information**:
- KiwiSDR passwords in configuration files
- wsprnet.org credentials
- GPS coordinates and station information

**Protection Mechanisms**:
```bash
# Environment variable substitution for secrets
KIWI_PASSWORD="${KIWI_PASSWORD:-$(cat /etc/wsprdaemon/kiwi_password)}"

# File permissions for sensitive data
chmod 600 /etc/wsprdaemon/secrets
chown wsprdaemon:wsprdaemon /etc/wsprdaemon/secrets
```

## Developer Access Security

### RAC Authentication Flow
1. User enables RAC with unique channel number
2. Developer connects via central proxy: `ssh -p <RAC_PORT> wsprdaemon@vpn.wsprdaemon.org`
3. Connection logged on both proxy and user system
4. Time-limited access sessions (configurable)

### Developer Responsibilities
- Minimal system changes during support sessions
- Document any configuration modifications
- Use read-only operations when possible
- Respect user privacy and data security

### Audit and Logging
```bash
# RAC connection logging
/var/log/wsprdaemon/rac-access.log

# Configuration change tracking
git log --oneline wsprdaemon.conf

# Service modification logging  
journalctl -u wsprdaemon -f
```

## Deployment Security Best Practices

### System Hardening
```bash
# Disable unnecessary services
systemctl disable bluetooth
systemctl disable wifi-powersave

# Enable automatic security updates
apt install unattended-upgrades
dpkg-reconfigure unattended-upgrades

# Configure firewall for WsprDaemon
ufw allow ssh
ufw allow from 192.168.0.0/16 to any port 8081  # KA9Q-web
ufw enable
```

### Monitoring and Alerting
```bash
# System health monitoring
./wsprdaemon.sh -s > /tmp/wd-health.txt

# Automatic problem detection
if ! ./wsprdaemon.sh -s | grep -q "RUNNING"; then
    # Alert developer via configured method
    echo "WsprDaemon service issue detected" | mail -s "WD Alert" developer@example.com
fi
```

### Backup and Recovery
```bash
# Configuration backup before changes
cp wsprdaemon.conf wsprdaemon.conf.backup.$(date +%Y%m%d-%H%M%S)

# System state backup
tar -czf /tmp/wd-backup-$(date +%Y%m%d).tar.gz \
    wsprdaemon.conf \
    /var/log/wsprdaemon/ \
    ~/.ssh/authorized_keys
```

## Implementation Priorities

### Phase 1: Immediate Security Improvements
1. **Configuration Validation**: Prevent corrupted configurations
2. **SSH Key Management**: Automated key rotation and management  
3. **Logging Enhancement**: Structured logging for security events
4. **Update Automation**: Safe automatic updates with rollback

### Phase 2: User Experience Improvements  
1. **Web Configuration UI**: Remove need for terminal configuration
2. **Remote Diagnostics**: Automated problem detection and reporting
3. **Health Dashboards**: Status monitoring without technical knowledge
4. **Documentation**: Non-technical user guides

### Phase 3: Advanced Security
1. **Network Segmentation**: Isolate SDR networks from internet
2. **Certificate Management**: TLS for all web interfaces
3. **Intrusion Detection**: Automated attack detection and response
4. **Compliance**: Security audit logging and retention

This security model balances user protection with developer access needs, ensuring non-technical users can operate WsprDaemon safely while providing Rob with the tools needed for remote debugging and maintenance.