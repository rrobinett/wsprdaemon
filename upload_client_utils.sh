##########################################################################################################################################################
########## Section which manaages creating and later/remote uploading of the spot and noise level caches ##################################################
##########################################################################################################################################################

### We cache spots and noise data under ~/wsprdaemon/.. Three upload daemons run at second 110:
### 1)  Upload spots to wsprnet.org using the curl MEPT bulk transfer metho
### 2)  Upload those same spots to logs.wsprdaemon.org using 'curl ...'
### 3)  Upload noise level data to logs.wsprdaemon.org using 'curl ...'

###### uploading to wsprnet.org
### By consolidating spots for all bands of each CALL/GRID into one curl MEPT upload, we dramtically increase the effeciency of the upload for 
### both the Pi and wsprnet.org while also ensuring that when we view the wsprnet.org database sorted by CALL and TIME, the spots for
### each 2 minute cycle are displayed in ascending or decending frequency order.
### To achieve that:
### Wait for all of the CALL/GRID/BAND jobs in a two minute cycle to complete, 
###    then cat all of the wspr_spot.txt files together and sorting them into a single file in time->freq order
### The posting daemons put the wspr_spots.txt files in ${UPLOADS_WSPRNET_ROOT_DIR}/CALL/..
### There is a potential problem in the way I've implemented this algorithm:
###   If all of the wsprds don't complete their decdoing in the 2 minute WSPR cycle, then those tardy band results will be delayed until the following upload
###   I haven't seen that problem and if it occurs the only side effect is that a time sorted display of the wsprnet.org database may have bands that don't
###   print out in ascending frequency order for that 2 minute cycle.  Avoiding that unlikely and in any case lossless event would require a lot more logic
###   in the upload_to_wsprnet_daemon() and I would rather work on VHF/UHF support

declare uploading_status="enabled"    ### For testing.  If not "enabled", the the uploading daemons will not attempt 'curl...' and leave signals and noise in local cache
declare uploading_last_record_time=0 

### We save those variables in the ~/wsprdaemon/wspdaemon.status file where they can be accessed by NN_the uploaading_daemons
declare UPLOADING_CONTROL_FILE=${WSPRDAEMON_CONFIG_FILE/.conf/.status}
if [[ ! -f ${UPLOADING_CONTROL_FILE} ]] ; then
    cat > ${UPLOADING_CONTROL_FILE} <<EOF
declare uploading_status="enabled"
declare uploading_last_record_time=0
EOF
fi

function uploading_status() {
    source ${UPLOADING_CONTROL_FILE}
    echo "Spot and noise level uploading is ${uploading_status}"
    echo "Last cache record time ${uploading_last_record_time}"
}
function uploading_status_change() {
    local var_val=$1
    local var=${var_val%=*}
    local val=${var_val#*=}
    local cur_file="$(cat ${UPLOADING_CONTROL_FILE})"
    local new_file=$(sed "/${var}=/s/=.*/=${val}/" <<< ${cur_file})
    echo "${new_file}" > ${UPLOADING_CONTROL_FILE}.tmp
    mv ${UPLOADING_CONTROL_FILE}.tmp ${UPLOADING_CONTROL_FILE}
}

### implements '-u ...' cmd
function uploading_controls(){
    local cmd=$1
    case ${cmd} in
        z)
            uploading_status_change 'uploading_status="disabled"'
            uploading_status
            ;;
        a)
            uploading_status_change 'uploading_status="enabled"'
            uploading_status
            ;;
        r)
            uploading_record_cache
            ;;
        f)
            uploading_flush_cache
            ;;
        u)
            uploading_upload_cache
            ;;
        s)
            uploading_status
            ;;
        *)
            uploading_status
            ;;
    esac
}

### The spot and noise data is saved in permanent file systems, while temp files are not saved 
declare UPLOADS_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/uploads.d           ### Put under here all the spot, noise and log files here so they will persist through a reboot/power cycle
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
declare UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/wspr_spots.txt
declare UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/curl.log
declare UPLOADS_TMP_WSPRNET_SUCCESSFUL_LOGFILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/successful_spot_uploads.log

### wsprnet.org 
declare UPLOADS_WSPRNET_ROOT_DIR=${UPLOADS_ROOT_DIR}/wsprnet.d      
declare UPLOADS_WSPRNET_SPOTS_DIR=${UPLOADS_WSPRNET_ROOT_DIR}/spots.d
declare UPLOADS_WSPRNET_PIDFILE_PATH=${UPLOADS_WSPRNET_SPOTS_DIR}/uploads.pid
declare UPLOADS_WSPRNET_LOGFILE_PATH=${UPLOADS_WSPRNET_SPOTS_DIR}/uploads.log
declare UPLOADS_WSPRNET_SUCCESSFUL_LOGFILE=${UPLOADS_WSPRNET_SPOTS_DIR}/successful_spot_uploads.log

declare UPLOADS_MAX_LOG_LINES=100000    ### LImit our local spot log file size

