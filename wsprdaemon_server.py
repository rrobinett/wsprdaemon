#!/usr/bin/env python3
"""
WSPRDAEMON Server - Process .tbz files from wsprdaemon clients
Usage: wsprdaemon_server.py --clickhouse-user <user> --clickhouse-password <pass> [options]
"""

import argparse
import json
import sys
import time
import os
import tarfile
import shutil
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from datetime import datetime
import clickhouse_connect
import logging

# Version
VERSION = "2.7.0"  # Set distance/azimuth to -999 (not -1) when tx_loc is 'none' and can't be found

# Default configuration
DEFAULT_CONFIG = {
    'clickhouse_host': 'localhost',
    'clickhouse_port': 8123,
    'clickhouse_user': '',
    'clickhouse_password': '',
    'clickhouse_database': 'wsprdaemon',
    'clickhouse_spots_table': 'spots_raw',
    'clickhouse_noise_table': 'noise',
    'incoming_tbz_dirs': ['/var/spool/wsprdaemon/from-wd0', '/var/spool/wsprdaemon/from-wd00'],
    'extraction_dir': '/var/lib/wsprdaemon/extraction',
    'processed_tbz_file': '/var/lib/wsprdaemon/wsprdaemon/processed_tbz_list.txt',
    'max_processed_file_size': 1000000,
    'max_spots_per_insert': 50000,
    'max_noise_per_insert': 50000,
    'loop_interval': 10
}

# Logging configuration
LOG_FILE = 'wsprdaemon_server.log'
LOG_MAX_BYTES = 10 * 1024 * 1024  # 10MB
LOG_KEEP_RATIO = 0.75

class TruncatingFileHandler(logging.FileHandler):
    """File handler that truncates to newest 75% when file grows too large"""

    def __init__(self, filename, max_bytes, keep_ratio=0.75):
        self.max_bytes = max_bytes
        self.keep_ratio = keep_ratio
        super().__init__(filename, mode='a', encoding='utf-8')

    def emit(self, record):
        """Emit a record, truncating file if needed"""
        super().emit(record)
        self.check_truncate()

    def check_truncate(self):
        """Check file size and truncate if needed"""
        try:
            if os.path.exists(self.baseFilename):
                current_size = os.path.getsize(self.baseFilename)
                if current_size > self.max_bytes:
                    self.truncate_file()
        except Exception as e:
            print(f"Error checking log file size: {e}")

    def truncate_file(self):
        """Keep only the newest 75% of the file"""
        try:
            with open(self.baseFilename, 'r', encoding='utf-8') as f:
                lines = f.readlines()

            keep_count = int(len(lines) * self.keep_ratio)
            if keep_count < 1:
                keep_count = 1

            new_lines = lines[-keep_count:]

            with open(self.baseFilename, 'w', encoding='utf-8') as f:
                f.write(f"[Log truncated - kept newest {self.keep_ratio*100:.0f}% of {len(lines)} lines]\n")
                f.writelines(new_lines)

            old_size = sum(len(line.encode('utf-8')) for line in lines)
            new_size = os.path.getsize(self.baseFilename)
            logging.info(f"Log file truncated from {old_size:,} to {new_size:,} bytes")

        except Exception as e:
            print(f"Error truncating log file: {e}")


def setup_logging(log_file=None, max_bytes=LOG_MAX_BYTES, keep_ratio=LOG_KEEP_RATIO, verbosity=0):
    """Setup logging - either to file OR console, not both
    
    verbosity levels:
        0: WARNING and ERROR only
        1: INFO + WARNING + ERROR
        2+: DEBUG + INFO + WARNING + ERROR
    """
    logger = logging.getLogger()
    
    # Set level based on verbosity
    if verbosity == 0:
        logger.setLevel(logging.WARNING)
    elif verbosity == 1:
        logger.setLevel(logging.INFO)
    else:
        logger.setLevel(logging.DEBUG)
    
    logger.handlers.clear()

    if log_file:
        file_handler = TruncatingFileHandler(log_file, max_bytes, keep_ratio)
        file_formatter = logging.Formatter('[%(asctime)s] %(levelname)s: %(message)s',
                                          datefmt='%Y-%m-%d %H:%M:%S')
        file_handler.setFormatter(file_formatter)
        logger.addHandler(file_handler)
    else:
        console_handler = logging.StreamHandler()
        console_formatter = logging.Formatter('[%(asctime)s] %(levelname)s: %(message)s',
                                             datefmt='%Y-%m-%d %H:%M:%S')
        console_handler.setFormatter(console_formatter)
        logger.addHandler(console_handler)

    return logger


def log(message: str, level: str = "INFO"):
    """Log a message at the specified level"""
    logger = logging.getLogger()
    level_map = {
        'DEBUG': logging.DEBUG,
        'INFO': logging.INFO,
        'WARNING': logging.WARNING,
        'ERROR': logging.ERROR,
        'CRITICAL': logging.CRITICAL
    }
    logger.log(level_map.get(level, logging.INFO), message)
    # Force flush to disk
    for handler in logger.handlers:
        handler.flush()


