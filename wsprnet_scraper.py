#!/usr/bin/env python3
"""
WSPRNET Scraper - Simple Always-Cache Architecture
- Download thread: Always saves JSON to cache
- Insert thread: Processes cached files in order
No complex gap logic, just save everything and process in order.
"""
import argparse
import json
import sys
import time
import requests
from pathlib import Path
from typing import Dict, List, Optional, Tuple
import clickhouse_connect
import numpy as np
import logging
import os
from datetime import datetime
import threading
import glob

# Version
VERSION = "2.2.4"  # Fixed: spotnum_start should be last_spotnum, not last_spotnum + 1

# Default configuration
DEFAULT_CONFIG = {
    'max_bytes_per_second': 20000,
    'request_timeout': 120,
    'clickhouse_host': 'localhost',
    'clickhouse_port': 8123,
    'clickhouse_user': '',
    'clickhouse_password': '',
    'clickhouse_database': 'wsprnet',
    'clickhouse_table': 'spots',
    'wsprnet_url': 'http://www.wsprnet.org/drupal/wsprnet/spots/json',
    'wsprnet_login_url': 'http://www.wsprnet.org/drupal/rest/user/login',
    'band': 'All',
    'exclude_special': 0,
    'loop_interval': 120,
    'cache_dir': '/var/lib/wsprnet/cache'
}

# Logging configuration
LOG_FILE = 'wsprnet_scraper.log'
LOG_MAX_BYTES = 10 * 1024 * 1024
LOG_KEEP_RATIO = 0.75


class TruncatingFileHandler(logging.FileHandler):
    """File handler that truncates to newest 75% when file grows too large"""
    
    def __init__(self, filename, max_bytes, keep_ratio=0.75):
        self.max_bytes = max_bytes
        self.keep_ratio = keep_ratio
        super().__init__(filename, mode='a', encoding='utf-8')
    
    def emit(self, record):
        super().emit(record)
        self.check_truncate()
    
    def check_truncate(self):
        try:
            if os.path.exists(self.baseFilename):
                current_size = os.path.getsize(self.baseFilename)
                if current_size > self.max_bytes:
                    self.truncate_file()
        except Exception as e:
            print(f"Error checking log file size: {e}")
    
    def truncate_file(self):
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


def setup_logging(log_file=None, max_bytes=LOG_MAX_BYTES, keep_ratio=LOG_KEEP_RATIO):
    """Setup logging"""
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)
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
    """Log a message"""
    logger = logging.getLogger()
    level_map = {
        'DEBUG': logging.DEBUG,
        'INFO': logging.INFO,
        'WARNING': logging.WARNING,
        'ERROR': logging.ERROR,
        'CRITICAL': logging.CRITICAL
    }
    logger.log(level_map.get(level, logging.INFO), message)


def ensure_cache_dir(cache_dir: str) -> bool:
    """Ensure cache directory exists"""
    try:
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        test_file = Path(cache_dir) / '.test_write'
        test_file.touch()
        test_file.unlink()
        return True
    except Exception as e:
        log(f"Failed to create/access cache directory {cache_dir}: {e}", "ERROR")
        return False


def login_wsprnet(username: str, password: str, login_url: str, session_file: Path) -> Optional[Tuple[str, str]]:
    """Login to wsprnet.org"""
    log(f"Attempting to login as {username}...")
    
    login_data = {"name": username, "pass": password}
    headers = {'Content-Type': 'application/json'}
    
    try:
        response = requests.post(login_url, json=login_data, headers=headers, timeout=60)
        
        if response.status_code != 200:
            log(f"Login failed with status code {response.status_code}", "ERROR")
            return None
        
        data = response.json()
        sessid = data.get('sessid', '')
        session_name = data.get('session_name', '')
        
        if not sessid or not session_name:
            log(f"Login response missing sessid or session_name", "ERROR")
            return None
        
        session_data = {
            'sessid': sessid,
            'session_name': session_name,
            'username': username,
            'login_time': time.time()
        }
        
        session_file.parent.mkdir(parents=True, exist_ok=True)
        with open(session_file, 'w') as f:
            json.dump(session_data, f, indent=2)
        
        log(f"Login successful")
        return session_name, sessid
        
    except Exception as e:
        log(f"Login failed: {e}", "ERROR")
        return None


