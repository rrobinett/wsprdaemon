#!/bin/bash

###  grape-uploader.sh:  wakes up at every UTC 00:05, creates and uploads Digial RF files of the last 24 hours of WWV IQ recordings

###    Copyright (C) 2024  Robert S. Robinett
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

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

declare -r VERSION=0.1
declare    VERBOSITY=${VERBOSITY-2}     ### default to level 1
declare -r CMD_NAME=${0##*/}
declare -r CMD_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r CMD_PATH="${CMD_DIR}/${CMD_NAME}"
declare -r CMD_DESCRIPTION="GRAPE WWV IQ uploader"

###  Manage 
declare -r KIWI_STARTUP_DELAY_SECONDS=60   ### When starting the Pi wait this long before checking the Kiwis which may be powering up at the same time.
declare    SYSTEMNCTL_UNIT_FILE_NAME=${0##*/}
declare -r SYSTEMNCTL_SERVICE_NAME=${SYSTEMNCTL_UNIT_FILE_NAME%.*}
           SYSTEMNCTL_UNIT_FILE_NAME=${SYSTEMNCTL_SERVICE_NAME}.service
declare -r SYSTEMNCTL_UNIT_DIR=/lib/systemd/system
declare -r SYSTEMNCTL_UNIT_PATH=${SYSTEMNCTL_UNIT_DIR}/${SYSTEMNCTL_UNIT_FILE_NAME}

function create_service_file() {
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
    }

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

########################################
function daemon()
{
    local startup_delay=${1-0}

    if [[ ${startup_delay} -eq 0 ]]; then
        echo "$(date): daemon() is starting" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
    else
        echo "$(date): daemon() will start after a delay of ${startup_delay} seconds" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
        sleep ${startup_delay}
        echo "$(date): daemon() now starting after a delay of ${startup_delay} seconds" | tee -a ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
    fi

    while true; do
        [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): Checking that all Kiwis are running" >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE} 

        ### Make sure the IP interface to the Kiwis is active by successfully pinging the router
        local router_ip=${KIWI_BASE_IP}.1
        while ! ping -c 1 ${router_ip} > /dev/null ; do
            echo "$(date): failed to ping router at ${router_ip}, so assume that ethernet interface on this server is down and can't reach the Kiwis even if they are online.  Sleeping 60 seconds and retrying"
            sleep 60;
        done
        
        local kiwi_id
        for kiwi_id in ${KIWI_ID_LIST[@]}; do
            local kiwi_ip="${KIWI_BASE_IP}.${kiwi_id}"
            ##ping -c 1 ${kiwi_ip} > /dev/null
            curl --silent ${kiwi_ip}:8073/status > curl_output.txt
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                [[ ${VERBOSITY} -ge 2 ]] && echo "$(date): 'curl --silent ${kiwi_ip}/status => ${ret_code}, so Kiwi ${kiwi_id} is OK" >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE} 
            else
                echo "$(date): ERROR: 'curl --silent ${kiwi_ip}/status' => ${ret_code}, so power cycling Kiwi${kiwi_id} for 10 seconds"  >> ${KIWI_POWER_WATCH_DAEMON_LOG_FILE}
                sain_control ${kiwi_id} off
                sleep 10
                sain_control ${kiwi_id} on  
                ### We won't check this Kiwi again for at least 60 seconds, so no need to wait for it to come alive again
            fi
        done
        sleep ${KIWI_POWER_WAIT_SECS}
    done
}

function get_daemon_status()
{
    local router_ip=${KIWI_BASE_IP}.1
    if ! ping -c 1 ${router_ip} > /dev/null ; then
        echo "$(date): failed to ping router at ${router_ip}, so assume that ethernet interface on this server is down and can't reach the Kiwis even if they are online.  Sleeping 60 seconds and retrying"
        return 1
    fi

    local kiwi_id
    for kiwi_id in ${KIWI_ID_LIST[@]}; do
        local kiwi_ip="${KIWI_BASE_IP}.${kiwi_id}"
        if ping -c 1 ${kiwi_ip} > /dev/null; then
            echo "'ping -c 1 ${kiwi_ip}' => $?, so Kiwi ${kiwi_id} is OK" 
        else
            echo "ERROR: 'ping -c 1 ${kiwi_ip}' => $?"
        fi
    done
}

function spawn_daemon()
{
    local startup_delay=$1 

    if [[ -f ${DAEMON_PID_FILE_PATH} ]]; then
        local daemon_pid=$( < ${DAEMON_PID_FILE_PATH}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "daemon is running with pid = ${daemon_pid}"
            return 0
        else
            echo "daemon pid ${daemon_pid} in ${DAEMON_PID_FILE_PATH} is not active."
            rm ${DAEMON_PID_FILE_PATH}
        fi
    fi
    daemon ${startup_delay} &
    local daemon_pid=$!
    echo ${daemon_pid} > ${DAEMON_PID_FILE_PATH}
    echo "Spawned daemon which has pid ${daemon_pid}"
}

function kill_daemon()
{
    if [[ -f ${DAEMON_PID_FILE_PATH} ]]; then
        local daemon_pid=$( < ${DAEMON_PID_FILE_PATH}) 
        if ps ${daemon_pid} > /dev/null ; then
            kill ${daemon_pid}
            echo "Killed running daemon which had pid = ${daemon_pid}"
        else
            echo "Found daemon pid ${daemon_pid} in ${DAEMON_PID_FILE_PATH} is not active."
        fi
        rm ${DAEMON_PID_FILE_PATH}
    else
        echo "There is no file ${DAEMON_PID_FILE_PATH}, so daemon was not running"
    fi
}

function get_daemon_status()
{
    if [[ -f ${DAEMON_PID_FILE_PATH} ]]; then
        local daemon_pid=$( < ${DAEMON_PID_FILE_PATH}) 
        if ps ${daemon_pid} > /dev/null ; then
            echo "daemon is running with pid = ${daemon_pid}"
        else
            echo "Found daemon pid ${daemon_pid} in ${DAEMON_PID_FILE_PATH} but that pid is not active."
            rm ${DAEMON_PID_FILE_PATH}
        fi
    else
        echo "There is no file ${DAEMON_PID_FILE_PATH}, so daemon is not running"
    fi
    get_daemon_status
}

######### The fucntions which implment this service daemon follow this line ###############
declare GRAPE_WAV_ARCHIVE_ROOT_PATH="${HOME}/wsprdaemon/wav-archive.d"
function upload_grape_data() {
    local date_list=($@)

    if [[ ${#date_list[@]} -eq 0 || ${date_list[0]} == "h" ]]; then
        [[ ${VERBOSITY} -gt 0 ]] && echo "-c expects a DATE argument in the form YYYYMMDD [YYYYMMDD ...]"
        exit 1
    fi
    [[ ${VERBOSITY} -gt 1 ]] && echo "Creating and uploading a GRAPE report for date(s) ${date_list[@]}"
    local directory_list=($( find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -maxdepth 1 -type d | sort -n ) )

    if [[ ${#directory_list[@]} -eq 0 ]] ; then
        [[ ${VERBOSITY} -gt 1 ]] && echo "Can't find any date directories in ${GRAPE_WAV_ARCHIVE_ROOT_PATH}.  Is WD configured to record and archive WWV* channels?"
         return 2
    fi

    for date in ${date_list[@]}; do
        if [[ ! "${directory_list[*]}" =~ "${date}" ]]; then
            [[ ${VERBOSITY} -gt 1 ]] && echo "Can't find find a date directory for date ${date}"
            continue
        fi
        [[ ${VERBOSITY} -gt 1 ]] && echo "Found the date directory ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}"
        local site_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}/ -mindepth 1 -maxdepth 1 -type d) )
        if [[ ${#site_dir_list[@]} -eq 0 ]]; then
            [[ ${VERBOSITY} -gt 1 ]] && echo "Found no site directories for ${date}"
            continue
        fi
        [[ ${VERBOSITY} -gt 1 ]] && echo "Found ${#site_dir_list[@]} site directories for date ${date}: ${site_dir_list[*]}"
        local site_dir
        for site_dir in ${site_dir_list[@]} ; do
            local receiver_dir_list=( $(find ${site_dir} -mindepth 1 -maxdepth 1 -type d | sort ) )
            if [[ ${#receiver_dir_list[@]} -eq 0 ]]; then
                [[ ${VERBOSITY} -gt 1 ]] && echo "Found no receiver directories for ${date}"
                continue
            fi
            [[ ${VERBOSITY} -gt 1 ]] && echo "found ${#receiver_dir_list[@]} receivers at site ${site_dir}"
            
            local receiver_dir
            for receiver_dir in ${receiver_dir_list[@]}; do
                local band_dir_list=( $(find ${receiver_dir} -mindepth 1 -maxdepth 1 -type d | sort -n ) )
                if [[ ${#band_dir_list[@]} -eq 0 ]]; then
                    [[ ${VERBOSITY} -gt 1 ]] && echo "Found no band directories for receiver  ${receiver_dir}"
                    continue
                fi
                [[ ${VERBOSITY} -gt 1 ]] && echo "found ${#band_dir_list[@]} bands for receiver  ${receiver_dir}"
                local band_dir
                for band_dir in ${band_dir_list[@]} ; do
                    local flac_file_list=( $(find ${band_dir} -type f -name '*.flac') )
                    if [[ ${#flac_file_list[@]} -eq 0 ]]; then
                        [[ ${VERBOSITY} -gt 1 ]] && echo "Found no flac files for band ${band_dir}"
                        continue
                    fi
                    [[ ${VERBOSITY} -gt 2 ]] && echo "Found ${#flac_file_list[@]} flac files in band ${band_dir}"
                    if [[ ${#flac_file_list[@]} -ne ${MINUTES_PER_DAY} ]]; then
                         [[ ${VERBOSITY} -gt 1 ]] && echo "band ${band_dir} has ${#flac_file_list[@]} flac files, not the expected ${MINUTES_PER_DAY}"
                     else
                         [[ ${VERBOSITY} -gt 1 ]] && echo "found band dir ${band_dir} has the expected ${MINUTES_PER_DAY} *.flac files" 
                         create_grape_wav_file ${flac_file_list[@]}
                    fi
                done
            done
        done
    done
}

function create_grape_wav_file()
{
    local flac_file_list=($@)
    local flac_file_dir="${flac_file_list[0]%/*}"
    local output_10sps_wav_file="${flac_file_dir}/24_hour_10sps_iq.wav"

    if [[ -f ${output_10sps_wav_file} ]]; then
        [[ ${VERBOSITY} -gt 1 ]] && echo "create_grape_wav_file(): the 10 sps wav file ${output_10sps_wav_file} exists, so there is nothing to do in this directory"
        return 0
    fi

    local flac_base_hour_name="${flac_file_list[0]%T*}T"

    [[ ${VERBOSITY} -gt 1 ]] && echo "create_grape_wav_file(): create one 24 hour, 10 hz wav file from ${#flac_file_list[@]} flac files. flac_base_hour_name=${flac_base_hour_name}"

    local hours_list=( $(seq -f "%02g" 0 23) )
    local hours_files_list=()
    local hour
    for hour in ${hours_list[@]}  ; do
        local one_hour_of_flac_files_list=( $( find ${flac_file_dir} -name "*T${hour}*flac" | sort ) )
        [[ ${VERBOSITY} -gt 2 ]] && echo "create_grape_wav_file(): decompressing ${#one_hour_of_flac_files_list[@]} flac files in order to  create the hour ${hour} wav file"
        flac -s -d ${one_hour_of_flac_files_list[@]}

        local one_hour_of_wav_files_list=( ${one_hour_of_flac_files_list[*]/.flac/.wav} )
        local one_hour_iq_wav_file="${flac_file_dir}/hour_${hour}_400sps.wav"
        [[ ${VERBOSITY} -gt 2 ]] && echo -e "create_grape_wav_file(): decimate ${#one_hour_of_wav_files_list[@]} wav files into one 400 sps wav file:\nfirst wav = ${one_hour_of_wav_files_list[0]}\nlast wav =  ${one_hour_of_wav_files_list[-1]}"
        sox  ${one_hour_of_wav_files_list[@]}  ${one_hour_iq_wav_file} rate 400

        rm   ${one_hour_of_wav_files_list[@]}
        hours_files_list+=(  ${one_hour_iq_wav_file} )
    done

    sox ${hours_files_list[@]} ${output_10sps_wav_file} rate 10
    rm  ${hours_files_list[@]}

    [[ ${VERBOSITY} -gt 1 ]] && echo "create_grape_wav_file(): created ${output_10sps_wav_file}"
}

declare MINUTES_PER_DAY=$((60 * 24))   ### = 1440 minutes per day

function usage()
{
    echo "$0 Version ${VERSION}: 
    -c YYYYMMDD      Create 10 sps wav files for each band from flac.tar files for YYYYMMDD
    -a               Start daemon which pings kiwis and power cycles them if they don't respond
    -A               start daemon with a delay of ${KIWI_STARTUP_DELAY_SECONDS}
    -z               kill the daemon
    -s               show the daemon status
    -d [a|i|z|s]     systemctl commands for daemon (a=start, i=install and enable, z=disable and stop, s=show status"
}

case ${1--h} in
    -c)
        upload_grape_data  ${2-h}
        ;;
    -a)
        spawn_daemon ${2-0}
        ;;
    -A)
        ### If this is installed as a Pi daemon by '-d a', the systemctl system will execute '-A'.  
        spawn_daemon ${KIWI_STARTUP_DELAY_SECONDS}
        ;;
    -z)
        kill_daemon
        ;;
    -s)
        get_daemon_status
        ;;
    -d)
        startup_daemon_control ${2-h}
        ;;
    -h)
        usage
        ;;
    *)
        echo "ERROR: flag '$1' is not valid"
        ;;
esac

exit 0
