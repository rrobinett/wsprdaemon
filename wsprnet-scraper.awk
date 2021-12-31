#!/bin/awk

### The calling command line is expected to define two awk variables:  spot_epoch

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
    fixed_date = strftime( "%Y-%m-%d:%H:%M", fixed_spot_epoch )
    print_diags = 0
    if ( is_odd_minute == 0 ) {
        if ( print_diags == 1 ) {
            printf ( "Finding spots with epoch %d which is at even minute %d == '%s'\n", spot_epoch, spot_minute, fixed_date)
        }
    } else {
        printf ( "Finding spots with epoch %d which is at odd minute %d and if mode is invalid change the spot to the next even minute epoch %d == '%s'\n", spot_epoch, spot_minute, fixed_spot_epoch, fixed_date)
    }
    for ( i = 0; i < 60; i += 2  )  { valid_mode_1_minute[i]  = 1 }
    for ( i = 0; i < 60; i += 15 )  { valid_mode_2_minute[i]  = 1 }
    for ( i = 0; i < 60; i += 5 )   { valid_mode_4_minute[i]  = 1 }
    for ( i = 0; i < 60; i += 30 )  { valid_mode_8_minute[i]  = 1 }

    if ( valid_mode_1_minute[spot_minute] == 1 ) { is_valid_mode_1_minute = 1 }
    if ( valid_mode_2_minute[spot_minute] == 1 ) { is_valid_mode_2_minute = 1 }
    if ( valid_mode_4_minute[spot_minute] == 1 ) { is_valid_mode_4_minute = 1 }
    if ( valid_mode_8_minute[spot_minute] == 1 ) { is_valid_mode_8_minute = 1 }
}

$2 == spot_epoch {
    found_valid_mode = 1
    spot_minute_validity = "valid"
    if ( $15 == 1 ) {
        spot_length = 2   ### Mode 1 spots (2 minute long WSPR and FST4W) can happen only on even minutes
        if ( is_valid_mode_1_minute == 0 ) {
            spot_minute_validity = "invalid"
        } 
   } else if ( $15 == 2 ) {
        spot_length = 15  ### Mode 2 spots (15 minute long WSPR and FST4W) can happen on both even and odd minutes
        if ( is_valid_mode_2_minute == 0 ) {
            spot_minute_validity = "invalid"
        }
   } else if ( $15 == 4 ) {
        spot_length = 5   ### Mode 4 spots (5 minute long FST4W) can happen on both even and odd minutes
        if ( is_valid_mode_4_minute == 0 ) {
            spot_minute_validity = "invalid"
       }
    } else if ( $15 == 8 ) {
        spot_length = 30   ### Mode 8 spots (30 minute long FST4W) can happen only on even minutess
        if ( is_valid_mode_8_minute == 0 ) {
            spot_minute_validity = "invalid"
       }
    } else {
       printf ("Found invalid mode %d spot of unknown length at minute %d: %s\n", $15, spot_minute, $0 )
       found_valid_mode = 0
   }
    ### To mimic the wsprnet.org servers, we are always forcing spots to even minutes
    $2 = fixed_spot_epoch
    printf ( "%s,%s\n", fixed_date, $0 )

    if ( (found_valid_mode == 1) && ( spot_minute_validity == "invalid" ) ){
       printf ("Found valid mode %2d == %2d minute long spot at invalid minute %2d", $15, spot_length, spot_minute )
       if ( spot_epoch != fixed_spot_epoch ) {
           printf (" and fixed it to")
        }
       printf (" %d '%s': %s\n", fixed_spot_epoch, fixed_date, $0 )
   }
 }  

