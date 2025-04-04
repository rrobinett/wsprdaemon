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

    # remove DC offset?
    wav_demod = wav_amp - np.mean(wav_amp);

    # generate demod wav file for testing
    #sf.write('demod.wav', wav_demod, wav_sample_rate, subtype="FLOAT")

    # save max to graph the trigger point
    wav_max = np.max(wav_demod)

    # average of demod signal, used to select trigger level and hopefully reject impulse noise
    wav_mean = np.mean(np.abs(wav_demod));
    print("Demod mean: {:.3e} {:.1f} dB".format(wav_mean, 10*np.log10(wav_mean)))
    trigger_level = wav_mean / 2
    print("Trigger_Level value: {:.3e} {:.1f} dB".format(trigger_level, 10*np.log10(trigger_level)))

    for s in range(0, wav_demod.shape[0]):
        if wav_demod[s] > trigger_level:
            print("{:.3f} ms".format(1000.0*(s/wav_sample_rate)))
            return wav_demod, s, wav_max, wav_sample_rate, trigger_level

    return 0, 0, 0, 0, 0

def main():
    one_second = None
    one_second, trigger_point, wav_max, sample_rate, trigger_level = check_file(sys.argv[1], one_second)

    if (len(sys.argv) > 2) and (sample_rate>0):
        with open(os.path.basename(sys.argv[2])+".gnuplot", 'w') as f:
            f.write("set output '{}.png'\n".format(os.path.basename(sys.argv[2])))
            f.write("set title '{} Start of Minute Tone Burst (naive method 2)' noenhanced\n".format(sys.argv[1]))
            f.write("set xlabel 'ms (burst detected at {} ms)'\n".format(1000.0 * (trigger_point / sample_rate)))
            f.write('''
set key left
set term png size 1920,1080
set datafile separator ","
set ylabel "Amplitude?"
set key noautotitles
set bmargin 10
''')
            f.write("plot '-' using 1:2 with lines title 'AM', '-' using 1:3 with lines title 'Trigger at sample {} on {:.3e} (1/2 mean amplitude)'\n".format(trigger_point, float(trigger_level)))

            for s in range(0, trigger_point*2):
                f.write("{}, {}, {}\n".format(s/sample_rate, float(one_second[s][0]), wav_max*1.1 if s > trigger_point else -wav_max*1.1))
            f.write('e\n')

            for s in range(0, trigger_point*2):
                f.write("{}, {}, {}\n".format(s/sample_rate, float(one_second[s][0]), wav_max*1.1 if s > trigger_point else -wav_max*1.1))
            f.write('e\n')

if __name__ == '__main__':
    main()
