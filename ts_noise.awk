NF == 15 {
    no_head=FILENAME

    n = split (FILENAME, path_array, /\//)
    call_grid=path_array[n-3]

    split (call_grid, call_grid_array, "_")
    site=call_grid_array[1]
    gsub(/=/,"/",site)
    rx_grid=call_grid_array[2]

    receiver=path_array[n-2]
    band=path_array[n-1]
    time_freq=path_array[n]

    split (time_freq, time_freq_array, "_")
    date=time_freq_array[1]
    split (date,date_array,"")
    date_ts="20"date_array[1]date_array[2]"-"date_array[3]date_array[4]"-"date_array[5]date_array[6]
    time=time_freq_array[2]
    split (time, time_array,"")
    time_ts=time_array[1]time_array[2]":"time_array[3]time_array[4]

    rms_level=$13
    c2_level=$14
    ov=$15
    #printf "time='%s:%s' \nsite='%s' \nreceiver='%s' \nrx_grid='%s' \nband='%s' \nrms_level:'%s' \nc2_level:'%s' \nov='%s'\n", date_ts, time_ts, site, receiver, rx_grid, band, rms_level, c2_level, ov
    printf "%s:%s,%s,%s,%s,%s,%s,%s,%s\n", date_ts, time_ts, site, receiver, rx_grid, band, rms_level, c2_level, ov
}
