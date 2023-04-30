#!/bin/bash 

##########################################################################################################################################################
########## Section which manages creating and later/remote uploading of the spot and noise level caches ##################################################
##########################################################################################################################################################

### We cache spots and noise data under ~/wsprdaemon/.. Three upload daemons run at second 110:
### 1)  Upload spots to wsprnet.org using the curl MEPT bulk transfer method
### 2)  Upload those same spots to logs.wsprdaemon.org using 'curl ...'
### 3)  Upload noise level data to logs.wsprdaemon.org using 'curl ...'

###### uploading to wsprnet.org
### By consolidating spots for all bands of each CALL/GRID into one curl MEPT upload, we dramatically increase the efficiency of the upload for 
### both the Pi and wsprnet.org while also ensuring that when we view the wsprnet.org database sorted by CALL and TIME, the spots for
### each 2 minute cycle are displayed in ascending or descending frequency order.
### To achieve that:
### Wait for all of the CALL/GRID/BAND jobs in a two minute cycle to complete, 
###    then cat all of the wspr_spot.txt files together and sort them into a single file in time->freq order
### The posting daemons put the spots.txt files in ${UPLOADS_WSPRNET_ROOT_DIR}/CALL/..
### There is a potential problem in the way I've implemented this algorithm:
###   If all of the wsprds don't complete their decoding in the 2 minute WSPR cycle, then those tardy band results will be delayed until the following upload
###   I haven't seen that problem and if it occurs the only side effect is that a time sorted display of the wsprnet.org database may have bands that don't
###   print out in ascending frequency order for that 2 minute cycle.  Avoiding that unlikely and in any case lossless event would require a lot more logic
###   in the upload_to_wsprnet_daemon() and I would rather work on VHF/UHF support

### The spot and noise data is saved in permanent file systems, while temp files are not saved 
declare UPLOADS_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/uploads.d           ### Put under here all the spot, noise and log files so they will persist through a reboot/power cycle
declare UPLOADS_TMP_ROOT_DIR=${WSPRDAEMON_TMP_DIR}/uploads.d        ### Put under here all files which can or should be flushed when the system is started

declare UPLOADS_WSPRDAEMON_ROOT_DIR=${UPLOADS_ROOT_DIR}/wsprdaemon.d
declare UPLOADS_TMP_WSPRDAEMON_ROOT_DIR=${UPLOADS_TMP_ROOT_DIR}/wsprdaemon.d

### spots.logs.wsprdaemon.org
declare UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}/spots.d
declare UPLOADS_WSPRDAEMON_SPOTS_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_SPOTS_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/uploads.pid

declare UPLOADS_TMP_WSPRDAEMON_SPOTS_ROOT_DIR=${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}/spots.d

### noise.logs.wsprdaemon.org
declare UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}/noise.d
declare UPLOADS_WSPRDAEMON_NOISE_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/uploads.pid

declare UPLOADS_TMP_WSPRDAEMON_NOISE_ROOT_DIR=${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}/noise.d

### wsprnet.org upload daemon files
declare UPLOADS_TMP_WSPRNET_ROOT_DIR=${UPLOADS_TMP_ROOT_DIR}/wsprnet.d
mkdir -p ${UPLOADS_TMP_WSPRNET_ROOT_DIR}
declare UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/spots.txt
declare UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/curl.log
declare UPLOADS_TMP_WSPRNET_SUCCESSFUL_LOGFILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/successful_spot_uploads.log

### wsprnet.org 
declare UPLOADS_WSPRNET_ROOT_DIR=${UPLOADS_ROOT_DIR}/wsprnet.d      
declare UPLOADS_WSPRNET_SPOTS_DIR=${UPLOADS_WSPRNET_ROOT_DIR}/spots.d
declare UPLOADS_WSPRNET_PIDFILE_PATH=${UPLOADS_WSPRNET_SPOTS_DIR}/uploads.pid
declare UPLOADS_WSPRNET_LOGFILE_PATH=${UPLOADS_WSPRNET_SPOTS_DIR}/uploads.log
declare UPLOADS_WSPRNET_SUCCESSFUL_LOGFILE=${UPLOADS_WSPRNET_SPOTS_DIR}/successful_spot_uploads.log

