#!/bin/bash
# script to install the latest version of ka9q-web
# should be run from BASEDIR (i.e. /home/wsprdaemon/wsprdaemon) and it assumes
# that ka9q-radio has already been built in the ka9q-radio directory

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced
set -euo pipefail

  function wd_logger() { echo $@; }        ### Only for use when unit testing this file
  function is_uint() { return 0; }

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
    wd_logger 1 "Found pid =${ka9q_pid_value} and conf_file = '${ka9q_conf_file}'"
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
        wd_loogger 1 "Can't get ka9q-get-conf-file-name, so radiod  must not be running"
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
    wd_logger 1 "Found the radiod status DNS = '${ka9q_radiod_dns}'"
    eval ${___return_status_dns_var_name}=\"${ka9q_radiod_dns}\"
    return 0
}

#declare test_dns=foo
#ka9q-get-status-dns "test_dns" 
#echo "Gpt status DNS = '${test_dns}'"
#exit

declare KA9Q_WEB_PID_FILE_NAME="./ka9q-web.pid"

function ka9q-web-setup() {
    local rc
    wd_logger 1 "Starting"

    if [[ ! -f ${KA9Q_WEB_PID_FILE_NAME} ]]; then
        wd_logger 1 "No PID file, so install and spawn it"
    else
        local ka9q_web_pid=$(<  ${KA9Q_WEB_PID_FILE_NAME})
        wd_logger 1 "Got PID = ${ka9q_web_pid} from file  ${KA9Q_WEB_PID_FILE_NAME}"
        if ps  ${ka9q_web_pid} > /dev/null; then
            wd_logger 1 "ka9q-web is running, so nothing to do"
            return 0
        fi
         wd_logger 1 "Found file ${KA9Q_WEB_PID_FILE_NAME} which contains PID ${ka9q_web_pid}, but that PID is not active, so flush the PID file and start it again"
         rm -f ${KA9Q_WEB_PID_FILE_NAME}
    fi

    # 1. install Onion framework dependencies
    sudo apt update
    sudo apt install -y libgnutls28-dev libgcrypt20-dev cmake

    # 2. build and install Onion framework
    if [[ ! -d onion ]]; then
        git clone https://github.com/davidmoreno/onion
    fi
    (cd onion
    mkdir -p build
    cd build
    cmake -DONION_USE_PAM=false -DONION_USE_PNG=false -DONION_USE_JPEG=false -DONION_USE_XML2=false -DONION_USE_SYSTEMD=false -DONION_USE_SQLITE3=false -DONION_USE_REDIS=false -DONION_USE_GC=false -DONION_USE_TESTS=false -DONION_EXAMPLES=false -DONION_USE_BINDINGS_CPP=false ..
    make
    sudo make install
    sudo ldconfig)

    # 3. build and install ka9q-web
    if [[ ! -d ka9q-web ]]; then
        git clone https://github.com/fventuri/ka9q-web
    fi
    (cd ka9q-web
    make
    sudo make install)

    local ka9q_radiod_status_dns
    ka9q-get-status-dns "ka9q_radiod_status_dns"
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to find the status DNS  => ${rc}"
        return 1
    fi

    /usr/local/sbin/ka9q-web -m ${ka9q_radiod_status_dns} &
    rc=$?
    local ka9q_web_pid=$!
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to spawn ka9q-web.  => ${rc}"
        return 1
    fi
    echo ${ka9q_web_pid} > ${KA9Q_WEB_PID_FILE_NAME}
    wd_logger 1 "Started a new ka9q-web server which has pid = ${ka9q_web_pid}"
    return 0
}

function test_ka9q-web-setup() {
     ka9q-web-setup
 }

 test_ka9q-web-setup
