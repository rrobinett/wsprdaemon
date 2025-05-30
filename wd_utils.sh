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

### This ensures that 'bc's floating point calculations of spot frequencies give those numbers in a known format irrespective of the LOCALE environment of the host computer
export LC_ALL="C"

### This gets called when there is a system error and helps me find those lines DOESN'T WORK - TODO: debug
trap 'rc=$?; echo "Error code ${rc} at line ${LINENO} in file ${BASH_SOURCE[0]} line #${BASH_LINENO[0]}"' ERR

###  Returns 0 if arg is an unsigned integer, else 1
function is_uint() { case $1        in '' | *[!0-9]*              ) return 1;; esac ;}
function is_positive_integer()
{
    local test_value="$1"
    if [[ "$test_value" =~ ^[1-9][0-9]*$ ]]; then
        return 0
    else
        return 1
    fi
}


###
function wd_logger_flush_all_logs {
    wd_logger 2 "Flushing .log files"

    local restart_line=$(TZ=UTC printf "\n\n=============== ${WD_TIME_FMT}: ERROR: start ================\n\n" -1)
    local log_file
    for log_file in $(find ${WSPRDAEMON_TMP_DIR} ${WSPRDAEMON_ROOT_DIR} -type f -name '*.log'); do
        if [[ -s ${log_file} ]]; then
            if grep -q "UTC: " ${log_file} > /dev/null ; then
                ### Only add seperator to log files which already have wd_logger() lines in them
                truncate_file ${log_file} ${WD_LOGFILE_SIZE_MAX}
                echo "${restart_line}" >> ${log_file}
            fi
        fi
    done
}

