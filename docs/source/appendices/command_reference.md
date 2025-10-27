# Command Reference

Complete reference for all WsprDaemon command-line options and utilities.

## Main Command: wsprdaemon.sh

### Synopsis
```bash
./wsprdaemon.sh [OPTIONS]
```

### Options

#### Service Control
- **`-a`** - Start WsprDaemon services (interactive mode)
- **`-A`** - Start WsprDaemon as daemon with optional startup delay
- **`-z`** - Stop WsprDaemon services gracefully
- **`-Z`** - Force stop all WsprDaemon processes immediately

#### Status and Information
- **`-s`** - Show comprehensive system status
- **`-V`** - Display version information
- **`-h`** - Show help message and usage information
- **`-i`** - List available receivers and audio devices

#### Job Management
- **`-j COMMAND`** - Job management commands:
  - `s` - Show status of all jobs
  - `l` - List jobs with detailed information
  - `h` - Show job history
  - `r RECEIVER,BAND` - Restart specific receiver/band job

#### Logging and Debugging
- **`-l OPTION`** - Log file operations:
  - `recent` - View recent log entries
  - `error` - Search logs for error messages
  - `rotate` - Force log rotation
  - `PATH` - View specific log file
- **`-v`** - Increase verbosity level (can be used multiple times)
- **`-d`** - Increment debug verbosity
- **`-D`** - Decrement debug verbosity

#### Recording and Playback
- **`-r RECEIVER[,BAND]`** - Start WAV file recording for specified receiver/band
- **`-p`** - Generate noise plots from recorded data

#### Upload Management
- **`-U COMMAND`** - Upload control commands:
  - `start` - Start upload services
  - `stop` - Stop upload services
  - `status` - Show upload status
  - `flush` - Force upload of queued data

#### Advanced Features
- **`-g OPTION`** - GRAPE system commands:
  - `start` - Start GRAPE recording
  - `stop` - Stop GRAPE recording
  - `status` - Show GRAPE status
- **`-u COMMAND`** - Upload server commands (for server installations)
- **`-w COMMAND`** - Watchdog commands:
  - `start` - Start watchdog process
  - `stop` - Stop watchdog process
  - `status` - Show watchdog status

### Examples

**Basic Operations:**
```bash
# Start WsprDaemon
./wsprdaemon.sh -a

# Check status with verbose output
./wsprdaemon.sh -v -s

# Stop all services
./wsprdaemon.sh -z

# Force stop if graceful stop fails
./wsprdaemon.sh -Z
```

**Debugging and Monitoring:**
```bash
# Show detailed job information
./wsprdaemon.sh -j l

# View recent errors
./wsprdaemon.sh -l error

# Increase verbosity and check status
./wsprdaemon.sh -v -v -s

# Restart specific receiver/band
./wsprdaemon.sh -j r kiwi1,40m
```

**Recording and Analysis:**
```bash
# Record audio from specific receiver
./wsprdaemon.sh -r kiwi1,20m

# Generate noise plots
./wsprdaemon.sh -p

# Start GRAPE recording
./wsprdaemon.sh -g start
```

## Configuration Utilities

### Configuration Validation
```bash
# Check configuration file syntax
bash -n wsprdaemon.conf

# Validate configuration with WsprDaemon
./wsprdaemon.sh -s | grep -E "(ERROR|WARNING)"
```

### Receiver Testing
```bash
# Test all configured receivers
./wsprdaemon.sh -i

# Test specific receiver connectivity
ping -c 3 RECEIVER_IP
telnet RECEIVER_IP PORT
```

## Log Analysis Commands

### Log File Locations
```bash
# Main logs
/tmp/wsprdaemon/wsprdaemon.log          # Primary daemon log
/tmp/wsprdaemon/watchdog.log            # Watchdog process log
~/wsprdaemon/wsprdaemon.log             # Persistent main log

# Per-service logs
/tmp/wsprdaemon/recording.d/RX/BAND/    # Recording daemon logs
/tmp/wsprdaemon/decoding.d/RX/BAND/     # Decoding daemon logs
/tmp/wsprdaemon/posting.d/RX/BAND/      # Posting daemon logs
/tmp/wsprdaemon/uploads.d/              # Upload status logs
```

### Log Analysis Examples
```bash
# View recent activity
tail -100 /tmp/wsprdaemon/wsprdaemon.log

# Search for errors across all logs
grep -r "ERROR" /tmp/wsprdaemon/

# Monitor real-time log activity
tail -f /tmp/wsprdaemon/wsprdaemon.log

# Count successful uploads
find /tmp/wsprdaemon/uploads.d -name "*.log" -exec grep -c "SUCCESS" {} \;

# Analyze decode performance
grep "spots decoded" /tmp/wsprdaemon/decoding.d/*/*/decoding.log | \
  awk '{print $1, $NF}' | sort
```

