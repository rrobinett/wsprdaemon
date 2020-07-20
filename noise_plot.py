#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Filename: noise_plot.py
# April-May  2019  Gwyn Griffiths G3ZIL
# Use matplotlib to plot noise levels recorded by wsprdaemon by the sox stats RMS and sox stat -freq methods
# V0 Testing prototype 

# Import the required Python modules and methods some may need downloading 
from __future__ import print_function
import math
import datetime
#import scipy
import numpy as np
from numpy import genfromtxt
import csv
import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt
#from matplotlib import cm
import matplotlib.dates as mdates
import sys

# Get cmd line args
reporter=sys.argv[1]
maidenhead=sys.argv[2]
output_png_filepath=sys.argv[3]
calibration_file_path=sys.argv[4]
csv_file_path_list=sys.argv[5].split()    ## noise_plot.py KPH "/home/pi/.../2200 /home/pi/.../630 ..."

# read in the reporter-specific calibration file and print out
# if one didn't exist the bash script would have created one
# the user can of course manually edit the specific noise_cal_vals.csv file if need be
cal_vals=genfromtxt(calibration_file_path, delimiter=',')
nom_bw=cal_vals[0]
ne_bw=cal_vals[1]
rms_offset=cal_vals[2]
freq_offset=cal_vals[3]
fft_band=cal_vals[4]
threshold=cal_vals[5]

# need to set the noise equiv bw for the -freq method. It is 322 Hz if nom bw is 500Hz else it is ne_bw as set
if nom_bw==500:
    freq_ne_bw=322
else:
    freq_ne_bw=ne_bw

x_pixel=40
y_pixel=30
my_dpi=50         # set dpi and size for plot - these values are largest I can get on Pi window, resolution is good
fig = plt.figure(figsize=(x_pixel, y_pixel), dpi=my_dpi)
fig.subplots_adjust(hspace=0.4, wspace=0.4)
plt.rcParams.update({'font.size': 18})

# get, then set, start and stop time in UTC for use in overall title of charts
stop_t=datetime.datetime.utcnow()
start_t=stop_t-datetime.timedelta(days=1)   ### Plot last 24 hours
stop_time=stop_t.strftime('%Y-%m-%d %H:%M')
start_time=start_t.strftime('%Y-%m-%d %H:%M')

fig.suptitle("Site: '%s' Maidenhead: '%s'\n Calibrated noise (dBm in 1Hz, Temperature in K) red=RMS blue=FFT\n24 hour time span from '%s' to '%s' UTC" % (reporter, maidenhead, start_time, stop_time), x=0.5, y=0.99, fontsize=24)

# Process the list of csv  noise files
j=1
# get number of csv files to plot then divide by three and round up to get number of rows
plot_rows=int(math.ceil((len(csv_file_path_list)/3.0)))
for csv_file_path in csv_file_path_list:
    # matplotlib x axes with time not straightforward, get timestamp in separate 1D array as string
    timestamp  = genfromtxt(csv_file_path, delimiter=',', usecols=0, dtype=str)
    noise_vals = genfromtxt(csv_file_path, delimiter=',')[:,1:]  

    n_recs=int((noise_vals.size)/15)              # there are 15 comma separated fields in each row, all in one dimensional array as read
    noise_vals=noise_vals.reshape(n_recs,15)      # reshape to 2D array with n_recs rows and 15 columns

    # now  extract the freq method data and calibrate
    freq_noise_vals=noise_vals[:,13]  ### +freq_offset+10*np.log10(1/freq_ne_bw)+fft_band+threshold
    rms_trough_start=noise_vals[:,3]
    rms_trough_end=noise_vals[:,11]
    rms_noise_vals=np.minimum(rms_trough_start, rms_trough_end)
    rms_noise_vals=rms_noise_vals     #### +rms_offset+10*np.log10(1/ne_bw)
    ov_vals=noise_vals[:,14]          ### The OV (overload counts) reported by Kiwis have been added in V2.9

    # generate x axis with time
    fmt = mdates.DateFormatter('%H')          # fmt line sets the format that will be printed on the x axis
    timeArray = [datetime.datetime.strptime(k, '%d/%m/%y %H:%M') for k in timestamp]     # here we extract the fields from our original .csv timestamp

    ax1 = fig.add_subplot(plot_rows, 3, j)
    ax1.plot(timeArray, freq_noise_vals, 'b.', ms=2)
    ax1.plot(timeArray, rms_noise_vals, 'r.', ms=2)
    # ax1.plot(timeArray, ov_vals, 'g.', ms=2)       # OV values will need to be scaled if they are to appear on the graph along with noise levels

    ax1.xaxis.set_major_formatter(fmt)
 
    path_elements=csv_file_path.split('/')
    plt.title("Receiver %s   Band:%s" % (path_elements[len(path_elements)-3], path_elements[len(path_elements)-2]), fontsize=24)
    
    #axes = plt.gca()
    # GG chart start and stop UTC time as end now and start 1 day earlier, same time as the x axis limits
    ax1.set_xlim([datetime.datetime.utcnow()-datetime.timedelta(days=1), datetime.datetime.utcnow()])
    # first get 'loc' for the hour tick marks at an interval of 2 hours then use 'loc' to set the major tick marks and grid
    loc=mpl.dates.HourLocator(byhour=None, interval=2, tz=None)
    ax1.xaxis.set_major_locator(loc)

    #   set y axes lower and upper limits
    y_dB_lo=-175
    y_dB_hi=-105
    y_K_lo=10**((y_dB_lo-30)/10.)*1e23/1.38
    y_K_hi=10**((y_dB_hi-30)/10.)*1e23/1.38
    ax1.set_ylim([y_dB_lo, y_dB_hi])
    ax1.grid()

    # set up secondary y axis
    ax2 = ax1.twinx()
    # automatically set its limits to be equivalent to the dBm limits
    ax2.set_ylim([y_K_lo, y_K_hi])
    ax2.set_yscale("log")

    j=j+1  
fig.savefig(output_png_filepath)
