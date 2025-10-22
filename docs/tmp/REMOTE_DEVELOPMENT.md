# Remote Development Setup for WsprDaemon

*A guide for setting up modern development tools for WsprDaemon development on remote Raspberry Pi hosts*

**Date**: September 2025  
**Purpose**: Developer onboarding and tooling setup  
**Audience**: Contributors and maintainers working with WsprDaemon

This document describes how to set up VS Code and other development tools for remote WsprDaemon development on Raspberry Pi hosts.

## Overview

WsprDaemon development requires access to actual hardware (KiwiSDRs, RX888 SDRs) that's typically available only on remote Raspberry Pi systems. This setup provides Rob with modern development tools while maintaining the security and automation needed for non-technical end users.

**Key Requirements:**
- End users have varying levels of Linux experience, from beginners to advanced
- System must provide robust protection and automated maintenance
- Reliable data propagation from user machines to servers
- Developers need advanced debugging and development tools for remote systems

## Current Remote Access Architecture

WsprDaemon includes a sophisticated remote access system:

### Remote Access Channel (RAC) Architecture
- **Purpose**: Secure developer access to WD installations without internet exposure
- **Security Model**: FRP + WireGuard + Digital Ocean firewall (much safer than direct internet)
- **Port Mapping**: RAC number maps to port 35800+RAC on wd0.wsprdaemon.org  
  - RAC 0 → port 35800
  - RAC 1 → port 35801  
  - RAC 100 → port 35900
  - etc.
- **Access Method**: `ssh -p 35XXX wsprdaemon@wd0.wsprdaemon.org`
- **Network Security**: Requires active WireGuard VPN session to reach wd0

### How RAC Works
1. **Client Side**: WD installations run `frpc` to connect to wd0.wsprdaemon.org
2. **Server Side**: Each RAC opens a private port (35800+RAC) on wd0 that tunnels to client's port 22
3. **Security Layer**: wd0 is a Digital Ocean droplet behind DO firewall
4. **Access Control**: Only accessible via WireGuard VPN (Rob has 4-5 WG sessions active)
5. **Developer Access**: `ssh -p 35XXX wsprdaemon@wd0.wsprdaemon.org` (through VPN)
6. **Multiple Networks**: Rob has access to both wsprdaemon.org and HAM Site group networks

## Prerequisites

### Local Machine
- VS Code with Remote-SSH extension installed ✓
- SSH client (OpenSSH compatible)
- Internet access for extension downloads

### Remote Pi Host
- Ubuntu/Debian Linux (Raspberry Pi OS)
- SSH server running
- WsprDaemon user account with sudo access
- At least 2GB RAM (recommended for development)

## VS Code Configuration

The repository includes pre-configured VS Code settings:

### Workspace Settings (`.vscode/settings.json`)
- Shell script and Python file associations
- Linting enabled (ShellCheck, flake8)
- Remote development optimizations
- File watcher exclusions for logs and binary files

### Recommended Extensions (`.vscode/extensions.json`)
- `ms-vscode-remote.remote-ssh` - Remote SSH development
- `ms-python.python` - Python support
- `timonwong.shellcheck` - Bash script linting
- `foxundermoon.shell-format` - Shell script formatting

### Development Tasks (`.vscode/tasks.json`)
Ready-to-use tasks for common WD operations:
- **WD: Start Service** (`./wsprdaemon.sh -a`)
- **WD: Show Status** (`./wsprdaemon.sh -s`) 
- **WD: Stop Service** (`./wsprdaemon.sh -z`)
- **WD: View Error Logs** (`./wsprdaemon.sh -l e`)
- **ShellCheck: All Scripts** - Static analysis

## SSH Configuration

### Enhanced SSH Config
Your `~/.ssh/config` has been updated with WsprDaemon-specific settings:

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
    LocalForward 8081 localhost:8081
    LocalForward 8080 localhost:8080
```

### Connection Multiplexing Benefits
- Faster subsequent connections
- Reduced authentication overhead
- Persistent connections survive temporary network issues

## Development Workflow

Rob's actual development workflow uses tmux for persistent sessions and monitoring, especially critical for Antarctica satellite internet with frequent disconnections:

### 1. Connect to Remote Host
```bash
# SSH to WsprDaemon host
ssh wsprdaemon@<host>

# Or use VS Code Remote-SSH
# Cmd+Shift+P → "Remote-SSH: Connect to Host"
```

### 2. Set Up tmux Development Environment
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
```bash
# Option 1: Use VS Code Remote-SSH with integrated terminal
# The tmux sessions will be available in VS Code's terminal

# Option 2: Traditional terminal + VS Code remote editing
# Keep tmux in separate terminal, use VS Code for file editing
```

### 4. Common Development Tasks

#### Service Management
Use VS Code tasks (Cmd+Shift+P → "Tasks: Run Task"):
- Start WsprDaemon service
- Check status and logs
- Stop service for development

#### Code Editing
- Shell scripts get automatic ShellCheck linting
- Python scripts use remote Python interpreter
- Git operations work seamlessly

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
```

## Security Considerations

### RAC System Security
- Uses secure proxy tunnels via `frpc`
- Requires explicit configuration in `wsprdaemon.conf`
- Developer access controlled by WD maintainers
- All connections logged and monitored

### SSH Key Management
```bash
# Generate SSH key if needed
ssh-keygen -t ed25519 -C "your-email@example.com"

# Copy to remote host
ssh-copy-id wsprdaemon@your-pi-host
```

## Debugging Remote Issues

### Connection Problems
```bash
# Test SSH connection
ssh -vvv wd-pi-dev

# Check SSH service on remote
sudo systemctl status ssh

# Verify port forwarding
curl http://localhost:8081  # Should reach KA9Q-web if running
```

### WsprDaemon Issues
```bash
# Check service status
./wsprdaemon.sh -s

# View live error logs
./wsprdaemon.sh -l e

# Check systemd service (if installed)
sudo systemctl status wsprdaemon
```

### VS Code Remote Issues
```bash
# Reset VS Code server on remote host
rm -rf ~/.vscode-server

# Check remote extension installation
ls ~/.vscode-server/extensions/
```

## Hardware-Specific Development

### KiwiSDR Development
- KiwiSDR web interface: `http://your-kiwi:8073`
- Port 8073 automatically forwarded via SSH config
- Test with: `curl http://localhost:8073`

### RX888/KA9Q Radio Development  
- KA9Q-web interface: `http://localhost:8081`
- Radio control via multicast streams
- Requires specific `radiod.conf` configuration

### Multi-Band Testing
- Configure `WSPR_SCHEDULE` arrays for test scenarios
- Use `MERG_*` receivers for development without double-posting
- Monitor with `./wsprdaemon.sh -l n` (wsprnet uploads)

## Best Practices

### Development Workflow
1. Always test configuration with `./wsprdaemon.sh -s` before starting
2. Use separate config files for development vs production
3. Monitor logs continuously during testing
4. Keep backup configurations for known-good setups

### Code Quality
- Run ShellCheck on all shell scripts before committing
- Test Python scripts with multiple Python versions
- Validate configuration files before deployment
- Document any hardware-specific assumptions

### Remote Performance
- Use connection multiplexing for faster SSH
- Minimize file watchers on remote filesystem
- Cache dependencies locally when possible
- Use tmux/screen for long-running processes

This setup provides a professional development environment that matches the complexity and hardware requirements of WsprDaemon while maintaining security and performance.