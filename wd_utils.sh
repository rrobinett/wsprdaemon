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
###   GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

shopt -s -o nounset                               ### bash stops with error if undeclared variable is referenced

declare -i verbosity=${verbosity:-1}              ### default to level 2, but can be overridden on the cmd line.  e.g "v=2 wsprdaemon.sh -V"

export TZ=UTC                                                    ### Log lines use FMT below, but legacy $(date) will printout 12H UTC

declare WD_TIME_FMT=${WD_TIME_FMT-%(%a %d %b %Y %H:%M:%S %Z)T}   ### Used by printf "${WD_TIME}: ..." in lieu of $(date)
declare WD_LOGFILE=${WD_LOGFILE-}                                ### Top level command doesn't log by default since the user needs to get immediate feedback
declare WD_LOGFILE_SIZE_MAX=${WD_LOGFILE_SIZE_MAX-100000}        ### Limit log files to 100 KBytes

lc_numeric=$(locale | sed -n '/LC_NUMERIC/s/.*="*\([^"]*\)"*/\1/p')        ### There must be a better way, but locale sometimes embeds " in it output and this gets rid of them
if [[ "${lc_numeric}" != "POSIX" ]] && [[ "${lc_numeric}" != "en_US" ]] && [[ "${lc_numeric}" != "en_US.UTF-8" ]] && [[ "${lc_numeric}" != "en_GB.UTF-8" ]] && [[ "${lc_numeric}" != "C.UTF-8" ]] ; then
    echo "WARNING:  LC_NUMERIC '${lc_numeric}' on your server is not the expected value 'en_US.UTF-8'."     ### Try to ensure that the numeric frequency comparisons use the format nnnn.nnnn
    echo "          If the spot frequencies reported by your server are not correct, you may need to change the 'locale' of your server"
fi

function wd_logger() {
    local log_at_level=$1
    [[ ${verbosity} -lt ${log_at_level} ]] && return

    local format_string="$2"
    ### printf "${WD_TIME_FMT}: ${FUNCNAME[1]}() passed FORMAT: %s\n" -1 "${format_string}"
    local log_line=$(TZ=UTC printf "${WD_TIME_FMT}: ${FUNCNAME[1]}() ${format_string}"  -1 ${@:3})          ### printf "%(..)T ..." looks at the first -1 argument to signal 'current time'
    [ -t 0 -a -t 1 -a -t 2 ] &&  printf "${log_line}\n"                                              ### use [ -t 0 ...] to test if this is being run from a terminal session 
    if [[ -n "${WD_LOGFILE-}" ]]; then
        [[ ! -f ${WD_LOGFILE} ]] && touch ${WD_LOGFILE}       ### In case it doesn't yet exist
        local logfile_size=$(stat -c %s ${WD_LOGFILE} )
        if [[ ${logfile_size} -ge ${WD_LOGFILE_SIZE_MAX} ]]; then
            local logfile_lines=$(wc -l < ${WD_LOGFILE})
            local logfile_lines_to_trim=$(( logfile_lines / 4 ))       ### Trim off the first 25% of the lines
            printf "${WD_TIME_FMT}: ${FUNCNAME[0]}() logfile '${WD_LOGFILE}' size ${logfile_size} and lines ${logfile_lines} has grown too large, so truncating the first ${logfile_lines_to_trim} lines of it\n" >> ${WD_LOGFILE}
            sed -i "1,${logfile_lines_to_trim} d" ${WD_LOGFILE}
        fi
        printf "${log_line}\n" >> ${WD_LOGFILE}
    else
        true  ### echo "Not logging"
    fi
}

#############################################
function verbosity_increment() {
    verbosity=$(( $verbosity + 1))
    echo "$(date): verbosity_increment() verbosity now = ${verbosity}"
}
function verbosity_decrement() {
    [[ ${verbosity} -gt 0 ]] && verbosity=$(( $verbosity - 1))
    echo "$(date): verbosity_decrement() verbosity now = ${verbosity}"
}

function setup_verbosity_traps() {
    trap verbosity_increment SIGUSR1
    trap verbosity_decrement SIGUSR2
}

function signal_verbosity() {
    local up_down=$1
    local pid_files=$(shopt -s nullglob ; echo *.pid)

    if [[ -z "${pid_files}" ]]; then
        echo "No *.pid files in $PWD"
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
declare -r SYSTEMNCTL_UNIT_PATH=/lib/systemd/system/wsprdaemon.service
function setup_systemctl_deamon() {
    local start_args=${1--a}         ### Defaults to client start/stop args, but '-u a' (run as upload server) will configure with '-u a/z'
    local stop_args=${2--z} 
    local systemctl_dir=${SYSTEMNCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        echo "$(date): setup_systemctl_deamon() WARNING, this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): setup_systemctl_deamon() found this server already has a ${SYSTEMNCTL_UNIT_PATH} file. So leaving it alone."
        return
    fi
    local my_id=$(id -u -n)
    local my_group=$(id -g -n)
    cat > ${SYSTEMNCTL_UNIT_PATH##*/} <<EOF
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
   ask_user_to_install_sw "Configuring this computer to run the watchdog daemon after reboot or power up.  Doing this requires root priviledge" "wsprdaemon.service"
   sudo mv ${SYSTEMNCTL_UNIT_PATH##*/} ${SYSTEMNCTL_UNIT_PATH}    ### 'sudo cat > ${SYSTEMNCTL_UNIT_PATH} gave me permission errors
   sudo systemctl daemon-reload
   sudo systemctl enable wsprdaemon.service
   ### sudo systemctl start  kiwiwspr.service       ### Don't start service now, since we are already starting.  Service is setup to run during next reboot/powerup
   echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
   echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

function enable_systemctl_deamon() {
    sudo systemctl enable wsprdaemon.service
}
function disable_systemctl_deamon() {
    sudo systemctl disable wsprdaemon.service
}


