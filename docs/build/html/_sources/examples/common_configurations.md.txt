# Common Configurations

This section provides real-world configuration examples for typical WsprDaemon deployments.

## Single KiwiSDR Setup

### Basic Single-Band Configuration
```bash
# Station information
WSPR_CALL="W1ABC"
WSPR_GRID="FN42"

# Single KiwiSDR receiver
RECEIVER_LIST=(
    "kiwi1,192.168.1.100:8073"
)

# Simple 40m operation
WSPR_SCHEDULE=(
    "kiwi1,40m,WSPR,00:00,23:59"
)

# Basic reporting
WSPRNET_CALL="${WSPR_CALL}"
WSPRNET_GRID="${WSPR_GRID}"
```

### Multi-Band Time-Based Switching
```bash
# Station information
WSPR_CALL="K2DEF"
WSPR_GRID="FN32"

# Single KiwiSDR with band switching
RECEIVER_LIST=(
    "kiwi_main,192.168.1.100:8073"
)

# Time-based band schedule
WSPR_SCHEDULE=(
    "kiwi_main,160m,WSPR,00:00,06:00"    # Night - 160m
    "kiwi_main,80m,WSPR,06:00,08:00"     # Dawn - 80m
    "kiwi_main,40m,WSPR,08:00,16:00"     # Day - 40m
    "kiwi_main,20m,WSPR,16:00,20:00"     # Afternoon - 20m
    "kiwi_main,40m,WSPR,20:00,22:00"     # Evening - 40m
    "kiwi_main,80m,WSPR,22:00,24:00"     # Night - 80m
)

# Enable noise measurement
ENABLE_NOISE_GRAPHS="yes"
NOISE_GRAPHS_DIR="${HOME}/wsprdaemon/noise_graphs"
```

### Sunrise/Sunset Relative Scheduling
```bash
# Station information with location for sun calculations
WSPR_CALL="VE3GHI"
WSPR_GRID="FN03"
LATITUDE="43.6532"
LONGITUDE="-79.3832"

RECEIVER_LIST=(
    "kiwi_toronto,192.168.1.100:8073"
)

# Sun-relative scheduling
WSPR_SCHEDULE=(
    "kiwi_toronto,160m,WSPR,sunset-1h,sunrise+1h"
    "kiwi_toronto,80m,WSPR,sunset-30m,sunrise+2h"
    "kiwi_toronto,40m,WSPR,00:00,23:59"
    "kiwi_toronto,20m,WSPR,sunrise-1h,sunset+1h"
    "kiwi_toronto,15m,WSPR,sunrise+1h,sunset-1h"
)
```

## RX888 with KA9Q-Radio

### Single RX888 Multi-Band
```bash
# Station information
WSPR_CALL="W4JKL"
WSPR_GRID="EM75"

# RX888 via ka9q-radio multicast
RECEIVER_LIST=(
    "rx888_main,239.1.2.3:5004"
)

# Multiple simultaneous bands
WSPR_SCHEDULE=(
    "rx888_main,160m,WSPR,00:00,23:59"
    "rx888_main,80m,WSPR,00:00,23:59"
    "rx888_main,60m,WSPR,00:00,23:59"
    "rx888_main,40m,WSPR,00:00,23:59"
    "rx888_main,30m,WSPR,00:00,23:59"
    "rx888_main,20m,WSPR,00:00,23:59"
    "rx888_main,17m,WSPR,00:00,23:59"
    "rx888_main,15m,WSPR,00:00,23:59"
    "rx888_main,12m,WSPR,00:00,23:59"
    "rx888_main,10m,WSPR,00:00,23:59"
)

# KA9Q-radio specific settings
RADIOD_CONF_FILE="/etc/radio/radiod@rx888.conf"
ENABLE_GRAPE="yes"  # WWV/CHU recording for HamSCI
```

