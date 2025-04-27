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
    wd_logger 1 "Not adding grape_upload_daemon() to the watchdog_daemon_list[] since GRAPE_PSWS_ID is not defined in WD.conf"
else
    wd_logger 1 "Adding grape_upload_daemon() to the watchdog_daemon_list[] since GRAPE_PSWS_ID is defined in WD.con"
    watchdog_daemon_list+=("grape_upload_daemon     ${GRAPE_WAV_ARCHIVE_ROOT_PATH}")
fi

### 
### Returns 0 if no KA9Q  receive channels are configured in WD.conf, returns 1 if there is one or more KA9Q rx channel.
### 
function ka9q_rx_channel_is_configured()
{
    if [[ -z "${WSPR_SCHEDULE[@]-}" ]]; then
        wd_logger 1 "ERROR: the expected WSPR_SCHEDULE[] array is not defined in WD.conf"
        exit 2
    fi
    if ! [[ "${WSPR_SCHEDULE[@]}" =~ KA9Q|MERGE ]]; then
        wd_logger 1 "No KA9Q channels are configured on this WD server"
        return 0
    fi
    if [[ "${WSPR_SCHEDULE[@]}" =~ KA9Q ]]; then
        wd_logger 1 "There are KA9Q channels configured on this WD server"
        return 1
    fi
    ### TBD: This code needs to be finished and debugged
    ### There is ar MERG... receiver in the schedule.  See if it includes a KA9Q receiver
    local schedule_index
    for (( schedule_index=0; schedule_index < ${#WSPR_SCHEDULE[@]}; ++schedule_index )); do
        local jobs_list=( ${WSPR_SCHEDULE[schedule_index]} )
        local job
        for job in ${jobs_list[@]:1} ; do
            local job_receiver=${job%%,*}
            if [[ $job =~ MERGE ]]; then
                ### TBD: here...
                true
            fi
        done
    done
    wd_logger 1 "No KA9Q channels are found in the MERG.. receivers on this WD server"
    return 0
}

if [[ ka9q_rx_channel_is_configured != 1 ]]; then
    wd_logger 1 "Not adding ka9q_web_daemon() to watchdog_daemon_list[] since there are no KA9Q receivers"
else
    wd_logger 1 "Adding ka9q_web_daemon() to watchdog_daemon_list[] since there are KA9Q receivers"
    watchdog_daemon_list+=( "ka9q_web_daemon         ${WSPRDAEMON_ROOT_DIR}" )
fi

function test_ka9q_rx_channel_is_configured()
{ 
    ka9q_rx_channel_is_configured
    exit 0
}
(( ${test_new_feature-0} )) && test_ka9q_rx_channel_is_configured


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
