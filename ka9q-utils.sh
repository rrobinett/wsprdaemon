#!/bin/bash
### The previous line signals to the vim editor that it should use its 'bash' editing mode when editing this file

###  Wsprdaemon:   A robust  decoding and reporting system for  WSPR 

###    Copyright (C) 2020-2024  Robert S. Robinett
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

### Default to getting Phl's 9/2/23 18:00 PDT sources
declare KA9Q_RADIO_DIR="${WSPRDAEMON_ROOT_DIR}/ka9q-radio"
declare KA9Q_TEMPLATE_FILE="${WSPRDAEMON_ROOT_DIR}/radiod@rx888-wsprdaemon-template.conf"

declare KA9Q_RADIO_ROOT_DIR="${WSPRDAEMON_ROOT_DIR}/ka9q-radio"
declare KA9Q_RADIO_WD_RECORD_CMD="${KA9Q_RADIO_ROOT_DIR}/wd-record"

# 11/15/24 - Scott N5TNL enhanced wd-record to output wav files with 32bit float samples
# wd-record has some new command line options. -p enables float32 wav output (without the -p it'll do int wav files). You'll probably have to also pass -c (channels) and -S (sample rate) because the float
# encoded RTP streams don't include the right bits to ID channel count and sample rate.
declare KA9Q_RADIO_WD_RECORD_CMD_FLOAT_ARGS="${KA9Q_RADIO_WD_RECORD_CMD_FLOAT_ARGS--p -c 1 -S 12000}"

declare KA9Q_RADIO_PCMRECORD_CMD="${KA9Q_RADIO_ROOT_DIR}/pcmrecord"
declare KA9Q_RADIO_TUNE_CMD="${KA9Q_RADIO_ROOT_DIR}/tune"
declare KA9Q_DEFAULT_CONF_NAME="rx888-wsprdaemon"
declare KA9Q_RADIOD_CONF_DIR="/etc/radio"
declare KA9Q_RADIOD_LIB_DIR="/var/lib/ka9q-radio"

### These are the libraries needed by KA9Q, but it is too hard to extract them from the Makefile, so I just copied them here
declare KA9Q_RADIO_LIBS_NEEDED="curl rsync build-essential libusb-1.0-0-dev libusb-dev libncurses-dev libfftw3-dev libbsd-dev libhackrf-dev \
             libopus-dev libairspy-dev libairspyhf-dev librtlsdr-dev libiniparser-dev libavahi-client-dev portaudio19-dev libopus-dev \
             libnss-mdns mdns-scan avahi-utils avahi-discover libogg-dev python3-soundfile"

declare KA9Q_RADIO_ROOT_DIR="${WSPRDAEMON_ROOT_DIR}/ka9q-radio"
declare KA9Q_RADIO_NWSIDOM="${KA9Q_RADIO_ROOT_DIR}/nwisdom"     ### This is created by running fft_wisdom during the KA9Q installation
declare FFTW_DIR="/etc/fftw"                                    ### This is the directory where radiod looks for a wisdomf
declare FFTW_WISDOMF="${FFTW_DIR}/wisdomf"                      ### This the wisdom file it looks for

declare GIT_LOG_OUTPUT_FILE="${WSPRDAEMON_TMP_DIR}/git_log.txt"

###  function wd_logger() { echo $@; }        ### Only for use when unit testing this file

