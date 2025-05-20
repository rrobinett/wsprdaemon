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


declare -i verbosity=${verbosity:-1}

declare -r WSPRDAEMON_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/${0##*/}"
declare -r WSPRDAEMON_CONFIG_FILE=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.conf
declare -r WSPRDAEMON_CONFIG_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/wd_template.conf

### This is used by two .sh files, so it need to be declared here
declare NOISE_GRAPHS_REPORTER_INDEX_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/noise_graphs_reporter_index_template.html    ### This is put into each reporter's www/html/graphs/REPORTER directory

declare WD_TIME_FMT=${WD_TIME_FMT-%(%a %d %b %Y %H:%M:%S %Z)T}   ### Used by printf "${WD_TIME}: ..." in lieu of $(date)

### If the user has enabled ia Romote Access Channel to this machine by defining "REMOTE_ACCESS_CHANNEL=NN' in the wsprdaemon.conf file,
###     install and enable the remote access service.
### If REMOTE_ACCESS_CHANNEL is not defined, then disable and stop the 'wd_remote_access' service if it is installed and running
declare -r REMOTE_ACCESS_SERVICES=${WSPRDAEMON_ROOT_DIR}/remote_access_service.sh
source ${REMOTE_ACCESS_SERVICES}
wd_remote_access_service_manager

declare OS_RELEASE    ### We are not in a function, so it can't be local
get_file_variable OS_RELEASE "VERSION_ID" /etc/os-release

declare OS_CODENAME
get_file_variable OS_CODENAME "VERSION_CODENAME" /etc/os-release

declare CPU_ARCH
CPU_ARCH=$(uname -m)

if [[ "$(timedatectl show -p NTPSynchronized --value)" != "yes" ]]; then
    wd_logger 1 "WARNING: the system clock is not synchronized"
fi

wd_logger 2 "Installing on Linux '${OS_CODENAME}',  OS version = '${OS_RELEASE}', CPU_ARCH=${CPU_ARCH}"

declare    PACKAGE_NEEDED_LIST=( at bc curl bind9-host flac postgresql sox zstd avahi-daemon libnss-mdns inotify-tools \
                libbsd-dev libavahi-client-dev libfftw3-dev libiniparser-dev libopus-dev opus-tools uuid-dev \
                libusb-dev libusb-1.0-0 libusb-1.0-0-dev libairspy-dev libairspyhf-dev portaudio19-dev librtlsdr-dev \
                libncurses-dev bzip2 wavpack libsamplerate0 libsamplerate0-dev lsof )
                ### avahi-daemon libnss-mdns are not included in the OrangePi's Armbien OS.  libnss-mymachines may also be needed

### 9/16/23 - At GM0UDL found that jt9 depends upon the Qt5 library ;=(
declare LIB_QT5_CORE="libqt5core5a"
declare LIB_QT5_CORE_ARMHF="libqt5core5a:armhf"
declare LIB_QT5_CORE_AMD64="libqt5core5a:amd64"
declare LIB_QT5_CORE_UBUNTU_24_04="libqt5core5t64"
declare LIB_QT5_DEFAULT_ARMHF="qt5-default:armhf"
declare LIB_QT5_DEFAULT_AMD64="qt5-default:amd64"
declare LIB_QT5_DEFAULT_ARM64="libqt5core5a:arm64"
declare LIB_QT5_LINUX_MINT="qtbase5-dev"

case ${CPU_ARCH} in
    armv7l)
        if [[ "${OSTYPE}" == "linux-gnueabihf" ]] ; then
            PACKAGE_NEEDED_LIST+=(  python3-soundfile libgfortran5:armhf ${LIB_QT5_CORE_ARMHF} )         ### on Pi's 32 bit bullseye
        else
            PACKAGE_NEEDED_LIST+=( libgfortran5:armhf ${LIB_QT5_DEFAULT_ARMHF} )
        fi
        ;;
    aarch64)
        PACKAGE_NEEDED_LIST+=( libgfortran5:arm64 ${LIB_QT5_DEFAULT_ARM64} )
         if [[ "${OS_RELEASE}" == "12" ]]; then
            ### The 64 bit Pi5 OS is based upon Debian 12
            wd_logger 2 "Installing on a Pi5 which is based upon Debian ${OS_RELEASE}"
            PACKAGE_NEEDED_LIST+=(  python3-matplotlib )
         fi
        ;;
    x86_64)
        wd_logger 2 "Installing on Ubuntu ${OS_RELEASE}"
        if [[ "${OS_RELEASE}" =~ 2[02].04 || "${OS_RELEASE}" == "12" || "${OS_RELEASE}" =~ 21.. ]]; then
            ### Ubuntu 22.04 and Debian don't use qt5-default
            PACKAGE_NEEDED_LIST+=( python3-numpy libgfortran5:amd64 ${LIB_QT5_CORE_AMD64} )
        elif [[ "${OS_RELEASE}" =~ 24.04 ]]; then
            PACKAGE_NEEDED_LIST+=( libhdf5-dev  python3-matplotlib libgfortran5:amd64 python3-dev libpq-dev python3-psycopg2 ${LIB_QT5_CORE_UBUNTU_24_04})
        elif [[ "${OS_RELEASE}" =~ 24.10 ]]; then
            PACKAGE_NEEDED_LIST+=( python3-numpy libgfortran5:amd64 libqt5core5t64 python3-psycopg2 )
        elif grep -q 'Linux Mint' /etc/os-release; then
            PACKAGE_NEEDED_LIST+=( libgfortran5:amd64 python3-psycopg2 python3-numpy ${LIB_QT5_LINUX_MINT} )
        else
            PACKAGE_NEEDED_LIST+=( libgfortran5:amd64 ${LIB_QT5_DEFAULT_AMD64} )
        fi
        ;;
    *)
        wd_logger 1 "ERROR: wsrpdaemon doesn't know what libraries are needed when running on CPU_ARCH=${CPU_ARCH}"
        exit 1
        ;;
