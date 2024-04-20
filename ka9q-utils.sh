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
declare KA9Q_RADIO_ROOT_DIR="${WSPRDAEMON_ROOT_DIR}/ka9q-radio"
declare KA9Q_RADIO_WD_RECORD_CMD="${KA9Q_RADIO_ROOT_DIR}/wd-record"
declare KA9Q_RADIO_TUNE_CMD="${KA9Q_RADIO_ROOT_DIR}/tune"
declare KA9Q_GIT_URL="https://github.com/ka9q/ka9q-radio.git"
declare KA9Q_RADIOD_SERVICE_BASE='radiod@*'                ### used in calling systemctl
declare WD_CONF_BASE_NAME="${KA9Q_CONF_FILE-rx888-wsprdaemon}"
declare WD_KA9Q_SERVICE_NAME="radiod@${WD_CONF_BASE_NAME}"  ### the argument givien to systemctl

declare KA9Q_WSPRDAEMON_CONF_FILE="${WD_KA9Q_SERVICE_NAME}.conf"      ### Customized radiod conf file found in ~/wsprdaemon directory
declare KA9Q_WSPRDAEMON_CONF_TEMPLATE_FILE="radiod@${WD_CONF_BASE_NAME}-template.conf"   ### Template found in WD's git package


declare WD_KA9Q_CONF_FILE="${WSPRDAEMON_ROOT_DIR}/${KA9Q_WSPRDAEMON_CONF_FILE}"                      ### Full path to conf which Can be cutomized by the user
declare WD_KA9Q_CONF_TEMPLATE_FILE="${WSPRDAEMON_ROOT_DIR}/${KA9Q_WSPRDAEMON_CONF_TEMPLATE_FILE}"    ### Full path to template with defautls for KA9Q RX-888 installatons

declare KA9Q_RADIOD_CONF_DIR="/etc/radio"
declare KA9Q_RADIOD_WD_CONF_FILE=${KA9Q_RADIOD_CONF_DIR}/${KA9Q_WSPRDAEMON_CONF_FILE}                ### radiod looks in /etc/radio/... for conf files


### These are the libraries needed by KA9Q, but it is too hard to extract them from the Makefile, so I just copied them here
declare KA9Q_PACKAGE_DEPENDANCIES="curl rsync build-essential libusb-1.0-0-dev libusb-dev libncurses5-dev libfftw3-dev libbsd-dev libhackrf-dev \
             libopus-dev libairspy-dev libairspyhf-dev librtlsdr-dev libiniparser-dev libavahi-client-dev portaudio19-dev libopus-dev"

declare KA9Q_RADIO_ROOT_DIR="${WSPRDAEMON_ROOT_DIR}/ka9q-radio"
declare KA9Q_RADIO_NWSIDOM="${KA9Q_RADIO_ROOT_DIR}/nwisdom"     ### This is created by running fft_wisdom during the KA9Q installation
declare FFTW_DIR="/etc/fftw"                                    ### This is the directory where radiod looks for a wisdomf
declare FFTW_WISDOMF="${FFTW_DIR}/wisdomf"                      ### This the wisdom file it looks for

declare KA9Q_REQUIRED_COMMIT_SHA="${KA8Q_REQUIRED_COMMIT_SHA-707842bb35f8634a888c9dc2b898730571638d5c}"   ### Default to 1/2/24 which includes the enhanced wd-record.c
declare GIT_LOG_OUTPUT_FILE="${WSPRDAEMON_TMP_DIR}/git_log.txt"

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

    cd ${git_directory} >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't 'cd  ${git_directory}'"
        return 2
    fi
    local current_commit_sha
    get_current_commit_sha current_commit_sha $PWD
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd - > /dev/null
        wd_logger 1 "ERROR: 'get_current_commit_sha current_commit_sha ${PWD}' => ${rc}"
        return 3
    fi
    if [[ "${current_commit_sha}" == "${desired_git_sha}" ]]; then
        cd - > /dev/null
        wd_logger 2 "Current git commit SHA in ${PWD} is the expected ${current_commit_sha}"
        return 0
    fi
    wd_logger 2 "Current git commit SHA in ${PWD} is ${current_commit_sha}, not the desired SHA ${desired_git_sha}, so update the code from git"
    git checkout main >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd - > /dev/null
        wd_logger 1 "ERROR: 'git checkout origin/main' => ${rc}"
        return 4
    fi
    git pull >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd - > /dev/null
        wd_logger 1 "ERROR: 'git pull' => ${rc}"
        return 5
    fi
    git checkout ${desired_git_sha} >& /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        cd - > /dev/null
        wd_logger 1 "ERROR: 'git checkout ${desired_git_sha}' => ${rc}"
        return 6
    fi
    cd - > /dev/null
    wd_logger 1 "Successfully updated the ${git_directory} directory to SHA ${desired_git_sha}"
    return 1
}

