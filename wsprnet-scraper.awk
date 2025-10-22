#!/bin/awk

### Filter and convert spots reported by the wsprnet.org API into a csv file which will be recorded in the CH database
###
### The calling command line is expected to define the awk variable spot_epoch:
###     awk -v spot_epoch=${spot_epoch} -f ${WSPRDAEMON_ROOT_DIR}/wsprnet-scraper.awk

BEGIN {
    FS = ","
    OFS = ","
    spot_minute = ( ( spot_epoch % 3600 ) / 60 )

    is_odd_minute = ( spot_minute % 2 )
    if ( is_odd_minute == 0 ) {
        fixed_spot_epoch = spot_epoch
    } else {
        fixed_spot_epoch = spot_epoch + 60 
    }

    print_diags = 0

    for ( i = 0; i < 60; i += 2  )  { valid_mode_1_minute[i]  = 1 }     ## WSPR-2 valid minutes
    for ( i = 0; i < 60; i += 2  )  { valid_mode_3_minute[i]  = 1 }     ## FST4W-120 valid minutes
    for ( i = 0; i < 60; i += 5 )   { valid_mode_4_minute[i]  = 1 }     ## FST4W-300 valid minutes
    for ( i = 0; i < 60; i += 15 )  { valid_mode_2_minute[i]  = 1 }     ## FST4W-900 valid minutes
    for ( i = 0; i < 60; i += 30 )  { valid_mode_8_minute[i]  = 1 }     ## FST4W-1800 valid minutes

    if ( valid_mode_1_minute[spot_minute] == 1 ) { is_valid_mode_1_minute = 1 }
    if ( valid_mode_3_minute[spot_minute] == 1 ) { is_valid_mode_3_minute = 1 }
    if ( valid_mode_4_minute[spot_minute] == 1 ) { is_valid_mode_4_minute = 1 }
    if ( valid_mode_2_minute[spot_minute] == 1 ) { is_valid_mode_2_minute = 1 }
    if ( valid_mode_8_minute[spot_minute] == 1 ) { is_valid_mode_8_minute = 1 }
}

$2 == spot_epoch {
    found_valid_mode = 1
    found_valid_minute = 1
    if ( $15 == 1 ) {
        spot_length = 2   ### Mode 1 spots (2 minute long WSPR) can happen only on even minutes
        if ( is_valid_mode_1_minute == 0 ) {
            found_valid_minute = 0
        } 
    } else if ( $15 == 3 ) {
        spot_length = 2   ### Mode 3 spots (2 minute long FST4W-120) can happen only on even minutes
        if ( is_valid_mode_3_minute == 0 ) {
            found_valid_minute = 0
        } 
   } else if ( $15 == 2 ) {
        spot_length = 15  ### Mode 2 spots (15 minute long WSPR and FST4W) can happen on both even and odd minutes
        if ( is_valid_mode_2_minute == 0 ) {
            found_valid_minute = 0
        }
   } else if ( $15 == 4 ) {
        spot_length = 5   ### Mode 4 spots (5 minute long FST4W) can happen on both even and odd minutes
        if ( is_valid_mode_4_minute == 0 ) {
            found_valid_minute = 0
       }
    } else if ( $15 == 8 ) {
        spot_length = 30   ### Mode 8 spots (30 minute long FST4W) can happen only on even minutes
        if ( is_valid_mode_8_minute == 0 ) {
            found_valid_minute = 0
       }
    } else {
       found_valid_mode = 0
    }

    if ( found_valid_mode == 1) {
        if ( found_valid_minute == 1) {
            print $0  # Just output the original 15 fields
        } else {
            ### Mode is valid, but minute is not valid
            if ( is_odd_minute == 0 ) {
                printf ("Found valid mode %2d == %2d minute long spot at invalid even minute %2d: %s\n", $15, spot_length, spot_minute, $0 )
                print $0
            } else {
                $2 = fixed_spot_epoch
                printf ("Found valid mode %2d == %2d minute long spot at invalid odd minute %2d and fixed epoch to %d: %s\n", $15, spot_length, spot_minute, fixed_spot_epoch, $0 )
                print $0
            }
        }
    } else {
       ### Mode is invalid, so always force to even minute
       if ( is_odd_minute == 0 ) {
            printf ("Found invalid mode %2d spot at even minute %2d: %s\n", $15, spot_minute, $0 )
            print $0
       } else {
           $2 = fixed_spot_epoch
            printf ("Found invalid mode %2d spot at odd minute %2d and fixed epoch to %d: %s\n", $15, spot_minute, fixed_spot_epoch, $0 )
            print $0
        }
    } 
}