esac

function is_orange_pi_5() {
    if grep -q 'Rockchip RK3588' /proc/cpuinfo 2>/dev/null || \
       grep -q "Orange Pi 5" /sys/firmware/devicetree/base/model 2>/dev/null; then
        return 0  # Success (Orange Pi5 detected)
    else
        return 1  # Failure (Not an Orange Pi5)
    fi
}

declare CPU_CGROUP_PATH="/sys/fs/cgroup"
declare WD_CPUSET_PATH="${CPU_CGROUP_PATH}/wsprdaemon"

### Restrict WD and its children so two CPU cores are always free for KA9Q-radio
# This should be undone later on systems not running KA9Q-radio
function wd_run_in_cgroup() {
    local rc
    local wd_core_range

    if [[ "${OS_RELEASE}" =~ 20.04 ]]; then
        wd_logger 2 "Skipping CPUAffinity setup which isn't supported on '${OS_CODENAME}' version = '${OS_RELEASE}'"
        return 0
    fi

    if [[ -n "${WD_CPU_CORES+set}" ]]; then
        wd_core_range="$WD_CPU_CORES"
        wd_logger 1 "MAX_WD_CPU_CORES was set to ${WD_CPU_CORES} in WD.conf"
    else
        local cpu_core_count=$(grep -c ^processor /proc/cpuinfo)
        if ((  cpu_core_count < 8 )); then
            wd_logger 1 "This CPU has only ${cpu_core_count} cores, so don't restrict WD to a subset of cores"
            return 0
        fi
        ### Most CPUs seem to have one of its pair of high performance chyperthreaded cores at 0-1
        #### So leave those cores for radiod and restrict WD to the other cores of the CPU
        #### It would be better to learn which cores are running radiod and then exclude WD from using them, but there is only so much coding time in life...
        local max_cpu_core=${MAX_WD_CPU_CORES-$(( cpu_core_count - 1 ))}
        wd_core_range="2-$max_cpu_core"
        wd_logger 1 "Restricting WD to run in the default range '$wd_core_range'"
    fi

    ### Fix up the wsprdaemon.service file so the CPUAffinity is assigned by systemctl when it starts WD
    local wd_service_file="/etc/systemd/system/wsprdaemon.service"
    if [[ ! -f $wd_service_file ]]; then
        wd_logger 1 "WARNING: this WD server has not been setup to autostart"
    else
         update_ini_file_section_variable $wd_service_file "Service" "CPUAffinity" "$wd_core_range"
         rc=$?
         case $rc in
             0)
                 wd_logger 1 "update_ini_file_section_variable $wd_service_file 'Service' 'CPUAffinity' '$wd_core_range'  was already setup"
                 ;;
             1)
                 wd_logger 1 "update_ini_file_section_variable $wd_service_file 'Service' 'CPUAffinity' '$wd_core_range'  was added or changed"
                 sudo systemctl daemon-reload
                 ;;
             *)
                 wd_logger 1 "ERROR: 'update_ini_file_section_variable $wd_service_file 'Service' 'CPUAffinity' '$wd_core_range' => $rc"
                 ;;
         esac
    fi

    if [ -n "${INVOCATION_ID-}" ]; then
        wd_logger 1 "WD is being run by systemctld which is in control of CPUAffinity.  So don't try to reassign WD to other cores"
        return 0
    fi
    wd_logger 1 "WD is being run by a terminal session, so set CPUAffinity to run on cores '$wd_core_range'"
 
    echo  "+cpuset"         | sudo tee "${CPU_CGROUP_PATH}/cgroup.subtree_control" > /dev/null
    sudo mkdir -p  "${WD_CPUSET_PATH}"
    echo  "+cpuset"         | sudo tee "${WD_CPUSET_PATH}/cgroup.subtree_control"  > /dev/null
    echo  0                 | sudo tee "${WD_CPUSET_PATH}/cpuset.mems"             > /dev/null  ### This must be done before the next line
    echo  ${wd_core_range}  | sudo tee "${WD_CPUSET_PATH}/cpuset.cpus"             > /dev/null  ###
    echo $$                 | sudo tee "${WD_CPUSET_PATH}/cgroup.procs"            > /dev/null

    wd_logger 1 "Restricted current WD shell $$ and its children to CPU cores ${wd_core_range}"
}
wd_run_in_cgroup


