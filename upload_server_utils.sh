
############## Implents the '-u' cmd which runs only on wsprdaemon.org to process the tar .tbz files uploaded by WD sites

declare UPLOAD_FTP_PATH=~/ftp/upload       ### Where the FTP server leaves tar.tbz files
declare UPLOAD_BATCH_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/ts_upload_batch.py
declare TS_NOISE_AWK_SCRIPT=${WSPRDAEMON_ROOT_DIR}/ts_noise.awk

#     
#  local extended_line=$( printf "%6s %4s %3d %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
#                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
declare UPLOAD_SPOT_SQL='INSERT INTO wsprdaemon_spots_s (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon, receiver) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s); '
declare UPLOAD_NOISE_SQL='INSERT INTO wsprdaemon_noise_s (time, site, receiver, rx_grid, band, rms_level, c2_level, ov) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);'

### This deamon runs on wsprdaemon.org and processes tgz files FTPed to it by WD clients
### It optionally queues a copy of each tgz for FTP transfer to WD1
function tgz_service_daemon() {
    local tgz_service_daemon_root_dir=$1

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD

    mkdir -p ${UPLOADS_TMP_ROOT_DIR}
    cd ${UPLOADS_TMP_ROOT_DIR}

    ### wd_logger will write to $PWD in UPLOADS_TMP_ROOT_DIR.  We want the log to be kept on a permanet file system, so create a symlink to a log file over there
    touch tgz_service_daemon.log
    ln -s ${UPLOADS_TMP_ROOT_DIR}/tgz_service_daemon.log ${tgz_service_daemon_root_dir}       ### Logging for this dameon

    ### Most of the file read/write happens in /tmp/wsprdsaemon
    echo "UPLOAD_SPOT_SQL=${UPLOAD_SPOT_SQL}" > upload_spot.sql       ### helps debugging from cmd line
    echo "UPLOAD_NOISE_SQL=${UPLOAD_NOISE_SQL}" > upload_noise.sql
    shopt -s nullglob
    wd_logger 1 "Starting in $PWD"
    while true; do
        wd_logger 1 "Waiting for *.tbz files to appear in ${UPLOAD_FTP_PATH}"
        local -a tar_file_list
        while tar_file_list=( ${UPLOAD_FTP_PATH}/*.tbz) && [[ ${#tar_file_list[@]} -eq 0 ]]; do
            wd_logger 2 "waiting for *.tbz files"
            sleep 1
        done
        if [[ ${#tar_file_list[@]} -gt 1000 ]]; then
            wd_logger 1 "Processing only first 1000 tar files of the ${#tar_file_list[@]} in ${UPLOAD_FTP_PATH}/*.tbz"
            tar_file_list=( ${tar_file_list[@]:0:1000} )
        fi
        wd_logger 1 "Validating ${#tar_file_list[@]} tar.tbz files..."
        local valid_tbz_list=()
        local tbz_file 
        for tbz_file in ${tar_file_list[@]}; do
            if tar tf ${tbz_file} &> /dev/null ; then
                wd_logger 2 "Found a valid tar file: ${tbz_file}"
                valid_tbz_list+=(${tbz_file})
                if [[ ${tbz_file} =~ "[fF]6*" ]]; then
                    ###
                    wd_logger 1 "Copying ${tbz_file} to /tmp"
                    cp -p {tbz_file} /tmp/
                fi
            else
                if [[ ! -f ${tbz_file} ]]; then
                    wd_logger 1 "unexpectedly found tar file ${tbz_file} was deleted during validation"
                else
                    ### A client may be in the process of uploading a tar file.
                    wd_logger 1 "Found invalid tar file ${tbz_file}"
                    local file_mod_time=0
                    file_mod_time=$( $GET_FILE_MOD_TIME_CMD ${tbz_file})
                    local current_time=$(date +"%s")
                    local file_age=$(( ${current_time}  - ${file_mod_time} ))
                    if [[ ${file_age} -gt ${MAX_TAR_AGE_SECS-600} ]] ; then
                        wd_logger 1 "Deleting invalid file ${tbz_file} which is ${file_age} seconds old"
                        rm ${tbz_file}
                    fi
                fi
            fi
        done
        if [[ ${#valid_tbz_list[@]} -eq 0 ]]; then
            wd_logger 1 "found no valid tar files among the ${#tar_file_list[@]} raw tar files"
            sleep 1
            continue
        else
            wd_logger 1 "Extracting ${#valid_tbz_list[@]} valid tar files"
            queue_files_for_upload_to_wd1 ${valid_tbz_list[@]}
            cat  ${valid_tbz_list[@]} | tar jxf - -i
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: while validating tar files, tar returned error code ${ret_code}, but continuing to process them"
            fi
            if [[ ! -d wsprdaemon.d ]]; then
                wd_logger 1 "ERROR: tar sources didn't create wsprdaemon.d.  I don't ever expect this messsage"
            fi

            ### Record the spot files
            local spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_wspr_spots.txt')  )
            local raw_spot_file_list_count=${#spot_file_list[@]}
            if [[ ${#spot_file_list[@]} -eq 0 ]]; then
                wd_logger 1 "Found no spot files in any of the tar files.  Checking for noise files in $(ls -d wsprdaemon.d/*) ."
            else
                ### There are spot files 
                wd_logger 1 "Found ${raw_spot_file_list_count} spot files"

                ### Remove zero length spot files (that is common, since they are used by the decoding daemon to signal the posting daemon that decoding has been completed when no spots are decoded
                local zero_length_spot_file_list=( $(find wsprdaemon.d/spots.d -name '*wspr_spots.txt' -size 0) )
                local zero_length_spot_file_list_count=${#zero_length_spot_file_list[@]}

                wd_logger 1 "Found ${#zero_length_spot_file_list[@]} zero length spot files"
                local rm_file_list=()
                while rm_file_list=( ${zero_length_spot_file_list[@]:0:10000} ) && [[ ${#rm_file_list[@]} -gt 0 ]]; do     ### Remove in batches of 10000 files.
                    wd_logger 1 "Deleting batch of the first ${#rm_file_list[@]} of the remaining ${#zero_length_spot_file_list[@]}  zero length spot files"
                    rm ${rm_file_list[@]}
                    zero_length_spot_file_list=( ${zero_length_spot_file_list[@]:10000} )          ### Chop off the 10000 files we just rm'd
                done
                wd_logger 1 "Finished flushing zero length spot files.  Reload list of remaining non-zero length files"

                spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_wspr_spots.txt')  )
                wd_logger 1 "Found ${raw_spot_file_list_count} spot files, of which ${zero_length_spot_file_list_count} were zero length spot files.  After deleting those zero length files there are now ${#spot_file_list[@]} files with spots in them."

                ###
                if [[ ${#spot_file_list[@]} -eq 0 ]]; then
                    wd_logger 1 "There were no non-zero length spot files. Go on to check for noise files under wsprdaemon.noise."
                else
                    ### There are spot files with spot lines
                    ### If the sync_quality in the third field is a float (i.e. has a '.' in it), then this spot was decoded by wsprd v2.1
                    local calls_delivering_jtx_2_1_lines=( $(awk 'NF == 32 && $3  !~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
                    if [[ ${#calls_delivering_jtx_2_1_lines[@]} -ne 0 ]]; then
                        wd_logger 1 "Calls using WSJT-x V2.1 wsprd: ${calls_delivering_jtx_2_1_lines[@]}"
                    fi
                    local calls_delivering_jtx_2_2_lines=( $(awk 'NF == 32 && $3  ~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
                    if [[ ${#calls_delivering_jtx_2_2_lines[@]} -ne 0 ]]; then
                        wd_logger 1 "Calls using WSJT-x V2.2 wsprd: ${calls_delivering_jtx_2_2_lines[@]}"
                    fi
                    ###  Format of the extended spot line delivered by WD clients:
                    ###   spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin \
                    ###                                                                       spot_rms_noise spot_c2_noise spot_for_wsprnet band \
                    ###                                                                                        my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon

                    ###  Those lines are converted into a .csv file which will be recorded in TS and CH by this awk program:
                    ###  awk 'NF == 32' ${spot_file_list[@]:0:20000}  => filters out corrupt spot lines.  Only lines with 32 fields are fed to TS.  The bash cmd line can process no more than about 23,500 arguments, so pass at most 20,000 txt file names to awk.  If there are more, they will get processed in the next loop iteration
                    ###  sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/;'"s/\"/'/g"
                    ###          s/\S+\s+//18;  => deletes the 18th field, the 'proxy upload this spot to wsprnet.org'
                    ###                        s/ /,/g; => replace all spaces with ','s
                    ###                                   s/,/:/; => change the first two fields from DATE,TIME to DATE:TIME
                    ###                                          s/./&"/11; => add '"' to get DATE:TIME"
                    ###                                                      s/./&:/9; => insert ':' to get YYMMDD:HH:MM"
                    ###                                                                s/./&-/4; s/./&-/2;   => insert ':' to get YY-MM-DD:HH:MM"
                    ###                                                                                   s/^/"20/;  => insert '"20' to get "20YY-MM-DD:HH:MM"
                    ###                                                                                             s/",0\./",/; => WSJT-x V2.2+ outputs a floting point sync value.  this chops off the leading '0.' to make it a decimal number for TS 
                    ###                                                                                                          "s/\"/'/g" => replace those two '"'s with ''' to get '20YY-MM-DD:HH:MM'.  Since this expression includes a ', it has to be within "s
                    local TS_SPOTS_CSV_FILE=./ts_spots.csv
                    local TS_BAD_SPOTS_CSV_FILE=./ts_bad_spots.csv
                    ### the awk expression forces the tx_call and rx_id to be all upper case letters and the tx_grid and rx_grid to by UU99ll, just as is done by wsprnet.org
                    ### 9/5/20:  RR added receiver name to end of each line.  It is extracted from the path of the wsprdaemon_spots.txt file
                    awk 'NF == 32 && $7 != "none" && $8 != "none" {\
                        $7=toupper($7); \
                        $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4))); \
                        $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4))); \
                        $23=toupper($23); \
                        n = split(FILENAME, a, "/"); \
                        printf "%s %s\n", $0, a[n-2]} ' ${spot_file_list[@]}  > awk.out
                        cat awk.out | sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" > ${TS_SPOTS_CSV_FILE}

                    ### 9/5/20:  RR include receiver name in type 2 spot lines which have no maidenhead field in $8, and thus one less field
                    awk 'NF != 32 || $7 == "none" || $8 == "none" {\
                        $7=toupper($7); \
                        $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4))); \
                        $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4))); \
                        $23=toupper($23); \
                        n = split(FILENAME, a, "/"); \
                        printf "%s %s\n", $0, a[n-2]} ' ${spot_file_list[@]}  > awk_bad.out
                        cat awk_bad.out | sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" > ${TS_BAD_SPOTS_CSV_FILE}

                    if [[ -s ${TS_BAD_SPOTS_CSV_FILE} ]] ; then
                        wd_logger 1 "Found $(wc -l < ${TS_BAD_SPOTS_CSV_FILE} )  bad spots:\n$(head -n 4 ${TS_BAD_SPOTS_CSV_FILE})"
                    fi
                    if [[ ! -s ${TS_SPOTS_CSV_FILE} ]]; then
                        wd_logger 1 "Found zero valid spot lines in the ${#spot_file_list[@]} spot files which were extracted from ${#valid_tbz_list[@]} tar files."
                    else
                        python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_SPOTS_CSV_FILE}  "${UPLOAD_SPOT_SQL}"
                        local ret_code=$?
                        if [[ ${ret_code} -ne 0 ]]; then
                            wd_logger 1 "Python failed to record $( cat ${TS_SPOTS_CSV_FILE} | wc -l) spots to the wsprdaemon_spots_s table from \${spot_file_list[@]}"
                        else
                            wd_logger 1 "Rcorded $( wc -l < ${TS_SPOTS_CSV_FILE} ) spots to the wsprdaemon_spots_s table from ${#spot_file_list[*]} spot files which were extracted from ${#valid_tbz_list[*]} tar files, so flush the spot files"
                        fi
                    fi
                    rm ${spot_file_list[@]} 
                fi
            fi

            ### Record the noise files
            local noise_file_list=( $(find wsprdaemon.d/noise.d -name '*_wspr_noise.txt') )
            if [[ ${#noise_file_list[@]} -eq 0 ]]; then
                wd_logger 1 "Unexpectedly found no noise files"
            else
                wd_logger 1 "Found ${#noise_file_list[@]} noise files"
                local TS_NOISE_CSV_FILE=ts_noise.csv

                local csv_files_left_list=(${noise_file_list[@]})
                local csv_file_list=( )
                CSV_MAX_FILES=5000
                local csv_files_left_list=(${noise_file_list[@]})
                local csv_file_list=( )
                while csv_file_list=( ${csv_files_left_list[@]::${CSV_MAX_FILES}} ) && [[ ${#csv_file_list[@]} -gt 0 ]] ; do
                    wd_logger 1 "Processing batch of ${#csv_file_list[@]} of the remaining ${#csv_files_left_list[@]} noise_files into ${TS_NOISE_CSV_FILE}"
                    awk -f ${TS_NOISE_AWK_SCRIPT} ${csv_file_list[@]} > ${TS_NOISE_CSV_FILE}
                    if [[ $verbosity -ge 1 ]]; then
                        wd_logger 1 "awk created ${TS_NOISE_CSV_FILE} which contains $( wc -l < ${TS_NOISE_CSV_FILE} ) noise lines"
                        local UPLOAD_NOISE_SKIPPED_FILE=ts_noise_skipped.txt
                        awk 'NF != 15 {printf "%s: %s\n", FILENAME, $0}' ${csv_file_list[@]} > ${UPLOAD_NOISE_SKIPPED_FILE}
                        if [[ -s ${UPLOAD_NOISE_SKIPPED_FILE} ]]; then
                            wd_logger 1 "awk found $(cat ${UPLOAD_NOISE_SKIPPED_FILE} | wc -l) invalid noise lines which are saved in ${UPLOAD_NOISE_SKIPPED_FILE}:"
                        fi
                    fi
                    python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_NOISE_CSV_FILE}  "${UPLOAD_NOISE_SQL}"
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "Python failed to record $( wc -l < ${TS_NOISE_CSV_FILE}) noise lines to  the wsprdaemon_noise_s table from \${noise_file_list[@]}"
                    else
                        wd_logger 1 "Recorded $( wc -l < ${TS_NOISE_CSV_FILE} ) noise lines to the wsprdaemon_noise_s table from ${#noise_file_list[@]} noise files which were extracted from ${#valid_tbz_list[@]} tar files."
                        rm ${csv_file_list[@]}
                    fi
                    csv_files_left_list=( ${csv_files_left_list[@]:${CSV_MAX_FILES}} )            ### Chops off the first 1000 elements of the list 
                    wd_logger 1 "Finished with csv batch"
                done
                wd_logger 1 "Finished with all noise files"
            fi
            wd_logger 1 "Deleting the ${#valid_tbz_list[@]} valid tar files"
            rm ${valid_tbz_list[@]} 
        fi
    done
}

declare UPLOAD_TO_MIRROR_SERVER_URL="${UPLOAD_TO_MIRROR_SERVER_URL-}"       ### Defaults to blank, so no uploading happens

declare UPLOAD_TO_MIRROR_QUEUE_DIR=${UPLOADS_ROOT_DIR}/uploads.d            ### Where tgz files are put to be uploaded
if [[ ! -d ${UPLOAD_TO_MIRROR_QUEUE_DIR} ]]; then
    mkdir -p ${UPLOAD_TO_MIRROR_QUEUE_DIR}
fi

declare UPLOAD_TO_MIRROR_SERVER_SECS=10       ## How often to attempt to upload tar files to log1.wsprdaemon.org
declare UPLOAD_MAX_FILE_COUNT=1000          ## curl will upload only a ?? number of files, so limit the number of files given to curl

### Copies the valid tar files found by the upload_server_daemon() to logs1.wsprdaemon.org
function upload_to_mirror_daemon() {
    local upload_to_mirror_daemon_root_dir=$1
    mkdir -p ${upload_to_mirror_daemon_root_dir}
    cd ${upload_to_mirror_daemon_root_dir}

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD

    mkdir -p ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    cd       ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    wd_logger 1 "Starting in ${UPLOAD_TO_MIRROR_QUEUE_DIR}"
    while true; do
        shopt -s nullglob
        local files_queued_for_upload_list=( * )
        if [[ -z "${UPLOAD_TO_MIRROR_SERVER_URL}" ]]; then
            wd_logger 1 "UPLOAD_TO_MIRROR_SERVER_URL is not defined, so nothing for us to do now. 'sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}' and then reread the config file"
            if [[ ${#files_queued_for_upload_list[@]} -gt 0 ]]; then
                 wd_logger 1 "ERROR: this mirror server is disabled, but there are ${#files_queued_for_upload_list[@]} files waiting to be uploaded"
             fi
            sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
            source ${WSPRDAEMON_CONFIG_FILE}
            continue
        else
            local parsed_server_url_list=( ${UPLOAD_TO_MIRROR_SERVER_URL//,/ } )
            if [[ ${#parsed_server_url_list[@]} -ne ${UPLOAD_TO_MIRROR_SERVER_SECS} ]]; then
                wd_logger 1 "ERROR: invalid configuration variable UPLOAD_TO_MIRROR_SERVER_URL  = '${UPLOAD_TO_MIRROR_SERVER_URL}'. 'sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}' and then reread the config file"
                if [[ ${#files_queued_for_upload_list[@]} -gt 0 ]]; then
                    wd_logger 1 "ERROR: this mirror server's URL is corrupted and  there are ${#files_queued_for_upload_list[@]} files waiting to be uploaded"
                fi
                sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
                source ${WSPRDAEMON_CONFIG_FILE}
                continue
            fi
        fi
        local upload_url=${parsed_server_url_list[0]}
        local upload_user=${parsed_server_url_list[1]}
        local upload_password=${parsed_server_url_list[2]}

        if [[ ${#files_queued_for_upload_list[@]} -eq 0 ]]; then
            wd_logger 1 "Found now files to upload to upload_url=${upload_url}, upload_user=${upload_user}, upload_password=${upload_password}"
        else
            wd_logger 1 "Found {#files_queued_for_upload_list[@]} files to upload to upload_url=${upload_url}, upload_user=${upload_user}, upload_password=${upload_password}"

            local curl_upload_file_list=(${files_queued_for_upload_list[@]::${UPLOAD_MAX_FILE_COUNT}})  ### curl limits the number of files to upload, so curl only the first UPLOAD_MAX_FILE_COUNT files 
            wd_logger 1 "Starting curl of ${#curl_upload_file_list[@]} files using: '.. --user ${upload_user}:${upload_password} ftp://${upload_url}'"

            local curl_upload_file_string=${curl_upload_file_list[@]}

            curl_upload_file_string=${curl_upload_file_string// /,}     ### curl wants a comma-seperated list of files
            curl -s -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${upload_user}:${upload_password} ftp://${upload_url} 
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "curl xfer failed => ${ret_code}, so leave files alone and try again"
            else
                wd_logger 1 "curl xfer was successful, so delete ${#curl_upload_file_list[@]} local files"
                rm ${curl_upload_file_list[@]}
                local ret_code=$?
                if [[ ${ret_code} -ne 0 ]]; then
                    d_logger 1 "ERROR: 'rm ${curl_upload_file_list[*]}' => ${ret_code}, but there is nothing we can do to recover"
                fi
            fi
        fi
        wd_logger 1 "Sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function queue_files_for_upload_to_wd1() {
    local files="$@"

    if [[ -z "${UPLOAD_TO_MIRROR_SERVER_URL}" ]]; then
        wd_logger 1 "queuing disabled, so ignoring '${files}'"
    else
        local files_path_list=(${files})
        local files_name_list=(${files_path_list[@]##*/})
        wd_logger 1 "queuing ${#files_name_list[@]} files '${files_name_list[*]}' in '${UPLOAD_TO_MIRROR_QUEUE_DIR}'"
        ln ${files} ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    fi
}

