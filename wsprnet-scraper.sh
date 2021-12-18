#!/bin/bash

# Version 0.2  Add mutex 
# Version 0.3  upload to TIMESCALE rather than keeping in local log file and azimuths at tx and rx in that order added, km only, no miles
# Version 0.4  add_azi vertex corrected, use GG suggested fields and tags, add Band as a tag and add placeholder for c2_noise from WD users with absent data for now
# Version 0.5  GG using Droplet this acount for testing screening of tx_calls against list of first two characters
# Version 0.6  GG First version to upload to a Timescale database rather than Influx
# Version 0.7  RR shorten poll loop to 30 seconds.  Don't try to truncate the daemon.log file
# Version 0.8  RR spawn a daemon to FTP clean scrape files to logs1.wsprdaemon.org
# Version 0.9  RR Optionally use ~/ftp_uploads/* as source for new scrapes rather than going to wsprnet.org
# Version 1.0  RR Optionally use API interface to get new spots from wsprnet.org and populate the TS database 'wsprnet' table 'spots'

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

declare VERSION=1.1

export TZ=UTC LC_TIME=POSIX          ### Ensures that log dates will be in UTC

declare WSPRNET_SCRAPER_HOME_PATH=/home/scraper/wsprnet-scraper

### Get these TS_... values from the conf file
declare TS_USER=""
declare TS_PASSWORD=""
declare TS_DB=""

declare UPLOAD_MODE="API"            ## Either 
declare UPLOAD_TO_WD1="no"

### Get the Wsprnet login info from the conf file
declare WSPRNET_USER=""
declare WSPRNET_PASSWORD=""

declare WSPR_SCRAPER_CONF_FILE="./wsprnet-scraper.conf"

if [[ ! -f ${WSPR_SCRAPER_CONF_FILE} ]]; then
    echo "ERROR: can't open '${WSPR_SCRAPER_CONF_FILE}'"
    exit 1
fi

source ${WSPR_SCRAPER_CONF_FILE}

if [[ -z "${WSPRNET_USER}" || -z "${WSPRNET_PASSWORD}" || -z "${TS_USER}" || -z "${TS_PASSWORD}" || -z "${TS_DB}" ]]; then
    echo "ERROR: '${WSPR_SCRAPER_CONF_FILE}' doesn't contain lines which declare one or more of the expected variables"
    exit 1
fi

#############################################
declare -i verbosity=${v:-0}         ### default to level 0, but can be overridden on the cmd line.  e.g "v=2 wsprdaemon.sh -V"

function verbosity_increment() {
    verbosity=$(( $verbosity + 1))
    echo "$(date): verbosity_increment() verbosity now = ${verbosity}"
}
function verbosity_decrement() {
    [[ ${verbosity} -gt 0 ]] && verbosity=$(( $verbosity - 1))
    echo "$(date): verbosity_decrement() verbosity now = ${verbosity}"
}

function setup_verbosity_traps() {
    trap verbosity_increment SIGUSR1
    trap verbosity_decrement SIGUSR2
}

