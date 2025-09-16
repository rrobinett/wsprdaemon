# Network Security Architecture

*Comprehensive overview of WsprDaemon's secure remote access design*

WsprDaemon implements a sophisticated security architecture that protects amateur radio operators while enabling remote maintenance and development access. This document explains the technical implementation and security rationale.

## The Security Challenge

WsprDaemon operators typically have limited Linux command line experience and operate in diverse environments from home stations to extreme locations like Antarctica. The system must provide:

- Remote developer access for debugging and maintenance
- Protection against data corruption and malicious attacks  
- Automatic data propagation from client machines to servers
- Hardware-specific development capabilities
- Operation from extreme locations with unreliable connectivity

## Security Philosophy

**Core Principle**: Prioritize user protection over developer convenience. Technical complexity is absorbed by the system rather than pushed to end users.

**Key Insight**: "The problem is security and liability. I don't want to put WSPR clients on the open internet." - Rob Robinett AI6VN

## Remote Access Channel (RAC) System

### Architecture Overview

The RAC system uses a **reverse-tunnel architecture** where client devices never accept direct inbound connections. This protects amateur radio operators from internet-based attacks while enabling remote maintenance access.

**Core Components:**
- **FRP (Fast Reverse Proxy)**: Creates secure tunnels from client devices to central server
- **wd0.wsprdaemon.org**: Digital Ocean droplet acting as secure proxy server  
- **Digital Ocean Firewall**: Blocks all unauthorized access to wd0
- **WireGuard VPN**: Required for any access to the proxy server (port 51820)
- **RAC System**: Remote Access Channel numbering for organized device access

### Security Layers (Defense in Depth)

1. **Digital Ocean Firewall**: Perimeter defense blocking unauthorized traffic
2. **WireGuard VPN**: Encrypted access control and authentication
3. **FRP Reverse Tunnels**: No client exposure to internet
4. **SSH Key Authentication**: Developer access control
5. **Application-Level Permissions**: Service isolation and user protection

### Port Mapping System

**Formula**: `RAC_NUMBER → PORT 35800+RAC_NUMBER`

Examples:
- RAC 0 → `ssh -p 35800 wsprdaemon@wd0.wsprdaemon.org`
- RAC 1 → `ssh -p 35801 wsprdaemon@wd0.wsprdaemon.org`  
- RAC 100 → `ssh -p 35900 wsprdaemon@wd0.wsprdaemon.org`
- RAC 1000 → `ssh -p 36800 wsprdaemon@wd0.wsprdaemon.org`

**Range**: RAC 100 to several thousand (allows massive scaling)

## Technical Implementation

### Client Side Configuration

**User Experience**: Users add only two lines to `wsprdaemon.conf`:
```bash
REMOTE_ACCESS_CHANNEL=123
REMOTE_ACCESS_ID="MyStation-Pi4"
```

**Automatic FRPC Configuration**:
```ini
[common]
server_addr = wd0.wsprdaemon.org
server_port = 7000

[RAC_ID]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = 35XXX  # 35800 + RAC_NUMBER
```

### Developer Access Workflow

**Prerequisites:**
- Active WireGuard VPN connection to authorized network (port 51820)
- SSH access to wd0.wsprdaemon.org
- Knowledge of client's RAC number

**Connection Process:**
1. Connect to WireGuard VPN
2. SSH to specific RAC port: `ssh -p 35923 wsprdaemon@wd0.wsprdaemon.org`  # 35800 + 123  
3. Direct access to client's Pi as if local

### Multi-Network Deployment

**Wsprdaemon.org Network:**
- Rob's original deployment
- Digital Ocean infrastructure  
- Primary development and testing

**HAM Site Group Network:**
- Independent deployment by collaborators
- Own Digital Ocean droplet
- Own private network with WireGuard
- Shared codebase, independent security

**Scaling Model**: Each organization can deploy their own secure network while sharing the WsprDaemon codebase.

## Security Benefits

### For Amateur Radio Operators
- **Zero Internet Exposure**: Client devices never accept direct inbound connections
- **No Security Configuration**: Users don't need to manage firewalls, VPNs, or certificates
- **Liability Protection**: No risk of equipment being used for malicious purposes
- **Automatic Updates**: Security patches applied without user intervention

