# Remote Development Setup

*Modern development tools and workflows for WsprDaemon contributors*

This guide describes how to set up VS Code and other development tools for remote WsprDaemon development on Raspberry Pi hosts with SDR hardware.

## Overview

WsprDaemon development requires access to actual hardware (KiwiSDRs, RX888 SDRs) that's typically available only on remote Raspberry Pi systems. This setup provides developers with modern tools while maintaining the security and automation needed for non-technical end users.

### Key Requirements
- End users have varying levels of Linux experience
- System must provide robust protection and automated maintenance
- Reliable data propagation from user machines to servers
- Developers need advanced debugging and development tools for remote systems

## Remote Access Architecture

WsprDaemon includes a sophisticated remote access system designed for secure developer access without exposing client systems to the internet.

### Remote Access Channel (RAC) System
- **Purpose**: Secure developer access to WD installations without internet exposure
- **Security Model**: FRP + WireGuard + Digital Ocean firewall
- **Port Mapping**: RAC number maps to port 35800+RAC on wd0.wsprdaemon.org  
  - RAC 0 → port 35800
  - RAC 1 → port 35801  
  - RAC 100 → port 35900
- **Access Method**: `ssh -p 35XXX wsprdaemon@wd0.wsprdaemon.org`
- **Network Security**: Requires active WireGuard VPN session

### How RAC Works
1. **Client Side**: WD installations run `frpc` to connect to wd0.wsprdaemon.org
2. **Server Side**: Each RAC opens a private port (35800+RAC) that tunnels to client's port 22
3. **Security Layer**: wd0 is a Digital Ocean droplet behind firewall
4. **Access Control**: Only accessible via WireGuard VPN
5. **Developer Access**: `ssh -p 35XXX wsprdaemon@wd0.wsprdaemon.org` (through VPN)
6. **Multiple Networks**: Support for both wsprdaemon.org and HAM Site group networks

## Prerequisites

### Local Machine
- VS Code with Remote-SSH extension installed
- SSH client (OpenSSH compatible)
- Internet access for extension downloads
- WireGuard VPN client (for RAC access)

### Remote Pi Host
- Ubuntu/Debian Linux (Raspberry Pi OS)
- SSH server running
- WsprDaemon user account with sudo access
- At least 2GB RAM (recommended for development)
- SDR hardware connected and configured

## VS Code Configuration

### Workspace Settings (`.vscode/settings.json`)
```json
{
    "files.associations": {
        "*.sh": "shellscript",
        "*.conf": "properties",
        "wsprdaemon.conf": "properties"
    },
    "shellcheck.enable": true,
    "python.defaultInterpreterPath": "/usr/bin/python3",
    "files.watcherExclude": {
        "**/logs/**": true,
        "**/tmp/**": true,
        "**/*.wav": true,
        "**/*.log": true
    }
}
```

### Recommended Extensions (`.vscode/extensions.json`)
```json
{
    "recommendations": [
        "ms-vscode-remote.remote-ssh",
        "ms-python.python",
        "timonwong.shellcheck",
        "foxundermoon.shell-format"
    ]
}
```

### Development Tasks (`.vscode/tasks.json`)
```json
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "WD: Start Service",
            "type": "shell",
            "command": "./wsprdaemon.sh -a",
            "group": "build",
            "presentation": {
                "echo": true,
                "reveal": "always",
                "focus": false,
                "panel": "shared"
            }
        },
        {
            "label": "WD: Show Status",
            "type": "shell",
            "command": "./wsprdaemon.sh -s",
            "group": "test"
        },
        {
            "label": "WD: Stop Service",
            "type": "shell",
            "command": "./wsprdaemon.sh -z",
            "group": "build"
        },
        {
            "label": "WD: View Error Logs",
            "type": "shell",
            "command": "./wsprdaemon.sh -l e",
            "group": "test"
        },
        {
            "label": "ShellCheck: All Scripts",
            "type": "shell",
            "command": "find . -name '*.sh' -exec shellcheck {} \\;",
            "group": "test"
        }
    ]
}
```

## SSH Configuration

### Enhanced SSH Config
Add to your `~/.ssh/config`:

