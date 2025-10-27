# Diagnostic Tools

WsprDaemon includes several built-in diagnostic tools and commands to help identify and resolve issues.

## Built-in Diagnostic Commands

### Status and Information Commands

**System Status:**
```bash
# Comprehensive system status
./wsprdaemon.sh -s

# Verbose status with detailed information
./wsprdaemon.sh -v -s

# Show version information
./wsprdaemon.sh -V
```

**Job Management:**
```bash
# List all running jobs
./wsprdaemon.sh -j s

# List jobs with detailed information
./wsprdaemon.sh -j l

# Show job history
./wsprdaemon.sh -j h
```

**Device Information:**
```bash
# List available receivers and audio devices
./wsprdaemon.sh -i

# Test receiver connectivity
./wsprdaemon.sh -i -v
```

### Log Analysis Tools

**Log Viewing:**
```bash
# View recent log entries
./wsprdaemon.sh -l recent

# View specific log file
./wsprdaemon.sh -l /tmp/wsprdaemon/wsprdaemon.log

# Search logs for errors
./wsprdaemon.sh -l error
```

**Log Statistics:**
```bash
# Count log entries by type
grep -c "ERROR\|WARNING\|INFO" /tmp/wsprdaemon/*.log

# Show upload success rate
find /tmp/wsprdaemon/uploads.d -name "*.log" -exec grep -l "SUCCESS" {} \; | wc -l
```

## System Diagnostic Commands

### Hardware Diagnostics

**USB Device Detection:**
```bash
# List USB devices
lsusb

# Monitor USB device changes
udevadm monitor --subsystem-match=usb

# Check USB device permissions
ls -la /dev/bus/usb/*/*
```

**Audio System Diagnostics:**
```bash
# List audio input devices
arecord -l

# Test audio recording
arecord -D hw:0,0 -f S16_LE -r 12000 -c 1 -d 5 test.wav

# Check audio levels
sox test.wav -n stats
```

**Network Connectivity:**
```bash
# Test internet connectivity
ping -c 3 wsprnet.org
ping -c 3 8.8.8.8

# Check DNS resolution
nslookup wsprnet.org

# Test specific ports
telnet wsprnet.org 80
```

### System Resource Monitoring

**CPU and Memory:**
```bash
# Real-time system monitor
htop

# Memory usage details
free -h
cat /proc/meminfo

# CPU information
lscpu
cat /proc/cpuinfo
```

**Disk and I/O:**
```bash
# Disk space usage
df -h

# Directory sizes
du -sh /tmp/wsprdaemon/* ~/wsprdaemon/*

# I/O statistics
iostat -x 1 5
iotop
```

**Process Monitoring:**
```bash
# WsprDaemon processes
ps aux | grep wsprdaemon

# Process tree
pstree -p $(pgrep -f wsprdaemon)

# Resource usage by process
top -p $(pgrep -f wsprdaemon | tr '\n' ',' | sed 's/,$//')
```

## Configuration Diagnostics

### Configuration Validation

**Syntax Checking:**
```bash
# Check configuration file syntax
bash -n wsprdaemon.conf

# Validate receiver definitions
./wsprdaemon.sh -s | grep -i "receiver"

# Check schedule definitions
./wsprdaemon.sh -s | grep -i "schedule"
```

**Configuration Testing:**
```bash
# Test configuration without starting services
./wsprdaemon.sh -s -v | grep -E "(ERROR|WARNING)"

# Validate receiver connectivity
for rx in $(./wsprdaemon.sh -i | grep -v "Audio"); do
    echo "Testing $rx..."
    # Add specific receiver tests here
done
```

### Permission Diagnostics

**File Permissions:**
```bash
# Check configuration file permissions
ls -la wsprdaemon.conf

# Check directory permissions
ls -la /tmp/wsprdaemon/
ls -la ~/wsprdaemon/

# Check executable permissions
ls -la wsprdaemon.sh
```

**User and Group Membership:**
```bash
# Check current user
whoami
id

# Check group memberships
groups
grep $(whoami) /etc/group
```

## Network Diagnostics

### Connectivity Testing

**Basic Connectivity:**
```bash
# Test internet connection
curl -I http://wsprnet.org

# Test specific services
curl -I http://graphs.wsprdaemon.org
curl -I http://pskreporter.info
```

**Multicast Testing (for KA9Q-radio):**
```bash
# Check multicast routing
ip route show | grep 224

# Monitor multicast traffic
tcpdump -i eth0 multicast

# Test multicast reception
socat UDP4-RECV:5004,ip-add-membership=239.1.2.3:eth0 -
```

### Upload Diagnostics

**Upload Status:**
```bash
# Check upload queue
ls -la /tmp/wsprdaemon/uploads.d/

# Monitor upload attempts
tail -f /tmp/wsprdaemon/uploads.d/*/upload.log

# Test manual upload
curl -X POST -F "file=@test_spot.txt" http://wsprnet.org/post
```

## Performance Diagnostics

### Decoding Performance

**Decode Statistics:**
```bash
# Count successful decodes
find /tmp/wsprdaemon/decoding.d -name "*.log" -exec grep -c "spots decoded" {} \;

# Average decode time
grep "decode time" /tmp/wsprdaemon/decoding.d/*/*/decoding.log | \
  awk '{sum+=$NF; count++} END {print "Average:", sum/count, "seconds"}'
```

