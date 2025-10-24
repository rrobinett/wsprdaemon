#!/usr/bin/env python3
"""
WSPRDAEMON Reflector - Distribute .tbz files from clients to multiple servers
Usage: wsprdaemon_reflector.py --config /etc/wsprdaemon/reflector.conf [options]
"""

import argparse
import json
import sys
import time
import os
import subprocess
import threading
from pathlib import Path
from typing import Dict, List
import logging
from collections import defaultdict
import glob
import subprocess
from pathlib import Path

# Default configuration
DEFAULT_CONFIG = {
    'incoming_pattern': '/home/*/uploads/*.tbz',
    'queue_base_dir': '/var/spool/wsprdaemon/reflector',
    'state_file': '/var/lib/wsprdaemon/reflector/state.json',
    'destinations': [
        # {'name': 'WD1', 'user': 'wsprdaemon', 'host': 'WD1', 'path': '/var/spool/wsprdaemon/from-wd00'}
    ],
    'scan_interval': 10,
    'rsync_interval': 5,
    'cleanup_interval': 60,
    'rsync_bandwidth_limit': 20000,  # KB/s
    'rsync_timeout': 300,
    'max_retries': 3
}

# Logging configuration
LOG_FILE = 'wsprdaemon_reflector.log'
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

class ReflectorState:
    """Track which files have been distributed to which destinations"""
    # ... existing __init__, load, save, add_file, etc.

    def needs_processing(self, filename: str) -> bool:
        """Return True if the file is not yet tracked or any destination is pending"""
        with self.lock:
            if filename not in self.state:
                return True
            return any(dest_info['status'] != 'sent' for dest_info in self.state[filename].values())

    def __init__(self, state_file: Path):
        self.state_file = state_file
        self.lock = threading.RLock()
        # Format: {filename: {dest_name: {'status': 'pending'|'sent'|'failed', 'attempts': N, 'last_attempt': timestamp}}}
        self.state = defaultdict(dict)
        self.load()
    
    def load(self):
        """Load state from disk"""
        with self.lock:
            if self.state_file.exists():
                try:
                    with open(self.state_file, 'r') as f:
                        self.state = defaultdict(dict, json.load(f))
                    log(f"Loaded state: {len(self.state)} files tracked", "INFO")
                except Exception as e:
                    log(f"Error loading state: {e}", "ERROR")
    
    def save(self):
        """Save state to disk"""
        with self.lock:
            try:
                self.state_file.parent.mkdir(parents=True, exist_ok=True)
                with open(self.state_file, 'w') as f:
                    json.dump(dict(self.state), f, indent=2)
            except Exception as e:
                log(f"Error saving state: {e}", "ERROR")
    
    def add_file(self, filename: str, destinations: List[str]):
        """Add a new file to track for all destinations"""
        log(f"add_file called with filename={filename}, destinations={destinations}", "DEBUG") 
        with self.lock:
            log(f"Acquired lock, checking if {filename} in state", "DEBUG")  # ADD THIS
            log(f"filename in self.state = {filename in self.state}", "DEBUG")  # ADD THIS
            if filename not in self.state:
                log(f"Creating state entry for {filename}", "DEBUG")
                self.state[filename] = {}
                log(f"About to loop through destinations", "DEBUG")
                for dest in destinations:
                    log(f"Processing destination: {dest}", "DEBUG")
                    self.state[filename][dest] = {
                        'status': 'pending',
                        'attempts': 0,
                        'last_attempt': 0
                    }
                log(f"About to call self.save()", "DEBUG")  
                self.save()
                log(f"After self.save(), about to log tracking message", "DEBUG")
                log(f"Tracking new file: {filename} -> {destinations}", "DEBUG")

    
    def mark_sent(self, filename: str, destination: str):
        with self.lock:
            if filename in self.state and destination in self.state[filename]:
                self.state[filename][destination]['status'] = 'sent'
                self.state[filename][destination]['last_attempt'] = time.time()
                self.save()
                log(f"Marked {filename} as sent to {destination}", "DEBUG")
    
    def mark_failed(self, filename: str, destination: str):
        with self.lock:
            if filename in self.state and destination in self.state[filename]:
                self.state[filename][destination]['status'] = 'failed'
                self.state[filename][destination]['attempts'] += 1
                self.state[filename][destination]['last_attempt'] = time.time()
                self.save()
    
    def is_fully_distributed(self, filename: str) -> bool:
        with self.lock:
            if filename not in self.state:
                return False
            return all(dest['status'] == 'sent' for dest in self.state[filename].values())
    
    def get_pending_destinations(self, filename: str) -> List[str]:
        with self.lock:
            if filename not in self.state:
                return []
            return [dest for dest, info in self.state[filename].items() if info['status'] != 'sent']
    
    def remove_file(self, filename: str):
        with self.lock:
            if filename in self.state:
                del self.state[filename]
                self.save()
                log(f"Removed {filename} from tracking", "DEBUG")

