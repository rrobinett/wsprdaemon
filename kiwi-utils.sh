#!/bin/bash

##############################################################
function list_kiwis() 
{
     local i
     for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        if echo "${receiver_ip_address}" | ${GREP_CMD} -q '^[1-9]' ; then
            echo "${receiver_name}"
        fi
    done
}

function get_kiwi_ip_port()
{
    local __return_kiwi_ip_port=$1
    local target_kiwi_name=$2

     local i
     for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}

        if [[ ${receiver_name} == ${target_kiwi_name} ]]; then
          
            local receiver_ip_address=${receiver_info[1]}
            wd_logger 1 "Found ${target_kiwi_name} in RECEIVER_LIST[], its IP = ${receiver_ip_address}"
            eval ${__return_kiwi_ip_port}=\${receiver_ip_address}
            return 0
        fi
    done
    wd_logger 1 "ERROR: couldn't find  ${target_kiwi_name} in RECEIVER_LIST[]"
    return 1
}


###################################################
function check_kiwi_wspr_channels() {
    local kiwi_name=$1
    local kiwi_ip=$(get_receiver_ip_from_name ${kiwi_name})

    local users_max=$(curl -s --connect-timeout 5 ${kiwi_ip}/status | awk -F = '/users_max/{print $2}')
    if [[ -z "${users_max}" ]]; then
        wd_logger 2 "Kiwi '${kiwi_name}' not present or its SW doesn't report 'users_max', so nothing to do"
        return
    fi
    if [[ ${users_max} -lt 8 ]]; then
        wd_logger 3 " Kiwi '${kiwi_name}' is configured for ${users_max} users, not in 8 channel mode. So nothing to do"
        return
    fi

    local active_receivers_list=$( curl -s --connect-timeout 5 ${kiwi_ip}/users | sed -n '/"i":\([0-9]\),"n"/s//\n\1/gp' | ${GREP_CMD} "^[0-9]" )
    if [[ -z "${active_receivers_list}" ]];  then
        wd_logger 2 " Kiwi '${kiwi_name}' not reporting users status or there are no active rx channels on it. So nothing to do"
        return
    fi
    local wd_arg=$(echo "Kiwi ${kiwi_name} has active listeners:\n${active_receivers_list}")
    wd_logger 4 "${wd_arg}"

    if ! ${GREP_CMD} -q "wsprdaemon" <<< "${active_receivers_list}" ; then
        wd_logger 2 "Kiwi ${kiwi_name} has no active WD listeners"
       return
    fi
    local wd_listeners_count=$( ${GREP_CMD} wsprdaemon <<< "${active_receivers_list}" | wc -l) 
    local wd_ch_01_listeners_count=$( ${GREP_CMD} "^[01]:.wsprdaemon" <<< "${active_receivers_list}" | wc -l) 
    wd_logger 3 "Kiwi '${kiwi_name}' has ${wd_listeners_count} WD listeners of which ${wd_ch_01_listeners_count} listeners are on ch 0 or ch 1"
    if [[ ${wd_listeners_count} -le 6 && ${wd_ch_01_listeners_count} -gt 0 ]]; then
        wd_logger 1 "WARNING, Kiwi '${kiwi_name}' configured in 8 channel mode has ${wd_listeners_count} WD listeners. So all of them should be on rx ch 2-7, but  ${wd_ch_01_listeners_count} listeners are on ch 0 or ch 1: \n${active_receivers_list}"
        if ${GREP_CMD} -q ${kiwi_name} <<< "${RUNNING_JOBS[@]}"; then
            wd_logger 1 " found '${kiwi_name}' is in use by this instance of WD, so add code to clean up the RX channels used"
            ### TODO: recover from listener on rx 0/1 code here 
        else
            wd_logger 1 " do nothing, since '${kiwi_name}' is not in my RUNNING_JOBS[]= ${RUNNING_JOBS[@]}'"
        fi
    else
        wd_logger 3 " Kiwi '${kiwi_name}' configured for 8 rx channels found WD usage is OK"
    fi
}

### Check that WD listeners are on channels 2...7
function check_kiwi_rx_channels() {
    local kiwi
    local kiwi_list=$(list_kiwis)
    wd_logger 2 " starting a check of rx channel usage on all Kiwis"

    for kiwi in ${kiwi_list} ; do
        wd_logger 4 " check active users on Kiwi '${kiwi}'"
        check_kiwi_wspr_channels ${kiwi}
    done
}