function ka9q_setup()
{
    local rc
    
    if ! install_dpkg_list avahi-utils ; then
        wd_logger 1 "ERROR: 'install_debian_package ${package_needed}' => $?"
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
            wd-radiod-bw-check
            if sudo systemctl status ${WD_KA9Q_SERVICE_NAME} > /dev/null ; then
                wd_logger 2 "KA9Q software wasn't updated and the radiod service is running, so KA9Q is setup and running"
                return 0
            fi
            wd_logger 1 "KA9Q software wasn't updated but the needed local radiod service is not running, so compile and install all of KA9Q"
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
    if [[ ! -f Makefile ]]; then
        cp -p Makefile.linux Makefile
    fi
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

    wd_logger 1 "There is a local RX888, so KA9Q's radiod service needs to run"

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

    wd_logger 1 "Stop any currently running instance of radiod so this newly built version will be started"
    sudo systemctl stop  "${KA9Q_RADIOD_SERVICE_BASE}" > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "'sudo systemctl stop  ${KA9Q_RADIOD_SERVICE_BASE}' => ${rc}, so no radiod was running.  Proceed to start it"
    fi
    if [[ ! -f ${WD_KA9Q_CONF_FILE} ]]; then
        wd_logger 1 "Missing WD's customized '${WD_KA9Q_CONF_FILE}', so creating it from the template"
        cp ${WD_KA9Q_CONF_TEMPLATE_FILE} ${WD_KA9Q_CONF_FILE}
    fi
    if [[ ! -f ${KA9Q_RADIOD_WD_CONF_FILE} ]]; then
        wd_logger 1 "Missing KA9Q's radiod conf file '${KA9Q_RADIOD_WD_CONF_FILE}', so creating it from WD's ${WD_KA9Q_CONF_FILE}"
        cp -p ${WD_KA9Q_CONF_FILE} ${KA9Q_RADIOD_WD_CONF_FILE}
    fi
    if [[ ${WD_KA9Q_CONF_FILE} -nt ${KA9Q_RADIOD_WD_CONF_FILE} ]]; then
        wd_logger 1 "${WD_KA9Q_CONF_FILE} is newer than '${KA9Q_RADIOD_WD_CONF_FILE}', so save and update ${KA9Q_RADIOD_WD_CONF_FILE}"
        cp -p ${KA9Q_RADIOD_WD_CONF_FILE} ${KA9Q_RADIOD_WD_CONF_FILE}.save 
        cp ${WD_KA9Q_CONF_FILE} ${KA9Q_RADIOD_WD_CONF_FILE}
    fi
    wd_logger  1 "Finished validating and updating the KA9Q installation"
    if ! lsusb | grep -q "Cypress Semiconductor Corp" ; then
        wd_logger 1 "Can't find a RX888 MkII attached to a USB port"
        exit
    fi
    wd_logger 1 "Found a RX888 MkII attached to a USB port"
 
    ### Make sure the config doesn't have the broken low = 100, high = 5000 values
    wd-radiod-bw-check

    sudo systemctl start  "${WD_KA9Q_SERVICE_NAME}" > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'sudo systemctl start  ${WD_KA9Q_SERVICE_NAME}' => ${rc}, so failed to start radiod"
    fi
    sudo systemctl is-active "${WD_KA9Q_SERVICE_NAME}" > /dev/null
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: after an otherwise successful installation of KA9Q its 'radiod' is not active"
        return 1
    fi
    wd_logger 1 "after a successful installation of KA9Q its 'radiod' is active"
    return 0
}

### Execute this once at WD start time
#ka9q_setup
