#!/bin/awk

function abs(x){
    return ((x < 0.0) ? -x : x)
}

BEGIN {
    error_level = 0.90
    rec_length_secs_max=120.10
    rec_length_secs_min=119.90
}

/Bit-depth/{ 
    split(FILENAME, path, "/")
    rx_name = path[5]
    rx_band = path[6]
    split($0, line, "UTC: ")
    date = line[1]
    sox_stats = line[2]
    split(sox_stats, sox_values)
    min_val = sox_values[15] 
    gsub( "min=", "", min_val )
    gsub( ",", "", min_val )
    max_val = sox_values[16] 
    gsub( "max=", "", max_val )
    gsub( ",", "", max_val )
    rec_length = sox_values[6]
    rec_length_secs = rec_length
    gsub(/.*=/, "", rec_length_secs)
    bit_depth = sox_values[10]
    gsub( ":", "", bit_depth)
    min_string = sox_values[15]
    gsub( ",", "", min_string)
    max_string = sox_values[16]
    found_overload = "OV=0"
    if (abs(min_val) > error_level) found_overload = "OV=1"
    if (    max_val  > error_level) found_overload = "OV=1"
    length_error = "LEN=0"
    if ( (rec_length_secs > rec_length_secs_max) || (rec_length_secs < rec_length_secs_min) ) length_error = "LEN=1"
    printf "%12s %4sM: %sUTC: %s %-15s %s %s %s %s\n", rx_name, rx_band, date, rec_length, bit_depth, min_string, max_string, found_overload, length_error
}
