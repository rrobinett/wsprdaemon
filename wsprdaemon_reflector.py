#!/usr/bin/env python3
"""
WSPRDAEMON Reflector - Distribute .tbz files using atomic copy and rsync
Refined architecture:
- Input thread: polls for new files, copies to all destination spools (atomic rename), deletes input
- Output threads: one per destination, polls spool and rsyncs files
- Optional: Can try hard links first if config allows (off by default)
- No state tracking needed - filesystem manages everything
"""

import argparse
import json
import sys
import time
import os
import subprocess
import threading
import shutil
from pathlib import Path
from typing import Dict, List
import logging
import glob

# Default configuration
DEFAULT_CONFIG = {
    'incoming_pattern': '/home/*/uploads/*.tbz',
    'spool_base_dir': '/var/spool/wsprdaemon/reflector',
    'destinations': [
        # {'name': 'WD1', 'user': 'wsprdaemon', 'host': 'WD1', 'path': '/var/spool/wsprdaemon/from-wd00'}
    ],
    'scan_interval': 10,
    'rsync_interval': 5,
    'rsync_bandwidth_limit': 20000,  # KB/s
    'rsync_timeout': 300,
    'try_hardlinks': False,  # Set True only if protected_hardlinks=0 or same ownership
}

# Logging configuration
LOG_FILE = '/var/log/wsprdaemon/reflector.log'
LOG_MAX_BYTES = 10 * 1024 * 1024  # 10MB
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
        except Exception as e:
            print(f"Error truncating log file: {e}")