declare -r UPLOAD_DAEMON_LIST=(
   "upload_to_mirror_daemon        ${UPLOADS_ROOT_DIR} "
#   "tgz_service_daemon             ${UPLOADS_ROOT_DIR} "
#   "scraper_daemon          ${UPLOADS_ROOT_DIR} "
#   "noise_graph_daemon      ${UPLOADS_ROOT_DIR} "
    )

function upload_server_watchdog_daemon_kill_handler()
{
    wd_logger 1 "Got SIGTERM"
    for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local daemon_info_list=( ${daemon_info} )
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_home_dir=${daemon_info_list[1]}

        wd_logger 1 "Killing: '${daemon_function_name} ${daemon_home_dir}'"
        kill_daemon ${daemon_function_name} ${daemon_home_dir}
        local ret_code=$?
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 1 "Killed '${daemon_function_name} ${daemon_home_dir}'"
        else
            wd_logger 1 "ERROR: failed to kill '${daemon_function_name} ${daemon_home_dir}' => ${ret_code}"
        fi
    done
    wd_logger 1 "Done killing"
    exit 0
}
    
declare -r UPLOAD_SERVERS_POLL_RATE=10       ### Seconds for the daemons to wait between polling for files
function upload_server_watchdog_daemon() 
{
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    trap upload_server_watchdog_daemon_kill_handler SIGTERM

    wd_logger 1 "Starting"
    while true; do
        wd_logger 2 "Starting to check all daemons"
        local daemon_info
        for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
            wd_logger 2 "Check and spaawn ${daemon_info}"

            local daemon_info_list=( ${daemon_info} )
            local daemon_function_name=${daemon_info_list[0]}
            local daemon_home_dir=${daemon_info_list[1]}
            
            wd_logger 2 "Check and if needed spawn: '${daemon_function_name} ${daemon_home_dir}'"
            spawn_daemon ${daemon_function_name} ${daemon_home_dir}
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                wd_logger 2 "Spawned '${daemon_function_name} ${daemon_home_dir}'"
            else
                wd_logger 1 "ERROR: '${daemon_function_name} ${daemon_home_dir}' => ${ret_code}"
            fi
        done
        sleep ${UPLOAD_SERVERS_POLL_RATE}
    done
}

