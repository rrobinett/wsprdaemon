#!/bin/bash
#
# 1/5/25 - RR This was written to compare the spot counts at N3AGE between WD server N#AGE-1 which used wd-record to write one minute 16 bit int wav files
#          and N3AGE-2 which used the new pcmrecord to record one minute wav files with 32 bit floating point samples
#          float samples resulted in 0.5-1.0% more spots being decoded

set -u

declare N1_LOG_FILENAME="n3age-1-wspr.log"
declare N2_LOG_FILENAME="/var/log/wspr.log"
declare SCRPAER_PID_FILE="scraper.pid"

function n1-scrape-dameon() {
   while true; do
       ssh elmer@n3age-1 "tail -F /var/log/wspr.log" >> ${N1_LOG_FILENAME} 2>&1
       echo "ERROR: ssh elmer@n3age-1 'tail -F /var/log/wspr.log' => $?.  sleep 5 and retry"
       sleep 5
   done
}

function spawn-n1-scrape-dameon() {

    local scraper_pid
    if [[ -f ${SCRPAER_PID_FILE} ]]; then
        scraper_pid=$(< ${SCRPAER_PID_FILE})
        if [[ -n "${scraper_pid}" ]]; then
            if ps a -o pid | grep ${scraper_pid} ; then
                echo "scraper is running and has PID=${scraper_pid}"
                return 0
            fi
        fi
    fi

    local rc
    n1-scrape-dameon >&  n1-scrape-dameon.log &
    rc=$?
    if (( rc != 0 )) ; then
        echo "ERROR: 'n1-scrape-dameon >&  n1-scrape-dameon.log &' => ${rc}"
        return ${rc}
    fi
    local scraper_pid=$!
    echo ${scraper_pid} > ${SCRPAER_PID_FILE}
    echo "Spawned n1-scrape-dameon() which has PID=${scraper_pid}"
}

function kill-n1-scrape-dameon() {
    local scraper_pid
    if [[ -f ${SCRPAER_PID_FILE} ]]; then
        echo "There is no ${SCRPAER_PID_FILE}"
    else
        scraper_pid=$(< ${SCRPAER_PID_FILE})
        if [[ -n "${scraper_pid}" ]]; then
            if ps a -o pid | grep ${scraper_pid} ; then
                kill ${scraper_pid}
                echo "Killed scraper running which had PID=${scraper_pid}"
            else
                echo "${SCRPAER_PID_FILE} exists and contains PID=${scraper_pid}, but that pid is not active"
            fi
        fi
        rm ${SCRPAER_PID_FILE} 
    fi
    return 0
}

function show-differences-between-servers-in-last-cycle() {
    local last_e1_spots
    local last_e2_spots

    local last_e1_cycle=$(awk 'END {printf "%s %s\n", $1, $2}' ${N1_LOG_FILENAME})
    local last_e2_cycle=$(awk 'END {printf "%s %s\n", $1, $2}' ${N2_LOG_FILENAME})
    local newest_common_cycle=${last_e1_cycle}
    if (( ${last_e2_cycle/ /} > ${last_e1_cycle/ /}  )); then
        newest_common_cycle=${last_e2_cycle}
    fi
    awk -v cycle="${newest_common_cycle}" '$0 ~ ("^" cycle) {printf "%s\n", $0}'  ${N1_LOG_FILENAME} | sort -k 6,7n > n1-spots.log
    awk -v cycle="${newest_common_cycle}" '$0 ~ ("^" cycle) {printf "%s\n", $0}'  ${N2_LOG_FILENAME} | sort -k 6,7n > n2-spots.log

    #comm -23 n1-spots.log  n2-spots.log > n1.only.log
    #comm -13 n1-spots.log  n2-spots.log > n2.only.log
    #comm -3  n1-spots.log  n2-spots.log >    both.log

    #echo "Last N3AGE-1 (using wd-record) cycle = ${last_e1_cycle}, Last N3AGE-2 (using pcmrecord)  cycle = ${last_e1_cycle}, so newest_common_cycle=${newest_common_cycle}"
    echo "In the last commong WSPR cycle ${last_e1_cycle}, N3AGE-1 (using pcmrecord) reported $(wc -l < n1-spots.log) spots and N3AGE-2 (using pcmrecord) reported $(wc -l < n2-spots.log) spots"
    ## [[ -s n1-only.log ]] && echo "Lines only in n1:$(<n1-only.log)"
    ## [[ -s n2-only.log ]] && echo "Lines only in n2:$(<n2-only.log)"
    ## [[ -s both.log    ]] && echo "All lines which differ:$(<both.log)"
}

function get_all_sample_times() {
    local n1_times_list=( $(awk '/^2/{printf "%s%s\n", $1, $2}'  ${N1_LOG_FILENAME} | sort -n | uniq) )
    local n2_times_list=( $(awk '/^2/{printf "%s%s\n", $1, $2}'  ${N2_LOG_FILENAME} | sort -n | uniq) )
    local combined_list=( "${n1_times_list[@]}" "${n2_times_list[@]}")
    local sorted_uniq_list=( $(printf "%s\n" "${combined_list[@]}" | sort -rn | uniq) )
    echo "Found ${#n1_times_list[@]} dates in N1, ${#n1_times_list[@]} dates in N2, and ${#sorted_uniq_list[@]} date are in the union of those times"

    printf "%9s: %8s %8s\n" "YYMMDD HHMM" "wd-record" "pcmrecord"
    local cycles_count=0
    local wd_record_spots_count=0
    local pcmrecord_spots_count=0
    local pause_printout=${1-10}
    local datetime 
    for datetime in ${sorted_uniq_list[@]}; do
        local date_time="${datetime:0:6} ${datetime:6}"
        local n1_spots=$(grep "${date_time}"  ${N1_LOG_FILENAME} | wc -l)
        local n2_spots=$(grep "${date_time}"  ${N2_LOG_FILENAME} | wc -l)
        printf "%11s:  %8s  %8s\n" "${date_time}" "${n1_spots}"  "${n2_spots}"
        (( wd_record_spots_count += n1_spots))
        (( pcmrecord_spots_count += n2_spots ))
        local percent_diff=$(bc <<< " scale=0; diff=${pcmrecord_spots_count} - ${wd_record_spots_count}; scale=10; ratio=(diff / ${wd_record_spots_count}); scale=2; result=(ratio * 100); result/1")
        if (( --pause_printout == 0 )); then
            printf  "%11s:  %8s  %8s (%s%%)"  "Totals"  "${wd_record_spots_count}" "${pcmrecord_spots_count}" "${percent_diff}"
            read -p "         Continue? => "
            pause_printout=${1-10}
        fi
    done
}


function wd-spot-differences() {
while getopts "azst" opt; do
    case ${opt} in
        a)
            spawn-n1-scrape-dameon
            ;;
        z)
            kill-n1-scrape-dameon
            ;;
        s)
            show-differences-between-servers-in-last-cycle
            ;;
        t)
            get_all_sample_times
            ;;
        *)
            echo "ERROR: option '${opt}' is not valid"
            ;;
    esac
done
}

wd-spot-differences $@

