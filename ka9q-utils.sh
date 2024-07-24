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
declare KA9Q_RADIO_TUNE_CMD="${KA9Q_RADIO_ROOT_DIR}/tune"
declare KA9Q_GIT_URL="https://github.com/ka9q/ka9q-radio.git"
declare KA9Q_DEFAULT_CONF_NAME="rx888-wsprdaemon"
declare KA9Q_RADIOD_CONF_DIR="/etc/radio"

### These are the libraries needed by KA9Q, but it is too hard to extract them from the Makefile, so I just copied them here
declare KA9Q_PACKAGE_DEPENDANCIES="curl rsync build-essential libusb-1.0-0-dev libusb-dev libncurses5-dev libfftw3-dev libbsd-dev libhackrf-dev \
             libopus-dev libairspy-dev libairspyhf-dev librtlsdr-dev libiniparser-dev libavahi-client-dev portaudio19-dev libopus-dev"

declare KA9Q_RADIO_ROOT_DIR="${WSPRDAEMON_ROOT_DIR}/ka9q-radio"
declare KA9Q_RADIO_NWSIDOM="${KA9Q_RADIO_ROOT_DIR}/nwisdom"     ### This is created by running fft_wisdom during the KA9Q installation
declare FFTW_DIR="/etc/fftw"                                    ### This is the directory where radiod looks for a wisdomf
declare FFTW_WISDOMF="${FFTW_DIR}/wisdomf"                      ### This the wisdom file it looks for

declare KA9Q_REQUIRED_COMMIT_SHA="${KA8Q_REQUIRED_COMMIT_SHA-9cf48cf436ea5dbc50795c0311bf180af94b0e3e}"   ### Defaults to   Wed Jul 24 00:45:23 2024 -070
declare GIT_LOG_OUTPUT_FILE="${WSPRDAEMON_TMP_DIR}/git_log.txt"

###  function wd_logger() { echo $@; }        ### Only for use when unit testing this file

function get_current_commit_sha() {
    local __return_commit_sha_variable=$1
    local git_directory=$2
    local rc

    cd ${git_directory} >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't 'cd  ${git_directory}'"
        return 1
    fi
    git log >& ${GIT_LOG_OUTPUT_FILE}
    rc=$?
    cd - > /dev/null
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: directory ${git_directory} is not a git-created directory:\n$(< ${GIT_LOG_OUTPUT_FILE})"
        return 2
    fi
    local commit_sha=$( awk '/commit/{print $2; exit}' ${GIT_LOG_OUTPUT_FILE} )
    if [[ -z "${commit_sha}" ]]; then
        wd_logger 1 "ERROR: 'git log' output does not contain a line with 'commit' in it"
        return 3
    fi
    wd_logger 2 "'git log' is returning the current commit SHA = ${commit_sha}"
    eval ${__return_commit_sha_variable}=\${commit_sha}
    return 0
}

