# -*- coding: utf-8 -*-
# Filename: wsprnet_azi_calc.py
# February  2020  Gwyn Griffiths

# Take a scraper latest_log.txt file, extract the receiver and transmitter Maidenhead locators and calculates azimuth at tx and rx in that order
# Needs one argument, file path for latest_log.txt
# V1.0 outputs the azi-appended data to a file spots+azi.csv that is overwritten next 3 min cycle, this file appended to the master
# V1.1 also outputs lat and lo for tx and rx and the vertex, the point on the path nearest the pole (highest latitude) for the short path
# The vertex in the other hemisphere has the sign of the latitude reversed and 180˚ added to the longitude
# V1.2 The operating band is derived from the frequency, 60 and 60eu and 80 and 80eu are reported as 60 and 80
# Miles are not copied to the azi-appended file
# In the script the following lines preceed this code and there's an EOF added at the end
# V1.3 RR modified to accept API spot lines

import argparse
import csv
import datetime
import json
import os
import sys
import numpy as np

column_names = [
    "wd_time",
    "Spotnum",
    "Date",
    "Reporter",
    "ReporterGrid",
    "dB",
    "MHz",
    "CallSign",
    "Grid",
    "Power",
    "Drift",
    "distance",
    "azimuth",
    "Band",
    "version",
    "code"
]
additional_column_names = [
    "wd_band",
    "wd_c2_noise",
    "wd_rms_noise",
    "wd_rx_az",
    "wd_rx_lat",
    "wd_rx_lon",
    "wd_tx_az",
    "wd_tx_lat",
    "wd_tx_lon",
    "wd_v_lat",
    "wd_v_lon"
]

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
    700: 4,
    1444: 2,
    4323: 70,
    12965: 23
}
default_band = 9999

def loc_to_lat_lon(locator):
    """Convert a 4 or 6 character Maidenhead locator string to a tuple containing lat and lon in degrees"""
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

def calculate_azimuth(frequency, tx_locator, rx_locator):
    """Calculate various location data and return them as a tuple in the additional_column_names order"""
    (tx_lat, tx_lon) = loc_to_lat_lon(tx_locator)    # call function to do conversion, then convert to radians
    phi_tx_lat = np.radians(tx_lat)
    lambda_tx_lon = np.radians(tx_lon)
    (rx_lat,rx_lon) = loc_to_lat_lon(rx_locator)    # call function to do conversion, then convert to radians
    phi_rx_lat = np.radians(rx_lat)
    lambda_rx_lon = np.radians(rx_lon)
    delta_phi = (phi_tx_lat - phi_rx_lat)
    delta_lambda = (lambda_tx_lon-lambda_rx_lon)

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
    if tx_lon == rx_lon:
        v_lon = tx_lon
        v_lat = max([tx_lat, rx_lat], key=abs)
    else:
        v_lat = np.degrees(np.arccos(np.sin(np.radians(rx_azi))*np.cos(phi_rx_lat)))
    if v_lat > 90.0:
        v_lat = 180 - v_lat
    if rx_azi < 180:
        v_lon = ((rx_lon + np.degrees(np.arccos(np.tan(phi_rx_lat) / np.tan(np.radians(v_lat))))) + 360) % 360
    else:
        v_lon = ((rx_lon - np.degrees(np.arccos(np.tan(phi_rx_lat) / np.tan(np.radians(v_lat))))) + 360) % 360
    if v_lon > 180:
        v_lon = -(360 - v_lon)
    # now test if vertex is not  on great circle track, if so, lat/lon nearest pole is used
    if v_lon < min(tx_lon, rx_lon) or v_lon > max(tx_lon, rx_lon):
    # this is the off track case
        v_lat = max([tx_lat, rx_lat], key=abs)
        if v_lat == tx_lat:
            v_lon = tx_lon
        else:
            v_lon = rx_lon
    # derive the band in metres (except 70cm and 23cm reported as 70 and 23) from the frequency
    freq = int(10 * float(frequency))
    band = freq_to_band.get(freq, default_band)
    return (band, rx_azi, rx_lat, rx_lon, tx_azi, tx_lat, tx_lon, v_lat, v_lon)