#### 11/1/22 - It appears that last summer a bug was introduced into Ubuntu 20.04 which causes kiwiwrecorder.py to crash if there are no active ssh sessions
###           To get around that bug, have WD spawn a ssh session to itself
function setup_wd_auto_ssh()
{
    if [[ ${WD_NEEDS_SSH-no} =~ [Nn][Oo] ]]; then           ### Matches 'no', 'No', 'NO', and 'nO'
        wd_logger 2 "WD_NEEDS_SSH=\"${WD_NEEDS_SSH-no}\", so not configured to start the Linux bug patch which runs an auto-ssh session"
        return 0
    fi
    if [[ ! -d ~/.ssh ]]; then
        wd_logger 1 "ERROR: 'WD_NEEDS_SSH=\"${WD_NEEDS_SSH}\" in WD.conf configures WD to start the Linux bug patch which runs an auto-ssh session, but there is no '~/.ssh' directory.  Run 'ssh-keygen' to create and populate it"
        return 1
    fi
    if [[ ! -f ~/.ssh/id_rsa.pub ]]; then
        wd_logger 1 "ERROR: 'WD_NEEDS_SSH=\"${WD_NEEDS_SSH}\" in WD.conf configures WD to start the Linux bug patch which runs an auto-ssh session, but there is no '~/.ssh/id_rsa.pub' file.  Run 'ssh-keygen' to create it"
        return 2
    fi
    local my_ssh_pub_key=$(< ~/.ssh/id_rsa.pub)
    if [[ ! -f ~/.ssh/authorized_keys ]] || ! grep -q "${my_ssh_pub_key}" ~/.ssh/authorized_keys; then
        wd_logger 1 "Adding my ssh public key to my ~/.ssh/authorized_keys file"
        echo "${my_ssh_pub_key}" >> ~/.ssh/authorized_keys
    fi
    local wd_auto_ssh_pid=$(ps aux | grep "ssh \-fN" | awk '{print $2}')
    if [[ -n "${wd_auto_ssh_pid}" ]]; then
        wd_logger 2 "Auto ssh session is running with PID ${wd_auto_ssh_pid}"
    else
        wd_logger 1 "Spawning a new auto ssh session by running 'ssh -fN localhost'"
        ssh -fN localhost
    fi
    return 0
}
setup_wd_auto_ssh

function install_needed_dpkgs()
{
    wd_logger 2 "Starting"

    local package_needed
    for package_needed in ${PACKAGE_NEEDED_LIST[@]}; do
        wd_logger 2 "Checking for package ${package_needed}"
        if ! install_debian_package ${package_needed} ; then
            wd_logger 1 "ERROR: 'install_debian_package ${package_needed}' => $?"
            exit 1
        fi
    done
    wd_logger 2 "Checking for WSJT-x utilities 'wsprd' and 'jt9'"
}
### The configuration may determine which utilities are needed at run time, so now we can check for needed utilities
if ! install_needed_dpkgs ; then
    wd_logger 1  "ERROR: failed to load all the libraries needed on this server"
    exit 1
