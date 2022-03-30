#!/bin/bash 

##########################################################################################################################################################
########## Section which implements the job control system  ##############################################################################################
##########################################################################################################################################################
function start_stop_job() {
    local action=$1
    local receiver_name=$2
    local receiver_band=$3
    local receiver_modes=$4

    wd_logger 1 "Beginning '${action}' for ${receiver_name} on band ${receiver_band}"
    case ${action} in
        a) 
            spawn_posting_daemon        ${receiver_name} ${receiver_band} ${receiver_modes}
            ;;
        z)
            kill_posting_daemon        ${receiver_name} ${receiver_band}
            ;;
        *)
            wd_logger 1 "Argument action '${action}' is invalid"
            exit 1
            ;;
    esac
    add_remove_jobs_in_running_file ${action} ${receiver_name},${receiver_band},${receiver_modes}
}


##############################################################
###  -Z or -j o cmd, also called at the end of -z, also called by the watchdog daemon every two minutes
declare ZOMBIE_CHECKING_ENABLED=${ZOMBIE_CHECKING_ENABLED:=yes}

function check_for_zombie_daemon(){
    local pid_file_path=$1

    if [[ -f ${pid_file_path} ]]; then
        local daemon_pid=$(cat ${pid_file_path})
        if ps ${daemon_pid} > /dev/null ; then
            wd_logger 1 "Daemon pid ${daemon_pid} from '${pid_file_path} is active" 1>&2
            echo ${daemon_pid}
        else
            wd_logger 1 "Daemon pid ${daemon_pid} from '${pid_file_path} is dead" 1>&2
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
    local expected_and_running_pids=()

    wd_logger 2 "Starting"
    if [[ ${ZOMBIE_CHECKING_ENABLED} != "yes" ]]; then
        wd_logger 1 "Checking has been disabled"
        return 0
    fi
    ### First check if the watchdog and the upload daemons are running
    local expected_pid_file_list=$( find ${WSPRDAEMON_TMP_DIR} ${WSPRDAEMON_ROOT_DIR} -name '*.pid' )
    for pid_file_path in ${pid_file_list[@]}; do
        local daemon_pid=$(check_for_zombie_daemon ${pid_file_path} )
        if [[ -n "${daemon_pid}" ]]; then
            expected_and_running_pids+=( ${daemon_pid} )
            wd_logger 1 "Adding pid ${daemon_pid} of daemon '${pid_file_path}' to the expected pid list"
        else
            wd_logger 2 "Found no pid for daemon '${pid_file_path}'"
        fi
    done

    ### Next check that all of the pids associated with RUNNING_JOBS are active
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        wd_logger 1 "${RUNNING_JOBS_FILE} doesn't exist so skip checking for jobs"
    elif !  source ${RUNNING_JOBS_FILE} ; then
        local ret_code=$?
        wd_logger 1 "'ERROR: source ${RUNNING_JOBS_FILE}' => ${ret_code}, so skip checking for jobs"
    elif [[ ${#RUNNING_JOBS[@]} -eq 0 ]] ; then
        wd_logger 1 "No entries in RUNNING_JOBS[@], so skip checking for jobs"
    else
        ### There are jobs in ${#RUNNING_JOBS[@]} to be checked

        ### Verify there is a posting job for each logical receiver
        local running_job
        for running_job in ${RUNNING_JOBS[@]} ; do
            wd_logger 1 "Check that there is a posting job for ${running_job}"
            local running_job_fields=( ${running_job//,/ } )
            local receiver_name=${running_job_fields[0]}
            local receiver_band=${running_job_fields[1]}
            local receiver_modes=${running_job_fields[2]-ALL}
            
            local posting_daemon_pid_file
            if ! get_posting_pid_file_path posting_daemon_pid_file ${receiver_name} ${receiver_band} ; then
                wd_logger 1 "Found no posting_daemon pid file ${posting_daemon_pid_file} for running_job=${running_job}"
                add_remove_jobs_in_running_file z "${running_job}"
            else
                local posting_daemon_pid=$(< ${posting_daemon_pid_file})
                
                if ! [[ "${posting_daemon_pid}" =~ ^[0-9]+$ ]]; then
                    wd_logger 1 "ERROR: pid file ${posting_daemon_pid_file} exists but its contents '${posting_daemon_pid}' is not an integer number, so delete that pid file"
                    rm ${posting_daemon_pid_file}
                else
                    ps ${posting_daemon_pid} > /dev/null
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR: pid file ${posting_daemon_pid_file} exists and contains pid '${posting_daemon_pid}', but that pid is not running, so delete that pid file"
                        rm ${posting_daemon_pid_file}
                    else
                        wd_logger 1 "pid file ${posting_daemon_pid_file} exists and contains expected and running pid '${posting_daemon_pid}'"
                        expected_and_running_pids+=( ${posting_daemon_pid} )
                    fi
                fi
            fi
        done

        ### Create ${running_rx_list[]} with all the expected real rx devices. If there are MERGed jobs, then ensure that the real rx they depend upon is in ${running_rx_list}
        local real_rx_list=()
        for running_job in ${RUNNING_JOBS[@]} ; do
            if [[ ! "${running_job}" =~ ^MERG ]]; then
                if [[ " ${real_rx_list[*]} " =~ " ${running_job} " ]]; then
                    wd_logger 1 "Real rx job ${running_job} has already been added to real_rx_list[]='${real_rx_list[*]}'"
                else
                    real_rx_list+=( ${running_job} )
                    wd_logger 1 "Real rx job ${running_job} has been added to real_rx_list[]='${real_rx_list[*]}'"
                fi
            else
                ### This is a MERGed job
                local running_job_fields=( ${running_job//,/ } )
                local receiver_name=${running_job_fields[0]}
                local receiver_band=${running_job_fields[1]}
                local receiver_modes=${running_job_fields[2]-ALL}

                wd_logger 1 "Checking MERGed receiver ${running_job} and adding its real receivers to real_rx_list[]='${real_rx_list[*]}'"
                ### Check the MERGED device's real rx devices are in the list
                local merged_receiver_address=$(get_receiver_ip_from_name ${receiver_name})   ### In a MERGed rx, the real rxs feeding it are in a comma-separated list in the IP column
                local merged_receiver_name_list=( ${merged_receiver_address//,/ } )
                local rx_device
                for rx_device in ${merged_receiver_name_list[@]}; do
                    ### Check each real rx
                    local merged_rx_job=${rx_device},${receiver_band},${receiver_modes}
                    
                    if [[ " ${real_rx_list[*]} " =~ " ${merged_rx_job} " ]]; then
                        wd_logger 1 "For MERGed job ${running_job} it's merged_rx_job=${merged_rx_job} has already been added to real_rx_list[]='${real_rx_list[*]}'"
                    else
                        real_rx_list+=( ${merged_rx_job} )
                        wd_logger 1 "For MERGed job ${running_job} added its merged_rx_job=${merged_rx_job} to real_rx_list[]='${real_rx_list[*]}'"
                    fi
                done
            fi
        done

        ### Check for all the pids expected of real jobs
        for running_job in ${real_rx_list[@]}; do
            wd_logger 1 "Checking for real_rx pids for job ${running_job}"
            local running_job_fields=( ${running_job//,/ } )
            local receiver_name=${running_job_fields[0]}
            local receiver_band=${running_job_fields[1]}
            local receiver_modes=${running_job_fields[2]-ALL}

            local rx_dir_path=$(get_recording_dir_path ${receiver_name} ${receiver_band})
            shopt -s nullglob
            local rx_pid_file_list=( ${rx_dir_path}/*pid )
            shopt -u nullglob

            local expected_pid_files=3
            if [[ ${receiver_name} =~ ^AUDIO ]]; then
                expected_pid_files=2
            elif [[ ${receiver_name} =~ ^SDR ]]; then
                expected_pid_files=2
            fi
            if [[ ${#rx_pid_file_list[@]} -ne ${expected_pid_files}  ]]; then
                wd_logger 1 "WARNING: real rx_job='${running_job}' recording dir is missing some or all of the expected ${expected_pid_files} pid files. Found only: '${#rx_pid_file_list[@]}' pid files"
            fi

            for pid_file in ${rx_pid_file_list[@]} ; do
                local pid_val=$(< ${pid_file})
                
                if ! [[ "${pid_val}" =~ ^[0-9]+$ ]]; then
                    wd_logger 1 "ERROR: real_rx pid file ${id_val_file} exists but its contents '${pid_val}' is not an integer number, so delete that pid file"
                    rm ${pid_file}
                else
                    ps ${pid_val} > /dev/null
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR: real_rx pid file ${pid_file} exists and contains pid '${pid_val}', but that pid is not running, so delete that pid file"
                        rm ${pid_file}
                    else
                        wd_logger 1 "real_rx pid file ${pid_file} exists and contains expected and running pid '${pid_val}'"
                        expected_and_running_pids+=( ${pid_val} )
                    fi
                fi
            done
        done
    fi    

    wd_logger 1 "Checking all pids for 'wsprdaemon.sh -a' programs"
    local kill_pid_list=()
    local running_wsprdaemon_a_pid_list=( $(ps aux | awk '/wsprdaemon\/wsprdaemon.sh -a/{print $2}' ) )
    if [[ ${#running_wsprdaemon_a_pid_list[@]} -ne 0 ]]; then
        wd_logger 1 "Found ${#running_wsprdaemon_a_pid_list[*]} 'wsprdaemon/wsprdaemon.sh -a'. Kill them"
        kill ${running_wsprdaemon_a_pid_list[@]}
    fi

    ### We have checked all the pid files, now look at all running kiwirecorder programs reported by 'ps'
    wd_logger 1 "Checking all pids for kiwirecorder.py programs"
    local running_kiwirecorder_pid_list=( $(ps aux | awk '/kiwiclient\/kiwirecorder.py/{print $2}' ) )
    
    for running_pid in ${running_kiwirecorder_pid_list[@]} ; do
       if [[ " ${expected_and_running_pids[*]} " =~  " ${running_pid} " ]]; then
           wd_logger 1 "Found running_pid '${running_pid}' in expected_pids '${expected_and_running_pids[*]}'"
       else
           local ps_output=$(ps ${running_pid} )
           local ret_code=$?
           if [[ ${ret_code} -ne 0 ]]; then
               wd_logger 1 "Found zombie ${running_pid} which is no longer running"
           else
               sleep 1
               ps_output=$(ps ${running_pid} )
               ret_code=$?
               if [[ ${ret_code} -ne 0 ]]; then
                   wd_logger 1 "Found zombie ${running_pid} stopped running after running an extra 'sleep 1'"
               else
                   local ps_cmd_info=$( tail -n 1 <<< "${ps_output}" )
                   wd_logger 1 "Adding running zombie '${ps_cmd_info}' to kill list"
                   kill_pid_list+=(${running_pid})
               fi
           fi
       fi
    done
    wd_logger 1 "Found ${#expected_and_running_pids[*]} expected_and_running_pids[] and ${#kill_pid_list[@]} kill_pid_list[] pids = '${kill_pid_list[*]}'" 
    if [[ ${#kill_pid_list[@]} -gt 0 ]]; then
        kill ${kill_pid_list[@]}
        wd_logger 1 "Killed zombie pids:  '${kill_pid_list[*]}'"
    fi
}

##############################################################
###  -j s cmd   Argument is 'all' OR 'RECEIVER,BAND'
function show_running_jobs() {
    wd_logger 2 "Starting"
    local args_val=${1:-all}      ## -j s  defaults to 'all'
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    local show_band=${args_array[1]:-}
    if [[ "${show_target}" != "all" ]] && [[ -z "${show_band}" ]]; then
        wd_logger 1 "ERROR: missing RECEIVER,BAND argument"
        exit 1
    fi
    local receiver_name_list=()
    local receiver_name
    local receiver_band
    local found_job="no"

    if [[ ! -f ${RUNNING_JOBS_FILE} ]] ; then
        wd_logger 1 "ERROR: There is no RUNNING_JOBS_FILE '${RUNNING_JOBS_FILE}'"
        return 1
    elif ! source ${RUNNING_JOBS_FILE}; then
        wd_logger 1 "ERROR: 'source ${RUNNING_JOBS_FILE}' => $?"
        return 2
    elif [[ ${#RUNNING_JOBS[@]} -eq 0 ]] ; then
        wd_logger 1 "There are no running jobs"
        return 3
    fi

    local job_info
    local running_jobs_count=0
    for job_info in ${RUNNING_JOBS[*]} ; do
        local job_info_fields=( ${job_info//,/ } )
        local receiver_name=${job_info_fields[0]}
        local receiver_band=${job_info_fields[1]}
        local receiver_modes=${job_info_fields[2]}
        if [[ ${receiver_name} =~ ^MERG ]]; then
            ### For merged rx devices, there is only one posting pid, but one or more recording and decoding pids
            local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
            receiver_name_list=(${receiver_address//,/ })
            printf "%2s: %12s,%-4s merged posting    %s (%s)\n" ${job_info} ${receiver_name} ${receiver_band} "$(get_posting_status ${receiver_name} ${receiver_band})" "${receiver_address}"
        else
            ### For a simple rx device, the recording, decoding and posting pids are all in the same directory
            receiver_name_list=(${receiver_name})
            local print_string=$(printf "%25s: %12s,%-4s posting     %s\n" ${job_info} ${receiver_name} ${receiver_band}  "$(get_posting_status   ${receiver_name} ${receiver_band})")
            wd_logger -1 "${print_string}"
        fi
        for receiver_name in ${receiver_name_list[@]}; do
            if [[ ${show_target} == "all" ]] || ( [[ ${receiver_name} == ${show_target} ]] && [[ ${receiver_band} == ${show_band} ]] ) ; then
                local wd_log_string=$(printf "%25s: %12s,%-4s decoding    %s\n" ${job_info} ${receiver_name} ${receiver_band}  "$(get_decoding_status  ${receiver_name} ${receiver_band})")
                wd_logger -1 "${wd_log_string}"
                wd_log_string=$(printf "%25s: %12s,%-4s recording   %s\n" ${job_info} ${receiver_name} ${receiver_band}  "$(get_recording_status ${receiver_name} ${receiver_band})")
                wd_logger -1 "${wd_log_string}"
                found_job="yes"
            fi
        done
        if [[ ${found_job} == "yes" ]]; then
            (( ++running_jobs_count ))
            if [[ "${show_target}" == "all" ]]; then
                wd_logger 2 "job #${running_jobs_count} is running"
            else
                wd_logger 1 "No job found for RECEIVER '${show_target}' BAND '${show_band}'"
            fi
        fi
    done
    wd_logger -1 "Found ${running_jobs_count} running jobs"
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
    local job=$2       ## in form RECEIVER,BAND[,MODES]

    wd_logger 1 "Start with ${action}, ${job}"
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "RUNNING_JOBS=( )" > ${RUNNING_JOBS_FILE}
        wd_logger 1 "Creating new ${RUNNING_JOBS_FILE}"
    fi
    source ${RUNNING_JOBS_FILE}
    wd_logger 1 "RUNNING_JOBS='${RUNNING_JOBS[*]}'"
    case $action in
        a)
            if [[ " ${RUNNING_JOBS[@]} " =~ " ${job} " ]]; then
                ### We come here when restarting a dead capture job, so this condition is already printed out
                wd_logger 1 "Starting job '${job}' but found it is already in ${RUNNING_JOBS_FILE}='${RUNNING_JOBS[*]}'"
                return 1
            fi
            wd_logger 1 "Adding '${job}' to ${RUNNING_JOBS_FILE}"
            RUNNING_JOBS+=( ${job} )
            ;;
        z)
            if ! [[ " ${RUNNING_JOBS[@]} " =~ " ${job} " ]]; then
                wd_logger 1 "Stoppng job '${job}', but is not in ${RUNNING_JOBS_FILE}"
                return 1
            fi
            ### The following line is a little obscure, so here is an explanation
            ###  We are deleting the version of RUNNING_JOBS[] to delete one job.  Rather than loop through the array I just use sed to delete it from
            ###  the array declaration statement in the ${RUNNING_JOBS_FILE}.  So this statement redeclares RUNNING_JOBS[] with the deleted job element removed 
            #eval $( sed "s/${job}//" ${RUNNING_JOBS_FILE})
            wd_logger 1 "Deleting  job '${job}' from  '${RUNNING_JOBS[*]}'"
            RUNNING_JOBS=( "${RUNNING_JOBS[@]/${job}}" )     ### Deletes the job from the array
            wd_logger 1 "Job '${job}' should no longer be in '${RUNNING_JOBS[*]}'"
            ;;
        *)
            wd_logger 1 "ERROR: action ${action} invalid"
            return 2
    esac
    if [[ ${#RUNNING_JOBS[@]} -gt 0 ]]; then
        ### Sort RUNNING_JOBS by ascending band frequency
        ## IFS=$'\n'
        ### RUNNING_JOBS=( $(sort --field-separator=, -k 2,2n <<< "${RUNNING_JOBS[@]-}") )       ### I tried everyting I know to get this to work
        ## unset IFS
        RUNNING_JOBS=( $( local element; for element in ${RUNNING_JOBS[@]}; do echo ${element}; done | sort -t , -k 2,2nr ) )
    fi
    echo "declare RUNNING_JOBS=( ${RUNNING_JOBS[*]-} )" > ${RUNNING_JOBS_FILE}
    wd_logger 1 "Wrote new ${RUNNING_JOBS_FILE}: '${RUNNING_JOBS[*]-}'"
}

###

#############
###################
declare -r HHMM_SCHED_FILE=${WSPRDAEMON_ROOT_DIR}/hhmm.sched       ### Contains the schedule from wsprdaemon.conf with sunrise/sunset entries fixed in HHMM_SCHED[]
declare -r EXPECTED_JOBS_FILE=${WSPRDAEMON_ROOT_DIR}/expected.jobs ### Based upon current HHMM, this is the job list from EXPECTED_JOBS_FILE[] which should be running in EXPECTED_LIST[]
declare -r RUNNING_JOBS_FILE=${WSPRDAEMON_ROOT_DIR}/running.jobs   ### This is the list of jobs we programmed to be running in RUNNING_LIST[]

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

### Reads wsprdaemon.conf and if there are sunrise/sunset job times it gets the current sunrise/sunset times
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
        wd_logger 1 "found HHMM_SCHED_FILE file newer than config file and suntimes file, so no file update is needed."
        return
    fi

    if [[ ! -f ${HHMM_SCHED_FILE} ]]; then
        wd_logger 1 "found no HHMM_SCHED_FILE"
    else
        if [[ ${hhmm_sched_file_time} -lt ${suntimes_file_time} ]] ; then
            wd_logger 1 "found HHMM_SCHED_FILE file is older than SUNTIMES_FILE, so update needed"
        fi
        if [[ ${hhmm_sched_file_time} -lt ${config_file_time}  ]] ; then
            wd_logger 1 "found HHMM_SCHED_FILE is older than config file, so update needed"
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
            local receiver_name=${job_line[1]%,*}               ### I assume that all of the Receivers in this job are in the same grid as the Receiver in the first job 
            local receiver_grid="$(get_receiver_grid_from_name ${receiver_name})"
            job_line[0]=$(get_index_time ${job_line[0]} ${receiver_grid})
            local job_time=${job_line[0]}
            if [[ ! ${job_line[0]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                ### I don't think that get_index_time() can return a bad time for a sunrise/sunset job, but this is to be sure of that
                wd_logger 1 "ERROR: Found and invalid configured sunrise/sunset job time '${job_line[0]}' in wsprdaemon.conf, so skipping this job."
                continue ## to the next index
            fi
        fi
        if [[ ! ${job_line[0]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            ### validate all lines, whether a computed sunrise/sunset or simple HH:MM
            wd_logger 1 "ERROR: invalid job time '${job_line[0]}' in wsprdaemon.conf, expecting HH:MM so skipping this job."
            continue ### to the next index
        fi
        job_array_temp[${job_array_temp_index}]="${job_line[*]}"
        ((job_array_temp_index++))
    done
    wd_logger 2 "Created job_array_temp[${#job_array_temp[@]}]"

    ### Sort the now only HH:MM elements of job_array_temp[] by time into jobs_sorted[]
    IFS=$'\n' 
    local jobs_sorted=( $(sort <<< "${job_array_temp[*]}") )
    ### The elements are now sorted by schedule time, but the jobs are still in the wsprdaemon.conf order
    ### Sort the times for each schedule
    local index_sorted
    for index_sorted in $(seq 0 $(( ${#jobs_sorted[*]} - 1 )) ); do
        job_line=( ${jobs_sorted[${index_sorted}]} )
        local job_time=${job_line[0]}
        job_line[0]=""    ### delete the time 
        job_line=$( $(sort --field-separator=, -k 2,2n <<< "${job_line[*]}") ) ### sort by band
        jobs_sorted[${index_sorted}]="${job_time} ${job_line[*]}"              ### and put the sorted schedule entry back where it came from
    done
    unset IFS
    wd_logger 2 "Created jobs_sorted[${#jobs_sorted[@]}]"

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
    wd_logger 2 "Created job_array_temp[${#job_array_temp[*]}]='${job_array_temp[*]}'"

    ### Save the sorted schedule starting with 00:00 and with only HH:MM jobs to ${HHMM_SCHED_FILE}
    printf "declare HHMM_SCHED=(\n" > ${HHMM_SCHED_FILE}
    local sched_line
    for sched_line in "${job_array_temp[@]}"  ; do
        local job_line_list=(${sched_line})
        local job_time=${job_line_list[0]}

        wd_logger 1 "Processing sched line '${sched_line}', job_time=${job_time}"

        ### If needed, ddd the ',MODE' to the jobs defined for this time
        local output_jobs_list=(${job_time})   ### First element is the time

        ### Look at each job defined for this time
        local schedule_job
        for schedule_job in "${job_line_list[@]:1}"; do
            ### Look at one job
            wd_logger 2 "Processing schedule_job ${schedule_job}"
            local job_list=(${schedule_job//,/ })
            if [[ ${#job_list[@]} -lt 3 ]]; then
                ### conf file job doesn't have a ',MODE' field
                job_list[2]="DEFAULT"
            fi
            local output_schedule_job="${job_list[*]}"
                  output_schedule_job="${output_schedule_job// /,}"
            output_jobs_list+=( ${output_schedule_job} )
            wd_logger 2 "Added processed job ${output_schedule_job} to schedule for time ${output_jobs_list[0]}"
        done
        wd_logger 2 "Processed sched line into '${output_jobs_list[*]}'"

        ### Done processing one schedule time line
        wd_logger 1 "Appending '${output_jobs_list[*]}' to ${HHMM_SCHED_FILE}"
        printf "  \"${output_jobs_list[*]}\" \n" >> ${HHMM_SCHED_FILE}
    done
    printf ")\n" >> ${HHMM_SCHED_FILE}
    wd_logger 1 "Finished updating HHMM_SCHED_FILE"
}

###################
### Setup EXPECTED_JOBS[] in expected.jobs to contain the list of jobs which should be running at this time in EXPECTED_JOBS[]
function setup_expected_jobs_file () {
    update_hhmm_sched_file                 ### updates hhmm_schedule file if needed
    source ${HHMM_SCHED_FILE}

    local    current_time=$(date +%H%M)
    current_time=$((10#${current_time}))   ### remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
    local -a expected_jobs=()
    local -a hhmm_job
    local    index_max_hhmm_sched=$(( ${#HHMM_SCHED[*]} - 1))
    local    index_time

    ### Find the current schedule
    local index_now=0
    local index_now_time=0
    for index in $(seq 0 ${index_max_hhmm_sched}) ; do
        hhmm_job=( ${HHMM_SCHED[${index}]}  )
        local receiver_name=${hhmm_job[1]%,*}   ### I assume that all of the Receivers in this job are in the same grid as the Kiwi in the first job
        local receiver_grid="$(get_receiver_grid_from_name ${receiver_name})"
        index_time=$(get_index_time ${hhmm_job[0]} ${receiver_grid})  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        if [[ ! ${index_time} =~ ^[0-9]+ ]]; then
            wd_logger 1 "ERROR: invalid configured job time '${index_time}'"
            continue ### to the next index
        fi
        index_time=$((10#${index_time}))  ### remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        if [[ ${current_time} -ge ${index_time} ]] ; then
            expected_jobs=(${HHMM_SCHED[${index}]})
            expected_jobs=(${expected_jobs[*]:1})          ### Chop off first array element which is the schedule start time
            index_now=index                                ### Remember the index of the HHMM job which should be active at this time
            index_now_time=$index_time                     ### And the time of that HHMM job
            wd_logger 1 "current time '$current_time' is later than HHMM_SCHED[$index] time '${index_time}', so expected_jobs[*] =${expected_jobs[*]}'"
        fi
    done
    if [[ -z "${expected_jobs[*]}" ]]; then
        wd_logger 1 "ERROR: couldn't find a schedule"
        return 
    fi

    if [[ ! -f ${EXPECTED_JOBS_FILE} ]]; then
        echo "EXPECTED_JOBS=()" > ${EXPECTED_JOBS_FILE}
        wd_logger 1 "Creating new ${EXPECTED_JOBS_FILE}"
    fi
    source ${EXPECTED_JOBS_FILE}
    if [[ "${EXPECTED_JOBS[*]-}" == "${expected_jobs[*]}" ]]; then
        wd_logger 1 "At time ${current_time} the entry for time ${index_now_time} in EXPECTED_JOBS[] is present in EXPECTED_JOBS_FILE, so update of that file is not needed"
    else
        wd_logger 1 "A new schedule from EXPECTED_JOBS[] for time ${current_time} is needed for current time ${current_time}"

        ### Save the new schedule to be read by the calling function and for use the next time this function is run
        printf "EXPECTED_JOBS=( ${expected_jobs[*]} )\n" > ${EXPECTED_JOBS_FILE}
    fi
}

### Read the expected.jobs and running.jobs files and terminate and/or add jobs so that they match
function update_running_jobs_to_match_expected_jobs() {

    setup_expected_jobs_file
    source ${EXPECTED_JOBS_FILE}
    wd_logger 1 "EXPECTED_JOBS='${EXPECTED_JOBS[*]}'"

    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "RUNNING_JOBS=()" > ${RUNNING_JOBS_FILE}
    fi
    source ${RUNNING_JOBS_FILE}
    local temp_running_jobs=( ${RUNNING_JOBS[*]-} )
    wd_logger 1 "RUNNING_JOBS=${RUNNING_JOBS[*]-}"

    ### Check that posting jobs which should be running are still running, and terminate any jobs currently running which will no longer be running 
    ### posting_daemon() will ensure that decoding_daemon() and recording_daemon()s are running
    local running_job
    local schedule_change="no"
    for running_job in ${temp_running_jobs[*]}; do
        local running_job_fields=( ${running_job//,/ } )
        if [[ ${#running_job_fields[@]} -lt 2 ]]; then
            wd_logger 1 "Error in running job '${running_job}'. It has less than the minimun 2 fields of RX,BAND[,MODES,...]"
            continue
        else
           wd_logger 2 "Found job '${running_job}' has MODE field"
        fi
        local running_receiver=${running_job_fields[0]}
        local running_band=${running_job_fields[1]}
        local running_modes=${running_job_fields[2]-DEFAULT}
        local found_it="no"
        wd_logger 2 "Checking status of job ${running_job}"
        for index_schedule_jobs in $( seq 0 $(( ${#EXPECTED_JOBS[*]} - 1)) ) ; do
            if [[ ${running_job} == ${EXPECTED_JOBS[$index_schedule_jobs]} ]]; then
                found_it="yes"
                ### Verify that it is still running
                local status
                if status=$(get_posting_status ${running_receiver} ${running_band}) ; then
                    wd_logger 2 "Found posting_daemon() job ${running_receiver} ${running_band} is running"
                else
                    wd_logger 1 "Found dead posting_daemon() job '${running_receiver},${running_band}'. get_recording_status() returned '$status', so starting job"
                    start_stop_job a ${running_receiver} ${running_band} ${running_modes}
                fi
                break    ## No need to look further
            fi
        done
        if [[ $found_it == "no" ]]; then
            wd_logger 1 "Found Schedule has changed. Terminating posting job '${running_receiver},${running_band}'"
            ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE} and tell the posting_daemon to stop. It polls every 5 seconds and if there are no more clients will signal the recording deamon to stop
            start_stop_job z ${running_receiver} ${running_band} ${running_modes}
            schedule_change="yes"
        fi
    done

    if [[ ${schedule_change} == "yes" ]]; then
        ### A schedule change deleted a job. Since it could be either a MERGed or REAL job, we can't be sure if there was a real job terminated.  
        ### So just wait 10 seconds for the 'running.stop' files to appear and then wait for all of them to go away
        sleep ${STOPPING_MIN_WAIT_SECS:-10}            ### Wait a minimum of 30 seconds to be sure the Kiwi terminates rx sessions 
        wd_logger 1 "Schedule has changed"
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
            wd_logger 1 "Found that the schedule has changed. Starting new job '${expected_job}'"
            local expected_job_fields=( ${expected_job//,/ } )
            local expected_receiver=${expected_job_fields[0]}
            local expected_band=${expected_job_fields[1]}
            local expected_modes=${expected_job_fields[2]-DEFAULT}
            start_stop_job a ${expected_receiver} ${expected_band} ${expected_modes}       ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE}
            schedule_change="yes"
        fi
    done
    
    if [[ $schedule_change == "yes" ]]; then
        wd_logger 1 "The schedule has changed so a new schedule has been applied: '${EXPECTED_JOBS[*]}'"
    else
        wd_logger 1 "Checked the schedule and found that no jobs need to be changed"
    fi
}

### Read the running.jobs file and terminate one or all jobs listed there
function stop_running_jobs() {
    local stop_receiver=$1
    local stop_band=${2-all}    ### BAND or no arg if $1 == 'all'
    local stop_modes=${3-DEFAULT}

    wd_logger 2 "Start with args: $1,${2-} => ${stop_receiver},${stop_band}"
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        wd_logger 1 "Found no RUNNING_JOBS_FILE, so nothing to do"
        return 0
    fi
    source ${RUNNING_JOBS_FILE}
    if [[ ${#RUNNING_JOBS[@]} -eq 0 ]]; then
       wd_logger 1 "No jobs in RUNNING_JOBS[]"
       return 0
    fi

    ### Since RUNNING_JOBS[] will be shortened by our stopping a job, we need to use a copy of it
    local temp_running_jobs=( ${RUNNING_JOBS[*]} )

    ### Terminate any jobs currently running which will no longer be running 
    local running_job
    for running_job in ${temp_running_jobs[@]} ; do
        local running_job_fields=(${running_job//,/ } )
        local running_receiver=${running_job_fields[0]}
        local running_band=${running_job_fields[1]}
        local running_modes=${running_job_fields[2]}       ### The mode field is optional and will not be present in legacy config files
        wd_logger 1 "Compare the running job '${running_job_fields[*]}' with stop target ${running_receiver},${running_band}[,${running_modes}]"
        if [[ ${stop_receiver} == "all" || ( ${stop_receiver} == ${running_receiver} && ${stop_band} == ${running_band} && ${stop_modes} == ${running_modes} ) ]]  ; then
            wd_logger 1 "Terminating running  job ${running_receiver},${running_band},${running_modes}"
            start_stop_job z ${running_receiver} ${running_band} ${running_modes}      ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE}
        else
            wd_logger 1 "does not match running job '${running_job}'"
        fi
    done
    return

    ### Jobs signal they are terminated after the 40 second timeout when the running.stop files created by the above calls are no longer present
    local -i timeout=0
    local -i timeout_limit=$(( ${KIWIRECORDER_KILL_WAIT_SECS} + 20 ))
    [[ $verbosity -ge 0 ]] && echo "Waiting up to $(( ${timeout_limit} + 10 )) seconds for jobs to terminate..."
    sleep 10         ## While we give the daemons a change to create recording.stop files
    local found_running_file="yes"
    while [[ "${found_running_file}" == "yes" ]]; do
        found_running_file="no"
        for running_job in ${temp_running_jobs[@]} ; do
            local running_job_fields=(${running_job//,/ } )
            local running_receiver=${running_job_fields[0]}
            local running_band=${running_job_fields[1]}
            local running_modes=${running_job_fields[2]-ALL}       ### The mode field is optional and will not be present in legacy config files
            if [[ ${stop_receiver} == "all" ]] || ( [[ ${stop_receiver} == ${running_receiver} ]] && [[ ${stop_band} == ${running_band} ]]) ; then
                wd_logger 1 "Checking to see if job ${running_receiver},${running_band} is still running"
                local recording_dir=$(get_recording_dir_path ${running_receiver} ${running_band})
                if [[ -f ${recording_dir}/recording.stop ]]; then
                    wd_logger 1 "INFO: found file '${recording_dir}/recording.stop'"
                    found_running_file="yes"
                else
                    wd_logger 1 "no file '${recording_dir}/recording.stop'"
                fi
            fi
        done
        if [[ "${found_running_file}" == "yes" ]]; then
            (( ++timeout ))
            if [[ ${timeout} -ge ${timeout_limit} ]]; then
                wd_logger 1 "timeout while waiting for all jobs to stop"
                return
            fi
            wd_logger 1 "is waiting for recording.stop files to disappear"
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
        wd_logger 1 "ERROR in conf file job is missing ',BAND', so 'exit 1"
        exit 1
    fi

    wd_logger 2 "Starting with args $action,'$target_arg'"
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
            echo "ERROR: invalid action '${action}' specified. Valid values are 'a' (start) and 'z' (kill/stop).  RECEIVER,BAND defaults to 'all'."
            exit
            ;;
    esac
    wd_logger 2 "Finished"
}

### '-j ...' command
function jobs_cmd() {
    local ret_code=0
    local args_array=(${1/,/ })           ### Splits the first comma-separated field
    local cmd_val=${args_array[0]:- }     ### Which is the command
    local cmd_arg=${args_array[1]:-}      ### For command a and z, we expect RECEIVER,BAND as the second arg, defaults to ' ' so '-j i' doesn't generate unbound variable error

    wd_logger 2 "Starting to execute cmd '${cmd_val} ${cmd_arg}'"
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
            wd_logger 0  "ERROR: '-j ${cmd_val}' is not a valid command"
            ret_code=1
    esac
    wd_logger 2 "Finished"
    return ${ret_code}
}
