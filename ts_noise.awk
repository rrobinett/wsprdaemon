NF == 15 {
    n = split(FILENAME, path_array, /\//)

    call_grid = path_array[n-3]
    receiver  = path_array[n-2]
    band      = path_array[n-1]
    time_freq = path_array[n]

    split(call_grid, call_grid_array, "_")
    site = call_grid_array[1]
    gsub(/=/, "/", site)
    rx_loc = call_grid_array[2]

    split(time_freq, time_freq_array, "_")
    date = time_freq_array[1]
    time = time_freq_array[2]
    gsub(/_noise\.txt$/, "", time)

    split(date, d, "")
    date_str = "20"d[1]d[2]"-"d[3]d[4]"-"d[5]d[6]

    split(time, t, "")
    time_str = t[1]t[2]":"t[3]t[4]":00"

    timestamp = date_str " " time_str

    rms_level = $13
    c2_level  = $14
    ov        = $15

    # Output in correct column order for INSERT
    printf "%s,%s,%s,%s,%s,%s,%s,%s\n", timestamp, site, receiver, rx_loc, band, rms_level, c2_level, ov
}