class FileScanner(threading.Thread):
    """Scan for new .tbz files and queue them for distribution"""

    def __init__(self, config: Dict, state: ReflectorState, stop_event: threading.Event):
        super().__init__(name="Scanner", daemon=True)
        self.config = config
        self.state = state
        self.stop_event = stop_event
        self.dest_names = [d['name'] for d in config['destinations']]

    def run(self):
        log("File scanner thread started", "INFO")

        while not self.stop_event.is_set():
            try:
                self.scan_and_queue()
            except Exception as e:
                log(f"Scanner error: {e}", "ERROR")

            self.stop_event.wait(self.config['scan_interval'])

        log("File scanner thread stopped", "INFO")

    def scan_and_queue(self):
        """Scan for new files and queue them for transfer"""
        import glob
        import shutil

        pattern = self.config.get('incoming_pattern', '/home/*/uploads/*.tbz')
        log(f"Scanning with pattern: {pattern}", "DEBUG")

        files = glob.glob(pattern)
        if not files:
            log("No .tbz files found", "DEBUG")
            return

        log(f"Found {len(files)} .tbz files", "DEBUG")

        for filepath in files:
            filename = os.path.basename(filepath)
            log(f"Processing file: {filename}", "DEBUG")
            log(f"Checking needs_processing for {filename}", "DEBUG")
            needs_proc = self.state.needs_processing(filename)  # ADD THIS LINE
            log(f"needs_processing returned: {needs_proc}", "DEBUG")  # ADD THIS LINE
            log(f"About to add file to state", "DEBUG")

            # Check if file needs processing (filename only)
            if not self.state.needs_processing(filename):
                log(f"File {filename} already processed/being tracked", "DEBUG")
                continue

            # Add file to state with all destination names
            dest_names = [d['name'] for d in self.config['destinations']]
            self.state.add_file(filename, dest_names)
            log(f"Added {filename} to state tracking for destinations: {dest_names}", "DEBUG")

            # Queue the file for each destination
            for dest_name in dest_names:
                dest_queue = Path(self.config['queue_base_dir']) / dest_name
                dest_queue.mkdir(parents=True, exist_ok=True)
                queue_file = dest_queue / filename

                if not queue_file.exists():
                    try:
                        os.link(filepath, queue_file)
                        log(f"Queued {filename} for {dest_name} at {queue_file}", "INFO")
                    except OSError:
                        try:
                            shutil.copy2(filepath, queue_file)
                            log(f"Copied {filename} to queue for {dest_name} at {queue_file}", "INFO")
                        except Exception as e:
                            log(f"Failed to queue {filename} for {dest_name}: {e}", "ERROR")
                else:
                    log(f"File {filename} already queued for {dest_name}", "DEBUG")