function spawn_daemon() 
{
    local daemon_function_name=$1
    local daemon_root_dir=$2
    mkdir -p ${daemon_root_dir}
    local daemon_log_file_path=${daemon_root_dir}/${daemon_function_name}.log
    local daemon_pid_file_path=${daemon_root_dir}/${daemon_function_name}.pid  

    wd_logger 1 "Start with args '$1' '$2' => daemon_root_dir=${daemon_root_dir}, daemon_function_name=${daemon_function_name}, daemon_log_file_path=${daemon_log_file_path}, daemon_pid_file_path=${daemon_pid_file_path}"
#    setup_systemctl_deamon "-u a"  "-u z"
    if [[ -f ${daemon_pid_file_path} ]]; then
        local daemon_pid=$( < ${daemon_pid_file_path})
        if ps ${daemon_pid} > /dev/null ; then
            wd_logger 1 "daemon job for '${daemon_root_dir}' with pid ${daemon_pid} is already running"
            return 0
        else
            wd_logger 1 "found a stale file '${daemon_pid_file_path}' with pid ${daemon_pid}, so deleting it"
            rm -f ${daemon_pid_file_path}
        fi
    fi
    echo "WD_LOGFILE=${daemon_log_file_path} ${daemon_function_name}  ${daemon_root_dir}  &"
    WD_LOGFILE=${daemon_log_file_path} ${daemon_function_name}  ${daemon_root_dir}  > /dev/null &
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to spawn 'WD_LOGFILE=${daemon_log_file_path} ${daemon_function_name}  ${daemon_root_dir}' => ${ret_code}"
        return 1
    fi
    echo $! > ${daemon_pid_file_path}
    wd_logger 1 "Spawned new ${daemon_function_name} job with PID '$!' and recorded the pid to '${daemon_pid_file_path}'"
    return 0
}