**Audio Quality Assessment:**
```bash
# Check for audio clipping
find /tmp/wsprdaemon/recording.d -name "*.wav" -exec sox {} -n stats \; 2>&1 | \
  grep -E "(Maximum amplitude|Minimum amplitude)"

# Analyze noise levels
python3 noise_plot.py --analyze /tmp/wsprdaemon/recording.d/*/20m/*.wav
```

### System Performance

**Resource Utilization:**
```bash
# CPU usage by WsprDaemon
ps aux | grep wsprdaemon | awk '{cpu+=$3; mem+=$4} END {printf "CPU: %.1f%%, Memory: %.1f%%\n", cpu, mem}'

# I/O wait time
iostat 1 5 | grep -E "avg-cpu|%iowait"

# Memory pressure
cat /proc/pressure/memory
```

## Automated Diagnostic Scripts

### Health Check Script

```bash
#!/bin/bash
# wsprdaemon_health_check.sh

echo "=== WsprDaemon Health Check ==="
echo "Date: $(date)"
echo

# Check if WsprDaemon is running
if pgrep -f wsprdaemon.sh > /dev/null; then
    echo "✓ WsprDaemon is running"
else
    echo "✗ WsprDaemon is not running"
fi

# Check disk space
DISK_USAGE=$(df /tmp/wsprdaemon | tail -1 | awk '{print $5}' | sed 's/%//')
if [ $DISK_USAGE -lt 90 ]; then
    echo "✓ Disk usage OK ($DISK_USAGE%)"
else
    echo "✗ Disk usage high ($DISK_USAGE%)"
fi

# Check recent uploads
RECENT_UPLOADS=$(find /tmp/wsprdaemon/uploads.d -name "*.log" -mmin -10 -exec grep -l "SUCCESS" {} \; | wc -l)
if [ $RECENT_UPLOADS -gt 0 ]; then
    echo "✓ Recent uploads successful ($RECENT_UPLOADS)"
else
    echo "✗ No recent successful uploads"
fi

# Check for errors in logs
ERROR_COUNT=$(grep -c "ERROR" /tmp/wsprdaemon/*.log 2>/dev/null | awk -F: '{sum+=$2} END {print sum}')
if [ ${ERROR_COUNT:-0} -eq 0 ]; then
    echo "✓ No recent errors"
else
    echo "⚠ Found $ERROR_COUNT recent errors"
fi

echo
echo "=== End Health Check ==="
```

### Performance Monitor Script

```bash
#!/bin/bash
# wsprdaemon_performance.sh

echo "=== WsprDaemon Performance Monitor ==="

# CPU and Memory usage
echo "Resource Usage:"
ps aux | grep wsprdaemon | awk '
BEGIN {cpu=0; mem=0; count=0}
{cpu+=$3; mem+=$4; count++}
END {printf "  Processes: %d\n  CPU: %.1f%%\n  Memory: %.1f%%\n", count, cpu, mem}'

# Decode performance
echo
echo "Decode Performance (last hour):"
DECODES=$(find /tmp/wsprdaemon/decoding.d -name "*.log" -mmin -60 -exec grep -c "spots decoded" {} \; | awk '{sum+=$1} END {print sum}')
echo "  Total decodes: ${DECODES:-0}"

# Upload performance
echo
echo "Upload Performance (last hour):"
UPLOADS=$(find /tmp/wsprdaemon/uploads.d -name "*.log" -mmin -60 -exec grep -c "SUCCESS" {} \; | awk '{sum+=$1} END {print sum}')
echo "  Successful uploads: ${UPLOADS:-0}"

# Disk I/O
echo
echo "Disk I/O:"
iostat -x 1 1 | grep -E "(Device|tmp|home)" | tail -2
```

## Troubleshooting Workflows

### Systematic Diagnosis

**Step 1: Basic System Check**
```bash
# System status
./wsprdaemon.sh -s

# Resource availability
df -h && free -h

# Process status
ps aux | grep wsprdaemon
```

**Step 2: Configuration Validation**
```bash
# Configuration syntax
bash -n wsprdaemon.conf

# Receiver connectivity
./wsprdaemon.sh -i

# Network connectivity
ping -c 3 wsprnet.org
```

**Step 3: Log Analysis**
```bash
# Recent errors
grep -i error /tmp/wsprdaemon/*.log | tail -20

# Upload status
find /tmp/wsprdaemon/uploads.d -name "*.log" -exec tail -5 {} \;

# Decode performance
grep "spots decoded" /tmp/wsprdaemon/decoding.d/*/*/decoding.log | tail -10
```

### Common Diagnostic Patterns

**No Spots Being Decoded:**
1. Check audio input levels
2. Verify receiver connectivity
3. Confirm time synchronization
4. Validate frequency settings

**Upload Failures:**
1. Test internet connectivity
2. Check wsprnet.org accessibility
3. Verify callsign and grid settings
4. Review upload logs for error messages

**High Resource Usage:**
1. Monitor CPU and memory usage
2. Check for runaway processes
3. Analyze I/O patterns
4. Review configuration for optimization opportunities

These diagnostic tools provide comprehensive visibility into WsprDaemon operation and help quickly identify the root cause of issues.