fi

###################### Check OS ###################
if [[ "${OSTYPE}" == "linux-gnueabihf" ]] || [[ "${OSTYPE}" == "linux-gnu" ]] ; then
    ### We are running on a Raspberry Pi or generic Debian server
    declare -r GET_FILE_SIZE_CMD="stat --format=%s" 
    declare -r GET_FILE_MOD_TIME_CMD="stat -c %Y"       
elif [[ "${OSTYPE}" == "darwin18" ]]; then
    ### We are running on a Mac, but as of 3/21/19 this code has not been verified to run on these systems
    declare -r GET_FILE_SIZE_CMD="stat -f %z"       
    declare -r GET_FILE_MOD_TIME_CMD="stat -f %m"       
else
    ### TODO:  
    echo "ERROR: We are running on a OS '${OSTYPE}' which is not yet supported"
    exit 1
fi
declare -r DPKG_CMD="/usr/bin/dpkg"
declare -r GREP_CMD="/bin/grep"

### Check that there is a conf file
if [[ ! -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
    echo "WARNING: The configuration file '${WSPRDAEMON_CONFIG_FILE}' is missing, so it is being created from a template."
    echo "         Edit that file to match your Receiver(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
    cp -p  ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE}
    exit
fi
### Check that the conf file differs from the prototype conf file
if diff -q ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE} > /dev/null; then
    echo "WARNING: The configuration file '${WSPRDAEMON_CONFIG_FILE}' is the same as the template."
    echo "         Edit that file to match your Receiver(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
    exit 
fi

### Validate the config file so the user sees any errors on the command line
declare -r WSPRDAEMON_CONFIG_UTILS_FILE=${WSPRDAEMON_ROOT_DIR}/config_utils.sh
source ${WSPRDAEMON_CONFIG_UTILS_FILE}

if ! validate_configuration_file; then
    exit 1
fi

### Read the variables defined in the conf file
source ${WSPRDAEMON_CONFIG_FILE}

### Additional bands can be defined in the conf file (i.e. WWV, CHU,...)
WSPR_BAND_LIST+=( ${EXTRA_BAND_LIST[@]- } )
WSPR_BAND_CENTERS_IN_MHZ+=( ${EXTRA_BAND_CENTERS_IN_MHZ[@]- } )

### Check the variables which should (or might) be defined in the wsprdaemon.conf file
if [[ -z "${SIGNAL_LEVEL_UPLOAD-}" ]]; then
    if [[ -n "${SIGNAL_LEVEL_UPLOAD_MODE-}" ]]; then
        SIGNAL_LEVEL_UPLOAD="${SIGNAL_LEVEL_UPLOAD_MODE}"
    fi
fi
SIGNAL_LEVEL_UPLOAD=${SIGNAL_LEVEL_UPLOAD-no}                                                  ### This forces SIGNAL_LEVEL_UPLOAD to default to "no"
if [[ ${SIGNAL_LEVEL_UPLOAD} != "no" ]]; then
    if [[ ${SIGNAL_LEVEL_UPLOAD_ID-none} == "none" ]]; then
        wd_logger -1 "ERROR: in wsprdaemon.conf, SIGNAL_LEVEL_UPLOAD=\"${SIGNAL_LEVEL_UPLOAD}\" is set to upload to wsprdaemon.org, but no SIGNAL_LEVEL_UPLOAD_ID has been defined"
        exit 1
    fi
    if [[ ${SIGNAL_LEVEL_UPLOAD_ID} == "AI6VN" ]]; then
        wd_logger -1 "ERROR: please change SIGNAL_LEVEL_UPLOAD_ID in your wsprdaemon.conf file from the value \"AI6VN\" which was included in the wd_template.conf file"
        exit 2
    fi
    if [[ ${SIGNAL_LEVEL_UPLOAD_ID} =~ "/" ]]; then
        wd_logger -1 "ERROR: SIGNAL_LEVEL_UPLOAD_ID=\"${SIGNAL_LEVEL_UPLOAD_ID}\" defined in your wsprdaemon.conf file cannot include the \"/\". Please change it to \"_\""
        exit 3
    fi
fi