def setup_clickhouse_tables(admin_user: str, admin_password: str,
                           config: Dict) -> bool:
    """Setup ClickHouse database and tables (assumes admin user already exists)"""
    try:
        # Connect as admin user directly
        log(f"Connecting to ClickHouse as {admin_user}...", "INFO")
        admin_client = clickhouse_connect.get_client(
            host=config['clickhouse_host'],
            port=config['clickhouse_port'],
            username=admin_user,
            password=admin_password
        )

        # Create database if not exists
        result = admin_client.query(
            f"SELECT 1 FROM system.databases WHERE name = '{config['clickhouse_database']}'"
        )
        if not result.result_rows:
            log(f"Creating database {config['clickhouse_database']}...", "INFO")
            admin_client.command(f"CREATE DATABASE {config['clickhouse_database']}")
            log(f"Database {config['clickhouse_database']} created", "INFO")
        else:
            log(f"Database {config['clickhouse_database']} already exists", "INFO")

        # Create spots table - HARMONIZED with wsprnet.spots schema
        create_spots_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {config['clickhouse_database']}.{config['clickhouse_spots_table']}
        (
            -- Harmonized columns matching wsprnet.spots schema (with aliases for old names)
            id           Nullable(UInt64)        CODEC(Delta(8), ZSTD(1)),
            time         DateTime                CODEC(Delta(4), ZSTD(1)),
            band         Int16                   CODEC(T64, ZSTD(1)),
            rx_sign      LowCardinality(String)  CODEC(LZ4),
            rx_lat       Float32                 CODEC(Delta(4), ZSTD(3)),
            rx_lon       Float32                 CODEC(Delta(4), ZSTD(3)),
            rx_loc       LowCardinality(String)  CODEC(LZ4),
            tx_sign      LowCardinality(String)  CODEC(LZ4),
            tx_lat       Float32                 CODEC(Delta(4), ZSTD(3)),
            tx_lon       Float32                 CODEC(Delta(4), ZSTD(3)),
            tx_loc       LowCardinality(String)  CODEC(LZ4),
            distance     Int32                   CODEC(T64, ZSTD(1)),
            azimuth      Int32                   CODEC(T64, ZSTD(1)),
            rx_azimuth   Int32                   CODEC(T64, ZSTD(1)),
            frequency    UInt64                  CODEC(Delta(8), ZSTD(3)),
            power        Int8                    CODEC(T64, ZSTD(1)),
            snr          Int8                    CODEC(Delta(4), ZSTD(3)),
            drift        Int8                    CODEC(Delta(4), ZSTD(3)),
            version      LowCardinality(Nullable(String)) CODEC(LZ4),
            code         Int8                    CODEC(ZSTD(1)),
            
            -- Wsprdaemon-specific additional fields
            frequency_mhz Float64                CODEC(Delta(8), ZSTD(3)),
            rx_id        LowCardinality(String)  CODEC(LZ4),
            v_lat        Float32                 CODEC(Delta(4), ZSTD(3)),
            v_lon        Float32                 CODEC(Delta(4), ZSTD(3)),
            c2_noise     Float32                 CODEC(Delta(4), ZSTD(3)),
            sync_quality UInt16                  CODEC(ZSTD(1)),
            dt           Float32                 CODEC(Delta(4), ZSTD(3)),
            decode_cycles UInt32                 CODEC(T64, ZSTD(1)),
            jitter       Int16                   CODEC(T64, ZSTD(1)),
            rms_noise    Float32                 CODEC(Delta(4), ZSTD(3)),
            blocksize    UInt16                  CODEC(T64, ZSTD(1)),
            metric       Int16                   CODEC(T64, ZSTD(1)),
            osd_decode   UInt8                   CODEC(T64, ZSTD(1)),
            nhardmin     UInt16                  CODEC(T64, ZSTD(1)),
            ipass        UInt8                   CODEC(T64, ZSTD(1)),
            proxy_upload UInt8                   CODEC(T64, ZSTD(1)),
            ov_count     UInt32                  CODEC(T64, ZSTD(1)),
            rx_status    LowCardinality(String)  DEFAULT 'No Info' CODEC(LZ4),
            band_m       Int16                   CODEC(T64, ZSTD(1)),  -- Original band in meters from source
            
            -- Aliases for backwards compatibility with old column names
            Spotnum      UInt64 ALIAS id,
            Date         UInt32 ALIAS toUnixTimestamp(time),
            Reporter     String ALIAS rx_sign,
            ReporterGrid String ALIAS rx_loc,
            dB           Int8 ALIAS snr,
            freq         Float64 ALIAS frequency_mhz,
            MHz          Float64 ALIAS frequency_mhz,
            CallSign     String ALIAS tx_sign,
            Grid         String ALIAS tx_loc,
            Power        Int8 ALIAS power,
            Drift        Int8 ALIAS drift,
            Band         Int16 ALIAS band,
            rx_az        UInt16 ALIAS rx_azimuth,
            frequency_hz UInt64 ALIAS frequency
        ) 
        ENGINE = MergeTree
        PARTITION BY toYYYYMM(time)
        ORDER BY (time)
        SETTINGS index_granularity = 8192
        """
        admin_client.command(create_spots_table_sql)
        log(f"Table {config['clickhouse_database']}.{config['clickhouse_spots_table']} created/verified", "INFO")

        # Create view that matches wsprnet.spots schema (harmonized columns only)
        create_spots_view_sql = f"""
        CREATE OR REPLACE VIEW {config['clickhouse_database']}.spots AS
        SELECT
            id,
            time,
            band,
            rx_sign,
            rx_lat,
            rx_lon,
            rx_loc,
            tx_sign,
            tx_lat,
            tx_lon,
            tx_loc,
            distance,
            azimuth,
            rx_azimuth,
            frequency,
            power,
            snr,
            drift,
            version,
            code
        FROM {config['clickhouse_database']}.{config['clickhouse_spots_table']}
        """
        admin_client.command(create_spots_view_sql)
        log(f"View {config['clickhouse_database']}.spots created/verified", "INFO")

        # Create noise table with seqnum
        # Create noise table with correct column order
        create_noise_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {config['clickhouse_database']}.{config['clickhouse_noise_table']}
        (
            time       DateTime                     CODEC(Delta(4), ZSTD(1)),
            site       LowCardinality(String),
            receiver   LowCardinality(String),
            rx_loc     LowCardinality(String),
            band       LowCardinality(String),
            rms_level  Float32                      CODEC(ZSTD(1)),
            c2_level   Float32                      CODEC(ZSTD(1)),
            ov         Nullable(Int32),
            seqnum     Int64                        CODEC(Delta(8), ZSTD(1)),

            -- Aliases for alternate names
            rx_sign    String ALIAS site,
            rx_id      String ALIAS receiver
        )
        ENGINE = MergeTree
        PARTITION BY toYYYYMM(time)
        ORDER BY (time, site, receiver)
        SETTINGS index_granularity = 8192
        """
        admin_client.command(create_noise_table_sql)
        log(f"Table {config['clickhouse_database']}.{config['clickhouse_noise_table']} created/verified", "INFO")

        return True

    except Exception as e:
        log(f"Setup failed: {e}", "ERROR")
        return False