### High-Performance RX888 Setup
```bash
# High-throughput station
WSPR_CALL="W5MNO"
WSPR_GRID="EM25"

# Multiple RX888 receivers
RECEIVER_LIST=(
    "rx888_hf,239.1.2.3:5004"
    "rx888_vhf,239.1.2.4:5004"
)

# Full HF coverage
WSPR_SCHEDULE=(
    "rx888_hf,2200m,WSPR,00:00,23:59"
    "rx888_hf,630m,WSPR,00:00,23:59"
    "rx888_hf,160m,WSPR,00:00,23:59"
    "rx888_hf,80m,WSPR,00:00,23:59"
    "rx888_hf,60m,WSPR,00:00,23:59"
    "rx888_hf,40m,WSPR,00:00,23:59"
    "rx888_hf,30m,WSPR,00:00,23:59"
    "rx888_hf,20m,WSPR,00:00,23:59"
    "rx888_hf,17m,WSPR,00:00,23:59"
    "rx888_hf,15m,WSPR,00:00,23:59"
    "rx888_hf,12m,WSPR,00:00,23:59"
    "rx888_hf,10m,WSPR,00:00,23:59"
    "rx888_vhf,6m,WSPR,00:00,23:59"
    "rx888_vhf,4m,WSPR,00:00,23:59"
    "rx888_vhf,2m,WSPR,00:00,23:59"
)

# Performance optimizations
WSPRDAEMON_TMP_DIR="/dev/shm/wsprdaemon"  # Use RAM disk
MAX_DECODE_JOBS="16"  # Parallel processing
ENABLE_DEEP_SEARCH="yes"
```

## Multi-Receiver Configurations

### Antenna Diversity Setup
```bash
# Station with multiple antennas
WSPR_CALL="G0PQR"
WSPR_GRID="IO91"

# Multiple receivers for antenna diversity
RECEIVER_LIST=(
    "vertical,192.168.1.100:8073"
    "dipole,192.168.1.101:8073"
    "beverage,192.168.1.102:8073"
)

# Merged receivers for best SNR selection
WSPR_SCHEDULE=(
    "MERGED_160,160m,WSPR,00:00,23:59,vertical+beverage"
    "MERGED_80,80m,WSPR,00:00,23:59,vertical+dipole+beverage"
    "MERGED_40,40m,WSPR,00:00,23:59,vertical+dipole"
    "MERGED_20,20m,WSPR,00:00,23:59,vertical+dipole"
)

# Individual receiver monitoring
WSPR_SCHEDULE+=(
    "vertical,15m,WSPR,00:00,23:59"
    "dipole,10m,WSPR,00:00,23:59"
)
```

### Geographic Distribution
```bash
# Multi-site configuration
WSPR_CALL="VK2STU"
WSPR_GRID="QF56"

# Receivers at different locations
RECEIVER_LIST=(
    "site_north,203.0.113.10:8073"
    "site_south,203.0.113.20:8073"
    "site_coastal,203.0.113.30:8073"
)

# Site-specific scheduling
WSPR_SCHEDULE=(
    "site_north,40m,WSPR,00:00,12:00"
    "site_south,40m,WSPR,12:00,24:00"
    "site_coastal,20m,WSPR,06:00,18:00"
    "MERGED_80,80m,WSPR,00:00,23:59,site_north+site_south"
)

# Site-specific noise monitoring
ENABLE_NOISE_GRAPHS="yes"
NOISE_SITE_LABELS="North,South,Coastal"
```

## Specialized Configurations

### Research Station Setup
```bash
# Scientific research configuration
WSPR_CALL="W0XYZ"
WSPR_GRID="EN35"

RECEIVER_LIST=(
    "research_rx,192.168.1.100:8073"
)

# Comprehensive band coverage for research
WSPR_SCHEDULE=(
    "research_rx,2200m,WSPR,00:00,23:59"
    "research_rx,630m,WSPR,00:00,23:59"
    "research_rx,160m,WSPR,00:00,23:59"
    "research_rx,80m,WSPR,00:00,23:59"
    "research_rx,40m,WSPR,00:00,23:59"
    "research_rx,20m,WSPR,00:00,23:59"
    "research_rx,15m,WSPR,00:00,23:59"
    "research_rx,10m,WSPR,00:00,23:59"
)

# Enhanced data collection
ENABLE_GRAPE="yes"
ENABLE_NOISE_GRAPHS="yes"
ENABLE_EXTENDED_LOGGING="yes"
UPLOAD_TO_WSPRDAEMON_ORG="yes"

# Research-specific settings
NOISE_MEASUREMENT_INTERVAL="60"  # Every minute
SAVE_WAV_FILES="yes"  # Keep audio for analysis
EXTENDED_SPOT_FORMAT="yes"  # Additional metadata
```

