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

declare KA9Q_REQUIRED_COMMIT_SHA="${KA8Q_REQUIRED_COMMIT_SHA-005b525325879d061a20b24260a4ba95e6a519b5}"   ### Defaults to   Thu Aug 1 10:33:45 2024 -0700
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
    wd_logger 1 "Current git commit SHA in ${PWD} is ${current_commit_sha}, not the desired SHA ${desired_git_sha}, so update the code from git"
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
    wd_logger 1 "Compiling KA9Q-radio..."
    make clean >& /dev/null
    make  >& /dev/null
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

#function test_get_conf_section_variable() {
#    get_conf_section_variable "test_value" /etc/radio/radiod@rx888-wsprdaemon.conf FT8 "data"
#}
#declare test_value
#test_get_conf_section_variable
#printf "%s\n" ${test_value}
#exit

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

declare KA9Q_FT_TMP_ROOT="${KA9Q_FT_TMP_ROOT-/mnt/ka9q-radio}"
declare KA9Q_FT_TMP_ROOT_SIZE="${KA9Q_FT_TMP_ROOT_SIZE-100M}"

declare KA9Q_DECODE_FT_CMD="/usr/local/bin/decode_ft8"               ### hacked code which decodes both FT4 and FT8 
declare KA9Q_FT8_LIB_REPO_URL="https://github.com/ka9q/ft8_lib.git" ### Where to get that code
declare KA9Q_DECODE_FT8_DIR="${WSPRDAEMON_ROOT_DIR}/ft8_lib"        ### Like ka9q-radio, ka9q-web amd onion, build 'decode-ft' in a subdirectory of WD's home

function ka9q-ft-install-decode-ft() {
    local rc

    wd_logger 1 "Starting in $PWD"
    if [[ -x ${KA9Q_DECODE_FT_CMD} ]]; then
        wd_logger 1 "${KA9Q_DECODE_FT_CMD}, so nothing to do"
        return 0
    fi
    wd_logger 1 "'${KA9Q_DECODE_FT_CMD}, so we need to create it"

    if [[ ! -d ${KA9Q_DECODE_FT8_DIR} ]]; then
        wd_logger 1 "'${KA9Q_DECODE_FT8_DIR}' doesn't exist, so we need to 'git clone' it"
        git clone ${KA9Q_FT8_LIB_REPO_URL}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'git clone ${KA9Q_FT8_LIB_REPO_URL}' failed -> ${rc}"
            return ${rc}
        fi
        wd_logger "Cloning was successful"
    fi
 
    local start_pwd=${PWD}
    cd  ${KA9Q_DECODE_FT8_DIR}
    git pull
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${start_pwd} > /dev/null
        wd_logger 1 "ERROR: 'git pull' => ${rc}"
        return ${rc}
    fi
    make 
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${start_pwd} > /dev/null
        wd_logger 1 "ERROR: 'make' => ${rc}"
        return ${rc}
    fi
    sudo make install
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd ${start_pwd} > /dev/null
        wd_logger 1 "ERROR: 'sudo make install' => ${rc}"
        return ${rc}
    fi
     cd ${start_pwd} > /dev/null
    if [[ ! -x ${KA9Q_DECODE_FT_CMD} ]]; then
        wd_logger 1 "ERROR: Can't create '${KA9Q_DECODE_FT_CMD}'"
        return 1
    fi
    wd_logger 1 "Successfully created  '${KA9Q_DECODE_FT_CMD}'"
    return 0
}

