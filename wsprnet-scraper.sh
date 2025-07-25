#!/bin/bash

declare -r WSPRNET_SCRAPER_HOME_PATH="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"   ### Where to find the .sh, .conf and .awk files
declare -r WSPRNET_SCRAPER_TMP_PATH=${WSPRDAEMON_TMP_DIR}/scraper
mkdir -p ${WSPRNET_SCRAPER_TMP_PATH}
declare -r WSPRNET_HTML_SPOT_FILE=${WSPRNET_SCRAPER_TMP_PATH}/wsprnet_spots.html

################### Code which gets spots from wsprnet.org using its API and records them into our TS 'wsprnet' database table 'spots'  ##########################################################
function record_wsprnet_spots_in_clickhouse() {
    local csv_file=$1
    local ret_code

    wd_logger 2 "Record ${csv_file} to the Clickhouse wsprnet.rx table"

    clickhouse-client --host=localhost --port=9000 --user=wsprdaemon --password=hdt4txpCGYUkScM5pqcZxngdSsNOYiLX --database=wspr --query="INSERT INTO rx FORMAT CSV" < ${csv_file}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR: 'clickhouse-client --host=localhost --port=9000 --user=wsprdaemon --password=hdt4txpCGYUkScM5pqcZxngdSsNOYiLX --query='INSERT INTO wspr_data FORMAT CSV' <  ${csv_file} => ${ret_code}"
    else
        wd_logger 2 "Spot files were recorded by: 'clickhouse-client --host=localhost --port=9000 --user=wsprdaemon --password=hdt4txpCGYUkScM5pqcZxngdSsNOYiLX --query='INSERT INTO wspr_data FORMAT CSV' <  ${csv_file}"
    fi
    return ${ret_code}
}

declare WSPRNET_SESSION_ID_FILE=${WSPRNET_SCRAPER_TMP_PATH}/wsprnet_session_info.html

function wpsrnet_login() {
    wd_logger 1 "Executing curl to login"
    local ret_code

    if [[ -z "${WSPRNET_USER-}" ]]; then
        wd_logger 1 "ERROR: WSPRNET_USER is not declared in WD.conf"
        echo ${force_abort}
    fi
    if [[ -z "${WSPRNET_PASSWORD-}" ]]; then
        wd_logger 1 "ERROR: WSPRNET_PASSWORD is not declared in WD.conf"
        echo ${force_abort}
    fi
    timeout 60 curl -s -d '{"name":"'${WSPRNET_USER}'", "pass":"'${WSPRNET_PASSWORD}'"}' -H "Content-Type: application/json" -X POST http://www.wsprnet.org/drupal/rest/user/login > ${WSPRNET_SESSION_ID_FILE}
    ret_code=$? ; if (( ret_code == 0 )) ; then
         wd_logger 1 "wsprnet.org login for wsprnet user '${WSPRNET_USER}' with password '${WSPRNET_PASSWORD}' was successful, so ID has been saved in file ${WSPRNET_SESSION_ID_FILE}:\n$(< ${WSPRNET_SESSION_ID_FILE})"
         return 0
    fi
    ### curl returned an error
    local sessid=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/sessid/s/^.*://p' | sed 's/"//g')
    local session_name=$(cat ${WSPRNET_SESSION_ID_FILE} | tr , '\n' | sed -n '/session_name/s/^.*://p' | sed 's/"//g')
    if [[ -z "${sessid}" ]] || [[ -z "${session_name}" ]]; then
        wd_logger 1 "ERROR: curl login failed => ${ret_code}:\n$(<${WSPRNET_SESSION_ID_FILE})"
        wd_logger 1 "ERROR: failed to extract sessid=${sessid} and/or session_name${session_name}"
    else
        wd_logger 1 "ERROR: curl returned error ${ret_code}, but we could extract sessid=${sessid} and session_name=${session_name} from the html"
    fi
    return ${ret_code}
}

