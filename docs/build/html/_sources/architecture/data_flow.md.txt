# Data Flow Architecture

This document describes how data flows through WsprDaemon from audio capture to final spot reporting.

## Overview

WsprDaemon processes WSPR signals through a multi-stage pipeline that transforms raw audio into validated spot reports. The architecture is designed for reliability, scalability, and data integrity.

```
[SDR Hardware] → [Audio Capture] → [Decoding] → [Validation] → [Merging] → [Upload]
```

## Stage 1: Audio Capture

### Input Sources
- **KiwiSDR**: Network-based audio streams via kiwirecorder.py
- **RX888**: USB-based I/Q data via ka9q-radio
- **RTL-SDR**: USB-based I/Q data via rtl_sdr
- **Other SDRs**: Various interfaces through standardized APIs

### Recording Process
1. **Stream Initialization**: Establish connection to SDR hardware
2. **Audio Buffering**: Continuous audio capture with 2-minute windows
3. **File Creation**: Generate timestamped WAV files (YYMMDD_HHMM.wav)
4. **Quality Control**: Monitor for clipping, dropouts, and timing accuracy

### Data Format
- **Sample Rate**: 12 kHz (WSPR standard)
- **Bit Depth**: 16-bit signed integer
- **Channels**: Mono (single channel)
- **Duration**: Exactly 120 seconds per file
- **Timing**: Synchronized to even-minute boundaries

## Stage 2: Signal Decoding

### Decoding Engine
- **Primary Decoder**: wsprd from WSJT-X suite
- **Deep Search**: Optional wsprd -d for enhanced sensitivity
- **Parallel Processing**: Multiple decoders per receiver/band combination

### Processing Pipeline
1. **File Detection**: Monitor for new WAV files
2. **Preprocessing**: Audio validation and conditioning
3. **WSPR Decoding**: Extract callsign, grid, power, frequency, SNR
4. **Noise Analysis**: Calculate background noise levels
5. **Quality Assessment**: Validate decoded parameters

### Output Data
```
Timestamp: 2024-01-15 12:34:00
Callsign: W1ABC
Grid: FN42
Power: 37 dBm
Frequency: 14.097123 MHz
SNR: -18 dB
Drift: 0 Hz/min
```

## Stage 3: Data Validation

### Validation Layers
1. **Format Validation**: Verify callsign, grid, power formats
2. **Range Checking**: Ensure values within expected bounds
3. **Temporal Validation**: Confirm timing alignment
4. **Cross-Reference**: Compare with previous observations

### Quality Metrics
- **Decode Confidence**: Statistical confidence in decoded parameters
- **Signal Quality**: SNR and frequency stability metrics
- **Timing Accuracy**: Synchronization with WSPR schedule
- **Consistency**: Agreement with historical patterns

## Stage 4: Multi-Receiver Processing

### Spot Merging
When multiple receivers monitor the same band:

1. **Collection**: Gather spots from all receivers
2. **Correlation**: Match spots by callsign, time, and frequency
3. **Selection**: Choose best SNR for each unique transmission
4. **Metadata**: Preserve information from all receivers

### Receiver Coordination
- **Time Synchronization**: Ensure all receivers use common time reference
- **Frequency Calibration**: Account for receiver-specific offsets
- **Performance Monitoring**: Track individual receiver health
- **Load Balancing**: Distribute processing across available resources

## Stage 5: Data Aggregation

### Spot Compilation
1. **Temporal Grouping**: Collect spots by 2-minute transmission windows
2. **Duplicate Removal**: Eliminate redundant observations
3. **Metadata Addition**: Add receiver, location, and system information
4. **Format Conversion**: Prepare data for various output formats

### Noise Data Processing
- **Calibration**: Apply receiver-specific corrections
- **Averaging**: Calculate time-averaged noise levels
- **Trend Analysis**: Identify patterns and anomalies
- **Graphing**: Generate visualization data

## Stage 6: External Reporting

### Upload Destinations
1. **wsprnet.org**: Primary WSPR spot database
2. **wsprdaemon.org**: Enhanced data with additional metrics
3. **pskreporter.info**: FT4/FT8 mode reporting
4. **HamSCI GRAPE**: Scientific ionospheric research data

### Upload Process
1. **Queue Management**: Maintain upload queues per destination
2. **Format Conversion**: Transform data to required formats
3. **Transmission**: HTTP POST to destination servers
4. **Confirmation**: Verify successful delivery
5. **Retry Logic**: Handle temporary failures with exponential backoff

### Data Formats
**wsprnet.org Format:**
```
240115 1234 W1ABC FN42 37 K1DEF FN32 -18 0 0 14.097123 1
```

**Enhanced Format (wsprdaemon.org):**
```
{
  "timestamp": "2024-01-15T12:34:00Z",
  "tx_call": "W1ABC",
  "tx_grid": "FN42",
  "tx_power": 37,
  "rx_call": "K1DEF",
  "rx_grid": "FN32",
  "snr": -18,
  "frequency": 14.097123,
  "drift": 0,
  "noise_level": -142.5,
  "receiver_id": "kiwi_01"
}
```

## Data Storage and Archival

### Local Storage
- **Active Processing**: `/tmp/wsprdaemon/` (tmpfs recommended)
- **Persistent Logs**: `~/wsprdaemon/logs/`
- **Archive Data**: `~/wsprdaemon/archives/`
- **Configuration**: `~/wsprdaemon/wsprdaemon.conf`

### Data Retention
- **WAV Files**: Deleted after successful processing (configurable)
- **Spot Data**: Retained locally for backup and analysis
- **Log Files**: Rotated based on size and age limits
- **Noise Data**: Archived for long-term trend analysis

## Error Handling and Recovery

### Fault Tolerance
1. **Process Monitoring**: Watchdog processes restart failed components
2. **Data Caching**: Local storage until successful upload
3. **Graceful Degradation**: Continue operation with reduced functionality
4. **Automatic Recovery**: Self-healing from transient failures

### Error Propagation
- **Logging**: Comprehensive error logging at each stage
- **Alerting**: Notification of critical failures
- **Metrics**: Performance and error rate monitoring
- **Diagnostics**: Built-in tools for troubleshooting

## Performance Characteristics

### Throughput
- **Single Band**: ~30 spots/hour typical
- **Multi-Band**: Scales linearly with receiver count
- **Peak Load**: 2-minute processing windows create periodic load spikes
- **Sustained Rate**: Designed for 24/7 continuous operation

### Latency
- **Processing Delay**: 2-4 minutes from transmission to upload
- **Upload Latency**: Typically <30 seconds to external services
- **End-to-End**: 3-5 minutes from transmission to public availability

### Resource Usage
- **CPU**: Moderate during decode windows, low otherwise
- **Memory**: 200-500MB per active band
- **Disk I/O**: Burst writes during WAV creation and processing
- **Network**: Steady upload traffic, multicast for ka9q-radio

## Scalability Considerations

### Horizontal Scaling
- **Multiple Receivers**: Linear scaling with receiver count
- **Distributed Processing**: Separate recording and processing systems
- **Load Distribution**: Balance processing across available cores
- **Network Optimization**: Multicast for efficient data distribution

### Vertical Scaling
- **CPU Optimization**: Multi-threaded processing where beneficial
- **Memory Management**: Efficient buffer management and cleanup
- **I/O Optimization**: tmpfs for high-frequency file operations
- **Network Tuning**: Optimized for upload patterns and retry logic

This architecture ensures reliable, scalable processing of WSPR data while maintaining the flexibility to adapt to different hardware configurations and operational requirements.