### Contest/DXpedition Support
```bash
# Portable/contest configuration
WSPR_CALL="W1AW/P"
WSPR_GRID="FN42"

RECEIVER_LIST=(
    "portable_rx,192.168.43.100:8073"  # Mobile hotspot IP
)

# Contest-focused bands
WSPR_SCHEDULE=(
    "portable_rx,80m,WSPR,00:00,06:00"
    "portable_rx,40m,WSPR,06:00,18:00"
    "portable_rx,20m,WSPR,18:00,24:00"
)

# Minimal resource usage
ENABLE_NOISE_GRAPHS="no"
ENABLE_GRAPE="no"
LOG_LEVEL="1"  # Reduced logging
CLEANUP_OLD_FILES="yes"
```

### Remote Site Configuration
```bash
# Unattended remote site
WSPR_CALL="VK9ABC"
WSPR_GRID="QI22"

RECEIVER_LIST=(
    "remote_kiwi,10.0.0.100:8073"
)

WSPR_SCHEDULE=(
    "remote_kiwi,40m,WSPR,00:00,12:00"
    "remote_kiwi,20m,WSPR,12:00,24:00"
)

# Remote monitoring and reliability
ENABLE_WATCHDOG="yes"
WATCHDOG_RESTART_DELAY="300"  # 5 minutes
ENABLE_EMAIL_ALERTS="yes"
EMAIL_ALERT_ADDRESS="admin@example.com"

# Bandwidth conservation
UPLOAD_COMPRESSED_LOGS="yes"
REDUCE_UPLOAD_FREQUENCY="yes"
ENABLE_LOCAL_BACKUP="yes"
```

## Performance Tuning Examples

### High-Throughput Optimization
```bash
# Optimized for maximum throughput
WSPRDAEMON_TMP_DIR="/dev/shm/wsprdaemon"
MAX_PARALLEL_JOBS="$(nproc)"
NICE_LEVEL="-10"  # Higher priority
IONICE_CLASS="1"  # Real-time I/O scheduling

# Memory optimization
MALLOC_ARENA_MAX="2"
MALLOC_MMAP_THRESHOLD_="131072"

# Network optimization
TCP_WINDOW_SCALING="1"
TCP_CONGESTION_CONTROL="bbr"
```

### Resource-Constrained Setup
```bash
# Raspberry Pi optimization
MAX_PARALLEL_JOBS="2"
NICE_LEVEL="10"  # Lower priority
ENABLE_SWAP="yes"
SWAP_SIZE="2G"

# Reduced logging
LOG_LEVEL="1"
ROTATE_LOGS_SIZE="100K"
KEEP_LOG_DAYS="7"

# Conservative scheduling
DECODE_TIMEOUT="30"  # Shorter timeout
MAX_DECODE_ATTEMPTS="2"
```

## Integration Examples

### Home Automation Integration
```bash
# Integration with home automation
ENABLE_MQTT="yes"
MQTT_BROKER="192.168.1.50"
MQTT_TOPIC_PREFIX="wsprdaemon"

# Status publishing
PUBLISH_STATUS_INTERVAL="300"  # 5 minutes
PUBLISH_SPOT_COUNT="yes"
PUBLISH_NOISE_LEVELS="yes"
```

### Monitoring System Integration
```bash
# Prometheus/Grafana integration
ENABLE_METRICS_EXPORT="yes"
METRICS_PORT="9090"
METRICS_PATH="/metrics"

# InfluxDB integration
ENABLE_INFLUXDB="yes"
INFLUXDB_URL="http://192.168.1.60:8086"
INFLUXDB_DATABASE="wsprdaemon"
```

These configurations provide starting points for various deployment scenarios. Adapt the parameters to match your specific hardware, network, and operational requirements.
