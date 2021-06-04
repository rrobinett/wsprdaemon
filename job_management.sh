##########################################################################################################################################################
########## Section which implements the job control system  ########################################################################################################
##########################################################################################################################################################
function start_stop_job() {
    local action=$1
    local receiver_name=$2
    local receiver_band=$3

    [[ $verbosity -ge 3 ]] && echo "$(date): start_stop_job() begining '${action}' for ${receiver_name} on band ${receiver_band}"
    case ${action} in
        a) 
            spawn_upload_daemons     ### Ensure there are upload daemons to consume the spots and noise data
            spawn_posting_daemon        ${receiver_name} ${receiver_band}
            ;;
        z)
            kill_posting_daemon        ${receiver_name} ${receiver_band}
            ;;
        *)
            echo "ERROR: start_stop_job() aargument action '${action}' is invalid"
            exit 1
            ;;
    esac
    add_remove_jobs_in_running_file ${action} ${receiver_name},${receiver_band}
}


##############################################################
###  -Z or -j o cmd, also called at the end of -z, also called by the watchdog daemon every two minutes
declare ZOMBIE_CHECKING_ENABLED=${ZOMBIE_CHECKING_ENABLED:=yes}

function check_for_zombie_daemon(){
    local pid_file_path=$1

    if [[ -f ${pid_file_path} ]]; then
        local daemon_pid=$(cat ${pid_file_path})
        if ps ${daemon_pid} > /dev/null ; then
            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombie_daemon() daemon pid ${daemon_pid} from '${pid_file_path} is active" 1>&2
            echo ${daemon_pid}
        else
            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombie_daemon() daemon pid ${daemon_pid} from '${pid_file_path} is dead" 1>&2
            rm -f ${pid_file_path}
        fi
    fi
}
 