function check_tmp_filesystem()
{
    if [[ ! -d ${WSPRDAEMON_TMP_DIR} ]]; then
        [[ $verbosity -ge 0 ]] && echo "The directory system for WSPR recordings does not exist.  Creating it"
        if ! mkdir -p ${WSPRDAEMON_TMP_DIR} ; then
            "ERROR: Can't create the directory system for WSPR recordings '${WSPRDAEMON_TMP_DIR}'"
            exit 1
        fi
    fi
    if df ${WSPRDAEMON_TMP_DIR} | grep -q tmpfs ; then
        wd_logger 2 "Found '${WSPRDAEMON_TMP_DIR}' is a tmpfs file system"
    else
        if [[ "${USE_TMPFS_FILE_SYSTEM-yes}" != "yes" ]]; then
            echo "WARNING: configured to record to a non-ram file system"
        else
            echo "WARNING: This server is not configured so that '${WSPRDAEMON_TMP_DIR}' is a 300 MB RAM file system."
            echo "         Every 2 minutes this program can write more than 200 Mbps to that file system which will prematurely wear out a microSD or SSD"
            read -p "So do you want to modify your /etc/fstab to add that new file system? [Y/n]> "
            REPLY=${REPLY:-Y}     ### blank or no response change to 'Y'
            if [[ ${REPLY^} != "Y" ]]; then
                echo "WARNING: you have chosen to use a non-ram file system"
            else
                if ! grep -q ${WSPRDAEMON_TMP_DIR} /etc/fstab; then
                    sudo cp -p /etc/fstab /etc/fstab.save
                    echo "Modifying /etc/fstab.  Original has been saved to /etc/fstab.save"
                    echo "tmpfs ${WSPRDAEMON_TMP_DIR} tmpfs defaults,noatime,nosuid,size=300m    0 0" | sudo tee -a /etc/fstab  > /dev/null
                fi
                mkdir ${WSPRDAEMON_TMP_DIR}
                if ! sudo mount -a ${WSPRDAEMON_TMP_DIR}; then
                    echo "ERROR: failed to mount ${WSPRDAEMON_TMP_DIR}"
                    exit
                fi
                echo "Your server has been configured so that '${WSPRDAEMON_TMP_DIR}' is a tmpfs (RAM disk)"
            fi
        fi
    fi
}
check_tmp_filesystem

################## Check that kiwirecorder is installed and running #######################
declare   KIWI_RECORD_DIR="${WSPRDAEMON_ROOT_DIR}/kiwiclient" 
declare   KIWI_RECORD_COMMAND="${KIWI_RECORD_DIR}/kiwirecorder.py"
declare   KIWI_RECORD_TMP_LOG_FILE="${WSPRDAEMON_TMP_DIR}/kiwiclient.log"

