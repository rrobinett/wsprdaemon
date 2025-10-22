# Service Management

This guide covers starting, stopping, monitoring, and managing WsprDaemon services.

## Basic Service Control

### Starting WsprDaemon

**Interactive Start:**
```bash
# Start all configured services
./wsprdaemon.sh -a

# Start with increased verbosity for debugging
./wsprdaemon.sh -v -a
```

**Systemd Service Start:**
```bash
# Start as system service
sudo systemctl start wsprdaemon

# Enable automatic startup at boot
sudo systemctl enable wsprdaemon
```

### Stopping WsprDaemon

**Graceful Stop:**
```bash
# Stop all WsprDaemon processes gracefully
./wsprdaemon.sh -z

# Stop systemd service
sudo systemctl stop wsprdaemon
```

**Force Stop (Emergency):**
```bash
# Kill all WsprDaemon processes immediately
./wsprdaemon.sh -Z

# Force stop systemd service
sudo systemctl kill wsprdaemon
```

### Service Status

**Check Overall Status:**
```bash
# Display comprehensive status
./wsprdaemon.sh -s

# Check systemd service status
sudo systemctl status wsprdaemon
```

**Detailed Process Information:**
```bash
# Show all WsprDaemon processes
ps aux | grep wsprdaemon

# Show process tree
pstree -p $(pgrep -f wsprdaemon.sh)
```

## Service Components

### Core Processes

WsprDaemon runs multiple interconnected processes:

1. **Main Daemon** (`wsprdaemon.sh -A`)
   - Master process coordinating all operations
   - Manages configuration and process lifecycle

2. **Recording Daemons** (per receiver/band)
   - Capture audio from SDR receivers
   - Create 2-minute WAV files for processing

3. **Decoding Daemons** (per receiver/band)
   - Process WAV files through wsprd
   - Extract WSPR spots and noise measurements

4. **Posting Daemons** (per receiver/band)
   - Merge spots from multiple receivers
   - Upload to wsprnet.org and other services

5. **Watchdog Process**
   - Monitor all daemons for failures
   - Restart failed processes automatically

### Process Monitoring

**View Active Processes:**
```bash
# List all WsprDaemon jobs
./wsprdaemon.sh -j s

# Show detailed job information
./wsprdaemon.sh -j l
```

**Monitor Process Health:**
```bash
# Continuous status monitoring
watch -n 30 './wsprdaemon.sh -s'

# Monitor log files in real-time
tail -f /tmp/wsprdaemon/wsprdaemon.log
```

## Configuration Management

### Runtime Configuration Changes

**Reload Configuration:**
```bash
# Stop services
./wsprdaemon.sh -z

# Edit configuration
vim wsprdaemon.conf

# Restart with new configuration
./wsprdaemon.sh -a
```

**Validate Configuration:**
```bash
# Check configuration syntax
./wsprdaemon.sh -s | grep -i error

# Test receiver connectivity
./wsprdaemon.sh -i
```

### Service Dependencies

**Required Services:**
- Network connectivity
- Time synchronization (NTP)
- Audio system (ALSA/PulseAudio)
- USB subsystem (for SDR hardware)

**Check Dependencies:**
```bash
# Network connectivity
ping -c 3 wsprnet.org

# Time synchronization
timedatectl status

# USB devices
lsusb | grep -E "(RTL|RX888|AirSpy)"

# Audio system
arecord -l
```

## Logging and Monitoring

### Log File Locations

**Main Logs:**
```
/tmp/wsprdaemon/wsprdaemon.log          # Main daemon log
/tmp/wsprdaemon/watchdog.log            # Watchdog process log
~/wsprdaemon/wsprdaemon.log             # Persistent main log
```

**Per-Service Logs:**
```
/tmp/wsprdaemon/recording.d/RX/BAND/    # Recording daemon logs
/tmp/wsprdaemon/decoding.d/RX/BAND/     # Decoding daemon logs
/tmp/wsprdaemon/posting.d/RX/BAND/      # Posting daemon logs
/tmp/wsprdaemon/uploads.d/              # Upload status logs
```

### Log Analysis

**View Recent Activity:**
```bash
# Last 100 lines of main log
tail -100 /tmp/wsprdaemon/wsprdaemon.log

# Search for errors
grep -i error /tmp/wsprdaemon/*.log

# Monitor upload success
grep -i success /tmp/wsprdaemon/uploads.d/*/*.log
```

