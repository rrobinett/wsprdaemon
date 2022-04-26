#!/bin/bash

declare UPLOAD_FTP_PATH=/home/noisegraphs/ftp/upload                          ### Where the FTP server puts the uploaded tar.tbz files from WD clients
declare TS_NOISE_AWK_SCRIPT=${WSPRDAEMON_ROOT_DIR}/ts_noise.awk

### The extended spot lines created by WD 2.x have these 32 fields:
### spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin       <=== Taken directly from the ALL_WSPR.TXT spot lines
###                         spot_for_wsprnet spot_rms_noise spot_c2_noise                                                                                                                                             <=== Added by the decode_daemon()
###                         band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon                                                                                                          <=== Added by add_azi() python code

###  WD 3.0 adds two additional fields at the end of each extended spot line for a total of 34 fields:
###                         overload_counts  pkt_mode

declare MAX_SPOT_LINES=5000  ### Record no more than this many spot lines at a time to TS and CH 
declare MAX_RM_ARGS=5000     ### Limit of the number of files in the 'rm ...' cmd line

### This daemon runs on wsprdaemon.org and processes tgz files FTPed to it by WD clients
### It optionally queues a copy of each tgz for FTP transfer to WD1
function tbz_service_daemon() 
{
    wd_logger 1 "Starting in $PWD, but will run in ${UPLOADS_TMP_ROOT_DIR}"

    local tbz_service_daemon_root_dir=$1  ### The tbz files are found in permanent storage under ~/wsprdaemon/uploads.d/..., but this daemon does all its work in a /tmp/wsprdaemon/... directory

    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    mkdir -p ${UPLOADS_TMP_ROOT_DIR}
    cd ${UPLOADS_TMP_ROOT_DIR}

    ### wd_logger will write to $PWD in UPLOADS_TMP_ROOT_DIR.  We want the log to be kept on a permanent file system, so create a symlink to a log file over there
    if [[ ! -L tbz_service_daemon.log ]]; then
        ln -s ${tbz_service_daemon_root_dir}/tbz_service_daemon.log tbz_service_daemon.log       ### Logging for this daemon is in permanent storage
        wd_logger 1 "Created symlink 'ln -s ${tbz_service_daemon_root_dir}/tbz_service_daemon.log tbz_service_daemon.log'"
    fi

    shopt -s nullglob
    
    while true; do
        wd_logger 2 "Looking for *.tbz files in ${UPLOAD_FTP_PATH}"
        local -a tbz_file_list
        while tbz_file_list=( ${UPLOAD_FTP_PATH}/*.tbz) && [[ ${#tbz_file_list[@]} -eq 0 ]]; do
            wd_logger 2 "Found no files, so sleep and try again"
            sleep 1
        done

        ### Untar one .tbz file at a time, throwing away bad and old files, until we run out of .tbz files or we fill up the /tmp/wsprdaemon file system.
        rm -rf wsprdaemon.d wsprnet.d
        local file_system_size=$(df . | awk '/^tmpfs/{print $2}')
        local file_system_max_usage=$(( (file_system_size * 2) / 3 ))           ### Use no more than 2/3 of the /tmp/wsprdaemon file system
        wd_logger 2 "Found ${#tbz_file_list[@]} .tbz files.  The $PWD file system has ${file_system_size} kByte capacity, so use no more than ${file_system_max_usage} KB of it for temp spot and noise files"

        local valid_tbz_list=() 
        local tbz_file 
        for tbz_file in ${tbz_file_list[@]}; do
            wd_logger 3 "In $PWD: Running 'tar xf ${tbz_file}'"
            if tar xf ${tbz_file} &> /dev/null ; then
                wd_logger 2 "Found a valid tar file: ${tbz_file}"
                valid_tbz_list+=(${tbz_file})
                local file_system_usage=$(df . | awk '/^tmpfs/{print $3}')
                if [[ ${file_system_usage} -gt ${file_system_max_usage} ]]; then
                    wd_logger 1 "Filled up /tmp/wsprdaemon after extracting from ${#valid_tbz_list[@]} tbz files, so proceed to processing the spot and noise files which were extracted"
                    break
                fi
            else
                wd_logger 2 "Found invalid tar file ${tbz_file}"
                local file_mod_epoch=0
                file_mod_epoch=$( $GET_FILE_MOD_TIME_CMD ${tbz_file})
                local current_epoch=$( printf "%(%s)T" -1 )         ### faster than "date +"%s"
                local file_age=$(( ${current_epoch}  - ${file_mod_epoch} ))
                if [[ ${file_age} -gt ${MAX_TBZ_AGE_SECS-600} ]] ; then
                    if [[ ! ${tbz_file} =~ K7BIZ ]]; then   ### K7BIZ is running a corrupt config, so don't print that his .tbz files are corrupt
                        wd_logger 1 "Deleting invalid file ${tbz_file} which is ${file_age} seconds old"
                    fi
                    sudo rm ${tbz_file}
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR: when deleting invalid file ${tbz_file} which is ${file_age} seconds old, 'rm ${tbz_file}' => ${ret_code}"
                    fi
                fi
            fi
        done
        if [[ ${#valid_tbz_list[@]} -eq 0 ]]; then
            wd_logger 2 "Found no valid tar files among the ${#tbz_file_list[@]} raw tar files, so nothing to do"
            sleep 1
            continue
        fi
        ### Flush valid tbz files which we have previously processed
        declare TBZ_PROCESSED_ARCHIVE_FILE="tbz_processed_list.txt"
        declare MAX_SIZE_TBZ_PROCESSED_ARCHIVE_FILE=1000000            ### limit its size
        touch ${TBZ_PROCESSED_ARCHIVE_FILE}
        local previously_processed_tbz_list=()
        local new_tbz_list=()
        local tbz_file
        for tbz_file in ${valid_tbz_list[@]} ; do
            if grep ${tbz_file} ${TBZ_PROCESSED_ARCHIVE_FILE} > /dev/null ; then
                wd_logger 1 "Flushing '${tbz_file}' which has been previously processed"
                wd_rm ${tbz_file}
                previously_processed_tbz_list+=( ${tbz_file} )
            else
                new_tbz_list+=( ${tbz_file} )
            fi
        done
        wd_logger 1 "In checking for previously processed files: valid_tbz_list has ${#valid_tbz_list[@]} files, of which we flushed the ${#previously_processed_tbz_list[@]} files which have been previously processed."
        if [[ ${#new_tbz_list[@]} -eq 0 ]]; then
            wd_logger 1 "After flushing there are no new tbz files, so there are no new tbz files to process\n"
            sleep 1
            continue
        fi
        valid_tbz_list=( ${new_tbz_list[@]} )
        echo "${new_tbz_list[@]}" >> ${TBZ_PROCESSED_ARCHIVE_FILE}
        truncate_file ${TBZ_PROCESSED_ARCHIVE_FILE} ${MAX_SIZE_TBZ_PROCESSED_ARCHIVE_FILE}

        local valid_tbz_names_list=( ${valid_tbz_list[@]##*/} )
        local valid_reporter_names_list=( $( sort -u <<< "${valid_tbz_names_list[@]}") )
        wd_logger 1 "Extracted spot and noise files from the ${#valid_tbz_names_list[@]} valid tar files in the ftp directory which came from ${#valid_reporter_names_list[@]} different reporters: '${valid_reporter_names_list[*]}'"

        queue_files_for_mirroring ${valid_tbz_list[@]}

        ### Remove frequently found zero length spot files which are used by the decoding daemon client to signal the posting daemon that decoding has been completed when no spots are decodedgrep 
        flush_empty_spot_files

        record_spot_files
     
        record_noise_files

        wd_logger 1 "Deleting the ${#valid_tbz_list[@]} valid tar files"
        local tbz_file
        for tbz_file in ${valid_tbz_list[@]} ; do
            sudo rm ${tbz_file}              ### the tbz files are owned by the user 'noisegraphs' and we can't 'sudo wd_rm...', so 
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: while flushing ${tbz_file} recorded to TS, 'rm ...' => ${ret_code}"
            fi
        done
        wd_logger 1 "Finished deleting the tar files\n"
        sleep 1
    done
}