function check_for_kiwirecorder_cmd() {
    local get_kiwirecorder="no"
    local apt_update_done="no"
    if [[ ! -x ${KIWI_RECORD_COMMAND} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): check_for_kiwirecorder_cmd() found no ${KIWI_RECORD_COMMAND}"
        get_kiwirecorder="yes"
    else
        ## kiwirecorder.py has been installed.  Check to see if kwr is missing some needed modules
        [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_kiwirecorder_cmd() found  ${KIWI_RECORD_COMMAND}"
        local log_file=${KIWI_RECORD_TMP_LOG_FILE}
        if [[ -f ${log_file} ]]; then
            sudo rm -f ${log_file}       ## In case this was left behind by another user
        fi
        if ! python3 ${KIWI_RECORD_COMMAND} --help >& ${log_file} ; then
            echo "Currently installed version of kiwirecorder.py fails to run:"
            cat ${log_file}
            if ! ${GREP_CMD} "No module named 'numpy'" ${log_file}; then
                echo "Found unknown error in ${log_file} when running 'python3 ${KIWI_RECORD_COMMAND}'"
                exit 1
            fi
            if sudo apt install python3-numpy ; then
                echo "Successfully installed numpy"
            else
                echo "'sudo apt install python3-numpy' failed to install numpy"
                if ! pip3 install numpy; then 
                    echo "Installation command 'pip3 install numpy' failed"
                    exit 1
                fi
                echo "Installation command 'pip3 install numpy' was successful"
                if ! python3 ${KIWI_RECORD_COMMAND} --help >& ${log_file} ; then
                    echo "Currently installed version of kiwirecorder.py fails to run even after installing module numpy"
                    exit 1
                fi
            fi
        fi
        ### kwirecorder.py ran successfully
        if ! ${GREP_CMD} "ADC OV" ${log_file} > /dev/null 2>&1 ; then
            get_kiwirecorder="yes"
            echo "Currently installed version of kiwirecorder.py does not support overload reporting, so getting new version"
            rm -rf ${KIWI_RECORD_DIR}.old
            mv ${KIWI_RECORD_DIR} ${KIWI_RECORD_DIR}.old
        else
            [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_kiwirecorder_cmd() found ${KIWI_RECORD_COMMAND} supports 'ADC OV', so newest version is loaded"
        fi
    fi
    if [[ ${get_kiwirecorder} == "yes" ]]; then
        cd ${WSPRDAEMON_ROOT_DIR}
        echo "Installing kiwirecorder in $PWD"
        if ! ${DPKG_CMD} -l | ${GREP_CMD} -wq git  ; then
            [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
            sudo apt-get --yes install git
        fi
        git clone https://github.com/jks-prv/kiwiclient
        echo "Downloading the kiwirecorder SW from Github..." 
        if [[ ! -x ${KIWI_RECORD_COMMAND} ]]; then 
            echo "ERROR: can't find the kiwirecorder.py command needed to communicate with a KiwiSDR.  Download it from https://github.com/jks-prv/kiwiclient/tree/jks-v0.1"
            echo "       You may also need to install the Python library 'numpy' with:  sudo apt-get install python-numpy"
            exit 1
        fi
        if ! ${DPKG_CMD} -l | ${GREP_CMD} -wq python-numpy ; then
            [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
            sudo apt --yes install python-numpy
        fi
        echo "Successfully installed kiwirecorder.py"
        cd - >& /dev/null
    fi
}

function ask_user_to_install_sw() {
    local prompt_string=$1
    local is_requried_by_wd=${2:-}

    echo ${prompt_string}
    read -p "Do you want to proceed with the installation of this software? [Yn] > "
    REPLY=${REPLY:-Y}
    REPLY=${REPLY:0:1}
    if [[ ${REPLY^} != "Y" ]]; then
        if [[ -n "${is_requried_by_wd}" ]]; then
            echo "${is_requried_by_wd} is a software utility required by wsprdaemon and must be installed for it to run"
        else
            echo "WARNING: change wsprdaemon.conf to avoid installation of this software"
        fi
        exit
    fi
}

declare INSTALLED_DEBIAN_PACKAGES=$(${DPKG_CMD} -l)

############### Timescale database #######################
#### For writing and reading spots scraped from the Wsprnet.org spot database: TimeScale (TS) Wsprnet (WN) Write Only (WO) and Read Only (RO) defines
declare TS_WN_DB=wsprnet
declare TS_WN_TABLE=spots
declare TS_WN_BATCH_INSERT_SPOTS_SQL_FILE=${WSPRDAEMON_ROOT_DIR}/ts_insert_wn_spots.sql   ### Defines the format of the spot lines of the csv file obtained from wsprnet.org

### For the WN table to be accessed, valid usenames and passwords must be defined in the WD.conf file
declare TS_WN_WO_USER=${TS_WN_WO_USER-need_user}               ### For writes to work, a valid user name must be declared in WD.conf
declare TS_WN_WO_PASSWORD=${TS_WN_WO_PASSWORD-need_password}   ### For writes to work, the valid password must be declared in WD.conf

declare TS_WN_RO_USER=${TS_WN_RO_USER-wdread}                  ### This user is already public, so it can be the default value and shown here
declare TS_WN_RO_PASSWORD=${TS_WN_RO_PASSWORD-JTWSPR2008}      ### This password is already public, no it can be the deault value and shown here

### TimeScale (TS) Wsprdaemon (WD) Write Only (WO) and Read Only (RO) defines
declare TS_WD_DB=tutorial                                      ### The TS database (DB) which contains the tables of WD spots and noise
declare TS_WD_SPOTS_TABLE=wsprdaemon_spots_s
declare TS_WD_NOISE_TABLE=wsprdaemon_noise_s

declare TS_WD_WO_USER=${TS_WD_WO_USER-need_user}               ### For writes to work, a valid user name must be declared in WD.conf
declare TS_WD_WO_PASSWORD=${TS_WD_WO_PASSWORD-need_password}   ### For writes to work, the valid password must be declared in WD.conf

declare TS_WD_RO_USER=${TS_WD_RO_USER-wdread}                  ### This user is already public, so it can be the default value and shown here
declare TS_WD_RO_PASSWORD=${TS_WD_RO_PASSWORD-JTWSPR2008}      ### This password is already public, no it can be the default value and shown her

declare TS_WD_BATCH_INSERT_SPOTS_SQL_FILE=${WSPRDAEMON_ROOT_DIR}/ts_insert_wd_spots.sql
declare TS_WD_BATCH_INSERT_NOISE_SQL_FILE=${WSPRDAEMON_ROOT_DIR}/ts_insert_wd_noise.sql

### This python command is used by both the scraper daemon to record a csv file with a block of WN spots, and by the tgz servicing daemon to record WD_spots and WD_noise csv files
### usage:  python3 ${TS_BATCH_UPLOAD_PYTHON_CMD} --input ${csv_file} --sql ${insert_sql_file}  --address localhost --ip_port ${TS_IP_PORT-5432} --database ${TS_DB} --username ${TS_USER} --password ${TS_PASSWORD}
declare TS_BATCH_UPLOAD_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/ts_batch_upload.py


function install_ts_recording_packages()
{
   ### Get the Python packages needed to create the graphs.png
    local package
    for package in psycopg2 ; do
        wd_logger 2 "Install Python package ${package}"
        install_python_package ${package}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to install Python package ${package}"
            return ${ret_code}
        fi
    done
}

if ! install_ts_recording_packages ; then
    wd_logger 1 "ERROR: failed to install Python package ${package} needed by the server to record spots and noise to TS"
    exit 1
fi

### WD uses the 'wsprd' and 'jt9' binaries from the WSJT-x package.  
### 9/16/20 RR - WSJT-x doesn't yet install on Ubuntu 20.04, so special case that.
### 'wsprd' doesn't report its version number (e.g. with wsprd -V), so on most systems we learn the version from 'dpkt -l'.
### On Ubuntu 20.04 we can't install the package, so we can't learn the version number from dpkg.
### So on Ubuntu 20.04 we assume that if wsprd is installed it is the correct version
### Perhaps I will save the version number of wsprd and use this process on all OSs
### To avoid conflicts with wsprd from WSJT-x which may be also installed on this PC, run a WD copy of wsprd

declare WSPRD_CMD
declare WSPRD_SPREADING_CMD
declare JT9_CMD

declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
mkdir -p ${WSPRD_BIN_DIR}
declare WSPRD_CMD_FLAGS="${WSPRD_CMD_FLAGS--C 500 -o 4 -d}"
declare JT9_CMD_FLAGS="${JT9_CMD_FLAGS:---fst4w -p 120 -L 1400 -H 1600 -d 3}"
declare JT9_DECODE_ENABLED=${JT9_DECODE_ENABLED:-no}

function find_wsjtx_commands()
{
    local bin_file_list=( $(find ${WSPRD_BIN_DIR} -maxdepth 1 -type f -executable -printf "%p\n"  | sort) )

    if [[ ${#bin_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "ERROR: can't find any of the expected executable files in ${WSPRD_BIN_DIR}"
        exit 1
    fi
    wd_logger 2 "Found ${#bin_file_list[@]} executable files in  ${WSPRD_BIN_DIR}"

    local bin_file
    for bin_file in ${bin_file_list[@]} ; do
        wd_logger 2 "Testing ${bin_file}"
        local rc 
        ${bin_file} |& grep -q "Usage" 
        rc=$?
        if [[ ${rc} -ne 0 ]];  then
            wd_logger 2 "Bin file '${bin_file} fails to run on this server.  Skip to test next bin file"
        else
            wd_logger 2 "Bin file '${bin_file} runs on this server"
            if [[ ${bin_file} =~ bin/wsprd.spread ]]; then
                wd_logger 2 "Found that WSPRD_SPREADING_CMD='${bin_file}' runs on this server"
                if [[ -n "${WSPRD_SPREADING_CMD-}" ]]; then
                    wd_logger 1 "Warning: ignoring a second WSPRD_SPREADING_CMD='${bin_file}' which also runs on this server"
                else
                    WSPRD_SPREADING_CMD="${bin_file}"
                fi
            elif  [[ ${bin_file} =~ bin/wsprd ]]; then
                wd_logger 2 "Found that WSPRD_CMD='${bin_file}' runs on this server"
                if [[ -z "${WSPRD_CMD-}" ]]; then
                    wd_logger 2 "There is no 'WSPRD_CMD', so use this one '${bin_file}'"
                    WSPRD_CMD="${bin_file}"
                else
                    ### We have already found a 'bin/wsprd... command on this server
                    local test_name="${WSPRD_CMD##*bin/wsprd}"
                    if [[  -z "${test_name}" ]]; then
                        wd_logger 2 "Found a second bin/wsprd... after first finding ''bin/wsprd', so 'wd_rm ${WSPRD_CMD}' and use this ${bin_file}"
                        wd_rm ${WSPRD_CMD}
                        WSPRD_CMD="${bin_file}"
                    else
                        wd_logger 1 "Warning: Since we have a functioning non-'bin/wsprd' command ${WSPRD_CMD}, ignoring this second one '${bin_file}"
                    fi
                fi
            elif [[ ${bin_file} =~ bin/jt9 ]]; then
                wd_logger 2 "Found that JT9_CMD='${bin_file}' runs on this server"
                if [[ -z "${JT9_CMD-}" ]]; then
                    wd_logger 2 "There is no JT9_CMD, so use this one '${bin_file}'"
                    JT9_CMD="${bin_file}"
                else
                    local test_name=${JT9_CMD##*bin/jt9}        ## I gave up trying to find a regex experession which would do this
                    if [[  -z "${test_name}" ]]; then
                        wd_logger 2 "Found a second bin/jt9... after first finding ''bin/jt9', so 'wd_rm ${JT9_CMD}' and use this ${bin_file}"
                        wd_rm ${JT9_CMD}
                        JT9_CMD=${bin_file}
                    else
                        wd_logger 1 "Warning: Since we have a functioning non-'bin/jt9' command, ignoring this second one '${bin_file}"
                    fi 
                fi
            else
                wd_logger 2 "Ignoring executble command '${bin_file}'"
            fi
        fi
    done
    if [[ -z "${WSPRD_CMD-}" ]]; then
        wd_logger 1 "ERROR: couldn't find WSPRD_CMD"
        local rc
        sudo apt install wsjtx -y
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "Couldn't install wsprd: 'sudo apt install wsjtx -y' => ${rc}"
            exit 1
        fi
        local dpkg_wsprd_file_name="/usr/bin/wsprd"
        if [[ ! -x ${dpkg_wsprd_file_name} ]]; then
            wd_logger 1 "ERROR: after ' sudo apt install wsjtx -y' failed to find ${dpkg_wsprd_file_name}"
            exit 1
        fi
        cp ${dpkg_wsprd_file_name} bin/
        rc=$?
         if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "Couldn't 'cp ${dpkg_wsprd_file_name} bin/' => ${rc}"
            exit 1
        fi
        WSPRD_CMD=$(realpath bin/wsprd)
        wd_logger 1 "Installed missing bin/wsprd from the 'wsjtx' package"
    fi
    if [[ -z "${WSPRD_SPREADING_CMD-}" ]]; then
        if grep -q "Ubuntu 20" /etc/os-release ; then
            wd_logger 1 "On Ubuntu 20 installing bin/wsprd as wsprd.spread.ubuntu.20.x86"
            cp bin/wsprd bin/wsprd.spread.ubuntu.20.x86
            WSPRD_SPREADING_CMD=$(realpath bin/wsprd.spread.ubuntu.20.x86)
        else
            wd_logger 1 "ERROR: couldn't find WSPRD_SPREADING_CMD"
            exit 1
        fi
    fi
    if [[ -z "${JT9_CMD-}" ]]; then
        wd_logger 1 "ERROR: couldn't find JT9_CMD"
        exit 1
    fi
    wd_logger 2 "Found all three of the wsprd/jt9 executables are on this server:\nWSPRD_CMD=${WSPRD_CMD}\nWSPRD_SPREADING_CMD=${WSPRD_SPREADING_CMD}\nJT9_CMD=${JT9_CMD}"
}
find_wsjtx_commands

if ! check_for_kiwirecorder_cmd ; then
    wd_logger 1  "ERROR: failed to find or load Kiwi recording utility '${KIWI_RECORD_COMMAND}'"
    exit 1
fi

if ! check_systemctl_is_setup ; then
    wd_logger 1 "ERROR: failed to setup this server to auto-start"
    exit 1
fi

