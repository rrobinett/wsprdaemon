! /FREQUENCY/{++spots_count}; 
$10 == "*" {++q_missed_count}; 
$11 == "*" {++kiwi_missed_count}; 
#END {printf "%5d %5d (%4.2f%%%) %5d  (%4.2f%%%) \n", spots_count, q_missed_count, (q_missed_count/spots_count)*100, kiwi_missed_count, (kiwi_missed_count/spots_count)*100}
END {printf "%5d %5d (%4.2f%%) %5d (%4.2f%%)\n", spots_count, q_missed_count, (q_missed_count/spots_count)*100, kiwi_missed_count, (kiwi_missed_count/spots_count)*100 }
