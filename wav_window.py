#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Filename: wav_window_v1.py
# January  2020  Gwyn Griffiths
# Program to apply a Hann window to a wsprdaemon wav file for subsequent processing by sox stat -freq (initially at least)
 
from __future__ import print_function
import math
import scipy
import scipy.io.wavfile as wavfile
import numpy as np
import wave
import sys

WAV_INPUT_FILENAME=sys.argv[1]
WAV_OUTPUT_FILENAME=sys.argv[2]

# Set up the audio file parameters for windowing
# fs_rate is passed to the output file
fs_rate, signal = wavfile.read(WAV_INPUT_FILENAME)   # returns sample rate as int and data as numpy array
# set some constants
N_FFT=352                                   # this being the number expected
N_FFT_POINTS=4096                           # number of input samples in each sox stat -freq FFT (fixed)
                                            # so N_FFT * N_FFT_POINTS = 1441792 samples, which at 12000 samples per second is 120.15 seconds
                                            # while we have only 120 seconds, so for now operate with N_FFT-1 to have all filled
                                            # may decide all 352 are overkill anyway
N=N_FFT*N_FFT_POINTS
w=np.zeros(N_FFT_POINTS)

output=np.zeros(N, dtype=np.int16)          # declaring as dtype=np.int16 is critical as the wav file needs to be 16 bit integers

# create a N_FFT_POINTS array with the Hann weighting function
for i in range (0, N_FFT_POINTS):
  x=(math.pi*float(i))/float(N_FFT_POINTS)
  w[i]=np.sin(x)**2

for j in range (0, N_FFT-1):
  offset=j*N_FFT_POINTS
  for i in range (0, N_FFT_POINTS):
     output[i+offset]=int(w[i]*signal[i+offset])
wavfile.write(WAV_OUTPUT_FILENAME, fs_rate, output)