def process_csv_input(csv_file):
    """Process a CSV input file and return the data as an array of dictionaries with the column_names and additional_column_names keys"""
    # now read in lines file, as a single string, skip over lines with unexpected number of columns
    spot_lines=np.genfromtxt(csv_file, dtype='str', delimiter=',', loose=True, invalid_raise=False)
    # get number of lines
    n_lines=len(spot_lines)

    # loop to calculate  azimuths at tx and rx (wsprnet only does the tx azimuth)
    spots = []
    for i in range(0, n_lines):
        (band, rx_azi, rx_lat, rx_lon, tx_azi, tx_lat, tx_lon, v_lat, v_lon) = calculate_azimuth(frequency=spot_lines[i, 6], tx_locator=spot_lines[i, 8], rx_locator=spot_lines[i, 4])
        # output the original data and add lat lon at tx and rx, azi at tx and rx, vertex lat lon and the band
        updated_spot = {
            "wd_time": spot_lines[i, 0],
            "Spotnum": spot_lines[i, 1],
            "Date": spot_lines[i, 2],
            "Reporter": spot_lines[i, 3],
            "ReporterGrid": spot_lines[i, 4],
            "dB": spot_lines[i, 5],
            "MHz": spot_lines[i, 6],
            "CallSign": spot_lines[i, 7],
            "Grid": spot_lines[i, 8],
            "Power": spot_lines[i, 9],
            "Drift": spot_lines[i, 10],
            "distance": spot_lines[i, 11],
            "azimuth": spot_lines[i, 12],
            "Band": spot_lines[i, 13],
            "version": spot_lines[i, 14],
            "code": spot_lines[i, 15],
            "wd_band": band,
            "wd_c2_noise": "-999.9",
            "wd_rms_noise": "-999.9",
            "wd_rx_az": int(round(rx_azi)),
            "wd_rx_lat": "%.3f" % (rx_lat),
            "wd_rx_lon": "%.3f" % (rx_lon),
            "wd_tx_az": int(round(tx_azi)),
            "wd_tx_lat": "%.3f" % (tx_lat),
            "wd_tx_lon": "%.3f" % (tx_lon),
            "wd_v_lat": "%.3f" % (v_lat),
            "wd_v_lon": "%.3f" % (v_lon)
        }
        spots.append(updated_spot)
    return spots

def process_json_input(json_file):
    """Process a JSON input file and return the data as an array of dictionarys with the column_names and additional_column_names keys"""
    original_spots = json.load(json_file)

    # loop to calculate  azimuths at tx and rx (wsprnet only does the tx azimuth)
    spots = []
    for original_spot in original_spots:
        # ensure we drop any unknown keys and values
        filtered_spot = {key: value for (key, value) in original_spot.items() if key in column_names}
        # add the wd_time that wsprnet-scraper.sh seems to be creating
        filtered_spot["wd_time"] = datetime.datetime.fromtimestamp(int(original_spot['Date']), tz=datetime.timezone.utc).strftime("%Y-%m-%d:%H:%M")
        (band, rx_azi, rx_lat, rx_lon, tx_azi, tx_lat, tx_lon, v_lat, v_lon) = calculate_azimuth(frequency=original_spot["MHz"], tx_locator=original_spot["Grid"], rx_locator=original_spot["ReporterGrid"])
        additional_values = {
            "wd_band": band,
            "wd_c2_noise": "-999.9",
            "wd_rms_noise": "-999.9",
            "wd_rx_az": int(round(rx_azi)),
            "wd_rx_lat": "%.3f" % (rx_lat),
            "wd_rx_lon": "%.3f" % (rx_lon),
            "wd_tx_az": int(round(tx_azi)),
            "wd_tx_lat": "%.3f" % (tx_lat),
            "wd_tx_lon": "%.3f" % (tx_lon),
            "wd_v_lat": "%.3f" % (v_lat),
            "wd_v_lon": "%.3f" % (v_lon)
        }
        updated_spot = {**filtered_spot, **additional_values}
        spots.append(updated_spot)
    return spots

def wsprnet_azi_calc(input_file, output_file):
    """Process an input file and output the data as a CSV"""
    with input_file as in_file:
        extension = os.path.splitext(in_file.name)[1]
        if extension == ".csv":
            spots = process_csv_input(csv_file=in_file)
        # assume JSON if not explicitly given a CSV file, including via STDIN
        else:
            spots = process_json_input(json_file=in_file)

    # open file for output as a csv file, to which we will copy original data and the tx and rx azimuths
    with output_file as out_file:
        out_writer = csv.DictWriter(out_file, fieldnames=column_names + additional_column_names, delimiter=',', quotechar='"', quoting=csv.QUOTE_MINIMAL)
        for spot in spots:
            out_writer.writerow(spot)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Add azimuth calculations to a WSPRNET Spots TSV file')
    parser.add_argument("-i", "--input", dest="spotsFile", help="FILE is a CSV containing WSPRNET spots", metavar="FILE", required=True, nargs='?', type=argparse.FileType('r'), default=sys.stdin)
    parser.add_argument("-o", "--output", dest="spotsPlusAzimuthsFile", help="FILE is a CSV containing WSPRNET spots", metavar="FILE", required=True, nargs='?', type=argparse.FileType('w'), default=sys.stdout)
    args = parser.parse_args()

    wsprnet_azi_calc(input_file=args.spotsFile, output_file=args.spotsPlusAzimuthsFile)