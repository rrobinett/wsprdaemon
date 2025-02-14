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
            wd_logger 2 "You have asked for and are on the latest commit of the main branch"
        else
            wd_logger 1 "You have asked for but are not on the latest commit of the main branch, so update the local copy of the code"
            ( cd ${git_directory}; git restore pcmrecord.c ; git fetch origin && git checkout origin/${desired_git_sha} ) >& git.log
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: failed to update to latest commit:\n$(< git.log)"
            else
                 wd_logger 1 "Updated to latest commit"
            fi
        fi
        return ${rc}
    fi

    ### desired COMMIT SHA was specified
    local git_root="main"  ### Now github's default.  older projects like wsprdaemon have the root 'master'
    local current_commit_sha
    get_current_commit_sha current_commit_sha ${git_directory}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'get_current_commit_sha current_commit_sha ${git_director}' => ${rc}"
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
                    wd_logger 2 "Assigned ${__return_variable_name}=${receiver_call}"
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
    ( cd ${git_directory}; git log )  >& ${GIT_LOG_OUTPUT_FILE}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: directory ${git_directory} is not a git-created directory:\n$(< ${GIT_LOG_OUTPUT_FILE})"
        return 2
    fi
    local commit_sha=$( awk '/commit/{print $2; exit}' ${GIT_LOG_OUTPUT_FILE} )
    if [[ -z "${commit_sha}" ]]; then
        wd_logger 1 "ERROR: 'git log' output does not contain a line with 'commit' in it"
        return 3
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
        wd_logger 1 "radiod@${conf_name} is not running  on this server"
        return 0
    fi
    local rx_audio_low=$( awk '/^low =/{print $3;exit}' ${running_radiod_conf_file})     ### Assume that the first occurence of '^low' and '^high' is in the [WSPR] section
    local rx_audio_high=$( awk '/^high =/{print $3;exit}' ${running_radiod_conf_file})
    wd_logger 2 "In ${running_radiod_conf_file}: low = ${rx_audio_low}, high = ${rx_audio_high}"

    if [[ -z "${rx_audio_low}" || -z "${rx_audio_high}" ]]; then
        wd_logger 1 "ERROR: can't find the expected low and/or high settings in  ${running_radiod_conf_file}"
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
declare KA9Q_GET_STATUS_TRIES=5
declare KA9Q_METADUMP_WAIT_SECS=${KA9Q_METADUMP_WAIT_SEC-5}       ### low long to wait for a 'metadump...&' to complete
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
        wd_logger 1 "The ka9q-web service is not running"
        return 1
    fi
    local ka9q_pid_value
    ka9q_pid_value=$(echo "${ka9q_ps_line}" | awk '{print $2}')
    if [[ -z "${ka9q_pid_value}" ]]; then
        wd_logger 1 "ERROR: couldn't extract the pid value from this ps' line: '${ka9q_ps_line}"
        return 2
    fi
    if ! is_uint  "${ka9q_pid_value}" ]]; then
        wd_logger 1 "ERROR: couldn't extract a PID(unsigned integer) from the 2nd field of  this ps' line: '${ka9q_ps_line}"
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

    ka9q-get-conf-file-name  "ka9q_web_pid"  "ka9q_web_conf_file"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "Can't get ka9q-get-conf-file-name, so no local radiod is running. See if radiod is running remotely"
        avahi-browse -t -r _ka9q-ctl._udp 2> /dev/null | grep hf.*.local | sort -u  > avahi-browse.log
        local hf_locals_count=$(wc -l < avahi-browse.log)
        local status_dns=$( sed -n 's/.*\[\(.*\)\].*/\1/p'  avahi-browse.log )
        case ${hf_locals_count} in
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
                 wd_logger 1 "Found ${hf_locals_count} radiod iservers running on this LAN.  Chose which to listen to by adding a line to wsprdaemon.conf:\n$(<  avahi-browse.log)"
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
    wd_logger 1 "Starting loop by checking for DNS of status stream"

    local ka9q_radiod_status_dns
    ka9q-get-status-dns "ka9q_radiod_status_dns" >& /dev/null
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: failed to find the status DNS  => ${rc}"
    fi
    if [[ -z "${ka9q_radiod_status_dns}" ]]; then
        wd_logger 1 "ERROR: can't file ka9q_radiod_status_dns"
    else
        ka9q_service_daemons_list=()
        ka9q_service_daemons_list[0]="${ka9q_radiod_status_dns} ${KA9Q_WEB_IP_PORT-8081} ${KA9Q_WEB_TITLE:-WD_RX888}"         ### This is hack to get this one service imlmewntationb working

        local i
        for (( i=0; i < ${#ka9q_service_daemons_list[@]}; ++i )); do
            local  ka9q_service_daemon_info="${ka9q_service_daemons_list[i]}"

            wd_logger 1 "Running 'ka9q_web_service_daemon '${ka9q_service_daemon_info}'"
            ka9q_web_service_daemon ${ka9q_service_daemon_info}          ### These should be spawned off
            sleep 1
        done
    fi
}

function ka9q_web_service_daemon() {
    local status_dns_name=$1             ### Where to get the spectrum stream (e.g. hf.local)
    local server_ip_port=$2              ### On what IP port to offer the UI
    local server_description="${3//_/ }" ### The description string at the top of the UI page.  Change all '_' to ' '

    while true; do
        if [[ ! -x ${KA9Q_WEB_CMD} ]]; then
            wd_logger 1 "ERROR: can't find '${KA9Q_WEB_CMD}'. Sleep and check again"
            #exit 1
            wd_sleep 3
            continue
        fi
        local daemon_log_file="ka9q_web_service_${server_ip_port}.log"
        wd_logger 1 "Got status_dns_name='${status_dns_name}', IP port = ${server_ip_port}, server description = '${server_description}"
        ${KA9Q_WEB_CMD} ${WF_BIT_DEPTH_ARG--b1} -m ${status_dns_name} -p ${server_ip_port} -n "${server_description}" >& ${daemon_log_file}   ### DANGER: nothing limits the size of this log file!!!
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
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

### Given the path to an ini file like /etc/radio/radiod@rx888-wsprdemon.conf or ~/bin/frpc_wd.ini
### This function searches for a variable in a section and:
### 1)  If is isn't found, it adds the variable = value to the section
### 2)  If the variable is found it varifies its value and changes it if it differs
###     As a special case, if variable = '#', then remark out the line with a '#' as the first character of the line
### Created by chatgbt
function update_ini_file_section_variable() {
    local file="$1"
    local section="$2"
    local variable="$3"
    local new_value="$4"
    local rc=0

    if [[ ! -f "${file}" ]]; then
        wd_logger 1 "ERROR: ini file '${file}' does not exist"
        return 3
    fi

    # Escape special characters in section and variable for use in regex
    local section_esc=$(printf "%s\n" "$section" | sed 's/[][\/.^$*]/\\&/g')
    local variable_esc=$(printf "%s\n" "$variable" | sed 's/[][\/.^$*]/\\&/g')

    wd_logger 2 "In ini file $file edit or add variable $variable_esc in section $section_esc to have the value $new_value"

    # Check if section exists
    if ! grep -q "^\[$section_esc\]" "$file"; then
        # Add section if it doesn't exist
        wd_logger 1 "iERROR: expected section [$section] doesn't exist in '$file'"
        return 4
    fi

    # Find section start and end lines
    local section_start=$(grep -n "^\[$section_esc\]" "$file" | cut -d: -f1 | head -n1)
    local section_end=$(awk -v start=$section_start 'NR > start && /^\[.*\]/ {print NR-1; exit}' "$file")

    # If no next section is found, set section_end to end of file
    [[ -z "$section_end" ]] && section_end=$(wc -l < "$file")

    # Check if variable exists within the section
    if sed -n "${section_start},${section_end}p" "$file" | grep -q "^\s*$variable_esc\s*="; then
        ### The variable is defined.  see if it needs to be changed
        local temp_file="${file}.tmp"

        if [[ "$new_value" == "#" ]]; then
            wd_logger 1 "Remarking out one or more active '$variable_esc = ' lines in section [$section]"
            sed "${section_start},${section_end}s|^\(\s*$variable_esc\s*=\s*.*\)|# \1|" "$file" > "$temp_file"
        else
            wd_logger 2 "Maybe changing one or more active '$variable_esc = ' lines in section [$section] to $new_value"
            sed  "${section_start},${section_end}s|^\s*\($variable_esc\)\s*=\s*.*|\1=$new_value|" "$file" > "$temp_file"
        fi
        if ! diff "$file" "$temp_file" > diff.log; then
            wd_logger 1 "Changing section [$section] of $file:\n$(<diff.log)"
            mv "${temp_file}"  "$file"
            return 1
        else
            rm "${temp_file}"
            wd_logger 2 "Existing $variable_esc in section $section_esc already has the value $new_value, so nothing to do"
            return 0
        fi
    else
        # Append the variable inside the section
         if [[ "$new_value" == "#" ]]; then
            wd_logger 2 "Can't find an active '$variable_esc = ' line in section $section_esc, so there is no line to remark out with new_value='$new_value'"
            return 0
        else
            wd_logger 1 "variable '$variable_esc' was not in section [$section_esc] of file $file, so inserting the line '$variable=$new_value'"
            sed -i "${section_start}a\\$variable=$new_value" "$file"
            return 1
         fi
    fi
    ### Code should never get here
    return 2
}

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
            wd_logger 1 "New files were created, so run 'sudo make install"
            ( cd  ${project_subdir}; sudo make install ) >& ${project_logfile}
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
 
    ### Setup the radiod@conf files before starting or restarting  it
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
    "${ka9q_conf_file_path}  WSPR    agc          0"
    "${ka9q_conf_file_path}  WSPR    gain         0"
    "${ka9q_conf_file_path}  WSPR    low       1300"
    "${ka9q_conf_file_path}  WSPR    high      1700"
    "${ka9q_conf_file_path}  WSPR    encoding float"
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

   ### Make sure the wisdomf needed for effecient execution of radiod exists
    if [[ -f  ${KA9Q_RADIO_NWSIDOM} ]]; then
        wd_logger 2 "Found ${KA9Q_RADIO_NWSIDOM} used by radio, so no need to create it"
    else
        wd_logger 1 "Didn't find ${KA9Q_RADIO_NWSIDOM} by radiod, so need to create it.  This may take minutes or even hours..."
        cd ${KA9Q_RADIO_ROOT_DIR}
        time fftwf-wisdom -v -T 1 -o nwisdom rof1620000 cob9600 cob4800 cob1920 cob1200 cob960 cob800 cob600 cob480 cob400 cob320 cob300 cob200 cob160 cob150
        rc=$?
        cd - > /dev/null
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to 'time fftwf-wisdom -v -T 1 -o nwisdom rof500000...'"
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
    wd_logger 2 "Instructing the udev system to give radiod permissions to access the RS888"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    sudo chmod g+w ${KA9Q_RADIOD_LIB_DIR}

    local cpu_core_count=$( grep -c '^processor' /proc/cpuinfo )
    if (( cpu_core_count < 8 )); then
        wd_logger 1 "Found only ${cpu_core_count} cores, so don't resstrict radiod to cores"
    else
        local radiod_cores
        if [[ -n "${RADIOD_CPU_CORES+set}" ]]; then
             radiod_cores="$RADIOD_CPU_CORES"
             wd_logger 1 "RADIOD_CPU_CORES='$RADIOD_CPU_CORES' in WD.conf, so configure radiod to run in those cores"
         else
             radiod_cores="$(( cpu_core_count - ${RADIOD_RESERVED_CORES-2}))-$(( cpu_core_count - 1 ))"
             wd_logger 1 "This CPU has ${cpu_core_count} cores, so restrict radiod to cores ${radiod_cores}"
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
        wd_logger 1 "KA9Q-radio softwaare is installed and configured, but can't find a RX888 MkII attached to a USB port"
        exit 1
    fi
    wd_logger 2 "Found a RX888 MkII attached to a USB port"

    if [[  ${radio_restart_needed} == "no" ]] ; then
        sudo systemctl is-active radiod@${ka9q_conf_name} > /dev/null
        rc=$? ; if (( rc == 0 )); then
            wd_logger 2 "The installiation and configuration checks found no changes were needed and radiod is running, so nothing more to do"
            return 0
        fi
        wd_logger 1 "The installiation and configuration checks found no changes were needed but radiod is not running, so we need to start it"
    else
        wd_logger 1 "Istalliation and configuration checks made changes that require radiod to be started/restarted"
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
declare KA9Q_FT_TMP_ROOT="${KA9Q_FT_TMP_ROOT-/run}"             ### The KA9q FT decoder puts its wav files in the /tmp/ftX/... trees and logs spots to /var/log/ftX.log

declare KA9Q_DECODE_FT_CMD="/usr/local/bin/decode_ft8"               ### hacked code which decodes both FT4 and FT8 
declare KA9Q_FT8_LIB_REPO_URL="https://github.com/ka9q/ft8_lib.git" ### Where to get that code
declare KA9Q_DECODE_FT8_DIR="${WSPRDAEMON_ROOT_DIR}/ft8_lib"        ### Like ka9q-radio, ka9q-web amd onion, build 'decode-ft' in a subdirectory of WD's home

function ka9q-ft-setup() {
    local ka9q_runs_only_remotely
    get_config_file_variable "ka9q_runs_only_remotely" "KA9Q_RUNS_ONLY_REMOTELY"
    if [[ ${ka9q_runs_only_remotely} == "yes" ]]; then
        wd_logger 2 "KA9Q_RUNS_ONLY_REMOTELY=='yes', so don't install the FT8/4 services"
        return 0
    fi

    local ft_type=$1        ## can be 4 or 8
    local ka9q_ft_tmp_dir=${KA9Q_FT_TMP_ROOT}/${ft_type}       ### The ftX-decoded will create this directory and put the wav files it needs in it.  We don't need to create it.

    wd_logger 2 "Find the ka9q conf file"
    local rc
    local radiod_conf_file_name
    ka9q-get-configured-radiod "radiod_conf_file_name"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find expected 'radiod_conf_file_name'"
        return ${rc}
    fi
    wd_logger 2 "Found the radiod conf file is '${radiod_conf_file_name}'"

    wd_logger 2 "Find the multicast DNS name of the stream"
    local dns_name
    get_conf_section_variable "dns_name" ${radiod_conf_file_name} ${ft_type^^} "data"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find section ${ft_type^^} 'data =' line 'radiod_conf_file_name'"
        return ${rc}
    fi
    wd_logger 2 "Found the multicast DNS name of the ${ft_type^^} stream is '${dns_name}'"

    local decoded_conf_file_name="${KA9Q_RADIOD_CONF_DIR}/${ft_type}-decode.conf"
    local mcast_line="MCAST=${dns_name}"
    local directory_line="DIRECTORY=${ka9q_ft_tmp_dir}" 

    local needs_update="no"

    if [[ ! -f ${decoded_conf_file_name} ]]; then
        wd_logger 1 "File '${decoded_conf_file_name}' doesn't exist, so create it"
        needs_update="yes"
    elif ! grep -q "${mcast_line}" ${decoded_conf_file_name} ; then
         wd_logger 1 "File '${decoded_conf_file_name}' doesn't contain the expected multicast line '${mcast_line}', so recreate the file"
        needs_update="yes"
    elif ! grep -q "${directory_line}" ${decoded_conf_file_name} ; then
         wd_logger 1 "File '${decoded_conf_file_name}' doesn't contain the expected directory line '${directory_line}', so recreate the file"
        needs_update="yes"
    else
         wd_logger 2 "File '${decoded_conf_file_name}' is correct, so no update is needed"
    fi

    if [[ ${needs_update} == "yes" ]]; then
        echo "${mcast_line}"      >  ${decoded_conf_file_name}
        echo "${directory_line}"  >> ${decoded_conf_file_name}
        wd_logger 1 "Created ${decoded_conf_file_name} which contains:\n$(<  ${decoded_conf_file_name})"
    fi

    local rc
    getent group "radio" > /dev/null 2>&1
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: the expected group 'radio' created by ka9q-radio doesn't exist"
        return ${rc}
    fi

    local group_owner=$( stat -c "%G" ${decoded_conf_file_name} )
    if [[ ${group_owner} != "radio" ]]; then
        wd_logger 1 "'${decoded_conf_file_name}' is owned by group '${group_owner}', not the required group 'radio', so change the ownership"
        sudo chgrp "radio" ${decoded_conf_file_name}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 ""
            return ${rc}
        fi
    fi

    local needs_restart="no"
    local service_name="${ft_type}-decoded.service"

    if [[ ${needs_update} == "yes" ]]; then
        wd_logger 1 "We need to restart the '${service_name} because the conf file changed"
        needs_restart="yes"
    elif ! sudo systemctl status ${service_name}  >& /dev/null; then
        wd_logger 1 "${service_name} is not running, so it needs to be started"
        needs_restart="yes"
    else
        wd_logger 2 "${service_name} is running and its conf file hasn't changed, so it doesn't need to be restarted"
    fi
    if [[ ${needs_restart} == "yes" ]]; then
        local rc
        sudo systemctl restart ${service_name}  >& /dev/null
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to restart ${service_name} => ${rc}"
            return ${rc}
        fi
        wd_logger 1 "Restarted service  ${service_name}"
    fi

    ### When WD is running KA9Q's FTx decode services it could be configured to decode the wav files with WSJT-x's 'jt9' decoder,
    ### so create a bash script which can be run by ftX-decoded,
    ### But since jt9 can't decode ft4 wav files, WD continues to use the 'decode-ft8' program normally used by ka9q-radio.
    ### Since jt9 appears to be more sensitive than the FT4/8 decoder 'decode-ft8' specified by KA9Q-radio, create this script so that as some point in the future we can run jt9.
    ### In order that the jt9 spot line format matches that of 'decode-ft8', create a bash shell script which accepts the same arguments, runs jt9 and pipes its output through an awk script
    ### It is awkward to embed an awk script inline like this, but the alternative would be to add it to WD homne directory.  When we strt using jt9 we should put it there.

    sudo mkdir -p ${ka9q_ft_tmp_dir}
    sudo chmod 777 ${ka9q_ft_tmp_dir}
    local ka9q_ft_jt9_decoder="${ka9q_ft_tmp_dir}/wsjtx-ft-decoder.sh"
    wd_logger 2 "Creating ${ka9q_ft_jt9_decoder}  ft_type=${ft_type}"

    # execlp( Modetab[Mode].decode, Modetab[Mode].decode, "-f", freq, sp->filename, (char *)NULL);
    sudo rm -f ${ka9q_ft_jt9_decoder}
    echo -n "${JT9_CMD} -${ft_type#ft} \$3 | awk -v base_freq_ghz=\$2 -v file_name=\${3##*/} "             > ${ka9q_ft_jt9_decoder}
    echo    \''/^[0-9]/ {
            printf "%s %3d %4s %'\''12.1f ~ %s %s %s %s\n", 20substr(file_name,1,2)"/"substr(file_name,3,2)"/"substr(file_name,5,2)" "substr(file_name,8,2)":"substr(file_name,10,2)":"substr(file_name,12,2), $2, $3,
            ( (base_freq_ghz * 1e9) + $4), $6, $7, $8, $9}'\'           >>  ${ka9q_ft_jt9_decoder}
    chmod +x ${ka9q_ft_jt9_decoder}

    ### Create a service file for the psk uploader
    declare SYSTEMD_DIR="/etc/systemd/system"
    local ft_service_file_name="${SYSTEMD_DIR}/${ft_type}-decoded.service"
    local ft_log_file_name="/var/log/${ft_type}.log"

    local needs_new_service_file="no"
    if [[ ! -f ${ft_service_file_name} ]]; then
        wd_logger 1 "Can't find service file ${ft_service_file_name}"
        needs_new_service_file="yes"
    else
        local stdout_line="StandardOutput=append:${ft_log_file_name}"
        if ! grep -q "${stdout_line}" ${ft_service_file_name} ; then
            wd_logger 1 "Can't find correct stdout line in ${ft_service_file_name}, so recreate it" 
            needs_new_service_file="yes"
        fi
        if [[ ${ft_type} == "ft4" || ${ft_type} == "ft8" ]]; then
            wd_logger 2 "${ft_type} packets are proceessed by the 'decode-ft' command from ka9q-radio, so the Exec:.. line in the template .service files need not be changed"
            if [[ ! -x ${KA9Q_DECODE_FT_CMD} ]]; then
                wd_logger 1 "Can't find ' ${KA9Q_DECODE_FT_CMD}' which is used to decode ${ft_type} spots"
                ka9q-ft-install-decode-ft
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'ka9q-ft-install-decode-ft()' => ${rc}"
                    return ${rc}
                fi
                needs_new_service_file="yes"
                wd_logger 1 "Successfully installed  ${KA9Q_DECODE_FT_CMD}"
            fi
        elif [[ ${KA9Q_JT9_DECODING-no} == "yes" ]]; then
            if ! grep -q "${JT9_CMD}" ${ft_service_file_name}; then
                wd_logger 1 "Can't find ${JT9_CMD} in ${ft_service_file_name}, so recreate it"
                needs_new_service_file="yes"
            fi
        fi
    fi

    ### Earlier versons of WD put ft[48].log files in /dev/shm/wsprdaemon/...  Now that WD puts them in /var/log,
    ### ensure that the service file instructs systemctl to append stdout of the FT4/8 decoder to a /var/log/ft[48].log file
    if [[ ${needs_new_service_file} == "yes" ]]; then
        wd_logger 1 "Creating new service file ${ft_service_file_name}"
        local ka9q_service_template_dir="${KA9Q_RADIO_DIR}/service"
        local ka9q_ft_service_template_file_name="${ka9q_service_template_dir}/${ft_type}-decoded.service"
        local ka9q_ft_service_tmp_file_name="${KA9Q_FT_TMP_ROOT}/${ft_type}-decoded.service"

        cp ${ka9q_ft_service_template_file_name}                                                                                         ${ka9q_ft_service_tmp_file_name}
        sed -i "/User=/s/=.*/=${USER}/"                                                                                                  ${ka9q_ft_service_tmp_file_name}
        local my_primary_group=$(id -gn)
        sed -i "/GROUP=/s/=.*/=${my_primary_group}/"                                                                                     ${ka9q_ft_service_tmp_file_name}
        sed -i "/StandardOutput=append:/s;:.*;:${ft_log_file_name};"                                                                     ${ka9q_ft_service_tmp_file_name}
        #sed -i "/ExecStart=/s;=.*;=/usr/local/bin/jt-decoded -${ft_type#ft} -d \"\$DIRECTORY\" -x \"${ka9q_ft_jt9_decoder}\"  \$MCAST;"  ${ka9q_ft_service_tmp_file_name}
        sed -i "/ExecStart=/s;=.*;=/usr/local/bin/jt-decoded -${ft_type#ft} -d \"\$DIRECTORY\" \$MCAST;"                                 ${ka9q_ft_service_tmp_file_name}
        
        wd_logger 1 "Created a new service file ${ft_service_file_name} in  ${ka9q_ft_service_tmp_file_name}"
        if [[ -f ${ft_service_file_name} ]]; then
            sudo cp -p ${ft_service_file_name} ${ft_service_file_name}.old
        fi
        sudo cp  ${ka9q_ft_service_tmp_file_name} ${ft_service_file_name}
        sudo systemctl daemon-reload
        sudo systemctl restart ${ft_type}-decoded.service

        wd_logger 1 "Created new ${ft_type}-decoded.service file, daemon-reload, and restarted it" 
    else
        if ! sudo systemctl status ${ft_type}-decoded.service > /dev/null ; then
            wd_logger 2 "${ft_type}-decoded.service hasn't changed but it isn't running, so start it"
            sudo systemctl restart ${ft_type}-decoded.service
        else
            wd_logger 2 "${ft_type}-decoded.service hasn't changed and it is running, so nothing to do"
        fi
    fi

    ### CEnsure that the logrotate service is configured to archive the /var/log/ft[48].log files so they don't grow to an unbounded size
    local logrotate_job_file_name="/etc/logrotate.d/${ft_type}.rotate"
    local create_job_file="no"
    if [[ ! -f ${logrotate_job_file_name} ]]; then
        wd_logger 1 "Found no '${logrotate_job_file_name}', so create it"
        create_job_file="yes"
    elif ! grep -q 'maxsize'  ${logrotate_job_file_name}; then
         wd_logger 1 "Job file '${logrotate_job_file_name}' is missing the 'maxsize 1M' line, so recreate the file"
        create_job_file="yes"
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
        sudo cp /tmp/${ft_type}.rotate ${logrotate_job_file_name}
        sudo chmod 644  ${logrotate_job_file_name}
        wd_logger 1 "Added new logrotate job '${logrotate_job_file_name}' to keep '${ft_log_file_name}' clean"
    else
        wd_logger 2 "Found '${logrotate_job_file_name}', so check it"
    fi

    local target_file=$(sed -n 's;\(^/[^ ]*\).*;\1;p' ${logrotate_job_file_name})
    if [[ "${target_file}" == "${ft_log_file_name}" ]]; then
        wd_logger 2 "'${target_file}' is the required '${ft_log_file_name}' in '${logrotate_job_file_name}', so no changes are needed"
    else
        wd_logger 1 "'${target_file}' is not the required '${ft_log_file_name}' in '${logrotate_job_file_name}, so fix it'"
        sudo sed -i "s;^/[^{]*;${ft_log_file_name} ;" ${logrotate_job_file_name}
    fi

    wd_logger 2 "Setup complete"
}

function build_ka9q_ft8() {
    local project_subdir=$1
    local project_logfile="${project_subdir}_build.log"
    local rc

    wd_logger 2 "Starting"
    ( cd ${project_subdir}; if make; then sudo make install ; fi ; exit $? ) >& ${project_logfile}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${start_pwd} > /dev/null
        wd_logger 1 "ERROR: 'make' => ${rc}"
        return ${rc}
    fi

    local save_rc=0
    local ft_type
    for ft_type in ft8 ft4 ; do
        ka9q-ft-setup ${ft_type}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
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

    if ! python3 -c "import docopt" 2> /dev/null; then
        rc=$?
        wd_logger 1 " python3 -c 'import  docopt' => ${rc}.  So install it"
        if ! pip3 -h >& /dev/null ; then
            rc=$?
            wd_logger 1 "pip3 -h => ${rc}.  So install pipe"
            sudo apt install python3-pip -y
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_loggger 1 "ERROR: sudo apt install python-pip -> ${rc}"
                exit 1
            fi
            wd_logger 1 "apt installed pip3"
        fi
        local pip3_extra_args=""
        if [[ "${OS_RELEASE}" == "24.04" || "${OS_RELEASE}" == "12" ]]; then
            pip3_extra_args="--break-system-package"
        fi
        pip3 install docopt ${pip3_extra_args}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'pip3 install docopt' => ${rc}"
            return 2
        fi
        wd_logger 1 "Successfully ran python3 -c 'import  docopt'"
    fi

    local pskreporter_sender_file_name="${project_subdir}/pskreporter-sender"           ### This template file is part of the package
    local pskreporter_sender_bin_file_name="/usr/local/bin/pskreporter-sender"
    if [[ ! -x ${pskreporter_sender_bin_file_name} ]]; then
        wd_logger 1 "Copying ${pskreporter_sender_file_name} to ${pskreporter_sender_bin_file_name}"
        sudo cp ${pskreporter_sender_file_name} ${pskreporter_sender_bin_file_name}
        sudo chmod a+x  ${pskreporter_sender_bin_file_name}
    fi

    local pskreporter_service_file_name="${project_subdir}/pskreporter@.service"                ### This template file is part of the package
    local pskreporter_systemd_service_file_name="/etc/systemd/system/pskreporter@.service"      ### It should be copied to the /etc/systemd/system/ directory

    local needs_systemctl_daemon_reload="no"  
    local needs_systemctl_restart="no"  
    if [[ ! -f ${pskreporter_systemd_service_file_name} ]]; then
        wd_logger 2 "Missing ${pskreporter_systemd_service_file_name}, so creating it from ${pskreporter_service_file_name}"
        cp ${pskreporter_service_file_name} ${pskreporter_systemd_service_file_name}
        needs_systemctl_daemon_reload="yes"
    fi
    wd_logger 2 "${pskreporter_systemd_service_file_name} exists.  Check to see if it needs to be updated"

    ### Phil's repo expects the PSK command to be in /usr/local/bin, but WD runs it from under the WD hoem directory
    sed "s;/usr/local/bin;${KA9Q_PSK_REPORTER_DIR};" ${pskreporter_systemd_service_file_name} > ${pskreporter_systemd_service_file_name}.tmp
    if ! diff ${pskreporter_systemd_service_file_name} ${pskreporter_systemd_service_file_name}.tmp > /dev/null; then
        wd_logger 2 "${pskreporter_systemd_service_file_name} has been changed not no longer run from /usr/local/bin"
        mv ${pskreporter_systemd_service_file_name}.tmp ${pskreporter_systemd_service_file_name}
        needs_systemctl_daemon_reload="yes"
   fi
   if ! grep -q "WorkingDirectory" ${pskreporter_systemd_service_file_name} ; then
       sed -i "/ExecStart=/i\\
WorkingDirectory=${KA9Q_PSK_REPORTER_DIR}" ${pskreporter_systemd_service_file_name}
        wd_logger 2 "Added 'WorkingDirectory=${KA9Q_PSK_REPORTER_DIR}' to ${pskreporter_systemd_service_file_name}"
        needs_systemctl_daemon_reload="yes"
    fi
    if grep -q "User=recordings"  ${pskreporter_systemd_service_file_name} ; then
        sed -i "s/User=recordings/User=${USER}/"  ${pskreporter_systemd_service_file_name}
        wd_logger 2 "'Changed 'User=recordings' to 'User=${USER}' in  ${pskreporter_systemd_service_file_name}"
        needs_systemctl_daemon_reload="yes"
    fi
    if grep -q "Group=radio"  ${pskreporter_systemd_service_file_name} ; then
        local my_group=$(id -gn)
        sed -i "s/Group=radio/Group=${my_group}/"  ${pskreporter_systemd_service_file_name}
        wd_logger 2 "'Changed 'Group=radio' to 'Group=${my_group}}' in  ${pskreporter_systemd_service_file_name}"
        needs_systemctl_daemon_reload="yes"
    fi
    if ! grep -q "Environment=" ${pskreporter_systemd_service_file_name} ; then
       sed -i "/ExecStart=/i\\
Environment=\"TZ=UTC\"" ${pskreporter_systemd_service_file_name}
        wd_logger 2 "Added 'Environment=\"TZ=UTC\"' to ${pskreporter_systemd_service_file_name}"
        needs_systemctl_daemon_reload="yes"
    fi
    if [[ ${needs_systemctl_daemon_reload} == "yes" ]]; then
        wd_logger 2 "Beacuse the .service file changed, need to execute a 'sudo systemctl daemon-reload'.  Later, after the conf files have been modified or created, will also need to do a 'sudo systemctl restart...'"
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

        local ft_type_tmp_root_dir="/var/log"

        local ft_type_log_file_name="${ft_type_tmp_root_dir}/${ft_type}.log"
        if [[ ! -f ${ft_type_log_file_name} ]]; then
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
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'wd_get_config_value "config_value" ${config_variable}' => ${rc}"
                return ${rc}
            fi
            local variable_line="${config_variable}=${config_value}"
            if grep -q "${variable_line}" ${psk_conf_file} ; then
                wd_logger 2 "Found expected '${variable_line}' line in ${psk_conf_file}"
            else
                grep -v "${config_variable}=" ${psk_conf_file} > ${psk_conf_file}.tmp
                echo "${variable_line}" >> ${psk_conf_file}.tmp
                wd_logger 2 "Added or replaced invalid '${config_variable}=' line in  ${psk_conf_file} with '${variable_line}'"
                mv  ${psk_conf_file}.tmp  ${psk_conf_file}
                needs_systemctl_restart="yes"
            fi
        done

        sudo systemctl status pskreporter@${ft_type} > /dev/null
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 2 "'sudo systemctl status pskreporter@${ft_type}' => ${rc}, so restart it"
            needs_systemctl_restart="yes"
        fi

        if [[ ${needs_systemctl_restart} == "yes" || ${psk_services_restart_needed} == "yes" ]]; then
            wd_logger 2 "Executing a 'sudo systemctl restart "
            sudo systemctl restart pskreporter@${ft_type}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'sudo systemctl restart pskreporter@${ft_type}' => ${rc}"
                return ${rc}
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

    wd_logger 2 "In subdir '${project_subdir}' install libs '${project_libs}' and then ensure installation of '${project_url}' with commit COMMIT '${project_sha}'"

    if [[ ${project_libs} != "NONE" ]] && ! install_dpkg_list ${project_libs}; then
        wd_logger 1 "ERROR: 'install_dpkg_list ${project_libs}' => $?"
        exit 1
    fi

    if [[ -d  ${project_subdir} ]]; then
        local rc
        ( cd ${project_subdir}; git remote -v | grep -q "${project_url}" )   ### Run in a subshell which returnes the status returned by grep
        rc=$? ; if (( rc )); then
            echo wd_logger 1 "The clone of ${project_subdir} doesn't come from the configured ' ${project_url}', so delete the '${project_subdir}' directory so it will be re-cloned"
            rm -rf ${project_subdir}
        fi
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
        wd_logger 1 "Success: '${project_build_function} ${project_subdir}' => $?"
        return 0
    fi
    wd_logger 1 "ERROR: ${project_build_function} ${project_subdir} => $?"
    return 1
}

### The GITHUB_PROJECTS_LIST[] entries define additional Linux services which may be installed and started by WD.  Each line has the form:
### "~/wsprdaemon/<SUBDIR> check_git_commit[yes/no]  start_service_after_installation[yes/no] service_specific_bash_installation_function_name  linux_libraries_needed_list(comma-seperated)   git_url   git_commit_wanted   
declare GITHUB_PROJECTS_LIST=(
    "ka9q-radio        ${KA9Q_RADIO_COMMIT_CHECK-yes}   ${KA9Q_WEB_EABLED-yes}      build_ka9q_radio    ${KA9Q_RADIO_LIBS_NEEDED// /,}  ${KA9Q_RADIO_GIT_URL-https://github.com/ka9q/ka9q-radio.git}             ${KA9Q_RADIO_COMMIT-14ac7cfe7d626a97b276e6b7232a733c8847a005}"
    "ft8_lib           ${KA9Q_FT8_COMMIT_CHECK-yes}     ${KA9Q_FT8_EABLED-yes}      build_ka9q_ft8      NONE                            ${KA9Q_FT8_GIT_URL-https://github.com/ka9q/ft8_lib.git}                    ${KA9Q_FT8_COMMIT-66f0b5cd70d2435184b54b29459bb15214120a2c}"
    "ftlib-pskreporter ${PSK_UPLOADER_COMMIT_CHECK-yes} ${PSK_UPLOADER_ENABLED-yes} build_psk_uploader  NONE                            ${PSK_UPLOADER_GIT_URL-https://github.com/pjsg/ftlib-pskreporter.git}  ${PSK_UPLOADER_COMMIT-9e6128bb8882df27f52e9fd7ab28b3888920e9c4}"
    "onion             ${ONION_COMMIT_CHECK-yes}        ${ONION_ENABLED-yes}        build_onion         ${ONION_LIBS_NEEDED// /,}       ${ONION_GIT_URL-https://github.com/davidmoreno/onion}                         ${ONION_COMMIT-de8ea938342b36c28024fd8393ebc27b8442a161}"
    "ka9q-web          ${KA9Q_WEB_COMMIT_CHECK-yes}     ${KA9Q_WEB_ENABLED-yes}     build_ka9q_web      NONE                            ${KA9Q_WEB_GIT_URL-https://github.com/scottnewell/ka9q-web}                ${KA9Q_WEB_COMMIT-12e92c39505580b04b091b734b0754747bf6c05d}"
)

###
function ka9q-services-setup() {
    local rc
    wd_logger 2 "Starting in ${PWD}"

    local index
    for (( index=0; index < ${#GITHUB_PROJECTS_LIST[@]}; ++index))  ; do
        local project_info="${GITHUB_PROJECTS_LIST[index]}"
        wd_logger 2 "Setup project '${project_info}'"
        if ! install_github_project ${project_info} ; then
            wd_logger 1 "ERROR: 'install_dpkg_list ${project_info}' => $?"
            exit 1
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
        wd_logger 1 "There are no KA9Q receivers in the conf file, so skip KA9Q setup"
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