function signal_verbosity() {
    local up_down=$1
    local pid_files=$(shopt -s nullglob ; echo ${WSPRNET_SCRAPER_HOME_PATH}/*.pid)

    if [[ -z "${pid_files}" ]]; then
        echo "No *.pid files in ${WSPRNET_SCRAPER_HOME_PATH}"
        return
    fi
    local file
    for file in ${pid_files} ; do
        local debug_pid=$(cat ${file})
        if ! ps ${debug_pid} > /dev/null ; then
            echo "PID ${debug_pid} from ${file} is not running"
        else
            echo "Signaling verbosity change to PID ${debug_pid} from ${file}"
            kill -SIGUSR${up_down} ${debug_pid}
        fi
    done
}

### executed by cmd line '-d'
function increment_verbosity() {
    signal_verbosity 1
}
### executed by cmd line '-D'
function decrement_verbosity() {
    signal_verbosity 2
}

######################### Uploading to WD1 section ############################
declare UPLOAD_QUEUE_DIR=${WSPRNET_SCRAPER_HOME_PATH}/upload.d    ### On the WD server which is scraping wsprnet.org, this is where it puts parsed scrape files for upload to WD1

function upload_to_wd1_daemon() {
    local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-uploader}
    local upload_password=${SIGNAL_LEVEL_FTP_PASSWORD-xahFie6g}

    mkdir -p ${UPLOAD_QUEUE_DIR}
    cd ${UPLOAD_QUEUE_DIR}
    shopt -s nullglob
    while true; do
        [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_wd1_daemon() looking for files to upload"
        local file_list=()
        while file_list=( * ) && [[ ${#file_list[@]} -gt 0 ]]; do
            [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_wd1_daemon() found files '${file_list[@]}' to upload"
            local file
            for file in ${file_list[@]}; do
                local upload_url=${SIGNAL_LEVEL_FTP_URL-logs1.wsprdaemon.org}/${file}
                [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_wd1_daemon() uploading file '${file}'"
                curl -s -m 30 -T ${file}  --user ${upload_user}:${upload_password} ftp://${upload_url}
                local ret_code=$?
                if [[ ${ret_code} -eq 0 ]]; then
                    [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_wd1_daemon() upload of file '${file}' was successful"
                    rm ${file}
                else
                    [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_wd1_daemon() upload of file '${file}' failed.  curl => ${ret_code}"
                fi
            done
        done
        sleep 10
    done
}

function queue_upload_to_wd1() {
    local scrapes_to_add_file=$1

    mkdir -p ${UPLOAD_QUEUE_DIR}
    local epoch=$(date +%s)
    local upload_file_name="${scrapes_to_add_file%_*}_${epoch}.txt"
    while [[ -f ${upload_file_name} ]]; do
        [[ $verbosity -ge 1 ]] && echo "$(date): queue_upload_to_wd1() queued file '${UPLOAD_QUEUE_DIR}/${upload_file_name}' exists, Sleep 1 second and try again"
        sleep 1
        epoch=$(date +%s)
        upload_file_name="${scrapes_to_add_file%_*}_${epoch}.txt"
    done
    cp -p ${scrapes_to_add_file} ${UPLOAD_QUEUE_DIR}/${upload_file_name}
    bzip2 ${UPLOAD_QUEUE_DIR}/${upload_file_name}
    [[ $verbosity -ge 2 ]] && echo "$(date): queue_upload_to_wd1() queued ${scrapes_to_add_file} bzipped as ${UPLOAD_QUEUE_DIR}/${upload_file_name}.bz2"
}

################### API scrape section ##########################################################

declare UPLOAD_WN_BATCH_PYTHON_CMD=${WSPRNET_SCRAPER_HOME_PATH}/ts_upload_batch.py
declare UPLOAD_SPOT_SQL='INSERT INTO spots (wd_time, "Spotnum", "Date", "Reporter", "ReporterGrid", "dB", "MHz", "CallSign", "Grid", "Power", "Drift", distance, azimuth, "Band", version, code, 
    wd_band, wd_c2_noise, wd_rms_noise, wd_rx_az, wd_rx_lat, wd_rx_lon, wd_tx_az, wd_tx_lat, wd_tx_lon, wd_v_lat, wd_v_lon ) 
    VALUES( %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s );'

function wn_spots_batch_upload() {
    local csv_file=$1

    [[ $verbosity -ge 2 ]] && echo "$(date): wn_spots_batch_upload() record ${csv_file} to TS"
    if [[ ! -f ${UPLOAD_WN_BATCH_PYTHON_CMD} ]]; then
        create_wn_spots_batch_upload_python
    fi
    python3 ${UPLOAD_WN_BATCH_PYTHON_CMD} --input ${csv_file} --sql insert-spots.sql --address localhost --database ${TS_DB} --username ${TS_USER} --password ${TS_PASSWORD}  # "${UPLOAD_SPOT_SQL}" "${UPLOAD_WN_BATCH_TS_CONNECT_INFO}"
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): wn_spots_batch_upload() UPLOAD_WN_BATCH_PYTHON_CMD => ${ret_code}"
    fi
    [[ $verbosity -ge 2 ]] && echo "$(date): wn_spots_batch_upload() record ${csv_file} => ${ret_code}"
    return ${ret_code}
}


declare WSPRNET_SESSION_ID_FILE=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_session_info.html

function wpsrnet_login() {
    [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_login() executing curl to login"
    timeout 60 curl -s -d '{"name":"'${WSPRNET_USER}'", "pass":"'${WSPRNET_PASSWORD}'"}' -H "Content-Type: application/json" -X POST http://www.wsprnet.org/drupal/rest/user/login > ${WSPRNET_SESSION_ID_FILE}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        local sessid=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/sessid/s/^.*://p' | sed 's/"//g')
        local session_name=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/session_name/s/^.*://p' | sed 's/"//g')
        if [[ -z "${sessid}" ]] || [[ -z "${session_name}" ]]; then
            [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_login()  failed to extract sessid=${sessid} and/or session_name${session_name}"
            rm -f ${WSPRNET_SESSION_ID_FILE}
            ret_code=2
        else
            [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_login() login was successful"
        fi
    else
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_login()  curl login failed => ${ret_code}"
        rm -f ${WSPRNET_SESSION_ID_FILE}
   fi
    return ${ret_code}
}

declare WSPRNET_HTML_SPOT_FILE=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_spots.html
declare WSPRNET_LAST_SPOTNUM=0

function wpsrnet_get_spots() {
    [[ ${verbosity} -ge 2 ]] && echo "$(date): wpsrnet_get_spots() starting"
    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]] || [[ ! -s ${WSPRNET_SESSION_ID_FILE} ]]; then
       if ! wpsrnet_login ; then
           [[ ${verbosity} -ge 2 ]] && echo "$(date): wpsrnet_get_spots() failed to login"
           return 1
       fi
    fi
    local sessid=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/sessid/s/^.*://p' | sed 's/"//g')
    local session_name=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/session_name/s/^.*://p' | sed 's/"//g')
    if [[ -z "${sessid}" ]] || [[ -z "${session_name}" ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots(): wpsrnet_login() failed to extract sessid=${sessid} and/or session_name${session_name}"
        rm -f ${WSPRNET_SESSION_ID_FILE}
        ret_code=2
    fi
    local session_token="${session_name}=${sessid}"
    [[ ${verbosity} -ge 2 ]] && echo "$(date): wpsrnet_get_spots(): got wsprnet session_token = ${session_token}"
 
    if [[ ${WSPRNET_LAST_SPOTNUM} -eq 0 ]]; then
        ### Get the largest Spotnum from the TS DB
        ### I need to redirect the output to a file or the psql return code gets lost
        local psql_output_file=./psql.out
        PGPASSWORD=${TS_PASSWORD}  psql -t -U ${TS_USER} -d ${TS_DB}  -c 'select "Spotnum" from spots order by "Spotnum" desc limit 1 ;' > ${psql_output_file}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots(): psql( ${TS_USER}/${TS_PASSWORD}/${TS_DB}) for latest TS returned error => ${ret_code}"
            exit 1
        fi
        local psql_output=$(cat ${psql_output_file})
        local last_spotnum=$(tr -d ' ' <<< "${psql_output}")
        if [[ -z "${last_spotnum}" ]] || [[ ${last_spotnum} -eq 0 ]]; then
            [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots(): at startup failed to get a Spotnum from TS"
            exit 1
        fi
        WSPRNET_LAST_SPOTNUM=${last_spotnum}
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots(): at startup using highest Spotnum ${last_spotnum} from TS, not 0"
    fi
    [[ ${verbosity} -ge 2 ]] && echo "$(date): wpsrnet_get_spots() starting curl download for spotnum_start=${WSPRNET_LAST_SPOTNUM}"
    local start_seconds=${SECONDS}
    local curl_str="'{spotnum_start:\"${WSPRNET_LAST_SPOTNUM}\",band:\"All\",callsign:\"\",reporter:\"\",exclude_special:\"1\"}'"
    curl -s -m ${WSPRNET_CURL_TIMEOUT-120} -b "${session_token}" -H "Content-Type: application/json" -X POST -d ${curl_str}  "http://www.wsprnet.org/drupal/wsprnet/spots/json?band=All&spotnum_start=${WSPRNET_LAST_SPOTNUM}&exclude_special=0" > ${WSPRNET_HTML_SPOT_FILE}
    local ret_code=$?
    local end_seconds=${SECONDS}
    local curl_seconds=$(( end_seconds - start_seconds))
    if [[ ${ret_code} -ne 0 ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots() curl download failed => ${ret_code} after ${curl_seconds} seconds"
    else
        if grep -q "You are not authorized to access this page." ${WSPRNET_HTML_SPOT_FILE}; then
            [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots() wsprnet.org login failed"
            rm ${WSPRNET_SESSION_ID_FILE}
            ret_code=1
        else
            if ! grep -q "Spotnum" ${WSPRNET_HTML_SPOT_FILE} ; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): wpsrnet_get_spots() WARNING: ${WSPRNET_HTML_SPOT_FILE} contains no spots"
                ret_code=2
            else
                local download_size=$( cat ${WSPRNET_HTML_SPOT_FILE} | wc -c)
                [[ ${verbosity} -ge 2 ]] && echo "$(date): wpsrnet_get_spots() curl downloaded ${download_size} bytes of spot info after ${curl_seconds} seconds"
            fi
        fi
    fi
    return ${ret_code}
}

### Convert the html we get from wsprnet to a csv file
### The html records are in the order Spotnum,Date,Reporter,ReporterGrid,dB,Mhz,CallSign,Grid,Power,Drift,distance,azimuth,Band,version,code
### The html records are in the order  1       2     3         4         5  6     7       8     9    10      11      12     13     14    15
declare -r INVALID_SPOT_MINUTES=" 1 3 7 9 11 13 17 19 21 23 27 29 31 33 37 39 41 43 47 49 51 53 57 59 "
function wsprnet_to_csv() {
    local wsprnet_html_spot_file=$1
    local wsprnet_csv_spot_file=$2
        local scrape_start_seconds=$3
    
    local lines=$(cat ${wsprnet_html_spot_file} | sed 's/[{]/\n/g; s/[}],//g; s/"//g; s/[}]/\n/' | sed '/^\[/d; /^\]/d; s/[a-zA-Z]*://g')
          lines="${lines//\\/}"          ### Strips the '\' out of the call sign and reporter fields, e.g. 'N6GN\/P' becomes 'N6GN/P''
    local sorted_lines=$(sort <<< "${lines}")      ### Now sorted by spot id (which ought to be by time, too)
    local sorted_lines_array=()
    mapfile -t sorted_lines_array <<< "${sorted_lines}" 

    local html_spotnum_count=$(grep -o Spotnum ${wsprnet_html_spot_file} | wc -l)
    if [[ ${html_spotnum_count} -ne ${#sorted_lines_array[@]} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wsprnet_to_csv() WARNING: found ${html_spotnum_count} spotnums in the html file, but only ${#sorted_lines_array[@]} in our plaintext version of it"
    fi

    [[ ${verbosity} -ge 2 ]] && echo "$(date): wsprnet_to_csv() found ${#sorted_lines_array[@]} elements in sorted_lines_array[@]"

    local sorted_lines_array_count=${#sorted_lines_array[@]}
    local max_index=$((${sorted_lines_array_count} - 1))
    local first_line=${sorted_lines_array[0]}
    local last_line=${sorted_lines_array[${max_index}]}
    [[ ${verbosity} -ge 2 ]] && echo "$(date): wsprnet_to_csv() extracted ${sorted_lines_array_count} lines (max index = ${max_index}) from the html file.  After sort first= ${first_line}, last= ${last_line}"

    local jq_sorted_lines=$( jq -r '(.[0] | keys_unsorted) as $keys | $keys, map([.[ $keys[] ]])[] | @csv' ${wsprnet_html_spot_file} | tail -n +2 | sort )  ### tail -n +2 == chop off the first line with the column names
    local jq_sorted_lines_array=()
    mapfile -t jq_sorted_lines_array  <<< "$( sed 's/"//g' <<< "${jq_sorted_lines}" )"       ### strip off all the "s

    local different_lines=$( echo  ${sorted_lines_array[@]} ${jq_sorted_lines_array[@]}  | tr ' ' '\n' | sort | uniq -u )
    if [[ -n "${different_lines}" ]]; then
         if [[ ${verbosity} -ge 0 ]]; then
            echo "$(date): ERROR: wsprnet_to_csv() extracted ${#sorted_lines_array[@]} spot lines using sed, ${#jq_sorted_lines_array[@]} using jq and they differ.  So using the jq output"
            ( IFS=$'\n'; local line ; for line in "${sorted_lines_array[@]}"; do echo ${line}; done  > sed_lines.txt )
            ( IFS=$'\n'; local line ; for line in "${jq_sorted_lines_array[@]}"; do echo ${line}; done  > jq_lines.txt )
        fi
        sorted_lines_array=( "${jq_sorted_lines_array[@]}" )
    fi
 
    ### To monitor and validate the spots, check for gaps in the sequence numbers
    local total_gaps=0
    local total_missing=0
    local max_gap_size=0
    local expected_seq=0
    for index in $(seq 0 ${max_index}); do
        local got_seq=${sorted_lines_array[${index}]//,*}
        local next_seq=$(( ${got_seq} + 1 ))
        if [[ ${index} -eq 0 ]]; then
            expected_seq=${next_seq}
        else
            local gap_size=$(( got_seq - expected_seq ))
            if [[ ${gap_size} -ne 0  ]]; then
               total_gaps=$(( total_gaps + 1 ))
               total_missing=$(( total_missing + gap_size ))
               if [[ ${gap_size} -gt ${max_gap_size} ]]; then
                   max_gap_size=${gap_size}
               fi
               [[ ${verbosity} -ge 1 ]] && printf "$(date): wsprnet_to_csv() found gap of %3d at index %4d:  Expected ${expected_seq}, got ${got_seq}\n" "${gap_size}" "${index}"
           fi
           expected_seq=${next_seq}
       fi
    done
    if [[ ${verbosity} -ge 1 ]] && [[ ${max_gap_size} -gt 0 ]] && [[ ${WSPRNET_LAST_SPOTNUM} -ne 0 ]]; then
        printf "$(date): wsprnet_to_csv() found ${total_gaps} gaps missing a total of ${total_missing} spots. The max gap was of ${max_gap_size} spot numbers\n"
    fi

    unset lines   ### just to be sure we don't use it again

    ### Prepend TS format times derived from the epoch times in field #2 to each spot line in the sorted 
    ### There are probably only 1 or 2 different dates for the spot lines.  So use awk or sed to batch convert rather than examining each line.
    ### Prepend the TS format date to each of the API lines
    rm -f ${wsprnet_csv_spot_file}
    local dates_list=( $(awk -F , '{print $2}' <<< "${sorted_lines}" | sort -u) )
    for spot_date in "${dates_list[@]}"; do
        local spot_date_mod_secs=$(( spot_date % 120 ))
        if [[ ${spot_date_mod_secs} -eq 0 ]]; then
            local ts_spot_date=$(date -d @${spot_date} +%Y-%m-%d:%H:%M)
            awk "/${spot_date}/{print \"${ts_spot_date},\" \$0}" <<< "${sorted_lines}"  >> ${wsprnet_csv_spot_file}
        elif [[ ${spot_date_mod_secs} -eq 60 ]]; then
            ### In the .csv files WN appears to increment odd spot minute times to the next even minute, So we will do that too
            awk "/${spot_date}/" <<< "${sorted_lines}" > odd_spot_times.log
            local spot_minute=$(printf "%(%M)T" ${spot_date})
            [[ ${verbosity} -ge 1 ]] && printf "$(date): wsprnet_to_csv() found $( wc -l < odd_spot_times.log ) spots with time ${spot_date} (minute ${spot_minute}) which is not on a 2 minute boundary, so increment spot_date to next (even) minute\n$( < odd_spot_times.log )\n"
            local fixed_spot_date=$(( spot_date + 60 ))
            if [[ ! ${INVALID_SPOT_MINUTES} =~ " ${spot_minute} " ]]; then
                [[ ${verbosity} -ge 1 ]] && printf "$(date): wsprnet_to_csv() odd spots are for a valid minute ${spot_minute}\n"
            fi
            local fixed_ts_spot_date=$(date -d @${fixed_spot_date} +%Y-%m-%d:%H:%M)
            local fixed_lines=$( awk -F , "BEGIN {OFS = \",\"} /${spot_date}/{ \$2 = ${fixed_spot_date} ; print \"${ts_spot_date},\" \$0}" <<< "${sorted_lines}")
            echo "${fixed_lines}" >> ${wsprnet_csv_spot_file}
            [[ ${verbosity} -ge 2 ]] && printf "$(date): wsprnet_to_csv() changed odd minute spots:\n$(< odd_spot_times.log)\nTo:\n${fixed_lines}\n"
        else
            [[ ${verbosity} -ge 1 ]] && printf "$(date): wsprnet_to_csv() WARNING: wsprnet gave  spots with times not on even or odd minute:\n$( awk "/${spot_date}/"  <<< "${sorted_lines}")\n"
        fi
    done

    local csv_spotnum_count=$( wc -l < ${wsprnet_csv_spot_file})
    if [[ ${csv_spotnum_count} -ne ${#sorted_lines_array[@]} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wsprnet_to_csv() WARNING: found ${#sorted_lines_array[@]} in our plaintext of the html file, but only ${csv_spotnum_count} is the csv version of it"
    fi

    local first_spot_array=(${sorted_lines_array[0]//,/ })
    local last_spot_array=(${sorted_lines_array[${max_index}]//,/ })
    local scrape_seconds=$(( ${SECONDS} - ${scrape_start_seconds} ))
    [[ ${verbosity} -ge 1 ]] && printf "$(date): wsprnet_to_csv() in %3d seconds got scrape with %4d spots from %4d wspr cycles. First spot: ${first_spot_array[0]}/${first_spot_array[1]}, Last spot: ${last_spot_array[0]}/${last_spot_array[1]}\n" ${scrape_seconds} "${#sorted_lines_array[@]}" "${#dates_list[@]}" 

    ### For monitoring and validation, document the gap between the last spot of the last scrape and the first spot of this scrape
    local spot_num_gap=$(( ${first_spot_array[0]} - ${WSPRNET_LAST_SPOTNUM} ))
    if [[ ${WSPRNET_LAST_SPOTNUM} -ne 0 ]] && [[ ${spot_num_gap} -gt 2 ]]; then
        [[ ${verbosity} -ge 1 ]] && printf "$(date): wsprnet_to_csv() found gap of %4d spotnums between last spot #${WSPRNET_LAST_SPOTNUM} and first spot #${first_spot_array[0]} of this scrape\n" "${spot_num_gap}"
    fi
    ### Remember the current last spot for the next call to this function
    WSPRNET_LAST_SPOTNUM=${last_spot_array[0]}
}

declare WSPRNET_OFFSET_FIRST_SEC=55
declare WSPRNET_OFFSET_GAP=30
declare WSPRNET_OFFSET_SECS=""
offset=${WSPRNET_OFFSET_FIRST_SEC}
while [[ ${offset} -lt 120 ]]; do
   WSPRNET_OFFSET_SECS="${WSPRNET_OFFSET_SECS} ${offset}"
   offset=$(( offset + WSPRNET_OFFSET_GAP ))
done

function api_wait_until_next_offset() {
    local epoch_secs=$(date +%s)
    local cycle_offset=$(( ${epoch_secs} % 120 ))

    [[ ${verbosity} -ge 3 ]] && echo "$(date): api_wait_until_next_offset() starting at offset ${cycle_offset}"
    for secs in ${WSPRNET_OFFSET_SECS}; do
        secs_to_next=$(( ${secs} - ${cycle_offset} ))    
        [[ ${verbosity} -ge 3 ]] && echo "$(date): api_wait_until_next_offset() ${secs} - ${cycle_offset} = ${secs_to_next} secs_to_next"
        if [[ ${secs_to_next} -le 0 ]]; then
            [[ ${verbosity} -ge 3 ]] && echo "$(date): api_wait_until_next_offset() offset secs ${cycle_offset} is greater than test offset ${secs}"
        else
            [[ ${verbosity} -ge 3 ]] && echo "$(date): api_wait_until_next_offset() found ${secs}"
            break
        fi
    done
    local secs_to_next=$(( secs - cycle_offset ))
    if [[ ${secs_to_next} -le 0 ]]; then
       ### we started after 110 seconds
       secs=${WSPRNET_OFFSET_FIRST_SEC}
       secs_to_next=$(( 120 - cycle_offset + secs ))
    fi
    [[ ${verbosity} -ge 2 ]] && echo "$(date): api_wait_until_next_offset() starting at offset ${cycle_offset}, next offset ${secs}, so secs_to_wait = ${secs_to_next}"
    sleep ${secs_to_next}
}

# G3ZIL add tx and rx lat, lon and azimuths and path vertex using python script. In the main program, call this function with a file path/name for the input file
# the appended data gets stored into this file which can be examined. Overwritten each acquisition cycle.
declare WSPRNET_CSV_SPOT_FILE=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_spots.csv              ### This csv is derived from the html returned by the API and has fields 'wd_date, spotnum, epoch, ...' sorted by spotnum
declare WSPRNET_CSV_SPOT_AZI_FILE=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_spots_azi.csv      ### This csv is derived from WSPRNET_CSV_SPOT_FILE and includes wd_XXXX fields calculated by azi_calc.py and added to each spot line
declare AZI_PYTHON_CMD=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_azi_calc.py

### Takes a spot file created by API and adds azimuth fields to it
function wsprnet_add_azi() {
    local api_spot_file=$1
    local api_azi_file=$2

    [[ ${verbosity} -ge 2 ]] && echo "$(date): wsprnet_add_azi() process ${api_spot_file} to create ${api_azi_file}"

    if [[ ! -f ${AZI_PYTHON_CMD} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wsprnet_add_azi() ERROR: can't find expected python file ${AZI_PYTHON_CMD}"
        exit 1
    fi
    python3 ${AZI_PYTHON_CMD} --input ${api_spot_file} --output ${api_azi_file}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): wsprnet_add_azi() python3 ${AZI_PYTHON_CMD} ${api_spot_file} ${api_azi_file} => ${ret_code}"
    else
        [[ ${verbosity} -ge 2 ]] && echo "$(date): wsprnet_add_azi() python3 ${AZI_PYTHON_CMD} ${api_spot_file} ${api_azi_file} => ${ret_code}"
    fi
    return ${ret_code}
}

declare CLICKHOUSE_IMPORT_CMD=/home/arne/tools/wsprdaemonimport.sh
declare CLICKHOUSE_IMPORT_CMD_DIR=${CLICKHOUSE_IMPORT_CMD%/*}
declare UPLOAD_TO_TS="yes"    ### -u => don't upload 

function api_scrape_once() {
    local scrape_start_seconds=${SECONDS}

    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]]; then
        wpsrnet_login
    fi
    if [[ -f ${WSPRNET_SESSION_ID_FILE} ]]; then
        wpsrnet_get_spots
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            [[ ${verbosity} -ge 2 ]] && echo "$(date): api_scrape_once() wpsrnet_get_spots reported error => ${ret_code}."
        else
            wsprnet_to_csv      ${WSPRNET_HTML_SPOT_FILE} ${WSPRNET_CSV_SPOT_FILE} ${scrape_start_seconds}
            wsprnet_add_azi     ${WSPRNET_CSV_SPOT_FILE}  ${WSPRNET_CSV_SPOT_AZI_FILE}
            if [[ ${UPLOAD_TO_TS} == "yes" ]]; then
                wn_spots_batch_upload    ${WSPRNET_CSV_SPOT_AZI_FILE}
            fi
            if [[ -x ${CLICKHOUSE_IMPORT_CMD} ]]; then
                ( cd ${CLICKHOUSE_IMPORT_CMD_DIR}; ${CLICKHOUSE_IMPORT_CMD} ${WSPRNET_CSV_SPOT_FILE} )
                [[ ${verbosity} -ge 2 ]] && echo "$(date): The Clickhouse database has been updated"
            fi
            [[ ${verbosity} -ge 2 ]] && printf "$(date): api_scrape_once() batch upload completed.\n"
        fi
    fi
}

function api_scrape_daemon() {
    [[ ${verbosity} -ge 1 ]] && echo "$(date): wsprnet_scrape_daemon() is starting.  Scrapes will be attempted at second offsets: ${WSPRNET_OFFSET_SECS}"
    setup_verbosity_traps
    while true; do
        api_scrape_once
        api_wait_until_next_offset
   done
}

################### Deamon spawn/status/kill section ##########################################################
declare RUN_AS_DAEMON="yes"   ### -d => change to "no"
function spawn_daemon() {
    local daemon_function=$1
    local daemon_pid_file=$2
    local daemon_log_file=$3
    local daemon_pid=

    if [[ -f ${daemon_pid_file} ]]; then
        daemon_pid=$(cat ${daemon_pid_file})
        if ps ${daemon_pid} > /dev/null ; then
            [[ $verbosity -ge 1 ]] && echo "$(date): spawn_daemon() found running daemon '${daemon_function}' with pid ${daemon_pid}"
            return 0
        fi
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_daemon() found dead pid file ${daemon_pid_file} for daemon '${daemon_function}'"
        rm ${daemon_pid_file}
    fi
    if [[ ${RUN_AS_DAEMON} == "yes" ]]; then
        ${daemon_function}   > ${daemon_log_file} 2>&1 &
    else
        ${daemon_function} # > ${daemon_log_file} 2>&1 &
    fi
    local ret_code=$?
    local daemon_pid=$!
    if [[ ${ret_code} -ne 0 ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_daemon() failed to spawn ${daemon_function} => ${ret_code}"
        return 1
    fi
    echo ${daemon_pid} > ${daemon_pid_file}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_daemon() spawned ${daemon_function} which has pid ${daemon_pid}"
    return 0
}

function status_daemon() {
    local daemon_function=$1
    local daemon_pid_file=$2
    local daemon_pid=

    if [[ -f ${daemon_pid_file} ]]; then
        daemon_pid=$(cat ${daemon_pid_file})
        if ps ${daemon_pid} > /dev/null ; then
            [[ $verbosity -ge 0 ]] && echo "$(date): status_daemon() found running daemon '${daemon_function}' with pid ${daemon_pid}"
            return 0
        fi
        [[ $verbosity -ge 0 ]] && echo "$(date): status_daemon() found dead pid file ${daemon_pid_file} for daemon '${daemon_function}'"
        rm ${daemon_pid_file}
        return 1
    fi
    [[ $verbosity -ge 0 ]] && echo "$(date): status_daemon() found no pid file '${daemon_pid_file}' for daemon'${daemon_function}'"
    return 0
}

function kill_daemon() {
    local daemon_function=$1
    local daemon_pid_file=$2
    local daemon_pid=
    local ret_code

    if [[ ! -f ${daemon_pid_file} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): kill_daemon() found no pid file '${daemon_pid_file}' for daemon '${daemon_function}'"
        ret_code=0
    else
        daemon_pid=$(cat ${daemon_pid_file})
        ps ${daemon_pid} > /dev/null
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_daemon() found dead pid file ${daemon_pid_file} for daemon '${daemon_function}'"
            ret_code=1
        else
            kill ${daemon_pid}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): kill_daemon() FAILED 'kill ${daemon_pid}' => ${ret_code} for running daemon '${daemon_function}'"
            else
                [[ $verbosity -ge 1 ]] && echo "$(date): kill_daemon() killed running daemon '${daemon_function}' with pid ${daemon_pid}"
            fi
        fi
    fi
    rm -f ${daemon_pid_file}
    return ${ret_code}
}

declare UPLOAD_LOG_FILE=${WSPRNET_SCRAPER_HOME_PATH}/upload.log
declare UPLOAD_PID_FILE=${WSPRNET_SCRAPER_HOME_PATH}/upload.pid
declare WSPR_DAEMON_LOG_PATH=${WSPRNET_SCRAPER_HOME_PATH}/scraper.log
declare WSPR_DAEMON_PID_PATH=${WSPRNET_SCRAPER_HOME_PATH}/scraper.pid

if [[ ${UPLOAD_MODE} == "API" ]]; then
    declare UPLOAD_DAEMON_FUNCTION=api_scrape_daemon
else
    declare UPLOAD_DAEMON_FUNCTION=oldDb_scrape_daemon
fi

SCRAPER_CONFIG_FILE=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet-scraper.conf
if [[ -f ${SCRAPER_CONFIG_FILE} ]]; then
    source ${SCRAPER_CONFIG_FILE}
fi
declare MIRROR_TO_WD1=${MIRROR_TO_WD1:-no}

function scrape_start() {
    if [[ ${MIRROR_TO_WD1} == "yes" ]]; then
        spawn_daemon         upload_to_wd1_daemon           ${UPLOAD_PID_FILE}      ${UPLOAD_LOG_FILE}
    fi
    spawn_daemon         ${UPLOAD_DAEMON_FUNCTION}      ${WSPR_DAEMON_PID_PATH} ${WSPR_DAEMON_LOG_PATH}
}

function scrape_status() {
    if [[ ${MIRROR_TO_WD1} == "yes" ]]; then
        status_daemon        upload_to_wd1_daemon           ${UPLOAD_PID_FILE}      ${UPLOAD_LOG_FILE}
    fi
    status_daemon        ${UPLOAD_DAEMON_FUNCTION}      ${WSPR_DAEMON_PID_PATH} ${WSPR_DAEMON_LOG_PATH}
}

function scrape_stop() {
    if [[ ${MIRROR_TO_WD1} == "yes" ]]; then
        kill_daemon         upload_to_wd1_daemon           ${UPLOAD_PID_FILE}      ${UPLOAD_LOG_FILE}
    fi
    kill_daemon         ${UPLOAD_DAEMON_FUNCTION}      ${WSPR_DAEMON_PID_PATH} ${WSPR_DAEMON_LOG_PATH}
}

##########################################################################################
### Configure systemctl so the scrape daemon starts during boot
declare -r WSPRNET_SCRAPER_SERVICE_NAME=wsprnet-scraper
declare -r SYSTEMNCTL_UNIT_PATH=/lib/systemd/system/${WSPRNET_SCRAPER_SERVICE_NAME}.service

function setup_systemctl_deamon() {
    local systemctl_dir=${SYSTEMNCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        echo "$(date): setup_systemctl_deamon() WARNING, this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): setup_systemctl_deamon() found this server already has a ${SYSTEMNCTL_UNIT_PATH} file. So leaving it alone."
    fi
    local my_id="scraper"
    local my_group="scraper"
    cat > ${SYSTEMNCTL_UNIT_PATH##*/} <<EOF
    [Unit]
    Description= WsprNet Scraping daemon
    After=multi-user.target

    [Service]
    User=${my_id}
    Group=${my_group}
    Type=forking
    ExecStart=${WSPRNET_SCRAPER_HOME_PATH}/${WSPRNET_SCRAPER_SERVICE_NAME}.sh -a
    ExecStop=${WSPRNET_SCRAPER_HOME_PATH}/${WSPRNET_SCRAPER_SERVICE_NAME}.sh -z
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF
   mv ${SYSTEMNCTL_UNIT_PATH##*/} ${SYSTEMNCTL_UNIT_PATH}    ### 'sudo cat > ${SYSTEMNCTL_UNIT_PATH} gave me permission errors
   systemctl daemon-reload
   systemctl enable ${WSPRNET_SCRAPER_SERVICE_NAME}.service
   echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
   echo " ${WSPRNET_SCRAPER_SERVICE_NAME} daemon will now automatically start after a powerup or reboot of this system"
}

function enable_systemctl_deamon() {
    if [[ ${USER} != root ]]; then
        echo "This command must be run as user 'root'"
        return
    fi
    setup_systemctl_deamon
    systemctl enable ${WSPRNET_SCRAPER_SERVICE_NAME}.service
}
function disable_systemctl_deamon() {
    systemctl disable ${WSPRNET_SCRAPER_SERVICE_NAME}.service
}

### Prints the help message
function usage(){
    echo "usage: $0  VERSION=$VERSION
    -a             stArt WSPRNET scraping daemon
    -s             Show daemon Status
    -z             Kill (put to sleep == ZZZZZ) running daemon
    -d/-D          increment / Decrement the verbosity of a running daemon
    -e/-E          enable / disablE starting daemon at boot time
    -n             Don't run as daemon (for debugging)
    -u             Don't upload to TS (<S-F10>for debugging)
    -v             Increment verbosity of diagnotic printouts
    -h             Print this message
    "
}

### Print out an error message if the command line arguments are wrong
function bad_args(){
    echo "ERROR: command line arguments not valid: '$1'" >&2
    echo
    usage
}

cmd=bad_args
cmd_arg="$*"

while getopts :aszdDeEnuvh opt ; do
    case $opt in
        a)
            cmd=scrape_start
            ;;
        s)
            cmd=scrape_status
            ;;
        z)
            cmd=scrape_stop
            ;;
        d)
            cmd=increment_verbosity;
            ;;
        D)
            cmd=decrement_verbosity;
            ;;
        n)
            RUN_AS_DAEMON="no"
            ;;
        u)
            UPLOAD_TO_TS="no"
            ;;
        e)
            cmd=enable_systemctl_deamon
            ;;
        E)
            cmd=disable_systemctl_deamon
            ;;
        h)
            cmd=usage
            ;;
        v)
            let verbosity++
            echo "Verbosity = $verbosity" >&2
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit
            ;;
    esac
done

$cmd "$cmd_arg"