function get_status_tbz_service_daemon()
{
    get_status_of_daemon tbz_service_daemon ${TBZ_SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "The tbz_service_daemon is running in '${TBZ_SERVER_ROOT_DIR}'"
    else
        wd_logger -1 "The tbz_service_daemon is not running in '${TBZ_SERVER_ROOT_DIR}'"
    fi
}

function kill_tbz_service_daemon()
{
    kill_daemon tbz_service_daemon ${TBZ_SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "Killed the tbz_service_daemon running in '${TBZ_SERVER_ROOT_DIR}'"
    else
        wd_logger -1 "Failed to kill the tbz_service_daemon in '${TBZ_SERVER_ROOT_DIR}'"
    fi
}

function flush_empty_spot_files()
{
    local spot_file_list=()
    while [[ -d wsprdaemon.d/spots.d ]] && spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_spots.txt' -size 0 ) ) && [[ ${#spot_file_list[@]} -gt 0 ]]; do     ### Remove in batches of 10000 files.
        wd_logger 1 "Flushing ${#spot_file_list[@]} empty spot files"
        if [[ ${#spot_file_list[@]} -gt ${MAX_RM_ARGS} ]]; then
            wd_logger 1 "${#spot_file_list[@]} empty spot files are too many to 'rm ..' in one call, so 'rm' the first ${MAX_RM_ARGS} spot files"
            spot_file_list=(${spot_file_list[@]:0:${MAX_RM_ARGS}})
        fi
        wd_rm ${spot_file_list[@]}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: while flushing zero length files, 'rm ...' => ${ret_code}"
            exit
        fi
    done
}
function record_spot_files()
{
    wd_logger 1 "Starting"
    ### Process non-empty spot files
    while [[ -d wsprdaemon.d/spots.d ]] && spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_spots.txt')  ) && [[ ${#spot_file_list[@]} -gt 0 ]]; do
        if [[ ${#spot_file_list[@]} -gt ${MAX_RM_ARGS} ]]; then
            wd_logger 1 "${#spot_file_list[@]} spot files are too many to process in one pass, so processing the first ${MAX_RM_ARGS} spot files"
            spot_file_list=(${spot_file_list[@]:0:${MAX_RM_ARGS}})
        fi
        local ts_spots_csv_file=./ts_spots.csv    ### Take spots in wsprdaemon extended spot lines and format them into this file which can be recorded to TS 
        format_spot_lines ${ts_spots_csv_file}    ### format_spot_lines inherits the values in ${spot_file_list[@]}, it would probably be cleaner to pass them as args
        # mv ${ts_spots_csv_file} testing.csv
        # > ${ts_spots_csv_file}
       if [[ ! -s ${ts_spots_csv_file} ]]; then
            wd_logger 1 "Found zero valid spot lines in the ${#spot_file_list[@]} spot files which were extracted from ${#valid_tbz_list[@]} tar files, so there are not spots to record in the DB"
        else
            declare TS_MAX_INPUT_LINES=${PYTHON_MAX_INPUT_LINES-5000}
            declare SPLIT_CSV_PREFIX="split_spots_"
            rm -f ${SPLIT_CSV_PREFIX}*
            split --lines=${TS_MAX_INPUT_LINES} --numeric-suffixes --additional-suffix=.csv ${ts_spots_csv_file} ${SPLIT_CSV_PREFIX}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: couldn't split ${ts_spots_csv_file}.  'split --lines=${TS_MAX_INPUT_LINES} --numeric-suffixes --additional-suffix=.csv ${ts_spots_csv_file} ${SPLIT_CSV_PREFIX}' => ${ret_code}"
                exit
            fi
            local split_file_list=( ${SPLIT_CSV_PREFIX}* )
            wd_logger 2 "Split ${ts_spots_csv_file} into ${#split_file_list[@]} splitXXX.csv files"
            local split_csv_file
            for split_csv_file in ${split_file_list[@]} ; do
                wd_logger 2 "Recording spots ${split_csv_file}"
                python3 ${TS_BATCH_UPLOAD_PYTHON_CMD} --input ${split_csv_file} --sql ${TS_WD_BATCH_INSERT_SPOTS_SQL_FILE} --address localhost --ip_port ${TS_IP_PORT-5432} --database ${TS_WD_DB} --username ${TS_WD_WO_USER} --password ${TS_WD_WO_PASSWORD}
                local ret_code=$?
                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: ' ${UPLOAD_BATCH_PYTHON_CMD} ${split_csv_file} ...' => ${ret_code} when recording the $( wc -l < ${split_csv_file} ) spots in ${split_csv_file} to the wsprdaemon_spots_s table"
                else
                    wd_logger 2 "Recorded $( wc -l < ${split_csv_file} ) spots to the wsprdaemon_spots_s table from ${#spot_file_list[*]} spot files which were extracted from ${#valid_tbz_list[*]} tar files, so flush the spot file"
                fi
                #wd_rm ${split_csv_file}
            done
            wd_logger 2 "Finished recording the ${#split_file_list[@]} splitXXX.csv files"
        fi
        wd_logger 1 "Finished recording ${ts_spots_csv_file}, so flushing it and all the ${#spot_file_list[@]} spot files which created it"
        wd_rm ${ts_spots_csv_file} ${spot_file_list[@]}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: while flushing ${ts_spots_csv_file} and the ${#spot_file_list[*]} non-zero length spot files already recorded to TS, 'rm ...' => ${ret_code}"
        fi
    done
}

###  Format of the extended spot line delivered by WD clients:
###   spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin \
###                                                                       spot_rms_noise spot_c2_noise spot_for_wsprnet band \
###                                                                                        my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon (WD 3.x: wspr_packet_mode) (appended by awk: site_receiver_name)
###  Those lines are converted into a .csv file which will be recorded in TS and CH by this awk program:
###  awk 'NF == 32' ${spot_file_list[@]:0:20000}  => filters out corrupt spot lines.  Only lines with 32 fields are fed to TS.  The bash cmd line can process no more than about 23,500 arguments, so pass at most 20,000 txt file names to awk.  If there are more, they will get processed in the next loop iteration
###          
###  sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/;'"s/\"/'/g"
###          s/\S+\s+//18;  => deletes the 18th field, the 'proxy upload this spot to wsprnet.org'
###                        s/ /,/g; => replace all spaces with ','s
###                                   s/,/:/; => change the first two fields from DATE,TIME to DATE:TIME
###                                          s/./&"/11; => add '"' to get DATE:TIME"
###                                                      s/./&:/9; => insert ':' to get YYMMDD:HH:MM"
###                                                                s/./&-/4; s/./&-/2;   => insert ':' to get YY-MM-DD:HH:MM"
###                                                                                   s/^/"20/;  => insert '"20' to get "20YY-MM-DD:HH:MM"
###                                                                                             s/",0\./",/; => WSJT-x V2.2+ outputs a floating point sync value.  this chops off the leading '0.' to make it a decimal number for TS 
###                                                                                                          "s/\"/'/g" => replace those two '"'s with ''' to get '20YY-MM-DD:HH:MM'.  Since this expression includes a ', it has to be within "s

declare WD_SPOTS_TO_TS_AWK_PROGRAM=${WSPRDAEMON_ROOT_DIR}/wd_spots_to_ts.awk
function format_spot_lines()
{
    local fixed_spot_lines_file=$1

    if [[ ! -f ${WD_SPOTS_TO_TS_AWK_PROGRAM} ]]; then
        wd_logger 1 "ERROR: can't find awk program file '${WD_SPOTS_TO_TS_AWK_PROGRAM}'"
        exit 1
    fi
    awk -f ${WD_SPOTS_TO_TS_AWK_PROGRAM} ${spot_file_list[@]} > ${fixed_spot_lines_file}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'awk -f ${WD_SPOTS_TO_TS_AWK_PROGRAM}' => ${ret_code}"
        return 1
    fi
    if grep ERROR ${fixed_spot_lines_file} > fixed_error_spots.csv ; then
        grep -v ERROR ${fixed_spot_lines_file} > fixed_good_spots.csv
        mv ${fixed_spot_lines_file} good_and_bad_spots.csv
        cp fixed_good_spots.csv ${fixed_spot_lines_file}
        wd_logger 1 "ERROR: found some invalid spots which are not being recorded:\n$(< fixed_error_spots.csv)"
    fi

   wd_logger 1 "Formatted WD spot lines into TS spot lines of ${fixed_spot_lines_file}:\n$(head -n 4 ${fixed_spot_lines_file})"
    return 0
}

function record_noise_files()
{
    ### Record the noise files
    local noise_csv_file=ts_noise.csv
    local noise_file_list=()
    local max_noise_files=${MAX_RM_ARGS}
    while [[ -d wsprdaemon.d/noise.d ]] && noise_file_list=( $(find wsprdaemon.d/noise.d -name '*_noise.txt') ) && [[ ${#noise_file_list[@]} -gt 0 ]] ; do
        if [[ ${#noise_file_list[@]} -gt ${max_noise_files} ]]; then
            wd_logger 1 "${#noise_file_list[@]} noise files are too many to process in one pass, so process the first ${max_noise_files} noise files"
            noise_file_list=( ${noise_file_list[@]:0:${max_noise_files}} )
        else
            wd_logger 1 "Found ${#noise_file_list[@]} noise files to be processed"
        fi
        awk -f ${TS_NOISE_AWK_SCRIPT} ${noise_file_list[@]} > ${noise_csv_file}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: while recording ${#noise_file_list[@]} noise files, 'awk noise_file_list[@]' => ${ret_code}"
            exit
        fi
        python3 ${TS_BATCH_UPLOAD_PYTHON_CMD} --input ${noise_csv_file} --sql ${TS_WD_BATCH_INSERT_NOISE_SQL_FILE} --address localhost --ip_port ${TS_IP_PORT-5432} --database ${TS_WD_DB} --username ${TS_WD_WO_USER} --password ${TS_WD_WO_PASSWORD}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: Python failed to record $( wc -l < ${noise_csv_file}) noise lines to  the wsprdaemon_noise_s table from \${noise_file_list[@]}"
        else
            wd_logger 1 "Recorded $( wc -l < ${noise_csv_file} ) noise lines to the wsprdaemon_noise_s table from ${#noise_file_list[@]} noise files which were extracted from ${#valid_tbz_list[@]} tar files."
        fi
        wd_rm ${noise_file_list[@]}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: while flushing noise files already recorded to TS, 'rm ${spot_file_list[@]}' => ${ret_code}"
        fi
    done
}


################################## Mirror Service Section #########################################################################################
### This daemon runs on WD (logs.wsprdaemon.org), the cloud server where all WD clients deliver their tgz files

declare MIRROR_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/mirror.d   ### Where tgz files are put to be uploaded
### ID,URL[:port],FTP_USER,FTP_USER_PASSWORD              ### This is the primary target of client uploads. Mirror at WD spot/noise files to WD1
if [[ ${MIRROR_DESTINATIONS_LIST[0]-x} == "x" ]] ; then
    ### This array was not declared in the conf file, so declare it here
    declare -a MIRROR_DESTINATIONS_LIST=()
fi
declare UPLOAD_TO_MIRROR_SERVER_SECS=10     ### How often to attempt to upload tar files to log1.wsprdaemon.org
declare UPLOAD_MAX_FILE_COUNT=1000          ### curl will upload only a ?? number of files, so limit the number of files given to curl

function get_upload_spec_from_id()
{
    local _return_url_spec_variable=$1
    local target_spec_id=$2
    local mirror_spec
    
    for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]}; do
        local mirror_spec_list=( ${mirror_spec//,/ } )
        if [[ "${mirror_spec_list[0]}" == "${target_spec_id}" ]]; then
            wd_logger 1 "Found target_spec_id=${target_spec_id} in '${mirror_spec}"
            eval ${_return_url_spec_variable}="${mirror_spec}"
            return 0
        fi
    done
    wd_logger 1 "ERROR:  couldn't find target_spec_id=${target_spec_id} in MIRROR_DESTINATIONS_LIST[]"
    return 1
}

### One instance of this daemon is spawned for each mirror target defined in MIRROR_DESTINATIONS_LIST
### This daemon polls for files under its mirror source directory
function upload_to_mirror_site_daemon() {
    local my_pwd=$1            ### spawn_daemon passes us the directory we are to run in
    mkdir -p ${my_pwd}
    cd ${my_pwd}
      
    local my_upload_id=${my_pwd##*/}    ### Get the upload_id from the path to this daemon's home dir
    local url_spec
    get_upload_spec_from_id   url_spec ${my_upload_id}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: passed my home path '${my_upload_id}' which specifies an upload_id '${my_upload_id}' which can't be found in \$MIRROR_DESTINATIONS_LIST[]"
        exit ${ret_code}
    fi
     wd_logger 1 "Got url_spec=${url_spec}' for my_upload_id=${my_upload_id}"

    local url_spec_list=( ${url_spec//,/ } )
    local url_id=${url_spec_list[0]}
    local url_addr=${url_spec_list[1]}
    local url_login_name=${url_spec_list[2]}
    local url_login_password=${url_spec_list[3]}
    local upload_to_mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${url_id}   ### Where to find tbz files
    local upload_to_mirror_daemon_queue_dir=${upload_to_mirror_daemon_root_dir}/queue.d

    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    mkdir -p ${upload_to_mirror_daemon_queue_dir}
    wd_logger 1 "Looking for files in ${upload_to_mirror_daemon_queue_dir}"
    while true; do
        local files_queued_for_upload_list=( $(find ${upload_to_mirror_daemon_queue_dir} -type f) )
        if [[ ${#files_queued_for_upload_list[@]} -eq 0 ]]; then
            wd_logger 1 "Found no files to upload to url_addr=${url_addr}, url_login_name=${url_login_name}, url_login_password=${url_login_password}"
        else
            wd_logger 1 "Found ${#files_queued_for_upload_list[@]} files to upload to url_addr=${url_addr}, url_login_name=${url_login_name}, url_login_password=${url_login_password}"

            local curl_upload_file_list=(${files_queued_for_upload_list[@]::${UPLOAD_MAX_FILE_COUNT}})  ### curl limits the number of files to upload, so curl only the first UPLOAD_MAX_FILE_COUNT files 

            local curl_upload_file_string=${curl_upload_file_list[@]}
            curl_upload_file_string=${curl_upload_file_string// /,}     ### curl wants a comma-separated list of files

            wd_logger 2 "Starting curl of ${#curl_upload_file_list[@]} files using: 'curl -sS -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${url_login_name}:${url_login_password} ftp://${url_addr}/'"
            ### curl -sS == don't print progress, but print errors
            curl -sS --limit-rate ${UPLOAD_TO_MIRROR_SERVER_MAX_BYTES_PER_SECOND-20000} -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${url_login_name}:${url_login_password} ftp://${url_addr}/ > curl.log 2>&1 
            local ret_code=$?
            local curl_output=$(< curl.log)
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "Curl xfer failed: '${curl_output} ...'  => ${ret_code}, so leave files alone and try again"
            else
                wd_logger 1 "Curl xfer was successful, so delete the ${#curl_upload_file_list[@]} local files"
                wd_rm ${curl_upload_file_list[@]}
                local ret_code=$?
                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'wd_rm ${curl_upload_file_list[*]}' => ${ret_code}, but there is nothing we can do to recover"
                fi
            fi
        fi
        wd_logger 2 "Sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        wd_sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function kill_upload_to_mirror_site_daemons()
{
    wd_logger 2 "Start"

    if [[ ${#MIRROR_DESTINATIONS_LIST[@]} -eq 0 ]]; then
        wd_logger -2 "There are no mirror destinations declared in \${MIRROR_DESTINATIONS_LIST[@]}, so there are no mirror daemons running"
        return 0
    fi
 
    local mirror_spec
    for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
        local mirror_spec_list=(${mirror_spec[@]//,/ })
        local mirror_daemon_id=${mirror_spec_list[0]}
        local mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${mirror_daemon_id}

        wd_logger 2 "Killing mirror daemon with: 'kill_daemon upload_to_mirror_site_daemon ${mirror_daemon_root_dir}'"
        kill_daemon  upload_to_mirror_site_daemon ${mirror_daemon_root_dir}
        local ret_code=$?
        ### Normally upload_to_mirror_site_daemon() will print out its actions, so there is no reason to print out its return code
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger -1 "Killed a upload_to_mirror_site_daemon running in '${mirror_daemon_root_dir}'"
        else
            wd_logger -1 "The 'upload_to_mirror_site_daemon' was not running in '${mirror_daemon_root_dir}'"
        fi
    done
    wd_logger 2 "Done"
}

function mirror_daemon_kill_handler()
{
    wd_logger 1 "Got SIGTERM"
    kill_upload_to_mirror_site_daemons
    wd_logger 1 "Done killing"
    exit 0
}

function mirror_watchdog_daemon() {
    setup_verbosity_traps
    ## trap mirror_daemon_kill_handler SIGTERM

    while true; do
        local mirror_spec
        for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
            local mirror_spec_list=(${mirror_spec[@]//,/ })
            local mirror_daemon_id=${mirror_spec_list[0]}
            local mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${mirror_daemon_id}
            
            wd_logger 2 "Spawning mirror daemon for '${mirror_spec}'"
            mkdir -p ${mirror_daemon_root_dir}
            spawn_daemon  upload_to_mirror_site_daemon ${mirror_daemon_root_dir} 
            wd_logger 2 "Spawned upload_to_mirror_site_daemon with pid = $( < ${mirror_daemon_root_dir}/upload_to_mirror_site_daemon.pid)"
        done
        wd_logger 1 "Sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        wd_sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function kill_mirror_watchdog_daemon()
{
    local mirror_watchdog_daemon_home_dir=$1
    wd_logger 2 "Killing mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}" 
    kill_daemon    mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "Killed the mirror_watchdog_daemon running in '${mirror_watchdog_daemon_home_dir}'"
    else
        wd_logger -1 "The 'mirror_watchdog_daemon' was not running in '${mirror_watchdog_daemon_home_dir}'"
    fi

    ### If the mirror_watchdog_daemon() is running, then its SIG_TERM handler will have killed the individual mirror_daemons.
    ### But in the unlikely case that mirror_watchdog_daemon isn't running, make sure they are killed
    wd_logger 2 "Killing kill_upload_to_mirror_site_daemons ${mirror_watchdog_daemon_home_dir}"
    kill_upload_to_mirror_site_daemons ${mirror_watchdog_daemon_home_dir}
}

function get_status_mirror_watchdog_daemon()
{
    local mirror_watchdog_daemon_home_dir=$1
    
    wd_logger 2 "Get status for 'mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}'"
    get_status_of_daemon    mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "The mirror_watchdog_daemon is running in '${mirror_watchdog_daemon_home_dir}'"
    else
        wd_logger -1 "The mirror_watchdog_daemon is not running in '${mirror_watchdog_daemon_home_dir}'"
    fi

    if [[ ${#MIRROR_DESTINATIONS_LIST[@]} -eq 0 ]]; then
        wd_logger -2 "There are no mirror destinations declared in \${MIRROR_DESTINATIONS_LIST[@]}, so there are no mirror daemons running"
        return 0
    fi
    local mirror_spec
    for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
        local mirror_spec_list=(${mirror_spec[@]//,/ })
        local mirror_daemon_id=${mirror_spec_list[0]}
        local mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${mirror_daemon_id}

        wd_logger 2 "Get status for '${mirror_spec}'"
        get_status_of_daemon  upload_to_mirror_site_daemon ${mirror_daemon_root_dir}
        local ret_code=$?
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger -1 "The upload_to_mirror_site_daemon to site '${mirror_daemon_id}' is running in ${mirror_daemon_root_dir}"
        else
            wd_logger -1 "The upload_to_mirror_site_daemon to site '${mirror_daemon_id}' is not running in ${mirror_daemon_root_dir}"
        fi
    done
}

function queue_files_for_mirroring()
{
    local files="$@"
    local files_path_list=(${files})

    if [[ ${#MIRROR_DESTINATIONS_LIST[@]} -eq 0 ]]; then
        wd_logger 2 "There are no mirror destinations declared in \${MIRROR_DESTINATIONS_LIST[@]}, so don't queue the ${#files_path_list[@]} we were passed"
    else
        local mirror_spec
        for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
            local mirror_spec_list=(${mirror_spec[@]//,/ })
            local mirror_id=${mirror_spec_list[0]}
            local mirror_root_dir=${MIRROR_ROOT_DIR}/${mirror_id}
            local mirror_queue_dir=${mirror_root_dir}/queue.d

            mkdir -p ${mirror_queue_dir}
            wd_logger 1 "Queuing ${#files_path_list[@]} files to ${mirror_queue_dir}: '${files_path_list[*]::5}...'"
            local src_file_path
            for src_file_path in ${files_path_list[@]}; do
                local src_file_name=${src_file_path##*/}
                local dst_file_path=${mirror_queue_dir}/${src_file_name}
                if [[ -f ${dst_file_path} ]]; then
                    wd_logger 1 "WARNING: source file '${src_file_path}' already exists in '${mirror_queue_dir}', so skipping"
                else
                    ln ${src_file_path} ${dst_file_path}
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR: 'ln ${src_file_path} ${dst_file_path}' => ${ret_code}"
                    else
                        wd_logger 2 "Queued ${src_file_name} using 'ln ${src_file_path} ${dst_file_path}'"
                    fi
                fi
            done
            wd_logger 1 "Done queuing to mirror '${mirror_spec}'"
        done
        wd_logger 1 "Done queuing to mirror targets: '${MIRROR_DESTINATIONS_LIST[*]}'"
    fi
    wd_logger 2 "Done with all mirroring"
}

######################## Upload services spawned by the upload watchdog server ######################
function get_status_upload_service() 
{
    local daemon_function_name=$1

    local daemon_status_function_name=""
    local daemon_home_dir
    local entry_info
    for entry_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local entry_info_list=( ${entry_info} )
        local entry_function_name=${entry_info_list[0]}
        local entry_status_function_name=${entry_info_list[2]-get_status_of_daemon}
        local entry_home_dir=${entry_info_list[3]}

        if [[ ${daemon_function_name} == ${entry_function_name} ]]; then
            daemon_status_function_name=${entry_status_function_name}
            daemon_home_dir=${entry_home_dir}
            break
        fi
    done
    if [[ -z "${daemon_status_function_name}" ]]; then
        wd_logger 1 "ERROR:  can't find daemon_function_name='${daemon_function_name}' in '\${UPLOAD_DAEMON_LIST[@]}'"
        return 1
    fi

    wd_logger 1 "Get status of: '${daemon_function_name}' with home dir '${daemon_home_dir}' by executing '${daemon_status_function_name}'"
    ${daemon_status_function_name} ${daemon_home_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 2 "${daemon_status_function_name}() '${daemon_home_dir}' => OK"
    else
        wd_logger 1 "${daemon_status_function_name}() '${daemon_home_dir}' => ${ret_code}"
    fi
}

function get_status_upload_watchdog_services()
{
    local daemon_status_function_name=""
    local daemon_home_dir
    local entry_info
    for entry_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local entry_info_list=( ${entry_info} )
        local entry_function_name=${entry_info_list[0]}
        get_status_upload_service ${entry_function_name}
    done
    return 0
}

################################## Upload Server Top Level Daemon Watchdog Section #########################################################################################
declare -r UPLOAD_SERVERS_POLL_RATE=10       ### Seconds for the daemons to wait between polling for files

function upload_services_watchdog_daemon() 
{
    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    wd_logger 1 "Starting"
    while true; do
        wd_logger 1 "Starting to check all daemons"
        local daemon_info
        for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
            local daemon_info_list=( ${daemon_info} )
            local daemon_function_name=${daemon_info_list[0]}
            local daemon_home_dir=${daemon_info_list[3]}
            
            wd_logger 1 "Check and if needed spawn: '${daemon_function_name} ${daemon_home_dir}'"
            spawn_daemon ${daemon_function_name} ${daemon_home_dir}
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                wd_logger 1 "Spawned '${daemon_function_name} ${daemon_home_dir}'"
            else
                wd_logger 1 "ERROR: '${daemon_function_name} ${daemon_home_dir}' => ${ret_code}"
            fi
        done

        wd_sleep 600 # ${UPLOAD_SERVERS_POLL_RATE}
    done
}

function spawn_upload_services_watchdog_daemon() 
{
     spawn_daemon            upload_services_watchdog_daemon ${SERVER_ROOT_DIR}
}

function kill_upload_services_watchdog_daemon()
{
    wd_logger 2 "Kill the upload_services_watchdog_daemon by executing: 'kill_daemon upload_services_watchdog_daemon ${SERVER_ROOT_DIR}'"
    ### Kill the watchdog
    kill_daemon  upload_services_watchdog_daemon ${SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "Killed the daemon 'upload_services_watchdog_daemon' running in '${SERVER_ROOT_DIR}'"
    else
        wd_logger -1 "The 'upload_services_watchdog_daemon' was not running in '${SERVER_ROOT_DIR}'"
    fi

    ### Kill the services it spawned
    for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local daemon_info_list=( ${daemon_info} )
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_kill_function_name=${daemon_info_list[1]}
        local daemon_home_dir=${daemon_info_list[3]}

        wd_logger 2 "Kill the '${daemon_function_name} by executing: '${daemon_kill_function_name} ${daemon_home_dir}'"
        ${daemon_kill_function_name} ${daemon_home_dir}
        local ret_code=$?
        ### Normally the kill function will print out its actions, so don't print here
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 2 "'${daemon_kill_function_name} ${daemon_home_dir}' reports success"
        else
            wd_logger 2 "ERROR: '${daemon_kill_function_name} ${daemon_home_dir}' returned ${ret_code}"
        fi
    done
    wd_logger 2 "Done"
}

### Watchdog daemons which spawn service daemons have their own status report functions
function get_status_upload_services()
{
    wd_logger 2 "Get the status of the topmost daemon 'upload_services_watchdog_daemon' by executing: 'get_status_of_daemon   upload_services_watchdog_daemon ${SERVER_ROOT_DIR}'"
    get_status_of_daemon   upload_services_watchdog_daemon ${SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger -1 "The upload_services_watchdog_daemon is running in '${SERVER_ROOT_DIR}'"
    else
        wd_logger -1 "The upload_services_watchdog_daemon is not running in '${SERVER_ROOT_DIR}'"
    fi

    for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local daemon_info_list=( ${daemon_info} )
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_status_function_name=${daemon_info_list[2]}
        local daemon_home_dir=${daemon_info_list[3]}

        wd_logger 2 "Getting status for '${daemon_function_name}' spawned by 'upload_services_watchdog_daemon' by calling: ${daemon_status_function_name} ${daemon_home_dir}'"
        ${daemon_status_function_name}  ${daemon_home_dir}
    done
    return 0
}

declare SERVER_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}
declare TBZ_SERVER_ROOT_DIR=${SERVER_ROOT_DIR}/uploads.d
declare SCRAPER_ROOT_DIR=${SERVER_ROOT_DIR}/scraper.d
declare MIRROR_SERVER_ROOT_DIR=${SERVER_ROOT_DIR}/mirror.d
declare NOISE_GRAPHS_SERVER_ROOT_DIR=${SERVER_ROOT_DIR}/noise_graphs.d

declare -r UPLOAD_DAEMON_LIST=(
   "tbz_service_daemon              kill_tbz_service_daemon              get_status_tbz_service_daemon                 ${TBZ_SERVER_ROOT_DIR} "           ### Process extended_spot/noise files from WD clients
   "wsprnet_scrape_daemon           kill_wsprnet_scrape_daemon           get_status_wsprnet_scrape_daemon              ${SCRAPER_ROOT_DIR}"               ### Scrapes wspornet.org into a local DB
   "wsprnet_gap_daemon              kill_wsprnet_gap_daemon              get_status_wsprnet_gap_daemon                 ${SCRAPER_ROOT_DIR}"               ### Attempts to fill gaps reported by the wsprnet_scrape_daemon()
   "mirror_watchdog_daemon          kill_mirror_watchdog_daemon          get_status_mirror_watchdog_daemon             ${MIRROR_SERVER_ROOT_DIR}"         ### Forwards those files to WD1/WD2/...
   "noise_graphs_publishing_daemon  kill_noise_graphs_publishing_daemon  get_status_noise_graphs_publishing_daemon     ${NOISE_GRAPHS_SERVER_ROOT_DIR} "  ### Publish noise graph .png file
    )

### function which handles 'wd -u ...'
function upload_server_cmd() {
    local action=$1
    
    wd_logger 3 "Process cmd '${action}'"
    case ${action} in
        a)
            spawn_upload_services_watchdog_daemon
            ;;
        z)
            kill_upload_services_watchdog_daemon
            ;;
        s)
            get_status_upload_services
            return 0         ### Ignore error codes
            ;;
       *)
            wd_logger 1 "argument action '${action}' is invalid"
            exit 1
            ;;
    esac
}
