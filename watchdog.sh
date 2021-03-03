##########################################################################################################################################################
########## Section which creates and manages the 'top level' watchdog daemon  ############################################################################
##########################################################################################################################################################

declare -r    PATH_WATCHDOG_PID=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.pid
declare -r    PATH_WATCHDOG_LOG=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.log

### Wake up every odd minute and verify that the system is running properly
function watchdog_daemon() 
{
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    wd_logger 0 "Starting as pid $$\n"
    while true; do
        wd_logger 2 "Is awake"
        validate_configuration_file
        update_master_hashtable
        spawn_upload_daemons
        check_for_zombies
        start_or_kill_jobs a all
        purge_stale_recordings
        if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]] || [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS-no} == "yes" ]]; then
            plot_noise 24
        fi
        check_kiwi_rx_channels
        check_kiwi_gps
        print_new_ov_lines          ## 
        local sleep_secs=$( seconds_until_next_odd_minute )
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
    WD_LOG_FILE=${PATH_WATCHDOG_LOG} watchdog_daemon & 
    watchdog_pid=$!
    echo ${watchdog_pid}  > ${watchdog_pid_file}
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

    if [[ ! -f ${watchdog_pid_file} ]]; then
        if [[ ${verbosity} -ge 1 ]]; then
            echo "$(date): show_watchdog() found no watchdog daemon pid file '${watchdog_pid_file}'"
        else
            echo "No Watchdog deaemon is running"
        fi
        return
    fi
    local watchdog_pid=$(cat ${watchdog_pid_file})
    if [[ ! ${watchdog_pid} =~ ^[0-9]+$ ]]; then
        echo "Watchdog pid file '${watchdog_pid_file}' contains '${watchdog_pid}' which is not a decimal integer number"
        return
    fi
    if ! ps ${watchdog_pid} > /dev/null ; then
        echo "Watchdog deamon with pid '${watchdog_pid}' not running"
        rm ${watchdog_pid_file}
        return
    fi
    if [[ ${verbosity} -ge 1 ]]; then
        echo "$(date): Watchdog daemon with pid ${watchdog_pid} is running"
    else
        echo "The watchdog daemon is running"
    fi
}

### '-w z' runs this:
function kill_watchdog() {
    show_watchdog

    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}
    if [[ ! -f ${watchdog_pid_file} ]]; then
        echo "Watchdog pid file '${watchdog_pid_file}' doesn't exist"
        return
    fi
    local watchdog_pid=$(cat ${watchdog_pid_file})    ### show_watchog returns only if this file is valid
    [[ ${verbosity} -ge 2 ]] && echo "$(date): kill_watchdog() file '${watchdog_pid_file} which contains pid ${watchdog_pid}"

    kill ${watchdog_pid}
    echo "Killed watchdog with pid '${watchdog_pid}'"
    rm ${watchdog_pid_file}
}

#### -w [i,a,z] command
function watchdog_cmd() {
    [[ ${verbosity} -ge 2 ]] && echo "$(date): watchdog_cmd() got cmd $1"
    
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
}