declare UPLOADS_MAX_LOG_LINES=100000    ### Limit our local spot log file size

### The curl POST call requires the band center of the spot being uploaded, but the default is now to use curl MEPT, so this code isn't normally executed
declare MAX_SPOT_DIFFERENCE_IN_MHZ_FROM_BAND_CENTER="0.000200"  ### WSPR bands are 200 Hz wide, but we accept wsprd spots which are + or - 200 Hz of the band center

### This is an ugly and slow way to find the band center of spots.  To speed execution, put the bands with the most spots at the top of the list.
declare WSPR_BAND_CENTERS_IN_MHZ=(
       7.040100
      14.097100
      10.140200
       3.570100
       3.594100
       0.475700
       0.137500
       1.838100
       5.288700
       5.366200
      18.106100
      21.096100
      24.926100
      28.126100
      50.294500
      70.092500
     144.490500
     432.301500
    1296.501500
       0.060000
       2.500000
       5.000000
      10.000000
      15.000000
      20.000000
      25.000000
       3.330000
       7.850000
      14.670000
)

function band_center_mhz_from_spot_freq()
{
    local spot_freq=$1
    local band_center_freq
    for band_center_freq in ${WSPR_BAND_CENTERS_IN_MHZ[@]}; do
        if [[ $(bc <<< "define abs(x) {if (x<0) {return -x}; return x;}; abs(${band_center_freq} - ${spot_freq}) < ${MAX_SPOT_DIFFERENCE_IN_MHZ_FROM_BAND_CENTER}") == "1" ]]; then
            echo ${band_center_freq}
            return
        fi
    done
    echo "ERROR"
}

############
declare MAX_SPOTS_FILES=1000                                  ### Limit our search for spots to at most these many files, else a very full file tree will cause errors
declare MAX_UPLOAD_SPOTS_COUNT=${MAX_UPLOAD_SPOTS_COUNT-999}  ### Limit of number of spots to upload in one curl MEPT upload transaction
declare UPLOAD_SPOT_FILE_LIST_FILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/upload_spot_file_list.txt