def find_tbz_files(incoming_dirs: List[str]) -> List[Path]:
    """Find all .tbz files in incoming directories"""
    tbz_files = []
    for dir_path in incoming_dirs:
        if not os.path.exists(dir_path):
            log(f"Incoming directory does not exist: {dir_path}", "WARNING")
            continue
        
        for root, dirs, files in os.walk(dir_path):
            for file in files:
                if file.endswith('.tbz'):
                    tbz_files.append(Path(root) / file)
    
    return tbz_files


def is_tbz_processed(tbz_file: Path, processed_file: Path) -> bool:
    """Check if a .tbz file has already been processed"""
    if not processed_file.exists():
        return False
    
    try:
        with open(processed_file, 'r') as f:
            processed = f.read()
            return tbz_file.name in processed
    except Exception as e:
        log(f"Error reading processed file: {e}", "WARNING")
        return False


def mark_tbz_processed(tbz_file: Path, processed_file: Path, max_size: int):
    """Mark a .tbz file as processed"""
    try:
        processed_file.parent.mkdir(parents=True, exist_ok=True)
        
        with open(processed_file, 'a') as f:
            f.write(f"{tbz_file.name}\n")
        
        # Truncate if too large
        if processed_file.stat().st_size > max_size:
            with open(processed_file, 'r') as f:
                lines = f.readlines()
            
            keep_count = int(len(lines) * 0.75)
            with open(processed_file, 'w') as f:
                f.writelines(lines[-keep_count:])
            
            log(f"Truncated processed file from {len(lines)} to {keep_count} entries", "INFO")
    
    except Exception as e:
        log(f"Error marking file as processed: {e}", "ERROR")


def extract_tbz(tbz_file: Path, extraction_dir: Path) -> bool:
    """Extract a .tbz file to the extraction directory"""
    try:
        with tarfile.open(tbz_file, 'r:bz2') as tar:
            tar.extractall(path=extraction_dir)
        return True
    except Exception as e:
        log(f"Error extracting {tbz_file}: {e}", "ERROR")
        return False


def get_client_version(extraction_dir: Path) -> Optional[str]:
    """Extract CLIENT_VERSION from uploads_config.txt in the tbz extraction"""
    config_file = extraction_dir / "wsprdaemon" / "uploads_config.txt"
    
    if not config_file.exists():
        log(f"uploads_config.txt not found at {config_file}", "DEBUG")
        return None
    
    try:
        with open(config_file, 'r') as f:
            for line in f:
                if line.startswith('CLIENT_VERSION='):
                    version = line.strip().split('=', 1)[1]
                    log(f"Found CLIENT_VERSION: {version}", "DEBUG")
                    return f"WD_{version}"  # Prepend WD_ to version
    except Exception as e:
        log(f"Error reading uploads_config.txt: {e}", "WARNING")
    
    return None


