import soundfile as sf
import numpy as np
import argparse

# Set up argument parser
parser = argparse.ArgumentParser(description="Find the maximum sample value and its dBFS value in a list of audio files.")
parser.add_argument("files", nargs='+', help="Paths to the input WAV files")
args = parser.parse_args()

max_sample_value = -np.inf  # Initialize to the smallest possible value

# Process each file
for file_path in args.files:
    try:
        # Read the audio file
        data, samplerate = sf.read(file_path)
        
        # Flatten the data if it's multi-channel
        if data.ndim > 1:
            data = data.flatten()
        
        # Update the maximum sample value
        file_max = np.max(np.abs(data))
        max_sample_value = max(max_sample_value, file_max)
        
#        print(f"File: {file_path}, Max Sample: {file_max:.12f}")
    
    except Exception as e:
        print(f"Error processing {file_path}: {e}")

# Compute dBFS for the overall maximum sample
if max_sample_value > -np.inf:
    overall_dbfs = 20 * np.log10(max_sample_value) if max_sample_value > 0 else -float('inf')
#    print(f"\nOverall Max Sample Value (Linear): {max_sample_value:.12f}")
#    print(f"Overall Max Sample Value (dBFS): {overall_dbfs:.12f} dBFS")
    print(f"{max_sample_value:.12f}")
    print(f"{overall_dbfs:.12f}")
else:
    print("\nNo valid files processed.")

