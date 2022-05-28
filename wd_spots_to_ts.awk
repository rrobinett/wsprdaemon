#!/bin/awk

BEGIN {
    ts_2_10_fields_count = split (  "date time sync_quality snr dt freq call grid pwr drift decode_cycles jitter blocksize metric osd_decode ipass nhardmin for_wsprnet rms_noise c2_noise band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon",  ts_2_10_field_names, " ")
    ts_3_0_fields_count = split (  "date time sync_quality snr dt freq call grid pwr drift decode_cycles jitter blocksize metric osd_decode ipass nhardmin for_wsprnet rms_noise c2_noise band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon overload_counts  pkt_mode",  ts_3_0_field_names, " ")
}

function print_spot_line_fields (spot_line) {
    spot_line_count = split( spot_line, spot_line_array, " ")
    if ( spot_line_count == ts_2_10_fields_count ) {
        for ( i = 1; i <= ts_2_10_fields_count; ++ i ) {
            printf ( "#%2d: %15s: %s\n", i, ts_2_10_field_names[i], spot_line_array[i] )
        }
        return
    }
    if ( spot_line_count == ts_3_0_fields_count ) {
        for ( i = 1; i <= ts_3_0_fields_count; ++ i ) {
            printf ( "#%2d: %15s: %s\n", i, ts_3_0_field_names[i], spot_line_array[i] )
        }
        return
    }
    printf ( "ERROR: spot line has %d fields, not the expected %d fields: '%s'\n", spot_line_count, ts_2_10_fields_count, spot_line)
    return
}

### Process 32 filed WD 2.x spot lines and 34 field WD 3.0 spot lines into the CSV line format expected by TS

NF != 32 && NF != 34 {
    printf( "ERROR: file %s spot line has %d fields, not the expected 32 or 34 fields: '%s\n'", FILENAME, NF, $0)
}

NF == 32 || NF == 34 {
    field_count = split($0, fields, " ")
    if ( NF == 32 ) {
        if ( fields[18] == 0 ) {
            fields[18] = 2           ### In WD 2.x this field was a placeholder and always set to zero.  Set is to the value for 'WSPR-2' pkt mode, since that is the only pkt mode decoded by WD 2.x
        } else {
            ### In 2.10 some or all of the type 2 spots were incorrectly formatted where tx 'grid' was 'none', the next field 'tpwr' held that grid, and the following fields were similarly off by one
            ### This code attempts to detect and clean up such malformed lines
            if ( verbosity > 1 ) print_spot_line_fields($0)
            if ( verbosity > 0 ) printf ("ERROR: found unexpected 'pkt_mode' value '%s' instead of the expected value '0' in spot file %s spot line:\n%s\n", fields[18], FILENAME, $0 )
            for ( i = 8; i <= 19; ++i ) {
               if ( verbosity > 1 ) printf ("Move field #%2d (%s) to field #%2d\n", i+1, fields[i+1], i) 
               fields[i] = fields[i+1]
           }
           ### In 2.10 the RMS noise field is lost and C2_noise may contain RMS or C2 data.  So make both noise levels the same
           fields[18] = 2    ### In 2.10 this field was 'for_wsprnet' but in 3.0 is is 'pkt_mode' and all 2.10 spots are WSPR-2
        }
        fields[++field_count] = 0                      ### 'ov_count' :     There is no overload counts information in WD 2.x spot lines
        fields[++field_count] = 0                      ### 'wsprnet_info' :  This field may be used in WD 3.0 to signal that the server should 'proxy upload' this spot to wsprnet.org

        if ( fields[9] != int(fields[9]) ) {
            ### Some older versions of WD produce corrupt lines.  Don't record them
            printf ("ERROR: ")
        }
    }
    ### Create the spot time in the TS format:  "20YY-MM-DD:HH:MM"
    wd_year  = substr(fields[1], 1, 2)
    wd_month = substr(fields[1], 3, 2)
    wd_day   = substr(fields[1], 5, 2)
    wd_hour  = substr(fields[2], 1, 2)
    wd_min   = substr(fields[2], 3, 2)
    ts_time  = ( "20" wd_year "-" wd_month "-" wd_day ":" wd_hour ":" wd_min )

    fields[3] = int ( fields[3] * 100 )       ### ALL_WSPR.TXT reports sync_quality as a float (0.NN), but we have defined that sync field as a int in TS

    printf( "\"%s\"", ts_time )

    fields[7]  = toupper(fields[7])
    fields[8]  = ( toupper(substr(fields[8], 1, 2)) substr(fields[8], 3, 2) tolower(substr(fields[8], 5, 2)) )
    fields[23] = toupper(fields[23])
    fields[22] = ( toupper(substr(fields[22], 1, 2)) substr(fields[22], 3, 2) tolower(substr(fields[22], 5, 2)) )

    file_path_count = split ( FILENAME, file_path_array, "/" )
    rx_name = file_path_array[ file_path_count - 2]
    fields[++field_count] = rx_name                ### Taken from path to the file which contains this spot line

    for ( i = 3; i <= field_count; ++ i) {
        printf ( ",%s",  fields[i])
    }
    printf "\n"
}