def get_receiver_name_from_path(file_path: Path) -> str:
    """Extract receiver name from file path (2 levels up from file)"""
    parts = file_path.parts
    if len(parts) >= 3:
        return parts[-3]
    return "unknown"


def maidenhead_to_latlon(grid: str) -> Tuple[float, float]:
    """Convert Maidenhead grid square to latitude/longitude (center of square)
    
    Returns (lat, lon) with 3 decimal places precision
    Handles 4-character (e.g., CM87) and 6-character (e.g., CM87wj) grids
    Returns (-999, -999) if grid is invalid
    """
    if not grid or len(grid) < 4:
        return (-999.0, -999.0)
    
    grid = grid.upper()
    
    try:
        # Field (first 2 characters): 20° lon, 10° lat
        lon = (ord(grid[0]) - ord('A')) * 20 - 180
        lat = (ord(grid[1]) - ord('A')) * 10 - 90
        
        # Square (next 2 digits): 2° lon, 1° lat
        lon += int(grid[2]) * 2
        lat += int(grid[3]) * 1
        
        # Center of the square
        lon += 1.0  # Add half of 2°
        lat += 0.5  # Add half of 1°
        
        # Subsquare (optional next 2 characters): 5' lon, 2.5' lat
        if len(grid) >= 6:
            lon += (ord(grid[4]) - ord('A')) * (2.0/24.0)
            lat += (ord(grid[5]) - ord('A')) * (1.0/24.0)
            # Center of subsquare
            lon += (1.0/24.0)  # Add half of 2/24°
            lat += (0.5/24.0)  # Add half of 1/24°
        
        # Round to 3 decimal places
        return (round(lat, 3), round(lon, 3))
        
    except (ValueError, IndexError):
        return (-999.0, -999.0)


def calculate_distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> int:
    """Calculate great circle distance in kilometers using Haversine formula
    
    Returns integer distance in km, or -999 if any coordinate is -999
    """
    import math
    
    if lat1 == -999.0 or lon1 == -999.0 or lat2 == -999.0 or lon2 == -999.0:
        return -999
    
    # Convert to radians
    lat1_rad = math.radians(lat1)
    lon1_rad = math.radians(lon1)
    lat2_rad = math.radians(lat2)
    lon2_rad = math.radians(lon2)
    
    # Haversine formula
    dlat = lat2_rad - lat1_rad
    dlon = lon2_rad - lon1_rad
    
    a = math.sin(dlat/2)**2 + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(dlon/2)**2
    c = 2 * math.asin(math.sqrt(a))
    
    # Earth radius in km
    radius = 6371.0
    
    return int(round(radius * c))


def calculate_azimuth(lat1: float, lon1: float, lat2: float, lon2: float) -> int:
    """Calculate azimuth (bearing) from point 1 to point 2
    
    Returns integer azimuth in degrees (0-359), or -999 if any coordinate is -999
    """
    import math
    
    if lat1 == -999.0 or lon1 == -999.0 or lat2 == -999.0 or lon2 == -999.0:
        return -999
    
    # Convert to radians
    lat1_rad = math.radians(lat1)
    lon1_rad = math.radians(lon1)
    lat2_rad = math.radians(lat2)
    lon2_rad = math.radians(lon2)
    
    # Calculate bearing
    dlon = lon2_rad - lon1_rad
    
    x = math.sin(dlon) * math.cos(lat2_rad)
    y = math.cos(lat1_rad) * math.sin(lat2_rad) - math.sin(lat1_rad) * math.cos(lat2_rad) * math.cos(dlon)
    
    bearing_rad = math.atan2(x, y)
    bearing_deg = math.degrees(bearing_rad)
    
    # Normalize to 0-359
    azimuth = int(round(bearing_deg)) % 360
    
    return azimuth


def lookup_tx_loc(client, database: str, table: str, tx_sign: str) -> Optional[str]:
    """Look up the most recent valid tx_loc for a given tx_sign
    
    Returns the most recent tx_loc that is not 'none', or None if not found
    """
    try:
        result = client.query(f"""
            SELECT tx_loc 
            FROM {database}.{table}
            WHERE tx_sign = '{tx_sign}' 
              AND tx_loc != 'none' 
              AND tx_loc != ''
              AND length(tx_loc) >= 4
            ORDER BY time DESC
            LIMIT 1
        """)
        
        if result.result_rows:
            tx_loc = result.result_rows[0][0]
            log(f"Found previous tx_loc for {tx_sign}: {tx_loc}", "DEBUG")
            return tx_loc
    except Exception as e:
        log(f"Error looking up tx_loc for {tx_sign}: {e}", "DEBUG")
    
    return None


