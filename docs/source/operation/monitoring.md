# System Monitoring

This guide covers monitoring WsprDaemon performance, health, and data quality to ensure optimal operation.

## Real-Time Monitoring

### System Status Dashboard

**Primary Status Command:**
```bash
# Comprehensive system overview
./wsprdaemon.sh -s

# Continuous monitoring (updates every 30 seconds)
watch -n 30 './wsprdaemon.sh -s'
```

**Key Status Indicators:**
- Process health (running/stopped/failed)
- Recent decode activity
- Upload success rates
- System resource usage
- Error conditions

### Process Monitoring

**Active Process Overview:**
```bash
# List all WsprDaemon processes
ps aux | grep wsprdaemon

# Process tree view
pstree -p $(pgrep -f wsprdaemon.sh)

# Resource usage by process
top -p $(pgrep -f wsprdaemon | tr '\n' ',' | sed 's/,$//')
```

**Job Status Monitoring:**
```bash
# Current job status
./wsprdaemon.sh -j s

# Detailed job information
./wsprdaemon.sh -j l

# Job restart history
./wsprdaemon.sh -j h
```

## Performance Metrics

### Decoding Performance

**Decode Success Rates:**
```bash
# Count successful decodes per band (last hour)
find /tmp/wsprdaemon/decoding.d -name "*.log" -mmin -60 \
  -exec grep -c "spots decoded" {} \; | awk '{sum+=$1} END {print "Total decodes:", sum}'

# Average decode time per band
grep "decode completed" /tmp/wsprdaemon/decoding.d/*/*/decoding.log | \
  awk -F'[: ]' '{band=$1; time=$NF; sum[band]+=time; count[band]++} 
  END {for(b in sum) printf "%s: %.2fs avg\n", b, sum[b]/count[b]}'
```

**Signal Quality Metrics:**
```bash
# SNR distribution analysis
grep "SNR:" /tmp/wsprdaemon/decoding.d/*/*/decoding.log | \
  awk '{print $NF}' | sort -n | \
  awk 'BEGIN{count=0; sum=0} {sum+=$1; count++; values[count]=$1} 
  END {print "Count:", count, "Mean:", sum/count, "Median:", values[int(count/2)]}'
```

### Upload Performance

**Upload Success Monitoring:**
```bash
# Recent upload success rate
find /tmp/wsprdaemon/uploads.d -name "*.log" -mmin -60 \
  -exec grep -E "(SUCCESS|FAILED)" {} \; | \
  awk '/SUCCESS/{s++} /FAILED/{f++} END {print "Success:", s, "Failed:", f, "Rate:", s/(s+f)*100"%"}'

# Upload queue status
find /tmp/wsprdaemon/uploads.d -name "*.txt" | wc -l
echo "Pending uploads: $(find /tmp/wsprdaemon/uploads.d -name '*.txt' | wc -l)"
```

**Network Performance:**
```bash
# Monitor network connections to wsprnet.org
netstat -an | grep :14236

# Upload bandwidth usage
iftop -i eth0 -f "port 14236"
```

### System Resource Monitoring

**CPU and Memory Usage:**
```bash
# WsprDaemon-specific resource usage
ps aux | grep wsprdaemon | \
  awk '{cpu+=$3; mem+=$4; vsz+=$5; rss+=$6} 
  END {printf "CPU: %.1f%% Memory: %.1f%% VSZ: %dMB RSS: %dMB\n", cpu, mem, vsz/1024, rss/1024}'

# System load average
uptime

# Memory pressure indicators
free -h
cat /proc/pressure/memory 2>/dev/null || echo "Memory pressure info not available"
```

**Disk I/O and Storage:**
```bash
# Disk usage monitoring
df -h /tmp/wsprdaemon ~/wsprdaemon

# I/O statistics for WsprDaemon directories
iostat -x 1 3

# Directory size tracking
du -sh /tmp/wsprdaemon/* ~/wsprdaemon/* 2>/dev/null | sort -hr
```

## Log Analysis and Alerting

### Automated Log Monitoring