### If there are no GPS locks and it has been 24 hours since the last attempt to let the Kiwi get lock, stop all jobs for X seconds
declare KIWI_GPS_LOCK_CHECK=${KIWI_GPS_LOCK_CHECK-yes} ## :=no}
declare KIWI_GPS_LOCK_CHECK_INTERVAL=600 #$((24 * 60 * 60))  ### Seconds between checks
declare KIWI_GPS_STARUP_LOCK_WAIT_SECS=60                    ### When first starting and the Kiwi reports no GPS lock, poll for lock this many seconds
declare KIWI_GPS_LOCK_LOG_DIR=${WSPRDAEMON_TMP_DIR}/kiwi_gps_status

function check_kiwi_gps() {
    wd_logger 2 " start check of all known Kiwis"

    local kiwi
    local kiwi_list=$(list_kiwis)
    wd_logger 4 " got list of all defined Kiwis = '${kiwi_list}'"

    for kiwi in ${kiwi_list} ; do
        wd_logger 4 " check lock on Kiwi '${kiwi}'"
        let_kiwi_get_gps_lock ${kiwi}
    done
    wd_logger 2 " check completed"
}

### Once every KIWI_GPS_LOCK_CHECK_INTERVAL seconds check to see if the Kiwi is in GPS lock by seeing that the 'fixes' counter is incrementing
function let_kiwi_get_gps_lock() {
    [[ ${KIWI_GPS_LOCK_CHECK} != "yes" ]] && return
    local kiwi_name=$1
    local kiwi_ip=$(get_receiver_ip_from_name ${kiwi_name})

    ### Check to see if Kiwi reports gps status and if the Kiwi is locked to enough satellites
    local kiwi_status=$(curl -s --connect-timeout 5 ${kiwi_ip}/status)
    if [[ -z "${kiwi_status}" ]]; then
        wd_logger 1 " got no response from Kiwi '${kiwi_name}'"
        return
    fi
    local kiwi_gps_good_count=$(awk -F = '/gps_good=/{print $2}' <<< "${kiwi_status}" )
    if [[ -z "${kiwi_gps_good_count}" ]]; then
        wd_logger 1 " kiwi '${kiwi_name}' is running SW which doesn't report gps_good status"
        return
    fi
    declare GPS_MIN_GOOD_COUNT=4
    if [[ ${kiwi_gps_good_count} -lt ${GPS_MIN_GOOD_COUNT} ]]; then
        wd_logger 2 " kiwi '${kiwi_name}' reports '${kiwi_gps_good_count}' good GPS which is less than the min of ${GPS_MIN_GOOD_COUNT} we require. So GPS is bad on this Kiwi"
        ### TODO: don't perturb the Kiwi too often if it doesn't have GPS lock
    else
        wd_logger 3 " kiwi '${kiwi_name}' reports '${kiwi_gps_good_count}' good GPS which is greater than or equal to the min of ${GPS_MIN_GOOD_COUNT} we require. So GPS is OK on this Kiwi"
        ### TODO:  just return here once I am confident that further checks are not needed
        ### return
    fi

    ### Double check the GPS status by seeing if the fixes count has gone up
     ## Check to see if/when we last checked the Kiwi's GPS status
    if [[ ! -d ${KIWI_GPS_LOCK_LOG_DIR} ]]; then
        mkdir -p ${KIWI_GPS_LOCK_LOG_DIR}
        wd_logger 2 "created dir '${KIWI_GPS_LOCK_LOG_DIR}'"
    fi
    local kiwi_gps_log_file=${KIWI_GPS_LOCK_LOG_DIR}/${kiwi_name}_last_gps_fixes.log
    if [[ ! -f ${kiwi_gps_log_file} ]]; then 
        echo "0" > ${kiwi_gps_log_file}
        wd_logger 2 "created log file '${kiwi_gps_log_file}'"
    fi
    local kiwi_last_fixes_count=$(cat ${kiwi_gps_log_file})
    local current_time=$(date +%s)
    local kiwi_last_gps_check_time=$(date -r ${kiwi_gps_log_file} +%s)
    local seconds_since_last_check=$(( ${current_time} - ${kiwi_last_gps_check_time} ))

    if [[ ${kiwi_last_fixes_count} -gt 0 ]] && [[ ${seconds_since_last_check} -lt ${KIWI_GPS_LOCK_CHECK_INTERVAL} ]]; then
        wd_logger 3 " too soon to check Kiwi '${kiwi_name}'. Only ${seconds_since_last_check} seconds since last check"
        return
    fi
    ### fixes is 0 OR it is time to check again
    local kiwi_fixes_count=$(awk -F = '/fixes=/{print $2}' <<< "${kiwi_status}" )
    if [[ -z "${kiwi_fixes_count}" ]]; then
        wd_logger 1 " kiwi '${kiwi_name}' is running SW which doesn't report fixes status"
        return
    fi
    wd_logger 3 " got new fixes count '${kiwi_fixes_count}' from kiwi '${kiwi_name}'"
    if [[ ${kiwi_fixes_count} -gt ${kiwi_last_fixes_count} ]]; then
        wd_logger 3 " Kiwi '${kiwi_name}' is locked since new count ${kiwi_fixes_count} is larger than old count ${kiwi_last_fixes_count}"
        echo ${kiwi_fixes_count} > ${kiwi_gps_log_file}
        return
    fi
    if [[ ${kiwi_fixes_count} -lt ${kiwi_last_fixes_count} ]]; then
        wd_logger 2 " Kiwi '${kiwi_name}' is locked but new count ${kiwi_fixes_count} is less than old count ${kiwi_last_fixes_count}. Our old count may be stale (from a previous run), so save this new count"
        echo ${kiwi_fixes_count} > ${kiwi_gps_log_file}
        return
    fi
    wd_logger 2 " Kiwi '${kiwi_name}' reporting ${GPS_MIN_GOOD_COUNT} locks, but new count ${kiwi_fixes_count} == old count ${kiwi_last_fixes_count}, so fixes count has not changed"
    ### GPS fixes count has not changed. If there are active users or WD clients, kill those sessions so as to free the Kiwi to search for sats
    local active_receivers_list=$( curl -s --connect-timeout 5 ${kiwi_ip}/users | sed -n '/"i":\([0-9]\),"n"/s//\n\1/gp' | ${GREP_CMD} "^[0-9]" )
    if [[ -z "${active_receivers_list}" ]];  then
        wd_logger 2 " found no active rx channels on Kiwi '${kiwi_name}, so it is already searching for GPS"
        touch ${kiwi_gps_log_file}
        return
    fi
    wd_logger 2 " This is supposed to no longer be needed, but it appears that we terminate active users on Kiwi '${kiwi_name}' so it can get GPS lock: \n${active_receivers_list}"
}