def read_session_file(session_file: Path) -> Optional[Tuple[str, str]]:
    """Read session from file"""
    if not session_file.exists():
        return None
    
    try:
        with open(session_file, 'r') as f:
            data = json.load(f)
        
        sessid = data.get('sessid', '')
        session_name = data.get('session_name', '')
        
        if not sessid or not session_name:
            return None
        
        login_time = data.get('login_time', 0)
        age_hours = (time.time() - login_time) / 3600
        log(f"Using session (age: {age_hours:.1f} hours)")
        
        return session_name, sessid
    except Exception as e:
        return None


def get_session_token(session_file: Path, username: str, password: str, login_url: str) -> Optional[str]:
    """Get session token"""
    session_data = read_session_file(session_file)
    
    if session_data:
        session_name, sessid = session_data
        return f"{session_name}={sessid}"
    
    if not username or not password:
        log("No session and no credentials provided", "ERROR")
        return None
    
    login_result = login_wsprnet(username, password, login_url, session_file)
    if login_result:
        session_name, sessid = login_result
        return f"{session_name}={sessid}"
    
    return None


def get_last_spotnum_from_db(client, database: str, table: str) -> int:
    """Get highest spotnum from database"""
    try:
        result = client.query(f"SELECT max(id) FROM {database}.{table}")
        if result.result_rows and result.result_rows[0][0] is not None:
            return int(result.result_rows[0][0])
        return 0
    except Exception as e:
        log(f"Failed to get last spotnum: {e}", "WARNING")
        return 0


def download_and_cache_spots(session_token: str, last_spotnum: int, config: Dict, cache_dir: str) -> Tuple[bool, bool, int]:
    """
    Download spots and save to cache file
    Returns: (success, auth_failed, highest_spotnum)
    """
    params = {
        'band': config['band'],
        'exclude_special': config['exclude_special'],
        'spotnum_start': last_spotnum  # wsprnet API returns spots with ID > spotnum_start
    }
    
    headers = {'Cookie': session_token}
    
    try:
        response = requests.get(
            config['wsprnet_url'],
            params=params,
            headers=headers,
            timeout=config['request_timeout']
        )
        
        if response.status_code == 403:
            log("Authentication expired", "WARNING")
            return False, True, last_spotnum
        
        if response.status_code != 200:
            log(f"Download failed: {response.status_code}", "ERROR")
            return False, False, last_spotnum
        
        spots = response.json()
        
        if not spots:
            log("No new spots")
            return True, False, last_spotnum
        
        # Sort spots by ID (wsprnet sometimes returns them in reverse order)
        try:
            spots.sort(key=lambda x: int(x.get('Spotnum', 0)))
        except (ValueError, TypeError) as e:
            log(f"Warning: Could not sort spots by ID: {e}", "WARNING")
        
        # Get highest spotnum from this download
        try:
            highest_spotnum = int(spots[-1].get('Spotnum', 0))
        except (ValueError, TypeError):
            highest_spotnum = last_spotnum
        
        # Check for gap between last download and this download
        if len(spots) > 0:
            try:
                first_id = int(spots[0].get('Spotnum', 0))
                if last_spotnum > 0 and first_id > 0 and first_id != last_spotnum + 1:
                    gap_size = first_id - last_spotnum - 1
                    log(f"Gap between downloads: after spot {last_spotnum}, expected {last_spotnum + 1}, got {first_id} (gap of {gap_size})", "WARNING")
            except (ValueError, TypeError):
                pass
        
        # Check for gaps within downloaded data
        if len(spots) > 1:
            gaps_found = 0
            for i in range(1, len(spots)):
                try:
                    prev_id = int(spots[i-1].get('Spotnum', 0))
                    curr_id = int(spots[i].get('Spotnum', 0))
                    
                    if prev_id > 0 and curr_id > 0 and curr_id != prev_id + 1:
                        gap_size = curr_id - prev_id - 1
                        log(f"Gap in downloaded data: after spot {prev_id}, expected {prev_id + 1}, got {curr_id} (gap of {gap_size})", "WARNING")
                        gaps_found += 1
                except (ValueError, TypeError):
                    # Skip spots with bad IDs
                    continue
            
            if gaps_found > 0:
                log(f"Total gaps in this download: {gaps_found}", "WARNING")
        
        # Always save to cache
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        cache_file = Path(cache_dir) / f'spots_{timestamp}.json'
        
        cache_data = {
            'timestamp': timestamp,
            'download_time': time.time(),
            'spot_count': len(spots),
            'first_spotnum': spots[0].get('Spotnum', 0) if spots else 0,
            'last_spotnum': spots[-1].get('Spotnum', 0) if spots else 0,
            'spots': spots
        }
        
        with open(cache_file, 'w') as f:
            json.dump(cache_data, f, indent=2)
        
        log(f"Downloaded and cached {len(spots)} spots to {cache_file.name}")
        return True, False, highest_spotnum
        
    except Exception as e:
        log(f"Download error: {e}", "ERROR")
        return False, False, last_spotnum