def map_wsprdaemon_code_to_wsprnet(wsprdaemon_code: int) -> int:
    """Map wsprdaemon code values to wsprnet standard code values
    
    Wsprdaemon codes (from decode.sh):
        2: WSPR-2
        3: FST4W-120
        5: FST4W-300
        16: FST4W-900 / WSPR-15
        30: FST4W-1800
    
    WSPRnet standard codes:
        -1: Unknown
        1: WSPR-2
        2: FST4W-900 / WSPR-15
        3: FST4W-120
        4: FST4W-300
        8: FST4W-1800
    """
    code_map = {
        2: 1,   # WSPR-2
        3: 3,   # FST4W-120
        5: 4,   # FST4W-300
        16: 2,  # FST4W-900 / WSPR-15
        30: 8,  # FST4W-1800
    }
    return code_map.get(wsprdaemon_code, -1)  # Return -1 (Unknown) for unmapped codes


def parse_spot_line(line: str, file_path: Path, version: Optional[str] = None, 
                   client=None, database: str = None, table: str = None) -> Optional[List]:
    """Parse a 34-field spot line into ClickHouse row format - NEW HARMONIZED SCHEMA"""
    fields = line.strip().split()
    
    if len(fields) < 34:
        return None
    
    try:
        # Parse date/time
        date_str = fields[0]  # YYMMDD
        time_str = fields[1]  # HHMM
        
        yy = date_str[0:2]
        mm = date_str[2:4]
        dd = date_str[4:6]
        hh = time_str[0:2]
        min_str = time_str[2:4]
        
        # Convert to datetime object
        clickhouse_time = datetime.strptime(f"20{yy}-{mm}-{dd} {hh}:{min_str}:00", "%Y-%m-%d %H:%M:%S")
        
        # Extract receiver name from file path
        rx_id = get_receiver_name_from_path(file_path)
        
        # Parse frequency from MHz
        frequency_mhz = float(fields[5])
        frequency_hz = int(round(frequency_mhz * 1000000))
        
        # Calculate band from frequency
        if frequency_hz < 200000:
            band = -1
        else:
            band = frequency_hz // 1000000  # Integer division to get MHz
        
        # Parse lat/lon with 3-decimal precision and grid fallback
        rx_lat = round(float(fields[25]), 3)
        rx_lon = round(float(fields[26]), 3)
        rx_loc = fields[21]
        
        tx_lat = round(float(fields[28]), 3)
        tx_lon = round(float(fields[29]), 3)
        tx_loc = fields[7]
        tx_sign = fields[6]
        
        # If tx_loc is 'none', look up most recent valid tx_loc for this tx_sign
        if tx_loc.lower() == 'none' and client and database and table:
            looked_up_loc = lookup_tx_loc(client, database, table, tx_sign)
            if looked_up_loc:
                tx_loc = looked_up_loc
                log(f"Replaced tx_loc 'none' with {tx_loc} for {tx_sign}", "DEBUG")
            else:
                log(f"No previous tx_loc found for {tx_sign}, keeping 'none'", "DEBUG")
        
        # Track if we need to recalculate distance/azimuth
        recalculate_geometry = False
        
        # If rx_lat/lon are -999, calculate from rx_loc grid
        if rx_lat == -999.0 or rx_lon == -999.0:
            grid_lat, grid_lon = maidenhead_to_latlon(rx_loc)
            if grid_lat != -999.0:
                rx_lat = grid_lat
                rx_lon = grid_lon
                recalculate_geometry = True
        
        # If tx_lat/lon are -999, calculate from tx_loc grid
        if tx_lat == -999.0 or tx_lon == -999.0:
            grid_lat, grid_lon = maidenhead_to_latlon(tx_loc)
            if grid_lat != -999.0:
                tx_lat = grid_lat
                tx_lon = grid_lon
                recalculate_geometry = True
        
        # Parse or calculate distance and azimuths
        if recalculate_geometry:
            # Recalculate from lat/lon coordinates
            distance = calculate_distance_km(rx_lat, rx_lon, tx_lat, tx_lon)
            azimuth = calculate_azimuth(rx_lat, rx_lon, tx_lat, tx_lon)
            rx_azimuth = calculate_azimuth(tx_lat, tx_lon, rx_lat, rx_lon)
        elif tx_loc.lower() == 'none' and (tx_lat == -999.0 or tx_lon == -999.0):
            # tx_loc is 'none' and we couldn't look it up or calculate from it
            # Set geometry to -999 instead of using potentially invalid data
            distance = -999
            azimuth = -999
            rx_azimuth = -999
        else:
            # Use values from spot data
            distance = int(fields[23])
            azimuth = int(float(fields[27]))
            rx_azimuth = int(float(fields[24]))
        
        # Build row using NEW SCHEMA column order
        row = [
            # New harmonized columns (matching wsprnet.spots order)
            None,                      # id (NULL for wsprdaemon data - no Spotnum)
            clickhouse_time,           # time (DateTime)
            band,                      # band (calculated from frequency)
            fields[22],                # rx_sign (was Reporter)
            rx_lat,                    # rx_lat (3 decimal places, calculated from grid if -999)
            rx_lon,                    # rx_lon (3 decimal places, calculated from grid if -999)
            rx_loc,                    # rx_loc (was ReporterGrid)
            tx_sign,                   # tx_sign (was CallSign)
            tx_lat,                    # tx_lat (3 decimal places, calculated from grid if -999)
            tx_lon,                    # tx_lon (3 decimal places, calculated from grid if -999)
            tx_loc,                    # tx_loc (looked up if was 'none')
            distance,                  # distance (recalculated if lat/lon from grid)
            azimuth,                   # azimuth (recalculated if lat/lon from grid)
            rx_azimuth,                # rx_azimuth (recalculated if lat/lon from grid)
            frequency_hz,              # frequency (UInt64 Hz - rounded from MHz * 1000000)
            int(fields[8]),            # power
            int(float(fields[3])),     # snr (was dB)
            int(float(fields[9])),     # drift
            version,                   # version (from uploads_config.txt CLIENT_VERSION)
            map_wsprdaemon_code_to_wsprnet(int(fields[17])),  # code (mapped to wsprnet standard)
            
            # Wsprdaemon-specific additional fields
            frequency_mhz,             # frequency_mhz (Float64 MHz - original precision)
            rx_id,                     # rx_id
            float(fields[30]),         # v_lat
            float(fields[31]),         # v_lon
            float(fields[19]),         # c2_noise
            int(float(fields[2])),     # sync_quality
            float(fields[4]),          # dt
            int(fields[10]),           # decode_cycles
            int(fields[11]),           # jitter
            float(fields[18]),         # rms_noise
            int(fields[12]),           # blocksize
            int(fields[13]),           # metric
            int(fields[14]),           # osd_decode
            int(fields[16]),           # nhardmin
            int(fields[15]),           # ipass
            int(fields[33]),           # proxy_upload
            int(fields[32]),           # ov_count
            'No Info',                 # rx_status
            int(fields[20])            # band_m (original band in meters from source)
        ]
        
        return row
    
    except (ValueError, IndexError) as e:
        log(f"Error parsing spot line: {e}", "WARNING")
        return None