declare WD_LOGGING_EXCLUDE_LOG_FILENAMES="add_derived.log curl.log kiwi_recorder.log kiwi_recorder_overloads_count/n .log merged.log"
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
            wd_logger 2 "Log file ${log_file_path} is empty"
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
                if ! grep -F -q "${last_printed_line}" ${log_file_path} ; then
                    wd_logger 2 "Can't find that the line '${last_printed_line}' in ${log_file_last_printed} is in ${log_file_path}"
                    wd_rm ${log_file_last_printed}
                    cp ${log_file_path} ${new_log_lines_file}
                else
                    wd_logger 2 "Found line in ${log_file_last_printed} file is present in ${log_file_path}, so print only the lines which follow it"
                    grep -F -A 100000 "${last_printed_line}" ${log_file_path}  | tail -1 > ${new_log_lines_file}
                    if [[ ! -s ${new_log_lines_file} ]]; then
                        wd_logger 2 "Found no lines to print in ${log_file_path}, so nothing to print"
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
            grep -F -A 100000 "ERROR:" ${new_log_lines_file} > ${new_error_log_lines_file}
            if [[ ! -s ${new_error_log_lines_file} ]]; then
                local new_log_lines_count=$( wc -l < ${new_log_lines_file} )
                wd_logger 2 "$( printf "Found no 'ERROR:' lines in the %'6d new log lines of '${log_file_path}', so remember the last line of current log file '${log_file_last_printed} " ${new_log_lines_count})" 
                tail -n 1 ${log_file_path} > ${log_file_last_printed}
                continue
            else
                if  grep -F "ERROR: start =======" > /dev/null ${new_error_log_lines_file}; then
                    wd_logger 2 "Ignore ERROR line logged at startup of WD"
                else
                    wd_logger 1 "\nFound $( grep -F "ERROR:" ${new_error_log_lines_file} | wc -l ) new 'ERROR:' lines in ${log_file_path} among its $( wc -l < ${new_log_lines_file}) new log lines."
                    grep -F "ERROR:" ${new_error_log_lines_file} | head -n 1
                    read -p "That is the first ERROR: line. Press <ENTER> to check the next log file or 'l' to 'less all the new lines after that new ERROR line ${new_error_log_lines_file} => "
                    if [[ -n "${REPLY}" ]]; then
                        less ${new_error_log_lines_file}
                    fi
                fi
                 tail -n 1 ${log_file_path} > ${log_file_last_printed}       ### Start next search for new ERROR lines after the last line we have just searched
                continue
            fi
        fi
        
        if [[ -z "${new_log_lines}" ]]; then
            wd_logger 2 "There are no lines or no new lines in ${log_file_path} to print"
        else
            local new_log_lines_count=$( echo "${new_error_log_lines}" | wc -l  )
            wd_logger 1 "There are ${new_log_lines_count} new lines to print"
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
    if (( $# != 2 )); then
        local prefix_str=$(TZ=UTC printf "${WD_TIME_FMT}: ${FUNCNAME[1]}()")
        local bad_args="$@"
        echo "${prefix_str} called from function ${FUNCNAME[1]} in file ${BASH_SOURCE[1]} line #${BASH_LINENO[0]} with bad number of arguments: '${bad_args}'"
        return 1
    fi
    local log_at_level=$1
    local printout_string=$2

    local print_time_and_calling_function_name="yes"
    if (( log_at_level < 0 )); then
        print_time_and_calling_function_name="no"
        log_at_level=$((- log_at_level )) 
    fi
    (( verbosity < log_at_level )) && return 0

    ### printf "${WD_TIME_FMT}: ${FUNCNAME[1]}() passed FORMAT: %s\n" -1 "${format_string}"
    local time_and_calling_function_name=""
    if [[ ${print_time_and_calling_function_name} == "yes" ]]; then
        time_and_calling_function_name=$(TZ=UTC printf "${WD_TIME_FMT}: ${FUNCNAME[1]}() "  -1)          ### printf "%(..)T ..." looks at the first -1 argument to signal 'current time'
    fi
    local printout_line="${time_and_calling_function_name}${printout_string}"

    if [[ "${TERM}" = "screen" ]] || [ -t 0 -a -t 1 -a -t 2 ]; then
        ### This program is not a daemon, it is running in a tmux window or attached to a terminal.  So echo to that terminal
        echo -e "${printout_line}"                                              ### use [ -t 0 ...] to test if this is being run from a terminal session
    fi

    if [[ -z "${WD_LOGFILE-}" ]]; then
        ### No WD_LOGFILE has been defined, so nothing more to do
        return 0
    fi

    ### WD_LOGFILE is defined, so truncate if it has grown too large, then append the new log line(s)
    if [[ ! -f $WD_LOGFILE ]] ; then
        local rc
        local log_file_path
        log_file_path=$(realpath  $WD_LOGFILE )
        rc=$? ; if (( rc )) ; then
            local log_file_dir="${WD_LOGFILE%/*}"
            echo "$(TZ=UTC date): wd_logger(): ERROR: 'realpath  $WD_LOGFILE' => $rc, so 'mkdir -p $log_file_dir'" 1>&2   ### Send this message to stderr
            mkdir -p $log_file_dir
            echo "$(TZ=UTC date): wd_logger(): ERROR: had to create $log_file_dir" >  $WD_LOGFILE
        else
            echo "$(TZ=UTC date): wd_logger(): creating new $log_file_path" >  $WD_LOGFILE
        fi
    fi

    local logfile_size=$( ${GET_FILE_SIZE_CMD} $WD_LOGFILE )
    if (( logfile_size > WD_LOGFILE_SIZE_MAX )); then
        local logfile_lines=$(wc -l < $WD_LOGFILE )
        local logfile_lines_to_trim=$(( logfile_lines / 4 ))       ### Trim off the first 25% of the lines
        printf "$WD_TIME_FMT: ${FUNCNAME[0]}() logfile '$WD_LOGFILE' size $logfile_size and lines $logfile_lines has grown too large, so truncating the first $logfile_lines_to_trim lines of it\n" >> $WD_LOGFILE
        sed -i "1,$logfile_lines_to_trim d" $WD_LOGFILE
    fi
    echo -e "$printout_line" >> $WD_LOGFILE
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
declare -r SYSTEMCTL_UNIT_PATH=/etc/systemd/system/wsprdaemon.service

function systemctl_is_setup() {
    wd_logger 2 "Checking auto-start configuration"

    local systemctl_dir=${SYSTEMCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        wd_logger 1 "ERROR: this server appears to not be configured to use the 'systemctl' service needed for auto-start"
        return 1
    fi
    if [[ ! -f ${SYSTEMCTL_UNIT_PATH} ]]; then
         wd_logger 1 "This server has not been set up to auto-start wsprdaemon at powerup or reboot"
         return 1
    fi
    if ! grep -q "Restart=always" ${SYSTEMCTL_UNIT_PATH} || ! grep -q "RestartSec=10" ${SYSTEMCTL_UNIT_PATH} ; then
         wd_logger 1 "The ${SYSTEMCTL_UNIT_PATH} file is missing 'Restart=always' and/or 'RestartSec=10', so recreate that service file"
         wd_rm ${SYSTEMCTL_UNIT_PATH}
         return 1
    fi
     wd_logger 2 "This server already has a correctly configured ${SYSTEMCTL_UNIT_PATH} file. So leaving the configuration alone."
     if sudo systemctl is-enabled wsprdaemon.service > /dev/null ; then
         wd_logger 2 "The WD service is correctly configured and enabled"
         return 0
     fi
     wd_logger 1 "The WD service was configured but not enabled, so enable it"
     if sudo systemctl enabled wsprdaemon.service ; then
         wd_logger 1 "The WD service has been enabled"
         return 0
     fi
     wd_logger 1 "ERROR: failed to enable the WD service, so deleting the service file"
     wd_rm ${SYSTEMCTL_UNIT_PATH}
     return 1
}

### Called by wd_setup.sh each time WD is executed
function check_systemctl_is_setup() {
    local rc

    wd_logger 2 "Starting"
    if systemctl_is_setup; then
       wd_logger 2 "WD is setup to auto-start at powerup and reboot"
       return 0
    fi
    wd_logger 1 "WD needs to be setup to auto-start at powerup and reboot"
    setup_systemctl_daemon
    rc=$? ; if (( rc )); then
       wd_logger 1 "ERROR: failed to setup WD to auto-start"
       return 1
    fi
    wd_logger 1 "WD is now setup to auto-start"
    return 0
}


function setup_systemctl_daemon() {
    local start_args=${1--A}         ### Defaults to client start/stop args, but '-u a' (run as upload server) will configure with '-u a/z'
    local stop_args=${2--Z} 

    if systemctl_is_setup ; then
        wd_logger 1 "The WD service is setup and enabled"
        return 0
    fi
    if [[ -f ${SYSTEMCTL_UNIT_PATH} ]]; then
        if grep -q "Restart=always" ${SYSTEMCTL_UNIT_PATH}  &&  grep -q "RestartSec=10" ${SYSTEMCTL_UNIT_PATH} ; then
            wd_logger 1 "This server already has a correctly configured ${SYSTEMCTL_UNIT_PATH} file. So leaving the configuration alone."
            if ! sudo systemctl is-enabled wsprdaemon.service ; then
                wd_logger 1 "The WD service was configured but not enabled, so enabled it"
                if sudo systemctl enabled wsprdaemon.service ; then
                    wd_logger 1 "The WD service has been enabled"
                    return 0
                fi
                wd_logger 1 "ERROR: failed to enable the WD service, so re-install it"
            fi
        fi
         wd_logger 1 "The ${SYSTEMCTL_UNIT_PATH} file is missing 'Restart=always' and/or 'RestartSec=10', so recreate that service file"
         wd_rm ${SYSTEMCTL_UNIT_PATH}
    fi
    if [[ ! $(groups) =~ radio ]]; then
        sudo adduser --quiet --system --group radio
        sudo usermod -aG radio ${USER}
        wd_logger 1 "Added ${USER} to the group radio"
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
    SupplementaryGroups=radio
    WorkingDirectory=${WSPRDAEMON_ROOT_DIR}
    ExecStart=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.sh ${start_args}
    ExecStop=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.sh ${stop_args}
    Type=forking
    Restart=always
    RestartSec=10

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

### These are executed from the cmd line
function stop_systemctl_daemon() {
    sudo systemctl stop wsprdaemon.service >& /dev/null
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
        wd_logger 1 "wsprdaemon.servicd has been stopped"
    else
        wd_logger 1 "stop wsprdaemon.service => ${rc}"
    fi
    return 0
}

function start_systemctl_daemon() {
    if [[ ! -f ${SYSTEMCTL_UNIT_PATH} ]]; then
        wd_logger 1 "Creating and enabling ${SYSTEMCTL_UNIT_PATH}"
        setup_systemctl_daemon
    fi

    local rc
    sudo systemctl is-enabled wsprdaemon.service >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "wsprdaemon.service is not enabled, so enabled it"
        sudo systemctl enable wsprdaemon.service
    fi
    sudo systemctl start wsprdaemon.service >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "wsprdaemon.service is already running, so nothing to do"
    else
        wd_logger 1 "wsprdaemon.service is not running, so start the watchdog daemon"
        sudo systemctl enable wsprdaemon.service
    fi
    return 0
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
            rm ${rm_file} >& /dev/null
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: failed to 'rm ${rm_file}' requested by function"
                rm_errors=$(( ++rm_errors ))
            fi
        fi
    done
    if [[ ${rm_errors} -gt 0 ]]; then
        wd_logger 1 "ERROR: When called by ${FUNCNAME[0]}, encountered ${rm_errors} errors when executing 'rm ${rm_list[*]}'"
    fi
}

### Returns a list of PIDs in bottom up order
function wd_list_decendant_pids() {
  local children=$(ps -o pid= --ppid "$1")

  if [[  -z "${children}" ]]; then
      return
  fi

  for pid in ${children}; do
     wd_list_decendant_pids "${pid}"
  done
  echo "${children}"
}

function wd_list_parent_and_decenddant_pids() {
    local root_pid_to_be_killed=$1
    local top_down_pids_list=( $(wd_list_decendant_pids ${root_pid_to_be_killed}) )
    echo ${root_pid_to_be_killed} ${top_down_pids_list[@]}
}

function wd_kill_pid_and_its_decendants() {
    local pid_list=( $( wd_list_parent_and_decenddant_pids $1 ) )
    local save_rc=0
    local rc=0

    wd_logger 2 "Killing pid $1 and all of its decendents: '${pid_list[*]}'"

    local pid_to_kill
    for pid_to_kill in ${pid_list[@]} ; do
        wd_logger 2 "Killing pid ${pid_to_kill}"
        kill ${pid_to_kill} >& /dev/null
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 2 "INFO: 'kill ${pid_to_kill}' => ${rc}, but this frequently occurs when a process is executing a 'sleep'"
            save_rc=${rc}
        fi
    done
    if [[ ${save_rc} -ne 0 ]]; then
        wd_logger 2 "INFO: one or more 'kill ...' commands failed"
    fi
    wd_logger 2 "Killed ${#pid_list[@]} pids: ${pid_list[*]}"
    return 0
}

function wd_kill()
{
    local kill_pid_list=($@)

    wd_logger 2 "Kill pid(s):  '${kill_pid_list[*]}'"

    if [[ ${#kill_pid_list[@]} -eq 0 ]]; then
        wd_logger 1 "ERROR: no pid(s) were supplied"
        return 1
    fi
    local not_running_errors=0
    local kill_errors=0
    local kill_pid
    for kill_pid in ${kill_pid_list[@]}; do
        if ! ps ${kill_pid} > /dev/null ; then
            wd_logger 2 "ERROR: pid ${kill_pid} is not running"
            (( ++not_running_errors ))
        else
            wd_logger 2 "Killing pid ${kill_pid}"
            wd_kill_pid_and_its_decendants  ${kill_pid}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'wd_kill_pid_and_its_decendants  ${kill_pid}' => ${rc}"
                (( ++kill_errors ))
            fi
        fi
    done
    if [[ ${kill_errors} -ne 0 ]]; then
        ### I wouldn't expect any 'kill to fail'
        wd_logger 1 "ERROR: When called by ${FUNCNAME[0]} got kill_errors=${kill_errors}"
    fi
    if [[ ${not_running_errors} -ne 0 ]]; then
        ### Since we now kill all children, it is common for there to pids not running 
        wd_logger 2 "INFO When called by ${FUNCNAME[0]} got not_running_errors=${not_running_errors}"
        return 2
    fi
    return 0
}

function wd_kill_all()
{
    local rc
    local rc1

    wd_logger 2 "Force kill all WD programs"

    local pid_file_list=( $(find ${WSPRDAEMON_TMP_DIR} ${WSPRDAEMON_ROOT_DIR} -name '*.pid') )
    if [[ ${#pid_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no pid files"
    else 
        wd_logger 2 "Found ${#pid_file_list[@]} pid files: '${pid_file_list[*]}'"

        local pid_file
        for pid_file in ${pid_file_list[@]}; do
            local pid_val=$(< ${pid_file})
            wd_logger 2 "Killing PID ${pid_val} found in  pid file '${pid_file}'"
            # read -p "Kill pid ${pid_val} found in  pid file '${pid_file}'? => "
            wd_kill ${pid_val}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                ### This commonly occurs for wav_recording_daemon.pid files, they are children of an already killed decoding_daemon
                wd_logger 2 "INFO: failed to kill PID ${pid_val} found in pid file '${pid_file}'"
            fi
            wd_rm ${pid_file}
            rc1=$?
            if [[ ${rc1} -ne 0 ]]; then
                ### This commonly occurs for wav_recording_daemon.pid files, they are children of an already killed decoding_daemon
                wd_logger 2 "INFO: failed to rm '${pid_file}'"
            fi
        done
   fi
   #read -p "Done killing all pids from PID files. Proceed to search for and kill zombies? => "

    ps aux > ps.log            ### Don't pipe the output.  That creates mutlilple addtional bash programs which are really zombies
    grep "${WSPRDAEMON_ROOT_PATH}\|${KIWI_RECORD_COMMAND}" ps.log | grep -v $$ > grep.log         
    local zombie_pid_list=( $(awk '{print $2}'  grep.log) )

    if [[ ${#zombie_pid_list[@]} -ne 0 ]]; then
        wd_logger 1 "ERROR: Killing ${#zombie_pid_list[@]} zombie pids '${zombie_pid_list[*]}'"
        wd_kill ${zombie_pid_list[@]}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: for zombie pids 'kill ${zombie_pid_list[*]}' => ${rc}"
        fi
    fi

    active_decoding_cpus_init            ### zero the file which keeps the count of active decode jobs

    echo "RUNNING_JOBS=()" > ${RUNNING_JOBS_FILE}
    return 0
}


###  Given the path to a *.pid file, returns 0 if file exists and pid number is running and the PID value in the variable named in $1 
function get_pid_from_file()
{
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

function wd_kill_and_wait_for_death() 
{
    local pid_to_kill=$1

    if ! ps ${pid_to_kill} > /dev/null ; then
        wd_logger 1 "ERROR: pid ${pid_to_kill} is already dead"
        return 1
    fi
    local timeout=0

    while [[ ${timeout} -lt ${KILL_TIMEOUT_MAX_SECS} ]]; do
        wd_kill ${pid_to_kill}
        local rc=$?
        if [[ ${rc} -eq 0 ]]; then
            wd_logger 1 "Killed after ${timeout} seconds"
            return 0
        fi
        (( ++timeout ))
    done
    wd_logger 1 "ERROR: timeout after ${timeout} seconds  trying to kill ${pid_to_kill}"
    return 2
}

function wd_kill_pid_file()
{
    local local recording_pid_file=$1
    local recording_pid

    get_pid_from_file recording_pid ${recording_pid_file}
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 3 "ERROR: 'get_pid_from_file recording_pid ${recording_pid_file}' => ${rc}"
    fi

    wd_rm ${recording_pid_file}
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 3 "ERROR: 'wd_rm ${recording_pid_file}' => ${rc}"
    fi

    wd_kill_and_wait_for_death ${recording_pid}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'wd_kill ${recording_pid}' => $?"
        return 4
    fi
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
        if $(is_positive_integer "$daemon_pid" ) && ps ${daemon_pid} > /dev/null ; then
            wd_logger 2 "daemon job for '${daemon_root_dir}' with pid ${daemon_pid} is already running"
            return 0
        else
            wd_logger 1 "Found a stale pid file '${daemon_pid_file_path}' which contains '${daemon_pid}', so deleting it"
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
        wd_rm ${daemon_pid_file_path}
        if ! ps ${daemon_pid} > /dev/null ; then
            wd_logger 1 "ERROR: ${daemon_function_name} pid file reported pid ${daemon_pid}, but that isn't running"
            return 3
        else
            wd_kill ${daemon_pid}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'wd_kill ${daemon_pid}' => ${ret_code} == failed to kill an active pid ${daemon_pid}"
                return 4
            else
                wd_logger 2 "'wd_kill ${daemon_pid}' was successful"
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
        if [[ -z "${daemon_pid}" ]]; then
            wd_logger -1 "Daemon '${daemon_function_name}' pid file '${daemon_pid_file_path}' exists, but it is empty"
            return 3
        fi
        if ! is_uint "${daemon_pid}"; then
            wd_logger -1 "Daemon '${daemon_function_name}' pid file '${daemon_pid_file_path}' exists, but the text in it '${daemon_pid}' is not a valid PID"
            return 4
        fi
        ps ${daemon_pid} > /dev/null
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then 
            wd_logger -1 "Daemon '${daemon_function_name}' pid file '${daemon_pid_file_path}' reported pid ${daemon_pid}, but that isn't running"
            wd_rm ${daemon_pid_file_path}
            return 3
        else
            wd_logger -1 "$(printf "Daemon '%30s' is running with pid %6d in '%s'" ${daemon_function_name} ${daemon_pid} ${daemon_root_dir})"
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

    wd_logger 2 "Perform '${acton_to_perform}' on all the ${#daemon_list_name[@]} daemons listed in '${2}'"

    for spawn_line in "${daemon_list_name[@]}"; do
        local daemon_info_list=(${spawn_line})
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_home_directory=${daemon_info_list[1]}
        
        wd_logger 2 "Execute action '${acton_to_perform}' on daemon '${daemon_function_name}' which should run in '${daemon_home_directory}'"
        case ${acton_to_perform} in
            a|start)
                spawn_daemon ${daemon_function_name} ${daemon_home_directory}
                ;;
            z|stop)
                kill_daemon ${daemon_function_name} ${daemon_home_directory}
                ;;

            s|status)
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

### Get the current value of a variable stored in a file without perturbing any currently defined variables in the calling function
### To minimize the possibility of 'sourcing' an already declared r/o global variable, extract the line with the variable we are searching for
### into a tmp file, and then source only that tmp file
function get_file_variable()
{
    local __return_variable=$1
    local _variable_name=$2
    local source_file=$3

    local get_file_variable_tmp_file=${WSPRDAEMON_TMP_DIR}/get_file_variable.txt
    grep "${_variable_name}=" ${source_file} > ${get_file_variable_tmp_file}
    local value_in_file=$( shopt -u -o nounset; source ${get_file_variable_tmp_file}; eval echo \${${_variable_name}} )

    eval ${__return_variable}=\${value_in_file}
}

################################################################################################################################################################
declare MUTEX_DEFAULT_TIMEOUT=${MUTEX_DEFAULT_TIMEOUT-5}   ### How many seconds to wait to create lock before returning an error.  Defaults to 5 seconds
declare MUTEX_MAX_AGE=${MUTEX_MAX_AGE-30}                  ### If can't get lock and the lock is older than this, then flush the lock directory.  Defaults to 30 seconds

function wd_mutex_lock() {
    local mutex_name=$1
    local mutex_dir=$2                                          ### Directory in which to create lock
    local mutex_timeout_count=${3-${MUTEX_DEFAULT_TIMEOUT}}     ### How many seconds to wait to get mutex,  Defaults to 5 seconds

    if [[ ! -d ${mutex_dir} ]]; then
        wd_logger 1 "ERROR: directory '${mutex_dir}' for muxtex doesn't exist"
        return 1
    fi

    local mutex_lock_dir_name="${mutex_dir}/${mutex_name}-mutex.lock"         ### The lock directory
    wd_logger 2 "Trying to lock '${mutex_name}' by executing 'mkdir ${mutex_lock_dir_name}'"
    local mkdir_try_count=1
    while ! mkdir ${mutex_lock_dir_name} 2> /dev/null; do
        ((++mkdir_try_count))
        if [[ ${mkdir_try_count} -ge ${mutex_timeout_count} ]]; then
            wd_logger 1 "ERROR: timeout waiting to lock ${mutex_name} after ${mkdir_try_count} tries"
            return 1
        fi
        local sleep_secs
        sleep_secs=$(( ( ${RANDOM} % ${mutex_timeout_count} ) + 1 ))      ### randomize the sleep time or all the sessions will hang while wating for the lock to free
        wd_logger 1 "Try  #${mkdir_try_count} of 'mkdir ${mutex_lock_dir_name}' failed.  Sleep ${sleep_secs}  and retry"
        wd_sleep ${sleep_secs}
    done
    wd_logger 2 "Locked access to ${mutex_name} after ${mkdir_try_count} tries"
    return 0
}

function wd_mutex_unlock() {
    local mutex_name=$1
    local mutex_dir=$2                                          ### Directory in which to create lock

    wd_logger 2 "Unock mutex '${mutex_name}' in directory '${mutex_dir}'"
    if [[ ! -d ${mutex_dir} ]]; then
        wd_logger 1 "ERROR: directory '${mutex_dir}' containing the muxtex '${mutex_name}' doesn't exist"
        return 1
    fi

    local mutex_lock_dir_name="${mutex_dir}/${mutex_name}-mutex.lock"         ### The lock directory
    if [[ ! -d ${mutex_lock_dir_name} ]]; then
        wd_logger 1 "ERROR: the expected mutex directory '${mutex_dir}' doesn't exist"
        return 1
    fi
    rmdir ${mutex_lock_dir_name}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'rmdir ${mutex_lock_dir_name}' => ${rc}"
        return 1
    fi
    wd_logger 2 "Unlocked ${mutex_lock_dir_name}"
    return 0
}

function create_tmpfs() {
    local mount_point=$1
    local tmpfs_size=$2

    local rc
    if [[ ! -d ${mount_point} ]]; then
        umask 022
        sudo mkdir -p ${mount_point}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: can't create directory for tmpfs mount point '${mount_point}'"
            return ${rc}
        fi
        wd_logger 1 "Created new ${mount_point}"
        sudo chown ${USER}:$(id -gn)  ${mount_point}
        sudo chmod 777 ${mount_point}
    fi
    if ! mountpoint -q ${mount_point} ; then
        sudo mount -t tmpfs -o size=${tmpfs_size} tmpfs ${mount_point}
    fi
    return 0
}

function  wd_ip_is_valid() {
   local ip_port="${1}"   ### Strip spaces

    if [[ -z "${ip_port}" ]]; then
        wd_logger 1 "ERROR: given empty ip_port argument"
        return 1
    fi

    if [[ "${ip_port}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$ ]]; then
        # Split IP and PORT
        local arg_ip="${ip_port%:*}"
        local arg_port="${ip_port##*:}"

        # Check IP address validity
        if [[ $(echo "${arg_ip}" | awk -F. '$1<=255 && $2<=255 && $3<=255 && $4<=255') ]]; then
            # Check Port validity (1-65535)
            if [[ "${arg_port}" -ge 1 && "${arg_port}" -le 65535 ]]; then
                wd_logger 2  "Got valid IP:PORT ${ip_port}"
                return 0
            else
                wd_logger 1  "ERROR: Got invalid port '${arg_port}' in IP:PORT ${ip_port}"
                return 2
            fi
        else
            wd_logger 1  "ERROR: Got invalid IP '${arg_ip}' in IP:PORT ${ip_port}"
            return 3
        fi
    else
        wd_logger 1  "ERROR: Got invalid IP in IP:PORT ${ip_port}"
        return 4
    fi
    wd_logger 1 "ERROR: this line should never be executed"
    return 5
}

### Given the path to an ini file like /etc/radio/radiod@rx888-wsprdemon.conf, ~/bin/frpc_wd.ini or /etc/systemd/system/wsprdaemon.service
### This function searches for a variable in a section and:
### returns 0: if no changes were made
### returns 1: 1)  If the variable isn't found and '$variable=$value' was added to the $section
###            2)  If the variable is found but it was changed to '$variable=$value'
###            3) As a special case, if variable = '#', then remarks out the line with a '#' as the first character of the line
### returns 2: If there is a bug in the function, since it should always return 0 or 1
### Mostly created by chatgbt
#
function update_ini_file_section_variable() {
    local file="$1"          ### The ini file to be verified or modified if needed
    local section="$2"       ### The section which contains the variable of interest
    local variable="$3"      ### The variable which is to be verified or modified
    local new_value="$4"     ### The desired value of that variable
    local rc=0

    if [[ ! -f "${file}" ]]; then
        wd_logger 1 "ERROR: ini file '$file' does not exist"
        return 3
    fi

    ### 4/28/25 RR - fix bad WWVB freq value I introduced in the radiod@..conf template file
    if grep -q  '^ *freq *= *"60000 ' "$file" ; then
        wd_logger 1 "Fixing bad WWVB 'freq = \"60000' in $file"
        sed -i 's/\(^ *freq *= "\)60000 /\160k000 /' "$file"
    fi

    # Escape special characters in section and variable for use in regex
    local section_esc=$(printf "%s\n" "$section" | sed 's/[][\/.^$*]/\\&/g')
    local variable_esc=$(printf "%s\n" "$variable" | sed 's/[][\/.^$*]/\\&/g')

    wd_logger 2 "In ini file $file edit or add variable $variable_esc in section $section_esc to have the value $new_value"

    # Check if section exists
    if ! grep -q "^\s*\[$section_esc\]" "$file"; then
        # Add section if it doesn't exist
        wd_logger 1 "ERROR: expected section [$section] doesn't exist in '$file'"
        return 4
    fi

    # Find section start and end lines
    local section_start_line_number=$(grep -n "^\s*\[$section_esc\]" "$file" | cut -d: -f1 | head -n1)
    local section_end_line_number=$(awk -v start=$section_start_line_number 'NR > start && /^\[.*\]/ {print NR-1; exit}' "$file")

    # If no next section is found, set section_end_line_number to end of file
    [[ -z "$section_end_line_number" ]] && section_end_line_number=$(wc -l < "$file")

    # Check if variable exists within the section
    if sed -n "${section_start_line_number},${section_end_line_number}p" "$file" | grep -q "^\s*$variable_esc\s*="; then
        ### The variable is defined.  See if it needs to be changed
        local temp_file="/tmp/${file##*/}.tmp"

        if [[ "$new_value" == "#" ]]; then
            wd_logger 1 "Remarking out one or more active '$variable_esc = ' lines in section [$section]"
            sed "${section_start_line_number},${section_end_line_number}s|^\(\s*$variable_esc\s*=\s*.*\)|# \1|" "$file" > "$temp_file"
        else
            ### We are validating and/or modifying a variable
            if [[ "$section" == "rx888" && "$variable_esc" == "description" ]]; then
                wd_logger 2 "Checking that $file section [$section] variable 'description' isn't longer than 63 characters and doesn't contain '/'"
                local description_line=$(sed -n "${section_start_line_number},${section_end_line_number}p" "$file" | grep "^ *description")
                if [[ -z "$description_line" ]]; then
                    wd_logger 1 "ERROR: Can't find expected 'description line in $file section [$section]"
                    exit 1
                else
                    wd_logger 2 "Found expected description line in $file section [$section]: '$description_line'"
                    local description_string=$(echo "$description_line" | sed 's/^ *[^=]*= *"//; s/".*//' )
                    if [[ -z "$description_string" ]]; then
                        wd_logger 1 "ERROR: Can't find expected 'description field in description line: '$description_line'"
                    else
                        local description_string_chars=$(echo  "$description_string" | wc -c )
                        if (( description_string_chars > ${RADIO_MAX_DESCRIPTION_CHARS-63} )); then
                            wd_logger 1 "ERROR: The rx888 decription string in $file is longer than the allowed 63 characters, so edit that file and shorten it"
                            exit 1
                        fi
                        if [[ "$description_string" =~ "/" ]]; then
                            wd_logger 1 "ERROR: The rx888 decription string in $file contains the disallowed character '/', so edit that file and remove it"
                            exit 1
                        fi
                    fi
                fi
                wd_logger 2 "Found a valid description string '$description_string' in $file section [$section]"
                return 0
            fi
            wd_logger 2 "Maybe changing one or more active '$variable_esc = ' lines in section [$section] to $new_value"
            sed  "${section_start_line_number},${section_end_line_number}s|^\(\s*$variable_esc\)\s*=\s*.*|\1=$new_value|" "$file" > "$temp_file"
        fi
        if ! diff "$file" "$temp_file" > diff.log; then
            wd_logger 1 "Changing section [$section] of $file:\n$(<diff.log)"
            sudo mv "${temp_file}"  "$file"
            return 1
        else
            rm "${temp_file}"
            wd_logger 2 "Existing $variable_esc in section $section_esc already has the value $new_value, so nothing to do"
            return 0
        fi
    else
        # The variable isn't defined in the section, so insert it into the section
         if [[ "$new_value" == "#" ]]; then
            wd_logger 2 "Can't find an active '$variable_esc = ' line in section $section_esc, so there is no line to remark out with new_value='$new_value'"
            return 0
        else
            local temp_file="/tmp/${file##*/}"
            wd_logger 1 "variable '$variable_esc' was not in section [$section_esc] of file $file, so inserting the line '$variable=$new_value' by using ${temp_file}"
            sed "${section_start_line_number}a\\$variable=$new_value" "${file}" > ${temp_file}
            sudo mv ${temp_file} ${file}         ### The /etc/systemd/system/ dirctory is owned by root
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: 'mv ${temp_file} ${file}' => ${rc}"
            fi
            return 1
         fi
    fi
    ### Code should never get here
    return 2
}