function ka9q-ft-setup() {
    local ft_type=$1        ## can be 4 or 8

    if [[ ${FT_FORCE_INIT-yes} == "no" ]]; then
        wd_logger 1 "Checking to see if there is a running ${ft_type}"
        if sudo systemctl status ${ft_type}-decoded.service >& /dev/null && [[ ${FT_FORCE_INIT-no} == "no" ]] ; then
            wd_logger 1 "${ft_tpe}-decoded.service is running, so no init needed"
            return 0
        fi
        wd_logger 1 "The ${ft_type}-decoded.service is not running"
    fi

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

    wd_logger 2 "Check for and, if needed, create the directory in a tmpfs for wav files"
    if mountpoint -q ${KA9Q_FT_TMP_ROOT} ; then
        wd_logger 2 "Found the needed tmpfs file system '${KA9Q_FT_TMP_ROOT}'"
    else
        wd_logger 2 "Missing needed tmpfs file system '${KA9Q_FT_TMP_ROOT}'"
        if [[ ! -d ${KA9Q_FT_TMP_ROOT} ]]; then
            wd_logger 2 "Creating ${KA9Q_FT_TMP_ROOT}"
            sudo mkdir -p  ${KA9Q_FT_TMP_ROOT}
            sudo chmod 777  ${KA9Q_FT_TMP_ROOT}
        fi
        sudo mount -t tmpfs -o size=${KA9Q_FT_TMP_ROOT_SIZE} tmpfs ${KA9Q_FT_TMP_ROOT}
    fi
    local ka9q_ft_tmp_dir=${KA9Q_FT_TMP_ROOT}/${ft_type}
    mkdir -p ${ka9q_ft_tmp_dir}

    ### When WD is running KA9Q's FTx decode services it can be configured to decode the wav files with WSJT-x's 'jt9' decoder.
    ### We create a bash script which can be run by ftX-decoded,
    ### But since jt9 can't decode ft4 wav files, WD continues to use the 'decode-ft8' program normally used by ka9q-radio.

    ### In order that the jt9 spot line format matches that of 'decode-ft8', create a bash shell script which accepts the same arguments, runs jt9 and pipes its output through an awk script
    ### It is awkward to embed an awk script inline like this, but the alternative would be to bury it in WF directory where this 
    local ka9q_ft_jt9_decoder="${ka9q_ft_tmp_dir}/wsjtx-ft-decoder.sh"
    wd_logger 2 "Creating ${ka9q_ft_jt9_decoder}  ft_type=${ft_type}"

    # execlp( Modetab[Mode].decode, Modetab[Mode].decode, "-f", freq, sp->filename, (char *)NULL);
    echo -n "${JT9_CMD} -${ft_type#ft} \$3 | awk -v base_freq_ghz=\$2 -v file_name=\${3##*/} "             > ${ka9q_ft_jt9_decoder}
    echo    \''/^[0-9]/ {
            printf "%s %3d %4s %'\''12.1f ~ %s %s %s %s\n", 20substr(file_name,1,2)"/"substr(file_name,3,2)"/"substr(file_name,5,2)" "substr(file_name,8,2)":"substr(file_name,10,2)":"substr(file_name,12,2), $2, $3,
            ( (base_freq_ghz * 1e9) + $4), $6, $7, $8, $9}'\'           >>  ${ka9q_ft_jt9_decoder}
    chmod +x ${ka9q_ft_jt9_decoder}

    local decoded_conf_file_name="${KA9Q_RADIOD_CONF_DIR}/${ft_type}-decode.conf"
    echo "MCAST=${dns_name}"        >  ${decoded_conf_file_name}
    echo "DIRECTORY=${ka9q_ft_tmp_dir}" >> ${decoded_conf_file_name}
    wd_logger 2 "Created ${decoded_conf_file_name} which contains:\n$(<  ${decoded_conf_file_name})"

    declare SYSTEMD_DIR="/etc/systemd/system"
    local ft_service_file_name="${SYSTEMD_DIR}/${ft_type}-decoded.service"
    local ft_log_file_name="${ka9q_ft_tmp_dir}/${ft_type}.log"

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
                wd_logger 1 "Can't find ' ${KA9Q_DECODE_FT_CMD}' which is used to decode ${ft_type}  spots"
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

    ### Ensure that the service file appends the stdout of the jt9 decoder to a ft8.log file in the tmpfs
    ###    and that the 
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

    declare KA9Q_FT_LOGROTATE_JOB_FILE_NAME="/etc/logrotate.d/${ft_type}.rotate"

    if [[ ! -f ${KA9Q_FT_LOGROTATE_JOB_FILE_NAME} ]]; then
        wd_logger 1 "Found no '${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}', so create it"
        echo "${ft_log_file_name} {
        rotate 10
        daily
        missingok
        notifempty
        compress
        delaycompress
        copytruncate
} " > ${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}
        chmod 644  ${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}
        wd_logger 1 "Added new logrotate job '${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}' to keep '' clean"
    else
        wd_logger 2 "Found '${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}', so check it"
    fi

    local target_file=$(sed -n 's;\(^/[^ ]*\).*;\1;p' ${KA9Q_FT_LOGROTATE_JOB_FILE_NAME})
    if [[ "${target_file}" == "${ft_log_file_name}" ]]; then
        wd_logger 2 "'${target_file}' is the required '${ft_log_file_name}' in '${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}', so no changes are needed"
    else
        wd_logger 1 "'${target_file}' is not the required '${ft_log_file_name}' in '${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}, so fix it'"
        sudo sed -i "s;\(^/[^ ]*\).*;${ft_log_file_name};" ${KA9Q_FT_LOGROTATE_JOB_FILE_NAME}
    fi

    wd_logger 2 "Setup complete"
}

