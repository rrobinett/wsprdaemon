import re
import sys
import os
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

        # Print summary with all stats aligned, including first 10 and last 10 averages
        summary = (f"{filepath.ljust(max_filename_length)} Min: {min_birth:9.2f} ms  Max: {max_birth:9.2f} ms  "
                   f"Avg: {avg_birth:9.2f} ms  First 10 Avg: {avg_first_10:6.2f} ms  Last 10 Avg: {avg_last_10:6.2f} ms  "
                   f"Total Lines Processed: {total_lines_processed:5}")

        return summary, birth_nanoseconds
    else:
        return f"{filepath.ljust(max_filename_length)} No valid birth times found", None

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
    plt.show()
    print(f"Plot saved: {plot_filename}")

def main(filenames):
    """Main function to process sorted log files and interactively plot."""
    sorted_files = sorted(filenames, key=extract_sort_key, reverse=True)
    max_filename_length = max(len(f) for f in sorted_files) + 2

    summaries = []
    birth_data = []

    for file in sorted_files:
        summary, birth_nanoseconds = process_log_file(file, max_filename_length)
        summaries.append(summary)
        birth_data.append((file, birth_nanoseconds))

    # Print indexed summary with fixed-width index
    for i, summary in enumerate(summaries):
        print(f"[{i:>3}] {summary}")

    # If DISPLAY is set, prompt user to plot a selection
    if "DISPLAY" in os.environ:
        try:
            index = input("\nEnter index to plot (or press Enter to skip): ").strip()
            if index:
                index = int(index)
                if 0 <= index < len(birth_data):
                    plot_birth_times(birth_data[index][0], birth_data[index][1])
                else:
                    print("Invalid index.")
        except ValueError:
            print("Invalid input. Skipping plot.")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python script.py <file1> <file2> ...")
        sys.exit(1)
    main(sys.argv[1:])
