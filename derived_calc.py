# -*- coding: utf-8 -*-
# April  2020  Gwyn Griffiths. Based on the add_azi used in the ts-wspr-scraper.sh script

# Takes receiver and transmitter Maidenhead locators and calculates azimuths at tx and rx, lats and lons, distance and vertes lat and lon
# Needs the two locators and frequency as arguments. If spot_grid="none" puts absent data in the calculated fields.
# The operating band is derived from the frequency, 60 and 60eu and 80 and 80eu are reported as 60 and 80
# Miles are not copied to the azi-appended file
# In the script the following lines preceed this code and there's an EOF added at the end
# G3ZIL python script that gets copied into /tmp/derived_calc.py and is run there

import numpy as np
from numpy import genfromtxt
import sys
import csv
import argparse

absent_data=-999.0

# derive the band in metres (except 70cm and 23cm reported as 70 and 23) from the frequency
freq_to_band = {
    1: 2200,
    4: 630,
    18: 160,
    35: 80,
    52: 60,
    53: 60,
    70: 40,
    101: 30,
    140: 20,
    181: 17,
    210: 15,
    249: 12,
    281: 10,
    502: 6,
    503: 6,
    700: 4,
    701: 4,
    1442: 2,
    1444: 2,
    1445: 2,
    4321: 70,
    4323: 70,
    4324: 70,
    4325: 70,
    12965: 23
}
default_band=9999

# define function to convert 4 or 6 character Maidenhead locator to lat and lon in degrees
def loc_to_lat_lon (locator):
    locator=locator.strip()
    decomp=list(locator)
    lat=(((ord(decomp[1])-65)*10)+(ord(decomp[3])-48)+(1/2)-90)
    lon=(((ord(decomp[0])-65)*20)+((ord(decomp[2])-48)*2)+(1)-180)
    if len(locator)==6:
        if (ord(decomp[4])) >88:    # check for case of the third pair, likely to  be lower case
            ascii_base=96
        else:
            ascii_base=64
        lat=lat-(1/2)+((ord(decomp[5])-ascii_base)/24)-(1/48)
        lon=lon-(1)+((ord(decomp[4])-ascii_base)/12)-(1/24)
    return(lat, lon)

def locate(tx_locator, rx_locator, frequency, fp):
    # open file for output as a csv file, to which we will put the calculated values
    with fp as out_file:
        fieldnames = ["band", "km", "rx_azi", "rx_lat", "rx_lon", "tx_azi", "tx_lat", "tx_lon", "v_lat", "v_lon"]
        out_writer=csv.DictWriter(out_file, delimiter=',', quotechar='"', quoting=csv.QUOTE_MINIMAL, fieldnames=fieldnames)
        out_writer.writeheader()
        # loop to calculate  azimuths at tx and rx (wsprnet only does the tx azimuth)
        if tx_locator!="none":
            (tx_lat,tx_lon)=loc_to_lat_lon (tx_locator)    # call function to do conversion, then convert to radians
            phi_tx_lat = np.radians(tx_lat)
            lambda_tx_lon = np.radians(tx_lon)
            (rx_lat,rx_lon)=loc_to_lat_lon (rx_locator)    # call function to do conversion, then convert to radians
            phi_rx_lat = np.radians(rx_lat)
            lambda_rx_lon = np.radians(rx_lon)
            delta_phi = (phi_tx_lat - phi_rx_lat)
            delta_lambda=(lambda_tx_lon-lambda_rx_lon)

            # calculate azimuth at the rx
            y = np.sin(delta_lambda) * np.cos(phi_tx_lat)
            x = np.cos(phi_rx_lat)*np.sin(phi_tx_lat) - np.sin(phi_rx_lat)*np.cos(phi_tx_lat)*np.cos(delta_lambda)
            rx_azi = (np.degrees(np.arctan2(y, x))) % 360

            # calculate azimuth at the tx
            p = np.sin(-delta_lambda) * np.cos(phi_rx_lat)
            q = np.cos(phi_tx_lat)*np.sin(phi_rx_lat) - np.sin(phi_tx_lat)*np.cos(phi_rx_lat)*np.cos(-delta_lambda)
            tx_azi = (np.degrees(np.arctan2(p, q))) % 360
            # calculate the vertex, the lat lon at the point on the great circle path nearest the nearest pole, this is the highest latitude on the path
            # no need to calculate special case of both transmitter and receiver on the equator, is handled OK
            # Need special case for any meridian, where vertex longitude is the meridian longitude and the vertex latitude is the lat nearest the N or S pole
            if tx_lon==rx_lon:
                v_lon=tx_lon
                v_lat=max([tx_lat, rx_lat], key=abs)
            else:
                v_lat=np.degrees(np.arccos(np.sin(np.radians(rx_azi))*np.cos(phi_rx_lat)))
            if v_lat>90.0:
                v_lat=180-v_lat
            if rx_azi<180:
                v_lon=((rx_lon+np.degrees(np.arccos(np.tan(phi_rx_lat)/np.tan(np.radians(v_lat)))))+360) % 360
            else:
                v_lon=((rx_lon-np.degrees(np.arccos(np.tan(phi_rx_lat)/np.tan(np.radians(v_lat)))))+360) % 360
            if v_lon>180:
                v_lon=-(360-v_lon)
            # now test if vertex is not  on great circle track, if so, lat/lon nearest pole is used
            if v_lon < min(tx_lon, rx_lon) or v_lon > max(tx_lon, rx_lon):
            # this is the off track case
                v_lat=max([tx_lat, rx_lat], key=abs)
                if v_lat==tx_lat:
                    v_lon=tx_lon
                else:
                    v_lon=rx_lon
            # now calculate the short path great circle distance
            a=np.sin(delta_phi/2)*np.sin(delta_phi/2)+np.cos(phi_rx_lat)*np.cos(phi_tx_lat)*np.sin(delta_lambda/2)*np.sin(delta_lambda/2)
            c=2*np.arctan2(np.sqrt(a), np.sqrt(1-a))
            km=6371*c
        else:
            v_lon=absent_data
            v_lat=absent_data
            tx_lon=absent_data
            tx_lat=absent_data
            rx_lon=absent_data
            rx_lat=absent_data
            rx_azi=absent_data
            tx_azi=absent_data
            km=absent_data
            # end of list of absent data values for where tx_locator = "none"

        freq=int(10*float(frequency))
        band = freq_to_band.get(freq, default=default_band)
        # output the original data, except for pwr in W and miles, and add lat lon at tx and rx, azi at tx and rx, vertex lat lon and the band
        row = {
            "band": band,
            "km": "%.0f" % (km),
            "rx_azi": "%.0f" % (rx_azi),
            "rx_lat": "%.3f" % (rx_lat),
            "rx_lon": "%.3f" % (rx_lon),
            "tx_azi": "%.0f" % (tx_azi),
            "tx_lat": "%.1f" % (tx_lat),
            "tx_lon": "%.1f" % (tx_lon),
            "v_lat": "%.3f" % (v_lat),
            "v_lon": "%.3f" % (v_lon)
        }
        out_writer.writerow(row)

if __name__ == "__main__":
    # get the rx_locator, tx_locator and frequency from the command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument("tx_locator")
    parser.add_argument("rx_locator")
    parser.add_argument("frequency")
    parser.add_argument('outfile', nargs='?', type=argparse.FileType('w'), default=sys.stdout)
    args = parser.parse_args()

    print("tx_locator: %s; rx_locator: %s; frequency: %s" % (args.tx_locator, args.rx_locator, args.frequency))

    locate(args.tx_locator, args.rx_locator, args.frequency, args.outfile)