function kill_daemon() {
    local daemon_root_dir=$2
    if [[ ! -d ${daemon_root_dir} ]]; then
        d_logger 1 "ERROR: daemon root dir ${daemon_root_dir} doesn't exist"
        return 1
    fi
    local daemon_function_name=$1
    local daemon_log_file_path=${daemon_root_dir}/${daemon_function_name}.log
    local daemon_pid_file_path=${daemon_root_dir}/${daemon_function_name}.pid  

    wd_logger 1 "Start"
    if [[ ! -f ${daemon_pid_file_path} ]]; then
        wd_logger 1 "ERROR: ${daemon_function_name} pid file ${daemon_pid_file_path} doesn't exist"
        return 2
    else
        local daemon_pid=$( < ${daemon_pid_file_path})
        rm -f ${daemon_pid_file_path}
        if ! ps ${daemon_pid} > /dev/null ; then
            wd_logger 1 "ERROR: ${daemon_function_name} pid file reported pid ${daemon_pid}, but that isn't running"
            return 3
        else
            kill ${daemon_pid}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'kill ${daemon_pid}' failed for active pid ${daemon_pid}"
                return 4
            else
                wd_logger 1 "'kill ${daemon_pid}' was successful"
            fi
        fi
    fi
    return 0
}

function get_status_of_daemon() {
    local daemon_function_name=$1
    local daemon_root_dir=$2
    if [[ ! -d ${daemon_root_dir} ]]; then
        d_logger 1 "ERROR: daemon root dir ${daemon_root_dir} doesn't exist"
        return 1
    fi
    local daemon_log_file_path=${daemon_root_dir}/${daemon_function_name}.log
    local daemon_pid_file_path=${daemon_root_dir}/${daemon_function_name}.pid  

    wd_logger 1 "Start"
    if [[ ! -f ${daemon_pid_file_path} ]]; then
        wd_logger 1 "daemon '${daemon_function_name}' is not running since it has no  pid file '${daemon_pid_file_path}'"
        return 2
    else
        local daemon_pid=$( < ${daemon_pid_file_path})
        ps ${daemon_pid} > /dev/null
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then 
            wd_logger 1 "daemon '${daemon_function_name}' pid file '${daemon_pid_file_path}' reported pid ${daemon_pid}, but that isn't running"
            rm -f ${daemon_pid_file_path}
            return 3
        else
            wd_logger 1 "daemon '${daemon_function_name}' pid file '${daemon_pid_file_path}' reported pid ${daemon_pid} which is running"
        fi
    fi
    return 0
}

### function which handles 'wd -u ...'
function upload_server_daemon() {
    local action=$1
    
    wd_logger 1 "process cmd '${action}'"
    case ${action} in
        a)
            spawn_daemon            upload_server_watchdog_daemon ${WSPRDAEMON_ROOT_DIR}      ### Ensure there are upload daemons to consume the spots and noise data
            ;;
        z)
            kill_daemon             upload_server_watchdog_daemon ${WSPRDAEMON_ROOT_DIR}
            ;;
        s)
            get_status_of_daemon    upload_server_watchdog_daemon ${WSPRDAEMON_ROOT_DIR}
            return 0         ### Ignore error codes
            ;;
        *)
            wd_logger 1 "argument action '${action}' is invalid"
            exit 1
            ;;
    esac
}
