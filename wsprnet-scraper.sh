#!/bin/bash

declare WSPRNET_SCRAPER_PYTHON_CMD="${WSPRDAEMON_ROOT_DIR}/wsprnet_scraper.py"
declare WSPRNET_VENV_PATH="${WSPRDAEMON_ROOT_DIR}/venv"
declare WSPRNET_SCRAPER_HOME_PATH="${WSPRDAEMON_ROOT_DIR}/scraper"                ### Store session.json, .log and .pid files here
mkdir -p ${WSPRNET_SCRAPER_HOME_PATH}
declare WSPRNET_SESSION_FILE_PATH="${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_session.json"
declare WSPRNET_SCRAPER_LOG_FILE_PATH="${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_scrape_python_cmd.log"
declare WSPRNET_SCRAPER_PID_FILE_PATH="${WSPRNET_SCRAPER_HOME_PATH}/wsprnet_scrape_python_cmd.pid"

function wsprnet_scrape_daemon() {
    wd_logger 1 "Starting in $PWD"
    setup_verbosity_traps

    # Validate all required bash variables are defined
    local required_vars=(
        "WSPRNET_SCRAPER_PID_FILE_PATH"
        "WSPRNET_SCRAPER_PYTHON_CMD"
        "WSPRNET_SESSION_FILE_PATH"
        "WSPRNET_VENV_PATH"
        "CLICKHOUSE_DEFAULT_USER_PASSWORD"
        "CLICKHOUSE_WSPRNET_ADMIN_USER"
        "CLICKHOUSE_WSPRNET_ADMIN_PASSWORD"
        "CLICKHOUSE_WSPRNET_USER"
        "CLICKHOUSE_WSPRNET_USER_PASSWORD"
        "WSPRNET_SCRAPER_LOG_FILE_PATH"
    )

    local missing_vars=()
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        wd_logger 1 "ERROR: Required environment variables are not set:"
        for var in "${missing_vars[@]}"; do
            wd_logger 1 "  - $var"
        done
        return 1
    fi

    wd_logger 1 "All required environment variables are set"

    # Setup and validate Python venv
    local venv_python="${WSPRNET_VENV_PATH}/bin/python3"
    local venv_pip="${WSPRNET_VENV_PATH}/bin/pip3"

    if [[ ! -d "${WSPRNET_VENV_PATH}" ]]; then
        wd_logger 1 "Python venv not found at ${WSPRNET_VENV_PATH}, creating..."

        # Check if python3-venv is installed (Debian 13 requirement)
        if ! dpkg -l python3-venv &>/dev/null; then
            wd_logger 1 "ERROR: python3-venv package not installed"
            wd_logger 1 "Install with: sudo apt install python3-venv"
            return 1
        fi

        # Create venv
        if ! python3 -m venv "${WSPRNET_VENV_PATH}"; then
            wd_logger 1 "ERROR: Failed to create Python venv at ${WSPRNET_VENV_PATH}"
            return 1
        fi

        wd_logger 1 "Created Python venv at ${WSPRNET_VENV_PATH}"
    fi

    # Verify venv Python exists
    if [[ ! -x "${venv_python}" ]]; then
        wd_logger 1 "ERROR: venv Python not found or not executable: ${venv_python}"
        return 1
    fi

    # Check and install required Python packages
    local required_packages=("clickhouse-connect" "numpy" "requests")
    local packages_to_install=()

    wd_logger 1 "Checking required Python packages..."
    for package in "${required_packages[@]}"; do
        local import_name="${package//-/_}"  # clickhouse-connect -> clickhouse_connect
        if ! "${venv_python}" -c "import ${import_name}" 2>/dev/null; then
            packages_to_install+=("${package}")
            wd_logger 1 "  Package ${package} is missing"
        else
            wd_logger 1 "  Package ${package} is installed"
        fi
    done

    # Install missing packages
    if [[ ${#packages_to_install[@]} -gt 0 ]]; then
        wd_logger 1 "Installing missing Python packages: ${packages_to_install[*]}"
        if ! "${venv_pip}" install "${packages_to_install[@]}"; then
            wd_logger 1 "ERROR: Failed to install Python packages"
            return 1
        fi
        wd_logger 1 "Successfully installed missing packages"
    fi

    wd_logger 1 "Python venv validated successfully"

    # Extract Python script path from command
    local python_script="${WSPRNET_SCRAPER_PYTHON_CMD##* }"  # Get last argument

    if [[ ! -f "${python_script}" ]]; then
        wd_logger 1 "ERROR: Python script not found: ${python_script}"
        return 1
    fi

    wd_logger 1 "Python script found: ${python_script}"

    # Build the actual command using venv Python
    local scraper_cmd="${venv_python} ${python_script}"

    while true; do
        wd_logger 2 "Checking that scraper is running"
        local spawn_scraper="no"
        if [[ ! -f ${WSPRNET_SCRAPER_PID_FILE_PATH} ]]; then
            wd_logger 1 "PID file ${WSPRNET_SCRAPER_PID_FILE_PATH} doesn't exist, so spawn scraper daemon"
            spawn_scraper="yes"
        else
            scraper_pid=$(<${WSPRNET_SCRAPER_PID_FILE_PATH})
            kill -0 ${scraper_pid} 2>/dev/null
            rc=$?
            if (( rc )); then
                wd_logger 1 "ERROR: PID ${scraper_pid} found in ${WSPRNET_SCRAPER_PID_FILE_PATH} is dead, so spawn scraper daemon"
                rm -f ${WSPRNET_SCRAPER_PID_FILE_PATH}
                spawn_scraper="yes"
            else
                wd_logger 1 "PID ${scraper_pid} found in ${WSPRNET_SCRAPER_PID_FILE_PATH} is active"
            fi
        fi
        if [[ ${spawn_scraper} == "yes" ]]; then
            wd_logger 1 "Spawning wsprnet_scraper"
            ${scraper_cmd} \
                --session-file           ${WSPRNET_SESSION_FILE_PATH} \
                --setup-default-password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} \
                --clickhouse-user        ${CLICKHOUSE_WSPRNET_ADMIN_USER}  --clickhouse-password     ${CLICKHOUSE_WSPRNET_ADMIN_PASSWORD} \
                --setup-readonly-user    ${CLICKHOUSE_WSPRNET_USER}        --setup-readonly-password ${CLICKHOUSE_WSPRNET_USER_PASSWORD} \
                --log-file               ${WSPRNET_SCRAPER_LOG_FILE_PATH}  --log-max-mb              ${WSPRNET_SCRAPER_LOG_FILE_MAX_SIZE_MB:-10} \
                --loop                   ${CLICKHOUSE_WSPRNET_SCRAPER_POLL_SECS:-20}  2>&1 &
            scraper_pid=$!
            echo ${scraper_pid} > ${WSPRNET_SCRAPER_PID_FILE_PATH}
            wd_logger 1 "Spawned scraper command which has PID ${scraper_pid}"
            sleep 1
            if ! kill -0 ${scraper_pid} 2>/dev/null; then
                wd_logger 1 "ERROR: Scraper PID ${scraper_pid} died immediately after spawn"
                rm -f ${WSPRNET_SCRAPER_PID_FILE_PATH}
            fi
        fi
        wd_sleep ${WSPRNET_SCRAPER_WATCHDOG_INTERVAL:-30}
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