**Error Detection Script:**
```bash
#!/bin/bash
# error_monitor.sh - Monitor for critical errors

LOG_FILES="/tmp/wsprdaemon/*.log"
ERROR_THRESHOLD=5
ALERT_EMAIL="admin@example.com"

# Count recent errors (last 10 minutes)
ERROR_COUNT=$(find /tmp/wsprdaemon -name "*.log" -mmin -10 \
  -exec grep -c "ERROR\|CRITICAL\|FATAL" {} \; | \
  awk '{sum+=$1} END {print sum}')

if [ ${ERROR_COUNT:-0} -gt $ERROR_THRESHOLD ]; then
    echo "High error rate detected: $ERROR_COUNT errors in last 10 minutes" | \
    mail -s "WsprDaemon Alert: High Error Rate" $ALERT_EMAIL
fi
```

**Performance Degradation Detection:**
```bash
#!/bin/bash
# performance_monitor.sh - Detect performance issues

# Check decode success rate (should be >80% during active periods)
DECODE_RATE=$(find /tmp/wsprdaemon/decoding.d -name "*.log" -mmin -30 \
  -exec grep -c "spots decoded\|no spots" {} \; | \
  awk 'NR%2==1{decoded=$1} NR%2==0{total=decoded+$1; if(total>0) rate=decoded/total*100; print rate}' | \
  awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print 0}')

if (( $(echo "$DECODE_RATE < 50" | bc -l) )); then
    echo "Low decode rate: $DECODE_RATE%" | \
    mail -s "WsprDaemon Alert: Low Decode Rate" admin@example.com
fi
```

### Log Rotation and Archival

**Automated Log Management:**
```bash
#!/bin/bash
# log_maintenance.sh - Automated log cleanup and archival

LOG_DIR="/tmp/wsprdaemon"
ARCHIVE_DIR="$HOME/wsprdaemon/archives"
RETENTION_DAYS=30

# Archive old logs
find $LOG_DIR -name "*.log" -mtime +1 -exec gzip {} \;
find $LOG_DIR -name "*.log.gz" -mtime +7 -exec mv {} $ARCHIVE_DIR/ \;

# Clean up very old archives
find $ARCHIVE_DIR -name "*.log.gz" -mtime +$RETENTION_DAYS -delete

# Rotate large current logs
find $LOG_DIR -name "*.log" -size +10M -exec logrotate -f {} \;
```

## Health Monitoring Dashboard

### Custom Monitoring Script

```bash
#!/bin/bash
# wsprdaemon_dashboard.sh - Comprehensive health dashboard

clear
echo "==============================================="
echo "        WsprDaemon Health Dashboard"
echo "        $(date)"
echo "==============================================="

# System Status
echo
echo "=== SYSTEM STATUS ==="
if pgrep -f wsprdaemon.sh > /dev/null; then
    echo "✓ WsprDaemon: RUNNING"
    PROCESS_COUNT=$(pgrep -f wsprdaemon | wc -l)
    echo "  Active processes: $PROCESS_COUNT"
else
    echo "✗ WsprDaemon: STOPPED"
fi

# Resource Usage
echo
echo "=== RESOURCE USAGE ==="
LOAD=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
echo "System load: $LOAD"

DISK_USAGE=$(df /tmp/wsprdaemon 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//')
if [ -n "$DISK_USAGE" ]; then
    if [ $DISK_USAGE -lt 80 ]; then
        echo "✓ Disk usage: ${DISK_USAGE}%"
    else
        echo "⚠ Disk usage: ${DISK_USAGE}% (HIGH)"
    fi
fi

# Recent Activity
echo
echo "=== RECENT ACTIVITY (Last 30 minutes) ==="
RECENT_DECODES=$(find /tmp/wsprdaemon/decoding.d -name "*.log" -mmin -30 \
  -exec grep -c "spots decoded" {} \; 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
echo "Successful decodes: $RECENT_DECODES"

RECENT_UPLOADS=$(find /tmp/wsprdaemon/uploads.d -name "*.log" -mmin -30 \
  -exec grep -c "SUCCESS" {} \; 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
echo "Successful uploads: $RECENT_UPLOADS"

# Error Summary
echo
echo "=== ERROR SUMMARY (Last hour) ==="
ERROR_COUNT=$(find /tmp/wsprdaemon -name "*.log" -mmin -60 \
  -exec grep -c "ERROR" {} \; 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
WARNING_COUNT=$(find /tmp/wsprdaemon -name "*.log" -mmin -60 \
  -exec grep -c "WARNING" {} \; 2>/dev/null | awk '{sum+=$1} END {print sum+0}')

if [ $ERROR_COUNT -eq 0 ]; then
    echo "✓ Errors: $ERROR_COUNT"
else
    echo "⚠ Errors: $ERROR_COUNT"
fi

if [ $WARNING_COUNT -lt 5 ]; then
    echo "✓ Warnings: $WARNING_COUNT"
else
    echo "⚠ Warnings: $WARNING_COUNT"
fi

echo
echo "==============================================="
```

