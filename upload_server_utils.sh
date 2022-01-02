#!/bin/bash

declare UPLOAD_FTP_PATH=~/ftp/upload       ### Where the FTP server leaves tar.tbz files
declare UPLOAD_BATCH_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/ts_upload_batch.py
declare TS_NOISE_AWK_SCRIPT=${WSPRDAEMON_ROOT_DIR}/ts_noise.awk

#     
#  local extended_line=$( printf "%6s %4s %3d %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
#                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
declare UPLOAD_SPOT_SQL='INSERT INTO wsprdaemon_spots_s (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon, mode, receiver) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s); '
declare UPLOAD_NOISE_SQL='INSERT INTO wsprdaemon_noise_s (time, site, receiver, rx_grid, band, rms_level, c2_level, ov) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);'
declare MAX_SPOT_LINES=5000  ### Record no more than this many spot lines at a time to TS and CH 
declare MAX_RM_ARGS=5000    ### Limit of the number of files in the 'rm ...' cmd line

### This deamon runs on wsprdaemon.org and processes tgz files FTPed to it by WD clients
### It optionally queues a copy of each tgz for FTP transfer to WD1
function tbz_service_daemon() 
{
    wd_logger 1 "Starting in $PWD, but will run in ${UPLOADS_TMP_ROOT_DIR}"

    local tbz_service_daemon_root_dir=$1       ### The tbz files are found in permanent storage under ~/wsprdaemon/uploads.d/..., but this daemon does all its work in a /tmp/wsprdaemon/... directory

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD

    mkdir -p ${UPLOADS_TMP_ROOT_DIR}
    cd ${UPLOADS_TMP_ROOT_DIR}

    ### wd_logger will write to $PWD in UPLOADS_TMP_ROOT_DIR.  We want the log to be kept on a permanet file system, so create a symlink to a log file over there
    if [[ ! -L tbz_service_daemon.log ]]; then
        ln -s ${tbz_service_daemon_root_dir}/tbz_service_daemon.log tbz_service_daemon.log       ### Logging for this dameon is in permanent storage
        wd_logger 1 "Created symlink 'ln -s ${tbz_service_daemon_root_dir}/tbz_service_daemon.log tbz_service_daemon.log'"
    fi

    ### Most of the file read/write happens in /tmp/wsprdsaemon
    echo "UPLOAD_SPOT_SQL=${UPLOAD_SPOT_SQL}" > upload_spot.sql       ### helps debugging from cmd line
    echo "UPLOAD_NOISE_SQL=${UPLOAD_NOISE_SQL}" > upload_noise.sql
    shopt -s nullglob
    
    while true; do
        wd_logger 2 "Looking for *.tbz files in ${UPLOAD_FTP_PATH}"
        local -a tbz_file_list
        while tbz_file_list=( ${UPLOAD_FTP_PATH}/*.tbz) && [[ ${#tbz_file_list[@]} -eq 0 ]]; do
            wd_logger 2 "Found no files, so sleep and try again"
            sleep 1
        done

        ### Untar one .tbz file at a time, throwing away bad and old files, until we run out of .tbz files or we  fill up the /tmp/wsprdemon file system.
        rm -rf wsprdaemon.d wsprnet.d
        local file_system_size=$(df . | awk '/^tmpfs/{print $2}')
        local file_system_max_usage=$(( (file_system_size * 2) / 3 ))           ### Use no more than 2/3 of the /tmp/wsprdaemon file system
        wd_logger 1 "Found ${#tbz_file_list[@]} .tbz files.  The $PWD file system has ${file_system_size} KByte capacity, so use no more than ${file_system_max_usage} KB of it for temp spot and noise files"

        local valid_tbz_list=() 
        local tbz_file 
        for tbz_file in ${tbz_file_list[@]}; do
            if tar xf ${tbz_file} &> /dev/null ; then
                wd_logger 2 "Found a valid tar file: ${tbz_file}"
                if [[ ${tbz_file} =~ AI6VN ]]; then
                    local tared_files=$(tar tf ${tbz_file})
                    wd_logger 3 "Tar file ${tbz_file} contains:\n${tared_files}"
                fi
                valid_tbz_list+=(${tbz_file})
                local file_system_usage=$(df . | awk '/^tmpfs/{print $3}')
                if [[ ${file_system_usage} -gt ${file_system_max_usage} ]]; then
                    wd_logger 1 "Filled up /tmp/wsprdaemon after extracting from ${#valid_tbz_list[@]} tbz files, so proceed to processing the spot and noise files which were extracted"
                    break
                fi
            else
                wd_logger 1 "Found invalid tar file ${tbz_file}"
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
            wd_logger 1 "Found no valid tar files among the ${#tbz_file_list[@]} raw tar files, so nothing to do"
            sleep 1
            continue
        fi
        local valid_tbz_names_list=( ${valid_tbz_list[@]##*/} )
        wd_logger 1 "Extracted spot and noise files from the ${#tbz_file_list[@]} raw tar files in the ftp directory. Next  process ${#valid_tbz_list[@]} valid tbz files: '${valid_tbz_names_list[*]:0:4}...'"

        queue_files_for_upload_to_wd1 ${valid_tbz_list[@]}

        ### Remove frequectly found zero length spot files which are  are used by the decoding daemon client to signal the posting daemon that decoding has been completed when no spots are decoded
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
    ### Process non-empty spot files
    while [[ -d wsprdaemon.d/spots.d ]] && spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_spots.txt')  ) && [[ ${#spot_file_list[@]} -gt 0 ]]; do
        if [[ ${#spot_file_list[@]} -gt ${MAX_RM_ARGS} ]]; then
            wd_logger 1 "${#spot_file_list[@]} spot files are too many to process in one pass, so processing the first ${MAX_RM_ARGS} spot files"
            spot_file_list=(${spot_file_list[@]:0:${MAX_RM_ARGS}})
        fi
        ### If the sync_quality in the third field is a float (i.e. has a '.' in it), then this spot was decoded by wsprd v2.1
        local calls_delivering_jtx_2_1_lines=( $(awk 'NF == 32 && $3  !~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
        if [[ ${#calls_delivering_jtx_2_1_lines[@]} -ne 0 ]]; then
            wd_logger 1 "ERROR: found spots from calls using WSJT-x V2.1 wsprd: ${calls_delivering_jtx_2_1_lines[@]}"
        fi
        local calls_delivering_jtx_2_2_lines=( $(awk 'NF == 32 && $3  ~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
        if [[ ${#calls_delivering_jtx_2_2_lines[@]} -ne 0 ]]; then
            wd_logger 2 "Found spots from Calls using WSJT-x V2.2 wsprd: ${calls_delivering_jtx_2_2_lines[@]}"
        fi

        local ts_spots_csv_file=./ts_spots.csv    ### Take spots in wsprdaemon extended spot lines and format them into this file which can be recorded to TS 
        format_spot_lines ${ts_spots_csv_file}

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
                wd_logger 2 "Recording ${split_csv_file}"
                python3 ${UPLOAD_BATCH_PYTHON_CMD} ${split_csv_file} "${UPLOAD_SPOT_SQL}"
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
###                                                                                             s/",0\./",/; => WSJT-x V2.2+ outputs a floting point sync value.  this chops off the leading '0.' to make it a decimal number for TS 
###                                                                                                          "s/\"/'/g" => replace those two '"'s with ''' to get '20YY-MM-DD:HH:MM'.  Since this expression includes a ', it has to be within "s
function format_spot_lines()
{
    local fixed_spot_lines_file=$1

    ### WD v2.10* spot lines will have 32 fields, while v3.0a+ spot lines will have 33 fields
    awk '{printf "%90s:%s\n", FILENAME, $0}' ${spot_file_list[@]} > file_fields.log
    if [[ -s file_fields.log ]]; then
        wd_logger 1 "Recording spots from ${#spot_file_list[@]} spot files:\n$(head -n 4 file_fields.log)"
    fi

    local TS_BAD_SPOTS_FILE=./ts_bad_spots.log
    awk 'NF != 32 && NF != 34' ${spot_file_list[@]} > ${TS_BAD_SPOTS_FILE}
    if [[ -s ${TS_BAD_SPOTS_FILE} ]] ; then
        wd_logger 1 "Found $(wc -l < ${TS_BAD_SPOTS_FILE} ) bad spots:\n$(head -n 4 ${TS_BAD_SPOTS_FILE})"
    fi

    ### the awk expression forces the tx_call and rx_id to be all upper case letters and the tx_grid and rx_grid to by UU99ll, just as is done by wsprnet.org
    ### 9/5/20:   RR: added the site's receiver name to end of each line.  It is extracted from the path of the wsprdaemon_spots.txt file
    ### 10/26.21: RR: The decoder now inserts 'none' in type 2 spots, so changed this to test only for spots without 32 fields.
    ###               Added the wspr_packet_mode 'W_2' to spot lines from WD 2.10x which are missing that last field 
    awk 'NF == 32 { 
                   if (NF == 32)  wspr_pkt_mode = "2 ";
                   $7=toupper($7); 
                   if ( $8 != "none" ) $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4))); 
                   if ( $9 !~ /^[0-9]+/ ) { for ( i=9; i<20; i++ ) { $i = $(i+1)} ; $i = "-999.0"} ;
                   $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4))); 
                   $23=toupper($23); 
                   n = split(FILENAME, a, "/"); 
                   printf "%s %s%s\n", $0, wspr_pkt_mode, a[n-2]} ' ${spot_file_list[@]}  > awk.out
    sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" awk.out > ${fixed_spot_lines_file}

    ### WD 3.0 extended spot lines have two more fields and are in the ALL_WSPR.TXT field order
    ### $6=toupper($6)     ==> call sign is all upper case
    ### 
     awk 'NF == 34 {
                   $6=toupper($6);
                   if ( $8 != "none" ) $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4)));
                   if ( $9 !~ /^[0-9]+/ ) { for ( i=9; i<20; i++ ) { $i = $(i+1)} ; $i = "-999.0"} ;
                   $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4)));
                   $23=toupper($23);
                   n = split(FILENAME, a, "/");
                   printf "%s %s%s\n", $0, wspr_pkt_mode, a[n-2]} ' ${spot_file_list[@]}  > awk.out
    sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" awk.out > /dev/null

    wd_logger 1 "Formatted WD spot lines into TS spot lines:\n$(head -n 4 ${fixed_spot_lines_file})"
    return 0
}

