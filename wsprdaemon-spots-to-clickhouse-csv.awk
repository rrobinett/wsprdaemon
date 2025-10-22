#!/bin/awk -f

BEGIN {
    FS=" "
    OFS=""
}

# Function to extract receiver name from file path
function get_rx_name(filename) {
    n = split(filename, parts, "/")
    return parts[n-2]
}

# Skip lines with insufficient fields
NF < 34 { next }

{
    # Field mapping from wsprdaemon extended spot format:
    # 1:spot_date 2:spot_time 3:spot_sync_quality 4:spot_snr 5:spot_dt 
    # 6:spot_freq 7:spot_call 8:spot_grid 9:spot_pwr 10:spot_drift
    # 11:spot_cycles 12:spot_jitter 13:spot_blocksize 14:spot_metric 
    # 15:spot_decodetype 16:spot_ipass 17:spot_nhardmin 18:spot_pkt_mode
    # 19:wspr_cycle_rms_noise 20:wspr_cycle_fft_noise 21:band 
    # 22:real_receiver_grid 23:real_receiver_call_sign 24:km 
    # 25:rx_az 26:rx_lat 27:rx_lon 28:tx_az 29:tx_lat 30:tx_lon 
    # 31:v_lat 32:v_lon 33:wspr_cycle_kiwi_overloads_count 
    # 34:proxy_upload_this_spot

    # --- generate ClickHouse timestamp ---
    yy = substr($1,1,2)
    mm = substr($1,3,2)
    dd = substr($1,5,2)
    hh = substr($2,1,2)
    min = substr($2,3,2)
    clickhouse_time = "20" yy "-" mm "-" dd " " hh ":" min ":00"

    # --- numeric conversions ---
    band          = $21+0      # band
    freq          = $6+0       # spot_freq
    snr           = $4+0       # spot_snr
    c2_noise      = $20+0      # wspr_cycle_fft_noise
    drift         = $10+0      # spot_drift (field 10, not 5!)
    decode_cycles = $11+0      # spot_cycles
    jitter        = $12+0      # spot_jitter
    blocksize     = $13+0      # spot_blocksize
    metric        = $14+0      # spot_metric
    osd_decode    = $15+0      # spot_decodetype
    ipass         = $16+0      # spot_ipass
    nhardmin      = $17+0      # spot_nhardmin
    rms_noise     = $19+0      # wspr_cycle_rms_noise
    km            = $24+0      # km
    rx_az         = $25+0      # rx_az
    rx_lat        = $26+0      # rx_lat
    rx_lon        = $27+0      # rx_lon
    tx_az         = $28+0      # tx_az
    tx_dBm        = $9+0       # spot_pwr
    tx_lat        = $29+0      # tx_lat
    tx_lon        = $30+0      # tx_lon
    v_lat         = $31+0      # v_lat
    v_lon         = $32+0      # v_lon
    dt            = $5+0       # spot_dt
    
    # sync_quality - convert to integer percentage
    sync_quality  = int($3)    # spot_sync_quality (already 0-100 range)

    # --- ClickHouse-only fields ---
    proxy_upload  = $34+0      # proxy_upload_this_spot
    mode          = $18+0      # spot_pkt_mode
    ov_count      = $33+0      # wspr_cycle_kiwi_overloads_count

    # --- string fields ---
    rx_grid   = $22        # real_receiver_grid
    rx_id     = get_rx_name(FILENAME)
    tx_call   = $7         # spot_call
    tx_grid   = $8         # spot_grid
    receiver  = $23        # real_receiver_call_sign
    rx_status = "No Info"

    # --- print CSV line matching ClickHouse schema order ---
    printf("\"%s\",%d,%s,%s,%s,%s,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%d,%d,%.3f,%d,%d,%d,%s,%d,%d,%d,%d,%d,%s\n",
    clickhouse_time,
    band,
    rx_grid,
    rx_id,
    tx_call,
    tx_grid,
    snr,
    c2_noise,
    drift,
    freq,
    km,
    rx_az,
    rx_lat,
    rx_lon,
    tx_az,
    tx_dBm,
    tx_lat,
    tx_lon,
    v_lat,
    v_lon,
    sync_quality,
    dt,
    decode_cycles,
    jitter,
    rms_noise,
    blocksize,
    metric,
    osd_decode,
    receiver,
    nhardmin,
    ipass,
    proxy_upload,
    mode,
    ov_count,
    rx_status)
}