def process_spot_files(extraction_dir: Path, version: Optional[str] = None,
                      client=None, database: str = None, table: str = None) -> List[List]:
    """Find and process all spot files"""
    spot_files = list(extraction_dir.rglob('*_spots.txt'))
    
    if not spot_files:
        log("No spot files found", "DEBUG")
        return []
    
    log(f"Found {len(spot_files)} spot files", "DEBUG")
    
    all_rows = []
    valid_count = 0
    error_count = 0
    
    for spot_file in spot_files:
        if spot_file.stat().st_size == 0:
            continue
        
        try:
            with open(spot_file, 'r') as f:
                for line in f:
                    row = parse_spot_line(line, spot_file, version, client, database, table)
                    if row:
                        all_rows.append(row)
                        valid_count += 1
                    else:
                        error_count += 1
        except Exception as e:
            log(f"Error reading spot file {spot_file}: {e}", "ERROR")
    
    log(f"Parsed {valid_count} valid spots, {error_count} errors", "DEBUG")
    return all_rows


def parse_noise_line(line: str, file_path: Path) -> Optional[List]:
    """Parse a 15-field noise line into ClickHouse row format - NEW SCHEMA"""
    fields = line.strip().split()
    
    if len(fields) != 15:
        return None
    
    try:
        # Extract metadata from file path
        # Path format: .../noise/SITE_GRID/RECEIVER/BAND/YYMMDD_HHMM_noise.txt
        parts = file_path.parts
        
        # Get filename and extract date/time
        filename = file_path.name  # e.g., "251007_2230_noise.txt"
        date_time = filename.replace('_noise.txt', '')
        date_part, time_part = date_time.split('_')
        
        yy = date_part[0:2]
        mm = date_part[2:4]
        dd = date_part[4:6]
        hh = time_part[0:2]
        min_str = time_part[2:4]
        
        # Convert to datetime object
        clickhouse_time = datetime.strptime(f"20{yy}-{mm}-{dd} {hh}:{min_str}:00", "%Y-%m-%d %H:%M:%S")
        
        # Extract site and grid from path (e.g., "KJ6MKI_CM88oi")
        call_grid = parts[-4]
        site_parts = call_grid.split('_')
        rx_sign = site_parts[0].replace('=', '/')  # Handle callsigns with / encoded as =
        rx_loc = site_parts[1] if len(site_parts) > 1 else ''
        
        # Extract receiver (e.g., "KA9Q_0")
        rx_id = parts[-3]
        
        # Extract band (e.g., "20")
        band = parts[-2]
        
        # Fields 13, 14, 15 (0-indexed: 12, 13, 14) are rms_level, c2_level, ov
        rms_level = float(fields[12])
        c2_level = float(fields[13])
        ov = int(float(fields[14]))
        
        # New schema order: time, rx_sign, rx_id, rx_loc, band, rms_level, c2_level, ov
        # (seqnum is auto-generated)
        row = [
            clickhouse_time,
            rx_sign,
            rx_id,
            rx_loc,
            band,
            rms_level,
            c2_level,
            ov
        ]
        
        return row
    
    except (ValueError, IndexError) as e:
        log(f"Error parsing noise line from {file_path}: {e}", "WARNING")
        return None


