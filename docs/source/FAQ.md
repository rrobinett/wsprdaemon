# Frequently Asked Questions

## Installation & Setup

### Q: What operating systems does WsprDaemon support?
**A:** WsprDaemon runs on Ubuntu 24.04 LTS (recommended), Ubuntu 22.04 LTS, Linux Mint, and Debian-based systems. It works on x86_64, ARM64, and Raspberry Pi 4/5 platforms.

### Q: Can I run WsprDaemon on a Raspberry Pi?
**A:** Yes, but with limitations. Pi 4/5 can handle multiple WSPR bands but cannot support the full bandwidth of an RX888 plus WsprDaemon processing. It works well with RTL-SDR, FUNcube Dongle, and AirspyR2.

### Q: What hardware do I need to get started?
**A:** Minimum requirements:
- Antenna system with appropriate filtering and LNA
- SDR receiver (KiwiSDR, RX888, RTL-SDR, etc.)
- Computer with sufficient CPU/memory (Ryzen 5800+ recommended for RX888)
- Network connection
- For RX888: USB 3.0 port and appropriate low-pass filter

### Q: Do I need sudo privileges to run WsprDaemon?
**A:** Yes, installation and proper operation require sudo access. WsprDaemon automatically configures passwordless sudo for the user account.

## Configuration

### Q: How do I configure multiple receivers?
**A:** Define each receiver in the `RECEIVER_LIST` array in `wsprdaemon.conf`. You can merge spots from multiple receivers on the same band, and WsprDaemon will report only the best SNR to wsprnet.org.

### Q: Can I schedule different bands at different times?
**A:** Yes, WsprDaemon supports sophisticated scheduling including:
- Time-based band switching
- Sunrise/sunset relative scheduling
- Different schedules for different receivers
- Seasonal schedule variations

### Q: How do I set up noise measurement and graphing?
**A:** Enable noise measurement in your configuration and WsprDaemon will automatically:
- Record background noise levels
- Generate calibrated noise graphs
- Upload data to graphs.wsprdaemon.org (if configured)
- Create local noise plots

## Operation & Troubleshooting

### Q: How do I start and stop WsprDaemon?
**A:** Use these commands:
- Start: `./wsprdaemon.sh -a` (or `systemctl start wsprdaemon`)
- Stop: `./wsprdaemon.sh -z` (or `systemctl stop wsprdaemon`)
- Status: `./wsprdaemon.sh -s`
- Restart: Stop, then start

### Q: Where are the log files located?
**A:** Log files are in:
- Main logs: `/tmp/wsprdaemon/` and `~/wsprdaemon/`
- Individual receiver logs: `/tmp/wsprdaemon/recording.d/RECEIVER/BAND/`
- Decoding logs: `/tmp/wsprdaemon/decoding.d/RECEIVER/BAND/`

### Q: My RX888 disappeared from USB - what do I do?
**A:** This is a known issue. Solutions:
1. Power cycle the computer and RX888
2. Set up network-controlled power management for remote recovery
3. Check USB 3.0 connection quality
4. Verify adequate power supply

### Q: WsprDaemon won't start - what should I check?
**A:** Common issues:
1. No receivers defined in configuration
2. No schedule defined
3. Hardware radio not accessible
4. Network connectivity issues
5. Insufficient permissions
6. Check logs: `./wsprdaemon.sh -s` and examine error messages

### Q: How do I know if my spots are being uploaded successfully?
**A:** Check:
- Upload logs in `/tmp/wsprdaemon/uploads.d/`
- Your callsign on wsprnet.org
- WsprDaemon status: `./wsprdaemon.sh -s`
- Look for "SUCCESS" messages in posting logs

## Performance & Optimization

### Q: How many bands can I run simultaneously?
**A:** Depends on your hardware:
- Ryzen 5800+: 10+ bands with RX888
- Pi 4/5: 6-8 WSPR bands (no RX888)
- Intel systems: Varies by CPU generation and cores

### Q: Can I run radiod and WsprDaemon on separate computers?
**A:** Yes, using RTP multicast streams. Requirements:
- Set `ttl = 1` in radiod@.conf
- Use IGMP-aware ethernet switch
- Avoid WiFi for multicast traffic (causes network congestion)

### Q: How do I optimize performance for high-throughput sites?
**A:** Best practices:
- Use tmpfs (RAM disk) for temporary files
- Adequate CPU cooling
- Fast storage for permanent logs
- Sufficient RAM (8GB+ recommended)
- Optimize network settings for multicast

## Data & Reporting

### Q: What data does WsprDaemon collect beyond basic WSPR spots?
**A:** Additional data includes:
- Doppler shift measurements
- Background noise levels
- Signal-to-noise ratios
- Frequency accuracy
- Timing information
- Receiver performance metrics

### Q: Where does my data go?
**A:** Depending on configuration:
- wsprnet.org (WSPR spots)
- wsprdaemon.org (enhanced spot data)
- pskreporter.info (FT4/FT8 spots)
- HamSCI GRAPE system (WWV/CHU recordings)
- Local storage and graphs

### Q: Can I access historical data?
**A:** Yes, WsprDaemon maintains:
- Local log archives
- Noise measurement history
- Spot databases
- Performance statistics
- Upload to external databases for long-term storage

## Advanced Features

### Q: What is GRAPE integration?
**A:** GRAPE (Global Radio Array for Propagation Enhancement) records WWV and CHU time signals for ionospheric research. WsprDaemon can automatically record and upload these signals to HamSCI.

### Q: How does spot merging work with multiple receivers?
**A:** When multiple receivers monitor the same band:
1. Each receiver decodes independently
2. WsprDaemon compares SNR values
3. Only the best SNR spot is reported to wsprnet.org
4. All spots are logged locally for analysis

### Q: Can I integrate with external monitoring systems?
**A:** Yes, WsprDaemon provides:
- JSON status outputs
- Log file monitoring
- Performance metrics
- Alert mechanisms
- API endpoints for custom integration

## Getting Help

### Q: Where can I get support?
**A:** Resources include:
- GitHub issues: Report bugs and feature requests
- Documentation: https://wsprdaemon.readthedocs.io
- WSPR community forums
- Email: rob@robinett.us

### Q: How do I report a bug?
**A:** Include:
- WsprDaemon version (`./wsprdaemon.sh -V`)
- Operating system and version
- Hardware configuration
- Configuration files (sanitized)
- Relevant log excerpts
- Steps to reproduce the issue

### Q: Can I contribute to WsprDaemon development?
**A:** Yes! Contributions welcome:
- Bug reports and fixes
- Documentation improvements
- Feature enhancements
- Testing on different platforms
- Performance optimizations