def setup_logging(log_file=None, max_bytes=LOG_MAX_BYTES, keep_ratio=LOG_KEEP_RATIO, verbosity=0):
    """Setup logging with verbosity levels"""
    logger = logging.getLogger()

    if verbosity == 0:
        logger.setLevel(logging.WARNING)
    elif verbosity == 1:
        logger.setLevel(logging.INFO)
    else:
        logger.setLevel(logging.DEBUG)

    logger.handlers.clear()

    if log_file:
        # Ensure log directory exists
        Path(log_file).parent.mkdir(parents=True, exist_ok=True)
        file_handler = TruncatingFileHandler(log_file, max_bytes, keep_ratio)
        file_formatter = logging.Formatter(
            '[%(asctime)s] %(levelname)s: %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
        file_handler.setFormatter(file_formatter)
        logger.addHandler(file_handler)
    else:
        console_handler = logging.StreamHandler()
        console_formatter = logging.Formatter(
            '[%(asctime)s] %(levelname)s: %(message)s',
            datefmt='%Y-%m-%d %H:%M:%S'
        )
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
    for handler in logger.handlers:
        handler.flush()


def check_hardlink_support():
    """Check if system supports hard links across different file owners"""
    try:
        with open('/proc/sys/fs/protected_hardlinks', 'r') as f:
            value = int(f.read().strip())
            return value == 0
    except (FileNotFoundError, ValueError, PermissionError):
        # If we can't read it, assume protected
        return False


class InputPoller(threading.Thread):
    """Poll for incoming files, hard-link to all destination spools, delete input"""

    def __init__(self, config: Dict, stop_event: threading.Event):
        super().__init__(name="InputPoller", daemon=True)
        self.config = config
        self.stop_event = stop_event
        self.spool_base = Path(config['spool_base_dir'])
        self.destination_names = [d['name'] for d in config['destinations']]

    def run(self):
        log("Input poller thread started", "INFO")
        log(f"Polling pattern: {self.config['incoming_pattern']}", "INFO")
        log(f"Destination spools: {self.destination_names}", "INFO")
        log(f"Hard links: {'enabled' if self.config.get('try_hardlinks', False) else 'disabled (using copy mode)'}", "INFO")

        while not self.stop_event.is_set():
            try:
                self.poll_and_distribute()
            except Exception as e:
                log(f"Input poller error: {e}", "ERROR")
            
            self.stop_event.wait(self.config['scan_interval'])

        log("Input poller thread stopped", "INFO")

    def poll_and_distribute(self):
        """Find new files, hard-link to destination spools, delete input"""
        # Find all matching files
        matching_files = glob.glob(self.config['incoming_pattern'])
        
        if not matching_files:
            log("No new files found", "DEBUG")
            return

        log(f"Found {len(matching_files)} files to distribute", "INFO")

        for source_path in matching_files:
            source_file = Path(source_path)
            if not source_file.exists():
                log(f"File disappeared: {source_file}", "WARNING")
                continue

            filename = source_file.name
            log(f"Processing: {filename}", "INFO")

            # Hard-link to each destination spool
            links_created = 0
            for dest_name in self.destination_names:
                dest_spool = self.spool_base / dest_name
                dest_file = dest_spool / filename

                try:
                    dest_spool.mkdir(parents=True, exist_ok=True)
                    
                    # Try hard link first if enabled (most efficient when it works)
                    if self.config.get('try_hardlinks', False):
                        try:
                            os.link(str(source_file), str(dest_file))
                            links_created += 1
                            log(f"Hard-linked {filename} to {dest_name} spool", "DEBUG")
                            continue  # Skip to next destination
                        except OSError as e:
                            # Hard link failed - fall back to copy
                            log(f"Hard-link failed for {filename} to {dest_name} ({e}), falling back to copy", "DEBUG")
                    
                    # Copy with atomic rename to prevent rsync race condition
                    temp_file = dest_spool / f"{filename}.tmp"
                    shutil.copy2(source_file, temp_file)
                    temp_file.rename(dest_file)  # Atomic operation
                    links_created += 1
                    log(f"Copied {filename} to {dest_name} spool", "DEBUG")
                    
                except FileExistsError:
                    log(f"File already exists: {dest_file}", "DEBUG")
                    links_created += 1  # Count as success
                except Exception as e:
                    log(f"Failed to distribute {filename} to {dest_name}: {e}", "ERROR")

            # Delete the input file only if we successfully linked to all destinations
            if links_created == len(self.destination_names):
                try:
                    source_file.unlink()
                    log(f"Deleted input file: {source_file} (hard links remain)", "INFO")
                except Exception as e:
                    log(f"Failed to delete input file {source_file}: {e}", "ERROR")
            else:
                log(f"Only {links_created}/{len(self.destination_names)} links created for {filename}, keeping input file", "WARNING")


class OutputRsyncWorker(threading.Thread):
    """Poll destination spool directory and rsync files to remote server"""

    def __init__(self, destination: Dict, config: Dict, stop_event: threading.Event):
        super().__init__(name=f"Output-{destination['name']}", daemon=True)
        self.destination = destination
        self.config = config
        self.stop_event = stop_event
        self.spool_dir = Path(config['spool_base_dir']) / destination['name']

    def run(self):
        log(f"Output rsync worker for {self.destination['name']} started", "INFO")
        log(f"Spool directory: {self.spool_dir}", "INFO")
        log(f"Remote target: {self.destination['user']}@{self.destination['host']}:{self.destination['path']}", "INFO")

        while not self.stop_event.is_set():
            try:
                self.sync_files()
            except Exception as e:
                log(f"Output worker {self.destination['name']} error: {e}", "ERROR")
            
            self.stop_event.wait(self.config['rsync_interval'])

        log(f"Output rsync worker for {self.destination['name']} stopped", "INFO")

    def sync_files(self):
        """Rsync all files from spool directory to remote destination"""
        # Ensure spool directory exists
        if not self.spool_dir.exists():
            self.spool_dir.mkdir(parents=True, exist_ok=True)
            log(f"Created spool directory: {self.spool_dir}", "DEBUG")

        # Check for files to sync
        queued_files = list(self.spool_dir.glob('*.tbz'))
        if not queued_files:
            log(f"No files in {self.destination['name']} spool", "DEBUG")
            return

        log(f"Syncing {len(queued_files)} files from {self.destination['name']} spool", "INFO")

        # Build rsync command
        remote_path = f"{self.destination['user']}@{self.destination['host']}:{self.destination['path']}/"
        ssh_cmd = 'ssh -i /home/wsprdaemon/.ssh/id_rsa -o StrictHostKeyChecking=no'

        rsync_cmd = [
            'rsync',
            '-a',
            '-e', ssh_cmd,
            '--remove-source-files',  # Delete after successful transfer
            '--delay-updates',  # Atomic rename on remote after transfer completes
            '--exclude=*.tmp',  # Skip temp files still being copied locally
            f'--bwlimit={self.config["rsync_bandwidth_limit"]}',
            f'--timeout={self.config["rsync_timeout"]}',
            str(self.spool_dir) + '/',
            remote_path
        ]

        try:
            log(f"Running rsync to {self.destination['name']}: {' '.join(rsync_cmd)}", "DEBUG")
            result = subprocess.run(
                rsync_cmd,
                capture_output=True,
                text=True,
                timeout=self.config['rsync_timeout'] + 30
            )
            
            if result.returncode == 0:
                log(f"Successfully synced {len(queued_files)} files to {self.destination['name']}", "INFO")
                # rsync with --remove-source-files already deleted the hard links
                # When all hard links are deleted, the file data is automatically freed by the filesystem
            else:
                log(f"Rsync to {self.destination['name']} failed (rc={result.returncode}): {result.stderr}", "ERROR")
                
        except subprocess.TimeoutExpired:
            log(f"Rsync to {self.destination['name']} timed out", "ERROR")
        except Exception as e:
            log(f"Rsync to {self.destination['name']} error: {e}", "ERROR")


def main():
    parser = argparse.ArgumentParser(description='WSPRDAEMON Reflector - Hard-link based distribution')
    parser.add_argument('--config', required=True, help='Path to config file (JSON)')
    parser.add_argument('--log-file', default=LOG_FILE, help='Path to log file')
    parser.add_argument('--log-max-mb', type=int, default=10, help='Max log file size in MB')
    parser.add_argument('--verbose', type=int, default=1, choices=range(0, 10),
                        help='Verbosity level 0-9 (0=WARNING+ERROR, 1=INFO, 2+=DEBUG)')
    args = parser.parse_args()

    setup_logging(args.log_file, args.log_max_mb * 1024 * 1024, verbosity=args.verbose)

    log("=== WSPRDAEMON Reflector Starting (Copy Mode with Optional Hard Links) ===", "INFO")
    log(f"Verbosity level: {args.verbose}", "INFO")

    # Load configuration
    config = DEFAULT_CONFIG.copy()
    try:
        with open(args.config, 'r', encoding='utf-8') as f:
            loaded_config = json.load(f)
            config.update(loaded_config)
        log(f"Loaded configuration from {args.config}", "INFO")
    except Exception as e:
        log(f"Error loading config: {e}", "ERROR")
        sys.exit(1)

    if not config['destinations']:
        log("No destinations configured", "ERROR")
        sys.exit(1)

    log(f"Configured {len(config['destinations'])} destinations: {[d['name'] for d in config['destinations']]}", "INFO")

    # Check hardlink support and provide intelligent suggestions
    system_supports_hardlinks = check_hardlink_support()
    try_hardlinks_enabled = config.get('try_hardlinks', False)
    
    log(f"System protected_hardlinks: {'0 (hardlinks allowed)' if system_supports_hardlinks else '1 (hardlinks restricted)'}", "INFO")
    log(f"Config try_hardlinks: {try_hardlinks_enabled}", "INFO")
    
    # Provide suggestions based on system capability vs config
    if system_supports_hardlinks and not try_hardlinks_enabled:
        log("SUGGESTION: System supports hard links across users (protected_hardlinks=0)", "WARNING")
        log(f"SUGGESTION: Consider enabling hard links for better performance:", "WARNING")
        log(f"SUGGESTION: Add '\"try_hardlinks\": true' to {args.config}", "WARNING")
        log("SUGGESTION: This will eliminate file copy overhead (zero-copy distribution)", "WARNING")
    elif not system_supports_hardlinks and try_hardlinks_enabled:
        log("WARNING: Hard links enabled but system has protected_hardlinks=1", "WARNING")
        log("WARNING: Hard link attempts will fail and fall back to copy mode", "WARNING")
        log("WARNING: Consider setting '\"try_hardlinks\": false' for cleaner operation", "WARNING")

    # Create spool base directory
    spool_base = Path(config['spool_base_dir'])
    spool_base.mkdir(parents=True, exist_ok=True)
    log(f"Spool base directory: {spool_base}", "INFO")

    # Ensure all destination spool directories exist
    for dest in config['destinations']:
        dest_spool = spool_base / dest['name']
        dest_spool.mkdir(parents=True, exist_ok=True)
        log(f"Destination spool: {dest_spool}", "DEBUG")

    stop_event = threading.Event()
    threads = []

    # Start input poller thread
    input_poller = InputPoller(config, stop_event)
    input_poller.start()
    threads.append(input_poller)

    # Start one output rsync worker per destination
    for dest in config['destinations']:
        worker = OutputRsyncWorker(dest, config, stop_event)
        worker.start()
        threads.append(worker)

    log(f"Started {len(threads)} worker threads (1 input + {len(config['destinations'])} output)", "INFO")

    try:
        while True:
            time.sleep(60)
            # Count files in spools
            total_files = sum(len(list((spool_base / d['name']).glob('*.tbz'))) 
                            for d in config['destinations'])
            if total_files > 0:
                log(f"Status: {total_files} files queued across all spools", "INFO")
    except KeyboardInterrupt:
        log("Received shutdown signal", "INFO")
    finally:
        log("Stopping worker threads...", "INFO")
        stop_event.set()
        for thread in threads:
            thread.join(timeout=5)
        log("WSPRDAEMON Reflector stopped", "INFO")


if __name__ == '__main__':
    main()
