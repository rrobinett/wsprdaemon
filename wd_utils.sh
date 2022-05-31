#!/bin/bash

###  Wsprdaemon:   A robust  decoding and reporting system for  WSPR

###    Copyright (C) 2020-2021  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###    GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

shopt -s -o nounset                               ### bash stops with error if undeclared variable is referenced

declare -i verbosity=${verbosity:-1}              ### default to level 1, but can be overridden on the cmd line.  e.g "v=2 wsprdaemon.sh -V"

declare WD_LOGFILE=${WD_LOGFILE-}                                ### Top level command doesn't log by default since the user needs to get immediate feedback
declare WD_LOGFILE_SIZE_MAX=${WD_LOGFILE_SIZE_MAX-1000000}        ### Limit log files to 1 Mbyte

lc_numeric=$(locale | sed -n '/LC_NUMERIC/s/.*="*\([^"]*\)"*/\1/p')        ### There must be a better way, but locale sometimes embeds " in its output and this gets rid of them
if [[ "${lc_numeric}" != "POSIX" ]] && [[ "${lc_numeric}" != "en_US" ]] && [[ "${lc_numeric}" != "en_US.UTF-8" ]] && [[ "${lc_numeric}" != "en_GB.UTF-8" ]] && [[ "${lc_numeric}" != "C.UTF-8" ]] ; then
    echo "WARNING:  LC_NUMERIC '${lc_numeric}' on your server is not the expected value 'en_US.UTF-8'."     ### Try to ensure that the numeric frequency comparisons use the format nnnn.nnnn
    echo "          If the spot frequencies reported by your server are not correct, you may need to change the 'locale' of your server"
fi

### This gets called when there is a system error and helps me find those lines DOESN'T WORK - TODO: debug
trap 'rc=$?; echo "Error code ${rc} at line ${LINENO} in file ${BASH_SOURCE[0]} line #${BASH_LINENO[0]}"' ERR

###  Returns 0 if arg is an unsigned integer, else 1
function is_uint() { case $1        in '' | *[!0-9]*              ) return 1;; esac ;}

###
function wd_logger_flush_all_logs {
    wd_logger 2 "Flushing all .log and .printed files"
    find ${WSPRDAEMON_TMP_DIR} ${WSPRDAEMON_ROOT_DIR} -type f -name '*.log'     -exec rm {} \;
    find ${WSPRDAEMON_TMP_DIR} ${WSPRDAEMON_ROOT_DIR} -type f -name '*.printed' -exec rm {} \;
}

declare WD_LOGGING_EXCLUDE_LOG_FILENAMES="add_derived.log curl.log kiwi_recorder.log kiwi_recorder_overloads_count.log merged.log"
declare WD_LOGGING_EXCLUDE_DIR_NAMES="kiwi_gps_status"

