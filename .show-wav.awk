#!/bin/awk

/Bit-depth/{ 
    split(FILENAME, path, "/")
    rx_name = path[5]
    rx_band= path[6]
    split($0, line, ": ")
    date = line[1]
    message = line[2]
    printf "%12s %4sM: %s %s %s %s\n", rx_name, rx_band, date, message, line[3], line[4]
}
