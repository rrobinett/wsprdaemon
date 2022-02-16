#!/bin/bash

declare -r WSPRNET_SCRAPER_HOME_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"   ### Where to find the .sh, .conf and .awk files
declare -r WSPRNET_SCRAPER_TMP_PATH=${WSPRDAEMON_TMP_DIR}/scraper.d
mkdir -p ${WSPRNET_SCRAPER_TMP_PATH}
declare -r WSPRNET_HTML_SPOT_FILE=${WSPRNET_SCRAPER_TMP_PATH}/wsprnet_spots.html

################### API scrape section ##########################################################

declare UPLOAD_WN_BATCH_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/wn_upload_batch.py
declare UPLOAD_SPOT_SQL='INSERT INTO spots (wd_time, "Spotnum", "Date", "Reporter", "ReporterGrid", "dB", "MHz", "CallSign", "Grid", "Power", "Drift", distance, azimuth, "Band", version, code, 
    wd_band, wd_c2_noise, wd_rms_noise, wd_rx_az, wd_rx_lat, wd_rx_lon, wd_tx_az, wd_tx_lat, wd_tx_lon, wd_v_lat, wd_v_lon ) 
    VALUES( %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s );'

function wn_spots_batch_upload() {
    local csv_file=$1

    wd_logger 2 "Record ${csv_file} to TS"
    if [[ ! -f ${UPLOAD_WN_BATCH_PYTHON_CMD} ]]; then
        wd_logger 1 "ERROR: Can't find expected file '${UPLOAD_WN_BATCH_PYTHON_CMD}'"
        return 1
    fi
    python3 ${UPLOAD_WN_BATCH_PYTHON_CMD} --input ${csv_file} --sql ${WSPRDAEMON_ROOT_DIR}/insert-spots.sql --address localhost --database ${TS_DB} --username ${TS_USER} --password ${TS_PASSWORD}  # "${UPLOAD_SPOT_SQL}" "${UPLOAD_WN_BATCH_TS_CONNECT_INFO}"
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'python3 ${UPLOAD_WN_BATCH_PYTHON_CMD} --input ${csv_file} --sql ${WSPRDAEMON_ROOT_DIR}/insert-spots.sql --address localhost --database ${TS_DB} --username ${TS_USER} --password ${TS_PASSWORD}' => ${ret_code}"
    else
        wd_logger 2 "Spot files were recorded by 'python3 ${UPLOAD_WN_BATCH_PYTHON_CMD} --input ${csv_file} --sql ${WSPRDAEMON_ROOT_DIR}/insert-spots.sql --address localhost --database ${TS_DB} --username ${TS_USER} --password ${TS_PASSWORD}' "
    fi
    return ${ret_code}
}

declare WSPRNET_SESSION_ID_FILE=${WSPRNET_SCRAPER_TMP_PATH}/wsprnet_session_info.html

function wpsrnet_login() {
    wd_logger 1 "Executing curl to login"
    timeout 60 curl -s -d '{"name":"'${WSPRNET_USER}'", "pass":"'${WSPRNET_PASSWORD}'"}' -H "Content-Type: application/json" -X POST http://www.wsprnet.org/drupal/rest/user/login > ${WSPRNET_SESSION_ID_FILE}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        local sessid=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/sessid/s/^.*://p' | sed 's/"//g')
        local session_name=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/session_name/s/^.*://p' | sed 's/"//g')
        if [[ -z "${sessid}" ]] || [[ -z "${session_name}" ]]; then
            wd_logger 1 "ERROR: failed to extract sessid=${sessid} and/or session_name${session_name}"
            rm -f ${WSPRNET_SESSION_ID_FILE}
            ret_code=2
        else
            wd_logger 1 "Login was successful"
        fi
    else
        wd_logger 1 "ERROR: curl login failed => ${ret_code}"
        rm -f ${WSPRNET_SESSION_ID_FILE}
   fi
    return ${ret_code}
}

declare WSPRNET_LAST_SPOTNUM=0