function check_for_zombies() {
    local force_kill=${1:-yes}   
    local job_index
    local job_info
    local receiver_name
    local receiver_band
    local found_job="no"
    local expected_and_running_pids=""

    if [[ ${ZOMBIE_CHECKING_ENABLED} != "yes" ]]; then
        return
    fi
    ### First check if the watchdog and the upload daemons are running
    local PID_FILE_LIST="${PATH_WATCHDOG_PID} ${UPLOADS_WSPRNET_PIDFILE_PATH} ${UPLOADS_WSPRDAEMON_SPOTS_PIDFILE_PATH} ${UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH} 
                       ${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH} ${WSPRDAEMON_PROXY_PID_FILE}"
    for pid_file_path in ${PID_FILE_LIST}; do
        local daemon_pid=$(check_for_zombie_daemon ${pid_file_path} )
        if [[ -n "${daemon_pid}" ]]; then
            expected_and_running_pids="${expected_and_running_pids} ${daemon_pid}"
            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombies() is adding pid ${daemon_pid} of daemon '${pid_file_path}' to the expected pid list"
        else
            [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_zombies() found no pid for daemon '${pid_file_path}'"
        fi
    done

    ### Next check that all of the pids associated with RUNNING_JOBS are active
    ### Create ${running_rx_list} with  all the expected real rx devices. If there are MERGED jobs, then ensure that the real rx they depend upon is in ${running_rx_list}
    source ${RUNNING_JOBS_FILE}        ### populates the array RUNNING_JOBS()
    local running_rx_list=""           ### remember the rx rx devices
    for job_index in $(seq 0 $(( ${#RUNNING_JOBS[*]} - 1 )) ) ; do
        local job_info=(${RUNNING_JOBS[job_index]/,/ } )
        local receiver_name=${job_info[0]}
        local receiver_band=${job_info[1]}
        local job_id=${receiver_name},${receiver_band}
             
        if [[ ! "${receiver_name}" =~ ^MERG ]]; then
            ### This is a KIWI,AUDIO or SDR reciever
            if [[ ${running_rx_list} =~ " ${job_id} " ]] ; then
                [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() real rx job ${job_id}' is already listed in '${running_rx_list}'\n"
            else
                [[ ${verbosity} -ge 3 ]] && printf "$(date): check_for_zombies() real rx job ${job_id}' is not listed in running_rx_list ${running_rx_list}', so add it\n"
                ### Add it to the rx list
                running_rx_list="${running_rx_list} ${job_id}"
                ### Verify that pid files exist for it
                local rx_dir_path=$(get_recording_dir_path ${receiver_name} ${receiver_band})
                local posting_dir_path=$(get_posting_dir_path ${receiver_name} ${receiver_band})
                shopt -s nullglob
                local rx_pid_files=$( ls ${rx_dir_path}/{kiwi_recorder,recording,decode}.pid ${posting_dir_path}/posting.pid 2> /dev/null | tr '\n' ' ')
                shopt -u nullglob
                local expected_pid_files=4
                if [[ ${receiver_name} =~ ^AUDIO ]]; then
                    expected_pid_files=3
                elif [[ ${receiver_name} =~ ^SDR ]]; then
                    expected_pid_files=3
                fi
                if [[ $(wc -w <<< "${rx_pid_files}") -eq ${expected_pid_files}  ]]; then
                    [[ ${verbosity} -ge 3 ]] && printf "$(date): check_for_zombies() adding the ${expected_pid_files} expected real rx ${receiver_name}' recording pid files\n"
                    local pid_file
                    for pid_file in ${rx_pid_files} ; do
                        local pid_value=$(cat ${pid_file})
                        if ps ${pid_value} > /dev/null; then
                            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombies() rx pid ${pid_value} found in '${pid_file}'is active"
                            expected_and_running_pids="${expected_and_running_pids} ${pid_value}"
                        else
                            [[ ${verbosity} -ge 1 ]] && echo "$(date): check_for_zombies() ERROR: rx pid ${pid_value} found in '${pid_file}' is not active, so deleting that pid file"
                            rm -f ${pid_file}
                        fi
                    done
                else
                    [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() WARNING: real rx ${receiver_name}' recording dir missing some or all of the expeted 4 pid files.  Found only: '${rx_pid_files}'\n"
                fi
            fi
        else  ### A MERGED device
            local merged_job_id=${job_id}
            ### This is a MERGED device.  Get its posting.pid
            local rx_dir_path=$(get_posting_dir_path ${receiver_name} ${receiver_band})
            local posting_pid_file=${rx_dir_path}/posting.pid
            if [[ ! -f ${posting_pid_file} ]]; then
                [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}' has no pid file '${posting_pid_file}'\n"
            else ## Has a posting.od file
                local pid_value=$(cat ${posting_pid_file})
                if ! ps  ${pid_value} > /dev/null ; then
                    [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}'  pid '${pid_value}' is dead from pid file '${posting_pid_file}'\n"
                else ### posting.pid is active
                    ### Add the postind.pid to the list and check the real rx devices 
                    [[ ${verbosity} -ge 2 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}'  pid '${pid_value}' is active  from file '${posting_pid_file}'\n"
                    expected_and_running_pids="${expected_and_running_pids} ${pid_value}"

                    ### Check the MERGED device's real rx devices are in the list
                    local merged_receiver_address=$(get_receiver_ip_from_name ${receiver_name})   ### In a MERGed rx, the real rxs feeding it are in a comma-seperated list in the IP column
                    local merged_receiver_name_list=${merged_receiver_address//,/ }
                    local rx_device 
                    for rx_device in ${merged_receiver_name_list}; do  ### Check each real rx
                        ### Check each real rx
                        job_id=${rx_device},${receiver_band}
                        if ${GREP_CMD} -wq ${job_id} <<< "${running_rx_list}" ; then 
                            [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}' is fed by real job '${job_id}' which is already listed in '${running_rx_list}'\n"
                        else ### Add new real rx
                            [[ ${verbosity} -ge 2 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}' is fed by real job '${job_id}' which needs to be added to '${running_rx_list}'\n"
                            running_rx_list="${running_rx_list} ${rx_device}"
                            ### Verify that pid files exist for it
                            local rx_dir_path=$(get_recording_dir_path ${rx_device} ${receiver_band})
                            shopt -s nullglob
                            local rx_pid_files=$( ls ${rx_dir_path}/{kiwi_recorder,recording,decode}.pid 2> /dev/null | tr '\n' ' ' )
                            shopt -u nullglob
                            local expected_pid_files=3
                            if [[ ${rx_device} =~ ^AUDIO ]]; then
                                expected_pid_files=2
                            elif [[ ${rx_device} =~ ^SDR ]]; then
                                expected_pid_files=2
                            fi
                            if [[ $(wc -w <<< "${rx_pid_files}") -ne  ${expected_pid_files} ]]; then
                                [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() WARNING: real rx ${rx_device}' recording dir missing some or all of the expeted 3 pid files.  Found only: '${rx_pid_files}'\n"
                            else  ### Check all 3 pid files 
                                [[ ${verbosity} -ge 2 ]] && printf "$(date): check_for_zombies() adding the 3 expected real rx ${rx_device}' pid files\n"
                                local pid_file
                                for pid_file in ${rx_pid_files} ; do ### Check one pid 
                                    local pid_value=$(cat ${pid_file})
                                    if ps ${pid_value} > /dev/null; then ### Is pid active
                                        [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_zombies() rx pid ${pid_value} found in '${pid_file}'is active"
                                        expected_and_running_pids="${expected_and_running_pids} ${pid_value}"
                                    else
                                        [[ ${verbosity} -ge 1 ]] && echo "$(date): check_for_zombies() ERROR: rx pid ${pid_value} found in '${pid_file}' is not active, so deleting that pid file"
                                        rm -f ${pid_file}
                                    fi ### Is pid active
                                done ### Check one pid
                            fi ### Check all 3 pid files
                        fi ### Add new real rx
                    done ### Check each real rx
                fi ### posting.pid is active
            fi ## Has a posting.od file
        fi ## A MERGED device
    done

    ### We have checked all the pid files, now look at all running kiwirecorder programs reported by 'ps'
    local kill_pid_list=""
    local ps_output_lines=$(ps auxf)
    local ps_running_list=$( awk '/wsprdaemon/ && !/vi / && !/ssh/ && !/scp/ && !/-v*[zZ]/ && !/\.log/ && !/wav_window.py/ && !/psql/ && !/derived_calc.py/ && !/curl/ && !/avahi-daemon/ && !/frpc/ {print $2}' <<< "${ps_output_lines}" )
    [[ $verbosity -ge 3 ]] && echo "$(date): check_for_zombies() filtered 'ps usxf' output '${ps_output_lines}' to get list '${ps_running_list}"
    for running_pid in ${ps_running_list} ; do
       if ${GREP_CMD} -qw ${running_pid} <<< "${expected_and_running_pids}"; then
           [[ $verbosity -ge 3 ]] && printf "$(date): check_for_zombies() Found running_pid '${running_pid}' in expected_pids '${expected_and_running_pids}'\n"
       else
           if [[ $verbosity -ge 2 ]] ; then
               printf "$(date): check_for_zombies() WARNING: did not find running_pid '${running_pid}' in expected_pids '${expected_and_running_pids}'\n"
               ${GREP_CMD} -w ${running_pid} <<< "${ps_output_lines}"
           fi
           if ps ${running_pid} > /dev/null; then
               [[ $verbosity -ge 1 ]] && printf "$(date): check_for_zombies() adding running  zombie '${running_pid}' to kill list\n"
               kill_pid_list="${kill_pid_list} ${running_pid}"
           else
               [[ $verbosity -ge 2 ]] && printf "$(date): check_for_zombies()  zombie ${running_pid} is phantom which is no longer running\n"
           fi
       fi
    done
    local ps_running_count=$(wc -w <<< "${ps_running_list}")
    local ps_expected_count=$(wc -w <<< "${expected_and_running_pids}")
    local ps_zombie_count=$(wc -w <<< "${kill_pid_list}")
    if [[ -n "${kill_pid_list}" ]]; then
        if [[ "${force_kill}" != "yes" ]]; then
            echo "check_for_zombies() pid $$ expected ${ps_expected_count}, found ${ps_running_count}, so there are ${ps_zombie_count} zombie pids: '${kill_pid_list}'"
            read -p "Do you want to kill these PIDs? [Yn] > "
            REPLY=${REPLY:-Y}     ### blank or no response change to 'Y'
            if [[ ${REPLY^} == "Y" ]]; then
                force_kill="yes"
            fi
        fi
        if [[ "${force_kill}" == "yes" ]]; then
            if [[ $verbosity -ge 1 ]]; then
                echo "$(date): check_for_zombies() killing pids '${kill_pid_list}'"
                ps ${kill_pid_list}
            fi
            kill -9 ${kill_pid_list}
        fi
    else
        ### Found no zombies
        [[ $verbosity -ge 2 ]] && echo "$(date): check_for_zombies() pid $$ expected ${ps_expected_count}, found ${ps_running_count}, so there are no zombies"
    fi
}


##############################################################
###  -j s cmd   Argument is 'all' OR 'RECEIVER,BAND'
function show_running_jobs() {
    local args_val=${1:-all}      ## -j s  defaults to 'all'
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    local show_band=${args_array[1]:-}
    if [[ "${show_target}" != "all" ]] && [[ -z "${show_band}" ]]; then
        echo "ERROR: missing RECEIVER,BAND argument"
        exit 1
    fi
    local job_index
    local job_info
    local receiver_name_list=()
    local receiver_name
    local receiver_band
    local found_job="no"
 
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "There is no RUNNING_JOBS_FILE '${RUNNING_JOBS_FILE}'"
        return 1
    fi
    source ${RUNNING_JOBS_FILE}
    
    for job_index in $(seq 0 $(( ${#RUNNING_JOBS[*]} - 1 )) ) ; do
        job_info=(${RUNNING_JOBS[job_index]/,/ } )
        receiver_band=${job_info[1]}
        if [[ ${job_info[0]} =~ ^MERG ]]; then
            ### For merged rx devices, there is only one posting pid, but one or more recording and decoding pids
            local merged_receiver_name=${job_info[0]}
            local receiver_address=$(get_receiver_ip_from_name ${merged_receiver_name})
            receiver_name_list=(${receiver_address//,/ })
            printf "%2s: %12s,%-4s merged posting  %s (%s)\n" ${job_index} ${merged_receiver_name} ${receiver_band} "$(get_posting_status ${merged_receiver_name} ${receiver_band})" "${receiver_address}"
        else
            ### For a simple rx device, the recording, decdoing and posting pids are all in the same directory
            receiver_name=${job_info[0]}
            receiver_name_list=(${receiver_name})
            printf "%2s: %12s,%-4s posting  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_posting_status   ${receiver_name} ${receiver_band})"
        fi
        if [[ ${verbosity} -gt 0 ]]; then
            for receiver_name in ${receiver_name_list[@]}; do
                if [[ ${show_target} == "all" ]] || ( [[ ${receiver_name} == ${show_target} ]] && [[ ${receiver_band} == ${show_band} ]] ) ; then
                    printf "%2s: %12s,%-4s capture  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_recording_status ${receiver_name} ${receiver_band})"
                    printf "%2s: %12s,%-4s decode   %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_decoding_status  ${receiver_name} ${receiver_band})"
                    found_job="yes"
                fi
            done
            if [[ ${found_job} == "no" ]]; then
                if [[ "${show_target}" == "all" ]]; then
                    echo "No spot recording jobs are running"
                else
                    echo "No job found for RECEIVER '${show_target}' BAND '${show_band}'"
                fi
           fi
        fi
    done
}

##############################################################
###  -j l RECEIVER,BAND cmd
function tail_wspr_decode_job_log() {
    local args_val=${1:-}
    if [[ -z "${args_val}" ]]; then
        echo "ERROR: missing ',RECEIVER,BAND'"
        exit 1
    fi
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    if [[ -z "${show_target}" ]]; then
        echo "ERROR: missing RECEIVER"
        exit 1
    fi
    local show_band=${args_array[1]:-}
    if [[ -z "${show_band}" ]]; then
        echo "ERROR: missing BAND argument"
        exit 1
    fi
    local job_index
    local job_info
    local receiver_name
    local receiver_band
    local found_job="no"

    source ${RUNNING_JOBS_FILE}

    for job_index in $(seq 0 $(( ${#RUNNING_JOBS[*]} - 1 )) ) ; do
        job_info=(${RUNNING_JOBS[${job_index}]/,/ })
        receiver_name=${job_info[0]}
        receiver_band=${job_info[1]}
        if [[ ${show_target} == "all" ]] || ( [[ ${receiver_name} == ${show_target} ]] && [[ ${receiver_band} == ${show_band} ]] )  ; then
            printf "%2s: %12s,%-4s capture  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_recording_status ${receiver_name} ${receiver_band})"
            printf "%2s: %12s,%-4s decode   %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_decoding_status  ${receiver_name} ${receiver_band})"
            printf "%2s: %12s,%-4s posting  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_posting_status   ${receiver_name} ${receiver_band})"
            local decode_log_file=$(get_recording_dir_path ${receiver_name} ${receiver_band})/decode.log
            if [[ -f ${decode_log_file} ]]; then
                less +F ${decode_log_file}
            else
                echo "ERROR: can't file expected decode log file '${decode_log_file}"
                exit 1
            fi
            found_job="yes"
        fi
    done
    if [[ ${found_job} == "no" ]]; then
        echo "No job found for RECEIVER '${show_target}' BAND '${show_band}'"
    fi
}

###
function add_remove_jobs_in_running_file() {
    local action=$1    ## 'a' or 'z'
    local job=$2       ## in form RECEIVER,BAND

    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "RUNNING_JOBS=( )" > ${RUNNING_JOBS_FILE}
    fi
    source ${RUNNING_JOBS_FILE}
    case $action in
        a)
            if ${GREP_CMD} -w ${job} ${RUNNING_JOBS_FILE} > /dev/null; then
                ### We come here when restarting a dead capture jobs, so this condition is already printed out
                [[ $verbosity -ge 2 ]] && \
                    echo "$(date): add_remove_jobs_in_running_file():  WARNING: found job ${receiver_name},${receiver_band} was already listed in ${RUNNING_JOBS_FILE}"
                return 1
            fi
            source ${RUNNING_JOBS_FILE}
            RUNNING_JOBS+=( ${job} )
            ;;
        z)
            if ! ${GREP_CMD} -w ${job} ${RUNNING_JOBS_FILE} > /dev/null; then
                echo "$(date) WARNING: start_stop_job(remove) found job ${receiver_name},${receiver_band} was already not listed in ${RUNNING_JOBS_FILE}"
                return 2
            fi
            ### The following line is a little obscure, so here is an explanation
            ###  We are deleting the version of RUNNING_JOBS[] to delete one job.  Rather than loop through the array I just use sed to delete it from
            ###  the array declaration statement in the ${RUNNING_JOBS_FILE}.  So this statement redeclares RUNNING_JOBS[] with the delect job element removed 
            eval $( sed "s/${job}//" ${RUNNING_JOBS_FILE})
            ;;
        *)
            echo "$(date): add_remove_jobs_in_running_file(): ERROR: action ${action} invalid"
            return 2
    esac
    ### Sort RUNNING_JOBS by ascending band frequency
    IFS=$'\n'
    RUNNING_JOBS=( $(sort --field-separator=, -k 2,2n <<< "${RUNNING_JOBS[*]-}") )    ### TODO: this doesn't sort.  
    unset IFS
    echo "RUNNING_JOBS=( ${RUNNING_JOBS[*]-} )" > ${RUNNING_JOBS_FILE}
}

###

#############
###################
declare -r HHMM_SCHED_FILE=${WSPRDAEMON_ROOT_DIR}/hhmm.sched      ### Contains the schedule from kwiwwspr.conf with sunrise/sunset entries fixed in HHMM_SCHED[]
declare -r EXPECTED_JOBS_FILE=${WSPRDAEMON_ROOT_DIR}/expected.jobs    ### Based upon current HHMM, this is the job list from EXPECTED_JOBS_FILE[] which should be running in EXPECTED_LIST[]
declare -r RUNNING_JOBS_FILE=${WSPRDAEMON_ROOT_DIR}/running.jobs      ### This is the list of jobs we programmed to be running in RUNNING_LIST[]

### Once per day, cache the sunrise/sunset times for the grids of all receivers
function update_suntimes_file() {
    if [[ -f ${SUNTIMES_FILE} ]] \
        && [[ $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ) -gt $( $GET_FILE_MOD_TIME_CMD ${WSPRDAEMON_CONFIG_FILE} ) ]] \
        && [[ $(( $(date +"%s") - $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ))) -lt ${MAX_SUNTIMES_FILE_AGE_SECS} ]] ; then
        ## Only update once a day
        return
    fi
    rm -f ${SUNTIMES_FILE}
    source ${WSPRDAEMON_CONFIG_FILE}
    local maidenhead_list=$( ( IFS=$'\n' ; echo "${RECEIVER_LIST[*]}") | awk '{print $4}' | sort | uniq)
    for grid in ${maidenhead_list[@]} ; do
        echo "${grid} $(get_sunrise_sunset ${grid} )" >> ${SUNTIMES_FILE}
    done
    [[ $verbosity -ge 2 ]] && echo "$(date): Got today's sunrise and sunset times"
}

### reads wsprdaemon.conf and if there are sunrise/sunset job times it gets the current sunrise/sunset times
### After calculating HHMM for sunrise and sunset array elements, it creates hhmm.sched with job times in HHMM_SCHED[]
function update_hhmm_sched_file() {
    update_suntimes_file      ### sunrise/sunset times change daily

    ### EXPECTED_JOBS_FILE only should need to be updated if WSPRDAEMON_CONFIG_FILE or SUNTIMES_FILE has changed
    local config_file_time=$($GET_FILE_MOD_TIME_CMD ${WSPRDAEMON_CONFIG_FILE} )
    local suntimes_file_time=$($GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} )
    local hhmm_sched_file_time

    if [[ ! -f ${HHMM_SCHED_FILE} ]]; then
        hhmm_sched_file_time=0
    else
        hhmm_sched_file_time=$($GET_FILE_MOD_TIME_CMD ${HHMM_SCHED_FILE} )
    fi

    if [[ ${hhmm_sched_file_time} -ge ${config_file_time} ]] && [[ ${hhmm_sched_file_time} -ge ${suntimes_file_time} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): update_hhmm_sched_file() found HHMM_SCHED_FILE file newer than config file and suntimes file, so no file update is needed."
        return
    fi

    if [[ ! -f ${HHMM_SCHED_FILE} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): update_hhmm_sched_file() found no HHMM_SCHED_FILE"
    else
        if [[ ${hhmm_sched_file_time} -lt ${suntimes_file_time} ]] ; then
            [[ $verbosity -ge 2 ]] && echo "$(date): update_hhmm_sched_file() found HHMM_SCHED_FILE file is older than SUNTIMES_FILE, so update needed"
        fi
        if [[ ${hhmm_sched_file_time} -lt ${config_file_time}  ]] ; then
            [[ $verbosity -ge 2 ]] && echo "$(date): update_hhmm_sched_file() found HHMM_SCHED_FILE is older than config file, so update needed"
        fi
    fi

    local -a job_array_temp=()
    local -i job_array_temp_index=0
    local -a job_line=()

    source ${WSPRDAEMON_CONFIG_FILE}      ### declares WSPR_SCHEDULE[]
    ### Examine each element of WSPR_SCHEDULE[] and Convert any sunrise or sunset times to HH:MM in job_array_temp[]
    local -i wspr_schedule_index
    for wspr_schedule_index in $(seq 0 $(( ${#WSPR_SCHEDULE[*]} - 1 )) ) ; do
        job_line=( ${WSPR_SCHEDULE[${wspr_schedule_index}]} )
        if [[ ${job_line[0]} =~ sunrise|sunset ]] ; then
            local receiver_name=${job_line[1]%,*}               ### I assume that all of the Reciever in this job are in the same grid as the Reciever in the first job 
            local receiver_grid="$(get_receiver_grid_from_name ${receiver_name})"
            job_line[0]=$(get_index_time ${job_line[0]} ${receiver_grid})
            local job_time=${job_line[0]}
            if [[ ! ${job_line[0]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                ### I don't think that get_index_time() can return a bad time for a sunrise/sunset job, but this is to be sure of that
                echo "$(date): ERROR: in update_hhmm_sched_file(): found and invalid configured sunrise/sunset job time '${job_line[0]}' in wsprdaemon.conf, so skipping this job."
                continue ## to the next index
            fi
        fi
        if [[ ! ${job_line[0]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            ### validate all lines, whether a computed sunrise/sunset or simple HH:MM
            echo "$(date): ERROR: in update_hhmm_sched_file(): invalid job time '${job_line[0]}' in wsprdaemon.conf, expecting HH:MM so skipping this job."
            continue ## to the next index
        fi
        job_array_temp[${job_array_temp_index}]="${job_line[*]}"
        ((job_array_temp_index++))
    done

    ### Sort the now only HH:MM elements of job_array_temp[] by time into jobs_sorted[]
    IFS=$'\n' 
    local jobs_sorted=( $(sort <<< "${job_array_temp[*]}") )
    ### The elements are now sorted by schedule time, but the jobs are stil in the wsprdaemon.conf order
    ### Sort the times for each schedule
    local index_sorted
    for index_sorted in $(seq 0 $(( ${#jobs_sorted[*]} - 1 )) ); do
        job_line=( ${jobs_sorted[${index_sorted}]} )
        local job_time=${job_line[0]}
        job_line[0]=""    ### delete the time 
        job_line=$( $(sort --field-separator=, -k 2,2n <<< "${job_line[*]}") ) ## sort by band
        jobs_sorted[${index_sorted}]="${job_time} ${job_line[*]}"              ## and put the sorted shedule entry back where it came from
    done
    unset IFS

    ### Now that all jobs have numeric HH:MM times and are sorted, ensure that the first job is at 00:00
    unset job_array_temp
    local -a job_array_temp
    job_array_temp_index=0
    job_line=(${jobs_sorted[0]})
    if [[ ${job_line[0]} != "00:00" ]]; then
        ### The config schedule doesn't start at midnight, so use the last config entry as the config for start of the day
        local -i jobs_sorted_index_max=$(( ${#jobs_sorted[*]} - 1 ))
        job_line=(${jobs_sorted[${jobs_sorted_index_max}]})
        job_line[0]="00:00"
        job_array_temp[${job_array_temp_index}]="${job_line[*]}" 
        ((++job_array_temp_index))
    fi
    for index in $(seq 0 $(( ${#jobs_sorted[*]} - 1 )) ) ; do
        job_array_temp[$job_array_temp_index]="${jobs_sorted[$index]}"
        ((++job_array_temp_index))
    done

    ### Save the sorted schedule strting with 00:00 and with only HH:MM jobs to ${HHMM_SCHED_FILE}
    echo "declare HHMM_SCHED=( \\" > ${HHMM_SCHED_FILE}
    for index in $(seq 0 $(( ${#job_array_temp[*]} - 1 )) ) ; do
        echo "\"${job_array_temp[$index]}\" \\" >> ${HHMM_SCHED_FILE}
    done
    echo ") " >> ${HHMM_SCHED_FILE}
    [[ $verbosity -ge 1 ]] && echo "$(date): INFO: update_hhmm_sched_file() updated HHMM_SCHED_FILE"
}

###################
### Setup EXPECTED_JOBS[] in expected.jobs to contain the list of jobs which should be running at this time in EXPECTED_JOBS[]
function setup_expected_jobs_file () {
    update_hhmm_sched_file                     ### updates hhmm_schedule file if needed
    source ${HHMM_SCHED_FILE}

    local    current_time=$(date +%H%M)
    current_time=$((10#${current_time}))   ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
    local -a expected_jobs=()
    local -a hhmm_job
    local    index_max_hhmm_sched=$(( ${#HHMM_SCHED[*]} - 1))
    local    index_time

    ### Find the current schedule
    local index_now=0
    local index_now_time=0
    for index in $(seq 0 ${index_max_hhmm_sched}) ; do
        hhmm_job=( ${HHMM_SCHED[${index}]}  )
        local receiver_name=${hhmm_job[1]%,*}   ### I assume that all of the Recievers in this job are in the same grid as the Kiwi in the first job
        local receiver_grid="$(get_receiver_grid_from_name ${receiver_name})"
        index_time=$(get_index_time ${hhmm_job[0]} ${receiver_grid})  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        if [[ ! ${index_time} =~ ^[0-9]+ ]]; then
            echo "$(date): setup_expected_jobs_file() ERROR: invalid configured job time '${index_time}'"
            continue ## to the next index
        fi
        index_time=$((10#${index_time}))  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        if [[ ${current_time} -ge ${index_time} ]] ; then
            expected_jobs=(${HHMM_SCHED[${index}]})
            expected_jobs=(${expected_jobs[*]:1})          ### Chop off first array element which is the scheudle start time
            index_now=index                                ### Remember the index of the HHMM job which should be active at this time
            index_now_time=$index_time                     ### And the time of that HHMM job
            if [[ $verbosity -ge 3 ]] ; then
                echo "$(date): INFO: setup_expected_jobs_file(): current time '$current_time' is later than HHMM_SCHED[$index] time '${index_time}', so expected_jobs[*] ="
                echo "         '${expected_jobs[*]}'"
            fi
        fi
    done
    if [[ -z "${expected_jobs[*]}" ]]; then
        echo "$(date): setup_expected_jobs_file() ERROR: couldn't find a schedule"
        return 
    fi

    if [[ ! -f ${EXPECTED_JOBS_FILE} ]]; then
        echo "EXPECTED_JOBS=()" > ${EXPECTED_JOBS_FILE}
    fi
    source ${EXPECTED_JOBS_FILE}
    if [[ "${EXPECTED_JOBS[*]-}" == "${expected_jobs[*]}" ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): setup_expected_jobs_file(): at time ${current_time} the entry for time ${index_now_time} in EXPECTED_JOBS[] is present in EXPECTED_JOBS_FILE, so update of that file is not needed"
    else
        [[ $verbosity -ge 2 ]] && echo "$(date): setup_expected_jobs_file(): a new schedule from EXPECTED_JOBS[] for time ${current_time} is needed for current time ${current_time}"

        ### Save the new schedule to be read by the calling function and for use the next time this function is run
        printf "EXPECTED_JOBS=( ${expected_jobs[*]} )\n" > ${EXPECTED_JOBS_FILE}
    fi
}

### Read the expected.jobs and running.jobs files and terminate and/or add jobs so that they match
function update_running_jobs_to_match_expected_jobs() {
    setup_expected_jobs_file
    source ${EXPECTED_JOBS_FILE}

    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "RUNNING_JOBS=()" > ${RUNNING_JOBS_FILE}
    fi
    source ${RUNNING_JOBS_FILE}
    local temp_running_jobs=( ${RUNNING_JOBS[*]-} )

    ### Check that posting jobs which should be running are still running, and terminate any jobs currently running which will no longer be running 
    ### posting_daemon() will ensure that decoding_daemon() and recording_deamon()s are running
    local index_temp_running_jobs
    local schedule_change="no"
    for index_temp_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
        local running_job=${temp_running_jobs[${index_temp_running_jobs}]}
        local running_reciever=${running_job%,*}
        local running_band=${running_job#*,}
        local found_it="no"
        [[ $verbosity -ge 3 ]] && echo "$(date): update_running_jobs_to_match_expected_jobs(): checking posting_daemon() status of job $running_job"
        for index_schedule_jobs in $( seq 0 $(( ${#EXPECTED_JOBS[*]} - 1)) ) ; do
            if [[ ${running_job} == ${EXPECTED_JOBS[$index_schedule_jobs]} ]]; then
                found_it="yes"
                ### Verify that it is still running
                local status
                if status=$(get_posting_status ${running_reciever} ${running_band}) ; then
                    [[ $verbosity -ge 3 ]] && echo "$(date): update_running_jobs_to_match_expected_jobs() found job ${running_reciever} ${running_band} is running"
                else
                    [[ $verbosity -ge 1 ]] && printf "$(date): update_running_jobs_to_match_expected_jobs() found dead recording job '%s,%s'. get_recording_status() returned '%s', so starting job.\n"  \
                        ${running_reciever} ${running_band} "$status"
                    start_stop_job a ${running_reciever} ${running_band}
                fi
                break    ## No need to look further
            fi
        done
        if [[ $found_it == "no" ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): INFO: update_running_jobs_to_match_expected_jobs() found Schedule has changed. Terminating posting job '${running_reciever},${running_band}'"
            ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE} and tell the posting_dameon to stop.  Ot polls every 5 seconds and if there are no more clients will signal the recording deamon to stop
            start_stop_job z ${running_reciever} ${running_band} 
            schedule_change="yes"
        fi
    done

    if [[ ${schedule_change} == "yes" ]]; then
        ### A schedule change deleted a job.  Since it could be either a MERGED or REAL job, we can't be sure if there was a real job terminated.  
        ### So just wait 10 seconds for the 'running.stop' files to appear and then wait for all of them to go away
        sleep ${STOPPING_MIN_WAIT_SECS:-30}            ### Wait a minimum of 30 seconds to be sure the Kiwi to terminates rx sessions 
        wait_for_all_stopping_recording_daemons
    fi

    ### Find any jobs which will be new and start them
    local index_expected_jobs
    for index_expected_jobs in $( seq 0 $(( ${#EXPECTED_JOBS[*]} - 1)) ) ; do
        local expected_job=${EXPECTED_JOBS[${index_expected_jobs}]}
        local found_it="no"
        ### RUNNING_JOBS_FILE may have been changed each time through this loop, so reload it
        unset RUNNING_JOBS
        source ${RUNNING_JOBS_FILE}                           ### RUNNING_JOBS_FILE may have been changed above, so reload it
        temp_running_jobs=( ${RUNNING_JOBS[*]-} ) 
        for index_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
            if [[ ${expected_job} == ${temp_running_jobs[$index_running_jobs]} ]]; then
                found_it="yes"
            fi
        done
        if [[ ${found_it} == "no" ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): update_running_jobs_to_match_expected_jobs() found that the schedule has changed. Starting new job '${expected_job}'"
            local expected_receiver=${expected_job%,*}
            local expected_band=${expected_job#*,}
            start_stop_job a ${expected_receiver} ${expected_band}       ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE}
            schedule_change="yes"
        fi
    done
    
    if [[ $schedule_change == "yes" ]]; then
        [[ $verbosity -ge 1 ]] && printf "$(date): update_running_jobs_to_match_expected_jobs() The schedule has changed so a new schedule has been applied: '${EXPECTED_JOBS[*]}'\n"
    else
        [[ $verbosity -ge 2 ]] && printf "$(date): update_running_jobs_to_match_expected_jobs() Checked the schedule and found that no jobs need to be changed\n"
    fi
}

### Read the running.jobs file and terminate one or all jobs listed there
function stop_running_jobs() {
    local stop_receiver=$1
    local stop_band=${2-}    ## BAND or no arg if $1 == 'all'

    [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs(${stop_receiver},${stop_band}) INFO: begin"
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        [[ $verbosity -ge 1 ]] && echo "INFO: stop_running_jobs() found no RUNNING_JOBS_FILE, so nothing to do"
        return
    fi
    source ${RUNNING_JOBS_FILE}

    ### Since RUNNING_JOBS[] will be shortened by our stopping a job, we need to use a copy of it
    local temp_running_jobs=( ${RUNNING_JOBS[*]-} )

    ### Terminate any jobs currently running which will no longer be running 
    local index_running_jobs
    for index_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
        local running_job=(${temp_running_jobs[${index_running_jobs}]/,/ })
        local running_reciever=${running_job[0]}
        local running_band=${running_job[1]}
        [[ $verbosity -ge 3 ]] && echo "$(date): stop_running_jobs(${stop_receiver},${stop_band}) INFO: compare against running job ${running_job[@]}"
        if [[ ${stop_receiver} == "all" ]] || ( [[ ${stop_receiver} == ${running_reciever} ]] && [[ ${stop_band} == ${running_band} ]]) ; then
            [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO: is terminating running  job '${running_job[@]/ /,}'"
            start_stop_job z ${running_reciever} ${running_band}       ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE}
        else
            [[ $verbosity -ge 3 ]] && echo "$(date): stop_running_jobs() INFO: does not match running  job '${running_job[@]}'"
        fi
    done
    ### Jobs signal they are terminated after the 40 second timeout when the running.stop files created by the above calls are no longer present
    local -i timeout=0
    local -i timeout_limit=$(( ${KIWIRECORDER_KILL_WAIT_SECS} + 20 ))
    [[ $verbosity -ge 0 ]] && echo "Waiting up to $(( ${timeout_limit} + 10 )) seconds for jobs to terminate..."
    sleep 10         ## While we give the dameons a change to create recording.stop files
    local found_running_file="yes"
    while [[ "${found_running_file}" == "yes" ]]; do
        found_running_file="no"
        for index_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
            local running_job=(${temp_running_jobs[${index_running_jobs}]/,/ })
            local running_reciever=${running_job[0]}
            local running_band=${running_job[1]}
            if [[ ${stop_receiver} == "all" ]] || ( [[ ${stop_receiver} == ${running_reciever} ]] && [[ ${stop_band} == ${running_band} ]]) ; then
                [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO: checking to see if job '${running_job[@]/ /,}' is still running"
                local recording_dir=$(get_recording_dir_path ${running_reciever} ${running_band})
                if [[ -f ${recording_dir}/recording.stop ]]; then
                    [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO: found file '${recording_dir}/recording.stop'"
                    found_running_file="yes"
                else
                    [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO:    no file '${recording_dir}/recording.stop'"
                fi
            fi
        done
        if [[ "${found_running_file}" == "yes" ]]; then
            (( ++timeout ))
            if [[ ${timeout} -ge ${timeout_limit} ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date) stop_running_jobs() ERROR: timeout while waiting for all jobs to stop"
                return
            fi
            [[ $verbosity -ge 2 ]] && echo "$(date): kill_recording_daemon() is waiting for recording.stop files to disappear"
            sleep 1
        fi
    done
    [[ $verbosity -ge 1 ]] && echo "All running jobs have been stopped after waiting $(( ${timeout} + 10 )) seconds"
}
 
##############################################################
###  -j a cmd and -j z cmd
function start_or_kill_jobs() {
    local action=$1      ## 'a' === start or 'z' === stop
    local target_arg=${2:-all}            ### I got tired of typing '-j a/z all', so default to 'all'
    local target_info=(${target_arg/,/ })
    local target_receiver=${target_info[0]}
    local target_band=${target_info[1]-}
    if [[ ${target_receiver} != "all" ]] && [[ -z "${target_band}" ]]; then
        echo "ERROR: missing ',BAND'"
        exit 1
    fi

    [[ $verbosity -ge 2 ]] && echo "$(date): start_or_kill_jobs($action,$target_arg)"
    case ${action} in 
        a)
            if [[ ${target_receiver} == "all" ]]; then
                update_running_jobs_to_match_expected_jobs
            else
                start_stop_job ${action} ${target_receiver} ${target_band}
            fi
            ;;
        z)
            stop_running_jobs ${target_receiver} ${target_band} 
            ;;
        *)
            echo "ERROR: invalid action '${action}' specified.  Valid values are 'a' (start) and 'z' (kill/stop).  RECEIVER,BAND defaults to 'all'."
            exit
            ;;
    esac
}

### '-j ...' command
function jobs_cmd() {
    local args_array=(${1/,/ })           ### Splits the first comma-seperated field
    local cmd_val=${args_array[0]:- }     ### which is the command
    local cmd_arg=${args_array[1]:-}      ### For command a and z, we expect RECEIVER,BAND as the second arg, defaults to ' ' so '-j i' doesn't generate unbound variable error

    case ${cmd_val} in
        a|z)
            start_or_kill_jobs ${cmd_val} ${cmd_arg}
            ;;
        s)
            show_running_jobs ${cmd_arg}
            ;;
        l)
            tail_wspr_decode_job_log ${cmd_arg}
            ;;
	o)
	    check_for_zombies no
	    ;;
        *)
            echo "ERROR: '-j ${cmd_val}' is not a valid command"
            exit
    esac
}

