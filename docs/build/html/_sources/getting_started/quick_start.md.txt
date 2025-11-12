# Quick Start Guide

Get WsprDaemon running in 15 minutes with this streamlined setup guide for experienced users.

## Prerequisites Check

Before starting, ensure you have:
- Debian 12+ (preferred), otherwise Ubuntu 24.04 LTS, 22.04 LTS, or Linux Mint.
- Sudo privileges configured
- SDR hardware (KiwiSDR, RX888, RTL-SDR, etc.) connected and accessible
- GPSDO (e.g., Leo Bodnar)
- Antenna system with appropriate filtering
- Stable internet connection

## 1. System Preparation (2 minutes)

```bash
# Update system packages
sudo apt update && sudo apt upgrade -y

# Install essential dependencies
sudo apt install -y git build-essential cmake gcc libfftw3-dev \
    libusb-1.0-0-dev portaudio19-dev sox libsox-fmt-all \
    rsync tmux vim net-tools

# Create wsprdaemon user (recommended)
sudo adduser wsprdaemon
sudo usermod -a -G sudo,plugdev wsprdaemon

# Switch to wsprdaemon user
sudo su - wsprdaemon

# Ensure you have moved to the /home/wsprdaemon directory.
cd ~ 
```

## 2. Download and Install (5 minutes)

```bash
# Clone the repository
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon

# Run initial setup (installs dependencies and compiles components)
./wsprdaemon.sh -h
```

The setup script will automatically:
- Install ka9q-radio and other dependencies
- Compile necessary components
- Set up directory structure
- Configure system services

## 3. Basic Configuration (5 minutes)

### Create Configuration File
```bash
# Copy template configuration
cp wd_template.conf wsprdaemon.conf

# Edit configuration (use your preferred editor)
vim wsprdaemon.conf
```

### Essential Configuration Settings

**Minimum required configuration:**

```bash
# Your station information
WSPR_CALL="YOUR_CALL"
WSPR_GRID="YOUR_GRID"

# Define at least one receiver
RECEIVER_LIST=(
    "rx1,IP_ADDRESS:PORT"
)

# Define a basic schedule
WSPR_SCHEDULE=(
    "rx1,40m,WSPR,00:00,23:59"
    "rx1,20m,WSPR,06:00,18:00"
)
```

**For KiwiSDR:**
```bash
RECEIVER_LIST=(
    "kiwi1,192.168.1.100:8073"
)
```

**For RX888 with ka9q-radio:**
```bash
RECEIVER_LIST=(
    "rx888,239.1.2.3:5004"
)
```

## 4. Start WsprDaemon (1 minute)

```bash
# Start WsprDaemon
./wsprdaemon.sh -a

# Check status
./wsprdaemon.sh -s
```

## 5. Verify Operation (2 minutes)

### Check System Status
```bash
# View running processes
./wsprdaemon.sh -s

# Monitor logs
tail -f /tmp/wsprdaemon/wsprdaemon.log
```

### Verify Spot Upload
- Check your callsign appears on [wsprnet.org](http://wsprnet.org)
- Look for "SUCCESS" messages in upload logs
- Monitor `/tmp/wsprdaemon/uploads.d/` directory

## Common Quick Configurations

### Single KiwiSDR, Multiple Bands
```bash
RECEIVER_LIST=(
    "kiwi1,192.168.1.100:8073"
)

WSPR_SCHEDULE=(
    "kiwi1,160m,WSPR,00:00,06:00"
    "kiwi1,80m,WSPR,06:00,12:00"
    "kiwi1,40m,WSPR,12:00,18:00"
    "kiwi1,20m,WSPR,18:00,24:00"
)
```

### RX888 with Multiple Bands
```bash
RECEIVER_LIST=(
    "rx888,239.1.2.3:5004"
)

WSPR_SCHEDULE=(
    "rx888,160m,WSPR,00:00,23:59"
    "rx888,80m,WSPR,00:00,23:59"
    "rx888,40m,WSPR,00:00,23:59"
    "rx888,20m,WSPR,00:00,23:59"
    "rx888,15m,WSPR,00:00,23:59"
    "rx888,10m,WSPR,00:00,23:59"
)
```

### Multiple Receivers with Spot Merging
```bash
RECEIVER_LIST=(
    "vertical,192.168.1.100:8073"
    "beverage,192.168.1.101:8073"
)

WSPR_SCHEDULE=(
    "MERGED_RX,40m,WSPR,00:00,23:59,vertical+beverage"
)
```

## Essential Commands

```bash
# Start WsprDaemon
./wsprdaemon.sh -a

# Stop WsprDaemon  
./wsprdaemon.sh -z

# Check status
./wsprdaemon.sh -s

# View version
./wsprdaemon.sh -V

# Increase verbosity (for debugging)
./wsprdaemon.sh -v -s

# View help
./wsprdaemon.sh -h
```

## Quick Troubleshooting

### WsprDaemon Won't Start
1. Check configuration: `./wsprdaemon.sh -s`
2. Verify receiver connectivity: `ping RECEIVER_IP`
3. Check permissions: `ls -la wsprdaemon.conf`
4. Review logs: `tail -f /tmp/wsprdaemon/wsprdaemon.log`

### No Spots Being Uploaded
1. Check internet connectivity
2. Verify wsprnet.org is accessible
3. Check upload logs: `ls -la /tmp/wsprdaemon/uploads.d/`
4. Confirm callsign and grid are set correctly

### Poor Decoding Performance
1. Check audio levels and clipping
2. Verify time synchronization: `timedatectl status`
3. Monitor CPU usage: `top`
4. Check for interference sources

## Next Steps

Once basic operation is confirmed:

1. **[Complete Installation Guide](../installation/preparation.md)** - Detailed setup instructions
2. **[Configuration Reference](../configuration/wd_conf.md)** - Advanced configuration options
3. **[Operation Guide](../operation/service_management.md)** - Day-to-day operation
4. **[Troubleshooting](../troubleshooting/overview.md)** - Detailed problem resolution

## Performance Optimization

For high-performance installations:
- Use tmpfs for `/tmp/wsprdaemon/`
- Ensure adequate cooling
- Monitor system resources
- Consider dedicated network interface for multicast

## Getting Help

If you encounter issues:
- Check the [FAQ](../FAQ.md)
- Review [troubleshooting guides](../troubleshooting/overview.md)
- Search GitHub issues
- Contact: rob@robinett.us

---

**Success Indicator**: Within 15 minutes, you should see your callsign appearing on wsprnet.org with spots from your configured bands.