function wpsrnet_get_spots() {
    local html_spot_file=$1     ### For now, this is always WSPRNET_HTML_SPOT_FILE

    wd_logger 2 "Starting"
    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]] || [[ ! -s ${WSPRNET_SESSION_ID_FILE} ]]; then
       if ! wpsrnet_login ; then
           wd_logger 1 "ERROR: failed to login to wsprnet.org"
           return 1
       fi
    fi
    local sessid=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/sessid/s/^.*://p' | sed 's/"//g')
    local session_name=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/session_name/s/^.*://p' | sed 's/"//g')
    if [[ -z "${sessid}" ]] || [[ -z "${session_name}" ]]; then
        wd_logger 1 "ERROR: failed to extract sessid=${sessid} and/or session_name${session_name}"
        rm -f ${WSPRNET_SESSION_ID_FILE}
        ret_code=2
    fi
    local session_token="${session_name}=${sessid}"
    wd_logger 2 "Got wsprnet session_token = ${session_token}"
 
    if [[ ${WSPRNET_LAST_SPOTNUM} -eq 0 ]]; then
        ### Get the largest Spotnum from the TS DB
        ### I need to redirect the output to a file or the psql return code gets lost
        local psql_output_file=${WSPRNET_SCRAPER_TMP_PATH}/psql.out
        PGPASSWORD=${TS_PASSWORD}  psql -t -U ${TS_USER} -d ${TS_DB}  -c 'select "Spotnum" from spots order by "Spotnum" desc limit 1 ;' > ${psql_output_file}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: psql( ${TS_USER}/${TS_PASSWORD}/${TS_DB}) for latest TS returned error => ${ret_code}"
            exit 1
        fi
        local psql_output=$(cat ${psql_output_file})
        local last_spotnum=$(tr -d ' ' <<< "${psql_output}")
        if [[ -z "${last_spotnum}" ]] || [[ ${last_spotnum} -eq 0 ]]; then
            wd_logger 1 "ERROR: At startup failed to get a Spotnum from TS"
            exit 1
        fi
        WSPRNET_LAST_SPOTNUM=${last_spotnum}
        wd_logger 1 "At startup using highest Spotnum ${last_spotnum} from TS, not 0"
    fi
    wd_logger 2 "Starting curl download for spotnum_start=${WSPRNET_LAST_SPOTNUM}"
    local start_seconds=${SECONDS}
    local curl_str="'{spotnum_start:\"${WSPRNET_LAST_SPOTNUM}\",band:\"All\",callsign:\"\",reporter:\"\",exclude_special:\"1\"}'"
    curl -s -m ${WSPRNET_CURL_TIMEOUT-120} -b "${session_token}" -H "Content-Type: application/json" -X POST -d ${curl_str}  i\
               "http://www.wsprnet.org/drupal/wsprnet/spots/json?band=All&spotnum_start=${WSPRNET_LAST_SPOTNUM}&exclude_special=0" > ${html_spot_file}
    local ret_code=$?
    local end_seconds=${SECONDS}
    local curl_seconds=$(( end_seconds - start_seconds))
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: curl download failed => ${ret_code} after ${curl_seconds} seconds"
    else
        if grep -q "You are not authorized to access this page." ${html_spot_file}; then
            wd_logger 1 "ERROR: wsprnet.org login failed and reported 'You are not authorized to access this page'"
            rm ${WSPRNET_SESSION_ID_FILE}
            ret_code=1
        else
            if ! grep -q "Spotnum" ${html_spot_file} ; then
                wd_logger 1 "WARNING: ${html_spot_file} contains no spots"
                ret_code=2
            else
                local download_size=$( cat ${html_spot_file} | wc -c)
                wd_logger 2 "curl downloaded ${download_size} bytes of spot info after ${curl_seconds} seconds"
            fi
        fi
    fi
    return ${ret_code}
}

### Convert the html we get from wsprnet to a csv file
### The html records are in the order Spotnum,Date,Reporter,ReporterGrid,dB,Mhz,CallSign,Grid,Power,Drift,distance,azimuth,Band,version,code
### The html records are in the order  1       2     3         4         5  6     7       8     9    10      11      12     13     14    15

declare SHOW_SPOTS_OLDER_THAN_MINUTES_DEFAULT=30       ## $(( 60 * 24 * 7 )) change to this if want to print out spots only older than 7 days
declare SHOW_SPOTS_OLDER_THAN_MINUTES=${SHOW_SPOTS_OLDER_THAN_MINUTES-${SHOW_SPOTS_OLDER_THAN_MINUTES_DEFAULT}}