**Log Rotation and Cleanup:**
```bash
# View log file sizes
du -sh /tmp/wsprdaemon/*.log ~/wsprdaemon/*.log

# Manual log rotation (if needed)
./wsprdaemon.sh -l rotate
```

## Performance Monitoring

### System Resource Usage

**CPU and Memory:**
```bash
# Monitor resource usage
htop

# WsprDaemon-specific resource usage
ps aux | grep wsprdaemon | awk '{sum+=$3} END {print "CPU:", sum"%"}'
ps aux | grep wsprdaemon | awk '{sum+=$4} END {print "Memory:", sum"%"}'
```

**Disk I/O:**
```bash
# Monitor disk usage
df -h /tmp/wsprdaemon ~/wsprdaemon

# I/O statistics
iostat -x 1 5
```

**Network Activity:**
```bash
# Monitor network connections
netstat -an | grep :14236  # wsprnet.org uploads

# Network traffic
iftop -i eth0
```

### Performance Metrics

**Decoding Performance:**
```bash
# Count successful decodes per hour
grep "spots decoded" /tmp/wsprdaemon/decoding.d/*/*/decoding.log | \
  awk -F: '{print $1}' | sort | uniq -c

# Upload success rate
grep -c "SUCCESS" /tmp/wsprdaemon/uploads.d/*/*.log
```

## Troubleshooting Service Issues

### Common Service Problems

**Service Won't Start:**
1. Check configuration file syntax
2. Verify receiver connectivity
3. Ensure sufficient disk space
4. Check system dependencies

**Service Stops Unexpectedly:**
1. Review error logs
2. Check system resource limits
3. Verify hardware connectivity
4. Monitor for system-level issues

**Poor Performance:**
1. Monitor CPU and memory usage
2. Check disk I/O performance
3. Verify network connectivity
4. Review receiver signal quality

### Diagnostic Commands

**System Health Check:**
```bash
# Comprehensive system check
./wsprdaemon.sh -s -v

# Hardware connectivity
./wsprdaemon.sh -i

# Configuration validation
./wsprdaemon.sh -j s | grep -i error
```

**Service Recovery:**
```bash
# Restart specific receiver/band
./wsprdaemon.sh -j r RECEIVER,BAND

# Full service restart
./wsprdaemon.sh -z && sleep 5 && ./wsprdaemon.sh -a

# Reset to clean state
./wsprdaemon.sh -Z && rm -rf /tmp/wsprdaemon/* && ./wsprdaemon.sh -a
```

## Automated Service Management

### Systemd Integration

**Service File Location:**
```
/etc/systemd/system/wsprdaemon.service
```

**Service Management:**
```bash
# Reload systemd configuration
sudo systemctl daemon-reload

# Enable automatic startup
sudo systemctl enable wsprdaemon

# Start/stop/restart service
sudo systemctl start wsprdaemon
sudo systemctl stop wsprdaemon
sudo systemctl restart wsprdaemon

# View service logs
journalctl -u wsprdaemon -f
```

### Monitoring and Alerting

**Health Check Script:**
```bash
#!/bin/bash
# Simple health check script
if ! ./wsprdaemon.sh -s | grep -q "running"; then
    echo "WsprDaemon not running - attempting restart"
    ./wsprdaemon.sh -a
    # Send alert email/notification here
fi
```

**Cron Job for Monitoring:**
```bash
# Add to crontab (crontab -e)
*/5 * * * * /home/wsprdaemon/wsprdaemon/health_check.sh
```

## Best Practices

### Service Management

1. **Always use graceful shutdown** (`-z`) before restart
2. **Monitor logs regularly** for early problem detection
3. **Keep configuration backed up** before making changes
4. **Test configuration changes** in non-production environment
5. **Document custom modifications** for future reference

### Performance Optimization

1. **Use tmpfs** for temporary files when possible
2. **Monitor resource usage** during peak activity
3. **Implement log rotation** to prevent disk filling
4. **Schedule maintenance** during low-activity periods
5. **Keep system updated** for security and performance

### Reliability

1. **Enable automatic startup** with systemd
2. **Implement monitoring** and alerting
3. **Regular backup** of configuration and logs
4. **Test recovery procedures** periodically
5. **Document operational procedures** for other operators
