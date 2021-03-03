
###################################################
function check_kiwi_wspr_channels() {
    local kiwi_name=$1
    local kiwi_ip=$(get_receiver_ip_from_name ${kiwi_name})

    local users_max=$(curl -s --connect-timeout 5 ${kiwi_ip}/status | awk -F = '/users_max/{print $2}')
    if [[ -z "${users_max}" ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' not present or its SW doesn't report 'users_max', so nothing to do"
        return
    fi
    if [[ ${users_max} -lt 8 ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' is configured for ${users_max} users, not in 8 channel mode.  So nothing to do"
        return
    fi

    local active_receivers_list=$( curl -s --connect-timeout 5 ${kiwi_ip}/users | sed -n '/"i":\([0-9]\),"n"/s//\n\1/gp' | ${GREP_CMD} "^[0-9]" )
    if [[ -z "${active_receivers_list}" ]];  then
        [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' not reporting users status or there are no active rx channels on it.  So nothing to do"
        return
    fi
    [[ $verbosity -ge 4 ]] && printf "$(date): check_kiwi_wspr_channels() Kiwi '%s' active listeners:\n%s\n" "${kiwi_name}" "${active_receivers_list}"

    if ! ${GREP_CMD} -q "wsprdaemon" <<< "${active_receivers_list}" ; then
        [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' has no active WD listeners"
        return
    fi
    local wd_listeners_count=$( ${GREP_CMD} wsprdaemon <<< "${active_receivers_list}" | wc -l) 
    local wd_ch_01_listeners_count=$( ${GREP_CMD} "^[01]:.wsprdaemon" <<< "${active_receivers_list}" | wc -l) 
    [[ $verbosity -ge 3 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' has ${wd_listeners_count} WD listeners of which ${wd_ch_01_listeners_count} listeners are on ch 0 or ch 1"
    if [[ ${wd_listeners_count} -le 6 && ${wd_ch_01_listeners_count} -gt 0 ]]; then
        if [[ $verbosity -ge 1 ]] ; then
            echo   "$(date): check_kiwi_wspr_channels() WARNING, Kiwi '${kiwi_name}' configured in 8 channel mode has ${wd_listeners_count} WD listeners."
            printf "$(date):    So all of them should be on rx ch 2-7,  but %s isteners are on ch 0 or ch 1: \n%s\n" "${wd_ch_01_listeners_count}" "${active_receivers_list}"
        fi
        if ${GREP_CMD} -q ${kiwi_name} <<< "${RUNNING_JOBS[@]}"; then
            [[ $verbosity -ge 1 ]] && echo "$(date): check_kiwi_wspr_channels() found '${kiwi_name}' is in use by this instance of WD, so add code to clean up the RX channels used"
            ### TODO: recover from listener on rx 0/1 code here 
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): check_kiwi_wspr_channels() do nothing, since '${kiwi_name}' is not in my RUNNING_JOBS[]= ${RUNNING_JOBS[@]}'"
        fi
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' configured for 8 rx channels found WD usage is OK"
    fi
}

### Check that WD listeners are on channels 2...7
function check_kiwi_rx_channels() {
    local kiwi
    local kiwi_list=$(list_kiwis)
    [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_rx_channels() starting a check of rx channel usage on all Kiwis"

    for kiwi in ${kiwi_list} ; do
        [[ $verbosity -ge 4 ]] && echo "$(date): check_kiwi_rx_channels() check active users on KIWI '${kiwi}'"
        check_kiwi_wspr_channels ${kiwi}
    done
}

### If there are no GPS locks and it has been 24 hours since the last attempt to let the Kiwi get lock, stop all jobs for X seconds
declare KIWI_GPS_LOCK_CHECK=${KIWI_GPS_LOCK_CHECK-yes} ## :=no}
declare KIWI_GPS_LOCK_CHECK_INTERVAL=600 #$((24 * 60 * 60))  ### Seconds between checks
declare KIWI_GPS_STARUP_LOCK_WAIT_SECS=60               ### Wher first starting and the Kiwi reports no GPS lock, poll for lock this many seconds
declare KIWI_GPS_LOCK_LOG_DIR=${WSPRDAEMON_TMP_DIR}/kiwi_gps_status

function check_kiwi_gps() {
    [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_gps() start check of all known Kiwis"

    local kiwi
    local kiwi_list=$(list_kiwis)
    [[ $verbosity -ge 4 ]] && echo "$(date): check_kiwi_gps() got list of all defined KIWIs = '${kiwi_list}'"

    for kiwi in ${kiwi_list} ; do
        [[ $verbosity -ge 4 ]] && echo "$(date): check_kiwi_gps() check lock on KIWI '${kiwi}'"
        let_kiwi_get_gps_lock ${kiwi}
    done
    [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_gps() check completed"
}

### Once every KIWI_GPS_LOCK_CHECK_INTERVAL seconds check to see if the Kiwi is in GPS lock by seeing that the 'fixes' counter is incrementing
function let_kiwi_get_gps_lock() {
    [[ ${KIWI_GPS_LOCK_CHECK} != "yes" ]] && return
    local kiwi_name=$1
    local kiwi_ip=$(get_receiver_ip_from_name ${kiwi_name})

    ### Check to see if Kiwi reports gps status and if the Kiwi is locked to enough satellites
    local kiwi_status=$(curl -s --connect-timeout 5 ${kiwi_ip}/status)
    if [[ -z "${kiwi_status}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() got no response from kiwi '${kiwi_name}'"
        return
    fi
    local kiwi_gps_good_count=$(awk -F = '/gps_good=/{print $2}' <<< "${kiwi_status}" )
    if [[ -z "${kiwi_gps_good_count}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' is running SW which doesn't report gps_good status"
        return
    fi
    declare GPS_MIN_GOOD_COUNT=4
    if [[ ${kiwi_gps_good_count} -lt ${GPS_MIN_GOOD_COUNT} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' reports '${kiwi_gps_good_count}' good GPS which is less than the min of ${GPS_MIN_GOOD_COUNT} we require.  So GPS is bad on this Kiwi"
        ### TODO: don't perturb the Kiwi too often if it doesn't have GPS lock
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' reports '${kiwi_gps_good_count}' good GPS which is greater than or equal to the min of ${GPS_MIN_GOOD_COUNT} we require.  So GPS is OK on this Kiwi"
        ### TODO:  just return here once I am confident that further checks are not needed
        ### return
    fi

    ### Double check the GPS status by seeing if the fixes count has gone up
     ## Check to see if/when we last checked the Kiwi's GPS status
    if [[ ! -d ${KIWI_GPS_LOCK_LOG_DIR} ]]; then
        mkdir -p ${KIWI_GPS_LOCK_LOG_DIR}
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() created dir '${KIWI_GPS_LOCK_LOG_DIR}'"
    fi
    local kiwi_gps_log_file=${KIWI_GPS_LOCK_LOG_DIR}/${kiwi_name}_last_gps_fixes.log
    if [[ ! -f ${kiwi_gps_log_file} ]]; then 
        echo "0" > ${kiwi_gps_log_file}
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() created log file '${kiwi_gps_log_file}'"
    fi
    local kiwi_last_fixes_count=$(cat ${kiwi_gps_log_file})
    local current_time=$(date +%s)
    local kiwi_last_gps_check_time=$(date -r ${kiwi_gps_log_file} +%s)
    local seconds_since_last_check=$(( ${current_time} - ${kiwi_last_gps_check_time} ))

    if [[ ${kiwi_last_fixes_count} -gt 0 ]] && [[ ${seconds_since_last_check} -lt ${KIWI_GPS_LOCK_CHECK_INTERVAL} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() too soon to check KIWI '${kiwi_name}'.  Only ${seconds_since_last_check} seconds since last check"
        return
    fi
    ### fixes is 0 OR it is time to check again
    local kiwi_fixes_count=$(awk -F = '/fixes=/{print $2}' <<< "${kiwi_status}" )
    if [[ -z "${kiwi_fixes_count}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' is running SW which doesn't report fixes status"
        return
    fi
    [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() got new fixes count '${kiwi_fixes_count}' from kiwi '${kiwi_name}'"
    if [[ ${kiwi_fixes_count} -gt ${kiwi_last_fixes_count} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() Kiwi '${kiwi_name}' is locked since new count ${kiwi_fixes_count} is larger than old count ${kiwi_last_fixes_count}"
        echo ${kiwi_fixes_count} > ${kiwi_gps_log_file}
        return
    fi
    if [[ ${kiwi_fixes_count} -lt ${kiwi_last_fixes_count} ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() Kiwi '${kiwi_name}' is locked but new count ${kiwi_fixes_count} is less than old count ${kiwi_last_fixes_count}. Our old count may be stale (from a previous run), so save this new count"
        echo ${kiwi_fixes_count} > ${kiwi_gps_log_file}
        return
    fi
    [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() Kiwi '${kiwi_name}' reporting ${GPS_MIN_GOOD_COUNT} locks, but new count ${kiwi_fixes_count} == old count ${kiwi_last_fixes_count}, so fixes count has not changed"
    ### GPS fixes count has not changed.  If there are active users or WD clients, kill those sessions so as to free the Kiwi to search for sats
    local active_receivers_list=$( curl -s --connect-timeout 5 ${kiwi_ip}/users | sed -n '/"i":\([0-9]\),"n"/s//\n\1/gp' | ${GREP_CMD} "^[0-9]" )
    if [[ -z "${active_receivers_list}" ]];  then
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() found no active rx channels on Kiwi '${kiwi_name}, so it is already searching for GPS"
        touch ${kiwi_gps_log_file}
        return
    fi
    [[ $verbosity -ge 2 ]] && printf "$(date): let_kiwi_get_gps_lock() this is supposed to no longer be needed, but it appears that we terminate active users on Kiwi '${kiwi_name}' so it can get GPS lock: \n%s\n" "${active_receivers_list}"
}


