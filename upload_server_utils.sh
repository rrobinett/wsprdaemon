
############## Implents the '-u' cmd which runs only on wsprdaemon.org to process the tar .tbz files uploaded by WD sites

declare UPLOAD_FTP_PATH=~/ftp/upload       ### Where the FTP server leaves tar.tbz files
declare UPLOAD_BATCH_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/ts_upload_batch.py
declare TS_NOISE_AWK_SCRIPT=${WSPRDAEMON_ROOT_DIR}/ts_noise.awk

#     
#  local extended_line=$( printf "%6s %4s %3d %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
#                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
declare UPLOAD_SPOT_SQL='INSERT INTO wsprdaemon_spots (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon, receiver) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s); '
declare UPLOAD_NOISE_SQL='INSERT INTO wsprdaemon_noise (time, site, receiver, rx_grid, band, rms_level, c2_level, ov) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);'

### This deamon runs on wsprdaemon.org and processes tgz files FTPed to it by WD clients
### It optionally queues a copy of each tgz for FTP transfer to WD1
function wsprdaemon_tgz_service_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD

    mkdir -p ${UPLOADS_TMP_ROOT_DIR}
    cd ${UPLOADS_TMP_ROOT_DIR}
    echo "UPLOAD_SPOT_SQL=${UPLOAD_SPOT_SQL}" > upload_spot.sql       ### helps debugging from cmd line
    echo "UPLOAD_NOISE_SQL=${UPLOAD_NOISE_SQL}" > upload_noise.sql
    shopt -s nullglob
    [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() starting in $PWD"
    while true; do
        [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() waiting for *.tbz files to appear in ${UPLOAD_FTP_PATH}"
        local -a tar_file_list
        while tar_file_list=( ${UPLOAD_FTP_PATH}/*.tbz) && [[ ${#tar_file_list[@]} -eq 0 ]]; do
            [[ $verbosity -ge 3 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() waiting for *.tbz files"
            sleep 10
        done
        if [[ ${#tar_file_list[@]} -gt 1000 ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() processing only first 1000 tar files of the ${#tar_file_list[@]} in ~/ftp/uploads directory"
            tar_file_list=( ${tar_file_list[@]:0:1000} )
        fi
        [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() validating ${#tar_file_list[@]} tar.tbz files..."
        local valid_tbz_list=()
        local tbz_file 
        for tbz_file in ${tar_file_list[@]}; do
            if tar tf ${tbz_file} &> /dev/null ; then
                [[ $verbosity -ge 3 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found valid tar file ${tbz_file}"
                valid_tbz_list+=(${tbz_file})
                if [[ ${tbz_file} =~ "[fF]6*" ]]; then
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() copying ${tbz_file} to /tmp"
                    cp -p {tbz_file} /tmp/
                fi
            else
                if [[ -f ${tbz_file} ]]; then
                    ### A client may be in the process of uploading a tar file.
                    [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found invalid tar file ${tbz_file}"
                    local file_mod_time=0
                    file_mod_time=$( $GET_FILE_MOD_TIME_CMD ${tbz_file})
                    local current_time=$(date +"%s")
                    local file_age=$(( ${current_time}  - ${file_mod_time} ))
                    if [[ ${file_age} -gt ${MAX_TAR_AGE_SECS-600} ]] ; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() deleting invalid file ${tbz_file} which is ${file_age} seconds old"
                        rm ${tbz_file}
                    fi
                else
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() unexpectedly found tar file ${tbz_file} was deleted during validation"
                fi
            fi
        done
        if [[ ${#valid_tbz_list[@]} -eq 0 ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found no valid tar files among the ${#tar_file_list[@]} raw tar files"
            sleep 1
            continue
        else
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() extracting ${#valid_tbz_list[@]} valid tar files"
            queue_files_for_upload_to_wd1 ${valid_tbz_list[@]}
            cat  ${valid_tbz_list[@]} | tar jxf - -i
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() ERROR: tar returned error code ${ret_code}"
            fi
            if [[ ! -d wsprdaemon.d ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() ERROR: tar sources didn't create wsprdaemon.d"
            fi

            ### Record the spot files
            local spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_wspr_spots.txt')  )
            local raw_spot_file_list_count=${#spot_file_list[@]}
            if [[ ${#spot_file_list[@]} -eq 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found no spot files in any of the tar files.  Checking for noise files in $(ls -d wsprdaemon.d/*) ."
            else
                ### There are spot files 
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${raw_spot_file_list_count} spot files.  Flushing zero length spot files"

                ### Remove zero length spot files (that is common, since they are used by the decoding daemon to signal the posting daemon that decoding has been completed when no spots are decoded
                local zero_length_spot_file_list=( $(find wsprdaemon.d/spots.d -name '*wspr_spots.txt' -size 0) )
                local zero_length_spot_file_list_count=${#zero_length_spot_file_list[@]}
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${#zero_length_spot_file_list[@]} zero length spot files"
                local rm_file_list=()
                while rm_file_list=( ${zero_length_spot_file_list[@]:0:10000} ) && [[ ${#rm_file_list[@]} -gt 0 ]]; do     ### Remove in batches of 10000 files.
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() deleting batch of the first ${#rm_file_list[@]} of the remaining ${#zero_length_spot_file_list[@]}  zero length spot files"
                    rm ${rm_file_list[@]}
                    zero_length_spot_file_list=( ${zero_length_spot_file_list[@]:10000} )          ### Chop off the 10000 files we just rm'd
                done
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() finished flushing zero length spot files.  Reload list of remaining non-zero length files"
                spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_wspr_spots.txt')  )
                [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${raw_spot_file_list_count} spot files, of which ${zero_length_spot_file_list_count} were zero length spot files.  After deleting those zero length files there are now ${#spot_file_list[@]} files with spots in them."

                ###
                if [[ ${#spot_file_list[@]} -eq 0 ]]; then
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() there were no non-zero length spot files. Go on to check for noise files under wsprdaemon.noise."
                else
                    ### There are spot files with spot lines
                    ### If the sync_quality in the third field is a float (i.e. has a '.' in it), then this spot was decoded by wsprd v2.1
                    local calls_delivering_jtx_2_1_lines=( $(awk 'NF == 32 && $3  !~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
                    if [[ ${#calls_delivering_jtx_2_1_lines[@]} -ne 0 ]]; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() Calls using WSJT-x V2.1 wsprd: ${calls_delivering_jtx_2_1_lines[@]}"
                    fi
                    local calls_delivering_jtx_2_2_lines=( $(awk 'NF == 32 && $3  ~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
                    if [[ ${#calls_delivering_jtx_2_2_lines[@]} -ne 0 ]]; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() Calls using WSJT-x V2.2 wsprd: ${calls_delivering_jtx_2_2_lines[@]}"
                    fi
                    ###   spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_rms_noise spot_c2_noise spot_for_wsprnet band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon

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

                    ### 9/5/20:  RR include receiver name in bad spots lines
                    awk 'NF != 32 || $7 == "none" || $8 == "none" {\
                        $7=toupper($7); \
                        $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4))); \
                        $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4))); \
                        $23=toupper($23); \
                        n = split(FILENAME, a, "/"); \
                        printf "%s %s\n", $0, a[n-2]} ' ${spot_file_list[@]}  > awk_bad.out
                        cat awk_bad.out | sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" > ${TS_BAD_SPOTS_CSV_FILE}

                    if [[ $verbosity -ge 1 ]] && [[ -s ${TS_BAD_SPOTS_CSV_FILE} ]] ; then
                        local bad_spots_count=$(cat ${TS_BAD_SPOTS_CSV_FILE} | wc -l)
                        echo -e "$(date): wsprdaemon_tgz_service_daemon() found ${bad_spots_count} bad spots:\n$(head -n 4 ${TS_BAD_SPOTS_CSV_FILE})"
                    fi
                    if [[ -s ${TS_SPOTS_CSV_FILE} ]]; then
                        python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_SPOTS_CSV_FILE}  "${UPLOAD_SPOT_SQL}"
                        local ret_code=$?
                        if [[ ${ret_code} -eq 0 ]]; then
                            if [[ $verbosity -ge 1 ]]; then
                                echo "$(date): wsprdaemon_tgz_service_daemon() recorded $( cat ${TS_SPOTS_CSV_FILE} | wc -l) spots to the wsprdaemon_spots table from ${#spot_file_list[@]} spot files which were extracted from ${#valid_tbz_list[@]} tar files."
                                grep -i f6bir ${spot_file_list[@]}
                            fi
                            rm ${spot_file_list[@]} 
                        else
                            [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() python failed to record $( cat ${TS_SPOTS_CSV_FILE} | wc -l) spots to the wsprdaemon_spots table from \${spot_file_list[@]}"
                        fi
                    else
                        if [[ $verbosity -ge 1 ]]; then
                            echo "$(date): wsprdaemon_tgz_service_daemon() found zero valid spot lines in the ${#spot_file_list[@]} spot files which were extracted from ${#valid_tbz_list[@]} tar files."
                            awk 'NF != 32 || $7 == "none" {printf "Skipped line in %s which contains invalid spot line %s\n", FILENAME, $0}' ${spot_file_list[@]}
                        fi
                        rm ${spot_file_list[@]} 
                    fi
                fi
            fi

            ### Record the noise files
            local noise_file_list=( $(find wsprdaemon.d/noise.d -name '*_wspr_noise.txt') )
            if [[ ${#noise_file_list[@]} -eq 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() unexpectedly found no noise files"
                sleep 1
            else
                [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${#noise_file_list[@]} noise files"
                local TS_NOISE_CSV_FILE=ts_noise.csv

                local csv_files_left_list=(${noise_file_list[@]})
                local csv_file_list=( )
                CSV_MAX_FILES=5000
                local csv_files_left_list=(${noise_file_list[@]})
                local csv_file_list=( )
                while csv_file_list=( ${csv_files_left_list[@]::${CSV_MAX_FILES}} ) && [[ ${#csv_file_list[@]} -gt 0 ]] ; do
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() processing batch of ${#csv_file_list[@]} of the remaining ${#csv_files_left_list[@]} noise_files into ${TS_NOISE_CSV_FILE}"
                    awk -f ${TS_NOISE_AWK_SCRIPT} ${csv_file_list[@]} > ${TS_NOISE_CSV_FILE}
                    if [[ $verbosity -ge 1 ]]; then
                        [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() awk created ${TS_NOISE_CSV_FILE} which contains $( cat ${TS_NOISE_CSV_FILE} | wc -l ) noise lines"
                        local UPLOAD_NOISE_SKIPPED_FILE=ts_noise_skipped.txt
                        awk 'NF != 15 {printf "%s: %s\n", FILENAME, $0}' ${csv_file_list[@]} > ${UPLOAD_NOISE_SKIPPED_FILE}
                        if [[ -s ${UPLOAD_NOISE_SKIPPED_FILE} ]]; then
                            echo "$(date): wsprdaemon_tgz_service_daemon() awk found $(cat ${UPLOAD_NOISE_SKIPPED_FILE} | wc -l) invalid noise lines which are saved in ${UPLOAD_NOISE_SKIPPED_FILE}:"
                            head -n 10 ${UPLOAD_NOISE_SKIPPED_FILE}
                        fi
                    fi
                    python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_NOISE_CSV_FILE}  "${UPLOAD_NOISE_SQL}"
                    local ret_code=$?
                    if [[ ${ret_code} -eq 0 ]]; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() recorded $( cat ${TS_NOISE_CSV_FILE} | wc -l) noise lines to the wsprdaemon_noise table from ${#noise_file_list[@]} noise files which were extracted from ${#valid_tbz_list[@]} tar files."
                        rm ${csv_file_list[@]}
                    else
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() python failed to record $( cat ${TS_NOISE_CSV_FILE} | wc -l) noise lines to  the wsprdaemon_noise table from \${noise_file_list[@]}"
                    fi
                    csv_files_left_list=( ${csv_files_left_list[@]:${CSV_MAX_FILES}} )            ### Chops off the first 1000 elements of the list 
                    [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() finished with csv batch"
                done
                [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() finished with all noise files"
            fi
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() deleting the ${#valid_tbz_list[@]} valid tar files"
            rm ${valid_tbz_list[@]} 
        fi
    done
}

declare UPLOAD_TO_MIRROR_SERVER_URL="${UPLOAD_TO_MIRROR_SERVER_URL-}"
declare UPLOAD_TO_MIRROR_QUEUE_DIR          ## setup when upload daemon is spawned
declare UPLOAD_TO_MIRROR_SERVER_SECS=10       ## How often to attempt to upload tar files to log1.wsprdaemon.org
declare UPLOAD_MAX_FILE_COUNT=1000          ## curl will upload only a ?? number of files, so limit the number of files given to curl

### Copies the valid tar files found by the upload_server_daemon() to logs1.wsprdaemon.org
function upload_to_mirror_daemon() {
    local mirror_files_path=${UPLOAD_TO_MIRROR_QUEUE_DIR}
    local parsed_server_url_list=( ${UPLOAD_TO_MIRROR_SERVER_URL//,/ } )
    if [[ ${#parsed_server_url_list[@]} -ne 3 ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon(): ERROR: invalid configuration variable UPLOAD_TO_MIRROR_SERVER_URL  = '${UPLOAD_TO_MIRROR_SERVER_URL}'"
        return 1
    fi
    local upload_url=${parsed_server_url_list[0]}
    local upload_user=${parsed_server_url_list[1]}
    local upload_password=${parsed_server_url_list[2]}

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    mkdir -p ${mirror_files_path}
    cd ${UPLOAD_TO_MIRROR_QUEUE_DIR}

    [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon starting in ${UPLOAD_TO_MIRROR_QUEUE_DIR}"
    while true; do
        [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_mirror_daemon() looking for files to upload"
        shopt -s nullglob
        local files_queued_for_upload_list=( * )
        if [[ ${#files_queued_for_upload_list[@]} -gt 0 ]]; then
            local curl_upload_file_list=(${files_queued_for_upload_list[@]::${UPLOAD_MAX_FILE_COUNT}})  ### curl limits the number of files to upload, so curl only the first UPLOAD_MAX_FILE_COUNT files 
            [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon() starting curl of ${#curl_upload_file_list[@]} files using: '.. --user ${upload_user}:${upload_password} ftp://${upload_url}'"
            local curl_upload_file_string=${curl_upload_file_list[@]}
            curl_upload_file_string=${curl_upload_file_string// /,}     ### curl wants a comma-seperated list of files
            curl -s -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${upload_user}:${upload_password} ftp://${upload_url} 
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon() curl xfer was successful, so delete ${#curl_upload_file_list[@]} local files"
                rm ${curl_upload_file_list[@]}
            else
                [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon() curl xfer failed => ${ret_code}"
            fi
        fi
        [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_mirror_daemon() sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function queue_files_for_upload_to_wd1() {
    local files="$@"

    if [[ -n "${UPLOAD_TO_MIRROR_SERVER_URL}" ]]; then
        if [[ $verbosity -ge 1 ]]; then
            local files_path_list=(${files})
            local files_name_list=(${files_path_list[@]##*/})
            echo "$(date): queue_files_for_upload_to_wd1() queuing ${#files_name_list[@]} files '${files_name_list[@]}' in '${UPLOAD_TO_MIRROR_QUEUE_DIR}'"
        fi
        ln ${files} ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    else
        [[ $verbosity -ge 2 ]] && echo "$(date): queue_files_for_upload_to_wd1() queuing disabled, so ignoring '${files}'"
    fi
}