### Get the /status page from the file ..../KIWI.../status.d/status.cached
### First check if that file is older than 1 minute and update the file from the Kiww
### Return error if you can't get current status from cache or Kiwi

function get_receiver_status()
{
    local __return_status_var=$1        ### Whole file in one string
    local receiver_name=$2

    if [[ "${receiver_name}" =~ ^Audio ]]; then
        wd_logger 1 "Can't get status for an AUDIO receive device, so return empty string"
        eval ${__return_status_var}=""
        return 0
    fi
    ### For now, assume receive with any name which starts without AUDIO... is a Kiwi.
    get_kiwi_status ${__return_status_var} ${receiver_name}
    local rc=$?
    wd_logger 1 "'get_kiwi_status ${__return_status_var} ${receiver_name}' => ${rc}"
    return ${rc}
}

function get_kiwi_status()
{
    local __return_status_var=$1        ### Return all the Kiwi's status lines in one string
    local kiwi_ip_port=$2
    local rc
    wd_logger 2 "Get status lines from Kiwi at IP:PORT '${kiwi_ip_port}'"

    ### Assume this function is called by the decodign daemon which is running in .../KIWI.../BAND, Sso the status for this Kwiw will be cached in ../status.d/kiwi_status.cache
    local kiwi_status_mutex_name="kiwi_status"
    local kiwi_status_dir="${PWD}/../${kiwi_status_mutex_name}.d"          ### The directory where we will put the cached Kiwi status information
          kiwi_status_dir=$(realpath ${kiwi_status_dir})
    if [[ ! -d ${kiwi_status_dir} ]]; then
        wd_logger 1 "Creating '${kiwi_status_dir}'"
        mkdir -p ${kiwi_status_dir}     ### There may be a race with ohter decoding jobs, but at least oneof them will succeed, so no need to test for an error
    fi

    wd_logger 2 "Locking access to status directory '${kiwi_status_dir}' of Kiwi '${kiwi_ip_port}'"

    wd_mutex_lock ${kiwi_status_mutex_name}  ${kiwi_status_dir} 
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to lock access to ${kiwi_status_dir}"
        return 1
    fi
    wd_logger 2 "Locked access to ${kiwi_status_dir}"

    local kiwi_status_cache_file="${kiwi_status_dir}/${kiwi_status_mutex_name}.cache"         ### The file which contains the cached Kiwi status information
    local kiwi_status_cache_file_age

    if [[ ! -f ${kiwi_status_cache_file} ]]; then
        wd_logger 1 "There is no cache file, so force refresh"
        kiwi_status_cache_file_age=999    ### Force a refresh of the cache file
    else
        local kiwi_status_cache_file_epoch=$( stat -c %Y ${kiwi_status_cache_file} )
        local current_epoch=$(printf "%(%s)T" -1 )   ### faster than 'date -s'
        kiwi_status_cache_file_age=$(( ${current_epoch} - ${kiwi_status_cache_file_epoch} ))
        wd_logger 2 "Cache file exists and is ${kiwi_status_cache_file_age} seconds old"
    fi

    if [[ ${kiwi_status_cache_file_age} -lt ${KIWI_STATUS_CACHE_FILE_MAX_AGE-10} ]]; then
        wd_logger 2 "Cache file is only ${kiwi_status_cache_file_age} seconds old, so no need to refresh it"
    else
        wd_logger 2 "Cache file ${kiwi_status_cache_file} is ${kiwi_status_cache_file_age} seconds old, so archive the current status and update it from the Kiwi"
        if [[ -f ${kiwi_status_cache_file} ]]; then
            mv ${kiwi_status_cache_file} ${kiwi_status_cache_file}.old
        fi
        curl --connect-timeout ${KIWI_GET_STATUS_TIMEOUT-4} ${kiwi_ip_port}/status 2> ${kiwi_status_cache_file}.stderr.txt > ${kiwi_status_cache_file}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            ### Free the lock before returning the error
            local rc1
            wd_mutex_unlock ${kiwi_status_mutex_name}  ${kiwi_status_dir} 
            rc1=$?
            if [[ ${rc1} -ne 0 ]] ; then
                wd_logger 1 "ERROR: failed 'wd_mutex_free ${kiwi_status_mutex_name}  ${kiwi_status_dir}'  => ${rc1} after 'curl --connect-timeout ${KIWI_GET_STATUS_TIMEOUT-4} ${kiwi_ip_port}/status 2> ${kiwi_status_cache_file}.stderr.txt > ${kiwi_status_cache_file}' => ${rc}"
            fi
            wd_logger 1 "ERROR: error or timeout updating status cache file from ${kiwi_ip_port}/status"
            return ${rc}
        fi
    fi
    local cached_status_lines="$(< ${kiwi_status_cache_file})"

    wd_mutex_unlock ${kiwi_status_mutex_name}  ${kiwi_status_dir} 
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to unlock mutex '${kiwi_status_mutex_name}' in ${kiwi_status_dir}"
    else
        wd_logger 2 "Unlocked mutex '${kiwi_status_mutex_name}' in ${kiwi_status_dir}"
    fi

    wd_logger 2 "Returning the current cached status in '${__return_status_var}'" #:\n${cached_status_lines}"
    eval ${__return_status_var}=\${cached_status_lines}
    return 0
}