declare WSPRNET_LAST_SPOTNUM=0
declare CLICKHOUSE_CONF_FILE_PATH="${WSPRNET_SCRAPER_HOME_PATH}/clickhouse.conf"

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
    wd_logger 2 "Got wsprnet session_token = '${session_token}'"
 
    ### If we have previously querried wsprnet.org and saved its spots in our local Clickhouse wsrpnet.rx database, then ask wsprnet.org for spots after the wsprnet-assigned 64 bit id of that spot
    if (( WSPRNET_LAST_SPOTNUM == 0 )); then
        wd_logger 1 "Making first query from wsprnet.org, so get the WN spot number of the most recent spot in our local CH database, if any"
        local clickhouse_output_file=${WSPRNET_SCRAPER_TMP_PATH}/clickhouse.out
        clickhouse-client --host=${CLICKHOUSE_HOST} --port=9000 --user=${CLICKHOUSE_USER} --password=${CLICKHOUSE_PASSWORD} --query "SELECT id FROM wspr.rx ORDER BY id DESC LIMIT 1" > ${clickhouse_output_file}
        ret_code=$? ; if (( ret_code )); then
            wd_logger 1 "ERROR: 'clickhouse-client --host=${CLICKHOUSE_HOST} --port=9000 --user=${CLICKHOUSE_USER} --password=${CLICKHOUSE_PASSWORD} --query 'SELECT id FROM wsprnet.rx ORDER BY id DESC LIMIT 1'' > ${ret_code}"
            echo ${force_abort}
        fi
        local last_spotnum=$(< ${clickhouse_output_file} )
        if [[ -z "${last_spotnum}" ]] || (( last_spotnum == 0 )); then
            wd_logger 1 "ERROR: At startup got no or invalid spot num '${last_spotnum}' from Clickhouse, so use last_spotnum='0'"
            last_spotnum=0
        else
            wd_logger 1 "At startup using highest Spotnum ${last_spotnum} from TS, not 0"
        fi
        WSPRNET_LAST_SPOTNUM=${last_spotnum}   ### Remember this spot id for the next query
    fi

    wd_logger 2 "Starting curl download for spotnum_start=${WSPRNET_LAST_SPOTNUM}"
    local start_seconds=${SECONDS}
    local curl_str="'{spotnum_start:\"${WSPRNET_LAST_SPOTNUM}\",band:\"All\",callsign:\"\",reporter:\"\",exclude_special:\"1\"}'"
    curl -s --limit-rate ${WSPRNET_SCRAPER_MAX_BYTES_PER_SECOND-20000} -m ${WSPRNET_CURL_TIMEOUT-120} -b "${session_token}" -H "Content-Type: application/json" -X POST -d ${curl_str} \
               "http://www.wsprnet.org/drupal/wsprnet/spots/json?band=All&spotnum_start=${WSPRNET_LAST_SPOTNUM}&exclude_special=0" > ${html_spot_file}
    ret_code=$?
    local end_seconds=${SECONDS}
    local curl_seconds=$(( end_seconds - start_seconds))
    if (( ret_code )); then
        wd_logger 1 "ERROR: curl download failed => ${ret_code} after ${curl_seconds} seconds"
    else
        if grep -q "You are not authorized to access this page." ${html_spot_file}; then
            local curl_command_line="curl -s --limit-rate ${WSPRNET_SCRAPER_MAX_BYTES_PER_SECOND-20000} -m ${WSPRNET_CURL_TIMEOUT-120} -b \"${session_token}\" -H \"Content-Type: application/json\" -X POST -d ${curl_str} \
               \"http://www.wsprnet.org/drupal/wsprnet/spots/json?band=All&spotnum_start=${WSPRNET_LAST_SPOTNUM}&exclude_special=0\""
                           wd_logger 1 "ERROR: the curl from wsprnet.org succeeded, but the response file ${html_spot_file} includes 'You are not authorized to access this page'.  So there are no spots reported:\n${curl_command_line}=>\n$(< ${html_spot_file})"
            rm ${WSPRNET_SESSION_ID_FILE}
            ret_code=1
        else
            if ! grep -q "Spotnum" ${html_spot_file} ; then
                wd_logger 1 "WARNING: ${html_spot_file} contains no spots"
                ret_code=2
            else
                local download_size=$( cat ${html_spot_file} | wc -c)
                wd_logger 1 "curl downloaded ${download_size} bytes of spot info in ${curl_seconds} seconds"
            fi
        fi
    fi
    return ${ret_code}
}

### Convert the html we get from wsprnet to a csv file
### The html records are in the order Spotnum,Date,Reporter,ReporterGrid,dB,Mhz,CallSign,Grid,Power,Drift,distance,azimuth,Band,version,code
### The html records are in the order  1       2     3         4         5  6     7       8     9    10      11      12     13     14    15

