##########################################################################################################################################################
########## Section which creates and manages the 'top level' watchdog daemon  ############################################################################
##########################################################################################################################################################

declare       WATCHDOG_POLL_SECONDS=5  ### How often the watchdog wakes up to check for all the log files for new lines and at the beginning of each odd minute run zombie checks, create noise graphs, etc....
declare       WATCHDOG_PRINT_ALL_LOGS=${WATCHDOG_PRINT_ALL_LOGS-no}

### Wake up every odd minute and verify that the system is running properly
function watchdog_daemon() 
{
    local last_minute=-1
    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD
    wd_logger_flush_all_logs
    rm -f hhmm.sched running.jobs
    wd_logger 1 "Starting in $PWD as pid $$"
    while true; do
        if [[ ${WATCHDOG_PRINT_ALL_LOGS} == "yes" ]]; then
            wd_logger_check_all_logs
        fi
        local current_minute=$(( 10#$(printf "%(%M)T") % 2 ))    ### '10#...' strips leading zeros resulting in: 0 st=> we are in an even minute, 1 => we are in an odd minute
        if [[ ${last_minute} -lt 0 || ( ${last_minute} == 0  && ${current_minute} == 1 ) ]]; then
            wd_logger 1 "Starting odd minute, do all watching functions"
            validate_configuration_file
            source ${WSPRDAEMON_CONFIG_FILE}
            spawn_upload_daemons
            # check_for_zombies
            start_or_kill_jobs a all
            purge_stale_recordings
            if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]] || [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS-no} == "yes" ]]; then
                plot_noise 24
            fi
            check_kiwi_rx_channels
            check_kiwi_gps
            print_new_ov_lines 
            wd_logger 2 "Finished odd minute processing"
        fi
        last_minute=${current_minute}
        local sleep_secs=${WATCHDOG_POLL_SECONDS}
        wd_logger 2 "Complete. Sleeping for $sleep_secs seconds."
        wd_sleep ${sleep_secs}
    done
}

function get_status_watchdog_daemon()
{
    daemons_list_action  s  watchdog_daemon_list
    get_status_upload_daemons
}

function kill_watchdog_daemon()
{
    daemons_list_action  z watchdog_daemon_list
    kill_upload_daemons
}

############## Top level which spawns/kill/shows status of all of the top level daemons
declare watchdog_daemon_list=(
   "watchdog_daemon         ${WSPRDAEMON_ROOT_DIR}"
)

if [[ -z "${GRAPE_PSWS_ID-}" ]]; then
    wd_logger 2 "Not adding grape_upload_daemon() to the watchdog_daemon_list[] since GRAPE_PSWS_ID is not defined in WD.conf"
else
    wd_logger 2 "Adding grape_upload_daemon() to the watchdog_daemon_list[] since GRAPE_PSWS_ID is defined in WD.con"
    watchdog_daemon_list+=("grape_upload_daemon     ${GRAPE_WAV_ARCHIVE_ROOT_PATH}")
fi

### 
### Returns 0 if no KA9Q  receive channels are configured in WD.conf, returns 1 if there is one or more KA9Q rx channel.
### 
function ka9q_rx_channel_is_configured()
{
    local __return_var_name="$1"

    if [[ -z "${WSPR_SCHEDULE[@]-}" ]]; then
        wd_logger 1 "ERROR: the expected WSPR_SCHEDULE[] array is not defined in WD.conf"
        exit 2
    fi

    local return_value=0       ### 0 => no KA9Q receive jobs,  1 => one or more KA9Q jobs
    if [[  -n "${KA9Q_RUNS_ONLY_REMOTELY-}" ]]; then
        wd_logger 2 "KA9Q_RUNS_ONLY_REMOTELY='$KA9Q_RUNS_ONLY_REMOTELY', so download and compile the ~/ka9q-radio directory and spawn ka9q-web"
         return_value=1
    elif ! [[ "${WSPR_SCHEDULE[@]}" =~ KA9Q|MERG ]]; then
        wd_logger 2 "No KA9Q channels are configured on this WD server"
    elif [[ "${WSPR_SCHEDULE[@]}" =~ KA9Q ]]; then
        wd_logger 2 "There are KA9Q channels configured on this WD server"
        return_value=1
    else
        ### There is a MERG... receiver in the schedule.  See if it includes a KA9Q receiver
        local schedule_index
        for (( schedule_index=0; schedule_index < ${#WSPR_SCHEDULE[@]}; ++schedule_index )); do
            local jobs_list=( ${WSPR_SCHEDULE[schedule_index]} )
            local job
            for job in ${jobs_list[@]:1} ; do
                local job_receiver=${job%%,*}
                if [[ $job =~ MERG ]]; then
                    local merg_rx="${job%%,*}"
                    local merg_rx_index=$(get_receiver_list_index_from_name $merg_rx)
                    if [[ -z "$merg_rx_index" ]]; then
                        wd_logger 1 "ERROR: can't find merg_rx_index for '$merg_rx' in the RECEIVER_LIST"
                        exit 2
                    fi
                    if [[ ${RECEIVER_LIST[merg_rx_index]} =~ KA9Q ]]; then
                        wd_logger 2 "Found a MERG receiver which includes a KA9Q receiver in WSPR_SCHEDULE[${schedule_index}]}: '${WSPR_SCHEDULE[schedule_index]}'"
                        return_value=1
                        break
                    fi
                fi
            done
        done
        (( return_value == 0 )) && wd_logger 2 "No KA9Q channels are found in the MERG.. receivers on this WD server"
    fi
    wd_logger 2 "Returning $return_value from a search"
    eval $__return_var_name=\$return_value
    return 0
}

declare ka9q_rx_is_active
ka9q_rx_channel_is_configured "ka9q_rx_is_active"
if (( $ka9q_rx_is_active != 1)); then
    wd_logger 2 "Not adding ka9q_web_daemon() to watchdog_daemon_list[] since there are no KA9Q receivers"
else
    wd_logger 2 "Adding ka9q_web_daemon() to watchdog_daemon_list[] since there are KA9Q receivers"
    watchdog_daemon_list+=( "ka9q_web_daemon         ${WSPRDAEMON_ROOT_DIR}" )
fi

function test_ka9q_rx_channel_is_configured()
{ 
    local test_if_configured
    ka9q_rx_channel_is_configured "test_if_configured"
    wd_logger 1 "'ka9q_rx_channel_is_configured()' => $test_if_configured"
    exit 0
}
# (( ${test_new_feature-0} )) && test_ka9q_rx_channel_is_configured


#### -w [a,z,s,l] command
function watchdog_cmd() {
    wd_logger 2 "Executing cmd $1"
    
    case $1 in
        a)
            daemons_list_action  $1 watchdog_daemon_list
            ;;
        s)
            get_status_watchdog_daemon
            ;;
        z)
            kill_watchdog_daemon
            ;;
        l)
            tail_watchdog_log
            ;;
        *)
            echo "ERROR: argument '${1}' not valid"
            exit 1
    esac
    wd_logger 2 "Finished  cmd $1"
}