def get_cached_files(cache_dir: str) -> List[Path]:
    """Get sorted list of cached files"""
    try:
        cache_path = Path(cache_dir)
        if not cache_path.exists():
            return []
        
        files = sorted(cache_path.glob('spots_*.json'))
        return files
    except Exception as e:
        log(f"Error reading cache: {e}", "ERROR")
        return []


def maidenhead_to_latlon(grid: str) -> Tuple[float, float]:
    """Convert Maidenhead grid to lat/lon"""
    if not grid or len(grid) < 2:
        return 0.0, 0.0
    
    try:
        grid = grid.upper()
        
        lon = (ord(grid[0]) - ord('A')) * 20 - 180
        lat = (ord(grid[1]) - ord('A')) * 10 - 90
        
        if len(grid) >= 4:
            lon += int(grid[2]) * 2
            lat += int(grid[3])
        
        if len(grid) >= 6:
            lon += (ord(grid[4]) - ord('A')) * (2/24)
            lat += (ord(grid[5]) - ord('A')) * (1/24)
        
        lon += 1
        lat += 0.5
        
        return round(lat, 6), round(lon, 6)
    except:
        return 0.0, 0.0


def calculate_azimuth(lat1: float, lon1: float, lat2: float, lon2: float) -> int:
    """Calculate azimuth"""
    if lat1 == 0 and lon1 == 0:
        return 0
    if lat2 == 0 and lon2 == 0:
        return 0
    
    try:
        lat1_rad = np.radians(lat1)
        lat2_rad = np.radians(lat2)
        dlon_rad = np.radians(lon2 - lon1)
        
        x = np.sin(dlon_rad) * np.cos(lat2_rad)
        y = np.cos(lat1_rad) * np.sin(lat2_rad) - np.sin(lat1_rad) * np.cos(lat2_rad) * np.cos(dlon_rad)
        
        azimuth = np.degrees(np.arctan2(x, y))
        azimuth = (azimuth + 360) % 360
        
        return int(round(azimuth))
    except:
        return 0


def process_spot(spot: Dict) -> Optional[tuple]:
    """Process a single spot"""
    try:
        # Safe field extraction
        try:
            spotnum = int(spot.get('Spotnum', 0))
        except:
            spotnum = 0
            
        if spotnum == 0:
            return None
            
        try:
            date = int(spot.get('Date', 0))
        except:
            date = 0
            
        reporter = str(spot.get('Reporter', ''))
        reporter_grid = str(spot.get('ReporterGrid', ''))
        
        try:
            db = int(spot.get('dB', 0))
        except:
            db = 0
            
        try:
            mhz = float(spot.get('MHz', 0))
        except:
            mhz = 0.0
            
        callsign = str(spot.get('CallSign', ''))
        grid = str(spot.get('Grid', ''))
        
        try:
            power = int(spot.get('Power', 0))
        except:
            power = 0
            
        try:
            drift = int(spot.get('Drift', 0))
        except:
            drift = 0
            
        try:
            distance = int(spot.get('distance', 0))
        except:
            distance = 0
            
        try:
            azimuth = int(spot.get('azimuth', 0))
        except:
            azimuth = 0
            
        try:
            band = int(spot.get('Band', 0))
        except:
            band = 0
            
        version = str(spot.get('version', ''))
        
        try:
            code = int(spot.get('code', 0))
        except:
            code = 0
        
        # Calculate positions
        rx_lat, rx_lon = maidenhead_to_latlon(reporter_grid)
        tx_lat, tx_lon = maidenhead_to_latlon(grid)
        
        # Calculate rx_azimuth
        rx_azimuth = calculate_azimuth(tx_lat, tx_lon, rx_lat, rx_lon)
        
        # Convert frequency to Hz
        try:
            frequency_hz = int(mhz * 1_000_000)
        except:
            frequency_hz = 0
        
        row = (
            spotnum, date, band, reporter, rx_lat, rx_lon, reporter_grid,
            callsign, tx_lat, tx_lon, grid, distance, azimuth, rx_azimuth,
            frequency_hz, power, db, drift, version, code
        )
        
        return row
        
    except Exception as e:
        log(f"Error processing spot {spot.get('Spotnum', '?')}: {e}", "WARNING")
        return None


