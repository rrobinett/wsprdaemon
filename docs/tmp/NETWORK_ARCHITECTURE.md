# WsprDaemon Network Architecture

*A comprehensive overview of the secure remote access design for WsprDaemon installations*

**Author**: Based on insights from Rob Robinett AI6VN and the WsprDaemon development team  
**Date**: September 2025  
**Purpose**: Technical documentation for collaborators and contributors

## The Challenge

WsprDaemon operators typically have limited Linux command line experience. The system needs to accommodate users with varying technical backgrounds while providing:

- Remote developer access for debugging and maintenance
- Protection against data corruption and malicious attacks  
- Automatic data propagation from client machines to servers
- Hardware-specific development (every device environment is unique)
- Operation from extreme locations (Antarctica with satellite internet)

## Phil Karn's Suggestion vs. Reality

**Phil Karn (Internet pioneer, recent ARDC president) suggested**: Use AMPRNet IP block (https://en.wikipedia.org/wiki/AMPRNet) for direct internet access - simpler and less obscure than SSH tunnels.

**Rob's Response**: "The problem is security and liability. I don't want to put WSPR clients on the open internet."

## Rob's Security Architecture

### Core Design: FRP + WireGuard + Firewall

**Components:**
- **FRP (Fast Reverse Proxy)**: Creates secure tunnels from client devices to central server
- **wd0.wsprdaemon.org**: Digital Ocean droplet acting as secure proxy server  
- **Digital Ocean Firewall**: Blocks all unauthorized access to wd0
- **WireGuard VPN**: Required for any access to the proxy server (port 51820)
- **RAC System**: Remote Access Channel numbering for organized device access

### Why This Architecture

**Security Benefits:**
- No direct internet exposure of client devices
- Defense in depth: Firewall + VPN + Proxy
- Controlled access through central chokepoint
- Protection of amateur radio operators from liability

**Operational Benefits:**
- Works with users of all technical levels (zero client configuration needed)
- Survives NAT, firewalls, and dynamic IP addresses
- Automatic reconnection and health monitoring
- Scales to hundreds of installations

## Technical Implementation

### Remote Access Channel (RAC) System

**Port Mapping Formula**: `RAC_NUMBER → PORT 35800+RAC_NUMBER`

Examples:
- RAC 0 → ssh -p 35800 wsprdaemon@wd0.wsprdaemon.org
- RAC 1 → ssh -p 35801 wsprdaemon@wd0.wsprdaemon.org  
- RAC 100 → ssh -p 35900 wsprdaemon@wd0.wsprdaemon.org
- RAC 1000 → ssh -p 36800 wsprdaemon@wd0.wsprdaemon.org

**Range**: RAC 100 to several thousand (allows massive scaling)

### Client Side Operation

**FRPC Configuration** (automatic via WsprDaemon):
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

**User Experience**: Users add two lines to `wsprdaemon.conf`:
```bash
REMOTE_ACCESS_CHANNEL=123
REMOTE_ACCESS_ID="MyStation-Pi4"
```

### Developer Access Workflow

**Prerequisites:**
- Active WireGuard VPN connection to Rob's network (port 51820)
- SSH access to wd0.wsprdaemon.org
- Knowledge of client's RAC number

**Connection Process:**
1. Connect to WireGuard VPN
2. SSH to specific RAC port: `ssh -p 35923 wsprdaemon@wd0.wsprdaemon.org`  # 35800 + 123  
3. Direct access to client's Pi as if local

**Rob's Current Setup:**
- 4-5 active WireGuard sessions on Mac
- Access to multiple private networks:
  - wsprdaemon.org network (Rob's)
  - HAM Site group network (collaborative deployment)

## Multi-Network Deployment

### Wsprdaemon.org Network
- Rob's original deployment
- Digital Ocean infrastructure  
- Primary development and testing

### HAM Site Group Network  
- Independent deployment by collaborators
- Own Digital Ocean droplet
- Own private network with WireGuard
- Rob has access to both networks

**Scaling Model**: Each organization can deploy their own secure network while sharing the WsprDaemon codebase.

## Development Constraints and Solutions

### Why Device-Specific Development Required
- Every device environment is unique (different SDRs, configurations, interference)
- Hardware dependencies (KiwiSDRs, RX888s, antenna systems)
- Real-world RF conditions cannot be simulated

### Connection Reliability Challenges
**Environment**: Antarctica satellite internet
- High latency (500-1000ms+)
- Frequent disconnections  
- Bandwidth limitations
- Packet loss

**Current Solutions**:
- tmux for session persistence across connection drops
- SSH connection optimization for high-latency links
- FRP tunnel automatic reconnection

**Note on Alternative Solutions**: While tools like Mosh offer theoretical improvements for unreliable connections, they are incompatible with the secure reverse-tunnel architecture that protects non-technical users. The current SSH + tmux approach provides both the necessary functionality and maintains the security model.

## Security Evaluation

### Threat Model Addressed
- **Amateur Radio Liability**: No direct internet exposure
- **User Protection**: Zero security configuration required from operators
- **Data Integrity**: Automated propagation with validation
- **Unauthorized Access**: Multiple authentication layers
- **Network Attacks**: Isolated networks with VPN access

### Defense in Depth
1. **Digital Ocean Firewall**: First barrier
2. **WireGuard VPN**: Authentication and encryption  
3. **SSH Authentication**: Key-based access
4. **Application Level**: WsprDaemon user permissions
5. **Monitoring**: Connection and access logging

## Comparison with Alternatives

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

## Conclusion

Rob's FRP + WireGuard architecture prioritizes **security and liability protection** over technical simplicity. While Phil Karn's direct internet suggestion would be technically simpler, Rob's approach provides:

- **Zero security configuration burden** on operators
- **Professional-grade security** for amateur radio community  
- **Liability protection** for equipment owners
- **Operational resilience** in extreme environments
- **Scalable deployment model** for collaborative networks

The architecture successfully balances the competing requirements of security, usability, and maintainability for a global amateur radio infrastructure deployment.

---

*This document captures the WsprDaemon network architecture decisions for secure remote access. The design reflects years of operational experience with non-technical users, extreme deployment environments, and the need to balance security with functionality in amateur radio applications.*