def process_noise_files(extraction_dir: Path) -> List[List]:
    """Find and process all noise files"""
    noise_files = list(extraction_dir.rglob('*_noise.txt'))
    
    if not noise_files:
        log("No noise files found", "DEBUG")
        return []
    
    log(f"Found {len(noise_files)} noise files", "DEBUG")
    
    all_rows = []
    valid_count = 0
    error_count = 0
    
    for noise_file in noise_files:
        if noise_file.stat().st_size == 0:
            continue
        
        try:
            with open(noise_file, 'r') as f:
                for line in f:
                    row = parse_noise_line(line, noise_file)
                    if row:
                        all_rows.append(row)
                        valid_count += 1
                    else:
                        error_count += 1
        except Exception as e:
            log(f"Error reading noise file {noise_file}: {e}", "ERROR")
    
    log(f"Parsed {valid_count} valid noise records, {error_count} errors", "DEBUG")
    return all_rows


def insert_spots(client, spots: List[List], database: str, table: str, batch_size: int) -> bool:
    """Insert spots into ClickHouse in batches - NEW HARMONIZED SCHEMA"""
    if not spots:
        return True

    # New harmonized column names
    column_names = [
        # Harmonized columns matching wsprnet.spots
        'id', 'time', 'band', 'rx_sign', 'rx_lat', 'rx_lon', 'rx_loc',
        'tx_sign', 'tx_lat', 'tx_lon', 'tx_loc', 'distance', 'azimuth', 'rx_azimuth',
        'frequency', 'power', 'snr', 'drift', 'version', 'code',
        # Wsprdaemon-specific columns
        'frequency_mhz', 'rx_id', 'v_lat', 'v_lon', 'c2_noise', 'sync_quality', 'dt',
        'decode_cycles', 'jitter', 'rms_noise', 'blocksize', 'metric', 'osd_decode',
        'nhardmin', 'ipass', 'proxy_upload', 'ov_count', 'rx_status', 'band_m'
    ]

    total_inserted = 0
    for i in range(0, len(spots), batch_size):
        batch = spots[i:i + batch_size]
        try:
            client.insert(f"{database}.{table}", batch, column_names=column_names)
            total_inserted += len(batch)
            log(f"Inserted batch of {len(batch)} spots (total: {total_inserted}/{len(spots)})", "DEBUG")
        except Exception as e:
            log(f"Failed to insert spot batch: {e}", "ERROR")
            return False

    log(f"Inserted {total_inserted} spots into ClickHouse", "INFO")
    return True

def insert_noise(client, noise_records: List[List], database: str, table: str, batch_size: int) -> bool:
    """Insert noise records into ClickHouse in batches with auto-incrementing seqnum"""
    if not noise_records:
        return True

    # Get current max seqnum
    try:
        result = client.query(f"SELECT COALESCE(MAX(seqnum), -1) FROM {database}.{table}")
        next_seqnum = int(result.result_rows[0][0]) + 1
    except Exception as e:
        log(f"Could not query max seqnum, starting from 0: {e}", "WARNING")
        next_seqnum = 0

    # Add seqnum to each row
    noise_with_seqnum = []
    for i, row in enumerate(noise_records):
        noise_with_seqnum.append(row + [next_seqnum + i])

    column_names = ['time', 'site', 'receiver', 'rx_loc', 'band', 'rms_level', 'c2_level', 'ov', 'seqnum']

    total_inserted = 0
    for i in range(0, len(noise_with_seqnum), batch_size):
        batch = noise_with_seqnum[i:i + batch_size]
        try:
            client.insert(f"{database}.{table}", batch, column_names=column_names)
            total_inserted += len(batch)
            log(f"Inserted batch of {len(batch)} noise records (total: {total_inserted}/{len(noise_with_seqnum)})", "DEBUG")
        except Exception as e:
            log(f"Failed to insert noise batch: {e}", "ERROR")
            return False

    log(f"Inserted {total_inserted} noise records into ClickHouse", "INFO")
    return True