class RsyncWorker(threading.Thread):
    """Worker thread that rsyncs files to a specific destination"""

    def __init__(self, destination: Dict, config: Dict, state: ReflectorState, stop_event: threading.Event):
        super().__init__(name=f"Rsync-{destination['name']}", daemon=True)
        self.destination = destination
        self.config = config
        self.state = state
        self.stop_event = stop_event
        self.queue_dir = Path(config['queue_base_dir']) / destination['name']

    def run(self):
        log(f"Rsync worker for {self.destination['name']} started", "INFO")
        while not self.stop_event.is_set():
            try:
                self.sync_files()
            except Exception as e:
                log(f"Rsync worker {self.destination['name']} error: {e}", "ERROR")
            self.stop_event.wait(self.config['rsync_interval'])
        log(f"Rsync worker for {self.destination['name']} stopped", "INFO")

    def sync_files(self):
        """Rsync queued files to destination"""
        if not self.queue_dir.exists():
            self.queue_dir.mkdir(parents=True, exist_ok=True)
            log(f"Created missing queue directory: {self.queue_dir}", "DEBUG")

        queued_files = list(self.queue_dir.glob('*.tbz'))
        if not queued_files:
            log(f"No files queued for {self.destination['name']}", "DEBUG")
            return

        log(f"Found {len(queued_files)} files to sync to {self.destination['name']}", "INFO")

        remote_path = f"{self.destination['user']}@{self.destination['host']}:{self.destination['path']}/"
        ssh_cmd = 'ssh -i /home/wsprdaemon/.ssh/id_rsa -o StrictHostKeyChecking=no'

        rsync_cmd = [
            'rsync',
            '-a',
            '-e', ssh_cmd,
            '--remove-source-files',
            f'--bwlimit={self.config["rsync_bandwidth_limit"]}',
            f'--timeout={self.config["rsync_timeout"]}',
            str(self.queue_dir) + '/',
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
                for file in queued_files:
                    self.state.mark_sent(file.name, self.destination['name'])
            else:
                log(f"Rsync to {self.destination['name']} failed: {result.stderr}", "ERROR")
                for file in queued_files:
                    self.state.mark_failed(file.name, self.destination['name'])
        except subprocess.TimeoutExpired:
            log(f"Rsync to {self.destination['name']} timed out", "ERROR")
            for file in queued_files:
                self.state.mark_failed(file.name, self.destination['name'])
        except Exception as e:
            log(f"Rsync to {self.destination['name']} error: {e}", "ERROR")


class CleanupWorker(threading.Thread):
    """Remove source files after successful distribution to all destinations"""

    def __init__(self, config: Dict, state: ReflectorState, stop_event: threading.Event):
        super().__init__(name="Cleanup", daemon=True)
        self.config = config
        self.state = state
        self.stop_event = stop_event

    def run(self):
        log("Cleanup worker thread started", "INFO")

        while not self.stop_event.is_set():
            try:
                self.cleanup_distributed_files()
            except Exception as e:
                log(f"Cleanup worker error: {e}", "ERROR")

            self.stop_event.wait(self.config['cleanup_interval'])

        log("Cleanup worker thread stopped", "INFO")

    def cleanup_distributed_files(self):
        """Delete source files that have been sent to all destinations"""
        files_to_clean = []

        for filename in list(self.state.state.keys()):
            if self.state.is_fully_distributed(filename):
                files_to_clean.append(filename)

        if not files_to_clean:
            log("No files ready for cleanup", "DEBUG")
            return

        log(f"Cleaning up {len(files_to_clean)} fully distributed files", "INFO")

        for filename in files_to_clean:
            deleted = False

            for home_dir in Path('/home').iterdir():
                if home_dir.is_dir():
                    uploads_dir = home_dir / 'uploads'
                    source_file = uploads_dir / filename

                    if source_file.exists():
                        try:
                            # Use Python's unlink - we're running as root
                            source_file.unlink()
                            deleted = True
                            log(f"Deleted source file: {source_file}", "INFO")
                        except FileNotFoundError:
                            # File was already deleted (race condition)
                            log(f"File already deleted: {source_file}", "DEBUG")
                            deleted = True
                        except Exception as e:
                            log(f"Error deleting {source_file}: {e}", "ERROR")

            if deleted:
                self.state.remove_file(filename)

def main():
    parser = argparse.ArgumentParser(description='WSPRDAEMON Reflector')
    parser.add_argument('--config', help='Path to config file (JSON)')
    parser.add_argument('--log-file', default=LOG_FILE, help='Path to log file')
    parser.add_argument('--log-max-mb', type=int, default=10, help='Max log file size in MB')
    parser.add_argument('--verbose', type=int, default=0, choices=range(0, 10),
                        help='Verbosity level 0-9 (0=WARNING+ERROR, 1=INFO, 2+=DEBUG)')
    args = parser.parse_args()

    setup_logging(args.log_file, args.log_max_mb * 1024 * 1024, verbosity=args.verbose)

    log("=== WSPRDAEMON Reflector Starting ===", "INFO")
    log(f"Verbosity level: {args.verbose}", "INFO")

    config = DEFAULT_CONFIG.copy()
    if args.config:
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

    state_file = Path(config['state_file'])
    state = ReflectorState(state_file)

    stop_event = threading.Event()

    # Ensure queue directories exist for all destinations
    for dest in config['destinations']:
        queue_dir = Path(config['queue_base_dir']) / dest['name']
        queue_dir.mkdir(parents=True, exist_ok=True)
        log(f"Ensured queue directory exists: {queue_dir}", "DEBUG")

    threads = []

    scanner = FileScanner(config, state, stop_event)
    scanner.start()
    threads.append(scanner)

    for dest in config['destinations']:
        worker = RsyncWorker(dest, config, state, stop_event)
        worker.start()
        threads.append(worker)

    cleanup = CleanupWorker(config, state, stop_event)
    cleanup.start()
    threads.append(cleanup)

    log(f"Started {len(threads)} worker threads", "INFO")

    try:
        while True:
            time.sleep(10)
            log(f"Status: {len(state.state)} files tracked", "DEBUG")
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
