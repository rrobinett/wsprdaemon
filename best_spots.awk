#!/bin/awk
{
    spot_line = $0
    if ( $NF ~ /^[0-9]+$/ ) {
        ### The last column is an integer, so this spot line comes from the WSJT-x wsprd
        spot_line = spot_line "  9.999"
        this_spot_has_spreding_infomation = 0
    } else {
        this_spot_has_spreding_infomation = 1
    }
    spot_lines_with_this_call[$6]++
    if ( spot_lines_with_this_call[$6] == 1 ) {
        spot_lines_for_calls[$6] = spot_line
        spot_line_snr[$6]  = $3
        spot_line_has_spread[$6] = this_spot_has_spreding_infomation
    } else {
        if (    ( this_spot_has_spreding_infomation == 0  &&   spot_line_has_spread[$6] == 0 && $3 > spot_line_snr[$6] )  \
             || ( this_spot_has_spreding_infomation == 1  && ( spot_line_has_spread[$6] == 0 || $3 > spot_line_snr[$6])  ) )  {
            spot_lines_for_calls[$6] = spot_line
            spot_line_snr[$6]  = $3
            spot_line_has_spread[$6] = this_spot_has_spreding_infomation
        }
    }
}

END {
    for (spot_call in spot_lines_for_calls)
        printf "%s\n", spot_lines_for_calls[spot_call] 
}
