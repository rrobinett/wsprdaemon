# Developer Getting Started Guide

*Essential information for WsprDaemon contributors and developers*

This guide provides the core information needed to start developing and contributing to WsprDaemon, based on the project's architecture and development practices.

## Project Overview

WsprDaemon (WD) is a Linux service that decodes WSPR and FST4W signals from KiwiSDR and RX888 SDRs and posts them to wsprnet.org. It's primarily written in Bash with Python utilities and runs as a 24/7 service with automatic recovery from outages.

### Key Statistics
- **20+ top spotting sites** use this architecture
- **~33% of daily WSPR spots** globally (7+ million/day)
- **Multi-continent deployment** including extreme locations like Antarctica
- **Thousands of active installations** worldwide

## Core Architecture

- **Main Script**: `wsprdaemon.sh` - Primary entry point and service orchestrator
- **Configuration**: `wd_template.conf` - Main config template with receiver/schedule definitions  
- **Modular Design**: Core functionality split across sourced shell scripts:
  - `decoding.sh` - WSPR signal decoding logic
  - `posting.sh` - Upload to wsprnet.org
  - `job-management.sh` - Process lifecycle management
  - `watchdog.sh` - Service monitoring and recovery
  - `usage.sh` - Help system and command documentation

## Development Environment Setup

### Prerequisites
- Linux development environment (Ubuntu/Debian preferred)
- Access to SDR hardware (KiwiSDR, RX888, or test environment)
- Basic familiarity with Bash scripting and Python
- Git for version control

### Initial Setup
```bash
# Clone the repository
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon

# Copy configuration template
cp wd_template.conf wsprdaemon.conf

# Review available options
./wsprdaemon.sh -h

# Check system compatibility
./wsprdaemon.sh -i
```

## Common Development Commands

### Service Management
```bash
# Start the watchdog daemon (primary command)
./wsprdaemon.sh -a

# Show status of all running jobs
./wsprdaemon.sh -s

# Stop all services
./wsprdaemon.sh -z

# Install as Linux service
./wsprdaemon.sh -A

# View logs (errors, wsprnet uploads, wsprdaemon uploads)
./wsprdaemon.sh -l e
./wsprdaemon.sh -l n  
./wsprdaemon.sh -l d
```

### Configuration Management
Key configuration elements in `wsprdaemon.conf`:
- `RECEIVER_LIST` array - Defines available receivers
- `WSPR_SCHEDULE` arrays - Scheduling for different receiver types
- Supports KiwiSDR (`KIWI_*`), KA9Q radio (`KA9Q_*`), and merged receivers (`MERG_*`)

### Development Utilities
```bash
# List audio/SDR devices
./wsprdaemon.sh -i

# Increase/decrease logging verbosity 
./wsprdaemon.sh -d/-D

# Python utilities for data processing
python3 ts_batch_upload.py     # Batch upload historical data
python3 wd-validate-wav-logs.py # Validate audio recordings
python3 c2_noise.py            # Noise analysis
```

### Documentation
```bash
# Build Sphinx documentation
cd docs
make html
make clean
```

## Receiver Architecture

WsprDaemon supports three types of receivers:

### 1. KiwiSDR (`KIWI_*`)
- Network-attached SDRs accessed via kiwirecorder.py
- Web interface typically on port 8073
- Requires password authentication in many cases

### 2. KA9Q Radio (`KA9Q_*`)
- High-performance multichannel SDRs  
- Uses multicast streams for radio control
- Web interface on port 8081
- Requires specific `radiod.conf` configuration

### 3. Merged Receivers (`MERG_*`)
- Combines multiple receivers, posts best SNR
- Useful for development without double-posting
- Requires careful configuration to avoid conflicts

### Schedule Format
```bash
"HH:MM RECEIVER,BAND,MODES RECEIVER,BAND,MODES ..."
```

Example:
```bash
"00:00 KA9Q_0,20,W2:F2:F5 KIWI_0,40,W2:F2:F5"
```

## Python Environment

Most Python scripts expect system Python3 with specific package requirements. Some scripts have hardcoded paths to virtual environments that may need updating for local development.