### Creates a file which records a gap between scrapes or within a scrape.  The scrape_gap_filler_deemon() will attempt to fill those gaps by quering the other WD servers
function queue_gap_file() {
    local first_missing_seq=$1
    local last_missing_seq=$2
    mkdir -p gaps.d/
    printf "%(%s)T %d %d\n" -1 ${first_missing_seq} ${last_missing_seq} > gaps.d/${first_missing_seq}.log
}

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
        wd_logger 1 "ERROR: found ${html_spotnum_count} spotnums in the html file, but only ${#sorted_lines_array[@]} in our plaintext version of it"
    fi

    wd_logger 2 "Found ${#sorted_lines_array[@]} spots"

    local sorted_lines_array_count=${#sorted_lines_array[@]}
    local max_index=$((${sorted_lines_array_count} - 1))
    local first_line=${sorted_lines_array[0]}
    local last_line=${sorted_lines_array[${max_index}]}
    wd_logger 2 "Extracted ${sorted_lines_array_count} lines (max index = ${max_index}) from the html file.  After sort first= ${first_line}, last= ${last_line}"

    local jq_sorted_lines=$( jq -r '(.[0] | keys_unsorted) as $keys | $keys, map([.[ $keys[] ]])[] | @csv' ${wsprnet_html_spot_file} | tail -n +2 | sort )  ### tail -n +2 == chop off the first line with the column names
    local jq_sorted_lines_array=()
    mapfile -t jq_sorted_lines_array  <<< "$( sed 's/"//g' <<< "${jq_sorted_lines}" )"       ### strip off all the "s

    local different_lines=$( echo  ${sorted_lines_array[@]} ${jq_sorted_lines_array[@]}  | tr ' ' '\n' | sort | uniq -u )
    if [[ -n "${different_lines}" ]]; then
         if [[ ${verbosity} -ge 0 ]]; then
            wd_logger 1 "ERROR: extracted ${#sorted_lines_array[@]} spot lines using sed, ${#jq_sorted_lines_array[@]} using jq and they differ.  So using the jq output"
            ( IFS=$'\n'; local line ; for line in "${sorted_lines_array[@]}"; do echo ${line}; done  > ${WSPRNET_SCRAPER_TMP_PATH}/sed_lines.txt )
            ( IFS=$'\n'; local line ; for line in "${jq_sorted_lines_array[@]}"; do echo ${line}; done  > ${WSPRNET_SCRAPER_TMP_PATH}/jq_lines.txt )
        fi
        sorted_lines_array=( "${jq_sorted_lines_array[@]}" )
    fi

    ### See if there is a gap between the last spot of the previous scrape or the last spot stored in our TS data and the first spot of this scrape
    local first_spot_array=(${sorted_lines_array[0]//,/ })
    local last_spot_array=(${sorted_lines_array[${max_index}]//,/ })
    local scrape_seconds=$(( ${SECONDS} - ${scrape_start_seconds} ))
    #wd_logger 1 "$(printf "In %3d seconds got scrape with %4d spots from %4d wspr cycles. First sequence_num spot: ${first_spot_array[0]}/${first_spot_array[1]}, Last spot: ${last_spot_array[0]}/${last_spot_array[1]}" ${scrape_seconds} "${#sorted_lines_array[@]}" "${#epochs_list[@]}")"
    wd_logger 1 "$(printf "In %3d seconds got scrape with %4d spots first sequence_num spot: ${first_spot_array[0]}/${first_spot_array[1]}, Last spot: ${last_spot_array[0]}/${last_spot_array[1]}" ${scrape_seconds} "${#sorted_lines_array[@]}" )"

    local spot_num_gap=$(( ${first_spot_array[0]} - ${WSPRNET_LAST_SPOTNUM} ))
    if [[ ${WSPRNET_LAST_SPOTNUM} -ne 0 ]] && [[ ${spot_num_gap} -gt 1 ]]; then
        wd_logger 1 "$(printf "Found gap of %4d spotnums between last spot #${WSPRNET_LAST_SPOTNUM} and first spot #${first_spot_array[0]} of this scrape" "${spot_num_gap}")"
        local first_missing_seq=$(( ${WSPRNET_LAST_SPOTNUM} + 1 ))
        local last_missing_seq=$((  ${first_spot_array[0]}  - 1 ))
        queue_gap_file ${first_missing_seq} ${last_missing_seq}
    fi
    ### Remember the current last spot for the next call to this function
    WSPRNET_LAST_SPOTNUM=${last_spot_array[0]}

    ### Check for gaps within this new scrape
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
               wd_logger 1 "$(printf "Found gap of %3d at index %4d:  Expected ${expected_seq}, got ${got_seq}" "${gap_size}" "${index}")"
               local first_missing_seq=${expected_seq}
               local last_missing_seq=$(( got_seq - 1 ))
               queue_gap_file ${first_missing_seq} ${last_missing_seq}
           fi
           expected_seq=${next_seq}
       fi
    done
    if [[ ${verbosity} -ge 1 ]] && [[ ${max_gap_size} -gt 0 ]] && [[ ${WSPRNET_LAST_SPOTNUM} -ne 0 ]]; then
        wd_logger 1 "Found ${total_gaps} gaps missing a total of ${total_missing} spots. The max gap was of ${max_gap_size} spot numbers"
    fi

    ### Create a csv file from the scraped spots
    unset lines   ### just to be sure we don't use it again

    ### Prepend TS format times derived from the epoch times in field #2 to each spot line in the sorted 
    ### There are probably only 1 or 2 different dates for the spot lines.  So use awk or sed to batch convert rather than examining each line.
    ### Prepend the TS format date to each of the API lines
    rm -f ${wsprnet_csv_spot_file}
    local epochs_list=( $(awk -F , '{print $2}' <<< "${sorted_lines}" | sort -u) )
    if [[ ${#epochs_list[@]} -eq 1 ]]; then
        wd_logger 1 "Found all spots are for epoch ${epochs_list[0]}"
    else
        local minutes_span=$(( (${epochs_list[-1]} - ${epochs_list[0]}) / 60 ))
        wd_logger 1 "Found spots which span ${minutes_span} minutes: ${epochs_list[*]:0:10}.."
    fi

    for spot_epoch in "${epochs_list[@]}"; do
        awk -v spot_epoch=${spot_epoch} -f ${WSPRDAEMON_ROOT_DIR}/wsprnet-scraper.awk <<< "${sorted_lines}" > ${WSPRNET_SCRAPER_TMP_PATH}/filtered_spots.csv
        grep -v "^20" ${WSPRNET_SCRAPER_TMP_PATH}/filtered_spots.csv > ${WSPRNET_SCRAPER_TMP_PATH}/bad_spots.txt 
        if [[ -s ${WSPRNET_SCRAPER_TMP_PATH}/bad_spots.txt ]]; then
            wd_logger 1 "Found invalid spots:\n$(< ${WSPRNET_SCRAPER_TMP_PATH}/bad_spots.txt)"
        fi
        grep    "^20" ${WSPRNET_SCRAPER_TMP_PATH}/filtered_spots.csv > ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv
        if [[ -s ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv ]]; then
            local spots_to_add_count=$(wc -l < ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv)
            wd_logger 1 "$(printf "adding %4d spots at epoch %d == '%(%Y-%m-%d:%H:%M)T'"  ${spots_to_add_count}  ${spot_epoch} ${spot_epoch})"
            local this_epcoch_age_minutes=$(( (${epochs_list[-1]} - ${spot_epoch}) / 60 ))
            if [[ ${this_epcoch_age_minutes} -gt ${SHOW_SPOTS_OLDER_THAN_MINUTES} ]]; then
                wd_logger 1 "Adding spots more than ${SHOW_SPOTS_OLDER_THAN_MINUTES} minutes old:\n$(head -n 4 ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv)"
            fi
            cat ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv  >> ${wsprnet_csv_spot_file}
        fi
    done

    local csv_spotnum_count=$( wc -l < ${wsprnet_csv_spot_file})
    if [[ ${csv_spotnum_count} -ne ${#sorted_lines_array[@]} ]]; then
        wd_logger 1 "ERROR: found ${#sorted_lines_array[@]} in our plaintext of the html file, but only ${csv_spotnum_count} is the csv version of it"
        return 1
    fi
    return 0
}

### Create ${WSPRNET_OFFSET_SECS}, a string of offsets in seconds from the start of an even minute when the scraper should execute the wsprnet API to get the latest spots
### This variable is used by the api_wait_until_next_offset() to determine how long to sleep
declare WSPRNET_OFFSET_FIRST_SEC=55
declare WSPRNET_OFFSET_GAP=30
declare WSPRNET_OFFSET_SECS=""
offset=${WSPRNET_OFFSET_FIRST_SEC}
while [[ ${offset} -lt 120 ]]; do
   WSPRNET_OFFSET_SECS="${WSPRNET_OFFSET_SECS} ${offset}"
   offset=$(( offset + WSPRNET_OFFSET_GAP ))
done

function api_wait_until_next_offset() {
    local epoch_secs=$(printf "%(%s)T\n" -1)    ### more efficient than $(date +%s)'
    local cycle_offset=$(( ${epoch_secs} % 120 ))

    wd_logger 2 "starting at offset ${cycle_offset}"
    for secs in ${WSPRNET_OFFSET_SECS}; do
        secs_to_next=$(( ${secs} - ${cycle_offset} ))    
        wd_logger 2 "${secs} - ${cycle_offset} = ${secs_to_next} secs_to_next"
        if [[ ${secs_to_next} -le 0 ]]; then
            wd_logger 2 "Offset secs ${cycle_offset} is greater than test offset ${secs}"
        else
            wd_logger 2 "Found next offset will be at ${secs}"
            break
        fi
    done
    local secs_to_next=$(( secs - cycle_offset ))
    if [[ ${secs_to_next} -le 0 ]]; then
       ### we started after 110 seconds
       secs=${WSPRNET_OFFSET_FIRST_SEC}
       secs_to_next=$(( 120 - cycle_offset + secs ))
    fi
    wd_logger 2 "Starting at offset ${cycle_offset}, next offset ${secs}, so secs_to_wait = ${secs_to_next}"
    wd_sleep ${secs_to_next}
}

# G3ZIL add tx and rx lat, lon and azimuths and path vertex using python script. In the main program, call this function with a file path/name for the input file
# the appended data gets stored into this file which can be examined. Overwritten each acquisition cycle.
declare WSPRNET_CSV_SPOT_FILE=${WSPRNET_SCRAPER_TMP_PATH}/wsprnet_spots.csv              ### This csv is derived from the html returned by the API and has fields 'wd_date, spotnum, epoch, ...' sorted by spotnum
declare WSPRNET_CSV_SPOT_AZI_FILE=${WSPRNET_SCRAPER_TMP_PATH}/wsprnet_spots_azi.csv      ### This csv is derived from WSPRNET_CSV_SPOT_FILE and includes wd_XXXX fields calculated by azi_calc.py and added to each spot line
declare WSPRNET_AZI_PYTHON_CMD=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_azi_calc.py

### Takes a spot file created by API and adds azimuth fields to it
function wsprnet_add_azi() {
    local api_spot_file_path=$1
    local api_azi_file_path=$2

    wd_logger 2 "process ${api_spot_file_path} to create ${api_azi_file_path}"
    if [[ ! -f ${api_spot_file_path} ]]; then
        wd_logger 1 "ERROR: no api_spot_file_path=${api_spot_file_path}"
        return 1
    fi

    if [[ ! -f ${WSPRNET_AZI_PYTHON_CMD} ]]; then
        wd_logger 1 "ERROR: can't find expected python file ${WSPRNET_AZI_PYTHON_CMD}"
        return 2
    fi
    python3 ${WSPRNET_AZI_PYTHON_CMD} --input ${api_spot_file_path} --output ${api_azi_file_path}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR:  'python3 ${WSPRNET_AZI_PYTHON_CMD} --input ${api_spot_file_path} --output ${api_azi_file_path}' => ${ret_code}"
    else
        wd_logger 2 "python3 ${WSPRNET_AZI_PYTHON_CMD} ${api_spot_file_path} ${api_azi_file_path} => ${ret_code}"
    fi
    return ${ret_code}
}

declare CLICKHOUSE_IMPORT_CMD=/home/arne/tools/wsprdaemonimport.sh
declare CLICKHOUSE_IMPORT_CMD_DIR=${CLICKHOUSE_IMPORT_CMD%/*}
declare UPLOAD_TO_TS="yes"    ### -u => don't upload 

function api_scrape_once() {
    local scrape_start_seconds=${SECONDS}
    local ret_code

    wd_logger 2 "Starting in $PWD"
    if [[ ! -d ${UPLOAD_DAEMON_FTP_DIR} ]]; then
	wd_logger 1 "No '${UPLOAD_DAEMON_FTP_DIR}' on this server, so the user 'noisegraphs' is not setup on this server. Aborting this scrape and try to find it again later"
	return 1
    fi
    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]]; then
        wd_logger 1 "Logging into wsprnet"
        wpsrnet_login
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: wpsrnet_login returned error => ${ret_code}"
            return ${ret_code}
        fi
    fi
    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]]; then
         wd_logger 1 "ERROR: wpsrnet_login was successful, but it produced no ${WSPRNET_SESSION_ID_FILE}"
         return 1
    fi
    wpsrnet_get_spots ${WSPRNET_HTML_SPOT_FILE}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: wpsrnet_get_spots() returned error => ${ret_code}."
        return ${ret_code}
    fi
    wd_logger 2 "Got spots in html file  ${WSPRNET_HTML_SPOT_FILE}, translate into ${WSPRNET_CSV_SPOT_FILE}"
    wsprnet_to_csv      ${WSPRNET_HTML_SPOT_FILE} ${WSPRNET_CSV_SPOT_FILE} ${scrape_start_seconds}
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'wsprnet_to_csv      ${WSPRNET_HTML_SPOT_FILE} ${WSPRNET_CSV_SPOT_FILE} ${scrape_start_seconds}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 2 "Got csv ${WSPRNET_CSV_SPOT_FILE}, append azi information into ${WSPRNET_CSV_SPOT_AZI_FILE}"
    wsprnet_add_azi     ${WSPRNET_CSV_SPOT_FILE}  ${WSPRNET_CSV_SPOT_AZI_FILE}
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'wsprnet_add_azi     ${WSPRNET_CSV_SPOT_FILE}  ${WSPRNET_CSV_SPOT_AZI_FILE}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 2 "Created azi file ${WSPRNET_CSV_SPOT_AZI_FILE}" 

    wn_spots_batch_upload    ${WSPRNET_CSV_SPOT_AZI_FILE}
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'wn_spots_batch_upload    ${WSPRNET_CSV_SPOT_AZI_FILE}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 2 "Recorded spots to TS database"

    if [[ -x ${CLICKHOUSE_IMPORT_CMD} ]]; then
        ( cd ${CLICKHOUSE_IMPORT_CMD_DIR}; ${CLICKHOUSE_IMPORT_CMD} ${WSPRNET_CSV_SPOT_FILE} )
        wd_logger 2 "Recorded spots to Clickhouse database"
    fi
    wd_logger 2 "Done in $PWD"
    return  ${ret_code}
}

function wsprnet_scrape_daemon() {
    local scraper_root_dir=$1

    mkdir -p ${scraper_root_dir}
    cd ${scraper_root_dir}

    wd_logger 1 "Starting and scrapes will be attempted at second offsets: ${WSPRNET_OFFSET_SECS}"
    setup_verbosity_traps
    while true; do
        if ! api_scrape_once ; then
	    wd_logger 1 "Scrape failed.  Sleep and try again later"
	fi
        api_wait_until_next_offset
    done
}

function kill_wsprnet_scrape_daemon() 
{
    local scraper_root_dir=$1
    local scraper_daemon_function_name="wsprnet_scrape_daemon"

    wd_logger 2 "Kill with: 'kill_daemon ${scraper_daemon_function_name}  ${scraper_root_dir}'"
    kill_daemon         ${scraper_daemon_function_name}  ${scraper_root_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "Killed the ${scraper_daemon_function_name} running in '${scraper_root_dir}'"
    else
        wd_logger -1 "The '${scraper_daemon_function_name}' was not running in '${scraper_root_dir}'"
    fi
}

function get_status_wsprnet_scrape_daemon() 
{
    local scraper_root_dir=$1
    local scraper_daemon_function_name="wsprnet_scrape_daemon"

    wd_logger 2 "Get status with: 'get_status_of_daemon ${scraper_daemon_function_name}  ${scraper_root_dir}'"
    get_status_of_daemon  ${scraper_daemon_function_name}  ${scraper_root_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "The ${scraper_daemon_function_name} is running in  '${scraper_root_dir}'"
    else
        wd_logger -1 "The ${scraper_daemon_function_name} is not running in '${scraper_root_dir}'"
    fi
    return ${ret_code}
}

##########  Gap filling daemon ###########

declare GAP_POLL_SECS=5                             ### How often to look for new gap report files
declare GAP_PROCESSED_LOG_FILE=gaps_processed.log   ### Log our processing acts here
declare GAP_PROCESSED_LOG_MAX_BYTES=100000          ### Limit this log size
declare GAP_MIN_AGE_SECS=20      ### Wait 5 minutes before asking other WDs for spots in gap

function wsprnet_gap_daemon()
{
    wd_logger 1 "Starting in ${PWD}"
    mkdir -p ${SCRAPER_ROOT_DIR}/gaps.d
    local tmp_ts_csv_file=${WSPRNET_SCRAPER_TMP_PATH}/missing_spots.csv
    while true; do
        local gap_files_list=()
        while [[ ! -d ${SCRAPER_ROOT_DIR}/gaps.d ]] ; do
            wd_logger 1 "There is no ${SCRAPER_ROOT_DIR}/gaps.d directory, so sleep ${GAP_POLL_SECS}"
            wd_sleep ${GAP_POLL_SECS}
        done
        wd_logger 1 "Waiting for gap report files to appear in ${SCRAPER_ROOT_DIR}/gaps.d"
        while gap_files_list=( $(find ${SCRAPER_ROOT_DIR}/gaps.d -type f) ) && [[ ${#gap_files_list[@]} -eq 0 ]] ; do
            wd_logger 2 "Found no gap files, so sleep ${GAP_POLL_SECS}"
            wd_sleep ${GAP_POLL_SECS}
        done
        wd_logger 1 "Found ${#gap_files_list[@]} new gap reports"
        local aged_files_list=()
        local current_epoch=$(printf "%(%s)T" -1 )
        local oldest_gap_file_age=0
        local gap_file
        for gap_file in ${gap_files_list[@]}; do
            local gap_file_epoch=$( ${GET_FILE_MOD_TIME_CMD} ${gap_file} )
            local gap_file_age=$(( current_epoch - gap_file_epoch ))
            if [[ ${gap_file_age} -lt ${GAP_MIN_AGE_SECS} ]]; then
                wd_logger 1 "Gap file ${gap_file} age is ${gap_file_age} seconds.  Wait until it is ${GAP_MIN_AGE_SECS} seconds old before processing it"
                if [[ ${gap_file_age} -gt ${oldest_gap_file_age} ]]; then
                    wd_logger 1 "Gap file ${gap_file} age ${gap_file_age} is older than oldest gap of ${gap_file_age} second, so remember it"
                    oldest_gap_file_age=${gap_file_age}
                fi
            else
                wd_logger 1 "Gap file ${gap_file} age is ${gap_file_age} seconds, so process it"
                aged_files_list+=( ${gap_file} )
            fi
        done
        if [[ ${#aged_files_list[@]} -eq 0 ]]; then
            local gap_sleep_seconds=$(( GAP_MIN_AGE_SECS - oldest_gap_file_age ))
            wd_logger 1 "Found no gap files old enough to be processed.  The oldest gap file is ${oldest_gap_file_age}, so sleep ${gap_sleep_seconds} until it will be ready to be processed"
            wd_sleep ${gap_sleep_seconds}
            continue
        fi
        wd_logger 1 "Found ${#aged_files_list[@]} gap reports old enough to be ready for processing"
        for gap_file in ${aged_files_list[@]}; do
            local gap_line_list=( $(< ${gap_file}) )
            if [[ ${#gap_line_list[@]} -ne 3 ]]; then
                wd_logger 1 "ERROR: got gap file ${gap_file} with invalid line: $(< ${gap_file})"
                wd_rm ${gap_file}
                continue
            fi
            local gap_report_epoch=${gap_line_list[0]}
            local gap_seq_start=${gap_line_list[1]}
            local gap_seq_end=${gap_line_list[2]}
            local gap_count=$(( gap_seq_end - gap_seq_start ))
            wd_logger 1 "$(printf "Attmept to fill gap reported at ${WD_TIME_FMT} of ${gap_count} spots from ${gap_seq_start} to ${gap_seq_end}" ${gap_report_epoch})"

            local psql_response=$(PGPASSWORD=${GAP_FILLER_TS_PASSWORD}  psql -U wdread -h localhost -p 5432 -d wsprnet -c "\COPY (SELECT * FROM spots where \"Spotnum\" > ${gap_seq_start}  and \"Spotnum\" < ${gap_seq_end} ) TO ${tmp_ts_csv_file} DELIMITER ',' CSV")
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: psql query of localhost failed when verifying that gap file spots are really missing from the local TS DB"
            else
                local psql_copy_count=$(awk '/COPY/{print $2}' <<< "${psql_response}")
                local tmp_csv_file_count=$(wc -l < ${tmp_ts_csv_file})
                if [[ ${psql_copy_count} -ne 0 ]]; then
                    wd_logger 1 "ERROR: in local TS DB found ${psql_copy_count} spots in the gap.  Expecting 0 spots"
                fi
            fi

            local host
            for host in ${GAP_FILLER_HOST_LIST[@]}; do
                wd_logger 1 "Querying ${host} for missing spots"
                local psql_response=$(PGPASSWORD=${GAP_FILLER_TS_PASSWORD}  psql -U wdread -h ${host} -p 5432 -d wsprnet -c "\COPY (SELECT * FROM spots where \"Spotnum\" > ${gap_seq_start}  and \"Spotnum\" < ${gap_seq_end} ) TO ${tmp_ts_csv_file} DELIMITER ',' CSV")
                local rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: psql query of ${host} failed"
                else
                    local psql_copy_count=$(awk '/COPY/{print $2}' <<< "${psql_response}")
                    local tmp_csv_file_count=$(wc -l < ${tmp_ts_csv_file})
                    if [[ ${psql_copy_count} -ne ${tmp_csv_file_count} ]]; then
                        wd_logger 1 "ERROR: psql ${host} asked for the ${gap_count} missing spots from ${gap_seq_start} to ${gap_seq_end}, but psql response ${psql_copy_count} doesn't equal the number of lines {tmp_csv_file_count} in the csv file"
                    fi
                    if [[ ${psql_copy_count} -eq 0 ]]; then
                        wd_logger 1 "psql ${host} asked for the ${gap_count} missing spots from ${gap_seq_start} to ${gap_seq_end} but got zero spot lines"
                    else
                        wd_logger 1 "psql ${host} asked for the ${gap_count} missing spots from ${gap_seq_start} to ${gap_seq_end} and got response of '${psql_response}' while csv file has ${tmp_csv_file_count} spot lines:\n$(< ${tmp_ts_csv_file})"
                    fi
                fi
            done
            printf "${WD_TIME_FMT}: ${gap_seq_start} to ${gap_seq_end} filled with ..." >> ${GAP_PROCESSED_LOG_FILE}
            truncate_file ${GAP_PROCESSED_LOG_FILE} ${GAP_PROCESSED_LOG_MAX_BYTES}
            wd_rm ${gap_file}
        done
    done
}
    
function kill_wsprnet_gap_daemon()
{
    wd_logger 2 "Kill the wsprnet_gap_daemon by executing: 'kill_daemon wsprnet_gap_daemon ${SCRAPER_ROOT_DIR}'"
    ### Kill the watchdog
    kill_daemon  wsprnet_gap_daemon ${SCRAPER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "Killed the daemon 'wsprnet_gap_daemon' running in '${SCRAPER_ROOT_DIR}'"
    else
        wd_logger -1 "The 'wsprnet_gap_daemon' was not running in '${SCRAPER_ROOT_DIR}'"
    fi
    return 0
}

function get_status_wsprnet_gap_daemon()
{
    get_status_of_daemon   wsprnet_gap_daemon  ${SCRAPER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "The wsprnet_gap_daemon is running in '${SCRAPER_ROOT_DIR}'"
    else
        wd_logger -1 "The wsprnet_gap_daemon is not running in '${SCRAPER_ROOT_DIR}'"
    fi
    return 0
}