def main():
    parser = argparse.ArgumentParser(description='WSPRDAEMON Server')
    parser.add_argument('--clickhouse-user', required=True, help='ClickHouse admin username (required)')
    parser.add_argument('--clickhouse-password', required=True, help='ClickHouse admin password (required)')
    parser.add_argument('--config', help='Path to config file (JSON)')
    parser.add_argument('--loop', type=int, metavar='SECONDS', help='Run continuously with SECONDS delay between checks')
    parser.add_argument('--log-file', default=LOG_FILE, help='Path to log file (if not specified, log to console only)')
    parser.add_argument('--log-max-mb', type=int, default=10, help='Max log file size in MB before truncation')
    parser.add_argument('--verbose', type=int, default=0, choices=range(0, 10), metavar='LEVEL',
                       help='Verbosity level 0-9 (0=WARNING+ERROR, 1=INFO, 2+=DEBUG)')
    args = parser.parse_args()

    if args.log_file:
        setup_logging(args.log_file, args.log_max_mb * 1024 * 1024, verbosity=args.verbose)
    else:
        setup_logging(verbosity=args.verbose)

    # Log version and startup info
    log(f"WSPRDAEMON Server version {VERSION} starting...", "INFO")
    log("=== WSPRDAEMON Server Starting ===", "INFO")
    log(f"Verbosity level: {args.verbose}", "INFO")

    # Load configuration
    config = DEFAULT_CONFIG.copy()
    if args.config:
        with open(args.config) as f:
            config.update(json.load(f))

    # Override with command line credentials
    config['clickhouse_user'] = args.clickhouse_user
    config['clickhouse_password'] = args.clickhouse_password

    log(f"Incoming directories: {config['incoming_tbz_dirs']}", "INFO")

    # Always run setup to ensure database and tables exist
    log("Running setup to ensure ClickHouse is configured...", "INFO")
    success = setup_clickhouse_tables(
        admin_user=args.clickhouse_user,
        admin_password=args.clickhouse_password,
        config=config
    )

    if not success:
        log("Setup failed - cannot continue", "ERROR")
        sys.exit(1)

    # Connect to ClickHouse
    try:
        client = clickhouse_connect.get_client(
            host=config['clickhouse_host'],
            port=config['clickhouse_port'],
            username=config['clickhouse_user'],
            password=config['clickhouse_password']
        )
        log("Connected to ClickHouse", "INFO")
    except Exception as e:
        log(f"Failed to connect to ClickHouse: {e}", "ERROR")
        sys.exit(1)

    # Ensure extraction directory exists
    extraction_dir = Path(config['extraction_dir'])
    extraction_dir.mkdir(parents=True, exist_ok=True)

    processed_file = Path(config['processed_tbz_file'])

    # Main loop
    loop_count = 0
    while True:
        loop_count += 1
        log(f"=== Processing cycle {loop_count} ===", "INFO")

        # Find .tbz files
        tbz_files = find_tbz_files(config['incoming_tbz_dirs'])
        
        if not tbz_files:
            log("No .tbz files found", "INFO")
            if not args.loop:
                break
            log(f"Sleeping {args.loop} seconds...", "DEBUG")
            time.sleep(args.loop)
            continue

        log(f"Found {len(tbz_files)} .tbz files", "INFO")

        # Filter out already processed files
        unprocessed = [f for f in tbz_files if not is_tbz_processed(f, processed_file)]
        
        if not unprocessed:
            log("All .tbz files have been processed", "INFO")
            if not args.loop:
                break
            log(f"Sleeping {args.loop} seconds...", "DEBUG")
            time.sleep(args.loop)
            continue

        log(f"Found {len(unprocessed)} unprocessed .tbz files", "INFO")

        # Process each .tbz file
        for tbz_file in unprocessed:
            log(f"Processing {tbz_file.name}...", "INFO")

            # Clean extraction directory
            if extraction_dir.exists():
                shutil.rmtree(extraction_dir)
            extraction_dir.mkdir(parents=True, exist_ok=True)

            # Extract
            if not extract_tbz(tbz_file, extraction_dir):
                log(f"Failed to extract {tbz_file.name}, skipping", "ERROR")
                continue

            # Get CLIENT_VERSION from uploads_config.txt
            client_version = get_client_version(extraction_dir)
            if client_version:
                log(f"Using CLIENT_VERSION: {client_version}", "DEBUG")
            else:
                log("No CLIENT_VERSION found in uploads_config.txt", "DEBUG")

            # Process spots
            spots = process_spot_files(extraction_dir, client_version, 
                                      client, config['clickhouse_database'], 
                                      config['clickhouse_spots_table'])
            if spots:
                if insert_spots(client, spots, config['clickhouse_database'], 
                              config['clickhouse_spots_table'], config['max_spots_per_insert']):
                    log(f"Successfully processed {len(spots)} spots from {tbz_file.name}", "INFO")
                else:
                    log(f"Failed to insert spots from {tbz_file.name}", "ERROR")
                    continue

            # Process noise
            noise_records = process_noise_files(extraction_dir)
            if noise_records:
                if insert_noise(client, noise_records, config['clickhouse_database'],
                              config['clickhouse_noise_table'], config['max_noise_per_insert']):
                    log(f"Successfully processed {len(noise_records)} noise records from {tbz_file.name}", "INFO")
                else:
                    log(f"Failed to insert noise from {tbz_file.name}", "ERROR")
                    continue

            # Mark as processed
            mark_tbz_processed(tbz_file, processed_file, config['max_processed_file_size'])

            # Delete source .tbz file
            try:
                tbz_file.unlink()
                log(f"Deleted {tbz_file.name}", "INFO")
            except Exception as e:
                log(f"Failed to delete {tbz_file.name}: {e}", "WARNING")

        # Clean up extraction directory
        if extraction_dir.exists():
            shutil.rmtree(extraction_dir)

        if not args.loop:
            break

        log(f"Sleeping {args.loop} seconds...", "DEBUG")
        time.sleep(args.loop)


if __name__ == '__main__':
    main()