### The curl POST call requires the band center of the spot being uploaded, but the default is now to use curl MEPT, so this code isn't normally executed
declare MAX_SPOT_DIFFERENCE_IN_MHZ_FROM_BAND_CENTER="0.000200"  ### WSPR bands are 200z wide, but we accept wsprd spots which are + or - 200 Hz of the band center

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
declare MAX_UPLOAD_SPOTS_COUNT=${MAX_UPLOAD_SPOTS_COUNT-999}           ### Limit of number of spots to upload in one curl MEPT upload transaction
declare UPLOAD_SPOT_FILE_LIST_FILE=${UPLOADS_WSPRNET_ROOT_DIR}/upload_spot_file_list.txt

### Creates a file containing a list of all the spot files to be the sources of spots in the next MEPT upload
function upload_wsprnet_create_spot_file_list_file()
{
    local wspr_spots_files="$@"         ### i.e. a list of spot files in the format:  /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI/BAND/YYMMDD_HHMM_BAND_wspr_spots.txt
    [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() starting with list '${wspr_spots_files}'"

    local wspr_spots_files_count=$(wc -w <<< "${wspr_spots_files}")
    local wspr_spots_count=$(cat ${wspr_spots_files} | wc -l )
    local wspr_spots_root_path=$(echo "${wspr_spots_files}" | tr ' ' '\n' | head -1)  ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI/BAND/YYMMDD_HHMM_FREQ_wspr_spots.txt
          wspr_spots_root_path=${wspr_spots_root_path%/*}      ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI/BAND
          wspr_spots_root_path=${wspr_spots_root_path%/*}      ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI
          wspr_spots_root_path=${wspr_spots_root_path%/*}      ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID
    local cycles_list=$(echo "${wspr_spots_files}" | tr ' ' '\n' | sed 's;.*/;;' | cut -c 1-11 | sort -u )
    local cycles_count=$(echo "${cycles_list}" | wc -l)
    [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() under '${wspr_spots_root_path}' found ${wspr_spots_count} spots in ${wspr_spots_files_count} files from ${cycles_count} wspr cycles"

    local spots_file_list=""
    local spots_file_list_count=0
    local file_spots=""
    local file_spots_count=0
    for cycle in ${cycles_list} ; do
        local cycle_root_name="${wspr_spots_root_path}/*/*/${cycle}"  ### e.g.: /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/*/*/YYMMDD_HHMM
        [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() checking for spots in cycle ${cycle} using pattern ${cycle_root_name}"

        local cycle_files=$( ls -1  ${cycle_root_name}_* | sort -u )        ### globbing double expanding some of the files.  This hack supresses that. Probably was due to bug in creating $wspr_spots_root_path
        [[ $verbosity -ge 3 ]] && printf "$(date): upload_wsprnet_create_spot_file_list_file() checking for number of spots in \n%s\n" "${cycle_files}"

        local cycle_spots_count=$(cat ${cycle_files} | wc -l)
        [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found ${cycle_spots_count} spots in cycle ${cycle}"

        local new_count=$(( ${spots_file_list_count} + ${cycle_spots_count} ))
        if [[ ${cycle_spots_count} -eq 0 ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found the complete set of files in cycle ${cycle_root_name} contain no spots.  So flush those files"
            rm ${cycle_files}
        else
            if [[ ${new_count} -gt ${MAX_UPLOAD_SPOTS_COUNT} ]]; then
                [[ $verbosity -ge 2 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found that adding the ${cycle_spots_count} spots in cycle ${cycle} will exceed the max ${MAX_UPLOAD_SPOTS_COUNT} spots for an MEPT upload, so upload list is complete"
                echo "${spots_file_list}" > ${UPLOAD_SPOT_FILE_LIST_FILE}
                return
            fi
            spots_file_list=$(echo -e "${spots_file_list}\n${cycle_files}")
            spots_file_list_count=$(( ${spots_file_list_count} + ${cycle_spots_count}))
       fi
   done
   [[ $verbosity -ge 2 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found that all of the ${spots_file_list_count} spots in the current spot files can be uploaded"
   echo "${spots_file_list}" > ${UPLOAD_SPOT_FILE_LIST_FILE}
}

function get_call_grid_from_receiver_name() {
    local target_rx=$1

    local rx_entry
    for rx_entry in "${RECEIVER_LIST[@]}" ; do
        local rx_entry_list=( ${rx_entry} )
        local rx_entry_rx_name=${rx_entry_list[0]}
        if [[ "${rx_entry_rx_name}" == "${target_rx}" ]]; then
            echo "${rx_entry_list[2]}_${rx_entry_list[3]}"
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
    local call_dir_name=${call/\//=}_${grid}
    local receiver_posting_path="${UPLOADS_WSPRNET_SPOTS_DIR}/${call_dir_name}/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_posting_path}
}


function upload_to_wsprnet_daemon()
{
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    mkdir -p ${UPLOADS_WSPRNET_SPOTS_DIR}
    shopt -s nullglob    ### * expands to NULL if there are no file matches
    while true; do
        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() checking for spot files to upload in all running jobs directories"
        local all_call_grid_list=()
        source ${RUNNING_JOBS_FILE}
        local job
        for job in ${RUNNING_JOBS[@]} ; do
            [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprnet_daemon() check to see if job ${job} should be added to \$all_call_grid_list[@]"
            local call_grid=$( get_call_grid_from_receiver_name ${job%,*} )
            if [[ ! ${all_call_grid_list[@]} =~ ${call_grid} ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() adding '${call_grid}' to list of CALL_GRIDs to be searched for spot files to upload"
                all_call_grid_list+=(${call_grid})
            else 
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprnet_daemon() call_grid '${call_grid}' is already in \$all_call_grid_list+[@]"
            fi
        done
        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found ${#all_call_grid_list[@]} CALL_GRIDS to search for uploads: '${all_call_grid_list[@]}'"

        for call_grid in ${all_call_grid_list[@]} ; do
            local call=${call_grid%_*}
            local grid=${call_grid#*_}

            ### Get a list of all bands which are reported with this CALL_GRID.  Frequently bands are on differnet Kiwis
            local call_grid_job_list=()
            local call_grid_band_list=()
            for job in ${RUNNING_JOBS[@]} ; do
                local job_rx=${job%,*}
                local job_band=${job#*,}
                local job_call_grid=$( get_call_grid_from_receiver_name ${job_rx} )
                local job_call=${job_call_grid%_*}
                local job_grid=${job_call_grid#*_}
                if [[ ${job_call} == ${call} ]] && [[ ${job_grid} == ${grid} ]]; then
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() adding band '${job_band}' to list for call ${call} grid ${grid}"
                    call_grid_band_list+=( ${job_band} )
                    call_grid_job_list+=( ${job} )
                else
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() job '${job}' is not uploaded with call ${call} grid ${grid}"
                fi
            done
            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() '${call_grid}' reports on bands '${call_grid_band_list[@]}' from jobs '${call_grid_job_list[@]}'"

            ### Check to see that spot files are present for all bands for this CALL_GRID before uploading.  This results in time and frequency ordered printouts from wsprnet.org 
            local all_spots_file_list=()
            local missing_job_spots="no"
            for job in ${call_grid_job_list[@]} ; do
                local call_grid_rx_band_path=$( get_wsprnet_uploading_job_dir_path ${job} )
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() checking running job '${job}' spot directory ${call_grid_rx_band_path}"
                local job_spot_file_list=(${call_grid_rx_band_path}/*.txt)
                if [[ ${#job_spot_file_list[@]} -eq 0 ]]; then
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found no spot files in ${call_grid_rx_band_path}"
                    missing_job_spots="yes"
                else
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found ${#job_spot_file_list[@]} spot files in ${call_grid_rx_band_path}"
                    all_spots_file_list+=( ${job_spot_file_list[@]} )
                fi
            done

            if [[ ${missing_job_spots} == "yes" ]]; then
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprnet_daemon() found some job dirs have no spots, so wait for all job dirs to have at least one spot file"
            else
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found ${#all_spots_file_list[@]} spot files in '\${all_spots_file_list}'.  Create file with at most ${MAX_UPLOAD_SPOTS_COUNT} spots for upload"
                upload_wsprnet_create_spot_file_list_file ${all_spots_file_list[@]}
                local wspr_spots_files=( $(cat ${UPLOAD_SPOT_FILE_LIST_FILE})  )
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() uploading spots from ${#wspr_spots_files[@]} files"

                ### sort ascending by fields of wspr_spots.txt: YYMMDD HHMM .. FREQ
                cat ${wspr_spots_files[@]} | sort -k 1,1 -k 2,2 -k 6,6n > ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE}
                local    spots_to_xfer=$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} | wc -l)
                if [[ ${spots_to_xfer} -eq 0 ]] || [[ ${SIGNAL_LEVEL_UPLOAD-no} == "proxy" ]]; then
                    if [[ ${spots_to_xfer} -eq 0 ]] ; then
                        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() no spots to upload in the ${#wspr_spots_files[@]} spot files.  Purging '${wspr_spots_files[@]}'"
                    else
                        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() in proxy upload mode, so don't upload to wsprnet.org.  Purging '${wspr_spots_files[@]}'"
                    fi
                    rm -f ${all_spots_file_list[@]}
                else
                    ### Upload all the spots for one CALL_GRID in one curl transaction 
                    [[ ${verbosity} -ge 1 ]] && printf "$(date): upload_to_wsprnet_daemon() uploading ${call}_${grid} spots file ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} with $(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} | wc -l) spots in it.\n"
                    [[ ${verbosity} -ge 3 ]] && printf "$(date): upload_to_wsprnet_daemon() uploading spot file ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE}:\n$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE})\n"
                    curl -m ${UPLOADS_WSPNET_CURL_TIMEOUT-300} -F allmept=@${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} -F call=${call} -F grid=${grid} http://wsprnet.org/meptspots.php > ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH} 2>&1
                    local ret_code=$?
                    if [[ $ret_code -ne 0 ]]; then
                        [[ ${verbosity} -ge 2 ]] && echo -e "$(date): upload_to_wsprnet_daemon() curl returned error code => ${ret_code} and logged:\n$( cat ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})\nSo leave spot files for next loop iteration"
                    else
                        local spot_xfer_counts=( $(awk '/spot.* added/{print $1 " " $4}' ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH} ) )
                        if [[ ${#spot_xfer_counts[@]} -ne 2 ]]; then
                            [[ ${verbosity} -ge 2 ]] && echo -e "$(date): upload_to_wsprnet_daemon() couldn't extract 'spots added' from the end of the server's response:\n$( tail -n 2 ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})So presume no spots were recorded and the our spots queued for the next upload attempt."
                            [[ ${verbosity} -ge 2 ]] && echo -e "$(date): upload_to_wsprnet_daemon() couldn't extract 'spots added' into '${spot_xfer_counts[@]}' from curl log, so presume no spots were recorded and try again:\n$( cat ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})\n"
                        else
                            local spots_xfered=${spot_xfer_counts[0]}
                            local spots_offered=${spot_xfer_counts[1]}
                            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() wsprnet reported ${spots_xfered} of the ${spots_offered} offered spots were added"
                            if [[ ${spots_offered} -ne ${spots_to_xfer} ]]; then
                                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprnet_daemon() UNEXPECTED ERROR: spots offered '${spots_offered}' reported by curl doesn't match the number of spots in our upload file '${spots_to_xfer}'"
                            fi
                            local curl_msecs=$(awk '/milliseconds/{print $3}' ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})
                            if [[ ${spots_xfered} -eq 0 ]]; then
                                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() the curl upload was successful in ${curl_msecs} msecs, but 0 spots were added. Don't try them again"
                            else
                                ## wsprnet responded with a message which includes the number of spots we are attempting to transfer,  
                                ### Assume we are done attempting to transfer those spots
                                [[ ${verbosity} -ge 1 ]] && printf "$(date): upload_to_wsprnet_daemon() successful curl upload has completed. ${spots_xfered} of these offered ${spots_offered} spots were accepted by wsprnet.org:\n$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE})\n"
                            fi
                            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() flushing spot files '${all_spots_file_list[@]}'"
                            rm -f ${all_spots_file_list[@]}
                        fi
                    fi
                fi
            fi
        done
        ### Pole every 10 seconds for a complete set of wspr_spots.txt files
        local sleep_secs=10
        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() sleeping for ${sleep_secs} seconds"
        sleep ${sleep_secs}
    done
}

function spawn_upload_to_wsprnet_daemon()
{
    local uploading_pid_file_path=${UPLOADS_WSPRNET_PIDFILE_PATH}
    mkdir -p ${uploading_pid_file_path%/*}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_upload_to_wsprnet_daemon() INFO: uploading job with pid ${uploading_pid} is already running"
            return
        else
            echo "$(date): WARNING: spawn_upload_to_wsprnet_daemon() found a stale uploading.pid file with pid ${uploading_pid}. Deleting file ${uploading_pid_file_path}"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    mkdir -p ${UPLOADS_WSPRNET_LOGFILE_PATH%/*}
    upload_to_wsprnet_daemon > ${UPLOADS_WSPRNET_LOGFILE_PATH} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_to_wsprnet_daemon() Spawned new uploading job with PID '$!'"
}

function kill_upload_to_wsprnet_daemon()
{
    local uploading_pid_file_path=${UPLOADS_WSPRNET_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprnet_daemon() killing active upload_to_wsprnet_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_to_wsprnet_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprnet_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}

function upload_to_wsprnet_daemon_status()
{
    local uploading_pid_file_path=${UPLOADS_WSPRNET_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "The wsprnet.org    spots uploading daemon is running"
            else
                echo "$(date): upload_to_wsprnet_daemon_status() with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprnet Uploading daemon pid file records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): upload_to_wsprnet_daemon_status() found a stale uploading.pid file with pid ${uploading_pid}"
            fi
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "No wsprnet.org upload daemon is running"
        else
            echo "$(date): upload_to_wsprnet_daemon_status() found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

declare TS_HOSTNAME=logs.wsprdaemon.org
declare TS_IP_ADDRESS=$(host ${TS_HOSTNAME})
if [[ $? -eq 0 ]]; then
    TS_IP_ADDRESS=$(awk '{print $NF}' <<< "${TS_IP_ADDRESS}")
    declare MY_IP_ADDRESS=$(ifconfig eth0 2> /dev/null | awk '/inet[^6]/{print $2}')
    if [[ -n "${MY_IP_ADDRESS}" ]] && [[ "${MY_IP_ADDRESS}" == "${TS_IP_ADDRESS}" ]]  || [[ -z "${MY_IP_ADDRESS}" ]]; then
        TS_HOSTNAME=localhost
    fi
fi

function upload_line_to_wsprdaemon() {
    local file_path=$1
    local file_type=${file_path##*_wspr_}
    local file_line="${2/,/ }"   ## (probably no longer needed) Remove the ',' from an enhanced spot report line

    local ts_server_url="${TS_HOSTNAME}"

    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() upload file '${file_path}' containing line '${file_line}'"
    local line_array=(${file_line})
    local path_array=( ${file_path//\// } ) 
    local path_array_count=${#path_array[@]}
    local my_receiver_index=$(( ${path_array_count} - 3 ))
    local my_receiver=${path_array[${my_receiver_index}]}
    local path_call_grid_index=$(( ${path_array_count} - 4 ))
    local call_grid=( ${path_array[${path_call_grid_index}]/_/ } )
    local my_call_sign=${call_grid[0]/=//}
    local my_grid=${call_grid[1]}
    local file_name=${file_path##*/}
    local file_name_elements=( ${file_name//_/ } )

    case ${file_type} in
        spots.txt)
            ### in the field  order of the extended spot lines version 2 which include the wsprd v2.2 additional 2 decode values and the 'spot_for_wsprnet' signal from the client that this server should recreate a wsprnet.org spot and queue it for uploading 
            local spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_rms_noise spot_c2_noise spot_for_wsprnet band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon
            if [[ ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} -eq 1 ]]; then
                ### These fields are not present in version 1 spot files
                spot_ipass=0
                spot_nhardmin=0
                spot_for_wsprnet=0
                read  spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode                                          spot_rms_noise spot_c2_noise band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${file_line}"
            elif [[ ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} -eq 2 ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() processing VERSION = ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} extended spot line"
                read  spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_for_wsprnet spot_rms_noise spot_c2_noise band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${file_line}"
            else
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() INTERNAL ERROR: UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION = ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} is not supported"
                return 1
            fi
            local timestamp="${spot_date} ${spot_time}"
            local sql1='Insert into wsprdaemon_spots (time, band, rx_grid, rx_id, tx_call, tx_grid, "SNR", c2_noise, drift, freq, km, rx_az, rx_lat, rx_lon, tx_az, "tx_dBm", tx_lat, tx_lon, v_lat, v_lon, sync_quality, dt, decode_cycles, jitter, rms_noise, blocksize, metric, osd_decode, ipass, nhardmin, receiver) values '
            local sql2="('${timestamp}', '${band}', '${my_grid}', '${my_call_sign}', '${spot_call}', '${spot_grid}', ${spot_snr}, ${spot_c2_noise}, ${spot_drift}, ${spot_freq}, ${km}, ${rx_az}, ${rx_lat}, ${rx_lon}, ${tx_az}, ${spot_pwr}, ${tx_lat}, ${tx_lon}, ${v_lat}, ${v_lon}, ${spot_sync_quality}, ${spot_dt}, ${spot_decode_cycles}, ${spot_jitter}, ${spot_rms_noise}, ${spot_blocksize}, ${spot_metric}, ${spot_osd_decode}, ${spot_ipass}, ${spot_nhardmin}, '${my_receiver}' )"
            #echo "PGPASSWORD=Whisper2008 psql -U wdupload -d tutorial -h ${ts_server_url} -A -F, -c '${sql1} ${sql2}' &> add_derived_psql.txt"
            PGPASSWORD=Whisper2008 psql -U wdupload -d tutorial -h ${ts_server_url} -A -F, -c "${sql1} ${sql2}" &> add_derived_psql.txt

            ### If running on a server and the client signals the server to perform a proxy upload, synthesize a wsprnet.org spot line
            if [[ ${spot_for_wsprnet} -ne 0 ]]; then
                ### Don't upload rx members of a MERG* rx.  Those spot files were uploaded by the client in the tar file
                if [[ "${spot_grid}" == "none" ]]; then
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() WD spot line has no grid to add to wsprnet.org spot line"
                    spot_grid=""
                fi
                local wsprnet_spot_line="${spot_date} ${spot_time} ${spot_sync_quality} ${spot_snr} ${spot_dt} ${spot_freq} ${spot_call} ${spot_grid} ${spot_pwr} ${spot_drift} ${spot_decode_cycles} ${spot_jitter}"
                # echo "${wsprnet_spot_line}" >> ${UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH}
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() NOT YET IMPLENTED: client marked this spot '${wsprnet_spot_line}' for proxy upload to wsprnet.org byu copying it to ${UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH}"
            fi

            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon(): uploaded spot '$sql2'"  ### add c2
            if ! ${GREP_CMD} -q "INSERT" add_derived_psql.txt ; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() failed upload of spots file '${file_path}' containing line '${file_line}'. psql '${sql1} ${sql2}' returned '$(cat add_derived_psql.txt)'"
                 return 1
            fi
            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() uploaded spots file '${file_path}' containing line '${file_line}'"
            return 0
            ;;
       noise.txt)
            declare NOISE_LINE_EXPECTED_FIELD_COUNT=15     ## Each report line must include ( 3 * pre/sig/post ) + sox_fft + c2_fft + ov = 15 fields
            local line_field_count=${#line_array[@]}
            if [[ ${line_field_count} -lt ${NOISE_LINE_EXPECTED_FIELD_COUNT} ]]; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() tossing corrupt noise.txt line '${file_line}'in '${file_path}'"
                return  1
            fi
            local real_receiver_name_index=$(( ${path_array_count} - 3 ))
            local real_receiver_name=${path_array[${real_receiver_name_index}]}
            local real_receiver_maidenhead=${my_grid}
            local real_receiver_rx_band=$(get_wspr_band_name_from_freq_hz ${file_name_elements[2]})
            [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_line_to_wsprdaemon() noise freq '${file_name_elements[2]}'  => band '${real_receiver_rx_band}'"
            local sox_fft_value=${line_array[12]}
            local pre_rms_level=${line_array[3]}
            local post_rms_level=${line_array[11]}
            if [[ $(bc <<< "${post_rms_level} < ${pre_rms_level}") -eq 1 ]] ; then
                local rms_value=${post_rms_level}
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_line_to_wsprdaemon() choosing post_rms for rms_value=${post_rms_level}.  pre= ${pre_rms_level}"
            else
                local rms_value=${pre_rms_level}
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_line_to_wsprdaemon() choosing pre_rms for rms_value=${pre_rms_level}. post=${post_rms_level}"
            fi
            local c2_fft_value=${line_array[13]}
            local ov_value=${line_array[14]}
            ### Time comes from the filen2me 
            local time_year=20${file_name_elements[0]:0:2}
            local time_month=${file_name_elements[0]:2:2}
            local time_day=${file_name_elements[0]:4:2}
            local time_hour=${file_name_elements[1]:0:2}
            local time_minute=${file_name_elements[1]:2:2}
            local time_epoch=$(TZ=UTC date --date="${time_year}-${time_month}-${time_day} ${time_hour}:${time_minute}" +%s)
            local timestamp_ms=$(( ${time_epoch} * 1000))

            # G3ZIL added function to write to Timescale DB. And format the timestamp to suit Timescale DB.
            local datestamp_ts="${time_year}-${time_month}-${time_day}"
            local timestamp_ts="${time_hour}:${time_minute}"
            local time_ts="${datestamp_ts} ${timestamp_ts}:00+00"
            # 
            local sql1='Insert into wsprdaemon_noise (time,  site,receiver,  rx_grid, band, rms_level, c2_level, ov) values '
            local sql2="('${time_ts}', '${my_call_sign}', '${real_receiver_name}', '${real_receiver_maidenhead}', '${real_receiver_rx_band}', ${rms_value}, ${c2_fft_value}, ${ov_value} )"
            PGPASSWORD=Whisper2008 psql -U wdupload -d tutorial -h ${ts_server_url} -A -F, -c "${sql1}${sql2}" &> add_derived_psql.txt
            local py_retcode=$?
            if [[ ${py_retcode} -ne 0 ]]; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() upload of noise from ${real_receiver_name}/${real_receiver_rx_band}  failed"
                return ${py_retcode}
            fi
            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() upload of noise from ${real_receiver_name}/${real_receiver_rx_band} complete"
            return 0
            ;;
        *)
            [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() ERROR file_type '${file_type}' is invalid"
            return 2
            ;;
    esac
 }
 
### Polls for wspr_spots.txt or wspr_noise.txt files and uploads them to wsprdaemon.org 
function upload_to_wsprdaemon_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    local source_root_dir=$1

    mkdir -p ${source_root_dir}
    cd ${source_root_dir}
    while true; do
        [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() checking for files to upload under '${source_root_dir}/*/*'"
        shopt -s nullglob    ### * expands to NULL if there are no file matches
        local call_grid_path
        for call_grid_path in $(ls -d ${source_root_dir}/*/) ; do
            call_grid_path=${call_grid_path%/*}      ### Chop off the trailing '/'
            [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() checking for files under call_grid_path directory '${call_grid_path}'" 
            ### Spots from all recievers with the same call/grid are put into this one directory
            local call_grid=${call_grid_path##*/}
            call_grid=${call_grid/=/\/}         ### Restore the '/' in the reporter call sign
            local my_call_sign=${call_grid%_*}
            local my_grid=${call_grid#*_}
            shopt -s nullglob    ### * expands to NULL if there are no file matches
            unset all_upload_files
            local all_upload_files=( $(echo ${call_grid_path}/*/*/*.txt) )
            if [[ ${#all_upload_files[@]} -eq 0  ]] ; then
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() found no files to  upload under '${my_call_sign}_${my_grid}'"
            else
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() found upload files under '${my_call_sign}_${my_grid}': '${all_upload_files[@]}'"
                local upload_file
                for upload_file in ${all_upload_files[@]} ; do
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() starting to upload '${upload_file}"
                    local xfer_success=yes
                    local upload_line
                    while read upload_line; do
                        ### Parse the spots.txt or noise.txt line to determine the curl URL and arg`
                        [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() starting curl upload from '${upload_file}' of line ${upload_line}"
                        upload_line_to_wsprdaemon ${upload_file} "${upload_line}" 
                        local ret_code=$?
                        if [[ ${ret_code} -eq 0 ]]; then
                            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprdaemon_daemon() upload_line_to_wsprdaemon()  eports successful upload of line '${upload_line}'"
                        else
                            [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() curl reports failed upload of line '${upload_line}'"
                            xfer_success=no
                        fi
                    done < ${upload_file}

                    if [[ ${xfer_success} == yes ]]; then
                        [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() sucessfully uploaded all the lines from '${upload_file}', delete the file"
                    else 
                        [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() failed to  upload all the lines from '${upload_file}', delete the file"
                    fi
                    rm ${upload_file}
                done ## for upload_file in ${all_upload_files[@]} ; do
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() finished upload files under '${my_call_sign}_${my_grid}': '${all_upload_files[@]}'"
            fi  ### 
        done

        ### Sleep until 10 seconds before the end of the current two minute WSPR cycle by which time all of the previous cycle's spots will have been decoded
        local sleep_secs=5
        [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() sleeping for ${sleep_secs} seconds"
        sleep ${sleep_secs}
    done
}

function spawn_upload_to_wsprdaemon_daemon() {
    local uploading_root_dir=$1
    mkdir -p ${uploading_root_dir}
    local uploading_log_file_path=${uploading_root_dir}/uploads.log
    local uploading_pid_file_path=${uploading_root_dir}/uploads.pid  ### Must match UPLOADS_WSPRDAEMON_SPOTS_PIDFILE_PATH or UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH

    local uploading_tmp_root_dir=$2
    mkdir -p ${uploading_tmp_root_dir}

    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_upload_to_wsprdaemon_daemon() INFO: uploading job for '${uploading_root_dir}' with pid ${uploading_pid} is already running"
            return
        else
            echo "$(date): WARNING: spawn_upload_to_wsprdaemon_daemon() found a stale file '${uploading_pid_file_path}' with pid ${uploading_pid}, so deleting it"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    upload_to_wsprdaemon_daemon ${uploading_root_dir} ${uploading_tmp_root_dir} > ${uploading_log_file_path} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 2 ]] && echo "$(date): spawn_upload_to_wsprdaemon_daemon() Spawned new uploading job  with PID '$!'"
}

function kill_upload_to_wsprdaemon_daemon()
{
    local uploading_pid_file_path=${1}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprdaemon_daemon() killing active upload_to_wsprdaemon_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_to_wsprdaemon_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprdaemon_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}

function upload_to_wsprdaemon_daemon_status()
{
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} == "no" ]]; then
        ## wsprdaemon uploading is not enabled
        return
    fi
    local uploading_pid_file_path=$1
    if [[ ${uploading_pid_file_path} == ${UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH} ]] ; then
        local data_type="noise"
    else
        local data_type="spots"
    fi
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprdaemon ${data_type} uploading daemon with pid '${uploading_pid}' is running"
            else
                echo "$(date): upload_to_wsprdaemon_daemon_status() '${uploading_pid_file_path}' with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprdaemon uploading daemon pid file ${uploading_pid_file_path}' records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): upload_to_wsprdaemon_daemon_status() found a stale pid file '${uploading_pid_file_path}'with pid ${uploading_pid}"
            fi
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "Wsprdaemon uploading daemon found no pid file '${uploading_pid_file_path}'"
        else
            echo "$(date): upload_to_wsprdaemon_daemon_status() found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

### Upload using FTP mode
### There is only one upload daemon in FTP mode
declare UPLOADS_WSPRDAEMON_FTP_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}
declare UPLOADS_WSPRDAEMON_FTP_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads.pid
declare UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads_config.txt  ## Communicates client FTP mode to FTP server
declare UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/wsprnet_spots.txt  ## On FTP server, TMP file synthesized from WD spots line



##############
#############
### FTP upload mode functions
declare UPLOADS_FTP_MODE_SECONDS=${UPLOADS_FTP_MODE_SECONDS-10}       ### Defaults to upload every 60 seconds
declare UPLOADS_FTP_MODE_MAX_BPS=${UPLOADS_FTP_MODE_MAX_BPS-100000}   ### Defaults to upload at 100 kbps
declare UPOADS_MAX_FILES=${UPOADS_MAX_FILES-10000}                    ### Limit the number of *txt files in one upload tar file.  bash limits this to < 24000
declare UPLOADS_WSPRNET_LINE_FORMAT_VERSION=1                         ### I don't expect this will change
declare UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION=2
declare UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION=1
function ftp_upload_to_wsprdaemon_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    local source_root_dir=${UPLOADS_ROOT_DIR}

    mkdir -p ${source_root_dir}
    cd ${source_root_dir}
    while true; do
        ### find all *.txt files under spots.d and noise.d.  Don't upload wsprnet.d/... files
        [[ ${verbosity} -ge 1 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() starting search for *wspr*.txt files"
        local -a file_list
        while file_list=( $(find wsprdaemon.d/ -name '*wspr*.txt' | head -n ${UPOADS_MAX_FILES} ) ) && [[ ${#file_list[@]} -eq 0 ]]; do   ### bash limits the # of cmd line args we will pass to tar to about 24000
            [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() found no .txt files. sleeping..."
            sleep 10
        done
        [[ ${verbosity} -ge 1 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() found ${#file_list[@]} '*wspr*.txt' files. Wait until there are no more new files."
        local old_file_count=${#file_list[@]}
        sleep 20
        while file_list=( $(find wsprdaemon.d/ -name '*wspr*.txt' | head -n ${UPOADS_MAX_FILES} ) ) && [[ ${#file_list[@]} -ne ${old_file_count} ]]; do
            local new_file_count=${#file_list[@]}
            [[ ${verbosity} -ge 1 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() file count increased from ${old_file_count} to ${new_file_count}. sleep 5 and check again."
            old_file_count=${new_file_count}
            sleep 5
        done
        [[ ${verbosity} -ge 1 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() file count stabilized at ${old_file_count}, so proceed to create tar file and upload"

        ### Get list of MERGed rx for use by server FTP proxy service
        local -a MERGED_RX_LIST=()
        for rx_line in "${RECEIVER_LIST[@]}"; do
            local rx_line_array=(${rx_line})
            if [[ "${rx_line_array[0]}" =~ ^MERG ]]; then
                MERGED_RX_LIST+=(${rx_line_array[0]}:${rx_line_array[1]})
            fi
        done

        ### Communicate this client's configuraton to the wsprdaemon.org server through lines in ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}
        echo -e "CLIENT_VERSION=${VERSION}
                 UPLOADS_WSPRNET_LINE_FORMAT_VERSION=${UPLOADS_WSPRNET_LINE_FORMAT_VERSION}
                 UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION=${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION}
                 UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION=${UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION}
                 SIGNAL_LEVEL_UPLOAD=${SIGNAL_LEVEL_UPLOAD-no}
                 MERGED_RX_LIST=( ${MERGED_RX_LIST[@]} )
                 $(cat ${RUNNING_JOBS_FILE})" | sed 's/^ *//'                         > ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}         ### sed strips off the leading spaces in each line of the file
        local config_relative_path=${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH#$PWD/}
        [[ ${verbosity} -ge 2 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() created ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}:\n$(cat ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH})"

        local tar_file_name="${SIGNAL_LEVEL_UPLOAD_ID}_$(date -u +%g%m%d_%H%M_%S).tbz"
        [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() creating tar file '${tar_file_name}'"
        if ! tar cfj ${tar_file_name} ${config_relative_path} ${file_list[@]}; then
            local ret_code=$?
            [[ ${verbosity} -ge 1 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() ERROR 'tar cfj ${tar_file_name} \${file_list[@]}' => ret_code ${ret_code}"
        else
            if [[ ${verbosity} -ge 1 ]]; then
                local tar_file_size=$( ${GET_FILE_SIZE_CMD} ${tar_file_name} )
                local source_file_bytes=$(cat ${file_list[@]} | wc -c)
                echo "$(date): ftp_upload_to_wsprdaemon_daemon() uploading tar file '${tar_file_name}' of size ${tar_file_size} which contains ${source_file_bytes} bytes transfering ${#file_list[@]} spot and noise files."
            fi
            local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-noisegraphs}
            local upload_password=${SIGNAL_LEVEL_FTP_PASSWORD-xahFie6g}    ## Hopefully this default password never needs to change
            local upload_url=${SIGNAL_LEVEL_FTP_URL-graphs.wsprdaemon.org/upload}/${tar_file_name}
            curl -s --limit-rate ${UPLOADS_FTP_MODE_MAX_BPS} -T ${tar_file_name} --user ${upload_user}:${upload_password} ftp://${upload_url}
            local ret_code=$?
            if [[ ${ret_code} -eq  0 ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() curl FTP upload was successful. Deleting wspr*.txt files."
                rm -f ${file_list[@]}
            else
                [[ ${verbosity} -ge 1 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() curl FTP upload failed. ret_code = ${ret_code}"
            fi
            rm -f ${tar_file_name} 
        fi
        [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() sleeping for ${UPLOADS_FTP_MODE_SECONDS} seconds"
        sleep ${UPLOADS_FTP_MODE_SECONDS}
    done
}

function spawn_ftp_upload_to_wsprdaemon_daemon() {
    local uploading_root_dir=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}
    mkdir -p ${uploading_root_dir}
    local uploading_log_file_path=${UPLOADS_WSPRDAEMON_FTP_LOGFILE_PATH}
    local uploading_pid_file_path=${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}

    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_ftp_upload_to_wsprdaemon_daemon() INFO: uploading job for '${uploading_root_dir}' with pid ${uploading_pid} is already running"
            return
        else
            echo "$(date): WARNING: spawn_ftp_upload_to_wsprdaemon_daemon() found a stale file '${uploading_pid_file_path}' with pid ${uploading_pid}, so deleting it"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    ftp_upload_to_wsprdaemon_daemon > ${uploading_log_file_path} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_ftp_upload_to_wsprdaemon_daemon() Spawned new uploading job  with PID '$!'"
}

function kill_ftp_upload_to_wsprdaemon_daemon()
{
    local uploading_pid_file_path=${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_ftp_upload_to_wsprdaemon_daemon() killing active upload_to_wsprdaemon_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_ftp_upload_to_wsprdaemon_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): ftp_kill_upload_to_wsprdaemon_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}
function ftp_upload_to_wsprdaemon_daemon_status()
{
    local uploading_pid_file_path=${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "The wsprdaemon.org uploading daemon is running"
            else
                echo "$(date): ftp_upload_to_wsprdaemon_daemon_status() with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "The wsprdemon.org uploading daemon pid file ${uploading_pid_file_path}' records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): ftp_upload_to_wsprdaemon_daemon_status() found a stale pid file '${uploading_pid_file_path}'with pid ${uploading_pid}"
            fi
            rm -f ${uploading_pid_file_path}
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "No wsprdaemon.org uploading daemon is running"
        else
            echo "$(date): ftp_upload_to_wsprdaemon_daemon_status() found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

############## Top level which spawns/kill/shows status of all of the upload daemons
function spawn_upload_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): spawn_upload_daemons() start"
    spawn_upload_to_wsprnet_daemon
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then
        spawn_ftp_upload_to_wsprdaemon_daemon 
    fi
}

function kill_upload_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): kill_upload_daemons() start"
    kill_upload_to_wsprnet_daemon
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then
        kill_ftp_upload_to_wsprdaemon_daemon
    fi
}

function upload_daemons_status(){
    [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_daemons_status() start"
    upload_to_wsprnet_daemon_status
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then
        ftp_upload_to_wsprdaemon_daemon_status
    fi
}