```ssh
# WsprDaemon Development Hosts
Host wd-pi-*
    User wsprdaemon
    ForwardAgent yes
    ServerAliveInterval 60
    ServerAliveCountMax 3
    # Connection multiplexing for faster development
    ControlMaster auto
    ControlPath ~/.ssh/control-%r@%h:%p
    ControlPersist 10m
    # Port forwarding for web interfaces
    LocalForward 8081 localhost:8081  # KA9Q-web
    LocalForward 8080 localhost:8080  # Alternative web interface
    LocalForward 8073 localhost:8073  # KiwiSDR web interface

# RAC-based connections
Host wd-rac-*
    Hostname wd0.wsprdaemon.org
    User wsprdaemon
    ForwardAgent yes
    ServerAliveInterval 30
    ServerAliveCountMax 10
    # Optimized for high-latency connections
    TCPKeepAlive yes
    Compression yes
```

### Connection Multiplexing Benefits
- Faster subsequent connections
- Reduced authentication overhead
- Persistent connections survive temporary network issues
- Shared connections for multiple VS Code windows

## Development Workflow

### 1. Connect to Remote Host

**Direct Connection:**
```bash
# SSH to WsprDaemon host (if direct access available)
ssh wsprdaemon@<host>
```

**RAC Connection:**
```bash
# Connect via RAC system (requires WireGuard VPN)
ssh -p 35923 wsprdaemon@wd0.wsprdaemon.org  # RAC 123 example
```

**VS Code Remote-SSH:**
- Cmd+Shift+P → "Remote-SSH: Connect to Host"
- Select configured host or enter connection details

### 2. Set Up tmux Development Environment

tmux is essential for persistent sessions, especially for unreliable connections like Antarctica satellite internet:

```bash
# Start or attach to tmux session
tmux new-session -d -s wd-dev
tmux attach-session -t wd-dev

# Create multiple panes for different tasks
tmux split-window -h    # Split horizontally
tmux split-window -v    # Split vertically

# Common tmux workflow:
# Pane 1: Code editing and git operations
# Pane 2: WsprDaemon monitoring (./wsprdaemon.sh -s)  
# Pane 3: Live log monitoring (./wsprdaemon.sh -l e)
# Pane 4: Service control and testing
```

### 3. VS Code Integration with tmux

**Option 1: VS Code Remote-SSH with integrated terminal**
```bash
# The tmux sessions will be available in VS Code's terminal
# Use Ctrl+` to open integrated terminal
# Run: tmux attach-session -t wd-dev
```

**Option 2: Traditional terminal + VS Code remote editing**
```bash
# Keep tmux in separate terminal window
# Use VS Code for file editing and project management
# Switch between terminal and VS Code as needed
```

### 4. Common Development Tasks

#### Service Management
Use VS Code tasks (Cmd+Shift+P → "Tasks: Run Task"):
- **WD: Start Service** - Start WsprDaemon service
- **WD: Show Status** - Check status and logs
- **WD: Stop Service** - Stop service for development
- **WD: View Error Logs** - Monitor error logs

#### Code Editing
- Shell scripts get automatic ShellCheck linting
- Python scripts use remote Python interpreter
- Git operations work seamlessly
- File watching optimized for remote development

#### Testing Changes
```bash
# Copy config template and customize
cp wd_template.conf wsprdaemon.conf
# Edit configuration for your hardware
code wsprdaemon.conf

# Test configuration
./wsprdaemon.sh -s

# View logs in real-time
./wsprdaemon.sh -l e

# Monitor specific log types
./wsprdaemon.sh -l n  # wsprnet uploads
./wsprdaemon.sh -l d  # daemon logs
```

## Hardware-Specific Development

### KiwiSDR Development
```bash
# KiwiSDR web interface access
# Port 8073 automatically forwarded via SSH config
curl http://localhost:8073  # Test connectivity

# KiwiSDR configuration in wsprdaemon.conf
KIWI_0_HOST="your-kiwi-hostname"
KIWI_0_PORT="8073"
KIWI_0_PASSWORD="your-password"
```

### RX888/KA9Q Radio Development  
```bash
# KA9Q-web interface access
curl http://localhost:8081  # Test KA9Q-web