declare KA9Q_PSK_REPORTER_URL="https://github.com/pjsg/ftlib-pskreporter.git"
declare KA9Q_PSK_REPORTER_DIR="${WSPRDAEMON_ROOT_DIR}/ftlib-pskreporter"

function wd_get_config_value() {
    local __return_variable_name=$1
    local return_variable_type=$2

    wd_logger 2 "Find the value of the '${return_variable_type}' from the config settings in the WD.conf file"

    if ! declare -p WSPR_SCHEDULE &> /dev/null ; then
        wd_logger 1 "ERROR: the array WSPR_SCHEDULE has not been declared in the WD.conf file"
        return 1
    fi
    local -A receiver_reference_count_list=()
    local schedule_index
    for (( schedule_index=0; schedule_index < ${#WSPR_SCHEDULE[@]}; ++schedule_index )); do
        local job_line="${WSPR_SCHEDULE[${schedule_index}]}"
        wd_logger 2 "Getting the names and counts of radios defined for job ${schedule_index}: ${job_line}"
        local job_line_list=( ${job_line} )
        local job_field
        for job_field in ${job_line_list[@]:1}; do
            local job_receiver=${job_field%%,*}
            ((receiver_reference_count_list["${job_receiver}"]++))
            wd_logger 2 "Found receiver ${job_receiver} referenced in job ${job_field} has been referenced ${receiver_reference_count_list["${job_receiver}"]} times"
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
    wd_logger 2 "Found the most referenced receiver in the WSPR_SCHEDULE[] is '${most_referenced_receiver}' which was referenced in ${largest_reference_count} jobs"

    if ! declare -p RECEIVER_LIST >& /dev/null ; then
        wd_logger 1 "ERROR: the RECEIVER_LIST array is not declared in WD.conf"
        return 2
    fi
    set +x
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
                    local receiver_description
                    if [[ "${receiver_line}" =~ "#" ]]; then
                        receiver_description="${receiver_line##*#}"
                        shopt -s extglob
                        receiver_description="${receiver_description##+([[:space:]])}"    ### trim off leading white space
                        wd_logger 2 "Found the description '${receiver_description}' in line: ${receiver_line}"
                    else
                        receiver_description="No_antenna_information"
                        wd_logger 2 "Can't find comments about receiver ${receiver_call}, so use 'No antenna information'"
                    fi

                    eval ${__return_variable_name}="\${receiver_description}"
                    wd_logger 2 "Assigned ${__return_variable_name}=${receiver_description}"
                    return 0
                    ;;
                *)
                    wd_logger 1 "ERROR: invalid return_variable_type='${return_variable_type}"
                    return 0
            esac
        fi
    done
    set +x
    wd_logger 1 "ERROR: can't find ${return_variable_type} config information"
    return 1
}

function  ka9q-psk-reporter-setup() {
    local rc

    if [[ ! -d ${KA9Q_PSK_REPORTER_DIR} ]]; then
        wd_logger 1 "No '${KA9Q_PSK_REPORTER_DIR}', so need to 'git clone to create it"
        git clone ${KA9Q_PSK_REPORTER_URL}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'git clone ${KA9Q_PSK_REPORTER_URL}' => ${rc}"
            return ${rc}
        fi
        if [[ ! -d ${KA9Q_PSK_REPORTER_DIR} ]]; then
            wd_logger 1 "ERROR: Successfully cloned '${KA9Q_PSK_REPORTER_URL}' but '${KA9Q_PSK_REPORTER_DIR}' was not created, so the github repo is broken"
            return 1
        fi

        local pip3_extra_args=""
        if [[ "${OS_RELEASE}" == "24.04" ]]; then
            pip3_extra_args="--break-system-package"
        fi
        pip3 install docopt ${pip3_extra_args}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'pip3 install docopt' => ${rc}"
            return 2
        fi

        wd_logger 1 "Successfully cloned '${KA9Q_PSK_REPORTER_URL}'"
    fi

    local pskreporter_sender_file_name="${KA9Q_PSK_REPORTER_DIR}/pskreporter-sender"           ### This template file is part of the package
    local pskreporter_sender_bin_file_name="/usr/local/bin//pskreporter-sender"
    if [[ ! -x ${pskreporter_sender_bin_file_name} ]]; then
        wd_logger 1 "Copying ${pskreporter_sender_file_name} to ${pskreporter_sender_bin_file_name}"
        sudo cp ${pskreporter_sender_file_name} ${pskreporter_sender_bin_file_name}
        sudo chmod a+x  ${pskreporter_sender_bin_file_name}
    fi

    local pskreporter_service_file_name="${KA9Q_PSK_REPORTER_DIR}/pskreporter@.service"         ### This template file is part of the package
    local pskreporter_systemd_service_file_name="/etc/systemd/system/pskreporter@.service"      ### It should be copied to the systemd/system/ dire\

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
    for ft_type in ft4 ft8; do
        local psk_conf_file="${KA9Q_RADIOD_CONF_DIR}/${ft_type}-pskreporter.conf"
        wd_logger 2 "Checking and updating  ${psk_conf_file}"
        if [[ ! -f ${psk_conf_file} ]]; then
            wd_logger 2 "Creating missing ${psk_conf_file}"
            touch ${psk_conf_file}
        fi
        local variable_line
        variable_line="MODE=${ft_type}"
        if grep -q "${variable_line}" ${psk_conf_file} ; then
            wd_logger 2 "Found the correct 'MODE=${ft_type}' line in ${psk_conf_file}, so no need to change ${psk_conf_file}"
        else
            grep -v "MODE=" ${psk_conf_file} > ${psk_conf_file}.tmp
            echo "${variable_line}" >> ${psk_conf_file}.tmp
            wd_logger 2 "Added or replaced invalid 'MODE=' line in  ${psk_conf_file} with '${variable_line}'"
            mv  ${psk_conf_file}.tmp  ${psk_conf_file}
            needs_systemctl_restart="yes"
        fi
        
        local ft_type_tmp_root_dir="${KA9Q_FT_TMP_ROOT}/${ft_type}"
        mkdir -p ${ft_type_tmp_root_dir}

        local ft_type_log_file_name="${ft_type_tmp_root_dir}/${ft_type}.log"
        if [[ ! -f ${ft_type_log_file_name} ]]; then
            wd_logger 2 "Creating new ${ft_type_log_file_name}"
            touch ${ft_type_log_file_name}
        fi
        variable_line="FILE=${ft_type_log_file_name}"
        if grep -q "${variable_line}" ${psk_conf_file} ; then
            wd_logger 2 "Found the correct ${variable_line}' line in ${psk_conf_file}, so no need to change ${psk_conf_file}"
        else
            grep -v "FILE=" ${psk_conf_file} > ${psk_conf_file}.tmp
            echo "${variable_line}" >> ${psk_conf_file}.tmp
            wd_logger 2 "Added or replaced invalid 'FILE=' line in  ${psk_conf_file} with '${variable_line}'"
            mv  ${psk_conf_file}.tmp  ${psk_conf_file}
            needs_systemctl_restart="yes"
        fi
        
        local config_variable
        for config_variable in CALLSIGN LOCATOR ANTENNA; do
            local config_value
            wd_get_config_value "config_value" ${config_variable}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: ' wd_get_config_value "config_value" ${config_variable}' => ${rc}"
                return ${rc}
            fi
            variable_line="${config_variable}=${config_value}"
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

        if [[ ${needs_systemctl_restart} == "yes" ]]; then
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

function ka9q_setup() {    
    wd_logger 2 "Starting in ${PWD}"

    local active_receivers
    get_list_of_active_real_receivers "active_receivers"
    if ! [[ "${active_receivers}" =~ KA9Q ]]; then
        wd_logger 1 "There are no KA9Q receivers in the conf file, so skip KA9Q setup"
        return 0
   fi
    wd_logger 2 "There are KA9Q receivers in the conf file, so set up KA9Q"
 
    ka9q-radiod-setup 
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR:  ka9q-radiod-setup() => ${rc}"
        return ${rc}
    fi
    wd_logger 2 "ka9q-radiod is setup ${PWD}"

    ka9q-web-setup
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR:  ka9q-web-setup() => ${rc}"
    else
        wd_logger 2 "Both radiod and ka9q-web are setup"
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
    wd_logger 2 "All three ka9q services: radiod, web and ft, are setup. So finished in $PWD"

    ka9q-psk-reporter-setup
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: ka9q-psk-reporter-setup() => ${rc}"
        save_rc=${rc}
    else
        wd_logger 2 "ka9q-psk-reporter-setup() is  setup"
    fi

    return ${save_rc}
}
ka9q_setup
