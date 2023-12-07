#!/bin/bash

### This program records the 64.8 Msps output of a RX888 to a series of one minute long losslessly compressed raw sample files on a USB3 hard disk '/mnt/RX888_samples'

###    Copyright (C) 2023  Robert S. Robinett
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

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

declare -r VERSION="0.1"
declare    VERBOSITY=${VERBOSITY-1}     ### default to level 1

declare -r CMD_NAME=${0##*/}
declare -r CMD_PATH=$(realpath "$0")
declare -r CMD_DIR=$( dirname "${CMD_PATH}")
declare -r CONF_PATH="${CMD_PATH%.sh}.conf"

if [[ ! -f ${CONF_PATH} ]]; then
    echo "ERROR: can't find expected config file ${CONF_PATH}"
    exit 1
fi
exit 0

declare -r CACHE_DIR="${CACHE_DIR-/dev/shm/RX888_recording_cache}"        ### The uncompressed raw files are written here
mkdir -p ${CACHE_DIR}                                        ### /dev/shm always exists, so this should never fail
declare -r ARCHIVE_DIR="${ARCHIVE_DIR-/mnt/RX888_recording_archive}"        ### Those raw files are compressed about 50% by zstd and saved on this hard disk
if [[ ! -d ${ARCHIVE_DIR} ]]; then
    echo "ERROR: the ARCHIVE_DIR '${ARCHIVE_DIR}', which is supposed to be the root of a mounted USB3 hard dish, does not exist"
    exit 1
fi

echo "Raw IQ files will be cached in '${CACHE_DIR}' and flac compressed versions will be saved in '${ARCHIVE_DIR}'"
exit 0

declare -r CMD_DESCRIPTION="RX888 Recording Daemon"
declare -r RX_RECORD_DAEMON_PID_FILE=${CMD_DIR}/rx_record_daemon.pid
declare -r RX_RECORD_DAEMON_LOG_FILE=${CMD_DIR}/rx_record_daemon.log
declare -r RX_COMPRESS_DAEMON_PID_FILE=${CMD_DIR}/rx_compress_daemon.pid
declare -r RX_COMPRESS_DAEMON_LOG_FILE=${CMD_DIR}/rx_compress_daemon.log

###  Manage 
declare    SYSTEMNCTL_UNIT_FILE_NAME=${0##*/}
declare -r SYSTEMNCTL_SERVICE_NAME=${SYSTEMNCTL_UNIT_FILE_NAME%.*}
           SYSTEMNCTL_UNIT_FILE_NAME=${SYSTEMNCTL_SERVICE_NAME}.service
declare -r SYSTEMNCTL_UNIT_DIR=/lib/systemd/system
declare -r SYSTEMNCTL_UNIT_PATH=${SYSTEMNCTL_UNIT_DIR}/${SYSTEMNCTL_UNIT_FILE_NAME}

cat > ${SYSTEMNCTL_UNIT_FILE_NAME} <<EOF
    [Unit]
    Description= ${CMD_DESCRIPTION}
    After=multi-user.target

    [Service]
    User=$(id -u -n)
    Group=$(id -g -n) 
    WorkingDirectory=${CMD_DIR}
    ExecStart=${CMD_PATH} -A
    ExecStop=${CMD_PATH} -z
    Type=forking
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF

function setup_systemctl_deamon() 
{
    if [[ ! -d ${SYSTEMNCTL_UNIT_DIR} ]]; then
        echo "WARNING: this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        if diff ${SYSTEMNCTL_UNIT_FILE_NAME} ${SYSTEMNCTL_UNIT_PATH} ; then
            echo "This service is already setup"
            return 0
        else
            echo "This service template ${SYSTEMNCTL_UNIT_FILE_NAME} differs from the installed service file ${SYSTEMNCTL_UNIT_PATH}, so reinstall it."
        fi
    fi
    sudo cp ${SYSTEMNCTL_UNIT_FILE_NAME} ${SYSTEMNCTL_UNIT_PATH}
    echo "Copied ${SYSTEMNCTL_UNIT_FILE_NAME} to ${SYSTEMNCTL_UNIT_PATH}"

    sudo systemctl daemon-reload
    echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
}

function start_systemctl_daemon()
{
    sudo systemctl start ${SYSTEMNCTL_SERVICE_NAME}
}

function enable_systemctl_deamon() 
{
    setup_systemctl_deamon
    sudo systemctl enable ${SYSTEMNCTL_SERVICE_NAME}
    echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

function disable_systemctl_deamon() 
{
    sudo systemctl stop    ${SYSTEMNCTL_SERVICE_NAME}
    sudo systemctl disable ${SYSTEMNCTL_SERVICE_NAME}
}

function get_systemctl_deamon_status()
{
    setup_systemctl_deamon
    sudo systemctl status ${SYSTEMNCTL_UNIT_FILE_NAME}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        echo "${SYSTEMNCTL_UNIT_FILE_NAME} is enabled"
    else
        echo "${SYSTEMNCTL_UNIT_FILE_NAME} is disabled"
    fi
}

function startup_daemon_control()
{
    local action=${1-h}

    case ${action} in
        h)
            echo "usage: -d [a|i|z|s]     setup to be run at startup of this server using the systemctl service (a=start, i=install and enable, z=disable and stop, s=show status"
            ;;
        a)
            start_systemctl_daemon
            ;;
        i)
            enable_systemctl_deamon
            ;;
        z)
            disable_systemctl_deamon
            ;;
        s)
            get_systemctl_deamon_status
            ;;
        *)
            echo "ERROR: action ${action} is invalid"
            ;;
    esac
}

