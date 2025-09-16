# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WsprDaemon (WD) is a Linux service that decodes WSPR and FST4W signals from KiwiSDR and RX888 SDRs and posts them to wsprnet.org. It's primarily written in Bash with Python utilities and runs as a 24/7 service with automatic recovery from outages.

## Core Architecture

- **Main Script**: `wsprdaemon.sh` - Primary entry point and service orchestrator
- **Configuration**: `wd_template.conf` - Main config template with receiver/schedule definitions  
- **Modular Design**: Core functionality split across sourced shell scripts:
  - `decoding.sh` - WSPR signal decoding logic
  - `posting.sh` - Upload to wsprnet.org
  - `job-management.sh` - Process lifecycle management
  - `watchdog.sh` - Service monitoring and recovery
  - `usage.sh` - Help system and command documentation

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

### Configuration
- Copy `wd_template.conf` to `wsprdaemon.conf` and customize
- Key config elements: `RECEIVER_LIST` array and `WSPR_SCHEDULE` arrays
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
1. **KiwiSDR** (`KIWI_*`) - Network-attached SDRs accessed via kiwirecorder.py
2. **KA9Q Radio** (`KA9Q_*`) - High-performance multichannel SDRs  
3. **Merged Receivers** (`MERG_*`) - Combines multiple receivers, posts best SNR

Schedule format: `"HH:MM RECEIVER,BAND,MODES RECEIVER,BAND,MODES ..."`

Example: `"00:00 KA9Q_0,20,W2:F2:F5 KIWI_0,40,W2:F2:F5"`

## Python Environment

Most Python scripts expect system Python3 with specific package requirements. Some scripts have hardcoded paths to virtual environments that may need updating for local development.

Common Python entry points:
- `ts_batch_upload.py` - Batch operations
- `wwv_start.py` - WWV time signal processing  
- `wav2grape.py` - Audio format conversion
- `wd-validate-wav-logs.py` - Validation utilities

## Testing and Validation

No formal test suite. Validation typically done through:
1. Configuration validation via `./wsprdaemon.sh -s`
2. Log monitoring via `./wsprdaemon.sh -l e`
3. Manual spot verification on wsprnet.org
4. Audio file validation with `wd-validate-wav-logs.py`

## Service Dependencies

- **WSJT-x**: Provides `wsprd` decoder binary (critical dependency)
- **Python 3**: For KiwiSDR interface and data processing
- **systemd**: For Linux service integration
- **Network tools**: curl, wget for uploads and API calls

## Configuration Templates

- `wd_template.conf` - Basic configuration with examples
- `wd_template_full.conf` - Complete configuration with all options
- `radiod@rx888-wsprdaemon-template.conf` - KA9Q radio specific config

## Error Recovery

WsprDaemon is designed for unattended operation with automatic recovery from:
- Power outages (systemd restart)
- Network interruptions (cached uploads)
- SDR disconnections (automatic reconnection)
- Decode failures (process restart)