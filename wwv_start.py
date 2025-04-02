#!/home/wsprdaemon/n5tnl/venv/bin/python3

import numpy as np
import os
import soundfile as sf
import sys
from pathlib import Path

def check_file(filename, one_second):
    samples, wav_sample_rate = sf.read(filename)

    # Convert to a 1d array of complex values
    samples_c = samples.view(dtype = np.complex128)

    # Not sure if this is power, but it should be sqrt(I^2 + Q^2)
    wav_amp = np.abs(samples_c)
    wav_mean = np.mean(wav_amp)
    wav_amp = wav_amp - wav_mean;
    wav_max = np.max(wav_amp)

    for s in range(0, samples.shape[0]):
        if wav_amp[s] > (wav_max/2):
            print("{:.3f} ms".format(1000.0*(s/wav_sample_rate)))
            return wav_amp, s, wav_max, wav_sample_rate
        
    return 0, 0, 0, 0

def main():
    one_second = None
    one_second, trigger, wav_max, sample_rate = check_file(sys.argv[1], one_second)

    if (len(sys.argv) > 2) and (sample_rate>0):
        with open(os.path.basename(sys.argv[2])+".gnuplot", 'w') as f:
            f.write("set output '{}.png'\n".format(os.path.basename(sys.argv[2])))
            f.write("set title '{} Start of Minute Tone Burst (naive method)' noenhanced\n".format(sys.argv[1]))
            f.write("set xlabel 'ms (burst detected at {} ms)'\n".format(1000.0 * (trigger / sample_rate)))
            f.write('''
set key left
set term png size 1920,1080
set datafile separator ","
set ylabel "Amplitude?"
set key noautotitles
set bmargin 10
plot '-' using 1:2 with lines title "AM", '-' using 1:3 with lines title "Trigger on 1/2 max amplitude"
''')

            for s in range(0, trigger*2):
                f.write("{}, {}, {}\n".format(s/sample_rate, float(one_second[s][0]), wav_max*1.1 if s > trigger else -wav_max*1.1))
            f.write('e\n')

            for s in range(0, trigger*2):
                f.write("{}, {}, {}\n".format(s/sample_rate, float(one_second[s][0]), wav_max*1.1 if s > trigger else -wav_max*1.1))
            f.write('e\n')
    
if __name__ == '__main__':
    main()