# Radio control via multicast streams
# Requires specific radiod.conf configuration
# Check multicast groups
ip maddr show
```

### Multi-Band Testing
```bash
# Configure WSPR_SCHEDULE arrays for test scenarios
WSPR_SCHEDULE_0=(
    "00:00 KA9Q_0,20,W2:F2:F5 KIWI_0,40,W2:F2:F5"
    "00:02 KA9Q_0,40,W2:F2:F5 KIWI_0,20,W2:F2:F5"
)

# Use MERG_* receivers for development without double-posting
MERG_0_CALL_SIGN="TEST"
MERG_0_GRID_SQUARE="AA00"

# Monitor uploads
./wsprdaemon.sh -l n  # wsprnet uploads
```

## Debugging Remote Issues

### Connection Problems
```bash
# Test SSH connection with verbose output
ssh -vvv wd-pi-dev

# Test RAC connection
ssh -vvv -p 35923 wd0.wsprdaemon.org

# Check SSH service on remote
sudo systemctl status ssh

# Verify port forwarding
curl http://localhost:8081  # Should reach KA9Q-web if running
curl http://localhost:8073  # Should reach KiwiSDR if configured
```

### WsprDaemon Issues
```bash
# Check service status
./wsprdaemon.sh -s

# View live error logs
./wsprdaemon.sh -l e

# Check systemd service (if installed)
sudo systemctl status wsprdaemon

# Validate configuration
bash -n wsprdaemon.conf
```

### VS Code Remote Issues
```bash
# Reset VS Code server on remote host
rm -rf ~/.vscode-server

# Check remote extension installation
ls ~/.vscode-server/extensions/

# Check VS Code server logs
cat ~/.vscode-server/.*.log
```

### Network Connectivity Issues
```bash
# Test internet connectivity
ping -c 3 wsprnet.org
curl -I http://wsprnet.org

# Check local network
ip addr show
ip route show

# Test SDR connectivity
ping -c 3 your-kiwi-hostname
telnet your-kiwi-hostname 8073
```

## Performance Optimization

### SSH Connection Optimization
```ssh
# ~/.ssh/config optimizations for high-latency connections
Host wd-*
    # Compression for slow connections
    Compression yes
    
    # Keep connections alive
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
    
    # Connection multiplexing
    ControlMaster auto
    ControlPath ~/.ssh/control-%r@%h:%p
    ControlPersist 10m
    
    # Cipher optimization for performance
    Ciphers aes128-gcm@openssh.com,aes128-ctr
```

### tmux Configuration
```bash
# ~/.tmux.conf optimizations
# Increase scrollback buffer
set-option -g history-limit 10000

# Reduce escape time for better responsiveness
set -sg escape-time 1

# Enable mouse support
set -g mouse on

# Better session management
bind-key S choose-session
```

### VS Code Remote Optimizations
```json
// settings.json for remote development
{
    "remote.SSH.connectTimeout": 60,
    "remote.SSH.keepAlive": 30,
    "files.watcherExclude": {
        "**/logs/**": true,
        "**/tmp/**": true,
        "**/*.wav": true,
        "**/*.log": true,
        "**/node_modules/**": true
    }
}
```

## Best Practices

### Development Workflow
1. **Always test configuration** with `./wsprdaemon.sh -s` before starting
2. **Use separate config files** for development vs production
3. **Monitor logs continuously** during testing
4. **Keep backup configurations** for known-good setups
5. **Document hardware-specific assumptions** in code comments

### Code Quality
- Run ShellCheck on all shell scripts before committing
- Test Python scripts with multiple Python versions when possible
- Validate configuration files before deployment
- Use consistent coding style and patterns
- Add meaningful commit messages with hardware context

### Remote Performance
- Use connection multiplexing for faster SSH connections
- Minimize file watchers on remote filesystem
- Cache dependencies locally when possible
- Use tmux/screen for long-running processes
- Optimize VS Code settings for remote development

### Security Considerations
- Use SSH keys instead of passwords
- Keep RAC access time-limited and documented
- Respect user privacy and system security
- Follow principle of least privilege
- Maintain audit trail of development activities

This setup provides a professional development environment that matches the complexity and hardware requirements of WsprDaemon while maintaining security and performance for remote development scenarios.