function record_noise_files()
{
    ### Record the noise files
    local TS_NOISE_CSV_FILE=ts_noise.csv
    local noise_file_list=()
    local max_noise_files=${MAX_RM_ARGS}
    while [[ -d wsprdaemon.d/noise.d ]] && noise_file_list=( $(find wsprdaemon.d/noise.d -name '*_wspr_noise.txt') ) && [[ ${#noise_file_list[@]} -gt 0 ]] ; do
        if [[ ${#noise_file_list[@]} -gt ${max_noise_files} ]]; then
            wd_logger 1 "${#noise_file_list[@]} noise files are too many to process in one pass, so process the first ${max_noise_files} noise files"
            noise_file_list=( ${noise_file_list[@]:0:${max_noise_files}} )
        else
            wd_logger 1 "Found ${#noise_file_list[@]} noise files to be processed"
        fi
        awk -f ${TS_NOISE_AWK_SCRIPT} ${noise_file_list[@]} > ${TS_NOISE_CSV_FILE}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: while recording ${#noise_file_list[@]} noise files, 'awk noise_file_list[@]' => ${ret_code}"
            exit
        fi
        python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_NOISE_CSV_FILE}  "${UPLOAD_NOISE_SQL}"
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: Python failed to record $( wc -l < ${TS_NOISE_CSV_FILE}) noise lines to  the wsprdaemon_noise_s table from \${noise_file_list[@]}"
        else
            wd_logger 2 "Recorded $( wc -l < ${TS_NOISE_CSV_FILE} ) noise lines to the wsprdaemon_noise_s table from ${#noise_file_list[@]} noise files which were extracted from ${#valid_tbz_list[@]} tar files."
        fi
        wd_rm ${noise_file_list[@]}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: while flushing noise files already recorded to TS, 'rm ${spot_file_list[@]}' => ${ret_code}"
        fi
    done
}


declare UPLOAD_TO_MIRROR_SERVER_URL="${UPLOAD_TO_MIRROR_SERVER_URL-}"       ### Defaults to blank, so no uploading happens

declare UPLOAD_TO_MIRROR_QUEUE_DIR=${UPLOADS_ROOT_DIR}/mirror.d            ### Where tgz files are put to be uploaded
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
        local files_queued_for_upload_list=( $(find -type f) )
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
            if [[ ${#parsed_server_url_list[@]} -ne  3  ]]; then
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
            wd_logger 1 "Found no files to upload to upload_url=${upload_url}, upload_user=${upload_user}, upload_password=${upload_password}"
        else
            wd_logger 1 "Found ${#files_queued_for_upload_list[@]} files to upload to upload_url=${upload_url}, upload_user=${upload_user}, upload_password=${upload_password}"

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
        wd_logger 2 "Queuing is disabled, so ignoring the we were passed"
    else
        local files_path_list=(${files})
        local files_name_list=(${files_path_list[@]##*/})
        wd_logger 1 "queuing ${#files_name_list[@]} files '${files_name_list[*]}' in '${UPLOAD_TO_MIRROR_QUEUE_DIR}'"
        ln ${files} ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    fi
}

declare -r UPLOAD_DAEMON_LIST=(
   "upload_to_mirror_daemon        ${UPLOADS_ROOT_DIR} "
   "tbz_service_daemon             ${UPLOADS_ROOT_DIR} "
   "wsprnet_scrape_daemon          ${WSPRDAEMON_ROOT_DIR} "
#   "noise_graph_daemon      ${UPLOADS_ROOT_DIR} "
    )

function upload_server_daemon_list_status()
{
    for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local daemon_info_list=( ${daemon_info} )
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_home_dir=${daemon_info_list[1]}

        wd_logger 2 "Get status of: '${daemon_function_name} ${daemon_home_dir}'"
        get_status_of_daemon  ${daemon_function_name} ${daemon_home_dir}
        local ret_code=$?
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 2 "get_status_of_daemon() '${daemon_function_name} ${daemon_home_dir}' => OK"
        else
            wd_logger 1 "get_status_of_daemon() '${daemon_function_name} ${daemon_home_dir}' => ${ret_code}"
        fi
    done
    exit 0
}

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
            wd_logger 2 "Check and spawn ${daemon_info}"

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
        wd_sleep ${UPLOAD_SERVERS_POLL_RATE}
    done
}

### function which handles 'wd -u ...'
function upload_server_cmd() {
    local action=$1
    
    wd_logger 2 "process cmd '${action}'"
    case ${action} in
        a)
            spawn_daemon            upload_server_watchdog_daemon ${WSPRDAEMON_ROOT_DIR}      ### Ensure there are upload daemons to consume the spots and noise data
            ;;
        z)
            set +x
            kill_daemon             upload_server_watchdog_daemon ${WSPRDAEMON_ROOT_DIR}
            return 0
            ;;
        s)
            upload_server_daemon_list_status
            return 0         ### Ignore error codes
            ;;
        *)
            wd_logger 1 "argument action '${action}' is invalid"
            exit 1
            ;;
    esac
}