## External Monitoring Integration

### Prometheus Metrics Export

**Metrics Collection Script:**
```bash
#!/bin/bash
# prometheus_exporter.sh - Export WsprDaemon metrics

METRICS_FILE="/tmp/wsprdaemon_metrics.prom"

cat > $METRICS_FILE << EOF
# HELP wsprdaemon_processes_total Number of active WsprDaemon processes
# TYPE wsprdaemon_processes_total gauge
wsprdaemon_processes_total $(pgrep -f wsprdaemon | wc -l)

# HELP wsprdaemon_decodes_total Total successful decodes in last hour
# TYPE wsprdaemon_decodes_total counter
wsprdaemon_decodes_total $(find /tmp/wsprdaemon/decoding.d -name "*.log" -mmin -60 -exec grep -c "spots decoded" {} \; | awk '{sum+=$1} END {print sum+0}')

# HELP wsprdaemon_uploads_total Total successful uploads in last hour
# TYPE wsprdaemon_uploads_total counter
wsprdaemon_uploads_total $(find /tmp/wsprdaemon/uploads.d -name "*.log" -mmin -60 -exec grep -c "SUCCESS" {} \; | awk '{sum+=$1} END {print sum+0}')

# HELP wsprdaemon_errors_total Total errors in last hour
# TYPE wsprdaemon_errors_total counter
wsprdaemon_errors_total $(find /tmp/wsprdaemon -name "*.log" -mmin -60 -exec grep -c "ERROR" {} \; | awk '{sum+=$1} END {print sum+0}')
EOF

# Serve metrics on port 9090
python3 -m http.server 9090 --directory $(dirname $METRICS_FILE) &
```

### MQTT Status Publishing

**MQTT Publisher Script:**
```bash
#!/bin/bash
# mqtt_publisher.sh - Publish status to MQTT broker

MQTT_BROKER="192.168.1.50"
MQTT_TOPIC="wsprdaemon/status"

# Collect status data
STATUS_JSON=$(cat << EOF
{
  "timestamp": "$(date -Iseconds)",
  "running": $(pgrep -f wsprdaemon.sh > /dev/null && echo "true" || echo "false"),
  "processes": $(pgrep -f wsprdaemon | wc -l),
  "recent_decodes": $(find /tmp/wsprdaemon/decoding.d -name "*.log" -mmin -10 -exec grep -c "spots decoded" {} \; | awk '{sum+=$1} END {print sum+0}'),
  "recent_uploads": $(find /tmp/wsprdaemon/uploads.d -name "*.log" -mmin -10 -exec grep -c "SUCCESS" {} \; | awk '{sum+=$1} END {print sum+0}'),
  "disk_usage": $(df /tmp/wsprdaemon 2>/dev/null | tail -1 | awk '{print $5}' | sed 's/%//' || echo "0")
}
EOF
)

# Publish to MQTT
mosquitto_pub -h $MQTT_BROKER -t $MQTT_TOPIC -m "$STATUS_JSON"
```

## Automated Monitoring Setup

### Cron Job Configuration

```bash
# Add to crontab (crontab -e)

# Health check every 5 minutes
*/5 * * * * /home/wsprdaemon/scripts/health_check.sh

# Performance monitoring every 15 minutes
*/15 * * * * /home/wsprdaemon/scripts/performance_monitor.sh

# Log maintenance daily at 2 AM
0 2 * * * /home/wsprdaemon/scripts/log_maintenance.sh

# Status dashboard update every minute
* * * * * /home/wsprdaemon/scripts/wsprdaemon_dashboard.sh > /tmp/wsprdaemon_status.txt

# MQTT status publishing every 5 minutes
*/5 * * * * /home/wsprdaemon/scripts/mqtt_publisher.sh
```

### Systemd Service for Monitoring

```ini
# /etc/systemd/system/wsprdaemon-monitor.service
[Unit]
Description=WsprDaemon Monitoring Service
After=wsprdaemon.service

[Service]
Type=simple
User=wsprdaemon
ExecStart=/home/wsprdaemon/scripts/continuous_monitor.sh
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
```

This comprehensive monitoring setup provides real-time visibility into WsprDaemon operation, automated alerting for issues, and integration with external monitoring systems.