###
declare KIWIRECORDER_KILL_WAIT_SECS=10       ### Seconds to wait after kiwirecorder is dead so as to ensure the Kiwi detects there is no longer a client and frees that rx2...7 channel

### NOTE: This function assumes it is executing in the KIWI/BAND directory of the job to be killed
function kiwirecorder_manager_daemon_kill_handler() {
    if [[ ! -f ${KIWI_RECORDER_PID_FILE} ]]; then
        wd_logger 2 "ERROR: found no ${KIWI_RECORDER_PID_FILE}" 
    else
        local kiwi_recorder_pid=$( < ${KIWI_RECORDER_PID_FILE} )
        wd_rm ${KIWI_RECORDER_PID_FILE}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'wd_rm ${KIWI_RECORDER_PID_FILE}' => ${rc}"
        fi
        if [[ -z "${kiwi_recorder_pid}" ]]; then
            wd_logger 1 "ERROR: ${KIWI_RECORDER_PID_FILE} is empty" 
        elif !  ps ${kiwi_recorder_pid} > /dev/null ; then
            wd_logger 1 "ERROR: kiwi_recorder_daemon is already dead"
        else
            wd_kill ${kiwi_recorder_pid}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'wd_kill ${kiwi_recorder_pid}' => ${rc}"
            fi
            local timeout=0
            while [[ ${timeout} < ${KIWIRECORDER_KILL_WAIT_SECS} ]] &&  ps ${kiwi_recorder_pid} > /dev/null; do
                wd_logger 1 "Waiting for kiwi_recorder_daemon(0 to die"
                (( ++timeout ))
                sleep 1
            done
            if ps ${kiwi_recorder_pid} > /dev/null; then
                wd_logger 1 "ERROR: kiwi_recorder_pid=${kiwi_recorder_pid} failed to die after waiting for ${KIWIRECORDER_KILL_WAIT_SECS} seconds"
            else
                wd_logger 1 "kiwi_recorder_daemon() has died after ${timeout} seconds"
            fi
        fi
    fi
   exit
}

