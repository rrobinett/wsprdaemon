import matplotlib
import os
import warnings

# Suppress specific Matplotlib warning
warnings.filterwarnings("ignore", category=UserWarning,
                        message=".*Unable to import Axes3D.*")

# Force TkAgg backend for GUI plotting
matplotlib.use('TkAgg')

import re
import sys
import matplotlib.pyplot as plt
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
    """Parses a birth time in HH:MM:SS.nanoseconds format and returns nanoseconds if seconds == 00."""
    try:
        h, m, s_nano = birth_time.split(':')
        s, nano = map(int, s_nano.split('.'))
        if int(s) != 0:
            return None  # Ignore if seconds are not 00
        return nano
    except ValueError:
        return None

def parse_tone_burst_offset(offset):
    """Parses the Tone_burst_offset in milliseconds and returns the value."""
    try:
        return float(offset)
    except ValueError:
        return None

def is_one_minute_later(prev_time, curr_time):
    """Checks if curr_time is exactly one minute later than prev_time."""
    if not prev_time or not curr_time:
        return False
    prev_h, prev_m = prev_time
    curr_h, curr_m = curr_time
    return (prev_h == curr_h and curr_m == prev_m + 1) or (curr_h == prev_h + 1 and curr_m == 0 and prev_m == 59)

def process_log_file(filepath, max_filename_length, index):
    """Processes a log file to check timestamp continuity, size validity, and birth time statistics."""
    with open(filepath, 'r') as file:
        lines = file.readlines()

    start_index = 0
    for i, line in enumerate(lines):
        if "starting decoding" in line:
            start_index = i + 1
            break

    regex_pattern = ('(\d{8}T\d{6}Z)_(\d+)_[a-z]+.wav:\s+Size:(\d+)\s+'
    'Birth:(\d{2}:\d{2}:\d{2}\.\d+)\s+'
    'Change:(\d{2}:\d{2}:\d{2}\.\d+)\s+'
    'Tone_burst_offset:(\d+\.\d+)_ms')

    prev_time = None
    birth_nanoseconds = []
    tone_burst_offsets = []
    first_10_samples = []
    last_10_samples = []
    total_lines_processed = 0

    for line in lines[start_index:]:
        total_lines_processed += 1
        match = re.search(regex_pattern, line)
        if match:
            curr_time = parse_time(match.group(1)[9:14])  # Extract HH:MM from the timestamp
            size_value = int(match.group(3))
            birth_nano = parse_birth_time(match.group(4))
            tone_burst_offset = parse_tone_burst_offset(match.group(6))

            if prev_time and not is_one_minute_later(prev_time, curr_time):
                print(f"Timestamp error in file {filepath}: {line.strip()}")

            if size_value not in (7680252, 2880252):
                print(f"Error: Incorrect size value {size_value} in file {filepath}, line: {line.strip()}")

            if birth_nano is not None:
                birth_nanoseconds.append(birth_nano)
                if len(first_10_samples) < 10:
                    first_10_samples.append(birth_nano)
                last_10_samples.append(birth_nano)
                if len(last_10_samples) > 10:
                    last_10_samples.pop(0)

            if tone_burst_offset is not None:
                tone_burst_offsets.append(tone_burst_offset)

            prev_time = curr_time
        else:
            print(f"Unmatched line: {line.strip()}")

    if birth_nanoseconds:
        min_birth = min(birth_nanoseconds) / 1_000_000
        max_birth = max(birth_nanoseconds) / 1_000_000
        avg_birth = (sum(birth_nanoseconds) / len(birth_nanoseconds)) / 1_000_000

        # Calculate average for first and last 10 samples
        avg_first_10 = (sum(first_10_samples) / len(first_10_samples)) / 1_000_000 if first_10_samples else 0
        avg_last_10 = (sum(last_10_samples) / len(last_10_samples)) / 1_000_000 if last_10_samples else 0

        if tone_burst_offsets:
            min_tone_burst = min(tone_burst_offsets)
            max_tone_burst = max(tone_burst_offsets)
            avg_tone_burst = sum(tone_burst_offsets) / len(tone_burst_offsets)
        else:
            min_tone_burst = max_tone_burst = avg_tone_burst = 0

        # Print summary with index as fixed-width (4 characters)
        print(f"[{str(index).rjust(3)}] {filepath.ljust(max_filename_length)} Min: {min_birth:9.2f} ms  Max: {max_birth:9.2f} ms  Avg: {avg_birth:9.2f} ms  "
              f"First 10 Avg: {avg_first_10:6.2f} ms  Last 10 Avg: {avg_last_10:6.2f} ms  "
              f"Tone Burst Min: {min_tone_burst:6.2f} ms  Max: {max_tone_burst:6.2f} ms  Avg: {avg_tone_burst:6.2f} ms  "
              f"Total Lines Processed: {total_lines_processed:5}")

        return birth_nanoseconds, tone_burst_offsets
    else:
        print(f"{filepath.ljust(max_filename_length)} No valid birth times found")
        return None

def plot_birth_times(filepath, birth_nanoseconds, tone_burst_offsets):
    """Plots birth time graph and displays it interactively."""
    if not birth_nanoseconds:
        print("No valid birth times to plot.")
        return

    plt.figure(figsize=(10, 6))
    plt.plot(range(len(birth_nanoseconds)), [b / 1_000_000 for b in birth_nanoseconds], marker='o', linestyle='-', color='b')
    if tone_burst_offsets:
        plt.plot(range(len(tone_burst_offsets)), [b for b in tone_burst_offsets], marker='o', linestyle='-', color='r')

    plt.title(f"Birth Time / WWV Offset Graph for {filepath}")
    plt.xlabel("Sample Index")
    plt.ylabel("Birth Time (ms)")
    plt.grid(True)
    plt.tight_layout()

    # Show plot interactively without saving it to a file
    plt.show()

def main(filenames):
    """Main function to process sorted log files."""
    sorted_files = sorted(filenames, key=extract_sort_key, reverse=True)
    max_filename_length = max(len(f) for f in sorted_files) + 2
    birth_times = {}
    tone_bursts = {}

    # Collect summaries and process files
    for idx, file in enumerate(sorted_files, start=1):
        birth_nanoseconds, tone_burst_offsets = process_log_file(file, max_filename_length, idx)
        if birth_nanoseconds:
            birth_times[file] = birth_nanoseconds
        if tone_burst_offsets:
            tone_bursts[file] = tone_burst_offsets

    # Check if DISPLAY is set and allow plotting
    if 'DISPLAY' in os.environ:
        while True:
            # Ask the user for the index of the summary to plot
            index_input = input("\nEnter the index to plot (or press Enter to skip): ").strip()

            if not index_input:  # User pressed Enter without typing anything, exit the loop
                print("Exiting...")
                break

            try:
                index = int(index_input)
                if 0 < index <= len(sorted_files):
                    plot_birth_times(sorted_files[index - 1], birth_times.get(sorted_files[index - 1]), tone_bursts.get(sorted_files[index - 1]))
                else:
                    print(f"Invalid index. Please enter a number between 1 and {len(sorted_files)}.")
            except ValueError:
                print("Invalid input. Please enter a valid index or press Enter to exit.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <file1> <file2> ...")
        sys.exit(1)
    main(sys.argv[1:])
