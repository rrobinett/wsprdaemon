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

# Default configuration
DEFAULT_CONFIG = {
    'clickhouse_host': 'localhost',
    'clickhouse_port': 8123,
    'clickhouse_user': '',
    'clickhouse_password': '',
    'clickhouse_database': 'wsprdaemon',
    'clickhouse_spots_table': 'spots',
    'clickhouse_noise_table': 'noise',
    'incoming_tbz_dirs': ['/var/spool/wsprdaemon/from-wd0', '/var/spool/wsprdaemon/from-wd00'],
    'extraction_dir': f'/run/user/{os.getuid()}/wsprdaemon',
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
                           readonly_user: str, readonly_password: str,
                           default_password: str, config: Dict) -> bool:
    """Setup ClickHouse users, database, and tables"""
    try:
        # Connect as default user to create users
        admin_client = clickhouse_connect.get_client(
            host=config['clickhouse_host'],
            port=config['clickhouse_port'],
            username='default',
            password=default_password
        )

        # Check/create admin user
        result = admin_client.query(
            f"SELECT count() FROM system.users WHERE name = '{admin_user}'"
        )
        if result.result_rows[0][0] == 1:
            log(f"Admin user {admin_user} already exists", "INFO")
        else:
            log(f"Creating admin user {admin_user}...", "INFO")
            admin_client.command(f"CREATE USER `{admin_user}` IDENTIFIED BY '{admin_password}'")
            admin_client.command(f"GRANT CREATE DATABASE ON *.* TO `{admin_user}`")
            admin_client.command(f"GRANT CREATE TABLE ON *.* TO `{admin_user}`")
            admin_client.command(f"GRANT INSERT ON {config['clickhouse_database']}.* TO `{admin_user}`")
            admin_client.command(f"GRANT SELECT ON {config['clickhouse_database']}.* TO `{admin_user}`")
            admin_client.command(f"GRANT DROP TABLE ON {config['clickhouse_database']}.* TO `{admin_user}`")
            log(f"Admin user {admin_user} created", "INFO")

        # Check/create read-only user
        result = admin_client.query(
            f"SELECT count() FROM system.users WHERE name = '{readonly_user}'"
        )
        if result.result_rows[0][0] == 1:
            log(f"Read-only user {readonly_user} already exists", "INFO")
        else:
            log(f"Creating read-only user {readonly_user}...", "INFO")
            admin_client.command(f"CREATE USER `{readonly_user}` IDENTIFIED BY '{readonly_password}'")
            admin_client.command(f"GRANT SELECT ON {config['clickhouse_database']}.* TO `{readonly_user}`")
            log(f"Read-only user {readonly_user} created", "INFO")

        # Connect as admin user to create database/table
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

        # Create spots table with ALL wsprnet.spots columns PLUS wsprdaemon extras
        create_spots_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {config['clickhouse_database']}.{config['clickhouse_spots_table']}
        (
            -- ALL columns from wsprnet.spots (EXACT same names and order)
            Spotnum        Nullable(UInt64)        CODEC(Delta(8), ZSTD(1)),
            Date           Nullable(UInt32)        CODEC(Delta(4), ZSTD(1)),
            Reporter       LowCardinality(String)  CODEC(LZ4),
            ReporterGrid   LowCardinality(String)  CODEC(LZ4),
            dB             Float32                 CODEC(Delta(4), ZSTD(3)),
            MHz            Float64                 CODEC(Delta(8), ZSTD(3)),
            CallSign       LowCardinality(String)  CODEC(LZ4),
            Grid           LowCardinality(String)  CODEC(LZ4),
            Power          UInt8                   CODEC(T64, ZSTD(1)),
            Drift          Float32                 CODEC(Delta(4), ZSTD(3)),
            distance       Int32                   CODEC(T64, ZSTD(1)),
            azimuth        Float32                 CODEC(Delta(4), ZSTD(3)),
            Band           Nullable(Int16)         CODEC(T64, ZSTD(1)),
            version        LowCardinality(Nullable(String)) CODEC(LZ4),
            code           Int16                   CODEC(ZSTD(1)),
            time           DateTime DEFAULT toDateTime(Date) CODEC(Delta(4), ZSTD(1)),
            band           Int16                   CODEC(T64, ZSTD(1)),
            rx_az          Float32                 CODEC(Delta(4), ZSTD(3)),
            rx_lat         Float32                 CODEC(Delta(4), ZSTD(3)),
            rx_lon         Float32                 CODEC(Delta(4), ZSTD(3)),
            tx_lat         Float32                 CODEC(Delta(4), ZSTD(3)),
            tx_lon         Float32                 CODEC(Delta(4), ZSTD(3)),
            
            -- Wsprdaemon-specific additional fields (NOT in wsprnet.spots)
            rx_id          LowCardinality(String)  CODEC(LZ4),
            v_lat          Float32                 CODEC(Delta(4), ZSTD(3)),
            v_lon          Float32                 CODEC(Delta(4), ZSTD(3)),
            c2_noise       Float32                 CODEC(Delta(4), ZSTD(3)),
            sync_quality   UInt16                  CODEC(ZSTD(1)),
            dt             Float32                 CODEC(Delta(4), ZSTD(3)),
            decode_cycles  UInt32                  CODEC(T64, ZSTD(1)),
            jitter         Int16                   CODEC(T64, ZSTD(1)),
            rms_noise      Float32                 CODEC(Delta(4), ZSTD(3)),
            blocksize      UInt16                  CODEC(T64, ZSTD(1)),
            metric         Int16                   CODEC(T64, ZSTD(1)),
            osd_decode     UInt8                   CODEC(T64, ZSTD(1)),
            nhardmin       UInt16                  CODEC(T64, ZSTD(1)),
            ipass          UInt8                   CODEC(T64, ZSTD(1)),
            proxy_upload   UInt8                   CODEC(T64, ZSTD(1)),
            ov_count       UInt32                  CODEC(T64, ZSTD(1)),
            rx_status      LowCardinality(String)  DEFAULT 'No Info' CODEC(LZ4)
        ) 
        ENGINE = MergeTree
        PARTITION BY toYYYYMM(time)
        ORDER BY (time)
        SETTINGS index_granularity = 8192
        """
        admin_client.command(create_spots_table_sql)
        log(f"Table {config['clickhouse_database']}.{config['clickhouse_spots_table']} created/verified", "INFO")

        # Create noise table
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
            ov         Nullable(Int32)
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


def get_receiver_name_from_path(file_path: Path) -> str:
    """Extract receiver name from file path (2 levels up from file)"""
    parts = file_path.parts
    if len(parts) >= 3:
        return parts[-3]
    return "unknown"


def parse_spot_line(line: str, file_path: Path) -> Optional[List]:
    """Parse a 34-field spot line into ClickHouse row format - HARMONIZED with wsprnet.spots"""
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
        
        # Calculate Date (Unix timestamp) for compatibility with wsprnet.spots
        date_timestamp = int(clickhouse_time.timestamp())
        
        # Extract receiver name from file path
        rx_id = get_receiver_name_from_path(file_path)
        
        # Build row matching ALL wsprnet.spots columns PLUS wsprdaemon extras
        row = [
            # ALL wsprnet.spots columns (in exact same order)
            None,                      # Spotnum (NULL for wsprdaemon data)
            date_timestamp,            # Date (Unix timestamp)
            fields[22],                # Reporter
            fields[21],                # ReporterGrid
            float(fields[3]),          # dB
            float(fields[5]),          # MHz
            fields[6],                 # CallSign
            fields[7],                 # Grid
            int(fields[8]),            # Power
            float(fields[9]),          # Drift
            int(fields[23]),           # distance
            float(fields[27]),         # azimuth
            int(float(fields[5])),     # Band (uppercase - integer MHz from frequency)
            None,                      # version (NULL for wsprdaemon data)
            int(fields[17]),           # code
            clickhouse_time,           # time
            int(fields[20]),           # band (lowercase)
            float(fields[24]),         # rx_az
            float(fields[25]),         # rx_lat
            float(fields[26]),         # rx_lon
            float(fields[28]),         # tx_lat
            float(fields[29]),         # tx_lon
            
            # Wsprdaemon-specific additional fields
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
            'No Info'                  # rx_status
        ]
        
        return row
    
    except (ValueError, IndexError) as e:
        log(f"Error parsing spot line: {e}", "WARNING")
        return None


def process_spot_files(extraction_dir: Path) -> List[List]:
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
                    row = parse_spot_line(line, spot_file)
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
    """Parse a 15-field noise line into ClickHouse row format"""
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
        site = site_parts[0].replace('=', '/')  # Handle callsigns with / encoded as =
        rx_loc = site_parts[1] if len(site_parts) > 1 else ''
        
        # Extract receiver (e.g., "KA9Q_0")
        receiver = parts[-3]
        
        # Extract band (e.g., "20")
        band = parts[-2]
        
        # Fields 13, 14, 15 (0-indexed: 12, 13, 14) are rms_level, c2_level, ov
        rms_level = float(fields[12])
        c2_level = float(fields[13])
        ov = int(float(fields[14]))
        
        row = [
            clickhouse_time,
            site,
            receiver,
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
    """Insert spots into ClickHouse in batches - ALL wsprnet.spots columns + extras"""
    if not spots:
        return True

    # Column names: ALL from wsprnet.spots + wsprdaemon extras
    column_names = [
        # ALL wsprnet.spots columns
        'Spotnum', 'Date', 'Reporter', 'ReporterGrid', 'dB', 'MHz', 'CallSign', 'Grid',
        'Power', 'Drift', 'distance', 'azimuth', 'Band', 'version', 'code',
        'time', 'band', 'rx_az', 'rx_lat', 'rx_lon', 'tx_lat', 'tx_lon',
        # Wsprdaemon-specific additional columns
        'rx_id', 'v_lat', 'v_lon', 'c2_noise', 'sync_quality', 'dt', 
        'decode_cycles', 'jitter', 'rms_noise', 'blocksize', 'metric', 'osd_decode',
        'nhardmin', 'ipass', 'proxy_upload', 'ov_count', 'rx_status'
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
    """Insert noise records into ClickHouse in batches"""
    if not noise_records:
        return True

    column_names = ['time', 'site', 'receiver', 'rx_loc', 'band', 'rms_level', 'c2_level', 'ov']

    total_inserted = 0
    for i in range(0, len(noise_records), batch_size):
        batch = noise_records[i:i + batch_size]
        try:
            client.insert(f"{database}.{table}", batch, column_names=column_names)
            total_inserted += len(batch)
            log(f"Inserted batch of {len(batch)} noise records (total: {total_inserted}/{len(noise_records)})", "DEBUG")
        except Exception as e:
            log(f"Failed to insert noise batch: {e}", "ERROR")
            return False

    log(f"Inserted {total_inserted} noise records into ClickHouse", "INFO")
    return True


def main():
    parser = argparse.ArgumentParser(description='WSPRDAEMON Server')
    parser.add_argument('--clickhouse-user', required=True, help='ClickHouse admin username (required)')
    parser.add_argument('--clickhouse-password', required=True, help='ClickHouse admin password (required)')
    parser.add_argument('--setup-default-password', required=True, help='Default ClickHouse password (required)')
    parser.add_argument('--setup-readonly-user', required=True, help='Read-only username (required)')
    parser.add_argument('--setup-readonly-password', required=True, help='Read-only password (required)')
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

    # Force initial log entries
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

    # Always run setup to ensure users, database, and tables exist
    log("Running setup to ensure ClickHouse is configured...", "INFO")
    success = setup_clickhouse_tables(
        admin_user=args.clickhouse_user,
        admin_password=args.clickhouse_password,
        readonly_user=args.setup_readonly_user,
        readonly_password=args.setup_readonly_password,
        default_password=args.setup_default_password,
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

            # Process spots
            spots = process_spot_files(extraction_dir)
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
