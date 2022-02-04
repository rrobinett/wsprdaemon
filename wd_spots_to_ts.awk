#!/bin/awk

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
            printf ("ERROR: found unexpected 'pkt_mode' value '%s' instead of the expected value '0' in spot file %s spot line: '%s'\n", fields[18], FILENAME, $0 )
        }
        fields[++field_count] = 0                      ### i'ov_count' :     There is no overload counts information in WD 2.x spot lines
        fields[++field_count] = 0                      ### 'wsprnet_info' :  This field may be used in WD 3.0 to signal that the server should 'proxy upload' this spot to wsprnet.org
    }
    ### Create the spot time in the TS format:  "20YY-MM-DD:HH:MM"
    wd_year  = substr(fields[1], 1, 2)
    wd_month = substr(fields[1], 3, 2)
    wd_day   = substr(fields[1], 5, 2)
    wd_hour  = substr(fields[2], 1, 2)
    wd_min   = substr(fields[2], 3, 2)
    ts_time  = ( "20" wd_year "-" wd_month "-" wd_day ":" wd_hour ":" wd_min )
    printf( "%d: \"%s\"", NF, ts_time )

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
