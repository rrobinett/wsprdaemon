import re
import sys
from pathlib import Path

def extract_sort_key(filepath):
    """Extracts the first directory starting with a number for sorting."""
    parts = Path(filepath).parts
    for part in parts:
        if re.match(r'\d', part):
            return int(re.search(r'\d+', part).group())
    return -1  # Default if no numeric directory found

def parse_time(timestamp):
    """Parses a timestamp in HH:MM format and returns hours and minutes as integers."""
    try:
        hours, minutes = map(int, timestamp.split(':'))
        return hours, minutes
    except ValueError:
        return None

def parse_birth_time(birth_time):
    """Parses a birth time in HH:MM:SS.microseconds format and returns microseconds if seconds == 00."""
    try:
        h, m, s_micro = birth_time.split(':')
        s, micro = map(int, s_micro.split('.'))
        if int(s) != 0:
            return None  # Ignore if seconds are not 00
        return micro
    except ValueError:
        return None

def is_one_minute_later(prev_time, curr_time):
    """Checks if curr_time is exactly one minute later than prev_time."""
    if not prev_time or not curr_time:
        return False
    prev_h, prev_m = prev_time
    curr_h, curr_m = curr_time
    return (prev_h == curr_h and curr_m == prev_m + 1) or (curr_h == prev_h + 1 and curr_m == 0 and prev_m == 59)

def process_log_file(filepath, max_filename_length):
    """Processes a log file to check timestamp continuity, size validity, and birth time statistics."""
    with open(filepath, 'r') as file:
        lines = file.readlines()
    
    start_index = 0
    for i, line in enumerate(lines):
        if "starting decoding" in line:
            start_index = i + 1
            break
    
    prev_time = None
    birth_microseconds = []
    for line in lines[start_index:]:
        match = re.search(r'(\d{8}T\d{6}Z)_\d+_[a-z]+\.wav: Size:(\d+) Birth:(\d{2}:\d{2}:\d{2}\.\d+)', line)
        if match:
            curr_time = parse_time(match.group(1)[9:14])  # Extract HH:MM from the timestamp
            size_value = int(match.group(2))
            birth_micro = parse_birth_time(match.group(3))
            
            if prev_time and not is_one_minute_later(prev_time, curr_time):
                print(f"Timestamp error in file {filepath}: {line.strip()}")
            
            if size_value != 2880252:
                print(f"Error: Incorrect size value {size_value} in file {filepath}, line: {line.strip()}")
            
            if birth_micro is not None:
                birth_microseconds.append(birth_micro)
            
            prev_time = curr_time
        else:
            print(f"Unmatched line: {line.strip()}")
    
    if birth_microseconds:
        min_birth = min(birth_microseconds) / 1000
        max_birth = max(birth_microseconds) / 1000
        avg_birth = (sum(birth_microseconds) / len(birth_microseconds)) / 1000
        print(f"{filepath.ljust(max_filename_length)} Min: {min_birth:.2f} ms  Max: {max_birth:.2f} ms  Avg: {avg_birth:.2f} ms")
    else:
        print(f"{filepath.ljust(max_filename_length)} No valid birth times found")

def main(filenames):
    """Main function to process sorted log files."""
    sorted_files = sorted(filenames, key=extract_sort_key, reverse=True)
    max_filename_length = max(len(f) for f in sorted_files) + 2
    for file in sorted_files:
        process_log_file(file, max_filename_length)

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <file1> <file2> ...")
        sys.exit(1)
    main(sys.argv[1:])