### Ensure that the set of source code in a git-managed directory is what you want
### Returns:  0 => already that SHA, so no change     1 => successfully checked out that commit SHA, else 2,3,4 ERROR in trying to execute
function pull_commit(){
    local git_directory=$1
    local desired_git_sha=$2
    local rc

    local save_pwd=${PWD}

    cd ${git_directory} >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${save_pwd}
        wd_logger 1 "ERROR: can't 'cd  ${git_directory}'"
        return 2
    fi
    local current_commit_sha
    get_current_commit_sha current_commit_sha $PWD
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${save_pwd}
        wd_logger 1 "ERROR: 'get_current_commit_sha current_commit_sha ${PWD}' => ${rc}"
        return 3
    fi
    if [[ "${current_commit_sha}" == "${desired_git_sha}" ]]; then
        cd ${save_pwd}
        wd_logger 2 "Current git commit SHA in ${PWD} is the expected ${current_commit_sha}"
        return 0
    fi
    wd_logger 2 "Current git commit SHA in ${PWD} is ${current_commit_sha}, not the desired SHA ${desired_git_sha}, so update the code from git"
    git checkout main >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${save_pwd}
        wd_logger 1 "ERROR: 'git checkout origin/main' => ${rc}"
        return 4
    fi
    git pull >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${save_pwd}
        wd_logger 1 "ERROR: 'git pull' => ${rc}"
        return 5
    fi
    git checkout ${desired_git_sha} >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${save_pwd}
        wd_logger 1 "ERROR: 'git checkout ${desired_git_sha}' => ${rc}"
        return 6
    fi
    cd ${save_pwd}
    wd_logger 1 "Successfully updated the ${git_directory} directory to SHA ${desired_git_sha}.  Returned to $PWD"
    return 1
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
declare KA9Q_METADUMP_LOG_FILE="${KA9Q_METADUMP_LOG_FILE-/dev/shm/wsprdaemon/ka9q_metadump.log}"   ### Put output of metadump here
declare KA9Q_METADUMP_STATUS_FILE="${KA9Q_STATUS_FILE-/dev/shm/wsprdaemon/ka9q.status}"            ### Parse the fields in that file into seperate lines in this file
declare KA9Q_MIN_LINES_IN_USEFUL_STATUS=20
declare KA9Q_GET_STATUS_TRIES=10
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
        wd_logger 1 "Getting new status information by executing 'metadump -c 2 -s ${receiver_freq_hz}  ${receiver_ip_address}'"
        metadump -c 2 -s ${receiver_freq_hz}  ${receiver_ip_address}  |  sed -e 's/ \[/\n[/g'  > ${status_log_file}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: ' metadump -s ${receiver_freq_hz}  ${receiver_ip_address} > ${status_log_file}' => ${rc}"
        else
            local status_log_line_count=$(wc -l <  ${status_log_file} )

            if [[ ${status_log_line_count} -gt ${KA9Q_MIN_LINES_IN_USEFUL_STATUS} ]]; then
                wd_logger 1 "Got useful status file"
                got_status="yes"
            else
                wd_logger 1 "WARNING: there are only ${status_log_line_count} lines in ${status_log_file}, so try again"
            fi
        fi
    done
    if [[  "${got_status}" == "no" ]]; then
        wd_logger 1 "ERROR: couldn't get useful status after ${KA9Q_GET_STATUS_TRIES}"
        return 1
    else
        wd_logger 1 "Got new status from:  'metadump -s ${receiver_freq_hz}  ${receiver_ip_address} > ${status_log_file}'"
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

function ka9q_get_current_status_value() {
    local __return_var="$1"
    local receiver_ip_address=$2
    local receiver_freq_hz=$3
    local search_val="$4"
    local rc

    local status_log_file="./ka9q_status.log"   ### each receiver+channel will have status fields unique to it, so there needs to be a file for each of them
    ka9q_get_metadump ${receiver_ip_address} ${receiver_freq_hz} ${status_log_file}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to get new status"
        return ${rc}
    fi

    local value_found
    ka9q_parse_status_value  value_found  ${status_log_file} "${search_val}"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to get new status"
        return ${rc}
    fi
    
    wd_logger 1 "Returning '${value_found}'"

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

declare KA9Q_WEB_PID_FILE_NAME="./ka9q-web.pid"

function ka9q-get-conf-file-name() {
    local __return_pid_var_name=$1
    local __return_conf_file_var_name=$2

    local ka9q_ps_line
    ka9q_ps_line=$( ps aux | grep "radiod@" | grep -v grep | head -n 14)

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
        wd_logger 1 "Can't get ka9q-get-conf-file-name, so radiod  must not be running"
        return 1
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
declare KA9Q_WEB_SETUP_LOG_FILE="${WSPRDAEMON_TMP_DIR}/ka9q_web_setup.log"

function ka9q_web_daemon() {

    while true; do
        if [[ ! -x ${KA9Q_WEB_CMD} ]]; then
            wd_logger 1 "ERROR: can't find '${KA9Q_WEB_CMD}'. Sleep and check again"
            #exit 1
            wd_sleep 3
            continue
        fi

       wd_logger 1 "Starting loop by checking for DNS of status stream"

        local ka9q_radiod_status_dns
        ka9q-get-status-dns "ka9q_radiod_status_dns" >& /dev/null
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to find the status DNS  => ${rc}"
        else
            wd_logger 1 "Got ka9q_radiod_status_dns='${ka9q_radiod_status_dns}'"
            ${KA9Q_WEB_CMD} -m ${ka9q_radiod_status_dns}  >& /dev/null
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: '${KA9Q_WEB_CMD} -m ${ka9q_radiod_status_dns}'=> ${rc}"
            fi
        fi
        wd_logger 1 "Sleeping for 5 seconds before restarting"
        wd_sleep 5
    done
}

#function test_ka9q-web-setup() {
#     ka9q-web-setup
#}
# test_ka9q-web-setup

### This is implemented as something of a hack which 
function ka9q-web-setup() {
    local rc
    wd_logger 2 "Starting in ${PWD}"

    if [[ -x ${KA9Q_WEB_CMD} ]]; then
        wd_logger 2 "Executable file '${KA9Q_WEB_CMD}' exists, so assume all of ka9q-web is installed"
        return 0
    fi
 
   # 1. install Onion framework dependencies
    local packages_needed="libgnutls28-dev libgcrypt20-dev cmake"
    if ! install_dpkg_list ${packages_needed}; then
        wd_logger 1 "ERROR: 'install_debian_package ${packages_needed}' => $?"
        exit 1
    fi

    # 2. build and install Onion framework
    if [[ ! -d onion ]]; then
        wd_logger 1 "Git is cloning a new copy of the 'onion' web server"
        git clone https://github.com/davidmoreno/onion >& ${KA9Q_WEB_SETUP_LOG_FILE}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR:  'git clone https://github.com/davidmoreno/onion ' => ${rc}:\n$(< ${KA9Q_WEB_SETUP_LOG_FILE})"
            return ${rc}
        fi
        wd_logger 1 "Git cloned a copy of the 'onion' web service"
    fi

    wd_logger 1 "Starting to compile 'onion' from dir $PWD"

    ( cd onion
    mkdir -p build
    cd build
    cmake -DONION_USE_PAM=false -DONION_USE_PNG=false -DONION_USE_JPEG=false -DONION_USE_XML2=false -DONION_USE_SYSTEMD=false -DONION_USE_SQLITE3=false -DONION_USE_REDIS=false -DONION_USE_GC=false -DONION_USE_TESTS=false -DONION_EXAMPLES=false -DONION_USE_BINDINGS_CPP=false ..
    make
    sudo make install
    sudo ldconfig)     >& ${KA9Q_WEB_SETUP_LOG_FILE}        ### Trucate log file and write the build stdout and stderr to the log file
    rc=$?

     if [[ ${rc} -ne 0 ]]; then
         wd_logger 1 "ERROR:  compile of 'onion' returned ${rc}"
         return ${rc}
     fi

    # 3. build and install ka9q-web
    wd_logger 1 "Finished compiling 'onion'.  Now get kan9q-web installed"

    if [[ ! -d ka9q-web ]]; then
        git clone https://github.com/fventuri/ka9q-web >& ${KA9Q_WEB_SETUP_LOG_FILE}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR:  'git clone https://github.com/fventuri/ka9q-web ' => ${rc}:\n$(< ${KA9Q_WEB_SETUP_LOG_FILE})"
            return ${rc}
        fi
        wd_logger 1 "Git cloned a copy of the 'ka9q-web' web service"
    fi

     wd_logger 1 "Starting to compile 'ka9q-web' from dir $PWD"
    ( cd ka9q-web
    make
    sudo make install) &>>  ${KA9Q_WEB_SETUP_LOG_FILE}  ### Append stdout and stderr to the log file
     rc=$?

     if [[ ${rc} -ne 0 ]]; then
         wd_logger 1 "ERROR:  compile of 'ka9q-web' returned ${rc}"
         return ${rc}
     fi

    wd_logger 1 "Finished compiling ka9q-web $PWD"

    if [[ ! -x ${KA9Q_WEB_CMD} ]]; then
        wd_logger 1 "ERROR: failed to create '${KA9Q_WEB_CMD}.  Here are the log lines from the builds:\n$(< ${KA9Q_WEB_SETUP_LOG_FILE}) '"
        return 1
    fi
    if ! ${KA9Q_WEB_CMD} -h |& grep -q "Usage" ; then 
        wd_logger 1 "ERROR: Created '${KA9Q_WEB_CMD}', but it fails to execute"
        return 2
    fi

    local ka9q_radiod_status_dns
    ka9q-get-status-dns "ka9q_radiod_status_dns"
    rc=$?
    if [[ ${rc} -ne 0  || -z "${ka9q_radiod_status_dns-}" ]]; then
        wd_logger 1 "Warning: failed to find the status DNS  => ${rc} OR {ka9q_radiod_status_dns is blank"
    fi
    return 0
}

function ka9q-radiod-setup()
{
    local rc
    wd_logger 2 "Starting in ${PWD}"

    local packages_needed="libnss-mdns mdns-scan avahi-utils avahi-discover"
    if ! install_dpkg_list ${packages_needed}; then
        wd_logger 1 "ERROR: 'install_debian_package ${packages_needed}' => $?"
        exit 1
    fi

    ### This has been called because A KA9Q rx has been configured, so we may need to install and compile ka9q-radio so that we can run the 'wd-record' command
    if [[ ! -d ${KA9Q_RADIO_DIR} ]]; then
        wd_logger 1 "ka9q-radio subdirectory doesn't exist, so 'get clone' to create it and populate with source code"
        git clone ${KA9Q_GIT_URL}
        rc=$?
        if [[ ${rc} -gt 1 ]]; then
            wd_logger 1 "ERROR: 'git clone ${KA9Q_GIT_URL}' > ${rc}"
            exit 1
        fi
    fi

    ### If KA9Q software was loaded or updated, then it will need to be compiled and installed
    local ka9q_make_needed="no"
    if [[ ${KA9Q_GIT_PULL_ENABLED-yes} == "no" ]]; then
        wd_logger 1 "Configured to not 'git pull' in the ka9q-radio/ directory"
    else
        pull_commit ${KA9Q_RADIO_DIR} ${KA9Q_REQUIRED_COMMIT_SHA}
        rc=$?
        if [[ ${rc} -eq 0 ]]; then
            wd_logger 2 "KA9Q software was current, so compiling and installing may not be needed.  Further checking will be done to determine it compiling is needed"
        elif [[  ${rc} -eq 1 ]]; then
            ka9q_make_needed="yes"
            wd_logger 1 "KA9Q software was updated, so compile and install it"
        else 
            wd_logger 1 "ERROR: git could not update KA9Q software"
            exit 1
        fi
        if [[ ! -L  ${KA9Q_RADIO_DIR}/Makefile ]]; then
            if [[ -f  ${KA9Q_RADIO_DIR}/Makefile ]]; then
                wd_logger 1 "ERROR:  ${KA9Q_RADIO_DIR}/Makefile doesn't exist or isn't a symbolic link to  ${KA9Q_RADIO_DIR}/Makefile.linux"
                rm -f ${KA9Q_RADIO_DIR}/Makefile
            fi
            wd_logger 1 "Creating a symbolic link from ${KA9Q_RADIO_DIR}/Makefile.linux to ${KA9Q_RADIO_DIR}/Makefile" 
            ln -s ${KA9Q_RADIO_DIR}/Makefile.linux ${KA9Q_RADIO_DIR}/Makefile
        fi
    fi

    local ka9q_conf_name
    get_config_file_variable  ka9q_conf_name "KA9Q_CONF_NAME"
    if [[ -n "${ka9q_conf_name}" ]]; then
        wd_logger 1 "KA9Q radiod is using configuration '${ka9q_conf_name}' found in the WD.conf file"
    else
        ka9q_conf_name="${KA9Q_DEFAULT_CONF_NAME}"
        wd_logger 2 "KA9Q radiod is using the default configuration '${ka9q_conf_name}'"
    fi

    if [[ ${ka9q_make_needed} == "no" ]]; then
        local ka9q_runs_only_remotely
        get_config_file_variable ka9q_runs_only_remotely "KA9Q_RUNS_ONLY_REMOTELY"
        if [[ ${ka9q_runs_only_remotely} == "yes" ]]; then
            if [[ -x ${KA9Q_RADIO_WD_RECORD_CMD} ]]; then
                wd_logger 2 "KA9Q software wasn't updated and WD needs only the executable 'wd-record' which exists. So nothing more to do"
                return 0
            fi
            wd_logger 1 "KA9Q software wasn't updated and only needs the executable 'wd-record' but it isn't present.  So compile and install all of KA9Q"
        else
            ### There is a local RX888.  Ensure it is properly configured and running
            if [[ ! $(groups) =~ radio ]]; then
                sudo adduser --quiet --system --group radio
                sudo usermod -aG radio ${USER}
                wd_logger 1 "NOTE: Needed to add user '${USER}' to the group 'radio', so YOU NEED TO logout/login to this server before KA9Q services can run"
            fi
            local ka9q_conf_file_name="radiod@${ka9q_conf_name}.conf"
            local ka9q_conf_file_path="${KA9Q_RADIOD_CONF_DIR}/${ka9q_conf_file_name}"
            if [[ ! -f ${ka9q_conf_file_path} ]]; then
                if [[ -f ${KA9Q_TEMPLATE_FILE} ]]; then
                    wd_logger 1 "Creating ${ka9q_conf_file_path} from template ${KA9Q_TEMPLATE_FILE}"
                    cp ${KA9Q_TEMPLATE_FILE} ${ka9q_conf_file_path}
                else
                    wd_logger 1 "ERROR: the conf file '${ka9q_conf_file_path}' for configuration ${ka9q_conf_name} does not exist"
                    exit 1
                fi
            fi
            if sudo systemctl status radiod@${ka9q_conf_name}  > /dev/null ; then
                wd_logger 2 "KA9Q software wasn't 'git pulled' and the radiod service '${ka9q_conf_name}' is running, so KA9Q is setup and running"
                return 0
            fi
            if sudo systemctl start radiod@${ka9q_conf_name}  > /dev/null ; then
                wd_logger 2 "KA9Q software wasn't 'git pulled' and the radiod service '${ka9q_conf_name}' was sucessfully started, so KA9Q is setup and running"
                return 0
            fi
            wd_logger 1 "KA9Q software wasn't 'git pulled', but the needed local radiod service '${ka9q_conf_name}' is not running, so compile and install all of KA9Q"
        fi
    fi

    sudo apt install -y ${KA9Q_PACKAGE_DEPENDANCIES} >& apt.log
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd - > /dev/null
        wd_logger 1 "ERROR: failed to install some or all of the libraries needed by ka9q-radio"
        return 1
    fi
    cd ${KA9Q_RADIO_DIR}
    if [[ ! -L Makefile ]]; then
        ln -s Makefile.linux Makefile
    fi
    make clean > /dev/null
    make  > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd - > /dev/null
        wd_logger 1 "ERROR: failed 'make' of new KA9Q software => ${rc}"
        return 1
    fi
    sudo make install > /dev/null
    rc=$?
    cd - > /dev/null
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed 'sudo make install' of new KA9Q software => ${rc}"
        return 1
    fi

    if [[ "${KA9Q_RUNS_ONLY_REMOTELY-no}" == "yes" ]]; then
        ### WD is not configured to install and confiugre a radiod daemon to run.  WD is only coing to run wd-record which created wav files from multicast streams coming for radiod on this and/or ptjher RX888 servers
        wd_logger 1 "WD.conf is configured to indicate that the wspr-pcm.local stream(s) all come from remote servers.  So WD doesn't need to configure or start radiod"
        return 0
    fi

    wd_logger 1 "WD is configured to get wav files from a loalRX888, so KA9Q's radiod service needs to run"

    if [[ -f  ${KA9Q_RADIO_NWSIDOM} ]]; then
        wd_logger 1 "Found ${KA9Q_RADIO_NWSIDOM} used by radio, so no need to create it"
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
    fi
    wd_logger 1 "${KA9Q_RADIO_NWSIDOM} exists"

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
    fi
    wd_logger 1 "${FFTW_WISDOMF} is current"

    wd_logger 1 "Stop any currently running instance of radiod in case there is a newly built version to be started"
    sudo systemctl stop  "radiod@*" > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "'sudo systemctl stop radiod@' => ${rc}, so no radiod was running.  Proceed to start it"
    fi
    if ! lsusb | grep -q "Cypress Semiconductor Corp" ; then
        wd_logger 1 "Can't find a RX888 MkII attached to a USB port"
        exit 1
    fi
    wd_logger 1 "Found a RX888 MkII attached to a USB port"

    ### Make sure the config doesn't have the broken low = 100, high = 5000 values
    ka9q_conf_file_bw_check ${ka9q_conf_name}

    sudo systemctl start  radiod@${ka9q_conf_name} > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'sudo systemctl start radiod@${ka9q_conf_name}' => ${rc}, so failed to start radiod"
    fi
    sudo systemctl is-active radiod@${ka9q_conf_name} > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: after an otherwise successful installation of KA9Q its 'radiod' is not active"
        return 1
    fi
    wd_logger 1 "after a successful installation of KA9Q its 'radiod' is active"
    return 0
}

function ka9q_setup()
{    
    wd_logger 2 "Starting in ${PWD}"

    ka9q-radiod-setup
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR:  ka9q-radiod-setup() => ${rc}"
        return ${rc}
    fi
    wd_logger 2 "ka9q-radiod-web is setup ${PWD}"

    ka9q-web-setup
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR:  ka9q-web-setup() => ${rc}"
    else
        wd_logger 2 "Both radiod and ka9q-web are setup. Finished in $PWD"
    fi
    return ${rc}
}