### For Developers
- **Controlled Access**: Central chokepoint for all remote access
- **Audit Trail**: All connections logged and monitored
- **Scalable**: Supports hundreds of installations
- **Reliable**: Works through NAT, firewalls, and dynamic IP addresses

## Connection Reliability Features

### Extreme Environment Support
**Challenge**: Antarctica satellite internet
- High latency (500-1000ms+)
- Frequent disconnections  
- Bandwidth limitations
- Packet loss

**Solutions**:
- tmux for session persistence across connection drops
- SSH connection optimization for high-latency links
- FRP tunnel automatic reconnection
- Connection multiplexing for efficiency

### Automatic Recovery
- **Power outages**: systemd restart capability
- **Network interruptions**: cached uploads until connectivity restored
- **SDR disconnections**: automatic reconnection attempts
- **Tunnel failures**: FRP client automatic reconnection

## Security Evaluation

### Threat Model Addressed
- **Amateur Radio Liability**: No direct internet exposure eliminates legal risks
- **User Protection**: Zero security configuration required from operators
- **Data Integrity**: Automated propagation with validation
- **Unauthorized Access**: Multiple authentication layers prevent intrusion
- **Network Attacks**: Isolated networks with VPN access control

### Comparison with Alternatives

| Approach | Security | Complexity | User Burden | Scalability |
|----------|----------|------------|-------------|-------------|
| Direct Internet (AMPRNet) | Low | Low | High | High |
| Port Forwarding | Medium | Medium | High | Low |  
| **FRP + WireGuard** | **High** | **Medium** | **Low** | **High** |
| Commercial VPN | Medium | Low | Medium | Medium |

## Operational Results

**Current Scale:**
- 20+ top WSPR spotting sites using this architecture
- Aggregate ~33% of daily spots on wsprnet.org (7+ million/day)
- Multi-continent deployment including extreme locations

**Reliability Metrics:**
- Works through power outages (automatic reconnection)
- Survives internet outages (cached data until reconnection)  
- Handles NAT changes and dynamic IP updates
- Functions in extreme RF environments

## Development Constraints and Solutions

### Why Device-Specific Development Required
- Every device environment is unique (different SDRs, configurations, interference)
- Hardware dependencies (KiwiSDRs, RX888s, antenna systems)
- Real-world RF conditions cannot be simulated
- Network conditions vary dramatically by location

### Remote Development Challenges
**Environment Factors:**
- High-latency connections (satellite internet)
- Unreliable connectivity with frequent drops
- Limited bandwidth for development tools
- Time zone differences for support

**Technical Solutions:**
- Session persistence with tmux/screen
- Connection multiplexing for efficiency
- Optimized SSH configurations
- Local caching of development resources

## Security Monitoring and Auditing

### Connection Logging
```bash
# RAC connection tracking
/var/log/wsprdaemon/rac-access.log

# FRP tunnel status
/var/log/frpc/tunnel-status.log

# SSH access logs
journalctl -u ssh -f
```

### Health Monitoring
```bash
# Tunnel health checks
frpc status

# VPN connectivity
wg show

# Service availability
systemctl status wsprdaemon
```

## Future Security Enhancements

### Planned Improvements
1. **Certificate Management**: TLS for all web interfaces
2. **Enhanced Monitoring**: Real-time security event detection
3. **Access Control**: Time-limited developer sessions
4. **Audit Compliance**: Extended logging and retention

### Long-term Vision
- **Web Configuration UI**: Eliminate terminal configuration needs
- **Mobile Management**: Smartphone apps for system monitoring
- **Automated Security**: Self-healing security configurations
- **Zero-Trust Architecture**: Enhanced verification at all levels

## Conclusion

The FRP + WireGuard architecture successfully balances the competing requirements of security, usability, and maintainability for a global amateur radio infrastructure deployment. By prioritizing user protection and absorbing technical complexity at the system level, WsprDaemon enables thousands of amateur radio operators to contribute to WSPR networks without security expertise or liability concerns.

The architecture demonstrates how sophisticated security can be made transparent to end users while providing developers with the access needed for maintenance and enhancement of critical amateur radio infrastructure.

---

*This security architecture reflects years of operational experience with non-technical users, extreme deployment environments, and the need to balance security with functionality in amateur radio applications.*
