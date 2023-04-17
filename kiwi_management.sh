#!/bin/bash

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

KIWI_CACHE_LOCK_TIMEOUT=${KIWI_CACHE_LOCK_TIMEOUT-5}

function get_kiwi_status()
{
    local __return_status_var=$1        ### Return all the Kiwi's status lines in one string
    local kiwi_ip_port=$2

    wd_logger 1 "Get status lines from Kiwi at IP:PORT '${kiwi_ip_port}'"

    ### Assume this function is called by the decodign daemon which is running in .../KIWI.../BAND, Sso the status for this Kwiw will be cached in ../status.d/kiwi_status.cache
    local kiwi_status_dir="${PWD}/../status.d"
    if [[ ! -d ${kiwi_status_dir} ]]; then
        wd_logger 1 "Creating '${kiwi_status_dir}'"
        mkdir ${kiwi_status_dir}     ### There may be a race with ohter decoding jobs, but at least oneof them will succeed, so no need to test for an error
    fi
    kiwi_status_dir=$(realpath ${kiwi_status_dir})

    local kiwi_status_cache_file="${kiwi_status_dir}/kiwi_status.cache"
    local kiwi_cache_lock_dir="${kiwi_status_dir}/lock.d"

    wd_logger 1 "Trying to lock access to status directory of Kiwi '${kiwi_ip_port}' by executing 'mkdir ${kiwi_cache_lock_dir}"
    local timeout=0
    while ! mkdir ${kiwi_cache_lock_dir} 2> /dev/null && [[ ${timeout} -lt ${KIWI_CACHE_LOCK_TIMEOUT-3} ]]; do
        ((++timeout))
        local sleep_secs
        sleep_secs=$(( ( ${RANDOM} % ${KIWI_CACHE_LOCK_TIMEOUT-3} ) + 1 ))      ### randomize the sleep time or all the lister sessions will hang while wating for the lock to free
        wd_logger 1 "Try  #${timeout} of 'mkdir ${kiwi_cache_lock_dir}' failed.  Sleep ${sleep_secs}  and retry"
        wd_sleep ${sleep_secs}
    done
    if [[ ${timeout} -ge ${KIWI_CACHE_LOCK_TIMEOUT-3} ]]; then
        local sleep_secs
        sleep_secs=$(( ( ${RANDOM} % ${KIWI_CACHE_LOCK_TIMEOUT-3} ) + 1 ))      ### randomize the sleep time or all the lister sessions will hang while wating for the lock to free
        wd_logger 1 "ERROR: timeout after ${KIWI_CACHE_LOCK_TIMEOUT-3} seconds (${timeout} tries) while waiting to lock access to ${kiwi_status_dir}, sleeping..."
        wd_sleep ${sleep_secs}
        return 1
    fi
    wd_logger 1 "Locked access to ${kiwi_status_dir} after ${timeout} tries"

    local kiwi_status_cache_file_age

    if [[ ! -f ${kiwi_status_cache_file} ]]; then
        wd_logger 1 "There is no cache file, so force refresh"
        kiwi_status_cache_file_age=999    ### Force a refresh of the cache file
    else
        local kiwi_status_cache_file_epoch
        kiwi_status_cache_file_epoch=$( stat -c %Y ${kiwi_status_cache_file} )
        local current_epoch
        current_epoch=$(printf "%(%s)T" -1 )   ### faster than 'date -s'
        kiwi_status_cache_file_age=$(( ${current_epoch} - ${kiwi_status_cache_file_epoch} ))
        wd_logger 1 "Cache file exists and is ${kiwi_status_cache_file_age} seconds old"
    fi

    if [[ ${kiwi_status_cache_file_age} -lt ${KIWI_STATUS_CACHE_FILE_MAX_AGE-60} ]]; then
        wd_logger 1 "Cache file is only ${kiwi_status_cache_file_age} seconds old, so no need to refresh it"
    else
        wd_logger 1 "Cache file ${kiwi_status_cache_file} is ${kiwi_status_cache_file_age} seconds old, so archive the current status and update it from teh Kiwi"
        if [[ -f ${kiwi_status_cache_file} ]]; then
            mv ${kiwi_status_cache_file} ${kiwi_status_cache_file}.old
        fi
        curl --connect-timeout ${KIWI_GET_STATUS_TIMEOUT-2} ${kiwi_ip_port}/status 2> ${kiwi_status_cache_file}.stderr.txt > ${kiwi_status_cache_file}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            ### Free the lock before returning the error
            rmdir ${kiwi_cache_lock_dir}
            wd_logger 1 "ERROR: error or timeout updating status cache file from ${kiwi_ip_port}/status"
            return ${rc}
        fi
    fi
    local cached_status_lines="$(< ${kiwi_status_cache_file})"
    local rc
    rmdir ${kiwi_cache_lock_dir}    ### Unloacks access to the cache file
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: freeing lock with 'rmdir ${kiwi_cache_lock_dir}' => ${rc}"
        exit
    fi

    wd_logger 1 "Returning the current cached status in '${__return_status_var}'" #:\n${cached_status_lines}"
    eval ${__return_status_var}=\${cached_status_lines}
    return 0
}

