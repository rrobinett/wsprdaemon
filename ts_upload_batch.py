#!/usr/bin/python3
# March-May  2020  Gwyn Griffiths
# ts_batch_upload.py   a program to read in a spots file scraped from wsprnet.org by scraper.sh and upload to a TimescaleDB
# Version 1.2 May 2020 batch upload from a parsed file. Takes about 1.7s compared with 124s for line by line
# that has been pre-formatted with an awk line to be in the right order and have single quotes around the time and character fields
# Added additional diagnostics to identify which part of the upload fails (12 in 1936 times)
import psycopg2                  # This is the main connection tool, believed to be written in C
import psycopg2.extras           # This is needed for the batch upload functionality
import csv                       # To import the csv file
import sys                       # to get at command line argument with argv

# initially set the connection flag to be None
conn=None
connected="Not connected"
cursor="No cursor"
execute="Not executed"
commit="Not committed"
ret_code=0

# get the path to the latest_log.txt file from the command line
batch_file_path=sys.argv[1]
sql=sys.argv[2]
#sql_orig="""INSERT INTO wsprdaemon_spots (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon)
#                          VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);"""
#
#print("sql:       ", sql,
#       "sql_orig: ", sql_orig)

try:
    with open (batch_file_path) as csv_file:
        csv_data = csv.reader(csv_file, delimiter=',')
        try:
               # connect to the PostgreSQL database
               #print ("Trying to  connect")
               conn = psycopg2.connect("dbname='tutorial' user='postgres' host='localhost' password='GW3ZIL'")
               connected="Connected"
               #print ("Appear to have connected")
               # create a new cursor
               cur = conn.cursor()
               cursor="Got cursor"
               # execute the INSERT statement
               psycopg2.extras.execute_batch(cur,sql,csv_data)
               execute="Executed"
               #print ("After the execute")
               # commit the changes to the database
               conn.commit()
               commit="Committed"
               # close communication with the database
               cur.close()
               #print (connected,cursor, execute,commit)
        except:
               print ("Unable to record spot file to the database:",connected,cursor, execute,commit)
               ret_code=1
finally:
        if conn is not None:
            conn.close()
        sys.exit(ret_code)
E
