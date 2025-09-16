
# Computer Issues

## CPUs

### Ryzen 5560, 5700, 5800, 5825, and above
Known to work running both WD and radiod.

### Intel

### Raspberry Pi (4 or 5)
Can work in constrained use -- but not supporting the full bandwidth of a RX888 plus WD.
Known to work with RTL-SDR, funcube dongle, AirspyR2, etc.

### Orange Pi-5
Known to work running both WD and radiod if configured correctly.

## Memory

### RAM Requirements

**Minimum Requirements:**
- **Basic Operation**: 4GB RAM for single-band WSPR decoding
- **Multi-band**: 8GB RAM for 6+ simultaneous bands
- **High-throughput**: 16GB+ RAM for RX888 with full spectrum processing

**Memory Usage Patterns:**
- Each WSPR band requires approximately 200-500MB RAM
- KA9Q-radio processes consume additional 100-200MB per receiver
- Noise analysis and graphing add 50-100MB overhead
- Buffer space for audio processing requires 100-200MB per active receiver

**Optimization Tips:**
- Use tmpfs for `/tmp/wsprdaemon/` to improve I/O performance
- Monitor memory usage with `free -h` and `htop`
- Configure swap space (4-8GB) for systems with limited RAM
- Consider memory-mapped files for large datasets

### Memory Configuration

**tmpfs Setup for Performance:**
```bash
# Add to /etc/fstab for persistent tmpfs
tmpfs /tmp/wsprdaemon tmpfs defaults,size=2G,uid=wsprdaemon,gid=wsprdaemon 0 0

# Mount immediately
sudo mount -a
```

**Swap Configuration:**
```bash
# Check current swap
swapon --show

# Create swap file if needed
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

## Disk Storage

### Storage Requirements

**Minimum Storage:**
- **System Installation**: 10GB for WsprDaemon and dependencies
- **Log Storage**: 1-5GB per month depending on verbosity and band count
- **Temporary Files**: 2-4GB for active processing buffers
- **Archive Storage**: Variable based on data retention requirements

**Recommended Storage:**
- **Root Partition**: 50GB minimum for system and software
- **Data Partition**: 100GB+ for logs, archives, and noise data
- **Backup Storage**: External storage for configuration and historical data

### Storage Performance Considerations

**I/O Requirements:**
- **Sequential Write**: 10-50 MB/s for continuous logging
- **Random I/O**: Moderate for configuration and status files
- **Burst Performance**: High during 2-minute WSPR decode cycles

**Storage Types:**
- **SSD Recommended**: For `/tmp/wsprdaemon/` and active logs
- **HDD Acceptable**: For long-term archives and backups
- **Network Storage**: Suitable for archives but not active processing

### Directory Structure and Sizing

**Active Processing Directories:**
```
/tmp/wsprdaemon/                    # 2-4GB (tmpfs recommended)
├── recording.d/                    # Audio buffers (500MB-2GB)
├── decoding.d/                     # Decode processing (200MB-1GB)
├── posting.d/                      # Upload queues (100MB-500MB)
└── uploads.d/                      # Upload staging (50MB-200MB)
```

**Persistent Storage:**
```
~/wsprdaemon/                       # 1-10GB depending on retention
├── logs/                           # Historical logs (100MB-5GB)
├── noise_graphs/                   # Noise measurement data (50MB-2GB)
├── archives/                       # Long-term data storage (variable)
└── backups/                        # Configuration backups (10MB-100MB)
```

### Storage Maintenance

**Log Rotation:**
- WsprDaemon automatically rotates logs when they exceed configured size limits
- Default maximum log file size: 1MB
- Older logs are compressed and archived
- Configure retention period based on available storage

**Cleanup Procedures:**
```bash
# Manual cleanup of old temporary files
find /tmp/wsprdaemon -type f -mtime +7 -delete

# Archive old logs
tar -czf ~/wsprdaemon/archives/logs_$(date +%Y%m).tar.gz ~/wsprdaemon/logs/*.log.old

# Monitor disk usage
df -h /tmp/wsprdaemon ~/wsprdaemon
```

**Automated Maintenance:**
- Set up cron jobs for regular cleanup
- Monitor disk space with system alerts
- Implement automatic archive rotation
- Configure backup procedures for critical data

### Performance Optimization

**File System Selection:**
- **ext4**: Good general-purpose performance
- **xfs**: Better for large files and high I/O
- **btrfs**: Advanced features but higher overhead
- **tmpfs**: Essential for high-performance temporary storage

**Mount Options:**
```bash
# High-performance options for data partition
/dev/sdb1 /home/wsprdaemon/data ext4 defaults,noatime,data=writeback 0 2

# tmpfs for temporary files
tmpfs /tmp/wsprdaemon tmpfs defaults,size=4G,noatime 0 0
```

### Monitoring and Alerts

**Disk Space Monitoring:**
```bash
# Check available space
df -h

# Monitor I/O performance
iostat -x 1

# Track directory sizes
du -sh /tmp/wsprdaemon/* ~/wsprdaemon/*
```

**Alert Thresholds:**
- Warning: 80% disk usage
- Critical: 90% disk usage
- Emergency cleanup: 95% disk usage

Configure system monitoring to alert when storage thresholds are exceeded to prevent service interruption.