### Ensure that the set of source code in a git-managed directory is what you want
### Returns:  0 => already that COMMIT, so no change     1 => successfully checked out that commit COMMIT, else 2,3,4 ERROR in trying to execute
function pull_commit(){
    local git_directory=$1
    local desired_git_sha=$2
    local git_project=${git_directory##*/}
    local rc

    if [[ ! -d ${git_directory} ]]; then
        wd_logger 1 "ERROR: project '${git_directory}' does not exist"
        return 2
    fi

    if [[ ${desired_git_sha} =~ main|master ]]; then
        wd_logger 2 "Loading the most recent COMMIT for project ${git_project}"
        rc=0
        if [[ "$(cd ${git_directory}; git rev-parse HEAD)" == "$( cd ${git_directory}; git fetch origin && git rev-parse origin/${desired_git_sha})" ]]; then
            wd_logger 2 "You have asked for and are on the latest commit of the main branch."
        else
            wd_logger 1 "You have asked for but are not on the latest commit of the main branch, so update the local copy of the code."
            ( cd ${git_directory}; git restore pcmrecord.c ; git fetch origin && git checkout origin/${desired_git_sha} ) >& git.log
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: failed to update to latest commit:\n$(< git.log)"
            else
                 wd_logger 1 "Updated to latest commit."
            fi
        fi
        return ${rc}
    fi

    ### desired COMMIT SHA was specified
    local git_root="main"  ### Now github's default.  older projects like wsprdaemon have the root 'master'
    if [[ ${git_project} == "ft8_lib" ]]; then
         git_root="master"
    fi

    local current_commit_sha
    get_current_commit_sha current_commit_sha ${git_directory}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'get_current_commit_sha current_commit_sha ${git_directory}' => ${rc}"
        return 3
    fi
    if [[ "${current_commit_sha}" == "${desired_git_sha}" ]]; then
        wd_logger 2 "Current git COMMIT in ${git_directory} is the expected ${current_commit_sha}"
        return 0
    fi
    wd_logger 1 "Current git commit COMMIT in ${git_directory} is ${current_commit_sha}, not the desired COMMIT ${desired_git_sha}, so update the code from git"
    wd_logger 1 "First 'git checkout ${git_root}'"
    ( cd ${git_directory}; git restore pcmrecord.c; git checkout ${git_root} ) >& git.log
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'git checkout ${git_root}' => ${rc}.  git.log:\n $(< git.log)"
        return 4
    fi
    wd_logger 1 "Then 'git pull' to be sure the code is current"
    ( cd ${git_directory}; git pull ) >& git.log
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'git pull' => ${rc}. git.log:\n$(< git.log)"
        return 5
    fi
    wd_logger 1 "Finally 'git checkout ${desired_git_sha}, which is the COMMIT we want"
    ( cd ${git_directory}; git checkout ${desired_git_sha} ) >& git.log
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'git checkout ${desired_git_sha}' => ${rc} git.log:\n$(< git.log)"
        return 6
    fi
    wd_logger 1 "Successfully updated the ${git_directory} directory to COMMIT ${desired_git_sha}"
    return 1
}

##############
function wd_get_config_value() {
    local __return_variable_name=$1
    local return_variable_type=$2

    wd_logger 3 "Find the value of the '${return_variable_type}' from the config settings in the WD.conf file"

    if ! declare -p WSPR_SCHEDULE &> /dev/null ; then
        wd_logger 1 "ERROR: the array WSPR_SCHEDULE has not been declared in the WD.conf file"
        return 1
    fi
    local -A receiver_reference_count_list=()
    local schedule_index
    for (( schedule_index=0; schedule_index < ${#WSPR_SCHEDULE[@]}; ++schedule_index )); do
        local job_line="${WSPR_SCHEDULE[${schedule_index}]}"
        wd_logger 3 "Getting the names and counts of radios defined for job ${schedule_index}: ${job_line}"
        local job_line_list=( ${job_line} )
        local job_field
        for job_field in ${job_line_list[@]:1}; do
            local job_receiver=${job_field%%,*}
            ((receiver_reference_count_list["${job_receiver}"]++))
            wd_logger 3 "Found receiver ${job_receiver} referenced in job ${job_field} has been referenced ${receiver_reference_count_list["${job_receiver}"]} times"
        done
    done
    local largest_reference_count=0
    local most_referenced_receiver
    local receiver_name
    for receiver_name in "${!receiver_reference_count_list[@]}"; do
        if [[ ${receiver_reference_count_list[${receiver_name}]} -gt ${largest_reference_count} ]]; then
            largest_reference_count=${receiver_reference_count_list[${receiver_name}]}
             most_referenced_receiver="${receiver_name}"
        fi
    done
    wd_logger 3 "Found the most referenced receiver in the WSPR_SCHEDULE[] is '${most_referenced_receiver}' which was referenced in ${largest_reference_count} jobs"

    if ! declare -p RECEIVER_LIST >& /dev/null ; then
        wd_logger 1 "ERROR: the RECEIVER_LIST array is not declared in WD.conf"
        return 2
    fi
    local receiver_index
    for (( receiver_index=0; receiver_index < ${#RECEIVER_LIST[@]}; ++receiver_index )); do
        local receiver_line_list=( ${RECEIVER_LIST[${receiver_index}]} )
        local receiver_name=${receiver_line_list[0]}
        local receiver_call=${receiver_line_list[2]}
        local receiver_grid=${receiver_line_list[3]}

        if [[ ${receiver_name} == ${most_referenced_receiver} ]]; then
            case ${return_variable_type} in
                CALLSIGN)
                    eval ${__return_variable_name}=\${receiver_call}
                    wd_logger 2 "Receiver ${receiver_name} is reporting as ${receiver_call} to return variable ${__return_variable_name}"
                    return 0
                    ;;
                LOCATOR)
                    eval ${__return_variable_name}=\${receiver_grid}
                    wd_logger 2 "Assigned ${__return_variable_name}=${receiver_grid}"
                    return 0
                    ;;
                ANTENNA)
                    #local receiver_description=$( sed -n "/${receiver_name}.*${receiver_grid}/s/${receiver_name}.*${receiver_grid}//p"  ${WSPRDAEMON_CONFIG_FILE} )
                    local receiver_line=$( grep "\"${receiver_name} .*${receiver_grid}"  ${WSPRDAEMON_CONFIG_FILE} )
                    local antenna_description
                    if [[ "${receiver_line}" =~ \#.*ANTENNA: ]]; then
                        antenna_description="${receiver_line##*\#*ANTENNA:}"
                        shopt -s extglob
                        antenna_description="${antenna_description##+([[:space:]])}"    ### trim off leading white space
                        wd_logger 2 "Found the description '${antenna_description}' in line: ${receiver_line}"
                    else
                        antenna_description="No antenna information"
                        wd_logger 2 "Can't find comments about receiver ${receiver_call}, so use 'No antenna information'"
                    fi

                    eval ${__return_variable_name}="\${antenna_description}"
                    wd_logger 2 "Assigned ${__return_variable_name}=${antenna_description}"
                    return 0
                    ;;
                *)
                    wd_logger 1 "ERROR: invalid return_variable_type='${return_variable_type}"
                    return 0
            esac
        fi
    done
    wd_logger 1 "ERROR: can't find ${return_variable_type} config information"
    return 1
}

### Assumes ka9q-radio has been successfully installed and setup to run
function get_conf_section_variable() {
    local __return_variable_name=$1
    local conf_file_name=$2
    local conf_section=$3
    local conf_variable_name=$4

    if [[ ! -f ${conf_file_name} ]] ; then
        wd_logger 1 "ERROR: '' doesn't exist"
        return 1
    fi
    local section_lines=$( grep -A 40 "\[.*${conf_section}\]"  ${conf_file_name} | awk '/^\[/ {++count} count == 2 {exit} {print}' )
    if [[ -z "${section_lines}" ]]; then
        wd_logger 1 "ERROR:  couldn't find section '\[${conf_section}\]' in  ${conf_file_name}"
        return 2
    fi
    wd_logger 2 "Got section '\[.*${conf_section}\]' in  ${conf_file_name}:\n${section_lines}"
    local section_variable_value=$( echo "${section_lines}" | awk "/${conf_variable_name} *=/ { print \$3 }" )
    if [[ -z "${section_variable_value}" ]]; then
        wd_logger 1 "ERROR: couldn't find variable ${conf_variable_name} in ${conf_section} section of config file  ${conf_file_name}"
        return 3
    fi
    eval ${__return_variable_name}="\${section_variable_value}"
    wd_logger 2 "Returned the value '${section_variable_value}' of variable '${conf_variable_name}' in '${conf_section}' section of config file '${conf_file_name}' to variable '${__return_variable_name}'"
    return 0
}

function get_current_commit_sha() {
    local __return_commit_sha_variable=$1
    local git_directory=$2
    local rc

    if [[ ! -d ${git_directory} ]]; then
        wd_logger 1 "ERROR: directory '${git_directory}' doesn't exist"
        return 1
    fi
    wd_logger 2 "Getting git commit from  ${git_directory}"
    ( cd ${git_directory}; git log >& ${GIT_LOG_OUTPUT_FILE} )
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'cd ${git_directory}; git log' => ${rc}:\n$(head ${GIT_LOG_OUTPUT_FILE})"
        echo ${force_abort}
    fi
    local commit_sha=$( awk '/commit/{print $2; exit}' ${GIT_LOG_OUTPUT_FILE} )
    if [[ -z "${commit_sha}" ]]; then
        wd_logger 1 "ERROR: 'git log' output does not contain a line with 'commit' in it"
        echo ${force_abort}
    fi
    wd_logger 2 "'git log' is returning the current commit COMMIT = ${commit_sha}"
    eval ${__return_commit_sha_variable}=\${commit_sha}
    return 0
}

function ka9q-get-configured-radiod() {
    local __return_radio_conf_file_name=$1

    local _radiod_conf_file_name=$( ps aux | awk '!/awk/ && /\/sbin\/radiod /{print $NF}')
    if [[ -n "${_radiod_conf_file_name}" ]]; then
        wd_logger 2 "Found radiod is running and configured by ${_radiod_conf_file_name}"
        eval ${__return_radio_conf_file_name}="\${_radiod_conf_file_name}"
        return 0
    fi
    wd_logger 2 "radiod isn't running, so find the conf file to use"

    local ka9q_conf_file_name
    if [[ -z "${KA9Q_CONF_NAME-}" ]]; then
        ka9q_conf_file_name=${KA9Q_RADIOD_CONF_DIR}/radiod@rx888-wsprdaemon.conf
        wd_logger 2 "Found that KA9Q_CONF_NAME has not been defined in WD.conf, so use the default radiod conf file ${ka9q_conf_file_name}"
        if [[ ! -f ${ka9q_conf_file_name} ]]; then
            wd_logger 1 "ERROR: KA9Q_CONF_NAME was not defined in WD.conf, but the default ${ka9q_conf_file_name} doesn't exist"
            exit 1
        fi
        wd_logger 2 "The default radiod conf file ${ka9q_conf_file_name} has been found"
    else
        ka9q_conf_file_name=${KA9Q_RADIOD_CONF_DIR}/radiod@${KA9Q_CONF_NAME}.conf
        wd_logger 2 "In WD.conf found KA9Q_CONF_NAME='${KA9Q_CONF_NAME}' => ${ka9q_conf_file_name}"

        if [[ ! -f ${ka9q_conf_file_name} ]]; then
            wd_logger 1 "ERROR: The conf file ${ka9q_conf_file_nam} specified by KA9Q_CONF_NAME=${KA9Q__CONF_NAME} doesn't exist"
            exit 1
        fi
        wd_logger 2 "The configured radio conf file ${ka9q_conf_file_name} has been found"
    fi

    eval ${__return_radio_conf_file_name}="\${ka9q_conf_file_name}"
    wd_logger 2 "Assigned ${__return_radio_conf_file_name}='${ka9q_conf_file_name}'"
    return 0
}


### Checks that the radiod config file is set with the desired low = 1300, high = 1700 and fix them if they were set to 100, 5000 by WD 3.1.4
function ka9q_conf_file_bw_check() {
    local conf_name=$1

    local running_radiod_conf_file=$( sudo systemctl status | grep -v awk | awk '/\/etc\/radio\/radiod.*conf/{print $NF}' | grep "${conf_name}" )
    if [[ -z "${running_radiod_conf_file}" ]]; then
        wd_logger 1 "radiod@${conf_name} is not running on this server"
        return 0
    fi
    local rx_audio_low=$( awk '/^low =/{print $3;exit}' ${running_radiod_conf_file})     ### Assume that the first occurence of '^low' and '^high' is in the [WSPR] section
    local rx_audio_high=$( awk '/^high =/{print $3;exit}' ${running_radiod_conf_file})
    wd_logger 2 "In ${running_radiod_conf_file}: low = ${rx_audio_low}, high = ${rx_audio_high}"

    if [[ -z "${rx_audio_low}" || -z "${rx_audio_high}" ]]; then
        wd_logger 1 "ERROR: can't find the expected low and/or high settings in ${running_radiod_conf_file}"
        return 1
    fi
    local rx_needs_restart="no"
    if [[ "${rx_audio_low}" != "1300" ]]; then
        wd_logger 1 "WARNING: found low = ${rx_audio_low}, so changing it to the desired value of 1300"
        sed -i "0, /^low =/{s/low = ${rx_audio_low}/low = 1300/}"  ${running_radiod_conf_file}      ### Only change the first 'low = ' line in the conf file
        rx_needs_restart="yes"
    fi
    if [[ "${rx_audio_high}" != "1700" ]]; then
        wd_logger 1 "WARNING: found high = ${rx_audio_high}, so changing it to the desired value of 1700"
        sed -i "0, /^high/{s/high = ${rx_audio_high}/high = 1700/}"  ${running_radiod_conf_file}
        rx_needs_restart="yes"
    fi
    if [[ ${rx_needs_restart} == "no" ]]; then
        wd_logger 2 "No changes needed"
    else
        wd_logger 1 "Restarting the radiod service"
        local radiod_service_name=${running_radiod_conf_file##*/}
        radiod_service_name=${radiod_service_name/.conf/.service}
        sudo systemctl restart ${radiod_service_name}
    fi
    return 0
}

### Parses the data fields in the first line with the word 'STAT' in it into the global associative array ka9q_status_list()
declare KA9Q_MIN_LINES_IN_USEFUL_STATUS=20
declare KA9Q_GET_STATUS_TRIES=${KA9Q_GET_STATUS_TRIES-1}
declare KA9Q_METADUMP_WAIT_SECS=${KA9Q_METADUMP_WAIT_SEC-15}       ### low long to wait for a 'metadump...&' to complete
declare -A ka9q_status_list=()

###  ka9q_get_metadump ${receiver_ip_address} ${receiver_freq_hz} ${status_log_file}
function ka9q_get_metadump() {
    local receiver_ip_address=$1
    local receiver_freq_hz=$2
    local status_log_file=$3

    local got_status="no"
    local timeout=${KA9Q_GET_STATUS_TRIES}
    while [[ "${got_status}" == "no" && ${timeout} -gt 0 ]]; do
        (( --timeout ))
        wd_logger 2 "Spawning 'metadump -c 2 -s ${receiver_freq_hz}  ${receiver_ip_address} > metadump.log &' and waiting ${KA9Q_METADUMP_WAIT_SECS} seconds for it to complete"

        local metadump_pid
        metadump -c 2 -s ${receiver_freq_hz}  ${receiver_ip_address}  > metadump.log &
        metadump_pid=$!

        local i
        for (( i=0; i<${KA9Q_METADUMP_WAIT_SECS}; ++i)); do
            if ! kill -0 ${metadump_pid} 2> /dev/null; then
                wait ${metadump_pid}
                rc=$?
                wd_logger 2 "'metadump...&' has finished before we timed out"
                break
            fi
            wd_logger 2 "Waiting another second for 'metadump...&' to finish"
            sleep 1
        done

        if [[ ${i} -lt ${KA9Q_METADUMP_WAIT_SECS} ]]; then
            wd_logger 2 "'metadump..&' finished after ${i} seconds of waiting"
        else
            wd_logger 2 "ERROR: timing out after ${i} seconds of waiting for 'metadump..&' to terminate itself, so killing its pid ${metadump_pid}:\n$(< metadump.log)"
            kill  ${metadump_pid} 2>/dev/null
            rc=124
        fi

        if (( rc )); then
            wd_logger 1 "ERROR: failed to get any status stream information from 'metadump -c 2 -s ${receiver_freq_hz}  ${receiver_ip_address} > metadump.log &':\n$(< metadump.log)"
        else
            sed -e 's/ \[/\n[/g' metadump.log  > ${status_log_file}
            local status_log_line_count=$(wc -l <  ${status_log_file} )
            wd_logger 2 "Parsed the $(wc -c < metadump.log) bytes of html in 'metadump.log' into ${status_log_line_count} lines in '${status_log_file}'"

            if (( status_log_line_count > KA9Q_MIN_LINES_IN_USEFUL_STATUS )); then
                wd_logger 2 "Got useful status file"
                got_status="yes"
            else
                wd_logger 1 "ERROR: There are only ${status_log_line_count} lines, not the expected ${KA9Q_MIN_LINES_IN_USEFUL_STATUS} or more lines in ${status_log_file}:\n$(< ${status_log_file})\nSo try metadump again"
            fi
        fi
    done
    if [[ "${got_status}" == "no" ]]; then
        wd_logger 2 "ERROR: couldn't get useful status after ${KA9Q_GET_STATUS_TRIES}"
        return 1
    else
        wd_logger 2 "Got new status from:  'metadump -s ${receiver_freq_hz}  ${receiver_ip_address} > ${status_log_file}'"
        return 0
    fi
 }

function ka9q_parse_metadump_file_to_status_file() {
    local metadump_log_file=${1}
    local metadump_status_file=${2}

    wd_logger 2 "Parse last STAT line in ${metadump_log_file}"

    local last_stat_line=$(grep "STAT"  ${metadump_log_file} | tail -n 1)
    wd_logger 2  "Last STAT line:  ${last_stat_line}" 

    local last_stat_line_list=(${last_stat_line})

    local last_stat_line_date="${last_stat_line_list[@]:0:6}"
    local last_stat_line_epoch=$(date -d "${last_stat_line_date}" +%s)
    local last_stat_line_host="${last_stat_line_list[6]}"
    local last_stat_line_data="${last_stat_line_list[@]:8}"

    wd_logger 2  "Last STAT date:  ${last_stat_line_date}  === epoch ${last_stat_line_epoch}" 
    wd_logger 2  "Last STAT host:  ${last_stat_line_host}" 
    wd_logger 2  "Last STAT data:  '${last_stat_line_data}'" 

    > ${metadump_status_file}.tmp    ### create or truncate the output file
    local parsed_status_line="${last_stat_line_data}"
    while [[ -n "${parsed_status_line}" ]]; do
        local leading_status_field="${parsed_status_line%% \[*}"
        echo "${leading_status_field}" >> ${metadump_status_file}.tmp
        wd_logger 2 "Got leading_status_field=${leading_status_field}"
        local no_left_parens="${parsed_status_line#\[}"
        if ! [[ ${no_left_parens} =~ \[ ]]; then
            wd_logger 2 "No '[' left after stripping the first one.  So we are done parsing"
           break
        fi
        parsed_status_line="[${parsed_status_line#* \[}"
    done
    sort -t '[' -k2n  ${metadump_status_file}.tmp >  ${metadump_status_file}
    rm -f ${metadump_status_file}.tm
}

function ka9q_parse_status_value() {
    local ___return_var="$1"
    local status_file=$2
    local search_val="$3"

    ### Parsing metadump's status report lines has proved to be a RE challenge since some lines include a subset of other status report lines
    ### Also each line starts with its enum value '[xxx]' while some lines include a '/'.  This sed expression avoids problems with '/' by delimiting the 's' seach 
    ### and replace command fields with ';' which isn't found in any of the current status lines
    if [[ ! -f  ${status_file} ]]; then
        wd_logger 1 "ERROR: can't find  ${status_file}"
        eval ${___return_var}=\"""\"  ### ensures that return variable is initialized
        return 1
    fi
    local search_results
    search_results=$( sed -n -e "s;^\[[0-9]*\] ${search_val};;p"  ${status_file} )

    if [[ -z "${search_results}" ]]; then
        wd_logger 1 "ERROR: can't find '${search_val}' in ${status_file}"
        eval ${___return_var}=\"""\"  ### ensures that return variable is initialized
        return 2
    fi
    wd_logger 2 "Found search string '${search_val}' in line and returning '${search_results}'"
    eval ${___return_var}=\""${search_results}"\"
    return 0
}

### To avoid executing multiple calls to 'metadump' cache its ouput in ./ka9q_status.log.  Each channel needs one of these
declare KA9Q_METADUMP_CACHE_FILE_NAME="./ka9q_status.log"
declare MAX_KA9Q_STATUS_FILE_AGE_SECONDS=${MAX_KA9Q_STATUS_FILE_AGE_SECONDS-5 }

function ka9q_get_current_status_value() {
    local __return_var="$1"
    local receiver_ip_address=$2
    local receiver_freq_hz=$3
    local search_val="$4"
    local rc

    local status_log_file="${KA9Q_METADUMP_CACHE_FILE_NAME}"   ### each receiver+channel will have status fields unique to it, so there needs to be a file for each of them
    local status_log_file_epoch=0

    if [[ -f  ${status_log_file} ]]; then
        status_log_file_epoch=$(stat -c %Y ${status_log_file} ) 
    fi
    local current_epoch=$(printf "%(%s)T")

    if [[ $((  current_epoch - status_log_file_epoch )) -lt ${MAX_KA9Q_STATUS_FILE_AGE_SECONDS} ]]; then
        wd_logger 2 "Getting value from ${KA9Q_METADUMP_CACHE_FILE_NAME} which is less than  ${MAX_KA9Q_STATUS_FILE_AGE_SECONDS} seconds old"
    else
        wd_logger 2 "Updating ${status_log_file}"
        ka9q_get_metadump ${receiver_ip_address} ${receiver_freq_hz} ${status_log_file}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to update ${status_log_file}"
            return ${rc}
        fi
    fi

    local value_found
    ka9q_parse_status_value  value_found  ${status_log_file} "${search_val}"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to get new status"
        return ${rc}
    fi
    
    wd_logger 2 "Returning '${value_found}'"

    eval ${__return_var}=\""${value_found}"\"
    return 0
}

function ka9q_status_service_test() {
    local ad_value
    local rc

    ka9q_get_current_status_value ad_value wspr-pcm.local 14095600  "A/D overrange:"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        printf "'ka9q_get_current_status_value (ad_value wspr-pcm.local 14095600 \"A/D overrange:\") ' => ${rc}\n"
        exit ${rc}
    fi
     printf "'ka9q_get_current_status_value (ad_value wspr-pcm.local 1409660  \"A/D overrange:\") ' returned '${ad_value}'\n"
     return -1
}
# ka9q_status_service_test
# exit

#!/bin/bash
# script to install the latest version of ka9q-web
# should be run from BASEDIR (i.e. /home/wsprdaemon/wsprdaemon) and it assumes
# that ka9q-radio has already been built in the ka9q-radio directory

#shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced
#set -euo pipefail

#  function wd_logger() { echo $@; }        ### Only for use when unit testing this file
#  function is_uint() { return 0; }

function ka9q-get-conf-file-name() {
    local __return_pid_var_name=$1
    local __return_conf_file_var_name=$2

    local ka9q_ps_line
    ka9q_ps_line=$( ps aux | grep "sbin/radiod .*radiod@" | grep -v grep | head -n 14)

    if [[ -z "${ka9q_ps_line}" ]]; then
        wd_logger 1 "The ka9q-radiod service is not running"
        return 1
    fi
    local ka9q_pid_value
    ka9q_pid_value=$(echo "${ka9q_ps_line}" | awk '{print $2}')
    if [[ -z "${ka9q_pid_value}" ]]; then
        wd_logger 1 "ERROR: couldn't extract the pid value from this ps' line: '${ka9q_ps_line}"
        return 2
    fi
    if ! is_uint  "${ka9q_pid_value}" ]]; then
        wd_logger 1 "ERROR: couldn't extract a PID(unsigned integer) from the 2nd field of this ps' line: '${ka9q_ps_line}"
        return 3
    fi
    eval ${__return_pid_var_name}=\"\${ka9q_pid_value}\"

    local ka9q_conf_file
    ka9q_conf_file=$(echo "${ka9q_ps_line}" | awk '{print $NF}')
    if [[ -z "${ka9q_conf_file}" ]]; then
        wd_logger 1 "ERROR: couldn't extract the conf file path from this ps' line: '${ka9q_ps_line}"
        return 2
    fi
    eval ${__return_conf_file_var_name}=\"\${ka9q_conf_file}\"
    wd_logger 2 "Found pid =${ka9q_pid_value} and conf_file = '${ka9q_conf_file}'"
    return 0
}

#declare test_pid=foo
#declare test_file_name=bar
#ka9q-get-conf-file-name  test_pid test_file_name
#echo "Gpt pid = ${test_pid} amd conf_file = '${test_file_name}'"
#exit

function ka9q-get-status-dns() {
    local ___return_status_dns_var_name=$1

    local ka9q_web_pid
    local ka9q_web_conf_file
    local rc

    local conf_web_dns
    get_config_file_variable "conf_web_dns" "KA9Q_WEB_DNS"
    if [[ -n "${conf_web_dns-}" ]]; then
        wd_logger 1 "Found KA9Q_WEB_DNS='$conf_web_dns' in WD.conf, so set KA9Q-web to display that"
        eval ${___return_status_dns_var_name}=\"${conf_web_dns}\"
        return 0
    else
        wd_logger 1 "Found no KA9Q_WEB_DNS='<DNS_URL>' in WD.conf, so lookup on tghe LAN using the avahi DNS service"
    fi

    ka9q-get-conf-file-name  "ka9q_web_pid"  "ka9q_web_conf_file"
    rc=$? ; if (( rc )); then
        wd_logger 1 "Can't get ka9q-get-conf-file-name, so no local radiod is running. See if radiod is running remotely"
        avahi-browse -t -r _ka9q-ctl._udp 2> /dev/null | grep hf.*.local | sort -u  > avahi-browse.log
        rc=$?
        wd_logger 2 "'avahi-browse -t -r _ka9q-ctl._udp 2> /dev/null | grep hf.*.local | sort -u  > avahi-browse.log' => $rc.  avahi-browse.log=>'$(<  avahi-browse.log)'"
        local status_dns_list=( $( sed -n 's/.*\[\(.*\)\].*/\1/p'  avahi-browse.log ) )
        wd_logger 1 "{#status_dns_list[@]} = ${#status_dns_list[@]}, status_dns_list[] = '${status_dns_list[*]}'"
        case ${#status_dns_list[@]} in
            0)
                wd_logger 1 "Can't find any hf...local streams"
                 return 1
                 ;;
             1)
                 wd_logger 1 "Found one radiod outputing ${status_dns}, so there must be an active radiod service running remotely"
                 eval ${___return_status_dns_var_name}=\"${status_dns}\"
                 return 0
                 ;;
             *)
                 local wd_logger_print_arg=$(printf "Found ${#status_dns_list[@]} radiod servers running on this LAN:\n${status_dns_list[*]}\nChose which to display by adding a line like this to wsprdemon.conf:\nKA9Q_WEB_DNS=\"${status_dns_list[0]}\"")
                 echo -e "$wd_logger_print_arg" >&2     ### wd_logger output goes into the daemon.log file, so echo this to stderr so the user sees it 
                 wd_logger 1 "Multiple DNS:\n$wd_logger_print_arg"
                 return 1
                 ;;
         esac
    fi
    if [[ -z "${ka9q_web_conf_file}" || ! -f "${ka9q_web_conf_file}" ]]; then
        wd_logger 1 "Cant' find the conf file '${conf_file}' for radiod"
        returm 2
    fi
    local ka9q_radiod_dns
    ka9q_radiod_dns=$( grep -A 20 "\[global\]" "${ka9q_web_conf_file}" |  awk '/^status =/{print $3}' )
    if [[ -z "${ka9q_radiod_dns}" ]]; then
        wd_logger 1 "Can't find the 'status =' line in '${conf_file}'"
        returm 3
    fi
    wd_logger 2 "Found the radiod status DNS = '${ka9q_radiod_dns}'"
    eval ${___return_status_dns_var_name}=\"${ka9q_radiod_dns}\"
    return 0
}

#declare test_dns=foo
#ka9q-get-status-dns "test_dns" 
#echo "Gpt status DNS = '${test_dns}'"
#exit

declare KA9Q_WEB_CMD="/usr/local/sbin/ka9q-web"


declare ka9q_service_daemons_list=(
    "hf1.local 8081 WW0WWV"
)

### This is called by the watchdog daemon and needs to be extended to support multiple RX888 servers at a site.
function ka9q_web_daemon() {
    wd_logger 1 "Starting"

    while true; do
        local rc
        wd_logger 1 "Starting loop by checking for DNS of status stream"

        local ka9q_radiod_status_dns=""
        while [[ -z "$ka9q_radiod_status_dns" ]]; do
            ka9q-get-status-dns "ka9q_radiod_status_dns" >& /dev/null
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: ka9q-get-status-dns()  => ${rc}"
            fi
            if [[ -z "${ka9q_radiod_status_dns}" ]]; then
                wd_logger 1 "ERROR: can't find ka9q_radiod_status_dns, so sleep for 5 seconds and try again"
                sleep 5
            fi
        done
        ka9q_service_daemons_list=()
        ka9q_service_daemons_list[0]="${ka9q_radiod_status_dns} ${KA9Q_WEB_IP_PORT-8081} ${KA9Q_WEB_TITLE-}"  ### This is hack to get this one service implementation working

        local i
        for (( i=0; i < ${#ka9q_service_daemons_list[@]}; ++i )); do
            local  ka9q_service_daemon_info="${ka9q_service_daemons_list[i]}"

            wd_logger 1 "Running 'ka9q_web_service_daemon '${ka9q_service_daemon_info}'"
            ka9q_web_service_daemon ${ka9q_service_daemon_info}          ### These should be spawned off
            rc=$?
            wd_logger 1 "ERROR: ka9q_web_service_daemon $ka9q_service_daemon_info => $rc.  Sleep 5 and run it aagain"
            sleep 5
        done
    done
}

### We could spawn multiple q-web daemons, so I've coded for this to be a spawned daemom.  But for now WD supports only one KA9Q-web daemon per server
function ka9q_web_service_daemon() {
    local status_dns_name=$1             ### Where to get the spectrum stream (e.g. hf.local)
    local server_ip_port=$2              ### On what IP port to offer the UI
    local server_description="${3:-}"    ### KA9Q_WEB_TITLE, if defined.
    server_description="${server_description//_/ }" ### Replace all '_' with ' '

    while true; do
        if [[ ! -x ${KA9Q_WEB_CMD} ]]; then
            wd_logger 1 "ERROR: can't find '${KA9Q_WEB_CMD}'. Sleep and check again"
            #exit 1
            wd_sleep 3
            continue
        fi
        local daemon_log_file="ka9q_web_service_${server_ip_port}.log"
        wd_logger 1 "Got status_dns_name='${status_dns_name}', IP port = ${server_ip_port}, server description = '${server_description}'"

        # Conditionally add -n "${server_description}" if KA9Q_WEB_TITLE is defined
        if [[ -n "${server_description}" ]]; then
            ${KA9Q_WEB_CMD} ${WF_BIT_DEPTH_ARG--b1} -m ${status_dns_name} -p ${server_ip_port} -n "${server_description}" >& ${daemon_log_file}
        else
            ${KA9Q_WEB_CMD} ${WF_BIT_DEPTH_ARG--b1} -m ${status_dns_name} -p ${server_ip_port} >& ${daemon_log_file}
        fi

        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: '${KA9Q_WEB_CMD} -m ${status_dns_name} -p ${server_ip_port} -n '${server_description}' => ${rc}:\n$(<  ${daemon_log_file})"
        fi
        wd_logger 1 "Sleeping for 5 seconds before restarting"
        wd_sleep 5
    done
}

#function test_ka9q-web-setup() {
#     ka9q-web-setup
#}
# test_ka9q-web-setup

### This function is executed once the ka9q-radio dirrectory is created and has the configured version of SW installed
function build_ka9q_radio() {
    local project_subdir=$1
    local project_logfile="${project_subdir}_build.log"

    wd_logger 2 "Starting"
    if [[ ! -e ${project_subdir} ]]; then
        wd_logger 1 "ERROR:  project_subdir=${project_subdir} doesn't exist"
        return 1
    fi
    local rc
    find ${project_subdir}  -type f -exec stat -c "%Y %n" {} \; | sort -n > before_make.txt
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'find ${project_subdir}  -type... > before_make.txt' => ${rc}"
        return 2
    fi
    wd_logger 2 "Building ${project_subdir}"
    (
    cd  ${project_subdir}
    if [[ ! -L  Makefile ]]; then
        if [[ -f  Makefile ]]; then
            wd_logger 1 "WARNING: Makefile exists but it isn't a symbolic link to Makefile.linux"
            rm -f Makefile
        fi
        wd_logger 1 "Creating a symbolic link from Makefile.linux to Makefile"
        ln -s Makefile.linux Makefile
    fi
    make
    ) >&  ${project_logfile}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: compile of '${project_subdir}' returned ${rc}:\n$(< ${project_logfile})"
        return 3
    fi

    find ${project_subdir} -type f -exec stat -c "%Y %n" {} \; | sort -n > after_make.txt
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'find ${project_subdir}  -type...' > after_make.tx  => ${rc} "
        return 3
    fi
    diff before_make.txt after_make.txt > diff.log
    rc=$? ; case ${rc} in
        0)
            wd_logger 2 "No new files were created, so no need for a 'sudo make install"
            ;;
        1)
            if [[ ${KA9Q_RUNS_ONLY_REMOTELY-no} == 'yes' ]]; then
                wd_logger 1 "New files were created but WD is not configured to install and run ka9q-radio, so don't run 'sudo make install"
            else
                wd_logger 1 "New files were created and WD is configured to install and run ka9q-radio, so run 'sudo make install"
                ( cd  ${project_subdir}; sudo make install ) >& ${project_logfile}
            fi
            ;;
        *)
            wd_logger 1 "ERROR: 'diff before_make.txt after_make.txt' => ${rc}:\n$(< diff.log)"
            exit 1
    esac

    ### This is a hack until Phil accepts Scott's version of pcmrecorder which  supports the -W and -q flags
    if ! [[ -f pcmrecord.c ]]; then
        wd_logger 2 "WD no longer stores Scott's version of pcmrecord.c, so Phil has integrated it"
    else
        if diff -q pcmrecord.c  ${project_subdir}/pcmrecord.c > /dev/null ; then
            wd_logger 2 "WD's pcmrecord matches the one in ka9q-radio/"
        else
            wd_logger 1 "Installing Scott's version of pcmrecord.c"
            cp pcmrecord.c  ${project_subdir}/pcmrecord.c
            (cd ${project_subdir} ; make)
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: failed to build Scott's version of pcmrecord.c"
            else
                wd_logger 1 "Built Scott's version of pcmrecord.c"
            fi
        fi
    fi

    ### KA9Q installed, so see if it needs to be started or restarted
    local ka9q_runs_only_remotely
    get_config_file_variable "ka9q_runs_only_remotely" "KA9Q_RUNS_ONLY_REMOTELY"
    if [[ ${ka9q_runs_only_remotely} == "yes" ]]; then
        if [[ ${PCMRECORD_ENABLED-yes} == "yes" && -x ${KA9Q_RADIO_PCMRECORD_CMD} ]]; then
            wd_logger 2 "KA9Q software wasn't updated and WD needs only the executable '${KA9Q_RADIO_PCMRECORD_CMD}' which exists. So nothing more to do"
            return 0
        elif [[ -x ${KA9Q_RADIO_WD_RECORD_CMD} ]]; then
            wd_logger 2 "KA9Q software wasn't updated and WD needs only the executable '${KA9Q_RADIO_WD_RECORD_CMD}' which exists. So nothing more to do"
            return 0
        else
            wd_logger 1 "ERROR: KA9Q software wasn't updated and only needs the executable 'pcmrecord' or 'wd-record', but it isn't present"
            exit 1
        fi
    fi

    ### We are configured to decode from a local RX888.  
    if ! getent group "radio" > /dev/null 2>&1; then
        wd_logger 1 "ERROR: the group 'radio' which should have been created by KA9Q-radio doesn't exist"
        exit 1
    fi
    if id -nG "${USER}" | grep -qw "radio" ; then
        wd_logger 2 "'${USER}' is a member of the group 'radio', so we can proceed to create and/or create the radiod@conf file needed to run radios"
    else
        sudo usermod -aG radio ${USER}
        wd_logger 1 "NOTE: Needed to add user '${USER}' to the group 'radio', so YOU NEED TO logout/login to this server before KA9Q services can run"
        exit 1
    fi
 
    if [[ ! -d ${KA9Q_RADIOD_CONF_DIR} ]]; then
        wd_logger 1 "ERROR: can't find expected KA9Q-radio configuration directory '${KA9Q_RADIOD_CONF_DIR}'"
        exit 1
    fi
 
    ### Setup the radiod@conf files before starting or restarting it
    local ka9q_conf_name
    get_config_file_variable  "ka9q_conf_name" "KA9Q_CONF_NAME"
    if [[ -n "${ka9q_conf_name}" ]]; then
        wd_logger 1 "KA9Q radiod is using configuration '${ka9q_conf_name}' found in the WD.conf file"
    else
        ka9q_conf_name="${KA9Q_DEFAULT_CONF_NAME}"
        wd_logger 2 "KA9Q radiod is using the default configuration '${ka9q_conf_name}'"
    fi
    local ka9q_conf_file_name="radiod@${ka9q_conf_name}.conf"
    local ka9q_conf_file_path="${KA9Q_RADIOD_CONF_DIR}/${ka9q_conf_file_name}"

    local radio_restart_needed="no"
    if [[ ! -f ${ka9q_conf_file_path} ]]; then
        if ! [[ -f ${KA9Q_TEMPLATE_FILE} ]]; then
            wd_logger 1 "ERROR: the conf file '${ka9q_conf_file_path}' for configuration ${ka9q_conf_name} does not exist"
            exit 1
        else
            wd_logger 1 "Creating ${ka9q_conf_file_path} from template ${KA9Q_TEMPLATE_FILE}"
            cp ${KA9Q_TEMPLATE_FILE} ${ka9q_conf_file_path}
            radio_restart_needed="yes"
        fi
    fi

    ### INI/CONF FILE        SECTION   VARIABLE  DESIRED VALUE
     local init_file_section_variable_value_list=(
    "${ka9q_conf_file_path}  rx888   gain         #"    ### Remark out any active gain = <INTEGER> lines so that RF AGC will be enabled
    "${ka9q_conf_file_path}  rx888   description 63"    ### avahi DNS names can be at most 63 characters and can't include '/' and other special chars, so error out if that isn't the case
    "${ka9q_conf_file_path}  WSPR    agc          0"
    "${ka9q_conf_file_path}  WSPR    gain         0"
    "${ka9q_conf_file_path}  WSPR    low       1300"
    "${ka9q_conf_file_path}  WSPR    high      1700"
    "${ka9q_conf_file_path}  WSPR    encoding float"
    "${ka9q_conf_file_path}  WWV-IQ  disable     no"
    "${ka9q_conf_file_path}  WWV-IQ  agc          0"
    "${ka9q_conf_file_path}  WWV-IQ  gain         0"
    "${ka9q_conf_file_path}  WWV-IQ  encoding float"
    )
    local index
    for (( index=0; index < ${#init_file_section_variable_value_list[@]}; ++index )); do
        wd_logger 2 "Checking .conf/.ini file variable with: 'update_ini_file_section_variable ${init_file_section_variable_value_list[index]}'"
        update_ini_file_section_variable ${init_file_section_variable_value_list[index]}
        rc=$?
        case $rc in
            0)
                wd_logger 2 "Made no changes"
                ;;
            1)
                wd_logger 1 "Made changes, so radiod restart is needed"
                radio_restart_needed="yes"
                  ;;
            *)
                 wd_logger 1 "ERROR: 'update_ini_file_section_variable ${init_file_section_variable_value_list[index]}' => $rc"
                 exit 1
                 ;;
         esac
    done
    if grep -q "m[0-9]*k" ${ka9q_conf_file_path} ; then
        ### 3/12/25 - RR   The template radiod@rx888-wsprdaemon.conf included in Ka9q-radio installations to date includes an invalid 17m FT4 band frequency specification "18m10k000"
        ###           This section repairs that and any other similarly corrupted frequency specs
        wd_logger 1 "Fixing corrupt frequency value(s) '$(grep -oE "m[0-9]*k" ${ka9q_conf_file_path})' found in  ${ka9q_conf_file_path}"
        sed -i -E 's/(m[0-9]*)k/\1/g' ${ka9q_conf_file_path}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'sed -i -E 's/(m[0-9]*)k/\1/g' ${ka9q_conf_file_path}' => $rc, so failed to correct corrupt freq line(s)"
        else
            wd_logger 1 "Fixed correct corrupt freq line(s), so restart radiod"
            radio_restart_needed="yes"
        fi
    fi

   ### Make sure the wisdomf needed for effecient execution of radiod exists
    if [[ -f  ${KA9Q_RADIO_NWSIDOM} ]]; then
        wd_logger 2 "Found ${KA9Q_RADIO_NWSIDOM} used by radio, so no need to create it"
    else
        wd_logger 1 "Didn't find ${KA9Q_RADIO_NWSIDOM} by radiod, so need to create it.  This may take minutes or even hours..."
        cd ${KA9Q_RADIO_ROOT_DIR}
        time fftwf-wisdom -v -T 1 -o nwisdom rof3240000 rof1620000 cob162000 cob81000 cob40500 cob32400 cob16200 cob9600 cob8100 cob4860 cob4800 cob3240 cob1920 cob1620 \
                                             cob1200 cob960 cob810 cob800 cob600 cob480 cob405 cob400 cob320 cob300 cob205 cob200 cob160 cob85 cob45 cob15
        rc=$?
        cd - > /dev/null
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to 'time fftwf-wisdom -v -T 1 -o nwisdom rof3240000 rof500000...'"
            return 3
        fi
        if [[ ! -f ${KA9Q_RADIO_NWSIDOM} ]]; then
            wd_logger 1 "ERROR: can't find expected '${KA9Q_RADIO_NWSIDOM}'"
            return 3
        fi
        wd_logger 1 "${KA9Q_RADIO_NWSIDOM} has been created"
    fi

    if [[ ! -f ${FFTW_WISDOMF} || ${KA9Q_RADIO_NWSIDOM} -nt ${FFTW_WISDOMF} ]]; then
        if [[ -f ${FFTW_WISDOMF} ]]; then
            wd_logger 1 "Backing up the exisitng ${FFTW_WISDOMF} to ${FFTW_WISDOMF}.save before installing a new ${KA9Q_RADIO_NWSIDOM}"
            sudo cp -p ${FFTW_WISDOMF} ${FFTW_WISDOMF}.save
        fi
        wd_logger 1 "Copying ${KA9Q_RADIO_NWSIDOM} to ${FFTW_WISDOMF}"
        sudo cp -p ${KA9Q_RADIO_NWSIDOM} ${FFTW_WISDOMF}
        local dir_user_group=$(stat --printf "%U:%G" ${FFTW_DIR})
        sudo chown ${dir_user_group} ${FFTW_WISDOMF}
        wd_logger 1 "Changed ownership of ${FFTW_WISDOMF} to ${dir_user_group}"
        radio_restart_needed="yes"
    fi
    wd_logger 2 "${FFTW_WISDOMF} is current"

    ### Make sure the udev permissions are set to allow radiod access to the RX888 on the USB bus
    wd_logger 2 "Instructing the udev system to give radiod permissions to access the RX888"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sudo chmod g+w ${KA9Q_RADIOD_LIB_DIR}

    local cpu_core_count=$( grep -c '^processor' /proc/cpuinfo )
    if (( cpu_core_count < 6 )); then
        wd_logger 2 "Found only ${cpu_core_count} cores, so don't restrict which cores it can run on"
    else
        local radiod_cores
        if [[ -n "${RADIOD_CPU_CORES+set}" ]]; then
             radiod_cores="$RADIOD_CPU_CORES"
             wd_logger 1 "RADIOD_CPU_CORES='$RADIOD_CPU_CORES' in WD.conf, so configure radiod to run in those cores"
         else
             radiod_cores="$(< /sys/devices/system/cpu/cpu0/topology/thread_siblings_list )"
             wd_logger 2 "This CPU has ${cpu_core_count} cores, so restrict radiod to cores ${radiod_cores}"
        fi
        local radio_service_file_path="/etc/systemd/system/radiod@.service"
        update_ini_file_section_variable "$radio_service_file_path"  "Service" "CPUAffinity" "$radiod_cores"
        rc=$?
        case $rc in
            0)
                wd_logger 2 "Made no changes to ${radio_service_file_path}"
                ;;
            1)
                wd_logger 1 "Made changes to ${radio_service_file_path}, so 'sudo systemctl daemon-reload' and radiod restart is needed"
                sudo systemctl daemon-reload
                rc=$? ; if (( rc )); then
                    wd_logger 1 "'sudo systemctl daemon-reload' => $rc after change to  ${radio_service_file_path}"
                    exit 1
                fi
                radio_restart_needed="yes"
                ;;
            *)
                wd_logger 1 "ERROR: 'update_ini_file_section_variable ${radio_service_file_path}' => $rc"
                exit 1
                ;;
        esac
    fi

    if ! lsusb | grep -q "Cypress Semiconductor Corp" ; then
        wd_logger 1 "KA9Q-radio software is installed and configured, but can't find a RX888 MkII attached to a USB port!"
        exit 1
    fi
    wd_logger 2 "Found a RX888 MkII attached to a USB port."

    if [[  ${radio_restart_needed} == "no" ]] ; then
        sudo systemctl is-active radiod@${ka9q_conf_name} > /dev/null
        rc=$? ; if (( rc == 0 )); then
            wd_logger 2 "The installiation and configuration checks found no changes were needed and radiod is running, so nothing more to do"
            return 0
        fi
        wd_logger 1 "The installation and configuration checks found no changes were needed but radiod is not running, so we need to start it"
    else
        wd_logger 1 "Installation and configuration checks made changes that require radiod to be started/restarted"
    fi
    if sudo systemctl restart radiod@${ka9q_conf_name}  > /dev/null ; then
        wd_logger 2 "KA9Q-radio was started"
        return 0
    else
       wd_logger 2 "KA9Q-radio failed to start"
       return 1
    fi

}

#function test_get_conf_section_variable() {
#    get_conf_section_variable "test_value" /etc/radio/radiod@rx888-wsprdaemon.conf FT8 "data"
#}
#declare test_value
#test_get_conf_section_variable
#printf "%s\n" ${test_value}
#exit
declare KA9Q_FT_TMP_ROOT="${KA9Q_FT_TMP_ROOT-/var/lib/ka9q-radio}"             ### Configure the dameon with runspcmrecord to put its wav files here is subdirs under here

declare KA9Q_DECODE_FT_CMD="/usr/local/bin/decode_ft8"               ### hacked code which decodes both FT4 and FT8 
declare KA9Q_FT8_LIB_REPO_URL="https://github.com/ka9q/ft8_lib.git" ### Where to get that code
declare KA9Q_DECODE_FT8_DIR="${WSPRDAEMON_ROOT_DIR}/ft8_lib"        ### Like ka9q-radio, ka9q-web amd onion, build 'decode-ft' in a subdirectory of WD's home

function ka9q-ft-setup() 
{
    local rc

    local ka9q_runs_only_remotely
    get_config_file_variable "ka9q_runs_only_remotely" "KA9Q_RUNS_ONLY_REMOTELY"
    if [[ ${ka9q_runs_only_remotely} == "yes" ]]; then
        wd_logger 1 "KA9Q_RUNS_ONLY_REMOTELY=='yes', so don't install the FT8/4 services"
        return 0
    fi

    local ft_type=${1}        ## must be 'ft4' or 'ft8'

    local ka9q_ft_tmp_dir=${KA9Q_FT_TMP_ROOT}/${ft_type}       ### The ftX-decoded will create this directory and put the wav files it needs in it.  We don't need to create it.

    ### Since May 2025 ka9q-radio decodes of each FT4/8 band is performed by a pair of systemctl daemons.
    ### The ftX-decode dameon reads wav files created by the ftX-record daemon (which is an instance of pcmrecord).
    ### It is created by a 'sudo make install' in the ka9q-radion directory and doesn't need any per-site customization

    ### First stop and deactivate the legacy ftX-decodd.service
    local legacy_ft_decoded_service_name="${ft_type}-decoded.service"
    local legacy_ft_decoded_service_file_path="/etc/systemd/system/${legacy_ft_decoded_service_name}"
    sudo systemctl list-unit-files | grep -q ${legacy_ft_decoded_service_name}
    rc=$? ; if (( rc )); then
        wd_logger 2 "Found no legacy ${legacy_ft_decoded_service_name} which would need to be disabled"
    else
        wd_logger 1 "Found a legacy ${legacy_ft_decoded_service_name} which needs to be stopped and disabled"
        sudo systemctl stop    ${legacy_ft_decoded_service_name}
        sudo systemctl disable ${legacy_ft_decoded_service_name}
        sudo rm ${legacy_ft_decoded_service_file_path}
        sudo systemctl daemon-reexec
    fi

    local service_restart_needed="no"
    local ft_decode_service_file_name="${ft_type}-decode@.service"
    local ft_decode_systemd_service_file_path="/etc/systemd/system/${ft_decode_service_file_name}"
    if [[ -f ${ft_decode_systemd_service_file_path} ]]; then
        wd_logger 2 "Found the expected service file '${ft_decode_systemd_service_file_path}'"
    else
        wd_logger 1 "Can't find the service file '${ft_decode_systemd_service_file_path}' because it is not automatically installed by ka9q-radio" 
        local ka9q_template_ft_decode_service_file_path="${KA9Q_RADIO_DIR}/service/${ft_decode_service_file_name}"
        if [[ ! -f ${ka9q_template_ft_decode_service_file_path} ]]; then
            wd_logger 1 "ERROR: can't find the expected template file ${ka9q_template_ft_decode_service_file_path}, so force an abort"
            echo ${force_abort}
        fi
        sudo cp -p ${ka9q_template_ft_decode_service_file_path} ${ft_decode_systemd_service_file_path}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'sudo cp -p ${ka9q_template_ft_decode_service_file_path} ${ft_decode_systemd_service_file_path}' => ${rc},  so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Copied the service file template ${ka9q_template_ft_decode_service_file_path} to ${ft_decode_systemd_service_file_path}"
        service_restart_needed="yes"
    fi
    ### We have the ftX-decode@.service file 

    ### To start it we need its conf file
    local ft_decode_conf_file_name="${ft_type}-decode.conf"
    local ka9q_ft_decode_conf_file_path="${KA9Q_RADIOD_CONF_DIR}/${ft_decode_conf_file_name}"
    if [[ ! -f ${ka9q_ft_decode_conf_file_path} ]]; then
        wd_logger 1 "Can't find expected ${ka9q_ft_decode_conf_file_path}, so copy the template file to it"
        local ka9q_template_ft_decode_conf_file_path="${KA9Q_RADIO_DIR}/config/${ft_decode_conf_file_name}"
        if [[ ! -f ${ka9q_template_ft_decode_conf_file_path} ]]; then
            wd_logger 1 "ERROR: can't file expected template file '${ka9q_template_ft_decode_conf_file_path}', so force an abort"
            echo ${force_abort}
        fi
        sudo sed '/^[[:space:]]*$/d' ${ka9q_template_ft_decode_conf_file_path} > ${ka9q_ft_decode_conf_file_path}     ### remove the blank lines from the template file
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'sudo cp -p ${ka9q_template_ft_decode_conf_file_path} ${ka9q_ft_decode_conf_file_path}' => ${rc}, so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Copied the conf file template ${ka9q_template_ft_decode_conf_file_path} to ${ka9q_ft_decode_conf_file_path}"
        service_restart_needed="yes"
    fi
    ### We have its conf file

    ### Start it up
    local ft_service_file_instance_name=${ft_decode_service_file_name/@/@1}
    if [[ ${service_restart_needed} == "no" ]] && sudo systemctl status ${ft_service_file_instance_name}  >& /dev/null; then
        wd_logger 2 "${ft_service_file_instance_name} is running and its conf file is never changed, so it doesn't need to be restarted"
    else
        wd_logger 1 "service_restart_needed='${service_restart_needed}' OR ${ft_service_file_instance_name} is not running, so it needs to be started"
        sudo systemctl daemon-reload
        sudo systemctl restart ${ft_service_file_instance_name}  >& /dev/null
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: failed to restart ${ft_service_file_instance_name} => ${rc}, so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Restarted service  ${ft_service_file_instance_name}"
    fi

    ### Ensure that it will run at startup
    if sudo systemctl is-enabled ${ft_service_file_instance_name} >& /dev/null ; then
        wd_logger 2 "${ft_service_file_instance_name} is enabled, so it doesn't need to be enabled"
    else
        wd_logger 1 "${ft_service_file_instance_name} is not enabled, so it needs to be enabled so it will start after a linux boot"
        sudo systemctl enable ${ft_service_file_instance_name} >& /dev/null
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: failed to enable ${ft_service_file_instance_name} => ${rc}, so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Enabled service ${ft_service_file_instance_name}"
    fi
    ### The ftX-decode daemon is set up

    ### Setup the ftX-record daemon
    ### The wav files are created by the ftX-record daemon which listens to the multicast stream defined in /etc/radio/radiod@.....conf and outputs a series of wav files
    ### Since sites with multiple RX88s will be sending to different MC addresses, the ftX-record dameon may need to be modified to listen on that MC address
    service_restart_needed="no"
    local ft_record_service_name="${ft_type}-record.service"           ### Unlike the new ftX-decode service above, the ftX-record service name and .service file name are the same
    local ft_record_service_file_name="${ft_record_service_name}"       
    local ft_record_systemd_service_file_path="/etc/systemd/system/${ft_record_service_file_name}"
    if [[ -f ${ft_record_systemd_service_file_path} ]]; then
        wd_logger 2 "Found the expected service file '${ft_record_systemd_service_file_path}'"
    else
        wd_logger 1 "Can't find the service file '${ft_record_systemd_service_file_path}' because it is not automatically installed by ka9q-radio" 
        local ka9q_template_ft_record_service_file_path="${KA9Q_RADIO_DIR}/service/${ft_record_service_file_name}"
        if [[ ! -f ${ka9q_template_ft_record_service_file_path} ]]; then
            wd_logger 1 "ERROR: can't find the expected template file ${ka9q_template_ft_record_service_file_path}, so force an abort"
            echo ${force_abort}
        fi
        sudo cp -p ${ka9q_template_ft_record_service_file_path} ${ft_record_systemd_service_file_path}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'sudo cp -p ${ka9q_template_ft_record_service_file_path} ${ft_record_systemd_service_file_path}' => ${rc},  so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Copied the service file template ${ka9q_template_ft_record_service_file_path} to ${ft_record_systemd_service_file_path}"
        service_restart_needed="yes"
    fi
    ### We have the ftX-record.service file 

    wd_logger 2 "Find the ka9q conf file"
    local radiod_conf_file_name
    ka9q-get-configured-radiod "radiod_conf_file_name"
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: can't find expected 'radiod_conf_file_name, so force an abort'"
        echo ${force_abort}
    fi
    wd_logger 2 "Found the radiod conf file is '${radiod_conf_file_name}'"

    wd_logger 2 "Find the multicast DNS name of the stream"
    local dns_name
    get_conf_section_variable "dns_name" ${radiod_conf_file_name} ${ft_type^^} "data"
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: can't find section ${ft_type^^} 'data =' line 'radiod_conf_file_name, so force an abort'"
        echo ${force_abort}
    fi
    wd_logger 2 "Found the multicast DNS name of the ${ft_type^^} stream is '${dns_name}'"

    local ft_record_conf_file_name="${ft_type}-decode.conf"     ### Counter-intuatively, the ftX-record.service file gets its MCAST from /etc/radio/ftX-decode.conf
    local ft_record_conf_file_path="${KA9Q_RADIOD_CONF_DIR}/${ft_record_conf_file_name}"
    local mcast_line="MCAST=${dns_name}"
    local directory_line="DIRECTORY=${ka9q_ft_tmp_dir}" 

    local needs_update="no"

    if [[ ! -f ${ft_record_conf_file_path} ]]; then
        wd_logger 1 "File '${ft_record_conf_file_path}' doesn't exist, so create it"
        touch ${ft_record_conf_file_path}
        needs_update="yes"
    fi
    if ! grep -q "${mcast_line}" ${ft_record_conf_file_path} ; then
        wd_logger 1 "File '${ft_record_conf_file_path}' doesn't contain the expected multicast line '${mcast_line}', so recreate the file"
        needs_update="yes"
    fi
    if ! grep -q "${directory_line}" ${ft_record_conf_file_path} ; then
         wd_logger 1 "File '${ft_record_conf_file_path}' doesn't contain the expected directory line '${directory_line}', so recreate the file"
        needs_update="yes"
    fi

    if [[ ${needs_update} != "yes" ]]; then
        wd_logger 2 "File '${ft_record_conf_file_path}' is correct, so no update is needed"
    else
        echo "${mcast_line}"      >  ${ft_record_conf_file_path}
        echo "${directory_line}"  >> ${ft_record_conf_file_path}
        wd_logger 1 "Created ${ft_record_conf_file_path} which contains:\n$(<  ${ft_record_conf_file_path})"
        service_restart_needed="yes"
    fi

    getent group "radio" > /dev/null 2>&1
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: the expected group 'radio' created by ka9q-radio doesn't exist, so force an abort"
        echo ${force_abort}
    fi

    local group_owner=$( stat -c "%G" ${ft_record_conf_file_path} )
    if [[ ${group_owner} != "radio" ]]; then
        wd_logger 1 "'${ft_record_conf_file_path}' is owned by group '${group_owner}', not the required group 'radio', so change the ownership"
        sudo chgrp "radio" ${ft_record_conf_file_path}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'sudo chgrp "radio" ${ft_record_conf_file_path}' => ${rc}, so force an abort"
            echo ${force_abort}
        fi
        service_restart_needed="yes"
    fi

    if [[ ${service_restart_needed} == "no" ]] && ! sudo systemctl status ${ft_record_service_name}  >& /dev/null; then
        wd_logger 1 "service_restart_needed='${service_restart_needed}' but ${ft_record_service_name} is not running, so it needs to be started"
        service_restart_needed="yes"
    else
        wd_logger 2 "${ft_record_service_name} is running and its conf file hasn't changed, so it doesn't need to be restarted"
    fi
    if [[ ${service_restart_needed} == "yes" ]]; then
        sudo systemctl restart ${ft_record_service_name}  >& /dev/null
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: failed to restart ${ft_record_service_name} => ${rc}, so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Restarted service ${ft_record_service_name}"
    fi
    if sudo systemctl is-enabled ${ft_record_service_name} >& /dev/null ; then
        wd_logger 2 "${ft_record_service_name} is enabled, so it doesn't need to be enabled"
    else
        wd_logger 1 "${ft_record_service_name} is not enabled, so it needs to be enabled so it will start after a linux boot"
        sudo systemctl enable ${ft_record_service_name} >& /dev/null
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: failed to enable ${ft_record_service_name} => ${rc}, so force an abort"
            echo ${force_abort}
        fi
        wd_logger 1 "Enabled service ${ft_record_service_name}"
    fi

    ### Ensure that the logrotate service is configured to archive the /var/log/ft[48].log files so they don't grow to an unbounded size
    local ft_log_file_name="/var/log/${ft_type}.log"
    local logrotate_job_file_path="/etc/logrotate.d/${ft_type}.rotate"
    local create_job_file="no"
    if [[ ! -f ${logrotate_job_file_path} ]]; then
        wd_logger 1 "Found no '${logrotate_job_file_path}', so create it"
        create_job_file="yes"
    elif ! grep -q 'maxsize'  ${logrotate_job_file_path}; then
         wd_logger 1 "Job file '${logrotate_job_file_path}' is missing the 'maxsize 1M' line, so recreate the file"
        create_job_file="yes"
    else
         wd_logger 2 "Logrotate file exists"
    fi
    if [[ ${create_job_file} == "yes" ]]; then
        echo "${ft_log_file_name} {
        maxsize 1M
        rotate 4
        daily
        missingok
        notifempty
        compress
        delaycompress
        copytruncate
} " > /tmp/${ft_type}.rotate
        sudo cp /tmp/${ft_type}.rotate ${logrotate_job_file_path}
        sudo chmod 644  ${logrotate_job_file_path}
        wd_logger 1 "Added new logrotate job '${logrotate_job_file_path}' to keep '${ft_log_file_name}' clean"
    else
        wd_logger 2 "Found '${logrotate_job_file_path}', so is configured properly so no need to change it"
    fi

    local target_file=$(sed -n 's;\(^/[^ ]*\).*;\1;p' ${logrotate_job_file_path})
    if [[ "${target_file}" == "${ft_log_file_name}" ]]; then
        wd_logger 2 "'${target_file}' is the required '${ft_log_file_name}' in '${logrotate_job_file_path}', so no changes are needed"
    else
        wd_logger 1 "'${target_file}' is not the required '${ft_log_file_name}' in '${logrotate_job_file_path}, so fix it'"
        sudo sed -i "s;^/[^{]*;${ft_log_file_name} ;" ${logrotate_job_file_path}
    fi

    wd_logger 2 "Setup complete"
    return 0
}

function build_ka9q_ft8() {
    local project_subdir=$1
    local project_logfile="${project_subdir}_build.log"
    local rc

    wd_logger 2 "Starting"
    ( cd ${project_subdir}; if make; then sudo make install ; fi ; exit $? ) >& ${project_logfile}
    rc=$? ; if (( rc )); then
        cd ${start_pwd} > /dev/null
        wd_logger 1 "ERROR: 'make' => ${rc}"
        return ${rc}
    fi

    local save_rc=0
    local ft_type
    for ft_type in ft8 ft4 ; do
        ka9q-ft-setup ${ft_type}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: ka9q-jt-setup() ${ft_type} => ${rc}"
            save_rc=${rc}
        else
            wd_logger 2 "Setup of ${ft_type} service is complete"
        fi
    done
    wd_logger 2 "Done"

   return 0
}

declare KA9Q_PSK_REPORTER_URL="https://github.com/pjsg/ftlib-pskreporter.git"
declare KA9Q_PSK_REPORTER_DIR="${WSPRDAEMON_ROOT_DIR}/ftlib-pskreporter"

function build_psk_uploader() {
    local project_subdir=$1
    local rc
    local psk_services_restart_needed="yes"

    wd_logger 2 "Start"
    if [[ ${KA9Q_RUNS_ONLY_REMOTELY-no} == 'yes' ]]; then
        wd_logger 1 "KA9Q_RUNS_ONLY_REMOTELY=='yes', so don't install psk_uploader"
        return 0
    fi

    python3 -c "import docopt" 2> /dev/null
    rc=$? ; if (( rc == 0 )) ; then
        wd_logger 2 "python docopt can be imported, so all needed libraries are presemt"
    else
        wd_logger 1 " python3 -c 'import  docopt' => ${rc}.  So run 'apt' to install it"
        sudo apt update
        sudo apt install python3-docopt
        rc=$? ; if (( rc == 0 )); then
            wd_logger 1 "'apt install python3-docopt' installed missing docopt"
        else
            pip3 -h >& /dev/null 
            rc=$? ; if (( rc == 0 )); then
                wd_logger 1 "pip3 is installed"
            else
                wd_logger 1 "pip3 -h => ${rc}.  So need to install pip3"
                sudo apt install python3-pip -y
                rc=$? ; if (( rc == 0 )); then
                    wd_logger 1 "apt installed pip3"
                else
                    wd_loggger 1 "ERROR: sudo apt install python-pip -> ${rc}, so force abort"
                    echo ${force_abort}
                fi
            fi
            local pip3_extra_args=""
            if [[ "${OS_RELEASE}" == "24.04" || "${OS_RELEASE}" == "12" ]]; then
                pip3_extra_args="--break-system-package"
                wd_logger 1 "Adding extra args to pip: ${pip3_extra_args}"
            fi
            pip3 install docopt ${pip3_extra_args}
            rc=$? ; if (( rc == 0 )); then
                wd_logger 1 "Successfully ran python3 -c 'import  docopt'"
            else
                wd_logger 1 "ERROR: 'pip3 install docopt' => ${rc}, so force abort"
                echo ${force_abort}
            fi
        fi
    fi

    ### Ensure that the two executables are in /usr/local/bin/
    local psk_executable_list=( pskreporter-sender  pskreporter.py )
    local executable_file
    for executable_file in ${psk_executable_list[@]}; do
        local template_file_path="$( realpath ${project_subdir}/${executable_file} )"
        local execute_dest_file_path="/usr/local/bin/${executable_file}"
        if [[ ! -f  ${execute_dest_file_path} ]]; then
            wd_logger 2 "${execute_dest_file_path} differs from ${template_file_path}, so update it"
            sudo cp -p ${template_file_path} ${execute_dest_file_path}
        fi
        if cmp ${template_file_path} ${execute_dest_file_path} ; then
            wd_logger 2 "${execute_dest_file_path} is up to date"
        else
            wd_logger 2 "${execute_dest_file_path} differs from ${template_file_path}, so update it"
            sudo cp -p ${template_file_path} ${execute_dest_file_path}
        fi
    done
 
    local pskreporter_service_file_name="pskreporter@.service"                                              ### This template file is part of the package
    local template_file_path="$(realpath ${project_subdir}/${pskreporter_service_file_name})"
    local pskreporter_systemd_service_file_path="/etc/systemd/system/${pskreporter_service_file_name}"      ### It should be copied to the /etc/systemd/system/ directory

    local needs_systemctl_daemon_reload="no"  
    local needs_systemctl_restart="no"  
    if [[ -f ${pskreporter_systemd_service_file_path} ]]; then
        wd_logger 2 "${pskreporter_systemd_service_file_path} exists.  Check to see if it needs to be updated"
    else
        local template_file_path="$(realpath ${project_subdir}/${pskreporter_service_file_name})"
        wd_logger 1 "Missing ${pskreporter_systemd_service_file_path}, so creating it from ${template_file_path}"
        sudo cp ${template_file_path} ${pskreporter_systemd_service_file_path}
        needs_systemctl_daemon_reload="yes"
    fi

    ### Update the service file if needed
    local tmp_service_file_path="/tmp/${pskreporter_systemd_service_file_path##*/}"
    cp -p ${pskreporter_systemd_service_file_path} ${tmp_service_file_path}
    if grep -q "User=recordings"  ${tmp_service_file_path} ; then
        sed -i "s/User=recordings/User=${USER}/"  ${tmp_service_file_path}
        wd_logger 1 "'Changed 'User=recordings' to 'User=${USER}' in  ${tmp_service_file_path}"
    fi
    if grep -q "Group=radio"  ${tmp_service_file_path} ; then
        local my_group=$(id -gn)
        sed -i "s/Group=radio/Group=${my_group}/"  ${tmp_service_file_path}
        wd_logger 1 "'Changed 'Group=radio' to 'Group=${my_group}}' in  ${tmp_service_file_path}"
    fi
    if ! grep -q "Environment=" ${tmp_service_file_path} ; then
        sed -i "/ExecStart=/i\\
        Environment=\"TZ=UTC\"" ${tmp_service_file_path}
        wd_logger 1 "Added 'Environment=\"TZ=UTC\"' to ${tmp_service_file_path}"
    fi
    ### add '--tcp' if it is missing
    sed -i '/ExecStart=.*pskreporter-sender/ {/--tcp/! s/pskreporter-sender/pskreporter-sender --tcp/}'  ${tmp_service_file_path}

    if diff ${tmp_service_file_path} ${pskreporter_systemd_service_file_path} > /dev/null ; then
        wd_logger 2 "The service file has not beeen changed"
    else
        wd_logger 1 "The service file needs to be changed, so update ${pskreporter_systemd_service_file_path}"
        sudo cp ${tmp_service_file_path} ${pskreporter_systemd_service_file_path}
        needs_systemctl_daemon_reload="yes"
    fi
    if [[ ${needs_systemctl_daemon_reload} == "yes" ]]; then
        wd_logger 1 "Beacuse ${tmp_service_file_path} changed we need to execute a 'sudo systemctl daemon-reload'.  Later, after the conf files have been modified or created, will also need to do a 'sudo systemctl restart...'"
        sudo systemctl daemon-reload 
        needs_systemctl_restart="yes"
    fi
 
    local ft_type 
    for ft_type in ft4 ft8 wspr; do
        local psk_conf_file="${KA9Q_RADIOD_CONF_DIR}/${ft_type}-pskreporter.conf"
        wd_logger 2 "Checking and updating  ${psk_conf_file}"
        if [[ ! -f ${psk_conf_file} ]]; then
            wd_logger 1 "Creating missing ${psk_conf_file}"
            touch ${psk_conf_file}
        fi
        local variable_line
        variable_line="MODE=${ft_type}"
        if grep -q "${variable_line}" ${psk_conf_file} ; then
            wd_logger 2 "Found the correct 'MODE=${ft_type}' line in ${psk_conf_file}, so no need to change ${psk_conf_file}"
        else
            grep -v "MODE=" ${psk_conf_file} > ${psk_conf_file}.tmp
            echo "${variable_line}" >> ${psk_conf_file}.tmp
            wd_logger 1 "Added or replaced invalid 'MODE=' line in  ${psk_conf_file} with '${variable_line}'"
            mv  ${psk_conf_file}.tmp  ${psk_conf_file}
            needs_systemctl_restart="yes"
        fi

        ### The decodes find the ftX.log and wspr.log files in /var/log
        local ft_type_tmp_root_dir="/var/log"

        local ft_type_log_file_name="${ft_type_tmp_root_dir}/${ft_type}.log"
        if [[ ! -f ${ft_type_log_file_name} ]]; then
            sudo touch ${ft_type_log_file_name}
            wd_logger 1 "WARNING: can't find expected file '${ft_type_log_file_name}'"
        fi

        local variable_line="FILE=${ft_type_log_file_name}"
        if grep -q "${variable_line}" ${psk_conf_file} ; then
            wd_logger 2 "Found the correct ${variable_line}' line in ${psk_conf_file}, so no need to change ${psk_conf_file}"
        else
            grep -v "FILE=" ${psk_conf_file} > ${psk_conf_file}.tmp
            echo "${variable_line}" >> ${psk_conf_file}.tmp
            wd_logger 1 "Added or replaced invalid 'FILE=' line in  ${psk_conf_file} with '${variable_line}'"
            mv  ${psk_conf_file}.tmp  ${psk_conf_file}
            needs_systemctl_restart="yes"
        fi

        local config_variable
        for config_variable in CALLSIGN LOCATOR ANTENNA; do
            local config_value
            wd_get_config_value "config_value" ${config_variable}
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: 'wd_get_config_value "config_value" ${config_variable}' => ${rc}, so force an abort"
                echo ${force_abort}
            fi
            local variable_line="${config_variable}=${config_value}"
            if grep -wq "${variable_line}" ${psk_conf_file} ; then
                wd_logger 2 "Found expected '${variable_line}' line in ${psk_conf_file}"
            else
                grep -v "${config_variable}=" ${psk_conf_file} > ${psk_conf_file}.tmp
                echo "${variable_line}" >> ${psk_conf_file}.tmp
                wd_logger 1 "Added or replaced invalid '${config_variable}=' line in ${psk_conf_file} with '${variable_line}'"
                mv  ${psk_conf_file}.tmp  ${psk_conf_file}
                needs_systemctl_restart="yes"
            fi
        done

        sudo systemctl status pskreporter@${ft_type} >& /dev/null
        rc=$? ; if (( rc )); then
            wd_logger 1 "'sudo systemctl status pskreporter@${ft_type}' => ${rc}, so restart it"
            needs_systemctl_restart="yes"
        fi

        if [[ ${needs_systemctl_restart} == "yes" || ${psk_services_restart_needed} == "yes" ]]; then
            wd_logger 2 "Executing a 'sudo systemctl restart "
            sudo systemctl restart pskreporter@${ft_type}
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: 'sudo systemctl restart pskreporter@${ft_type}' => ${rc}, so force an abort"
                echo ${force_abort}
            fi
        fi
        wd_logger 2 "Done checking and updating  ${psk_conf_file}"
    done
    wd_logger 2 "Finished creating or updating the ftX-pskreporter.conf files"
    return 0
}

declare ONION_LIBS_NEEDED="libgnutls28-dev libgcrypt20-dev cmake"
if [[ ${OS_RELEASE} =~ 24.04 ]]; then
    ONION_LIBS_NEEDED="${ONION_LIBS_NEEDED} libgnutls30t64 libgcrypt20"
fi

function build_onion() {
    local project_subdir=$1
    local project_logfile="${project_subdir}-build.log"

    wd_logger 2 "Building ${project_subdir}"
    (
    cd ${project_subdir}
    mkdir -p build
    cd build
    cmake -DONION_USE_PAM=false -DONION_USE_PNG=false -DONION_USE_JPEG=false -DONION_USE_XML2=false -DONION_USE_SYSTEMD=false -DONION_USE_SQLITE3=false -DONION_USE_REDIS=false -DONION_USE_GC=false -DONION_USE_TESTS=false -DONION_EXAMPLES=false -DONION_USE_BINDINGS_CPP=false ..
    make
    sudo make install
    sudo ldconfig
    )     >& ${project_logfile}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
         wd_logger 1 "ERROR: compile of '${project_subdir}' returned ${rc}:\n$( < ${project_logfile} )"
         exit 1
     fi
     wd_logger 2 "Done"
    return 0
}

function build_ka9q_web() {
    local project_subdir=$1
    local project_logfile="${project_subdir}_build.log"

    wd_logger 2 "Building ${project_subdir}"
    (
    cd  ${project_subdir}
    make
    sudo make install
    ) >&  ${project_logfile}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: compile of 'ka9q-web' returned ${rc}:\n$(< ${project_logfile})"
        exit 1
    fi
    wd_logger 2 "Done"
    return 0
}

function install_github_project() {
    local project_subdir="$1"
    local project_commit_check="$2"    ## yes by default, but can be defined in WD.conf
    local project_run"$3"              ## yes by default, but can be defined in WD.conf
    local project_build_function="$4"
    local project_libs="${5//,/ }"
    local project_url="$6"
    local project_sha="$7"

    local rc

    wd_logger 2 "In subdir '${project_subdir}' install libs '${project_libs}' and then ensure installation of '${project_url}' with commit COMMIT '${project_sha}'"

    if [[ ${project_libs} != "NONE" ]] && ! install_dpkg_list ${project_libs}; then
        wd_logger 1 "ERROR: 'install_dpkg_list ${project_libs}' => $?"
        return 1
    fi
    wd_logger 2 "Packages required by this service have been checked and installed if needed"

    if [[ -d  ${project_subdir} ]]; then
        wd_logger 2 "An existing project needs to be checked"
        ( cd ${project_subdir}; git remote -v | grep -q "${project_url}" )   ### Run in a subshell which returnes the status returned by grep
        rc=$? ; if (( rc )); then
            echo wd_logger 1 "The clone of ${project_subdir} doesn't come from the configured ' ${project_url}', so delete the '${project_subdir}' directory so it will be re-cloned"
            rm -rf ${project_subdir}
        fi
    else
         wd_logger 1 "There is no existing project sub-dir which needs to be checked"
    fi

    if [[ ! -d ${project_subdir} ]]; then
        wd_logger 1 "Subdir ${project_subdir} does not exist, so 'git clone ${project_url}'"
        git clone ${project_url} >& git.log
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'git clone ${project_url} >& git.log' =>  ${rc}:\n$(< git.log)"
            exit 1
        fi
        wd_logger 1 "Successful 'git clone ${project_url}'"
    fi

    case ${project_commit_check} in
        no)
            wd_logger 1 "Skipping commit check for project '${project_subdir}'"
            ;;
        yes|main|master)
            local pull_commit_target=${project_sha}
            if [[ ${project_commit_check} != "yes" ]]; then
                 pull_commit_target=${project_commit_check}
                 wd_logger 1 "Project '${project_subdir}' has been configured to load the latest ${pull_commit_target} branch commit"
            fi
            local project_real_path=$( realpath  ${project_subdir} )
            wd_logger 2 "Ensure the correct COMMIT is installed by running 'pull_commit ${project_real_path} ${project_sha}'"
            pull_commit ${project_real_path} ${pull_commit_target}
            rc=$? ; if (( rc == 0 )); then
                wd_logger 2 "The ${project_subdir} software was current"
            elif (( rc == 1 )); then
                wd_logger 1 "KA9Q software was updated, so compile and install it"
            else
                wd_logger 1 "ERROR: git could not update KA9Q software"
                return 1
            fi
            ;;
        *)
            wd_logger 1 "ERROR: ${project_commit_check}=${project_commit_check}"
            exit 1
            ;;
    esac

    wd_logger 2 "Run ${project_build_function}() in ${project_subdir}"
    if ${project_build_function} ${project_subdir} ; then
        wd_logger 2 "Success: '${project_build_function} ${project_subdir}' => $?"
        return 0
    fi
    wd_logger 1 "ERROR: ${project_build_function} ${project_subdir} => $?"
    return 1
}

### The GITHUB_PROJECTS_LIST[] entries define additional Linux services which may be installed and started by WD.  Each line has the form:
### "~/wsprdaemon/<SUBDIR> check_git_commit[yes/no]  start_service_after_installation[yes/no] service_specific_bash_installation_function_name  linux_libraries_needed_list(comma-seperated)   git_url   git_commit_wanted   
declare GITHUB_PROJECTS_LIST=(
    "ka9q-radio        ${KA9Q_RADIO_COMMIT_CHECK-yes}   ${KA9Q_WEB_ENABLED-yes}     build_ka9q_radio    ${KA9Q_RADIO_LIBS_NEEDED// /,}  ${KA9Q_RADIO_GIT_URL-https://github.com/ka9q/ka9q-radio.git}             ${KA9Q_RADIO_COMMIT-d151593b8b57146c7acd547c3ee5a0fcbc42a49e}"
    "ft8_lib           ${KA9Q_FT8_COMMIT_CHECK-yes}     ${KA9Q_FT8_ENABLED-yes}     build_ka9q_ft8      NONE                            ${KA9Q_FT8_GIT_URL-https://github.com/ka9q/ft8_lib.git}                    ${KA9Q_FT8_COMMIT-bc1fc691b20de6d0b2f378d24518fb671cdfaf80}"
    "ftlib-pskreporter ${PSK_UPLOADER_COMMIT_CHECK-yes} ${PSK_UPLOADER_ENABLED-yes} build_psk_uploader  NONE                            ${PSK_UPLOADER_GIT_URL-https://github.com/pjsg/ftlib-pskreporter.git}  ${PSK_UPLOADER_COMMIT-8e48695a5e65c7605383a2a4128116b95f3353a9}"
    "onion             ${ONION_COMMIT_CHECK-yes}        ${ONION_ENABLED-yes}        build_onion         ${ONION_LIBS_NEEDED// /,}       ${ONION_GIT_URL-https://github.com/davidmoreno/onion}                         ${ONION_COMMIT-de8ea938342b36c28024fd8393ebc27b8442a161}"
    "ka9q-web          ${KA9Q_WEB_COMMIT_CHECK-yes}     ${KA9Q_WEB_ENABLED-yes}     build_ka9q_web      NONE                            ${KA9Q_WEB_GIT_URL-https://github.com/wa2n-code/ka9q-web}                  ${KA9Q_WEB_COMMIT-2baa680410ba9ced5af661dce67b6665d2e541d7}"
)

###
function ka9q-services-setup() {
    local rc
    wd_logger 2 "Starting in ${PWD} and checking on ${#GITHUB_PROJECTS_LIST[@]} github projects"

    local index
    for (( index=0; index < ${#GITHUB_PROJECTS_LIST[@]}; ++index))  ; do
        local project_info="${GITHUB_PROJECTS_LIST[index]}"
        local project_info_list=( ${project_info} )
        local project_enabled="${project_info_list[2]}"
        if [[ ${project_enabled} != "yes" ]]; then
            wd_logger 1 "Project '${project_info_list[0]}' is disabled, so don't install and start it"
        else
            wd_logger 2 "Setup project '${project_info}'"
            if ! install_github_project ${project_info} ; then
                wd_logger 1 "ERROR: 'install_dpkg_list ${project_info}' => $?"
                exit 1
            fi
        fi
    done
    wd_logger 2 "Done and exiting"

   return 0
}

###
function ka9q-setup() {    
    wd_logger 2 "Starting in ${PWD}"

    local active_receivers
    get_list_of_active_real_receivers "active_receivers"
    if ! [[ "${active_receivers}" =~ KA9Q ]]; then
        wd_logger 2 "There are no KA9Q receivers in the conf file, so skip KA9Q setup"
        return 0
   fi
    wd_logger 2 "There are KA9Q receivers in the conf file, so set up KA9Q"
 
    ka9q-services-setup
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: ka9q-services-setup() => ${rc}"
    else
        wd_logger 2 "All ka9q services are installed"
    fi

    return ${rc}
}
ka9q-setup
