import matplotlib
matplotlib.use('TkAgg')  # Set the backend to TkAgg (GUI-supported)

import re
import sys
import matplotlib.pyplot as plt
import os
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
    birth_nanoseconds = []
    first_10_samples = []
    last_10_samples = []
    total_lines_processed = 0

    for line in lines[start_index:]:
        total_lines_processed += 1
        match = re.search(r'(\d{8}T\d{6}Z)_\d+_[a-z]+\.wav: Size:(\d+) Birth:(\d{2}:\d{2}:\d{2}\.\d+)', line)
        if match:
            curr_time = parse_time(match.group(1)[9:14])  # Extract HH:MM from the timestamp
            size_value = int(match.group(2))
            birth_nano = parse_birth_time(match.group(3))

            if prev_time and not is_one_minute_later(prev_time, curr_time):
                print(f"Timestamp error in file {filepath}: {line.strip()}")

            if size_value != 2880252:
                print(f"Error: Incorrect size value {size_value} in file {filepath}, line: {line.strip()}")

            if birth_nano is not None:
                birth_nanoseconds.append(birth_nano)
                if len(first_10_samples) < 10:
                    first_10_samples.append(birth_nano)
                last_10_samples.append(birth_nano)
                if len(last_10_samples) > 10:
                    last_10_samples.pop(0)

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

        # Print summary with all stats aligned
        print(f"{str(len(birth_nanoseconds)).ljust(4)} {filepath.ljust(max_filename_length)} Min: {min_birth:9.2f} ms  Max: {max_birth:9.2f} ms  Avg: {avg_birth:9.2f} ms  "
              f"First 10 Avg: {avg_first_10:6.2f} ms  Last 10 Avg: {avg_last_10:6.2f} ms  "
              f"Total Lines Processed: {total_lines_processed:5}")

        return birth_nanoseconds
    else:
        print(f"{filepath.ljust(max_filename_length)} No valid birth times found")
        return None

def plot_birth_times(filepath, birth_nanoseconds):
    """Plots birth time graph and saves it as a PNG."""
    if not birth_nanoseconds:
        print("No valid birth times to plot.")
        return

    plt.figure(figsize=(10, 6))
    plt.plot(range(len(birth_nanoseconds)), [b / 1_000_000 for b in birth_nanoseconds], marker='o', linestyle='-', color='b')
    plt.title(f"Birth Time Graph for {filepath}")
    plt.xlabel("Sample Index")
    plt.ylabel("Birth Time (ms)")
    plt.grid(True)
    plt.tight_layout()
    plot_filename = f"{filepath}_birth_time_graph.png"
    plt.savefig(plot_filename)
    plt.show()  # This will block and keep the plot open until closed by the user

    # Print plot saved message after the plot is closed
    print(f"Plot saved: {plot_filename}")

def main(filenames):
    """Main function to process sorted log files."""
    sorted_files = sorted(filenames, key=extract_sort_key, reverse=True)
    max_filename_length = max(len(f) for f in sorted_files) + 2
    birth_times = {}

    # Collect summaries
    for index, file in enumerate(sorted_files):
        print(f"Processing {file}")  # Add this for debugging to check if files are being processed
        birth_nanoseconds = process_log_file(file, max_filename_length)
        if birth_nanoseconds:
            birth_times[index] = birth_nanoseconds

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
                if 0 <= index < len(sorted_files):
                    plot_birth_times(sorted_files[index], birth_times.get(index))
                else:
                    print(f"Invalid index. Please enter a number between 0 and {len(sorted_files)-1}.")
            except ValueError:
                print("Invalid input. Please enter a valid index or press Enter to exit.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <file1> <file2> ...")
        sys.exit(1)
    main(sys.argv[1:])
