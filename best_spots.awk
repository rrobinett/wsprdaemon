#!/bin/awk
# 11/19/23 RR
# This code reads an ALL_WSPR.TXT format file and outputs spot lines which contain only one instance of each call sign
# while choosing the best spots with spreading infomation in the last column 
# spots which are reported only with no spreading information are reported with spreding of 9.999 hz
# Since the WSJT-x WSPR-2 decoder 'wsprd' includes drift compensation, it may report some spots which are not reported 
# by Ryan's enhaned wsprd decoder which has drift compensation disabled so that the spreading values it reports are meaningful
#
{
    spot_line = $0
    if ( $NF ~ /^[0-9\-]+$/ ) {
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
        if (    ( this_spot_has_spreding_infomation == spot_line_has_spread[$6] && $3 > spot_line_snr[$6] )  \
             || ( this_spot_has_spreding_infomation == 1  && spot_line_has_spread[$6] == 0 ) )  {
            # If there are two spots both with the sane speading information from the same call, then choose the one with better SNR
            # And always choose spots with spreading over those without spreading
            spot_lines_for_calls[$6] = spot_line
            spot_line_snr[$6]  = $3
            spot_line_has_spread[$6] = this_spot_has_spreding_infomation
        }
    }
}

### Pipe the output through 'sort -k 5,5n' to get a nicely ascending frequency output file
END {
    for (spot_call in spot_lines_for_calls)
        printf "%s\n", spot_lines_for_calls[spot_call] 
}