def insert_cached_file(client, cache_file: Path, database: str, table: str) -> bool:
    """Process and insert a cached file"""
    try:
        with open(cache_file, 'r') as f:
            cache_data = json.load(f)
        
        spots = cache_data.get('spots', [])
        
        if not spots:
            log(f"Cache file {cache_file.name} has no spots, deleting")
            cache_file.unlink()
            return True
        
        # Process all spots
        rows = []
        for spot in spots:
            row = process_spot(spot)
            if row:
                rows.append(row)
        
        if not rows:
            log(f"No valid spots in {cache_file.name}, deleting")
            cache_file.unlink()
            return True
        
        # Insert to ClickHouse
        column_names = [
            'id', 'time', 'band', 'rx_sign', 'rx_lat', 'rx_lon', 'rx_loc',
            'tx_sign', 'tx_lat', 'tx_lon', 'tx_loc', 'distance', 'azimuth',
            'rx_azimuth', 'frequency', 'power', 'snr', 'drift', 'version', 'code'
        ]
        
        client.insert(f"{database}.{table}", rows, column_names=column_names)
        
        # Get highest spotnum from inserted rows
        highest_spotnum = max(row[0] for row in rows)
        
        log(f"Inserted {len(rows)} spots from {cache_file.name} (highest id: {highest_spotnum})")
        
        # Delete cache file after successful insert
        cache_file.unlink()
        
        return True
        
    except Exception as e:
        log(f"Failed to insert {cache_file.name}: {e}", "ERROR")
        return False


def insert_thread_worker(config: Dict, cache_dir: str, database: str, table: str, stop_event: threading.Event):
    """Worker thread that processes cached files"""
    log("Insert thread started")
    
    # Create separate ClickHouse client for this thread
    try:
        client = clickhouse_connect.get_client(
            host=config['clickhouse_host'],
            port=config['clickhouse_port'],
            username=config['clickhouse_user'],
            password=config['clickhouse_password']
        )
        log("Insert thread: Connected to ClickHouse")
    except Exception as e:
        log(f"Insert thread: Failed to connect to ClickHouse: {e}", "ERROR")
        return
    
    while not stop_event.is_set():
        try:
            # Get oldest cached file
            cached_files = get_cached_files(cache_dir)
            
            if cached_files:
                oldest_file = cached_files[0]
                # Insert the file
                insert_cached_file(client, oldest_file, database, table)
            else:
                # No files, sleep briefly
                time.sleep(1)
                
        except Exception as e:
            log(f"Insert thread error: {e}", "ERROR")
            time.sleep(5)
    
    log("Insert thread stopped")