declare RX_RECORD_POLL_SECS=${RX_RECORD_POLL_SECS-10}
function rx888_record_daemon()
{
    while true; do
        [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): Checking that all Kiwis are running" >> ${RX_RECORD_DAEMON_LOG_FILE} 
        sleep ${RX_RECORD_POLL_SECS}
   done
}

function spawn_rx_record_daemon()
{
    local startup_delay=$1 

    if [[ -f ${RX_RECORD_DAEMON_PID_FILE} ]]; then
        local daemon_pid=$( < ${RX_RECORD_DAEMON_PID_FILE}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "daemon is running with pid = ${daemon_pid}"
            return 0
        else
            echo "daemon pid ${daemon_pid} in ${RX_RECORD_DAEMON_PID_FILE} is not active."
            rm ${RX_RECORD_DAEMON_PID_FILE}
        fi
    fi
    daemon ${startup_delay} &
    local daemon_pid=$!
    echo ${daemon_pid} > ${RX_RECORD_DAEMON_PID_FILE}
    echo "Spawned daemon which has pid ${daemon_pid}"
}

function kill_rx_record_daemon()
{
    if [[ -f ${RX_RECORD_DAEMON_PID_FILE} ]]; then
        local daemon_pid=$( < ${RX_RECORD_DAEMON_PID_FILE}) 
        if ps ${daemon_pid} > /dev/null ; then
            kill ${daemon_pid}
            echo "Killed running daemon which had pid = ${daemon_pid}"
        else
            echo "Found daemon pid ${daemon_pid} in ${RX_RECORD_DAEMON_PID_FILE} is not active."
        fi
        rm ${RX_RECORD_DAEMON_PID_FILE}
    else
        echo "There is no file ${RX_RECORD_DAEMON_PID_FILE}, so daemon was not running"
    fi
}

function status_of_daemon()
{
    if [[ -f ${RX_RECORD_DAEMON_PID_FILE} ]]; then
        local daemon_pid=$( < ${RX_RECORD_DAEMON_PID_FILE}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "daemon is running with pid = ${daemon_pid}"
        else
            echo "Found daemon pid ${daemon_pid} in ${RX_RECORD_DAEMON_PID_FILE} but that pid is not active."
            rm ${RX_RECORD_DAEMON_PID_FILE}
        fi
    else
        echo "There is no file ${RX_RECORD_DAEMON_PID_FILE}, so daemon is not running"
    fi
    check_kiwi_status
}

function usage()
{
    echo "$0 Version ${VERSION}: 
    -a               start daemon which records the 64.8 Msps output of the RX888 to a local HD
    -z               kill that daemon
    -s               show the daemon status
    -h               print this message
}

case ${1--h} in
    -a)
        spawn_rx_record_daemon ${2-0}
        ;;
    -z)
        kill_rx_record_daemon
        ;;
    -s)
        status_of_daemon
        ;;
    -h)
        usage
        ;;
    *)
        echo "ERROR: flag '$1' is not valid"
        usage
        ;;
esac

exit 0