### This daemon spawns a kiwirecorder.py session and monitor's its stdout for 'OV' lines
declare KIWI_RECORDER_PID_FILE="kiwi_recorder.pid"
declare KIWI_RECORDER_LOG_FILE="kiwi_recorder.log"
declare OVERLOADS_LOG_FILE="kiwi_recorder_overloads_count.log"   ### kiwirecorder_manager_daemon logs the OV
if [[ -n "${KIWI_TIMEOUT_PASSWORD-}" ]]; then
    KIWI_TIMEOUT_DISABLE_COMMAND_ARG="--tlimit-pw=${KIWI_TIMEOUT_PASSWORD}"
fi

function get_kiwirecorder_status()
{
    local __return_status_var=$1
    local kiwi_ip_port=$2

    wd_logger 2 "Get status with 'get_kiwi_status get_kiwi_status_lines  ${kiwi_ip_port}'"

    local get_kiwi_status_lines=""     ### In case the Kiwi isn't there
    local rc
    get_kiwi_status get_kiwi_status_lines  ${kiwi_ip_port}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'get_kiwi_status get_kiwi_status_lines  ${kiwi_ip_port}' => ${rc}"
        return 1
    fi

    if [[ -z "${get_kiwi_status_lines}" ]]; then
        wd_logger 1 "ERROR: 'get_kiwi_status get_kiwi_status_lines  ${kiwi_ip_port}' => 0, but get_kiwi_status_lines is empty"
        return 1
    fi

    wd_logger 2 "Got $(  echo "${get_kiwi_status_lines}" | wc -l  ) status lines from '${kiwi_ip_port}'"

    eval ${__return_status_var}="\${get_kiwi_status_lines}"
    return 0
}

function get_kiwirecorder_ov_count_from_ip_port()
{
    local __return_ov_count_var=$1
    local kiwi_ip_port=$2
 
    local rc
    local kiwi_status_lines

    get_kiwirecorder_status  kiwi_status_lines  ${kiwi_ip_port}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'get_kiwirecorder_status  kiwi_status_lines  ${kiwi_ip_port}' => ${rc}"
        return 2
    fi
    local ov_value
    ov_value=$( echo "${kiwi_status_lines}" | awk -F = '/^adc_ov/{print $2}' )
    if [[ -z "${ov_value}" ]]; then
        wd_logger 1 "ERROR: couldn't extract 'adc_ov' from kiwi's status lines"
        return 3
    fi
    wd_logger 2 "Got current adc_ov = ${ov_value}"
    eval ${__return_ov_count_var}=\${ov_value}
    return 0
}

function get_kiwirecorder_ov_count()
{
    local __return_ov_count_var=$1
    local kiwi_name=$2

    local kiwi_ip_port
    local rc
    get_kiwi_ip_port  kiwi_ip_port  ${kiwi_name}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'get_kiwi_ip_port  kiwi_ip_port  ${kiwi_name}' => ${rc}"
        return 1
    fi

    local kiwi_status_lines
    get_kiwirecorder_status  kiwi_status_lines  ${kiwi_ip_port}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'get_kiwirecorder_status  kiwi_status_lines  ${kiwi_ip_port}' => ${rc}"
        return 2
    fi
    local ov_value
    ov_value=$( echo "${kiwi_status_lines}" | awk -F = '/^adc_ov/{print $2}' )
    if [[ -z "${ov_value}" ]]; then
        wd_logger 1 "ERROR: couldn't extract 'adc_ov' from kiwi's status lines"
        return 3
    fi
    wd_logger "Got current adc_ov = ${ov_value}"
    eval ${__return_ov_count_var}=\${ov_value}
    return 0
}

declare KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR=${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR-10}    ### Wait 10 seconds after detecting an error before trying to spawn a new KWR