def setup_clickhouse_tables(admin_user: str, admin_password: str, 
                            readonly_user: str, readonly_password: str,
                            config: Dict) -> bool:
    """Setup ClickHouse database and tables"""
    try:
        admin_client = clickhouse_connect.get_client(
            host=config['clickhouse_host'],
            port=config['clickhouse_port'],
            username=admin_user,
            password=admin_password
        )
        
        log("Connected to ClickHouse with admin privileges")
        
        # Create readonly user if needed
        try:
            users = admin_client.query("SELECT name FROM system.users").result_rows
            user_names = [user[0] for user in users]
            
            if readonly_user not in user_names:
                log(f"Creating read-only user {readonly_user}...")
                admin_client.command(f"CREATE USER IF NOT EXISTS {readonly_user} IDENTIFIED BY '{readonly_password}'")
                admin_client.command(f"GRANT SELECT ON {config['clickhouse_database']}.* TO {readonly_user}")
                log(f"Read-only user {readonly_user} created")
        except Exception as e:
            log(f"Could not check/create readonly user: {e}", "WARNING")
        
        # Create database
        result = admin_client.query(
            f"SELECT 1 FROM system.databases WHERE name = '{config['clickhouse_database']}'"
        )
        
        if not result.result_rows:
            log(f"Creating database {config['clickhouse_database']}...")
            admin_client.command(f"CREATE DATABASE {config['clickhouse_database']}")
            log(f"Database {config['clickhouse_database']} created")
        else:
            log(f"Database {config['clickhouse_database']} exists")
        
        # Create table
        create_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {config['clickhouse_database']}.{config['clickhouse_table']}
        (
            id UInt64 CODEC(Delta(8), ZSTD(1)),
            time DateTime CODEC(Delta(4), ZSTD(1)),
            band Int16 CODEC(T64, ZSTD(1)),
            rx_sign LowCardinality(String),
            rx_lat Float32 CODEC(ZSTD(1)),
            rx_lon Float32 CODEC(ZSTD(1)),
            rx_loc LowCardinality(String),
            tx_sign LowCardinality(String),
            tx_lat Float32 CODEC(ZSTD(1)),
            tx_lon Float32 CODEC(ZSTD(1)),
            tx_loc LowCardinality(String),
            distance UInt16 CODEC(T64, ZSTD(1)),
            azimuth UInt16 CODEC(T64, ZSTD(1)),
            rx_azimuth UInt16 CODEC(T64, ZSTD(1)),
            frequency UInt64 CODEC(T64, ZSTD(1)),
            power Int8 CODEC(T64, ZSTD(1)),
            snr Int8 CODEC(ZSTD(1)),
            drift Int8 CODEC(ZSTD(1)),
            version LowCardinality(String),
            code Int8,
            
            Spotnum UInt64 ALIAS id,
            Date UInt32 ALIAS toUnixTimestamp(time),
            Reporter String ALIAS rx_sign,
            ReporterGrid String ALIAS rx_loc,
            dB Int8 ALIAS snr,
            MHz Float32 ALIAS frequency / 1000000.0,
            CallSign String ALIAS tx_sign,
            Grid String ALIAS tx_loc,
            Power Int8 ALIAS power,
            Drift Int8 ALIAS drift,
            Band Int16 ALIAS band,
            rx_az UInt16 ALIAS rx_azimuth
        )
        ENGINE = MergeTree
        PARTITION BY toYYYYMM(time)
        ORDER BY (time, id)
        SETTINGS index_granularity = 8192
        """
        
        admin_client.command(create_table_sql)
        log(f"Table {config['clickhouse_database']}.{config['clickhouse_table']} created/verified")
        
        return True
    
    except Exception as e:
        log(f"Setup failed: {e}", "ERROR")
        return False


def main():
    parser = argparse.ArgumentParser(description='WSPRNET Scraper - Simple Always-Cache')
    
    parser.add_argument('--session-file', required=True, help='Session file path')
    parser.add_argument('--username', help='WSPRNET username')
    parser.add_argument('--password', help='WSPRNET password')
    
    parser.add_argument('--clickhouse-user', required=True, help='ClickHouse admin user')
    parser.add_argument('--clickhouse-password', required=True, help='ClickHouse admin password')
    parser.add_argument('--setup-readonly-user', required=True, help='Read-only user')
    parser.add_argument('--setup-readonly-password', required=True, help='Read-only password')
    
    parser.add_argument('--config', help='Config file (JSON)')
    parser.add_argument('--cache-dir', help='Cache directory')
    parser.add_argument('--loop', type=int, metavar='SECONDS', help='Loop interval')
    parser.add_argument('--log-file', default=LOG_FILE, help='Log file path')
    parser.add_argument('--log-max-mb', type=int, default=10, help='Max log size MB')
    parser.add_argument('--verbose', type=int, default=1, choices=[0, 1, 2], 
                        help='Verbosity level (ignored, for compatibility)')
    
    args = parser.parse_args()
    
    if args.log_file:
        setup_logging(args.log_file, args.log_max_mb * 1024 * 1024)
    else:
        setup_logging()
    
    # Log startup banner with version
    log("")  # Blank line for separation
    log("=" * 70)
    log(f"WSPRNET Scraper version {VERSION} starting...")
    log("Architecture: Always-cache with separate insert thread")
    log("=" * 70)
    
    # Load config
    config = DEFAULT_CONFIG.copy()
    if args.config:
        with open(args.config) as f:
            config.update(json.load(f))
    
    if args.cache_dir:
        config['cache_dir'] = args.cache_dir
    
    if args.loop:
        config['loop_interval'] = args.loop
    
    # Ensure cache dir
    if not ensure_cache_dir(config['cache_dir']):
        log("Cannot create cache directory!", "ERROR")
        sys.exit(1)
    
    log(f"Cache directory: {config['cache_dir']}")
    
    config['clickhouse_user'] = args.clickhouse_user
    config['clickhouse_password'] = args.clickhouse_password
    
    # Setup ClickHouse
    log("Setting up ClickHouse...")
    success = setup_clickhouse_tables(
        admin_user=args.clickhouse_user,
        admin_password=args.clickhouse_password,
        readonly_user=args.setup_readonly_user,
        readonly_password=args.setup_readonly_password,
        config=config
    )
    
    if not success:
        log("Setup failed", "ERROR")
        sys.exit(1)
    
    session_file = Path(args.session_file)
    
    # Get session
    session_token = get_session_token(
        session_file,
        args.username or '',
        args.password or '',
        config['wsprnet_login_url']
    )
    
    if not session_token:
        log("Failed to get session", "ERROR")
        sys.exit(1)
    
    # Connect to ClickHouse
    try:
        client = clickhouse_connect.get_client(
            host=config['clickhouse_host'],
            port=config['clickhouse_port'],
            username=config['clickhouse_user'],
            password=config['clickhouse_password']
        )
        log("Connected to ClickHouse")
    except Exception as e:
        log(f"Failed to connect: {e}", "ERROR")
        sys.exit(1)
    
    # Get starting point
    last_spotnum = get_last_spotnum_from_db(client, config['clickhouse_database'], config['clickhouse_table'])
    log(f"Starting from spotnum: {last_spotnum}")
    
    # Start insert thread
    stop_event = threading.Event()
    insert_thread = threading.Thread(
        target=insert_thread_worker,
        args=(config, config['cache_dir'], config['clickhouse_database'], config['clickhouse_table'], stop_event),
        daemon=True
    )
    insert_thread.start()
    
    # Main download loop
    loop_count = 0
    
    try:
        while True:
            loop_count += 1
            log(f"Download cycle {loop_count}")
            
            success, auth_failed, new_spotnum = download_and_cache_spots(
                session_token,
                last_spotnum,
                config,
                config['cache_dir']
            )
            
            if auth_failed:
                log("Re-authenticating...")
                if session_file.exists():
                    session_file.unlink()
                
                session_token = get_session_token(
                    session_file,
                    args.username or '',
                    args.password or '',
                    config['wsprnet_login_url']
                )
                
                if not session_token:
                    log("Re-auth failed", "ERROR")
                    time.sleep(60)
                    continue
                
                # Retry
                success, auth_failed, new_spotnum = download_and_cache_spots(
                    session_token,
                    last_spotnum,
                    config,
                    config['cache_dir']
                )
            
            # Update last_spotnum from download
            if new_spotnum > last_spotnum:
                last_spotnum = new_spotnum
            
            # Show cache status
            cached_files = get_cached_files(config['cache_dir'])
            if cached_files:
                log(f"Cache status: {len(cached_files)} files pending")
            
            if not args.loop:
                break
            
            log(f"Sleeping {config['loop_interval']} seconds...")
            time.sleep(config['loop_interval'])
    
    except KeyboardInterrupt:
        log("Shutting down...")
        stop_event.set()
        insert_thread.join(timeout=5)
    
    log("Stopped")


if __name__ == '__main__':
    main()
