#!/home/wsprdaemon/n5tnl/venv/bin/python3

import numpy as np
import os
import soundfile as sf
import sys
from pathlib import Path
from scipy import signal
import re

def cross_file(filename):
    # look for 0.8 seconds of 1 kHz (eventually, also 1.5 kHz at top of hour)

    # determine tone burst frequency from filename, if possible
    # expects a filename such as 20250405T044300Z_5000000_iq.wav
    tone = 1000
    regex_pattern = '(\d{8})T(\d{2})(\d{2})(\d{2})Z_(\d+)_([a-z]+).wav'
    match = re.search(regex_pattern, filename)
    if match:
        if int(match.group(3)) == 0:
            # top of hour, 1500 Hz instead of 1000 Hz
            tone = 1500

    # read first 3 seconds from wav file
    wav_sample_rate = sf.info(filename).samplerate
    samples, wav_sample_rate = sf.read(filename, frames = (3 * wav_sample_rate))

    # Convert to a 1d array of complex values
    samples_c = samples.view(dtype = np.complex128)

    # demod, remove DC offset, convert to 1d array
    wav_amp = np.abs(samples_c)
    wav_demod = wav_amp - np.mean(wav_amp);
    wav_demod = wav_demod.squeeze()

    # generate demod wav file for testing
    # sf.write('demod.wav', wav_demod, wav_sample_rate, subtype="FLOAT")

    # create 0.8 seconds of sine wav at 1 kHz
    x = np.linspace(0, 0.8, int(0.8 * wav_sample_rate))
    beep = 0.05 * np.sin(2 * x * np.pi * tone)

    # normalize amplitudes
    beep = (beep - np.mean(beep)) / np.std(beep)
    wav_demod = (wav_demod - np.mean(wav_demod)) / np.std(wav_demod)

    # cross corr
    corr = signal.correlate(wav_demod, beep, mode='full', method='fft')
    lags = signal.correlation_lags(len(wav_demod), len(beep), mode='full')

    peak = np.argmax(corr)
    wav_peak = lags[peak];
    peak_value = corr[peak]

    print(f'{1000.0 * (wav_peak / wav_sample_rate):.2f} ms')
    return

def main():
    cross_file(sys.argv[1])

if __name__ == '__main__':
    main()