### Creates a file containing a list of all the spot files to be the sources of spots in the next MEPT upload
function upload_wsprnet_create_spot_file_list_file()
{
    ### All the spots in one upload to wsprnet.org must come from one reporter (CALL_GRID), so for this upload pick the CALL_GRID of the first file in the list
    local spots_files_list=( ${@} )
    local cycle_list=( ${spots_files_list[@]%_spots.txt} )     ### Extract the YYMMDD_HHMM from each filename and then get the uniq set
    cycle_list=( ${cycle_list[@]##*/} ) 
    IFS=$'\n'; cycle_list=( $(IFS=$'\n' echo "${cycle_list[*]}" | sort -u )  ); unset IFS

    wd_logger 1 "Given list of ${#spots_files_list[@]} spot files and found ${#cycle_list[@]} WSPR cycles among them"

    local upload_file_list=()
    local upload_spots_count=0
    local cycle
    for cycle in ${cycle_list[@]} ; do
        local cycle_files_list=()
        IFS=$'\n'; cycle_files_list=( $( IFS=$'\n'; echo "${spots_files_list[*]}" | grep ${cycle} ) ) ; unset IFS

        if [[ ${#cycle_files_list[@]} -eq 0 ]]; then
            wd_logger 1 "Found the spot files from cycle ${cycle} contain no spots, but add these file to ${UPLOAD_SPOT_FILE_LIST_FILE} below and leave it to the calling function to delete them"
        else
            wd_logger 2 "Found ${#cycle_files_list[@]} spot files in cycle ${cycle}"
        fi

        local cycle_spots_count=$( cat ${cycle_files_list[@]} |  wc -l )
        local new_count=$(( ${upload_spots_count} + ${cycle_spots_count} ))
        if [[ ${new_count} -le ${MAX_UPLOAD_SPOTS_COUNT} ]]; then
            wd_logger 2 "Adding the ${cycle_spots_count} spots in cycle ${cycle} will increase upload to ${new_count} spot which is less than the max ${MAX_UPLOAD_SPOTS_COUNT} spots for an MEPT upload"
            upload_file_list+=( ${cycle_files_list[@]})
            upload_spots_count=${new_count}
        else
            wd_logger 2 "Adding the ${cycle_spots_count} spots in cycle ${cycle} to the existing ${upload_spots_count} spots will exceed the max ${MAX_UPLOAD_SPOTS_COUNT} spots for an MEPT upload, so upload list is complete"
            break
        fi
   done

   ( IFS=$'\n'; echo "${upload_file_list[*]}" > ${UPLOAD_SPOT_FILE_LIST_FILE} )       ### IFS=$'\n' causes each element to be output on a seperate line
   wd_logger 1 "Found ${upload_spots_count} spots in ${#upload_file_list[@]} spot files and saved those spots in ${UPLOAD_SPOT_FILE_LIST_FILE}"
}

function get_call_grid_from_receiver_name() {
    local target_rx=$1

    local rx_entry
    for rx_entry in "${RECEIVER_LIST[@]}" ; do
        local rx_entry_list=( ${rx_entry} )
        local rx_entry_rx_name=${rx_entry_list[0]}
        if [[ "${rx_entry_rx_name}" == "${target_rx}" ]]; then
            local safe_call_name=${rx_entry_list[2]//\//=} ### So that receiver_call_grid can be used as a directory name, any '/' in the receiver call is replaced with '='
            echo "${safe_call_name}_${rx_entry_list[3]}"
            return 0
        fi
    done
    echo ""
    return 1
}

function get_wsprnet_uploading_job_dir_path(){
    local job=$1
    local job_list=(${job/,/ })
    local receiver_name=${job_list[0]}
    local receiver_rx_band=${job_list[1]}
    local call_grid=$(get_call_grid_from_receiver_name ${receiver_name})
    local call=${call_grid%_*}
    if [[ -z "${call}" ]]; then
        [[ ${verbosity} -ge 0 ]] && echo "$(date): ERROR: can't find call for running job '${job}'"
        exit 1
    fi
    local grid=${call_grid#*_}
    if [[ -z "${call_grid}" ]]; then
        [[ ${verbosity} -ge 0 ]] && echo "$(date): ERROR: can't find grid for running job '${job}'"
        exit 1
    fi
    ### Linux directory names can't have the '/' character in them which is so common in ham call signs.  So replace all those '/' with '=' characters which (I am pretty sure) are never legal in call signs
    local call_dir_name=${call//\//=}_${grid}    
    local receiver_posting_path="${UPLOADS_WSPRNET_SPOTS_DIR}/${call_dir_name}/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_posting_path}
}

declare MAX_SPOTFILE_SECONDS=${MAX_SPOTFILE_SECONDS-40} ### By default wait for the oldest spot file to be 40 seconds old before starting an upload of it and all newer spotfiles
declare UPLOAD_SLEEP_SECONDS=10
declare -r WSPR_CYCLE_SECONDS=120
declare    WN_UPLOAD_OFFSET_SECS_IN_CYCLE=${WN_UPLOAD_OFFSET_SECS_IN_CYCLE-10}    ### Wait until 100 seconds (default) into a wspr cycle before searching for spots to upload.
function upload_to_wsprnet_daemon() {
    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    mkdir -p ${UPLOADS_WSPRNET_SPOTS_DIR}
    cd ${UPLOADS_WSPRNET_SPOTS_DIR}

    wd_logger 1 "Starting in $PWD"

    while true; do
        ### Wait until we are (default) 100 seconds into a 120 second wspr cycle before searching for spot files to upload
        ### This minimizes the number of uploads per wspr cycle by giving our server time to finish decoding all of the spots from the last cycle
        local epoch_secs=$(printf "%(%s)T\n" -1)    ### more efficient than $(date +%s)'
        local cycle_offset=$(( ${epoch_secs} % ${WSPR_CYCLE_SECONDS}  ))
        if [[ ${cycle_offset} -lt ${WN_UPLOAD_OFFSET_SECS_IN_CYCLE} ]]; then
            sleep_secs=$(( ${WN_UPLOAD_OFFSET_SECS_IN_CYCLE} - ${cycle_offset} ))
        else
            sleep_secs=$(( ${WN_UPLOAD_OFFSET_SECS_IN_CYCLE} + ( ${WSPR_CYCLE_SECONDS} - ${cycle_offset}) ))
        fi
        wd_logger 1 "Waiting ${sleep_secs} seconds until cycle offset ${WN_UPLOAD_OFFSET_SECS_IN_CYCLE} when we will start to look for spot files and for all decodes to finish"
        wd_sleep ${sleep_secs}

        ### Wait until there are some spot files, the number of spot files hasn't changed for 5 seconds, and there are no running 'wsprd' or 'jt9' jobs
        wd_logger 1 "Waiting for there to be some spot files, for the number of spot files to stablize, and for there to be no running 'wsprd' or 'jt9 jobs"
        local ps_stdout=""
        local old_spot_file_count=0
        local spots_files_list=()
        while    spots_files_list=($(find . -name '*_spots.txt') ) \
              && [[ ${#spots_files_list[@]} -eq 0 ]] \
              || [[ ${#spots_files_list[@]} -ne ${old_spot_file_count} ]] \
              && ps_stdout=$( ps aux ) \
              || echo "${ps_stdout}" | grep -q "wsprdaemon/bin/wsprd \|wsprdaemon/bin/jt9 \|derived_calc.py" ; do
            ### There are no spot files, new spots are being added, or 'wsprd' and/or 'jt9' is running
            if [[ ${#spots_files_list[@]} -eq 0 ]]; then
                wd_logger 1 "Not ready to start uploads because there are no spot files"
            elif [[ ${#spots_files_list[@]} -ne ${old_spot_file_count} ]]; then
                 wd_logger 1 "Not ready to start uploads because there are now ${#spots_files_list[@]} spot files, more than the ${old_spot_file_count} spot files we previously found"
            else
                local runnung_jobs=$(echo "${ps_stdout}" | grep 'wsprd \|jt9\|derived_calc.py' )
                wd_logger 1 "Not ready to start uploads because there are running 'wsjtx', 'jt9' and/or 'derived_calc.py' jobs:\n${runnung_jobs}"
            fi
            old_spot_file_count=${#spots_files_list[@]}
            sleep ${UPLOAD_SLEEP_SECONDS}
        done
        wd_logger 1 "There are ${#spots_files_list[@]} spot files ready for upload and 'ps' didn't find any jobs which might create more.  Here are the top 10 jobs currently running on the system:\n$(top -b -n 1 | sed -n '7,17p') "
 
        wd_logger 1 "Checking for CALL/GRID directories"
        local call_grid_dirs_list
        call_grid_dirs_list=( $(find . -mindepth 1 -maxdepth 1 -type d) )
        call_grid_dirs_list=(${call_grid_dirs_list[@]#./})       ### strip the './' off the front of each element

        if [[ ${#call_grid_dirs_list[@]} -eq 0 ]]; then
            wd_logger 1 "Found no CALL/GRID directories.  'sleep ${UPLOAD_SLEEP_SECONDS}' and search again"
            sleep ${UPLOAD_SLEEP_SECONDS}
            continue
        fi

       wd_logger 2 "Found ${#call_grid_dirs_list[@]} CALL/GRID directories:  '${call_grid_dirs_list[*]}'"

       ### All spots in an upload to wspr.org must come from a single CALL/GRID
       for call_grid_dir in ${call_grid_dirs_list[@]} ; do

           spots_files_list=( $(find ${call_grid_dir} -name '*.txt' -printf '%T@,%p\n' | sort -n ) )

           if [[ ${#spots_files_list[@]} -eq 0 ]]; then
               wd_logger 1 "Found no '*_spots.txt' files under  ${call_grid_dir}"
               continue
           fi
           wd_logger 1 "Found ${#spots_files_list[@]}  '*_spots.txt' files under  ${call_grid_dir}"

           local all_spots_file_list=( ${spots_files_list[@]#*,} )
           upload_wsprnet_create_spot_file_list_file ${all_spots_file_list[@]}
           local upload_spots_file_list=( $( < ${UPLOAD_SPOT_FILE_LIST_FILE} )  )
           wd_logger 1 "Uploading spots from ${#upload_spots_file_list[@]} files"

            ### Remove the 'none' we insert in type 2 spot line, then sort the spots in ascending order by fields of spots.txt: YYMMDD HHMM .. FREQ, then chop off the extended spot information we added which isn't used  by wsprnet.org
            sed 's/none/    /' ${upload_spots_file_list[@]} | sort -k 1,1 -k 2,2 -k 6,6n > ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE}
            local spots_to_xfer=$( wc -l < ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} )
            if [[ ${spots_to_xfer} -eq 0 ]]; then
                wd_logger 1 "Found ${#upload_spots_file_list[@]} spot files but there are no spot lines in them, so flushing those spot files"
                wd_rm ${upload_spots_file_list[@]}
                continue
            fi
            if [[ ${SIGNAL_LEVEL_UPLOAD-no} == "proxy" ]]; then
                wd_logger 1 "WD is configured for proxy uploads, so leave it to wsprdaemon.org to upload those spots. Flushing ${#upload_spots_file_list[@]} spot files"
                wd_rm ${upload_spots_file_list[@]}
                continue
            fi
            ### Upload all the spots for one CALL_GRID in one curl transaction 
            local call=${call_grid_dir%_*}
            call=${call//=//}              ### Since CALL is part of a linux directory name, it can't contain the very common '/' in call signs.  So we have replaced '/' in diretory name with '='.  Now restore the '/'
            local grid=${call_grid_dir#*_}

            wd_logger 1 "Uploading ${call} at ${grid} spots file ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} with ${spots_to_xfer} spots in it"

            local start_epoch=${EPOCHSECONDS}
            curl -m ${UPLOADS_WSPNET_CURL_TIMEOUT-300} -F version=WD_${VERSION} -F allmept=@${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} -F call=${call} -F grid=${grid} http://wsprnet.org/meptspots.php > ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH} 2>&1
            local ret_code=$?
            local curl_exec_seconds=$(( ${EPOCHSECONDS} - ${start_epoch} ))
            if [[ $ret_code -ne 0 ]]; then
                wd_logger 1 "After ${curl_exec_seconds} seconds, curl returned error code => ${ret_code} and logged:\n$( < ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})\nSo leave spot files for next loop iteration"
                continue
            fi
            local spot_xfer_counts=( $(awk '/spot.* added/{print $1 " " $4}' ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH} ) )
            if [[ ${#spot_xfer_counts[@]} -ne 2 ]]; then
                wd_logger 1 "Couldn't extract 'spots added' from the end of the server's response:\n$( tail -n 2 ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})So presume no spots were recorded and the our spots queued for the next upload attempt."
            else
                local spots_xfered=${spot_xfer_counts[0]}
                local spots_offered=${spot_xfer_counts[1]}
                wd_logger 1 "After ${curl_exec_seconds} seconds, wsprnet reported ${spots_xfered} of the ${spots_offered} offered spots were added"
                if [[ ${spots_offered} -ne ${spots_to_xfer} ]]; then
                    wd_logger 1 "ERROR: Spots offered '${spots_offered}' reported by curl doesn't match the number of spots in our upload file '${spots_to_xfer}'"
                fi
                local curl_msecs=$(awk '/milliseconds/{print $3}' ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})
                if [[ ${spots_xfered} -eq 0 ]]; then
                    wd_logger 1 "The curl upload was successful in ${curl_msecs} msecs, but 0 spots were added. Don't try them again"
                else
                    ### wsprnet responded with a message which includes the number of spots we are attempting to transfer,  
                    ### Assume we are done attempting to transfer those spots
                    #local wd_arg=$(printf "Successful curl upload has completed. ${spots_xfered} of these offered ${spots_offered} spots were accepted by wsprnet.org:\n$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE})")
                    if [[ ${spots_xfered} -ne ${spots_offered} ]]; then
                        wd_logger 1 "INFO: Successful curl upload has completed, but only ${spots_xfered} of these offered ${spots_offered} spots were accepted by wsprnet.org"
                    fi
                    wd_logger 1 "Successful curl upload has completed. ${spots_xfered} of these offered ${spots_offered} spots were accepted by wsprnet.org:\n$( <${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} )"
                fi
                wd_logger 1 "Flushing the ${#upload_spots_file_list[*]} spot files containing ${spots_offered} spots now that the spots they contain have been uploaded"
                wd_logger 2 "\n${upload_spots_file_list[*]}"
                wd_rm ${upload_spots_file_list[@]}
            fi
        done
   done
}

###################  Upload to wsprdaemon.org functions ##################
if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then

    declare TS_HOSTNAME=${TS_HOSTNAME-logs.wsprdaemon.org}
    declare HOST_RETURN_LINE_LIST=( $(host ${TS_HOSTNAME}) )
    if [[ $? -ne 0 ]]; then
        wd_logger 1 "ERROR: config file variable SIGNAL_LEVEL_UPLOAD=${SIGNAL_LEVEL_UPLOAD} is not 'no', but can't find the IP address of TS_HOSTNAME=${TS_HOSTNAME}"
        exit 1
    fi
    TS_IP_ADDRESS=${HOST_RETURN_LINE_LIST[-1]}     ### The last word on the line returned by 'host' is the IP address 
    wd_logger 2 "Configured to upload to wsprdaemon server ${TS_HOSTNAME} which has the IP address ${TS_IP_ADDRESS}"
fi

### Upload using FTP mode
### There is only one upload daemon in FTP mode
declare UPLOADS_WSPRDAEMON_FTP_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}
declare UPLOADS_WSPRDAEMON_FTP_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads.pid
declare UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads_config.txt            ### Communicates client FTP mode to FTP server
declare UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/wsprnet_spots.txt  ### On FTP server, TMP file synthesized from WD spots line

##############
declare UPLOADS_FTP_MODE_SECONDS=${UPLOADS_FTP_MODE_SECONDS-10}           ### Defaults to upload every 60 seconds
declare UPLOADS_FTP_MODE_MAX_BPS=${UPLOADS_FTP_MODE_MAX_BPS-100000}       ### Defaults to upload at 100 kbps
declare UPLOADS_MAX_FILES=${UPLOADS_MAX_FILES-10000}                      ### Limit the number of *txt files in one upload tar file. Bash limits this to < 24000
declare UPLOADS_WSPRNET_LINE_FORMAT_VERSION=1                             ### I don't expect this will change
declare UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION=2
declare UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION=1
declare UPLOADS_WSPRDAEMON_PAUSE_SECS=${UPLOADS_WSPRDAEMON_PAUSE_SECS-30} ### How long to wait after the first spot and/or noise file appears before starting to create a tar file

function upload_to_wsprdaemon_daemon() {
    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD
    local source_root_dir=${1}     ### i.e. ~/wsprdaemon/uploads.d/wsprdaemon.d/
    mkdir -p ${source_root_dir}
    cd ${source_root_dir}

    wd_logger 1 "Starting in ${PWD}. Create '${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}'"   ### Now .log and .pid files are in permanent storage

    mkdir -p ${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}

    while true; do
        ### find all *.txt files under spots.d and noise.d.
        wd_logger 1 "Starting search for *_spots.txt files"
        local -a spot_file_list=()
        while spot_file_list=( $(find -name '*_spots.txt') ) && [[ ${#spot_file_list[@]} -eq 0 ]]; do   ### bash limits the # of cmd line args we will pass to tar to about 24000
            wd_logger 2 "Found no '*_spots.txt' files, so sleeping"
            wd_sleep 2
        done
        wd_logger 1 "Found ${#spot_file_list[@]} '*spots.txt' files. Wait until there are no more new files."
        local old_file_count=${#spot_file_list[@]}
        wd_sleep ${UPLOADS_WSPRDAEMON_PAUSE_SECS}
        while spot_file_list=( $(find -name '*_spots.txt' ) ) && [[ ${#spot_file_list[@]} -ne ${old_file_count} ]]; do
            local new_file_count=${#spot_file_list[@]}
            wd_logger 1 "spot file count increased from ${old_file_count} to ${new_file_count}. Sleep 5 and check again."
            old_file_count=${new_file_count}
            wd_sleep 5
        done
        wd_logger 1 "spots file count stabilized at ${old_file_count}"
        if [[ ${#spot_file_list[@]} -gt ${UPLOADS_MAX_FILES} ]]; then
            wd_logger 1 "Found ${#spot_file_list[@]} spot files, which are more than the max ${UPLOADS_MAX_FILES} files we can process at once, so truncate the spot_file_list[]"
            spot_file_list=(${spot_file_list[@]:0${UPLOADS_MAX_FILES}} )
        fi
        wd_logger 2 "Get list of noise files"
        local -a noise_file_list=()
        noise_file_list=( $(find -name '*_noise.txt') )
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'noise_file_list=( \$(find -name '*_noise.txt') )' = ${ret_code}"
            noise_file_list=()
        else
            if [[ ${#noise_file_list[@]} -eq 0 ]]; then
                wd_logger 1 "Found no noise files to be uploaded"
            else
                if [[ ${#noise_file_list[@]} -gt ${UPLOADS_MAX_FILES} ]]; then
                    wd_logger 1 "Found ${#noise_file_list[@]} noise files, which are more than the max ${UPLOADS_MAX_FILES} files we can process at once, so truncate the noise_file_list[]"
                    noise_file_list=(${noise_file_list[@]:0${UPLOADS_MAX_FILES}} )
                else
                    wd_logger 1 "Found ${#noise_file_list[@]} noise files"
                fi
            fi
        fi

       ### Communicate this client's configuraton to the wsprdaemon.org server through lines in ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}
        echo -e "CLIENT_VERSION=${VERSION}
                 UPLOADS_WSPRNET_LINE_FORMAT_VERSION=${UPLOADS_WSPRNET_LINE_FORMAT_VERSION}
                 UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION=${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION}
                 UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION=${UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION}
                 SIGNAL_LEVEL_UPLOAD=${SIGNAL_LEVEL_UPLOAD-no} 
                 $(cat ${RUNNING_JOBS_FILE})" | sed 's/^ *//'                         > ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}         ### sed strips off the leading spaces in each line of the file
        local config_relative_path=${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH#$PWD/}
        wd_logger 2 "created ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}:\n$(cat ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH})"

        local source_file_list=( ${spot_file_list[@]} ${noise_file_list[@]} )
        if [[ ${#source_file_list[@]} -gt ${MAX_RM_ARGS} ]]; then
            wd_logger 1 "source_file_list[] has ${#source_file_list[@]} elements which is more than the allowed MAX_RM_ARGS=${MAX_RM_ARGS} elements, so truncate it"
            source_file_list=( ${source_file_list[@]:0:${MAX_RM_ARGS}} )
        fi
        ### In v2.10* the spot and noise file paths were tared from the ~/wsprdaemon/uploads.d directory, so the filenames all start with 'wsprdaemon.d/...
        ### So to preserve backwards compatibility we will mimic that behavior by executing tar from ..uploads.d and prepending 'wsprdaemon.d' to all the filenames we are tarring
        local tar_source_file_list=( wsprdaemon.d/${config_relative_path} ${source_file_list[@]/./wsprdaemon.d} )

        local tar_file_name="${SIGNAL_LEVEL_UPLOAD_ID}_$(date -u +%g%m%d_%H%M_%S).tbz"
        local tar_file_path="${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}/${tar_file_name}"
        wd_logger 1 "Creating tar file '${tar_file_path}' with:  '( cd ${UPLOADS_ROOT_DIR}; tar cfj ${tar_file_path} \${tar_source_file_list[*]})"
        ( cd ${UPLOADS_ROOT_DIR}; tar cfj ${tar_file_path} ${tar_source_file_list[*]} )
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'tar cfj ${tar_file_path} \${source_file_list[@]}' => ret_code ${ret_code}"
        else
            wd_logger 1 "Starting curl upload of '${tar_file_path}' of size $( ${GET_FILE_SIZE_CMD} ${tar_file_path} ) which contains $(cat ${source_file_list[@]} | wc -c)  bytes from ${#source_file_list[@]} spot and noise files"
            wd_logger 2 "Spots are:\n$(sort -k6,6n ${spot_file_list[*]})"
            local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-noisegraphs}
            local upload_password=${SIGNAL_LEVEL_FTP_PASSWORD-xahFie6g}    ## Hopefully this default password never needs to change
            local upload_url=${SIGNAL_LEVEL_FTP_URL-graphs.wsprdaemon.org/upload}/${tar_file_name}
            local start_epoch=${EPOCHSECONDS}
            curl -s --limit-rate ${UPLOADS_FTP_MODE_MAX_BPS} -T ${tar_file_path} --user ${upload_user}:${upload_password} ftp://${upload_url}
            local ret_code=$?
            local curl_exec_seconds=$(( ${EPOCHSECONDS} - ${start_epoch} ))
            if [[ ${ret_code} -eq  0 ]]; then
                wd_logger 1 "After ${curl_exec_seconds} seconds, curl FTP upload was successful. Deleting the ${#source_file_list[@]} \${source_file_list[@]} files which were in the uploaded tar file"fter
                wd_rm ${source_file_list[@]}
            else
                wd_logger 1 "ERROR: After ${curl_exec_seconds} seconds, 'curl -s --limit-rate ${UPLOADS_FTP_MODE_MAX_BPS} -T ${tar_file_path} --user ${upload_user}:${upload_password} ftp://${upload_url}' faiiled => ${ret_code}, so leave spot and noise files and try again"
            fi
            wd_rm ${tar_file_path} 
        fi
        wd_logger 1 "sleeping for ${UPLOADS_FTP_MODE_SECONDS} seconds"
        wd_sleep ${UPLOADS_FTP_MODE_SECONDS}
    done
}

############## Top level which spawns/kill/shows status of all of the upload daemons
declare UPLOADS_WSPRNET_SPOTS_LOG_FILE=${UPLOADS_WSPRNET_SPOTS_DIR}/upload_to_wsprnet_daemon.log
declare UPLOADS_WSPRDAEMON_SPOTS_LOG_FILE=${UPLOADS_WSPRDAEMON_ROOT_DIR}/upload_to_wsprdaemon_daemon.log

declare client_upload_daemon_list=(
   "upload_to_wsprnet_daemon         ${UPLOADS_WSPRNET_SPOTS_DIR}"
   "upload_to_wsprdaemon_daemon      ${UPLOADS_WSPRDAEMON_ROOT_DIR}"
)

function spawn_upload_daemons() 
{
    daemons_list_action  a client_upload_daemon_list
}


function kill_upload_daemons() 
{
    daemons_list_action  z client_upload_daemon_list
}

function get_status_upload_daemons()
{
    wd_logger 2 "Get status on the ${#client_upload_daemon_list[@]} daemons in client_upload_daemon_list[]"
    daemons_list_action  s client_upload_daemon_list
}

