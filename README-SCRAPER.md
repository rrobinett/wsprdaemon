# WSPRNET Scraper

Scrapes WSPR spots from wsprnet.org and stores them in ClickHouse database.

## Files

- `wsprnet_scraper.py` - Main Python scraper script
- `wsprnet_scraper.sh` - Bash wrapper that loads config and calls Python script
- `wsprnet_scraper@.service` - systemd service file
- `wsprnet.conf.example` - Example WSPRNET configuration
- `clickhouse.conf.example` - Example ClickHouse configuration
- `install-scraper.sh` - Installation script

## Installation

```bash
cd ~/wsprdaemon
sudo ./install-scraper.sh
```

This will:
1. Create `wsprdaemon` user if needed
2. Install Python dependencies in a virtual environment
3. Create necessary directories
4. Install scripts to `/usr/local/bin/`
5. Install systemd service
6. Create example config files in `/etc/wsprdaemon/`

## Configuration

After installation, edit the configuration files:

```bash
sudo nano /etc/wsprdaemon/clickhouse.conf
sudo nano /etc/wsprdaemon/wsprnet.conf
```

### ClickHouse Configuration

Set your ClickHouse admin credentials:
```bash
CLICKHOUSE_ADMIN_USER="chadmin"
CLICKHOUSE_ADMIN_PASSWORD="your_password"
```

### WSPRNET Configuration

Optionally add WSPRNET credentials if you need to login:
```bash
WSPRNET_USERNAME="your_wsprnet_username"
WSPRNET_PASSWORD="your_wsprnet_password"
```

## Starting the Service

```bash
# Enable service to start on boot
sudo systemctl enable wsprnet_scraper@wsprnet.service

# Start the service
sudo systemctl start wsprnet_scraper@wsprnet.service

# Check status
sudo systemctl status wsprnet_scraper@wsprnet.service

# View logs
sudo journalctl -u wsprnet_scraper@wsprnet.service -f

# Or view the application log
tail -f /var/log/wsprdaemon/wsprnet_scraper.log
```

## Database Schema

The scraper creates two tables in the `wsprnet` database:

### Main Table: `spots`
Stores WSPR spot data with the following columns:
- `id` - Spot number (UInt64)
- `time` - Timestamp (DateTime)
- `band` - Band from wsprnet.org (Int16)
- `rx_sign` - Receiver callsign
- `rx_lat`, `rx_lon` - Receiver location
- `rx_loc` - Receiver grid locator
- `tx_sign` - Transmitter callsign
- `tx_lat`, `tx_lon` - Transmitter location
- `tx_loc` - Transmitter grid locator
- `distance` - Distance in km (UInt16)
- `azimuth` - Azimuth (UInt16)
- `rx_azimuth` - Receiver azimuth (UInt16)
- `frequency` - Frequency in Hz (UInt32, 0 if overflow)
- `power` - Power in dBm (Int8)
- `snr` - Signal-to-noise ratio (Int8)
- `drift` - Drift (Int8)
- `version` - Software version
- `code` - Mode code (Int8)

### Overflow Table: `spots_frequency_overflow`
Stores frequencies that exceed UInt32 (>4.29 GHz):
- `id` - Spot number (links to spots.id)
- `frequency_original` - Full frequency value (UInt64)
- `inserted_at` - When record was created

## Querying Data

```bash
# Connect to ClickHouse
clickhouse-client --user chadmin --password chadmin

# View recent spots
SELECT * FROM wsprnet.spots ORDER BY id DESC LIMIT 10 FORMAT PrettyCompact;

# Count total spots
SELECT count() FROM wsprnet.spots;

# Get spots with frequency overflow
SELECT s.*, o.frequency_original 
FROM wsprnet.spots s
JOIN wsprnet.spots_frequency_overflow o ON s.id = o.id
LIMIT 10;
```

## Troubleshooting

### Service won't start
```bash
# Check logs
sudo journalctl -u wsprnet_scraper@wsprnet.service -n 50

# Test manually
sudo -u wsprdaemon /usr/local/bin/wsprnet_scraper.sh
```

### Permission errors
```bash
# Fix log/lib directory permissions
sudo chown -R wsprdaemon:wsprdaemon /var/log/wsprdaemon
sudo chown -R wsprdaemon:wsprdaemon /var/lib/wsprdaemon
```

### Database connection errors
```bash
# Test ClickHouse connection
clickhouse-client --user chadmin --password chadmin --query "SELECT 1"
```