declare SED_TMP_CSV_FILE_PATH="${WSPRNET_SCRAPER_TMP_PATH}/sed-lines.txt"
declare JQ_TMP_CSV_FILE_PATH="${WSPRNET_SCRAPER_TMP_PATH}/jq-lines.txt"
declare SHOW_SPOTS_OLDER_THAN_MINUTES_DEFAULT=30       ## $(( 60 * 24 * 7 )) change to this if want to print out spots only older than 7 days
declare SHOW_SPOTS_OLDER_THAN_MINUTES=${SHOW_SPOTS_OLDER_THAN_MINUTES-${SHOW_SPOTS_OLDER_THAN_MINUTES_DEFAULT}}

function wsprnet_html_to_csv() {
    local wsprnet_html_spot_file=$1
    local wsprnet_csv_spot_file=$2
    local scrape_start_seconds=$3
    local rc

    jq -r '  sort_by(.Spotnum | tonumber)
           | .[] 
           | [.Spotnum, .Date, .Reporter, .ReporterGrid, .dB, .MHz, .CallSign, .Grid, .Power, .Drift, .distance, .azimuth, .Band, .version, .code] 
           | join(",")' "${wsprnet_html_spot_file}" > ${JQ_TMP_CSV_FILE_PATH}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'jq ... ${wsprnet_html_spot_file}' => ${rc}"
        return ${rc}
    fi
    local sorted_lines_array
    mapfile -t sorted_lines_array < ${JQ_TMP_CSV_FILE_PATH}
    
    ### See if there is a gap between the last spot of the previous scrape or the last spot stored in our TS data and the first spot of this scrape
    local first_spot_array=(${sorted_lines_array[0]//,/ })
    local last_spot_array=(${sorted_lines_array[-1]//,/ })
    local scrape_seconds=$(( ${SECONDS} - ${scrape_start_seconds} ))

    wd_logger 1 "$(printf "In %3d seconds got scrape with %4d spots first sequence_num spot: ${first_spot_array[0]}/${first_spot_array[1]}, Last spot: ${last_spot_array[0]}/${last_spot_array[1]}" ${scrape_seconds} "${#sorted_lines_array[@]}" )"

    local spot_num_gap=$(( ${first_spot_array[0]} - ${WSPRNET_LAST_SPOTNUM} ))
    if [[ ${WSPRNET_LAST_SPOTNUM} -ne 0 ]] && [[ ${spot_num_gap} -gt 1 ]]; then
        local first_missing_seq=$(( ${WSPRNET_LAST_SPOTNUM} + 1 ))
        local last_missing_seq=$((  ${first_spot_array[0]}  - 1 ))
        local missing_seq_count=$(( last_missing_seq - first_missing_seq + 1 ))
        wd_logger 1 "$(printf "Found gap of %4d spotnums between last spot #${WSPRNET_LAST_SPOTNUM} and first spot #${first_spot_array[0]} of this scrape" "${missing_seq_count}")"
        queue_gap_file ${first_missing_seq} ${last_missing_seq}
    fi
    ### Remember the current last spot for the next call to this function
    WSPRNET_LAST_SPOTNUM=${last_spot_array[0]}

    ### Check for gaps within this new scrape
    local total_gaps=0
    local total_missing=0
    local max_gap_size=0
    local expected_seq=0
    for (( index=0; index < ${#sorted_lines_array[@]}; ++index )); do
        local spot_line_list=( ${sorted_lines_array[index]//,/ } )
        local got_seq=${spot_line_list[0]}
        local next_seq=$(( got_seq + 1 ))
        if (( index == 0 )); then
            expected_seq=${next_seq}
        else
            local gap_size=$(( got_seq - expected_seq ))
            if (( gap_size == 0 )); then
                wd_logger 2 "This spot's ID ${got_seq} is one greater than the previous spot, so there is no gap"
            else
               total_gaps=$(( total_gaps + 1 ))
               total_missing=$(( total_missing + gap_size ))
               if (( gap_size > max_gap_size )); then
                   max_gap_size=${gap_size}
               fi
               wd_logger 2 "$(printf "Found gap of %3d at index %4d:  Expected ${expected_seq}, got ${got_seq}" "${gap_size}" "${index}")"
               local first_missing_seq=${expected_seq}
               local last_missing_seq=$(( got_seq - 1 ))
               queue_gap_file ${first_missing_seq} ${last_missing_seq}
           fi
           expected_seq=${next_seq}
        fi
    done
    if (( verbosity && max_gap_size && WSPRNET_LAST_SPOTNUM )); then
        wd_logger 1 "Found ${total_gaps} gaps missing a total of ${total_missing} spots. The max gap was of ${max_gap_size} spot numbers"
    fi

    ### Find the number of different WSPR cycles found in the spots file
    local epochs_list=( $(awk -F , '{print $2}' ${JQ_TMP_CSV_FILE_PATH}| sort -u) )
    if (( ${#epochs_list[@]} == 1 )); then
        wd_logger 1 "Found all spots are for epoch ${epochs_list[0]}"
    else
        local minutes_span=$(( (${epochs_list[-1]} - ${epochs_list[0]}) / 60 ))
        wd_logger 1 "Found spots which span ${minutes_span} minutes: ${epochs_list[*]:0:10}.."
    fi

    ### Create the return csv file which is sorted by spot time
    rm -f ${wsprnet_csv_spot_file}
    for spot_epoch in ${epochs_list[@]}; do
        ### Filter and convert spots repored by the wsprnet.org API into a csv file which will be recorded in the CH database
        ### awk prepends a date field to each spot line which is derived from the epoch field #2
        awk -v spot_epoch=${spot_epoch} -f ${WSPRDAEMON_ROOT_DIR}/wsprnet-scraper.awk  ${JQ_TMP_CSV_FILE_PATH} > ${WSPRNET_SCRAPER_TMP_PATH}/filtered_spots.csv
        grep -v "^20" ${WSPRNET_SCRAPER_TMP_PATH}/filtered_spots.csv > ${WSPRNET_SCRAPER_TMP_PATH}/bad_spots.txt 
        if [[ -s ${WSPRNET_SCRAPER_TMP_PATH}/bad_spots.txt ]]; then
            wd_logger 1 "Found invalid spots:\n$(< ${WSPRNET_SCRAPER_TMP_PATH}/bad_spots.txt)"
        fi
        grep    "^20" ${WSPRNET_SCRAPER_TMP_PATH}/filtered_spots.csv > ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv
        if [[ -s ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv ]]; then
            local spots_to_add_count=$(wc -l < ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv)
            wd_logger 1 "$(printf "adding %4d spots at epoch %d == '%(%Y-%m-%d:%H:%M)T'"  ${spots_to_add_count}  ${spot_epoch} ${spot_epoch})"
            local this_epcoch_age_minutes=$(( (${epochs_list[-1]} - ${spot_epoch}) / 60 ))
            if (( this_epcoch_age_minutes > SHOW_SPOTS_OLDER_THAN_MINUTES )); then
                wd_logger 1 "Adding spots more than ${SHOW_SPOTS_OLDER_THAN_MINUTES} minutes old:\n$(head -n 4 ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv)"
            fi
            cat ${WSPRNET_SCRAPER_TMP_PATH}/fixed_spots.csv  >> ${wsprnet_csv_spot_file}
        fi
    done

    local csv_spotnum_count=$( wc -l < ${wsprnet_csv_spot_file})
    if (( csv_spotnum_count != ${#sorted_lines_array[@]} )); then
        wd_logger 1 "ERROR: found ${#sorted_lines_array[@]} in our plaintext of the html file, but only ${csv_spotnum_count} is the csv version of it"
        return 1
    fi
    wd_logger 2 "Created the csv file ${wsprnet_csv_spot_file} with ${csv_spotnum_count} spot lines"
    return 0
}

### Create ${WSPRNET_OFFSET_SECS}, a string of offsets in seconds from the start of an even minute when the scraper should execute the wsprnet API to get the latest spots
### This variable is used by the wait_until_next_second_offset_in_wspr_cycle() to determine how long to sleep
declare WSPRNET_OFFSET_FIRST_SEC=55
declare WSPRNET_OFFSET_GAP=30
declare WSPRNET_OFFSET_SECS=""
offset=${WSPRNET_OFFSET_FIRST_SEC}
while [[ ${offset} -lt 120 ]]; do
   WSPRNET_OFFSET_SECS="${WSPRNET_OFFSET_SECS} ${offset}"
   offset=$(( offset + WSPRNET_OFFSET_GAP ))
done

function wait_until_next_second_offset_in_wspr_cycle() {
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
declare WSPRNET_CSV_TO_CLICKHOUSE_CSV_CMD=${WSPRNET_SCRAPER_HOME_PATH}/wsprnet-csv-to-clickhouse-csv.py

### Takes a csv spot file created from the html returned by the wpsrnet API and creates a csv file with azimuth fields which is recorded in the CH database
function convert-wsprnet-csv-to-clickhouse-csv() {
    local wsprnet_csv_file_path=$1
    local clickhouse_csv_file_path=$2
    local ret_code

    wd_logger 2 "process ${wsprnet_csv_file_path} to create ${clickhouse_csv_file_path}"
    if [[ ! -f ${wsprnet_csv_file_path} ]]; then
        wd_logger 1 "ERROR: no wsprnet_csv_file_path=${wsprnet_csv_file_path}"
        echo ${force_abort}
    fi

    if [[ ! -x ${WSPRNET_CSV_TO_CLICKHOUSE_CSV_CMD} ]]; then
        wd_logger 1 "ERROR: can't find expected executable python file ${WSPRNET_CSV_TO_CLICKHOUSE_CSV_CMD}"
        echo ${force_abort}
    fi
    python3 ${WSPRNET_CSV_TO_CLICKHOUSE_CSV_CMD} --input ${wsprnet_csv_file_path} --output ${clickhouse_csv_file_path}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR:  'python3 ${WSPRNET_CSV_TO_CLICKHOUSE_CSV_CMD} --input ${wsprnet_csv_file_path} --output ${clickhouse_csv_file_path}' => ${ret_code}"
    else
        wd_logger 2 "python3 ${WSPRNET_CSV_TO_CLICKHOUSE_CSV_CMD} ${wsprnet_csv_file_path} ${clickhouse_csv_file_path} => ${ret_code}"
    fi
    return ${ret_code}
}

function scrape_wsprnet() {
    local scrape_start_seconds=${SECONDS}
    local ret_code

    wd_logger 2 "Starting in $PWD"
    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]]; then
        wd_logger 1 "Logging into wsprnet"
        wpsrnet_login
        ret_code=$? ; if (( ret_code )); then
            wd_logger 1 "ERROR: wpsrnet_login returned error => ${ret_code}"
            return ${ret_code}
        fi
    fi
    if [[ ! -f ${WSPRNET_SESSION_ID_FILE} ]]; then
         wd_logger 1 "ERROR: wpsrnet_login was successful, but it produced no ${WSPRNET_SESSION_ID_FILE}"
         return 1
    fi
    wpsrnet_get_spots ${WSPRNET_HTML_SPOT_FILE}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR: wpsrnet_get_spots() returned error => ${ret_code}."
        return ${ret_code}
    fi
    wd_logger 2 "Got spots in html file  ${WSPRNET_HTML_SPOT_FILE}, translate into ${WSPRNET_CSV_SPOT_FILE}"
    wsprnet_html_to_csv      ${WSPRNET_HTML_SPOT_FILE} ${WSPRNET_CSV_SPOT_FILE} ${scrape_start_seconds}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR: 'wsprnet_html_to_csv      ${WSPRNET_HTML_SPOT_FILE} ${WSPRNET_CSV_SPOT_FILE} ${scrape_start_seconds}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 2 "Got csv ${WSPRNET_CSV_SPOT_FILE}, append azi information to each spot and store them in ${WSPRNET_CSV_SPOT_AZI_FILE}"
    convert-wsprnet-csv-to-clickhouse-csv     ${WSPRNET_CSV_SPOT_FILE}  ${WSPRNET_CSV_SPOT_AZI_FILE}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR: 'convert-wsprnet-csv-to-clickhouse-csv     ${WSPRNET_CSV_SPOT_FILE}  ${WSPRNET_CSV_SPOT_AZI_FILE}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 2 "Created spots with azi file ready for Clickhouse: ${WSPRNET_CSV_SPOT_AZI_FILE}" 

    record_wsprnet_spots_in_clickhouse ${WSPRNET_CSV_SPOT_AZI_FILE}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR: 'record_wsprnet_spots_in_clickhouse ${WSPRNET_CSV_SPOT_AZI_FILE}' => ${ret_code}"
    else
        wd_logger 2 "Recorded spots into the Clickhouse database"
    fi
    return  ${ret_code}
}

function setup_clickhouse_wsprnet_tables()
{
    local rc

     clickhouse-client -u ${CLICKHOUSE_USER} --password ${CLICKHOUSE_PASSWORD} --host ${CLICKHOUSE_HOST} --query="SELECT 1 FROM system.databases WHERE name = 'wspr'" | grep -q 1
     rc=$? ; if (( rc )); then
         wd_logger 1 "Creating the 'wspr' database"
         clickhouse-client -u ${CLICKHOUSE_USER} --password ${CLICKHOUSE_PASSWORD} --host ${CLICKHOUSE_HOST} --query="CREATE DATABASE wspr"
         rc=$? ; if (( rc )); then
             wd_logger 1 "Failed to create missing 'wspr' database"
             echo ${force_abort}
         fi
          wd_logger 1 "Created the missing 'wspr' database"
     fi
     clickhouse-client -u ${CLICKHOUSE_USER} --password ${CLICKHOUSE_PASSWORD} --host ${CLICKHOUSE_HOST} --query "
CREATE TABLE IF NOT EXISTS wspr.rx (
    id           UInt64                      CODEC(Delta(8), ZSTD(1)),
    time         DateTime                    CODEC(Delta(4), ZSTD(1)),
    band         Int16                       CODEC(T64, ZSTD(1)),
    rx_sign      LowCardinality(String),
    rx_lat       Float32                     CODEC(ZSTD(1)),
    rx_lon       Float32                     CODEC(ZSTD(1)),
    rx_loc       LowCardinality(String),
    tx_sign      LowCardinality(String),
    tx_lat       Float32                     CODEC(ZSTD(1)),
    tx_lon       Float32                     CODEC(ZSTD(1)),
    tx_loc       LowCardinality(String),
    distance     UInt16                      CODEC(T64, ZSTD(1)),
    azimuth      UInt16                      CODEC(T64, ZSTD(1)),
    rx_azimuth   UInt16                      CODEC(T64, ZSTD(1)),
    frequency    UInt32                      CODEC(T64, ZSTD(1)),
    power        Int8                        CODEC(T64, ZSTD(1)),
    snr          Int8                        CODEC(ZSTD(1)),
    drift        Int8                        CODEC(ZSTD(1)),
    version      LowCardinality(String),
    code         Int8
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(time)
ORDER BY (time, id)
SETTINGS index_granularity = 8192;
"
     rc=$? ; if (( rc )); then
         wd_logger 1 "ERROR: clickhouse-client ... 'CREATE TABLE IF NOT EXISTS' => ${rc}"
     else
         wd_logger 1 "clickhouse-client ... 'CREATE TABLE IF NOT EXISTS' was successful"
     fi
     return ${rc}
}

function wsprnet_scrape_daemon() {
    local scraper_root_dir=$1

    mkdir -p ${scraper_root_dir}
    cd ${scraper_root_dir}

    wd_logger 1 "Starting and scrapes will be attempted at second offsets: ${WSPRNET_OFFSET_SECS}"
    setup_verbosity_traps
    setup_clickhouse_wsprnet_tables

    while true; do
        if ! scrape_wsprnet ; then
	    wd_logger 1 "Scrape failed.  Sleep and try again later"
	fi
        wait_until_next_second_offset_in_wspr_cycle
    done
}

function kill_wsprnet_scrape_daemon() 
{
    local scraper_root_dir=$1
    local scraper_daemon_function_name="wsprnet_scrape_daemon"
    local ret_code

    wd_logger 2 "Kill with: 'kill_daemon ${scraper_daemon_function_name}  ${scraper_root_dir}'"
    kill_daemon         ${scraper_daemon_function_name}  ${scraper_root_dir}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "The '${scraper_daemon_function_name}' was not running in '${scraper_root_dir}'"
    else
        wd_logger 1 "Killed the ${scraper_daemon_function_name} running in '${scraper_root_dir}'"
    fi
}

function get_status_wsprnet_scrape_daemon() 
{
    local scraper_root_dir=$1
    local scraper_daemon_function_name="wsprnet_scrape_daemon"
    local ret_code

    wd_logger 2 "Get status with: 'get_status_of_daemon ${scraper_daemon_function_name}  ${scraper_root_dir}'"
    get_status_of_daemon  ${scraper_daemon_function_name}  ${scraper_root_dir}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "The ${scraper_daemon_function_name} is not running in '${scraper_root_dir}'"
    else
        wd_logger 2 "The ${scraper_daemon_function_name} is running in  '${scraper_root_dir}'"
    fi
    return ${ret_code}
}

##########  Gap filling daemon ###########

declare GAP_POLL_SECS=5                                                  ### How often to look for new gap report files
declare GAP_PROCESSED_LOG_MAX_BYTES=100000                               ### Limit this log size
declare GAP_MIN_AGE_SECS=20                                              ### Wait 5 minutes before asking other WDs for spots in gap
declare GAP_MAX_REQUEST=50000                                            ### Ask for no more than this number of spots per download

### Creates a file which records a gap between scrapes or within a scrape.  The scrape_gap_filler_deemon() will attempt to fill those gaps by quering the other WD servers
function queue_gap_file() {
    local first_missing_seq=$1
    local last_missing_seq=$2
    local gap_dir_path=${SCRAPER_ROOT_DIR}/gaps
    mkdir -p ${gap_dir_path}

    local first_seq=${first_missing_seq}
    local last_seq
    local gap_request_size

    while gap_request_size=$(( last_missing_seq - first_seq + 1 )) && [[ ${gap_request_size} -gt 0 ]] ; do
        if [[ ${gap_request_size} -le ${GAP_MAX_REQUEST} ]] ; then
            last_seq=${last_missing_seq}
        else
            last_seq=$(( ${first_seq} + ${GAP_MAX_REQUEST} - 1 ))
        fi
        local gap_file_path=${gap_dir_path}/${first_seq}.log
        printf "%(%s)T %d %d\n" -1 ${first_seq} ${last_seq}  > ${gap_file_path}
        wd_logger 2 "Queued gap reqeust file ${gap_file_path} which is for  ${gap_request_size} spots from seq_num ${first_seq} to ${last_seq}"
        first_seq=$(( ${last_seq} + 1 ))
    done
}

function wsprnet_gap_daemon()
{
    wd_logger 1 "Starting in ${PWD}"
    mkdir -p ${SCRAPER_ROOT_DIR}/gaps
    local tmp_ts_csv_file=${WSPRNET_SCRAPER_TMP_PATH}/missing_spots.csv
    while true; do
        local gap_files_list=()
        while [[ ! -d ${SCRAPER_ROOT_DIR}/gaps ]] ; do
            wd_logger 1 "There is no ${SCRAPER_ROOT_DIR}/gaps directory, so sleep ${GAP_POLL_SECS}"
            wd_sleep ${GAP_POLL_SECS}
        done
        wd_logger 1 "Waiting for gap report files to appear in ${SCRAPER_ROOT_DIR}/gaps"
        ### sort the output of find in numeric (i.e. sequence number) order.  Thus we will fill gaps from lowest sequence to highest
        while gap_files_list=( $(find ${SCRAPER_ROOT_DIR}/gaps -type f | sort -t / -k 2,2n ) ) && [[ ${#gap_files_list[@]} -eq 0 ]] ; do
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
                    wd_logger 2 "Gap file ${gap_file} age ${gap_file_age} is older than oldest gap of ${gap_file_age} second, so remember it"
                    oldest_gap_file_age=${gap_file_age}
                fi
            else
                wd_logger 1 "Gap file ${gap_file} age is ${gap_file_age} seconds, so process it"
                aged_files_list+=( ${gap_file} )
            fi
        done
        if [[ ${#aged_files_list[@]} -eq 0 ]]; then
            local gap_sleep_seconds=$(( GAP_MIN_AGE_SECS - oldest_gap_file_age ))
            wd_logger 1 "Found no gap files old enough to be processed.  The oldest gap file is ${oldest_gap_file_age} seconds old, so sleep ${gap_sleep_seconds} until it will be ready to be processed"
            wd_sleep ${gap_sleep_seconds}
            continue
        fi
        wd_logger 1 "Found ${#aged_files_list[@]} gap reports old enough to be ready for processing"
        for gap_file in ${aged_files_list[@]}; do
            local gap_filling_start_seconds=${SECONDS}
            local gap_line_list=( $(< ${gap_file}) )
            if [[ ${#gap_line_list[@]} -ne 3 ]]; then
                wd_logger 1 "ERROR: got gap file ${gap_file} with invalid line: $(< ${gap_file})"
                wd_rm ${gap_file}
                continue
            fi
            local gap_report_epoch=${gap_line_list[0]}
            local gap_seq_start=${gap_line_list[1]}
            local gap_seq_end=${gap_line_list[2]}
            local gap_count=$(( gap_seq_end - gap_seq_start + 1 ))
            wd_logger 1 "$(printf "Attempt to fill gap reported at ${WD_TIME_FMT} of ${gap_count} spots from ${gap_seq_start} to ${gap_seq_end}" ${gap_report_epoch})"

            local psql_response=$(PGPASSWORD=${TS_WN_RO_PASSWORD}  psql -h localhost -p ${TS_IP_PORT-5432} -U ${TS_WN_RO_USER} -d ${TS_WN_DB} -c "\COPY (SELECT * FROM spots where \"Spotnum\" >= ${gap_seq_start}  and \"Spotnum\" <= ${gap_seq_end} ) TO ${tmp_ts_csv_file} DELIMITER ',' CSV")
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

            local filled_count=0
            local host
            for host in ${GAP_FILLER_HOST_LIST[@]}; do
                wd_logger 1 "Querying ${host} for missing spots"
                local psql_response=$(PGPASSWORD=${TS_WN_RO_PASSWORD}  psql -h ${host} -p ${TS_IP_PORT-5432} -U ${TS_WN_RO_USER} -d ${TS_WN_DB} -c "\COPY (SELECT * FROM spots where \"Spotnum\" >= ${gap_seq_start}  and \"Spotnum\" <= ${gap_seq_end} ) TO ${tmp_ts_csv_file} DELIMITER ',' CSV")
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
                        wd_logger 1 "psql ${host} asked for the ${gap_count} missing spots from ${gap_seq_start} to ${gap_seq_end} but got zero spot lines in the response:\n${psql_response}"
                    else
                        ### Record the missing spots to local TS
                        sed -i 's/,$//' ${tmp_ts_csv_file}                         ### edit in place.  chops off the trailing ,
                        sort -t , -k 2,2n ${tmp_ts_csv_file} -o ${tmp_ts_csv_file}  ### sorts in place
                        wd_logger 1 "psql ${host} asked for the ${gap_count} missing spots from ${gap_seq_start} to ${gap_seq_end} and got response of '${psql_response}' while csv file has ${tmp_csv_file_count} spot lines:\n$(head -n 1 ${tmp_ts_csv_file}; echo ...; tail -n 1 ${tmp_ts_csv_file})"
                        record_wsprnet_spots_in_clickhouse ${tmp_ts_csv_file}
                        local rc=$?
                        if [[ ${rc} -ne 0 ]]; then
                            wd_logger 1 "ERROR: 'record_wsprnet_spots_in_clickhouse ${tmp_ts_csv_file}' => ${rc}, so try another WD"
                        else
                            wd_logger 1 "Recorded the ${psql_copy_count} spots of the ${gap_count} missing spots in a $(wc -c < ${tmp_ts_csv_file}) byte file. Don't try to find more on another WD"
                            filled_count=${psql_copy_count}
                            ### Record the missing spots to CH
                            if [[ -x ${CLICKHOUSE_IMPORT_CMD} ]]; then
                                ( cd ${CLICKHOUSE_IMPORT_CMD_DIR}; ${CLICKHOUSE_IMPORT_CMD} ${tmp_ts_csv_file} )
                                wd_logger 1 "Recorded spots to Clickhouse database"
                            else
                                wd_logger 1 "ERROR: can't find CLICKHOUSE_IMPORT_CMD '${CLICKHOUSE_IMPORT_CMD}'"
                            fi
                            break        ### Don't try to find gap spots on another WD
                        fi
                   fi
                fi
            done
            if [[ ${filled_count} -eq 0 ]]; then
                filled_count="no"
            fi
            local GAP_PROCESSED_LOG_FILE=${SCRAPER_ROOT_DIR}/gaps_processed.log    ### Log our processing acts here
            printf "${WD_TIME_FMT}: gap of ${gap_count} spots from seq ${gap_seq_start} to seq ${gap_seq_end} filled with ${filled_count} spots\n" -1  >> ${GAP_PROCESSED_LOG_FILE}
            truncate_file ${GAP_PROCESSED_LOG_FILE} ${GAP_PROCESSED_LOG_MAX_BYTES}
            wd_rm ${gap_file}
            wd_logger 1 "Finished processing gap file ${gap_file} in $(( ${SECONDS} - ${gap_filling_start_seconds} )) seconds"
        done
        wd_logger 1 "Finished processing all ready gap files"
    done
}
    
function kill_wsprnet_gap_daemon()
{
    local ret_code

    wd_logger 2 "Kill the wsprnet_gap_daemon by executing: 'kill_daemon wsprnet_gap_daemon ${SCRAPER_ROOT_DIR}'"
    ### Kill the watchdog
    kill_daemon  wsprnet_gap_daemon ${SCRAPER_ROOT_DIR}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "The 'wsprnet_gap_daemon' was not running in '${SCRAPER_ROOT_DIR}'"
    else
        wd_logger 1 "Killed the daemon 'wsprnet_gap_daemon' running in '${SCRAPER_ROOT_DIR}'"
    fi
    return 0
}

function get_status_wsprnet_gap_daemon()
{
    local ret_code

    get_status_of_daemon   wsprnet_gap_daemon  ${SCRAPER_ROOT_DIR}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "The wsprnet_gap_daemon is not running in '${SCRAPER_ROOT_DIR}'"
    else
        wd_logger 1 "The wsprnet_gap_daemon is running in '${SCRAPER_ROOT_DIR}'"
    fi
    return 0
}
