# FRP UDP Tunneling for Mosh - Technical Proposal

## Current Situation

WsprDaemon's FRP setup currently only supports TCP tunneling:
```ini
[common]
server_addr = wd0.wsprdaemon.org  
server_port = 35735

[RAC_ID]
type = tcp
local_port = 22
remote_port = 35XXX  # 35800 + RAC_NUMBER
```

## Proposed Mosh Integration

### 1. Enhanced FRP Configuration

Add UDP tunneling alongside existing TCP for each RAC:

```ini
[common]
server_addr = wd0.wsprdaemon.org
server_port = 35735

# Existing SSH tunnel (unchanged)
[RAC_ID-SSH]
type = tcp  
local_port = 22
remote_port = 35XXX  # 35800 + RAC

# New Mosh UDP tunnel
[RAC_ID-MOSH]
type = udp
local_port = 60001
remote_port = 45XXX  # 45800 + RAC (different range from TCP)
```

### 2. Port Allocation Strategy

**TCP Ports (SSH)**: 35800-39999 (existing)
**UDP Ports (Mosh)**: 45800-49999 (new range)

Examples:
- RAC 100: SSH on 35900/tcp, Mosh on 45900/udp
- RAC 500: SSH on 36300/tcp, Mosh on 46300/udp

### 3. Required Changes

#### Client Side (Pi hosts)
```bash
# Modified frpc configuration generator
cat > ${FRPC_INI_FILE} << EOF
[common]
server_addr = ${WD_FRPS_URL}
server_port = ${WD_FRPS_PORT}

[${remote_access_id}-SSH]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = ${tcp_remote_port}

[${remote_access_id}-MOSH] 
type = udp
local_ip = 127.0.0.1
local_port = 60001  # Fixed mosh server port
remote_port = ${udp_remote_port}
EOF
```

#### Server Side (wd0.wsprdaemon.org)
```bash
# FRP server configuration update
# Add UDP port range 45800-49999 to server config
# Update Digital Ocean firewall rules:
# - Allow UDP 45800-49999 from WireGuard clients
```

#### Client Connection Script
```bash
#!/bin/bash
# Enhanced connection script supporting both SSH and Mosh

RAC_NUMBER="$1"
MODE="${2:-ssh}"  # ssh or mosh

TCP_PORT=$((35800 + RAC_NUMBER))
UDP_PORT=$((45800 + RAC_NUMBER))

case "$MODE" in
    ssh)
        ssh -p $TCP_PORT wsprdaemon@wd0.wsprdaemon.org
        ;;
    mosh)
        # Use mosh with explicit server command
        mosh --ssh="ssh -p $TCP_PORT" \
             --server="MOSH_SERVER_NETWORK_TMOUT=604800 mosh-server new -p $UDP_PORT" \
             wsprdaemon@wd0.wsprdaemon.org
        ;;
    *)
        echo "Usage: $0 <RAC_NUMBER> [ssh|mosh]"
        exit 1
        ;;
esac
```

### 4. Implementation Challenges

#### Technical Issues
1. **FRP Version**: Need to upgrade from 0.36.2 to newer version supporting UDP
2. **Mosh Port Range**: Mosh typically uses random ports 60000-61000, but we need fixed ports for tunneling
3. **Server Configuration**: wd0 needs modified FRP server config and firewall rules
4. **NAT Traversal**: UDP tunneling through multiple NAT layers may have issues

#### Security Considerations - CRITICAL ISSUES
1. **MAJOR SECURITY HOLE**: Mosh UDP tunneling would expose client Pi ports to any WireGuard client
2. **Forward vs Reverse Tunneling**: 
   - Current: Reverse tunnels (wd0 → client) - only developer can initiate connections
   - Mosh UDP: Would require forward tunnels (client → wd0) - anyone on WireGuard can connect
3. **Attack Surface Expansion**: 
   - Current: Client Pi only accepts connections from wd0
   - Mosh UDP: Client Pi UDP port exposed to entire WireGuard network
4. **Access Control Loss**: WireGuard authentication alone insufficient for client access control

#### Operational Complexity
1. **Dual Configuration**: Each RAC needs both TCP and UDP tunnels
2. **Fallback Logic**: Need graceful fallback to SSH when Mosh fails
3. **Troubleshooting**: More complex network debugging

### 5. Alternative: SSH-Based Mosh

Instead of UDP tunneling, use Mosh's SSH ProxyCommand capability:

```bash
# ~/.ssh/config
Host wd-rac-*
    ProxyCommand ssh -p %p wd0.wsprdaemon.org nc %h %p
    ServerAliveInterval 30
    ServerAliveCountMax 6

# Connection command  
mosh --ssh="ssh -o ProxyCommand='ssh -p 35900 wd0.wsprdaemon.org nc %h 22'" \
     --server="mosh-server new" \
     localhost
```

**Problem**: This still requires direct UDP access to the target host, which defeats the FRP tunnel purpose.

## Recommendation

**Phase 1: Optimize Current SSH Setup**
- Enhance SSH connection persistence with optimized keepalive
- Improve tmux session management and auto-recovery
- Better connection multiplexing configuration

**Phase 2: Evaluate Mosh UDP Tunneling**
- Test FRP UDP tunneling in lab environment
- Measure performance improvements vs implementation complexity
- Assess security implications with security team

**Phase 3: Consider Alternatives**
- Evaluate Eternal Terminal (ET) - TCP-based persistent shell
- Consider custom UDP proxy solutions
- Look into SSH-based connection recovery tools

## Cost-Benefit Analysis

**Benefits of Mosh:**
- Better connection persistence through network changes
- Reduced perceived latency via local echo
- Automatic roaming capability

**Costs:**
- Significant infrastructure changes (server config, firewall rules)
- Increased complexity in troubleshooting
- More attack surface area
- Need for FRP version upgrade across all clients

**Assessment**: The benefits may not justify the implementation complexity and security risks, especially given the current system works reliably with tmux persistence.

## Conclusion

While technically feasible, adding Mosh support via FRP UDP tunneling would require substantial changes to the proven, secure architecture. The current SSH + tmux approach already provides good session persistence, and the Antarctica connection issues are more about total bandwidth/connectivity than just SSH resilience.

**Recommended approach**: Enhance the existing SSH-based solution with better configuration and automation rather than adding the complexity of UDP tunneling.