## System Integration Commands

### Systemd Service Management
```bash
# Service control
sudo systemctl start wsprdaemon
sudo systemctl stop wsprdaemon
sudo systemctl restart wsprdaemon
sudo systemctl status wsprdaemon

# Enable/disable automatic startup
sudo systemctl enable wsprdaemon
sudo systemctl disable wsprdaemon

# View service logs
journalctl -u wsprdaemon -f
journalctl -u wsprdaemon --since "1 hour ago"
```

### Process Management
```bash
# List WsprDaemon processes
ps aux | grep wsprdaemon
pgrep -f wsprdaemon

# Process tree view
pstree -p $(pgrep -f wsprdaemon.sh)

# Kill specific process
kill -TERM PID
kill -KILL PID  # Force kill if needed
```

## Diagnostic Commands

### System Health Checks
```bash
# Check system resources
free -h                    # Memory usage
df -h                      # Disk space
uptime                     # System load
iostat -x 1 5             # I/O statistics

# Network connectivity
ping -c 3 wsprnet.org
curl -I http://wsprnet.org
netstat -an | grep :14236  # wsprnet.org connections
```

### Hardware Diagnostics
```bash
# USB devices (for SDR hardware)
lsusb
lsusb -t

# Audio devices
arecord -l
aplay -l

# Network interfaces
ip addr show
ip route show
```

### Performance Analysis
```bash
# CPU usage by WsprDaemon
ps aux | grep wsprdaemon | awk '{cpu+=$3} END {print "Total CPU:", cpu"%"}'

# Memory usage by WsprDaemon
ps aux | grep wsprdaemon | awk '{mem+=$4} END {print "Total Memory:", mem"%"}'

# Disk I/O for WsprDaemon directories
iotop -a -o -d 1

# Network traffic analysis
iftop -i eth0
tcpdump -i eth0 host wsprnet.org
```

## Maintenance Commands

### Log Maintenance
```bash
# Rotate logs manually
./wsprdaemon.sh -l rotate

# Clean old temporary files
find /tmp/wsprdaemon -type f -mtime +7 -delete

# Archive old logs
tar -czf ~/wsprdaemon/archives/logs_$(date +%Y%m).tar.gz \
  ~/wsprdaemon/logs/*.log.old
```

### Configuration Backup
```bash
# Backup current configuration
cp wsprdaemon.conf wsprdaemon.conf.backup.$(date +%Y%m%d)

# Create complete backup
tar -czf wsprdaemon_backup_$(date +%Y%m%d).tar.gz \
  wsprdaemon.conf *.sh logs/ archives/
```

### System Cleanup
```bash
# Clean temporary files
rm -rf /tmp/wsprdaemon/tmp.*
rm -rf /tmp/wsprdaemon/recording.d/*/tmp.*

# Reset to clean state (stops all processes)
./wsprdaemon.sh -Z
rm -rf /tmp/wsprdaemon/*
./wsprdaemon.sh -a
```

## Environment Variables

### Configuration Variables
- **`WSPRDAEMON_ROOT_DIR`** - Installation directory path
- **`WSPRDAEMON_TMP_DIR`** - Temporary files directory (default: /tmp/wsprdaemon)
- **`WSPRDAEMON_CONFIG_FILE`** - Configuration file path
- **`WD_LOGFILE`** - Log file path for current session
- **`WD_LOGFILE_SIZE_MAX`** - Maximum log file size (default: 1000000 bytes)

### Runtime Variables
- **`verbosity`** - Current verbosity level (0-4)
- **`WD_TIME_FMT`** - Time format for log entries
- **`LC_ALL`** - Locale setting (set to "C" for consistent number formatting)

### Usage Examples
```bash
# Run with custom temporary directory
WSPRDAEMON_TMP_DIR=/mnt/ramdisk/wsprdaemon ./wsprdaemon.sh -a

# Increase verbosity for debugging
verbosity=3 ./wsprdaemon.sh -s

# Use custom configuration file
WSPRDAEMON_CONFIG_FILE=./test.conf ./wsprdaemon.sh -s
```

## Exit Codes

### Standard Exit Codes
- **0** - Success
- **1** - General error
- **2** - Configuration error
- **3** - Hardware/connectivity error
- **4** - Permission error
- **5** - Resource unavailable (disk space, memory, etc.)

### Signal Handling
- **SIGTERM (15)** - Graceful shutdown
- **SIGINT (2)** - Interrupt (Ctrl+C)
- **SIGHUP (1)** - Reload configuration
- **SIGUSR1 (10)** - Increase verbosity
- **SIGUSR2 (12)** - Decrease verbosity

This command reference provides comprehensive coverage of all WsprDaemon command-line options and related system commands for effective operation and troubleshooting.