### Common Python Entry Points
- `ts_batch_upload.py` - Batch operations for historical data
- `wwv_start.py` - WWV time signal processing  
- `wav2grape.py` - Audio format conversion for GRAPE system
- `wd-validate-wav-logs.py` - Validation utilities for audio files

### Python Dependencies
While there's no formal requirements.txt, common dependencies include:
- `numpy` - Numerical processing
- `matplotlib` - Plotting and visualization
- `requests` - HTTP client for API calls
- `psutil` - System monitoring

## Testing and Validation

### Current Testing Approach
No formal test suite exists. Validation typically done through:

1. **Configuration validation**: `./wsprdaemon.sh -s`
2. **Log monitoring**: `./wsprdaemon.sh -l e`
3. **Manual spot verification**: Check wsprnet.org for uploaded spots
4. **Audio file validation**: `wd-validate-wav-logs.py`

### Development Testing Workflow
```bash
# 1. Test configuration before starting
./wsprdaemon.sh -s

# 2. Start with verbose logging
./wsprdaemon.sh -v -a

# 3. Monitor logs in real-time
./wsprdaemon.sh -l e

# 4. Verify uploads to wsprnet.org
./wsprdaemon.sh -l n

# 5. Check system resource usage
./wsprdaemon.sh -l d
```

## Service Dependencies

### Critical Dependencies
- **WSJT-x**: Provides `wsprd` decoder binary (absolutely critical)
- **Python 3**: For KiwiSDR interface and data processing
- **systemd**: For Linux service integration
- **Network tools**: curl, wget for uploads and API calls

### Optional Dependencies
- **tmux/screen**: For persistent sessions during development
- **git**: For version control and configuration tracking
- **unattended-upgrades**: For automatic security updates

## Configuration Templates

The project includes several configuration templates:

- **`wd_template.conf`** - Basic configuration with examples
- **`wd_template_full.conf`** - Complete configuration with all options
- **`radiod@rx888-wsprdaemon-template.conf`** - KA9Q radio specific config

### Configuration Best Practices
```bash
# Always backup before changes
cp wsprdaemon.conf wsprdaemon.conf.backup.$(date +%Y%m%d-%H%M%S)

# Validate configuration syntax
bash -n wsprdaemon.conf

# Test configuration before deployment
./wsprdaemon.sh -s
```

## Error Recovery and Reliability

WsprDaemon is designed for unattended operation with automatic recovery from:

- **Power outages**: systemd restart capability
- **Network interruptions**: cached uploads until connectivity restored
- **SDR disconnections**: automatic reconnection attempts
- **Decode failures**: process restart and error logging

### Debugging Common Issues
```bash
# Check service status
./wsprdaemon.sh -s

# View recent errors
./wsprdaemon.sh -l e | tail -50

# Check system resources
free -h && df -h

# Verify network connectivity
ping -c 3 wsprnet.org
```

## Development Workflow

### Typical Development Session
1. **Connect to development system** (often remote Pi with SDR hardware)
2. **Start tmux session** for persistence across connection drops
3. **Monitor logs** in one pane while developing in another
4. **Test changes incrementally** with status checks
5. **Validate uploads** to ensure no disruption to wsprnet.org

### Code Quality Guidelines
- Use ShellCheck for bash script validation
- Follow existing code style and patterns
- Document any hardware-specific assumptions
- Test with multiple receiver types when possible
- Ensure changes don't break existing installations

## Getting Help

### Documentation Resources
- **ReadTheDocs**: Comprehensive user and operator documentation
- **FAQ**: Common questions and troubleshooting
- **Configuration examples**: Real-world setup patterns

### Community Support
- **GitHub Issues**: Bug reports and feature requests
- **Amateur Radio Forums**: Community discussions
- **Direct Contact**: For complex technical issues

### Development Support
- **Code Review**: Submit pull requests for review
- **Architecture Questions**: Consult existing documentation
- **Hardware Testing**: Coordinate with community for testing

This guide provides the foundation for contributing to WsprDaemon. The project welcomes contributions that maintain its reliability and security while extending its capabilities for the amateur radio community.
