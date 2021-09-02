##########################################################################################################################################################
########## Section which creates and manages the 'top level' watchdog daemon  ############################################################################
##########################################################################################################################################################

declare -r    PATH_WATCHDOG_PID=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.pid
declare -r    PATH_WATCHDOG_LOG=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.log
declare       WATCHDOG_POLL_SECONDS=5      ## How often the watchdog wakes up to check for all the log files for new lines and at the beginning of each odd minute run zombie checks, create noise graphs, etc....

### Wake up every odd minute and verify that the system is running properly
function watchdog_daemon() 
{
    local last_minute=-1
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    wd_logger_flush_all_logs
    wd_logger 1 "Starting in $PWD as pid $$"
    while true; do
        wd_logger_check_all_logs
        local current_minute=$(( 10#$(printf "%(%M)T") % 2 ))    ### '10#...' strips leading zeros resulting in: 0 st=> we are in an even minute, 1 => we are in an odd minute
        if [[ ${last_minute} -lt 0 || ( ${last_minute} == 0  && ${current_minute} == 1 ) ]]; then
            wd_logger 1 "Starting odd minute, do all watching functions"
            validate_configuration_file
            update_master_hashtable
            spawn_upload_daemons
            # check_for_zombies
            start_or_kill_jobs a all
            purge_stale_recordings
            if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]] || [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS-no} == "yes" ]]; then
                plot_noise 24
            fi
            check_kiwi_rx_channels
            check_kiwi_gps
            print_new_ov_lines          ## 
            wd_logger 2 "Finished odd minute processing"
        fi
        last_minute=${current_minute}
        local sleep_secs=${WATCHDOG_POLL_SECONDS}
        wd_logger 2 "Complete.  Sleeping for $sleep_secs seconds."
        sleep ${sleep_secs}
    done
}


### '-a' and '-w a' cmds run this:
function spawn_watchdog_daemon(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}
    local watchdog_pid

    if [[ -f ${watchdog_pid_file} ]]; then
        watchdog_pid=$(cat ${watchdog_pid_file})
        if [[ ${watchdog_pid} =~ ^[0-9]+$ ]]; then
            if ps ${watchdog_pid} > /dev/null ; then
                echo "Watchdog deamon with pid '${watchdog_pid}' is already running"
                return
            else
                echo "Deleting watchdog pid file '${watchdog_pid_file}' with stale pid '${watchdog_pid}'"
            fi
        fi
        rm -f ${watchdog_pid_file}
    fi
    setup_systemctl_deamon
    wd_logger 1 "Spawning watchdog_daemon"
    WD_LOGFILE=${PATH_WATCHDOG_LOG} watchdog_daemon  &
    watchdog_pid=$!
    echo ${watchdog_pid}  > ${watchdog_pid_file}
    wd_logger 1 "watchdog_daemon spawned and logging to ${WD_LOGFILE}"
    echo "Watchdog deamon with pid '${watchdog_pid}' is now running"
}

### '-w l cmd runs this
function tail_watchdog_log() {
    less +F ${PATH_WATCHDOG_LOG}
}


### '-w s' cmd runs this:
function show_watchdog(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}

    wd_logger 2 "Starting.  watchdog_pid_file=${PATH_WATCHDOG_PID}, watchdog_file_dir=${watchdog_pid_file%/*}"
    if [[ ! -f ${watchdog_pid_file} ]]; then
        wd_logger 1 "Found no watchdog daemon pid file '${watchdog_pid_file}'"
    else
        local watchdog_pid=$(cat ${watchdog_pid_file})
        if ! ps ${watchdog_pid} > /dev/null ; then
            wd_logger 1 "Watchdog deamon with pid '${watchdog_pid}' not running"
            rm ${watchdog_pid_file}
        else
            wd_logger 1 "Watchdog daemon with pid ${watchdog_pid} is running"
        fi
    fi
    wd_logger 2 "Finished"
}

### '-w z' runs this:
function kill_watchdog() {

    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}
    wd_logger 2 "Starting. watchdog_pid_file=${PATH_WATCHDOG_PID}, watchdog_file_dir=${watchdog_pid_file%/*}"

    if [[ ! -f ${watchdog_pid_file} ]]; then
        wd_logger 2 "Watchdog pid file '${watchdog_pid_file}' doesn't exist"
    else
        local watchdog_pid=$(cat ${watchdog_pid_file})    ### show_watchog returns only if this file is valid

        wd_logger 2 "Found ${watchdog_pid_file} which contains pid ${watchdog_pid}"
        if ! ps ${watchdog_pid} > /dev/null ; then
            wd_logger 2 "Watchdog deamon with pid '${watchdog_pid}' not running"
        else
            kill ${watchdog_pid}
            wd_logger 1 "Killed watchdog with pid '${watchdog_pid}'"
        fi
        rm ${watchdog_pid_file}
    fi
    wd_logger 2 "Finished"
}

#### -w [i,a,z] command
function watchdog_cmd() {
    wd_logger 2 "Executing cmd $1"
    
    case ${1} in
        a)
            spawn_watchdog_daemon
            ;;
        z)
            kill_watchdog
            kill_upload_daemons
            ;;
        s)
            show_watchdog
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


