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
            wd_tar_wavs
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

############## Top level which spawns/kill/shows status of all of the watchdog daemons
declare watchdog_daemon_list=(
   "watchdog_daemon         ${WSPRDAEMON_ROOT_DIR}"
)

### '-w l cmd runs this
function tail_watchdog_log() {
    less +F ${PATH_WATCHDOG_LOG}
}

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
