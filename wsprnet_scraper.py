#!/usr/bin/env python3
"""
WSPRNET Scraper - Download spots from wsprnet.org and store in ClickHouse
Usage: wsprnet_scraper.py --session-file <path> --username <user> --password <pass> [options]
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
    'loop_interval': 120
}

# Field mapping from wsprnet JSON
WSPRNET_FIELDS = [
    "Spotnum", "Date", "Reporter", "ReporterGrid", "dB", "MHz",
    "CallSign", "Grid", "Power", "Drift", "distance", "azimuth",
    "Band", "version", "code"
]

# Frequency to band mapping
FREQ_TO_BAND = {
    1: 2200, 4: 630, 18: 160, 35: 80, 52: 60, 53: 60, 70: 40,
    101: 30, 140: 20, 181: 17, 210: 15, 249: 12, 281: 10,
    502: 6, 700: 4, 1444: 2, 4323: 70, 12965: 23
}
DEFAULT_BAND = 9999


# Logging configuration
LOG_FILE = 'wsprnet_scraper.log'
LOG_MAX_BYTES = 10 * 1024 * 1024  # 10MB
LOG_KEEP_RATIO = 0.75  # Keep newest 75%

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
            # Don't let truncation errors break logging
            print(f"Error checking log file size: {e}")

    def truncate_file(self):
        """Keep only the newest 75% of the file"""
        try:
            # Read the file
            with open(self.baseFilename, 'r', encoding='utf-8') as f:
                lines = f.readlines()

            # Calculate how many lines to keep
            keep_count = int(len(lines) * self.keep_ratio)
            if keep_count < 1:
                keep_count = 1

            # Keep only the newest lines
            new_lines = lines[-keep_count:]

            # Rewrite the file
            with open(self.baseFilename, 'w', encoding='utf-8') as f:
                f.write(f"[Log truncated - kept newest {self.keep_ratio*100:.0f}% of {len(lines)} lines]\n")
                f.writelines(new_lines)

            old_size = sum(len(line.encode('utf-8')) for line in lines)
            new_size = os.path.getsize(self.baseFilename)
            logging.info(f"Log file truncated from {old_size:,} to {new_size:,} bytes")

        except Exception as e:
            print(f"Error truncating log file: {e}")


def setup_logging(log_file=None, max_bytes=LOG_MAX_BYTES, keep_ratio=LOG_KEEP_RATIO):
    """Setup logging - either to file OR console, not both"""
    logger = logging.getLogger()
    logger.setLevel(logging.INFO)

    # Clear any existing handlers
    logger.handlers.clear()

    if log_file:
        # File handler with truncation (no console)
        file_handler = TruncatingFileHandler(log_file, max_bytes, keep_ratio)
        file_formatter = logging.Formatter('[%(asctime)s] %(levelname)s: %(message)s',
                                          datefmt='%Y-%m-%d %H:%M:%S')
        file_handler.setFormatter(file_formatter)
        logger.addHandler(file_handler)
    else:
        # Console handler only (no file)
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

def login_wsprnet(username: str, password: str, login_url: str, session_file: Path) -> Optional[Tuple[str, str]]:
    """Login to wsprnet.org and save session"""
    log(f"Attempting to login as {username}...")
    
    login_data = {"name": username, "pass": password}
    headers = {'Content-Type': 'application/json'}
    
    try:
        response = requests.post(login_url, json=login_data, headers=headers, timeout=60)
        
        if response.status_code != 200:
            log(f"Login failed with status code {response.status_code}", "ERROR")
            return None
        
        try:
            data = response.json()
            sessid = data.get('sessid', '')
            session_name = data.get('session_name', '')
            
            if not sessid or not session_name:
                log(f"Login response missing sessid or session_name: {response.text}", "ERROR")
                return None
            
            # Save session to file
            session_data = {
                'sessid': sessid,
                'session_name': session_name,
                'username': username,
                'login_time': time.time()
            }
            
            session_file.parent.mkdir(parents=True, exist_ok=True)
            with open(session_file, 'w') as f:
                json.dump(session_data, f, indent=2)
            
            log(f"Login successful, session saved to {session_file}")
            return session_name, sessid
            
        except json.JSONDecodeError as e:
            log(f"Failed to parse login response: {e}", "ERROR")
            log(f"Response was: {response.text}", "ERROR")
            return None
            
    except requests.RequestException as e:
        log(f"Login request failed: {e}", "ERROR")
        return None


def read_session_file(session_file: Path) -> Optional[Tuple[str, str]]:
    """Read session name and ID from session file"""
    if not session_file.exists():
        log(f"Session file {session_file} does not exist", "WARNING")
        return None
    
    try:
        with open(session_file, 'r') as f:
            data = json.load(f)
            sessid = data.get('sessid', '')
            session_name = data.get('session_name', '')
            
            if not sessid or not session_name:
                log("Session file missing sessid or session_name", "WARNING")
                return None
            
            login_time = data.get('login_time', 0)
            age_hours = (time.time() - login_time) / 3600
            log(f"Using session from {session_file} (age: {age_hours:.1f} hours)")
            
            return session_name, sessid
    except Exception as e:
        log(f"Failed to read session file: {e}", "WARNING")
        return None


def get_session_token(session_file: Path, username: str, password: str, login_url: str) -> Optional[str]:
    """Get session token, logging in if necessary"""
    # Try to read existing session
    session = read_session_file(session_file)
    
    if session:
        session_name, sessid = session
        return f"{session_name}={sessid}"
    
    # Need to login
    if not username or not password:
        log("No valid session and no credentials provided", "ERROR")
        return None
    
    session = login_wsprnet(username, password, login_url, session_file)
    if session:
        session_name, sessid = session
        return f"{session_name}={sessid}"
    
    return None

def validate_spot_timing(date_epoch: int, code: int, spotnum: int = 0) -> Tuple[bool, int, str]:
    """Validate spot timing based on mode
    Returns: (is_valid, corrected_epoch, message)
    """
    spot_minute = ((date_epoch % 3600) // 60)
    is_odd_minute = (spot_minute % 2) == 1
    
    # Valid minutes for each mode
    valid_mode_1 = set(range(0, 60, 2))   # WSPR-2: even minutes
    valid_mode_3 = set(range(0, 60, 2))   # FST4W-120: even minutes
    valid_mode_2 = set(range(0, 60, 15))  # FST4W-900: 0,15,30,45
    valid_mode_4 = set(range(0, 60, 5))   # FST4W-300: 0,5,10,15...
    valid_mode_8 = set(range(0, 60, 30))  # FST4W-1800: 0,30
    
    mode_info = {
        1: (2, valid_mode_1, "WSPR-2"),
        3: (2, valid_mode_3, "FST4W-120"),
        2: (15, valid_mode_2, "FST4W-900"),
        4: (5, valid_mode_4, "FST4W-300"),
        8: (30, valid_mode_8, "FST4W-1800")
    }
    
    if code not in mode_info:
        # Invalid mode - force to even minute if odd
        if is_odd_minute:
            corrected = date_epoch + 60
            date_str = time.strftime('%Y-%m-%d %H:%M', time.gmtime(date_epoch))
            msg = f"Spot {spotnum}: Invalid mode {code} at odd minute {spot_minute} ({date_str}), corrected to next even minute"
            return False, corrected, msg
        msg = f"Spot {spotnum}: Invalid mode {code} at even minute {spot_minute}, kept as-is"
        return False, date_epoch, msg
    
    spot_length, valid_minutes, mode_name = mode_info[code]
    
    if spot_minute in valid_minutes:
        return True, date_epoch, ""
    
    # Invalid minute for this mode
    date_str = time.strftime('%Y-%m-%d %H:%M', time.gmtime(date_epoch))
    if is_odd_minute:
        corrected = date_epoch + 60
        corrected_str = time.strftime('%Y-%m-%d %H:%M', time.gmtime(corrected))
        msg = f"Spot {spotnum}: Mode {code} ({mode_name}, {spot_length} min) at invalid odd minute {spot_minute} ({date_str}), corrected to {corrected_str}"
        return False, corrected, msg
    else:
        msg = f"Spot {spotnum}: Mode {code} ({mode_name}, {spot_length} min) at invalid even minute {spot_minute} ({date_str}), kept as-is"
        return False, date_epoch, msg

def summarize_spots_by_date(spots: List[Dict]):
    """Print summary of spots grouped by Date epoch"""
    from collections import defaultdict
    
    date_counts = defaultdict(int)
    for spot in spots:
        date_epoch = int(spot.get('Date', 0))
        date_counts[date_epoch] += 1
    
    if not date_counts:
        return
    
    sorted_dates = sorted(date_counts.keys())
    log(f"Spot summary: {len(date_counts)} unique dates/times")
    
    for date_epoch in sorted_dates:
        count = date_counts[date_epoch]
        date_str = time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(date_epoch))
        log(f"  {date_str}: {count:4d} spots")
    
    if len(sorted_dates) > 1:
        time_span_minutes = (sorted_dates[-1] - sorted_dates[0]) / 60
        log(f"Time span: {time_span_minutes:.0f} minutes")

def validate_json(json_text: str) -> Tuple[Optional[List[Dict]], str]:
    """Validate JSON and return (spots, status)
    Status: 'valid', 'repaired', 'failed'
    """
    # Check for obviously bad responses
    if not json_text or len(json_text) < 10:
        return None, 'failed'
    
    if "You are not authorized" in json_text:
        return None, 'auth_failed'
    
    # Try to parse as-is
    try:
        spots = json.loads(json_text)
        if not isinstance(spots, list):
            log(f"JSON is not a list: {type(spots)}", "ERROR")
            return None, 'failed'
        
        if len(spots) == 0:
            log("JSON is valid but empty", "WARNING")
            return [], 'valid'
        
        # Validate first and last spot have required fields
        required_fields = ['Spotnum', 'Date', 'Reporter', 'Grid', 'MHz']
        for field in required_fields:
            if field not in spots[0] or field not in spots[-1]:
                log(f"Missing required field: {field}", "ERROR")
                return None, 'failed'
        
        log(f"JSON is valid with {len(spots)} spots")
        return spots, 'valid'
        
    except json.JSONDecodeError as e:
        log(f"JSON parse error at position {e.pos}: {e.msg}", "WARNING")
        # Try to repair
        spots = repair_json(json_text)
        if spots:
            return spots, 'repaired'
        return None, 'failed'


def download_spots(session_token: str, spotnum_start: int, config: Dict) -> Tuple[Optional[List[Dict]], bool]:
    """Download spots from wsprnet.org
    Returns: (spots_list, auth_failed)
    """
    post_data = {
        "spotnum_start": str(spotnum_start),
        "band": config["band"],
        "callsign": "",
        "reporter": "",
        "exclude_special": str(config["exclude_special"])
    }
    
    url = f'{config["wsprnet_url"]}?band={config["band"]}&spotnum_start={spotnum_start}&exclude_special={config["exclude_special"]}'
    
    headers = {'Content-Type': 'application/json'}
    cookies = dict(item.split("=") for item in session_token.split(";"))
    
    log(f"Downloading spots starting from {spotnum_start}...")
    start_time = time.time()
    
    try:
        response = requests.post(
            url,
            json=post_data,
            headers=headers,
            cookies=cookies,
            timeout=config['request_timeout'],
            stream=True
        )
        
        download_time = time.time() - start_time
        
        if response.status_code != 200:
            log(f"Download failed with status code {response.status_code}", "ERROR")
            return None, False
        
        response_text = response.text
        
        # Validate the JSON
        spots, status = validate_json(response_text)
        
        if status == 'auth_failed':
            return None, True
        
        if status == 'failed':
            log(f"JSON validation failed after {download_time:.1f}s", "ERROR")
            return None, False
        
        if status == 'repaired':
            log(f"Downloaded and repaired {len(spots)} spots in {download_time:.1f}s", "WARNING")
        else:
            log(f"Downloaded {len(spots)} spots in {download_time:.1f}s ({len(response_text)} bytes)")
        
        return spots, False
            
    except requests.Timeout:
        log(f"Request timeout after {config['request_timeout']} seconds", "ERROR")
        return None, False
    except requests.RequestException as e:
        log(f"Download failed: {e}", "ERROR")
        return None, False

def repair_json(json_text: str) -> Optional[List[Dict]]:
    """Attempt to repair truncated JSON by finding last valid record"""
    # Try to find the last complete record ending with }]
    for i in range(len(json_text) - 1, -1, -1):
        if json_text[i] == ']':
            try:
                test_json = json_text[:i+1]
                data = json.loads(test_json)
                if isinstance(data, list) and len(data) > 0:
                    log(f"Repaired JSON - recovered {len(data)} spots", "WARNING")
                    return data
            except:
                continue
    return None


def loc_to_lat_lon(locator: str) -> Tuple[float, float]:
    """Convert Maidenhead locator to lat/lon"""
    locator = locator.strip()
    if len(locator) < 4:
        return (0.0, 0.0)
    
    decomp = list(locator)
    lat = (((ord(decomp[1])-65)*10)+(ord(decomp[3])-48)+(1/2)-90)
    lon = (((ord(decomp[0])-65)*20)+((ord(decomp[2])-48)*2)+(1)-180)
    
    if len(locator) == 6:
        ascii_base = 96 if ord(decomp[4]) > 88 else 64
        lat = lat-(1/2)+((ord(decomp[5])-ascii_base)/24)-(1/48)
        lon = lon-(1)+((ord(decomp[4])-ascii_base)/12)-(1/24)
    
    return (lat, lon)

def calculate_azimuth(frequency: float, tx_locator: str, rx_locator: str) -> Dict:
    """Calculate azimuth and location data"""
    try:
        (tx_lat, tx_lon) = loc_to_lat_lon(tx_locator)
        (rx_lat, rx_lon) = loc_to_lat_lon(rx_locator)
        
        phi_tx = np.radians(tx_lat)
        lambda_tx = np.radians(tx_lon)
        phi_rx = np.radians(rx_lat)
        lambda_rx = np.radians(rx_lon)
        
        delta_lambda = lambda_tx - lambda_rx
        
        # RX azimuth
        y = np.sin(delta_lambda) * np.cos(phi_tx)
        x = np.cos(phi_rx)*np.sin(phi_tx) - np.sin(phi_rx)*np.cos(phi_tx)*np.cos(delta_lambda)
        rx_azi = (np.degrees(np.arctan2(y, x))) % 360
        
        # Calculate band
        freq = int(10 * float(frequency))
        band = FREQ_TO_BAND.get(freq, DEFAULT_BAND)
        
        return {
            'wd_band': band,
            'wd_rx_az': int(round(rx_azi)),
            'wd_rx_lat': round(rx_lat, 3),
            'wd_rx_lon': round(rx_lon, 3),
            'wd_tx_lat': round(tx_lat, 3),
            'wd_tx_lon': round(tx_lon, 3)
        }
    except Exception as e:
        log(f"Azimuth calculation failed: {e}", "WARNING")
        return {
            'wd_band': DEFAULT_BAND,
            'wd_rx_az': 0,
            'wd_rx_lat': 0.0,
            'wd_rx_lon': 0.0,
            'wd_tx_lat': 0.0,
            'wd_tx_lon': 0.0
        }

def detect_gaps(spots: List[Dict], last_spotnum: int) -> List[Tuple[int, int]]:
    """Detect gaps in spot numbers
    Returns: List of (first_missing, last_missing) tuples
    """
    if not spots:
        return []

    gaps = []
    sorted_spots = sorted(spots, key=lambda s: int(s.get('Spotnum', 0)))

    first_spotnum = int(sorted_spots[0].get('Spotnum', 0))
    last_in_batch = int(sorted_spots[-1].get('Spotnum', 0))

    log(f"Current batch: {len(spots)} spots, range {first_spotnum} to {last_in_batch}")
    log(f"Previous highest spotnum: {last_spotnum}")

    # Check gap before first spot
    if last_spotnum > 0 and first_spotnum > last_spotnum + 1:
        gap_size = first_spotnum - last_spotnum - 1
        gaps.append((last_spotnum + 1, first_spotnum - 1))
        log(f"GAP: Expected spotnum {last_spotnum + 1}, got {first_spotnum} (missing {gap_size} spots)", "WARNING")

    # Check gaps within this batch
    for i in range(len(sorted_spots) - 1):
        current = int(sorted_spots[i].get('Spotnum', 0))
        next_spot = int(sorted_spots[i + 1].get('Spotnum', 0))

        if next_spot > current + 1:
            gap_size = next_spot - current - 1
            gaps.append((current + 1, next_spot - 1))
            log(f"GAP within batch: after {current}, before {next_spot} ({gap_size} spots)", "WARNING")

    return gaps

def process_spots(spots: List[Dict]) -> List[List]:
    """Process spots and add calculated fields"""
    processed = []
    validation_stats = {'valid': 0, 'corrected': 0, 'failed': 0}

    for spot in spots:
        try:
            date_epoch = int(spot.get('Date', 0))
            code = int(spot.get('code', 1))
            spotnum = int(spot.get('Spotnum', 0))

            # Validate and possibly correct the timing
            is_valid, corrected_epoch, msg = validate_spot_timing(date_epoch, code, spotnum)
            if is_valid:
                validation_stats['valid'] += 1
            else:
                validation_stats['corrected'] += 1
                if msg:
                    log(msg, "WARNING")
                date_epoch = corrected_epoch

            # Calculate azimuth fields
            calc = calculate_azimuth(
                frequency=float(spot.get('MHz', 0)),
                tx_locator=spot.get('Grid', ''),
                rx_locator=spot.get('ReporterGrid', '')
            )

            # Build row for ClickHouse
            row = [
                spotnum,
                date_epoch,  # Use corrected epoch
                spot.get('Reporter', ''),
                spot.get('ReporterGrid', ''),
                int(spot.get('dB', 0)),
                float(spot.get('MHz', 0)),
                spot.get('CallSign', ''),
                spot.get('Grid', ''),
                int(spot.get('Power', 0)),
                int(spot.get('Drift', 0)),
                int(spot.get('distance', 0)),
                int(spot.get('azimuth', 0)),
                int(spot.get('Band', 0)),
                spot.get('version', ''),
                code,
                time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(date_epoch)),  # wd_date
                calc['wd_band'],
                calc['wd_rx_az'],
                calc['wd_rx_lat'],
                calc['wd_rx_lon'],
                calc['wd_tx_lat'],
                calc['wd_tx_lon']
            ]
            processed.append(row)
        except Exception as e:
            log(f"Failed to process spot {spot.get('Spotnum', '?')}: {e}", "WARNING")
            validation_stats['failed'] += 1
            continue

    log(f"Spot validation: {validation_stats['valid']} valid, {validation_stats['corrected']} corrected, {validation_stats['failed']} failed")
    return processed

def get_last_spotnum(client, database: str, table: str) -> int:
    """Get the highest Spotnum from ClickHouse"""
    try:
        result = client.query(f"SELECT MAX(Spotnum) FROM {database}.{table}")
        if result.result_rows and result.result_rows[0][0]:
            return int(result.result_rows[0][0])
    except Exception as e:
        log(f"Could not query last spotnum: {e}", "WARNING")
    return 0

def insert_spots(client, spots: List[List], database: str, table: str) -> bool:
    """Insert spots into ClickHouse"""
    if not spots:
        return True

    column_names = [
        'Spotnum', 'Date', 'Reporter', 'ReporterGrid', 'dB', 'MHz',
        'CallSign', 'Grid', 'Power', 'Drift', 'distance', 'azimuth',
        'Band', 'version', 'code', 'wd_date', 'wd_band',
        'wd_rx_az', 'wd_rx_lat', 'wd_rx_lon', 'wd_tx_lat', 'wd_tx_lon'
    ]

    try:
        client.insert(f"{database}.{table}", spots, column_names=column_names)
        log(f"Inserted {len(spots)} spots into ClickHouse")
        return True
    except Exception as e:
        log(f"Failed to insert spots: {e}", "ERROR")
        return False

def verify_first_spot(spots: List[Dict], expected_spotnum: int) -> bool:
    """Verify the first spot is the expected one"""
    if not spots:
        log("No spots received", "WARNING")
        return True
    
    # Sort by Spotnum to find the actual first spot
    sorted_spots = sorted(spots, key=lambda s: int(s.get('Spotnum', 0)))
    first_spotnum = int(sorted_spots[0].get('Spotnum', 0))
    
    if expected_spotnum == 0:
        log(f"First download: starting with spotnum {first_spotnum}")
        return True
    
    expected = expected_spotnum + 1
    
    if first_spotnum == expected:
        log(f"First spot {first_spotnum} matches expected {expected}")
        return True
    elif first_spotnum > expected:
        gap_size = first_spotnum - expected
        log(f"Gap before first spot: expected {expected}, got {first_spotnum} (missing {gap_size} spots)", "WARNING")
        return True
    else:
        log(f"Unexpected: first spot {first_spotnum} is less than expected {expected}", "ERROR")
        return False

def setup_clickhouse_tables(admin_user: str, admin_password: str,
                           readonly_user: str, readonly_password: str,
                           default_password: str, config: Dict) -> bool:
    """Setup ClickHouse users, database, and table"""
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
            log(f"Admin user {admin_user} already exists")
        else:
            log(f"Creating admin user {admin_user}...")
            admin_client.command(f"CREATE USER {admin_user} IDENTIFIED BY '{admin_password}'")
            admin_client.command(f"GRANT CREATE DATABASE ON *.* TO {admin_user}")
            admin_client.command(f"GRANT CREATE TABLE ON *.* TO {admin_user}")
            admin_client.command(f"GRANT INSERT ON {config['clickhouse_database']}.* TO {admin_user}")
            admin_client.command(f"GRANT SELECT ON {config['clickhouse_database']}.* TO {admin_user}")
            log(f"Admin user {admin_user} created")

        # Check/create read-only user
        result = admin_client.query(
            f"SELECT count() FROM system.users WHERE name = '{readonly_user}'"
        )
        if result.result_rows[0][0] == 1:
            log(f"Read-only user {readonly_user} already exists")
        else:
            log(f"Creating read-only user {readonly_user}...")
            admin_client.command(f"CREATE USER {readonly_user} IDENTIFIED BY '{readonly_password}'")
            admin_client.command(f"GRANT SELECT ON {config['clickhouse_database']}.* TO {readonly_user}")
            log(f"Read-only user {readonly_user} created")

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
            log(f"Creating database {config['clickhouse_database']}...")
            admin_client.command(f"CREATE DATABASE {config['clickhouse_database']}")
            log(f"Database {config['clickhouse_database']} created")
        else:
            log(f"Database {config['clickhouse_database']} already exists")

        # Create table if not exists
        create_table_sql = f"""
        CREATE TABLE IF NOT EXISTS {config['clickhouse_database']}.{config['clickhouse_table']}
        (
            Spotnum UInt64 CODEC(Delta(8), ZSTD(1)),
            Date UInt32 CODEC(Delta(4), ZSTD(1)),
            Reporter LowCardinality(String),
            ReporterGrid LowCardinality(String),
            dB Int16 CODEC(ZSTD(1)),
            MHz Float64 CODEC(ZSTD(1)),
            CallSign LowCardinality(String),
            Grid LowCardinality(String),
            Power Int8 CODEC(T64, ZSTD(1)),
            Drift Int16 CODEC(ZSTD(1)),
            distance UInt16 CODEC(T64, ZSTD(1)),
            azimuth UInt16 CODEC(T64, ZSTD(1)),
            Band Int8 CODEC(T64, ZSTD(1)),
            version LowCardinality(Nullable(String)),
            code Int8 CODEC(ZSTD(1)),
            wd_date String,
            wd_band Int16 CODEC(T64, ZSTD(1)),
            wd_rx_az UInt16 CODEC(T64, ZSTD(1)),
            wd_rx_lat Float32 CODEC(ZSTD(1)),
            wd_rx_lon Float32 CODEC(ZSTD(1)),
            wd_tx_lat Float32 CODEC(ZSTD(1)),
            wd_tx_lon Float32 CODEC(ZSTD(1)),
            inserted_at DateTime DEFAULT now() CODEC(Delta(4), ZSTD(1))
        )
        ENGINE = MergeTree()
        PARTITION BY toYYYYMM(toDateTime(Date))
        ORDER BY (Date, Spotnum)
        SETTINGS index_granularity = 8192
        """
        admin_client.command(create_table_sql)
        log(f"Table {config['clickhouse_database']}.{config['clickhouse_table']} created/verified")

        return True

    except Exception as e:
        log(f"Setup failed: {e}", "ERROR")
        return False

def main():
    parser = argparse.ArgumentParser(description='WSPRNET Scraper')
    parser.add_argument('--session-file', required=True, help='Path to session file with sessid and session_name')
    parser.add_argument('--username', help='WSPRNET username (required if session file missing)')
    parser.add_argument('--password', help='WSPRNET password (required if session file missing)')
    parser.add_argument('--clickhouse-user', required=True, help='ClickHouse admin username (required)')
    parser.add_argument('--clickhouse-password', required=True, help='ClickHouse admin password (required)')
    parser.add_argument('--setup-default-password', required=True, help='Default ClickHouse password (required)')
    parser.add_argument('--setup-readonly-user', required=True, help='Read-only username (required)')
    parser.add_argument('--setup-readonly-password', required=True, help='Read-only password (required)')
    parser.add_argument('--config', help='Path to config file (JSON)')
    parser.add_argument('--loop', type=int, metavar='SECONDS', help='Run continuously with SECONDS delay between downloads')
    parser.add_argument('--log-file', default=LOG_FILE, help='Path to log file (if not specified, log to console only)')
    parser.add_argument('--log-max-mb', type=int, default=10, help='Max log file size in MB before truncation')
    args = parser.parse_args()

    if args.log_file:
        setup_logging(args.log_file, args.log_max_mb * 1024 * 1024)
    else:
        setup_logging()  # Console only

    # Load configuration
    config = DEFAULT_CONFIG.copy()
    if args.config:
        with open(args.config) as f:
            config.update(json.load(f))

    # Override with command line credentials
    config['clickhouse_user'] = args.clickhouse_user
    config['clickhouse_password'] = args.clickhouse_password

    # Handle setup mode
    # Always run setup to ensure users, database, and table exist
    log("Running setup to ensure ClickHouse is configured...")
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
    session_file = Path(args.session_file)
    
    # Get session token (will login if needed)
    session_token = get_session_token(
        session_file, 
        args.username or '', 
        args.password or '', 
        config['wsprnet_login_url']
    )
    
    if not session_token:
        log("Failed to get session token", "ERROR")
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
        log(f"Failed to connect to ClickHouse: {e}", "ERROR")
        sys.exit(1)
    
    # Get starting spotnum
    last_spotnum = get_last_spotnum(client, config['clickhouse_database'], config['clickhouse_table'])
    log(f"Starting from spotnum: {last_spotnum}")
    
    # Main loop
    loop_count = 0
    while True:
        loop_count += 1
        log(f"Download cycle {loop_count}")
        
        spots, auth_failed = download_spots(session_token, last_spotnum, config)
        
        # If auth failed, try to re-login
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
                log("Re-authentication failed", "ERROR")
                if not args.loop:
                    sys.exit(1)
                time.sleep(60)
                continue
            
            # Retry download with new session
            spots, auth_failed = download_spots(session_token, last_spotnum, config)
        
        if spots:
            if not verify_first_spot(spots, last_spotnum):
                log("First spot verification failed", "ERROR")

            summarize_spots_by_date(spots)
            gaps = detect_gaps(spots, last_spotnum)
            if gaps:
                log(f"Total gaps found: {len(gaps)}", "WARNING")

            processed = process_spots(spots)
            if processed:
                if insert_spots(client, processed, config['clickhouse_database'], config['clickhouse_table']):
                    highest_spotnum = max(row[0] for row in processed)
                    log(f"Processed {len(processed)} spots, highest spotnum: {highest_spotnum}")
                    last_spotnum = highest_spotnum
        
        if not args.loop:
            break
        
        sleep_time = args.loop
        log(f"Sleeping {sleep_time} seconds...")
        time.sleep(sleep_time)


if __name__ == '__main__':
    main()