function wd_logger_check_all_logs 
{
    local check_only_for_errors=${1-no}

    local log_file_paths_list=( $( find ${WSPRDAEMON_TMP_DIR} ${WSPRDAEMON_ROOT_DIR} -name '*.log' | sort -r ) )
    wd_logger 2 "Checking ${#log_file_paths_list[@]} log files"

    for log_file_path in ${log_file_paths_list[@]} ; do
        local log_file_path_list=( ${log_file_path//\// } )
        local log_file_name=${log_file_path_list[-1]}
        local log_dir_name=${log_file_path_list[-2]}

        if [[ " ${WD_LOGGING_EXCLUDE_DIR_NAMES} " =~ " ${log_dir_name}" ]] || [[ " ${WD_LOGGING_EXCLUDE_LOG_FILENAMES} " =~ " ${log_file_name} " ]]; then
            wd_logger 2 "Skipping ${log_file_path}"
            continue
        fi
        wd_logger 2 "Checking ${log_file_path}"
        local log_file_last_printed=${log_file_path}.printed
        if [[ ! -s ${log_file_path} ]]; then
            wd_logger 1 "Log file ${log_file_path} is empty"
            continue
        fi
        ### The log file is not empty
        local new_log_lines_file=${WSPRDAEMON_TMP_DIR}/new_log_lines.txt
        if [[ ! -f ${log_file_last_printed} ]] ; then
            ### There is no *printed file, so search the whole log file
            wd_logger 2 "No ${log_file_last_printed} file, so none of the log lines in ${log_file_path} (if any) have been printed"
            cp ${log_file_path} ${new_log_lines_file}
        else
            ###  There is a *.printed file
            local last_printed_line=$( < ${log_file_last_printed} )
            if [[ -z "${last_printed_line}" ]]; then
                ### But that file is empty
                wd_logger 1 "The last_printed_line in ${log_file_last_printed} is empty, so delete that file and print all lines"
                wd_rm ${log_file_last_printed}
                cp ${log_file_path} ${new_log_lines_file}
            else
                ### There is a line in the *printed file
                if ! grep -q "${last_printed_line}" ${log_file_path} ; then
                    wd_logger 2 "Can't find that the line '${last_printed_line}' in ${log_file_last_printed} is in ${log_file_path}"
                    wd_rm ${log_file_last_printed}
                    cp ${log_file_path} ${new_log_lines_file}
                else
                    wd_logger 2 "Found line in ${log_file_last_printed} file is present in ${log_file_path}, so print only the lines which follow it"
                    grep -A 100000 "${last_printed_line}" ${log_file_path}  | tail -1 > ${new_log_lines_file}
                    if [[ ! -s ${new_log_lines_file} ]]; then
                        wd_logger 1 "Found no lines to print in ${log_file_path}, so nothing to print"
                        continue
                    fi
                    if [[ $( wc -l < ${new_log_lines_file}) -lt 2 ]]; then
                         wd_logger 2 "Last line of the log file has already been printed"
                         continue
                    fi
                fi
            fi
        fi
        ### There are new lines
        if [[ ${check_only_for_errors} == "check_only_for_new_errors" ]]; then
            local new_error_log_lines_file=${WSPRDAEMON_TMP_DIR}/new_error_log_lines.txt 
            grep -A 100000 "ERROR:" ${new_log_lines_file} > ${new_error_log_lines_file}
            if [[ ! -s ${new_error_log_lines_file} ]]; then
                local new_log_lines_count=$( wc -l < ${new_log_lines_file} )
                wd_logger 2 "$( printf "Found no 'ERROR:' lines in the %'6d new log lines of '${log_file_path}', so remember the last line of current log file '${log_file_last_printed} " ${new_log_lines_count})" 
                tail -n 1 ${log_file_path} > ${log_file_last_printed}
                continue
            else
                wd_logger 1 "\nFound $( grep "ERROR:" ${new_error_log_lines_file} | wc -l ) new 'ERROR:' lines in ${log_file_path} among its $( wc -l < ${new_log_lines_file}) new log lines.  Here is the first ERROR: line:"
                grep "ERROR:" ${new_error_log_lines_file} | head -n 1
                read -p "Press <ENTER> to check the next log file or 'l' to 'less all the new lines after that new ERROR line ${new_error_log_lines_file} > "
                if [[ -n "${REPLY}" ]]; then
                    less ${new_error_log_lines_file}
                fi
                tail -n 1 ${log_file_path} > ${log_file_last_printed}
                continue
            fi
        fi
        
        if [[ -z "${new_log_lines}" ]]; then
            wd_logger 2 "There are no lines or no new lines in ${log_file_path} to be printed"
        else
            local new_log_lines_count=$( echo "${new_error_log_lines}" | wc -l  )
            wd_logger 1 "There are ${new_log_lines_count} new lines to be printed"
            local new_last_printed_line=$( echo "${new_error_log_lines}" | tail -1)
            echo "${new_last_printed_line}" > ${log_file_last_printed}
            local new_lines_to_print=$( echo "${new_log_lines}" | awk "{print \"${log_file_path}: \" \$0}")
            wd_logger -1 "\n$( echo "${new_lines_to_print}" | head -n 8 )"
            [[ ${verbosity} -ge 1 ]] && read -p "Press <ENTER> to check the next log file > "
        fi
    done
}

declare CHECK_FOR_LOG_ERROR_LINES_SLEEP_SECS=10
function print_new_log_lines()
{
    wd_logger -1 "Checking every ${CHECK_FOR_LOG_ERROR_LINES_SLEEP_SECS} seconds for new ERROR lines in all the log files.  Press <CONTROL C> to exit"
    while true; do
        wd_logger_check_all_logs "check_only_for_new_errors"
        sleep ${CHECK_FOR_LOG_ERROR_LINES_SLEEP_SECS}
    done
}

function tail_log_file()
{
    local log_file=${1}

    wd_logger -1 "To view the full log file execute the command: 'less ${log_file}'\n"
    sleep 2
    wd_logger -1 "Running 'tail -F ${log_file}':\n"
    tail -F ${log_file}
    less ${log_file}
}

function log_file_viewing()
{
    local action=${1-e}

    case ${action} in
        e)
            print_new_log_lines
            ;;
        n)
            tail_log_file ${UPLOADS_WSPRNET_SPOTS_LOG_FILE}
            ;;
        d)
            tail_log_file ${UPLOADS_WSPRDAEMON_SPOTS_LOG_FILE}
            ;;
        *)
            wd_logger 1 "ERROR: invalid action ${action}"
            ;;
    esac
}

