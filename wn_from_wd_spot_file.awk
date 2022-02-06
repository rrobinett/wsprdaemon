#!/bin/awk

### This awk script takes a file of 34 field WD extended spot lines and output 11 field wsprnet batch upload spot lines
### Doing that requries moving the 'sync_quality' to field 3 and transforming the 'pkt_mode' field in field $18 of extended spots to a subset in field 11 of the WN spot line

NF != 34 {
    printf ("ERROR: WD spot file %s has %d fields instead of the expected 34 fields\n", FILENAME, NF )
}
NF == 34 {
    if ( $8 == "none" ) {
        $8 = "      "
    }
    wd_pkt_mode = $18
    if ( wd_pkt_mode == 2 )      
        wn_pkt_mode = 2               ### WSPR-2
    else if ( wd_pkt_mode == 15 )             
        wn_pkt_mode = 2               ### WSPR-15
    else if (  wd_pkt_mode == 3 )             
        wn_pkt_mode = 2               ### FST4W-120
    else if (  wd_pkt_mode == 5 )             
        wn_pkt_mode = 5               ### FST4W-300
    else if (  wd_pkt_mode == 16 )             
        wn_pkt_mode =15               ### FST4W-900
    else if (  wd_pkt_mode == 30 )
        wn_pkt_mode = 30              ### FST4W-1800
    else {
        wn_pkt_mod= 2
        printf ("ERROR: WD spot line has pkt_mode = '%s', not one of the expected 2/3/5/15/16/30 values: ", wd_pkt_mode)
    }
    printf ( "%6s %4s %3.2f %3d %5.2f %12.7f %-14s %-6s %2d %2d %4d\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, wn_pkt_mode)
}
