#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Filename: c2_noise.py
# Program to extract the noise level from the 'wsprd -c' C2 format file
## V1 by Christoph Mayer. This version V1.1 by Gwyn Griffiths to output a single value
## being the total power (dB arbitary scale) in the lowest 30% of the Fourier coefficients
## between 1369.5 and 1630.5 Hz where the passband is flat.

import struct
import sys
import numpy as np

fn = sys.argv[1] ## '000000_0001.c2'

with open(fn, 'rb') as fp:
     ## decode the header:
     filename,wspr_type,wspr_freq = struct.unpack('<14sid', fp.read(14+4+8))

     ## extract I/Q samples
     samples = np.fromfile(fp, dtype=np.float32)
     z = samples[0::2]+1j*samples[1::2]
     #print(filename,wspr_type,wspr_freq,samples[:100], len(samples), z[:10])

     ## z contains 45000 I/Q samples
     ## we perform 180 FFTs, each 250 samples long
     a     = z.reshape(180,250)
     a    *= np.hanning(250)
     freqs = np.arange(-125,125, dtype=np.float32)/250*375 ## was just np.abs, square to get power
     w     = np.square(np.abs(np.fft.fftshift(np.fft.fft(a, axis=1), axes=1)))
     ## these expressions first trim the frequency range to 1369.5 to 1630.5 Hz to ensure
     ## a flat passband without bias from the shoulders of the bandpass filter
     ## i.e. array indices 38:213
     w_bandpass=w[0:179,38:213]
     ## partitioning is done on the flattened array of coefficients
     w_flat_sorted=np.partition(w_bandpass, 9345, axis=None)
     noise_level_flat=10*np.log10(np.sum(w_flat_sorted[0:9344]))
     print(' %6.2f' % (noise_level_flat))