function wd_logger() {
    if [[ $# -ne 2 ]]; then
        local prefix_str=$(TZ=UTC printf "${WD_TIME_FMT}: ${FUNCNAME[1]}()")
        local bad_args="$@"
        echo "${prefix_str} called from function ${FUNCNAME[1]} in file ${BASH_SOURCE[1]} line #${BASH_LINENO[0]} with bad number of arguments: '${bad_args}'"
        return 1
    fi
    local log_at_level=$1
    local printout_string=$2

    local print_time_and_calling_function_name="yes"
    if [[ $1 -lt 0 ]]; then
        print_time_and_calling_function_name="no"
        log_at_level=$((- ${log_at_level} )) 
    fi
    [[ ${verbosity} -lt ${log_at_level} ]] && return 0

    ### printf "${WD_TIME_FMT}: ${FUNCNAME[1]}() passed FORMAT: %s\n" -1 "${format_string}"
    local time_and_calling_function_name=""
    if [[ ${print_time_and_calling_function_name} == "yes" ]]; then
        time_and_calling_function_name=$(TZ=UTC printf "${WD_TIME_FMT}: ${FUNCNAME[1]}() "  -1)          ### printf "%(..)T ..." looks at the first -1 argument to signal 'current time'
    fi
    local printout_line="${time_and_calling_function_name}${printout_string}"

    if [ -t 0 -a -t 1 -a -t 2 ]; then
        ### This program is not a daemon, it is attached to a terminal.  So echo to that terminal
        echo -e "${printout_line}"                                              ### use [ -t 0 ...] to test if this is being run from a terminal session
    fi

    if [[ -z "${WD_LOGFILE-}" ]]; then
        ### No WD_LOGFILE has been defined, so nothing more to do
        return 0
    fi

    ### WD_LOGFILE is defined, so truncate if it has grown too large, then append the new log line(s)
    [[ ! -f ${WD_LOGFILE} ]] && touch ${WD_LOGFILE}       ### In case it doesn't yet exist
    local logfile_size=$( ${GET_FILE_SIZE_CMD} ${WD_LOGFILE} )
    if [[ ${logfile_size} -ge ${WD_LOGFILE_SIZE_MAX} ]]; then
        local logfile_lines=$(wc -l < ${WD_LOGFILE})
        local logfile_lines_to_trim=$(( logfile_lines / 4 ))       ### Trim off the first 25% of the lines
        printf "${WD_TIME_FMT}: ${FUNCNAME[0]}() logfile '${WD_LOGFILE}' size ${logfile_size} and lines ${logfile_lines} has grown too large, so truncating the first ${logfile_lines_to_trim} lines of it\n" >> ${WD_LOGFILE}
        sed -i "1,${logfile_lines_to_trim} d" ${WD_LOGFILE}
    fi
    echo -e "${printout_line}" >> ${WD_LOGFILE}
    return 0
}

#############################################
function verbosity_increment() {
    verbosity=$(( $verbosity + 1))
    wd_logger 0 "verbosity now = ${verbosity}"
}
function verbosity_decrement() {
    [[ ${verbosity} -gt 0 ]] && verbosity=$(( $verbosity - 1))
    wd_logger 0 "verbosity now = ${verbosity}"
}

function setup_verbosity_traps() {
    trap verbosity_increment SIGUSR1
    trap verbosity_decrement SIGUSR2
}

function signal_verbosity() {
    local up_down=$1
    local pid_files=$(find ${RUNNING_IN_DIR} -maxdepth 1 -name '*.pid')

    if [[ -z "${pid_files}" ]]; then
        echo "No *.pid files in ${RUNNING_IN_DIR}"
        return
    fi
    local file
    for file in ${pid_files} ; do
        local debug_pid=$(cat ${file})
        if ! ps ${debug_pid} > /dev/null ; then
            echo "PID ${debug_pid} from ${file} is not running"
        else
            echo "Signaling verbosity change to PID ${debug_pid} from ${file}"
            kill -SIGUSR${up_down} ${debug_pid}
        fi
    done
}

### executed by cmd line '-d'
function increment_verbosity() {
    signal_verbosity 1
}
### executed by cmd line '-D'
function decrement_verbosity() {
    signal_verbosity 2
}

function seconds_until_next_even_minute() {
    local current_min_secs=$(date +%M:%S)
    local current_min=$((10#${current_min_secs%:*}))    ### chop off leading zeros
    local current_secs=$((10#${current_min_secs#*:}))   ### chop off leading zeros
    local current_min_mod=$(( ${current_min} % 2 ))
    current_min_mod=$(( 1 - ${current_min_mod} ))     ### Invert it
    local secs_to_even_min=$(( $(( ${current_min_mod} * 60 )) + $(( 60 - ${current_secs} )) ))
    echo ${secs_to_even_min}
}

function seconds_until_next_odd_minute() {
    local current_min_secs=$(date +%M:%S)
    local current_min=$((10#${current_min_secs%:*}))    ### chop off leading zeros
    local current_secs=$((10#${current_min_secs#*:}))   ### chop off leading zeros
    local current_min_mod=$(( ${current_min} % 2 ))
    local secs_to_odd_min=$(( $(( ${current_min_mod} * 60 )) + $(( 60 - ${current_secs} )) ))
    if [[ -z "${secs_to_odd_min}" ]]; then
        secs_to_odd_min=105   ### Default in case of math errors above
    fi
    echo ${secs_to_odd_min}
}

### Configure systemctl so this watchdog daemon runs at startup of the Pi
declare -r SYSTEMCTL_UNIT_PATH=/lib/systemd/system/wsprdaemon.service
function setup_systemctl_daemon() {
    local start_args=${1--a}         ### Defaults to client start/stop args, but '-u a' (run as upload server) will configure with '-u a/z'
    local stop_args=${2--z} 
    local systemctl_dir=${SYSTEMCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        echo "$(date): setup_systemctl_daemon() WARNING, this server appears to not be configured to use 'systemctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMCTL_UNIT_PATH} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): setup_systemctl_daemon() found this server already has a ${SYSTEMCTL_UNIT_PATH} file. So leaving it alone."
        return
    fi
    local my_id=$(id -u -n)
    local my_group=$(id -g -n)
    cat > ${SYSTEMCTL_UNIT_PATH##*/} <<EOF
    [Unit]
    Description= WSPR daemon
    After=multi-user.target

    [Service]
    User=${my_id}
    Group=${my_group}
    WorkingDirectory=${WSPRDAEMON_ROOT_DIR}
    ExecStart=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.sh ${start_args}
    ExecStop=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.sh ${stop_args}
    Type=forking
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF
   ask_user_to_install_sw "Configuring this computer to run the watchdog daemon after reboot or power up.  Doing this requires root privilege" "wsprdaemon.service"
   sudo mv ${SYSTEMCTL_UNIT_PATH##*/} ${SYSTEMCTL_UNIT_PATH}    ### 'sudo cat > ${SYSTEMCTL_UNIT_PATH} gave me permission errors
   sudo systemctl daemon-reload
   sudo systemctl enable wsprdaemon.service
   ### sudo systemctl start  kiwiwspr.service       ### Don't start service now, since we are already starting.  Service is setup to run during next reboot/powerup
   echo "Created '${SYSTEMCTL_UNIT_PATH}'."
   echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

function enable_systemctl_daemon() {
    if [[ ! -f ${SYSTEMCTL_UNIT_PATH} ]]; then
        setup_systemctl_daemon
    fi
    sudo systemctl enable wsprdaemon.service
}
function disable_systemctl_daemon() {
    if [[ ! -f ${SYSTEMCTL_UNIT_PATH} ]]; then
        wd_logger 1 "The wsprdaemon service has not been installed."
        return 0
    fi
    sudo systemctl disable wsprdaemon.service
}

##############################################################
function truncate_file() {
    local file_path=$1       ### Must be a text format file
    local file_max_size=$2   ### In bytes
    local file_size=$( ${GET_FILE_SIZE_CMD} ${file_path} )

    [[ $verbosity -ge 3 ]] && echo "$(date): truncate_file() '${file_path}' of size ${file_size} bytes to max size of ${file_max_size} bytes"
    
    if [[ ${file_size} -gt ${file_max_size} ]]; then 
        local file_lines=$( cat ${file_path} | wc -l )
        local truncated_file_lines=$(( ${file_lines} / 2))
        local tmp_file_path="${file_path%.*}.tmp"
        tail -n ${truncated_file_lines} ${file_path} > ${tmp_file_path}
        mv ${tmp_file_path} ${file_path}
        local truncated_file_size=$( ${GET_FILE_SIZE_CMD} ${file_path} )
        [[ $verbosity -ge 1 ]] && echo "$(date): truncate_file() '${file_path}' of original size ${file_size} bytes / ${file_lines} lines now is ${truncated_file_size} bytes"
    fi
}

### Because 'kill' and 'debug increment/decrement' traps are only processed by a program at the end of any currently running program,
### Executing a long sleep command like 'sleep 60' will block processing of 'kill' commands for up to (in that case) 60 seconds
### By using this command, long 'sleep NN' commands are executed as a series of 'sleep 1's and thus traps will be handled within one second
function wd_sleep()
{
    local sleep_for_secs=$1
    local start_secs=${SECONDS}
    local end_secs=$(( start_secs + sleep_for_secs ))

    wd_logger 2 "Starting to sleep for a total of ${sleep_for_secs} seconds"
    while [[ ${SECONDS} -le ${end_secs} ]]; do
        sleep 1
    done
    wd_logger 2 "Finished sleeping"
}

function wd_rm()
{
    local rm_list=($@)

    wd_logger 2 "Delete ${#rm_list[@]} files: ${rm_list[*]}"
    local rm_errors=0
    local rm_file
    for rm_file in ${rm_list[@]}; do
        if [[ ! -f ${rm_file} ]]; then
            wd_logger 1 "ERROR: can't find supplied file ${rm_file}"
        else
            rm ${rm_file}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: failed to 'rm ${rm_file}' requested by function"
                rm_errors=$(( ++rm_errors ))
            fi
        fi
    done
    if [[ ${rm_errors} -gt 0 ]]; then
        wd_logger 1 "ERROR: Encountered ${rm_errors} errors when executing 'rm ${rm_list[*]}'"
    fi
}

################# Daemon management functions ==============================
###
###  Given the path to a *.pid file, returns 0 if file exists and pid number is running and the PID value in the variable named in $1 
function get_pid_from_file(){
    local pid_var_name=$1   ### Where to return the PID found in $2 file
    local pid_file_name=$2
    
    eval ${pid_var_name}=0
    if [[ ! -f ${pid_file_name} ]]; then
        wd_logger 1 "pid file ${pid_file_name} does not exist"
        return 1
    fi
    local pid_val=$(< ${pid_file_name})
    if [[ -z "${pid_val}" ]] || [[ "${pid_val}" -ne "${pid_val}" ]] || [[ "${pid_val}" -eq 0 ]]  2> /dev/null ; then
        wd_logger 1 "pid file ${pid_file_name} contains invalid value '${pid_val}'"
        return 2
    fi
    ps ${pid_val} >& /dev/null
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 2 "Got pid from ${pid_file_name}. ps ${pid_val} => ${ret_code}, so pid isn't running"
        rm ${pid_file_name}
        return 3
    fi
    wd_logger 2 "Got running pid ${pid_val} from ${pid_file_name}"
    eval ${pid_var_name}=${pid_val}
    return 0
}

declare KILL_TIMEOUT_MAX_SECS=${KILL_TIMEOUT_MAX_SECS-10}

function kill_and_wait_for_death() {
    local pid_to_kill=$1

    if ! ps ${pid_to_kill} > /dev/null ; then
        wd_logger 1 "ERROR: pid ${pid_to_kill} is already dead"
        return 1
    fi
    kill ${pid_to_kill}

    local timeout=0
    while [[ ${timeout} < ${KILL_TIMEOUT_MAX_SECS} ]] && ps ${pid_to_kill} > /dev/null ; do
        (( ++timeout ))
        sleep 1
    done
    if ps ${pid_to_kill} > /dev/null; then
         wd_logger 1 "ERROR: timeout after ${timeout} seconds while waiting for pid ${pid_to_kill} is already dead"
        return 1
    fi
    wd_logger 1 "Pid ${pid_to_kill} died after ${timeout} seconds"
    return 0
}

function spawn_daemon() 
{
    local daemon_function_name=$1
    local daemon_root_dir=$2
    mkdir -p ${daemon_root_dir}
    local daemon_log_file_path=${daemon_root_dir}/${daemon_function_name}.log
    local daemon_pid_file_path=${daemon_root_dir}/${daemon_function_name}.pid  

    wd_logger 2 "Start with args '$1' '$2' => daemon_root_dir=${daemon_root_dir}, daemon_function_name=${daemon_function_name}, daemon_log_file_path=${daemon_log_file_path}, daemon_pid_file_path=${daemon_pid_file_path}"
    if [[ -f ${daemon_pid_file_path} ]]; then
        local daemon_pid=$( < ${daemon_pid_file_path})
        if ps ${daemon_pid} > /dev/null ; then
            wd_logger 2 "daemon job for '${daemon_root_dir}' with pid ${daemon_pid} is already running"
            return 0
        else
            wd_logger 1 "found a stale file '${daemon_pid_file_path}' with pid ${daemon_pid}, so deleting it"
            rm -f ${daemon_pid_file_path}
        fi
    fi
    WD_LOGFILE=${daemon_log_file_path} ${daemon_function_name}  ${daemon_root_dir}  > /dev/null &
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to spawn 'WD_LOGFILE=${daemon_log_file_path} ${daemon_function_name}  ${daemon_root_dir}' => ${ret_code}"
        return 1
    fi
    local spawned_pid=$!
    echo ${spawned_pid} > ${daemon_pid_file_path}
    wd_logger -1 "Spawned new ${daemon_function_name} job with PID '${spawned_pid}' and recorded that pid to '${daemon_pid_file_path}' == $(< ${daemon_pid_file_path})"
    return 0
}

function kill_daemon() {
    local daemon_root_dir=$2
    if [[ ! -d ${daemon_root_dir} ]]; then
        wd_logger 2 "ERROR: daemon root dir ${daemon_root_dir} doesn't exist"
        return 1
    fi
    local daemon_function_name=$1
    local daemon_log_file_path=${daemon_root_dir}/${daemon_function_name}.log
    local daemon_pid_file_path=${daemon_root_dir}/${daemon_function_name}.pid  

    wd_logger 2 "Start"
    if [[ ! -f ${daemon_pid_file_path} ]]; then
        wd_logger 2 "ERROR: ${daemon_function_name} pid file ${daemon_pid_file_path} doesn't exist"
        return 2
    else
        local daemon_pid=$( < ${daemon_pid_file_path})
        rm -f ${daemon_pid_file_path}
        if ! ps ${daemon_pid} > /dev/null ; then
            wd_logger 1 "ERROR: ${daemon_function_name} pid file reported pid ${daemon_pid}, but that isn't running"
            return 3
        else
            kill ${daemon_pid}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'kill ${daemon_pid}' failed for active pid ${daemon_pid}"
                return 4
            else
                wd_logger 2 "'kill ${daemon_pid}' was successful"
            fi
        fi
    fi
    return 0
}

function get_status_of_daemon() {
    local daemon_function_name=$1
    local daemon_root_dir=$2
    if [[ ! -d ${daemon_root_dir} ]]; then
        wd_logger 2 "ERROR: daemon root dir ${daemon_root_dir} doesn't exist"
        return 1
    fi
    local daemon_log_file_path=${daemon_root_dir}/${daemon_function_name}.log
    local daemon_pid_file_path=${daemon_root_dir}/${daemon_function_name}.pid  

    wd_logger 3 "Start"
    if [[ ! -f ${daemon_pid_file_path} ]]; then
        wd_logger -1 "$(printf "Daemon '%30s' is not running since it has no pid file '%s'" ${daemon_function_name} ${daemon_pid_file_path})"
        return 2
    else
        local daemon_pid=$( < ${daemon_pid_file_path})
        ps ${daemon_pid} > /dev/null
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then 
            wd_logger -1 "Daemon '${daemon_function_name}' pid file '${daemon_pid_file_path}' reported pid ${daemon_pid}, but that isn't running"
            wd_rm ${daemon_pid_file_path}
            return 3
        else
            wd_logger -1 "$(printf "Daemon '%30s' is     running with pid %6d in '%s'" ${daemon_function_name} ${daemon_pid} ${daemon_root_dir})"
        fi
    fi
    return 0
}

### Given a table of the form:
### 
### declare client_upload_daemon_list=(
###   "upload_to_wsprnet_daemon         ${UPLOADS_WSPRNET_SPOTS_DIR}"
###   "upload_to_wsprdaemon_daemon      ${UPLOADS_WSPRDAEMON_ROOT_DIR}"
### )
function daemons_list_action()
{
    local acton_to_perform=$1        ### 'a', 'z', or 's'
    local -n daemon_list_name=$2     ### This is my first use of a 'namedref'ed'  variable, i.e. this is the name of a array variable to be accessed below, like a pointer in C

    wd_logger 2 "Perform '${acton_to_perform}' on all the ${#daemon_list_name[@]} dameons listed in '${2}'"

    for spawn_line in "${daemon_list_name[@]}"; do
        local daemon_info_list=(${spawn_line})
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_home_directory=${daemon_info_list[1]}
        
        wd_logger 2 "Execute action '${acton_to_perform}' on daemon '${daemon_function_name}' which should run in '${daemon_home_directory}'"
        case ${acton_to_perform} in
            a)
                spawn_daemon ${daemon_function_name} ${daemon_home_directory}
                ;;
            z)
                kill_daemon ${daemon_function_name} ${daemon_home_directory}
                ;;

            s)
                get_status_of_daemon ${daemon_function_name} ${daemon_home_directory}
                ;;
            *)
                wd_logger 1 "ERROR: invalid action '${acton_to_perform}' on daemon '${daemon_function_name}' which should run in '${daemon_home_directory}'"
                ;;
        esac
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 2 "ERROR: Running action '${acton_to_perform}' on daemon '${daemon_function_name}' which should run in '${daemon_home_directory}' => ${ret_code}"
        fi
    done
}