### Spawns 2 daemons:  one to process the WD extended spots and noise delivered to the 'noisegrahs' user in .tgz files
###                    a second (optional) daemon mirrors those tgz files to a backup WD server
function spawn_upload_server_to_wsprdaemon_daemon() {
    local uploading_root_dir=$1
    mkdir -p ${uploading_root_dir}
    local uploading_log_file_path=${uploading_root_dir}/uploads.log
    local uploading_pid_file_path=${uploading_root_dir}/uploads.pid  
    local mirror_log_file_path=${uploading_root_dir}/mirror.log
    local mirror_pid_file_path=${uploading_root_dir}/mirror.pid  
    UPLOAD_TO_MIRROR_QUEUE_DIR=${uploading_root_dir}/mirror_queue.d
    if [[ ! -d ${UPLOAD_TO_MIRROR_QUEUE_DIR} ]]; then
        mkdir -p ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    fi

    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() start"
    setup_systemctl_deamon "-u a"  "-u z"
    if [[ -f ${mirror_pid_file_path} ]]; then
        local mirror_pid=$(cat ${mirror_pid_file_path})
        if ps ${mirror_pid} > /dev/null ; then
            [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() mirror daemon in '${mirror_pid_file_path}' with pid ${mirror_pid} is already running"
            kill ${mirror_pid}
        fi
        rm ${mirror_pid_file_path}
    fi
    if [[ -n "${UPLOAD_TO_MIRROR_SERVER_URL}" ]]; then
        upload_to_mirror_daemon  > ${mirror_log_file_path} 2>&1 &
        local mirror_pid=$!
        echo ${mirror_pid}  > ${mirror_pid_file_path}
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() started mirror daemon with pid ${mirror_pid}"
    fi

    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() uploading job for '${uploading_root_dir}' with pid ${uploading_pid} is already running"
            return 0
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): WARNING: spawn_upload_server_to_wsprdaemon_daemon() found a stale file '${uploading_pid_file_path}' with pid ${uploading_pid}, so deleting it"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    wsprdaemon_tgz_service_daemon ${uploading_root_dir} > ${uploading_log_file_path} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() Spawned new uploading job  with PID '$!'"
    return 0
}