function kiwirecorder_manager_daemon()
{
    local receiver_name=$1
    local receiver_ip=$2
    local receiver_rx_freq_khz=$3
    local my_receiver_password=$4
    local recording_client_name=${KIWIRECORDER_CLIENT_NAME:-wsprdaemon_v${VERSION}}

    setup_verbosity_traps          ## So we can increment and decrement verbosity without restarting WD

    wd_logger 1 "Starting in $PWD.  Recording from ${receiver_ip} on ${receiver_rx_freq_khz}"

    local kiwi_offset=$(get_receiver_khz_offset_list_from_name ${receiver_name})
    local kiwi_tune_freq=$( bc <<< " ${receiver_rx_freq_khz} - ${kiwi_offset}" )

    ### If the Kiwi returns the OV count in its status page, then don't have the Kiwi output 'ADC OV' lines to its log file
    ### By polling the /status page, there is no potential of filling the kiwi's log file which requires the kiwirecord job to be killed and restarted
    ### So Kiwis should no longer need intermittent restarts.
    local kiwirecorder_ov_flag
    local rc 
    local ov_count_var
    get_kiwirecorder_ov_count_from_ip_port  ov_count_var  ${receiver_ip}
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
        wd_logger 1 "The kiwi's /status page reports the current adc_ov count = ${ov_count_var}, so disabling the kiwi's 'ADC OV' logging since that data is available in the kiwi's status page"
        kiwirecorder_ov_flag=""
    else
        wd_logger 1 "ERROR: (not really), but this kiwi at ${receiver_ip} is running an old version of SW which doesn't output OV on its status page, so we have to enabled the output of 'ADC OV' lines to the kiwirecord's log"
        kiwirecorder_ov_flag="--OV"
    fi

    while true ; do

        ### Check to see if the PID in ${KIWI_RECORDER_PID_FILE} is running, and kill all zomvie PIDs
        local kiwi_recorder_pid=""
        local file_kiwi_recorder_pid=""
        if [[ -f ${KIWI_RECORDER_PID_FILE} ]]; then
            ### Check that the pid specified in the pid file is active and kill any zombies
            file_kiwi_recorder_pid=$( < ${KIWI_RECORDER_PID_FILE})                      ### receiver_ip IP:PORT => IP.*PORT
        fi
        ps aux > ps.log          ### 9/12/23 Avoid using pipes and see if that helps avoid the 'can't spawn kiwirecorder problem
        grep "${KIWI_RECORD_COMMAND}.*${receiver_rx_freq_khz}.*${receiver_ip/:/.*}" ps.log > ps_kiwi.log
        local pid_list=( $( awk '{print $2}' ps_kiwi.log)  )
        local ps_kiwi_recorder_pid 
        for ps_kiwi_recorder_pid in ${pid_list[@]} ;  do
            if [[ -n "${file_kiwi_recorder_pid}" && ${ps_kiwi_recorder_pid} -eq ${file_kiwi_recorder_pid} ]]; then
                wd_logger 1 "Found the expected file_kiwi_recorder_pid=${file_kiwi_recorder_pid} saved in ${KIWI_RECORDER_PID_FILE} is running"
                kiwi_recorder_pid="${file_kiwi_recorder_pid}"
            else
                wd_logger 1 "ERROR: a zombie ps_kiwi_recorder_pid=${ps_kiwi_recorder_pid} is not the PID ${file_kiwi_recorder_pid} found in ${KIWI_RECORDER_PID_FILE}), so kill it"
                wd_kill ${ps_kiwi_recorder_pid}
            fi
        done
        wd_logger 2 "Finished checking 'ps aux' output"

        while [[ -z "${kiwi_recorder_pid}"  ]]; do
            if [[ -f ${KIWI_RECORDER_PID_FILE} ]]; then
                wd_rm  ${KIWI_RECORDER_PID_FILE} 
            fi
            local rc
            python3 -u ${KIWI_RECORD_COMMAND} \
                    --freq=${receiver_rx_freq_khz} --server-host=${receiver_ip/:*} --server-port=${receiver_ip#*:} \
                    ${kiwirecorder_ov_flag} --user=${recording_client_name}  --password=${my_receiver_password} \
                    --agc-gain=60 --quiet --no_compression --modulation=usb --lp-cutoff=${LP_CUTOFF-1340} --hp-cutoff=${HP_CUTOFF-1660} --dt-sec=60 ${KIWI_TIMEOUT_DISABLE_COMMAND_ARG-} > ${KIWI_RECORDER_LOG_FILE} 2>&1 &
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: rc=${rc}. Failed to spawn kiwirecorder.py job.  Sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR} seconds and retry spawning"
                wd_sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR}
                continue
            else
                kiwi_recorder_pid=$!
                echo ${kiwi_recorder_pid} > ${KIWI_RECORDER_PID_FILE}
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'Successfully spawned kiwirecorder.py job with PID ${kiwi_recorder_pid}, but 'echo ${kiwi_recorder_pid} > ${KIWI_RECORDER_PID_FILE}' => ${rc}, soo sleep and spawn again"
                    kiwi_recorder_pid=""
                    wd_sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR}
                    continue
                else
                    wd_logger 1 "Successfully spawned kiwirecorder.py job with PID ${kiwi_recorder_pid} and recorded it to ${KIWI_RECORDER_PID_FILE}, sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR} seconds"
                    wd_sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR}
                fi
            fi

            ### To try to ensure that wav files are not corrupted (i.e. too short, too long, or missing) because of CPU starvation:
            #### Raise the priority of the kiwirecorder.py job to (by default) -15 so that wsprd, jt9 or other programs are less likely to preempt it
            ps --no-headers -o ni ${kiwi_recorder_pid} > before_nice_level.txt
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: While checking nice level before renicing 'ps --no-headers -o ni ${kiwi_recorder_pid}' => ${rc}, so sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR} seconds and retry spawning"
                wd_sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR}
                continue
            fi
            local before_nice_level=$(< before_nice_level.txt)

            ### Raise the priority of the KWR process
            sudo renice --priority ${KIWI_RECORDER_PRIORITY--15} ${kiwi_recorder_pid}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'renice --priority -15 ${kiwi_recorder_pid}' => ${rc}"
                wd_sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR}
                continue
            fi

            ps --no-headers -o ni ${kiwi_recorder_pid} > after_nice_level.txt
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: While checking for after_nice_level with 'ps --no-headers -o ni ${kiwi_recorder_pid}' => ${rc}, so sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR} seconds and retry spawning"
                wd_sleep ${KIWI_RECORDER_SLEEP_SECS_AFTER_ERROR}
                continue
            fi
            local after_nice_level=$(< after_nice_level.txt)
            wd_logger 1 "New kiwirecorder job with PID ${kiwi_recorder_pid} is running and was renice(d) from ${before_nice_level} to ${after_nice_level}"
        done

        if [[ ! -f ${OVERLOADS_LOG_FILE} ]]; then
            ## Initialize the file which logs the date in epoch seconds, and the number of OV errors since that time
            printf "%(%s)T 0" -1  > ${OVERLOADS_LOG_FILE}
        fi

        if [[ -n "${kiwirecorder_ov_flag}" && ! -s ${KIWI_RECORDER_LOG_FILE} ]]; then
            wd_logger 2 "The Kiwi is running old code which doesn't report overloads in its status page, so we are using the old technique of counting OVs in the Kiwi's stdout saved in ${KIWI_RECORDER_LOG_FILE}\nBut that file  is empty, so no overloads have been reported and thus there are no OV counts to be checked"
        else
            local current_time=$(printf "%(%s)T" -1 )
            local old_ov_info=( $(tail -1 ${OVERLOADS_LOG_FILE}) )
            local old_ov_count=${old_ov_info[1]}
            local new_ov_count=0

            if [[ -z "${kiwirecorder_ov_flag}" ]]; then
                ### We can poll the status page to learn if there are any new ov events
                local rc
                wd_logger 2 "Getting overload counts from the Kiwi's status page"
                get_kiwirecorder_ov_count_from_ip_port  ov_count_var  ${receiver_ip}
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: failed to get expected status from kiwi"
                else
                    local new_ov_count=${ov_count_var}
                    if [[ ${new_ov_count} -eq ${old_ov_count} ]]; then
                        wd_logger 2 "The ov count ${new_ov_count} reported by the Kiwi status page hasn't changed"
                    else
                        if [[ ${new_ov_count} -gt ${old_ov_count} ]]; then
                            wd_logger 2 "The ov count reported by the Kiwi has increased from ${old_ov_count} to ${new_ov_count}"
                        else
                            wd_logger 1 "The ov count ${new_ov_count} reported by the Kiwi status page is less than the previously reported count of ${old_ov_count}, so the Kiwi seems to have restarted"
                        fi
                        printf "\n${current_time} ${new_ov_count}" >> ${OVERLOADS_LOG_FILE}
                    fi
                fi
            elif [[ ${KIWI_RECORDER_LOG_FILE} -nt ${OVERLOADS_LOG_FILE} ]]; then
                ### Since kwirecorder has recently written one or more "OV" lines to its output, so count the number of new lines
                new_ov_count=$( ${GREP_CMD} OV ${KIWI_RECORDER_LOG_FILE} | wc -l )
                if [[ -z "${new_ov_count}" ]]; then
                    wd_logger 1 "Found no lines with 'OV' in ${KIWI_RECORDER_LOG_FILE}"
                    new_ov_count=0
                fi
                local new_ov_time=${current_time}
                if [[ "${new_ov_count}" -lt "${old_ov_count}" ]]; then
                    wd_logger 1 "Found '${KIWI_RECORDER_LOG_FILE}' has changed, but new OV count '${new_ov_count}' is less than old count '${old_ov_count}', so kiwirecorder job must have restarted"
                    printf "\n${current_time} ${new_ov_count}" >> ${OVERLOADS_LOG_FILE}
                elif [[ "${new_ov_count}" -eq "${old_ov_count}" ]]; then
                     wd_logger 1 "WARNING: Found '${KIWI_RECORDER_LOG_FILE}' has changed but new OV count '${new_ov_count}' is the same as old count '${old_ov_count}', which is unexpected"
                    touch ${OVERLOADS_LOG_FILE}
                else
                    printf "\n${current_time} ${new_ov_count}" >> ${OVERLOADS_LOG_FILE}
                    local ov_event_count=$(( "${new_ov_count}" - "${old_ov_count}" ))
                    wd_logger 1 "Found ${new_ov_count} new - ${old_ov_count} old = ${ov_event_count} new OV events were reported by kiwirecorder.py"
                fi
            fi

            ### If there have been OV events, then every 10 minutes printout the count and mark the most recent line in ${OVERLOADS_LOG_FILE} as PRINTED
            local latest_ov_log_line=( $(tail -1 ${OVERLOADS_LOG_FILE}) )   
            local latest_ov_count=${latest_ov_log_line[1]}
            local last_ov_print_line=( $(awk '/PRINTED/{t=$1; c=$2} END {printf "%d %d", t, c}' ${OVERLOADS_LOG_FILE}) )   ### extracts the time and count from the last PRINTED line
            local last_ov_print_time=${last_ov_print_line[0]-0}   ### defaults to 0
            local last_ov_print_count=${last_ov_print_line[1]-0}  ### defaults to 0
            local secs_since_last_ov_print=$(( ${current_time} - ${last_ov_print_time} ))
            local ov_print_interval=${OV_PRINT_INTERVAL_SECS-600}        ## By default, print OV count every 10 minutes
            local ovs_since_last_print=$((${latest_ov_count} - ${last_ov_print_count}))
            if [[ ${secs_since_last_ov_print} -ge ${ov_print_interval} ]] && [[ "${ovs_since_last_print}" -gt 0 ]]; then
                wd_logger 1 "$(printf "%5d overload events (OV) were reported in the last ${ov_print_interval} seconds" ${ovs_since_last_print})" 
                printf " PRINTED" >> ${OVERLOADS_LOG_FILE}
            fi
            truncate_file ${OVERLOADS_LOG_FILE} ${MAX_OV_FILE_SIZE-100000}

            local kiwi_recorder_log_size=$( ${GET_FILE_SIZE_CMD} ${KIWI_RECORDER_LOG_FILE} )
            if [[ ${kiwi_recorder_log_size} -gt ${MAX_KIWI_RECORDER_LOG_FILE_SIZE-200000} ]]; then
                ### Limit the kiwi_recorder.log file to less than 200 KB which is about 25000 2 minute reports
                wd_logger 1 "${KIWI_RECORDER_LOG_FILE} has grown too large (${kiwi_recorder_log_size} bytes), so killing kiwi_recorder"
                wd_kill ${kiwi_recorder_pid}
                local rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: when restarting after log file overflow, 'wd_kill ${kiwi_recorder_pid}' => ${rc}"
                fi
                wd_rm ${KIWI_RECORDER_PID_FILE}
                local rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: when restarting after log file overflow, 'wd_rm ${KIWI_RECORDER_PID_FILE}' => ${rc}"
                fi
            fi
        fi
        wd_sleep ${KIWI_POLLING_SLEEP-30}    ### By default sleep 30 seconds between each check of the Kiwi status
    done
}