function kill_upload_server_to_wsprdaemon_daemon()
{
    local mirror_pid_file_path=${1}/mirror.pid
    if [[ -f ${mirror_pid_file_path} ]]; then
        local mirror_pid=$(cat ${mirror_pid_file_path})
        if ps ${mirror_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() killing active mirror_server_to_wsprdaemon_daemon() with pid ${mirror_pid}"
            kill ${mirror_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found a stale mirror.pid file with pid ${mirror_pid}"
        fi
        rm -f ${mirror_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found no mirror.pid file ${mirror_pid_file_path}"
    fi
    local uploading_pid_file_path=${1}/uploads.pid
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() killing active upload_server_to_wsprdaemon_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}

function upload_server_to_wsprdaemon_daemon_status()
{
    local mirror_pid_file_path=${1}/mirror.pid
    if [[ -f ${mirror_pid_file_path} ]]; then
        local mirror_pid=$(cat ${mirror_pid_file_path})
        if ps ${mirror_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "Mirror daemon with pid '${mirror_pid}' is running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): mirror service daemon file '${mirror_pid_file_path}' with pid ${mirror_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprdaemon mirror daemon pid file ${mirror_pid_file_path}' records pid '${mirror_pid}', but that pid is not running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): found a stale pid file '${mirror_pid_file_path}'with pid ${mirror_pid}"
            fi
        fi
    else
        if [[ $verbosity -ge 2 ]] ; then
            echo "$(date): upload_to_wsprdaemon_daemon_status(): found no mirror.pid file ${mirror_pid_file_path}"
        fi
    fi
    local uploading_pid_file_path=${1}/uploads.pid
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "Uploading daemon with pid '${uploading_pid}' is running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): upload service daemon file '${uploading_pid_file_path}' with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Uploading daemon pid file ${uploading_pid_file_path}' records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): found a stale pid file '${uploading_pid_file_path}'with pid ${uploading_pid}"
            fi
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "Uploading daemon found no pid file '${uploading_pid_file_path}'"
        else
            echo "$(date): upload_server_to_wsprdaemon_daemon_status(): found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

function spawn_upload_server_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): spawn_upload_server_daemons() start"
    spawn_upload_server_to_wsprdaemon_daemon ${UPLOADS_ROOT_DIR}
}

function kill_upload_server_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): kill_upload_server_daemons() start"
    kill_upload_server_to_wsprdaemon_daemon ${UPLOADS_ROOT_DIR}
}

function upload_server_daemons_status(){
    [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_server_daemons_status() start"
    upload_server_to_wsprdaemon_daemon_status ${UPLOADS_ROOT_DIR}
}

### function which handles 'wd -u ...'
function upload_server_daemon() {
    local action=$1
    
    [[ $verbosity -ge 3 ]] && echo "$(date): upload_server_daemon() process cmd '${action}'"
    case ${action} in
        a)
            spawn_upload_server_daemons     ### Ensure there are upload daemons to consume the spots and noise data
            ;;
        z)
            kill_upload_server_daemons
            ;;
        s)
            upload_server_daemons_status
            ;;
        *)
            echo "ERROR: start_stop_job() aargument action '${action}' is invalid"
            exit 1
            ;;
    esac
}


