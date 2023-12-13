#!/bin/bash

declare -i verbosity=${verbosity:-1}

declare -r WSPRDAEMON_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/${0##*/}"
declare -r WSPRDAEMON_CONFIG_FILE=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.conf
declare -r WSPRDAEMON_CONFIG_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/wd_template.conf

### This is used by two .sh files, so it need to be declared here
declare NOISE_GRAPHS_REPORTER_INDEX_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/noise_graphs_reporter_index_template.html    ### This is put into each reporter's www/html/graphs/REPORTER directory

################# Check that our recordings go to a tmpfs (i.e. RAM disk) file system ################
declare WSPRDAEMON_TMP_DIR=/dev/shm/wsprdaemon
mkdir -p /dev/shm/wsprdaemon
if [[ -n "${WSPRDAEMON_TMP_DIR-}" && -d ${WSPRDAEMON_TMP_DIR} ]] ; then
    ### The user has configured a TMP dir
    wd_logger 2 "Using user configured TMP dir ${WSPRDAEMON_TMP_DIR}"
elif df /tmp/wspr-captures > /dev/null 2>&1; then
    ### Legacy name for /tmp file system.  Leave it alone
    WSPRDAEMON_TMP_DIR=/tmp/wspr-captures
elif df /tmp/wsprdaemon > /dev/null 2>&1; then
    WSPRDAEMON_TMP_DIR=/tmp/wsprdaemon
fi

declare WD_TIME_FMT=${WD_TIME_FMT-%(%a %d %b %Y %H:%M:%S %Z)T}   ### Used by printf "${WD_TIME}: ..." in lieu of $(date)

### If the user has enabled ia Romote Access Channel to this machine by defining "REMOTE_ACCESS_CHANNEL=NN' in the wsprdaemon.conf file,
###     install and enable the remote access service.
### If REMOTE_ACCESS_CHANNEL is not defined, then disable and stop the 'wd_remote_access' service if it is installed and running
declare -r REMOTE_ACCESS_SERVICES=${WSPRDAEMON_ROOT_DIR}/remote_access_service.sh
source ${REMOTE_ACCESS_SERVICES}
wd_remote_access_service_manager

declare    PACKAGE_NEEDED_LIST=( at bc curl host flac postgresql sox zstd avahi-daemon libnss-mdns \
                libbsd-dev libavahi-client-dev libfftw3-dev libiniparser-dev libopus-dev opus-tools uuid-dev \
                libusb-dev libusb-1.0-0 libusb-1.0-0-dev libairspy-dev libairspyhf-dev portaudio19-dev librtlsdr-dev libncurses-dev)      ### avahi-daemon libnss-mdns are not included in the OrangePi's Armbien OS.  libnss-mymachines may also be needed

if false; then
    ### Installation of the Qt5 library appears to be no longer necessary since we no longer try to install the full WSJT-x package
    declare LIB_QT5_CORE_ARMHF=""
    declare LIB_QT5_CORE_AMD64=""
    declare LIB_QT5_DEFAULT_ARMHF=""
    declare LIB_QT5_DEFAULT_AMD64=""
    declare LIB_QT5_DEFAULT_ARM64=""
else
    ### 9/16/23 - At GM0UDL found that jt9 depends upon the Qt5 library ;=(
    declare LIB_QT5_CORE_ARMHF="libqt5core5a:armhf"
    declare LIB_QT5_CORE_AMD64="libqt5core5a:amd64"
    declare LIB_QT5_DEFAULT_ARMHF="qt5-default:armhf"
    declare LIB_QT5_DEFAULT_AMD64="qt5-default:amd64"
    declare LIB_QT5_DEFAULT_ARM64="libqt5core5a:arm64"
fi

declare -r CPU_ARCH=$(uname -m)
case ${CPU_ARCH} in
    armv7l)
        if [[ "${OSTYPE}" == "linux-gnueabihf" ]] ; then
            PACKAGE_NEEDED_LIST+=( libgfortran5:armhf ${LIB_QT5_CORE_ARMHF} )         ### on Pi's i32 bit bullseye
        else
            PACKAGE_NEEDED_LIST+=( libgfortran5:armhf ${LIB_QT5_DEFAULT_ARMHF} )
        fi
        ;;
    aarch64)
        ### This is a 64 bit bullseye Pi4 and teh OrangePi
        PACKAGE_NEEDED_LIST+=( libgfortran5:arm64 ${LIB_QT5_DEFAULT_ARM64} )
        ;;
    x86_64)
        declare os_release    ### We are not in a function, so it can't be local
        get_file_variable os_release "VERSION_ID" /etc/os-release
        wd_logger 2 "Installing on Ubuntu ${os_release}"
        if [[ "${os_release}" =~ 2..04 || "${os_release}" == "12" || "${os_release}" =~ 21.2 ]]; then
            ### Ubuntu 22.04 and Debian doesn't use qt5-default
            PACKAGE_NEEDED_LIST+=( libgfortran5:amd64 ${LIB_QT5_CORE_AMD64} )
        else
            PACKAGE_NEEDED_LIST+=( libgfortran5:amd64 ${LIB_QT5_DEFAULT_AMD64} )
        fi
        ;;
    *)
        wd_logger 1 "ERROR: wsrpdaemon doesn't know what libraries are needed when running on CPU_ARCH=${CPU_ARCH}"
        exit 1
        ;;
esac

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
SIGNAL_LEVEL_UPLOAD=${SIGNAL_LEVEL_UPLOAD-no}                                                  ### This forces SIGNAL_LEVEL_UPLOAD to default to "no"
if [[ ${SIGNAL_LEVEL_UPLOAD} != "no" ]]; then
    if [[ ${SIGNAL_LEVEL_UPLOAD_ID-none} == "none" ]]; then
        wd_logger -1 "ERROR: in wsprdaemon.conf, SIGNAL_LEVEL_UPLOAD=\"${SIGNAL_LEVEL_UPLOAD}\" is set to upload to wsprdaemon.org, but no SIGNAL_LEVEL_UPLOAD_ID has been defined"
        exit 1
    fi
    if [[ ${SIGNAL_LEVEL_UPLOAD_ID} == "AI6VN" ]]; then
        wd_logger -1 "ERROR: please change SIGNAL_LEVEL_UPLOAD_ID in your wsprdaemon.conf file from the value \"AI6VN\" which was included in  the wd_template.conf file"
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
            [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_kiwirecorder_cmd() found  ${KIWI_RECORD_COMMAND} supports 'ADC OV', so newest version is loaded"
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

if ! check_for_kiwirecorder_cmd ; then
    echo "ERROR: failed to find or load Kiwi recording utility '${KIWI_RECORD_COMMAND}'"
    exit 1
fi

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

### To avoid conflicts with wsprd from WSJT-x which may be also installed on this PC, run a WD copy of wsprd
declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
mkdir -p ${WSPRD_BIN_DIR}
declare WSPRD_CMD=${WSPRD_BIN_DIR}/wsprd
declare WSPRD_VERSION_CMD=${WSPRD_BIN_DIR}/wsprd.version
declare WSPRD_CMD_FLAGS="${WSPRD_CMD_FLAGS--C 500 -o 4 -d}"

### Only WSJT-x version 2.6.x runs on Pi Bullseye and Ubuntu 22.04 LTS.  On Pi Buster and Ubuntu 20.04 LTS only WSJT-x 2.5.4 runs
declare os_release    ### We are not in a function, so it can't be local
get_file_variable os_release "VERSION_ID" /etc/os-release
declare os_codename
get_file_variable os_codename "VERSION_CODENAME" /etc/os-release
wd_logger 2 "Installing on Linux '${os_codename}',  OS version = '${os_release}'"

if [[ "${os_codename}" == "buster" && "${os_release}" == "10"  ]]; then
    ### Running wsprd and jt9 on Pi "buster" requires WSJT-x 2.5.4
    wd_logger 2 "Installing on a Raspberry Pi running '${os_codename}', so install WSJT-x version 2.5.4"
    declare WSJTX_REQUIRED_VERSION="${WSJTX_REQUIRED_VERSION:-2.5.4}"
else
    ### The Debian ID is 10 or 11 on a Raspberry Pi and 20.05 or 18.04 on older Ubuntus.  All those are supported by WSJT-x 2.5.4 
    declare WSJTX_REQUIRED_VERSION="${WSJTX_REQUIRED_VERSION:-2.6.1}"
fi
wd_logger 2 "Running WSJT-x ${WSJTX_REQUIRED_VERSION} on Ubuntu ${os_release}"

### 10/14/20 RR: Always install the 'jt9', but only execute it if 'JT9_CMD_EANABLED="yes"' is added to wsprdaemon.conf
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare JT9_CMD_FLAGS="${JT9_CMD_FLAGS:---fst4w -p 120 -L 1400 -H 1600 -d 3}"
declare JT9_DECODE_ENABLED=${JT9_DECODE_ENABLED:-no}

declare INSTALLED_DEBIAN_PACKAGES=$(${DPKG_CMD} -l)
declare APT_GET_UPDATE_HAS_RUN="no"

function install_debian_package(){
    local package_name=$1
    local ret_code

    #if [[ " ${INSTALLED_DEBIAN_PACKAGES} " =~  " ${package_name} " ]]; then
    if dpkg -l ${package_name} >& /dev/null ; then
        wd_logger 2 "Package ${package_name} has already been installed"
        return 0
    fi
    wd_logger 1 "Package ${package_name} needs to be installed"
    if [[ ${APT_GET_UPDATE_HAS_RUN} == "no" ]]; then
        wd_logger 1 "'apt-get update' needs to be run"
        sudo apt-get update --allow-releaseinfo-change
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'sudo apt-get update' => ${ret_code}"
            return ${ret_code}
        fi
        APT_GET_UPDATE_HAS_RUN="yes"
    fi
    sudo apt-get install ${package_name} --assume-yes
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'sudo apt-get install ${package_name}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 1 "Installed ${package_name}"
    return 0
}

function install_python_package()
{
    local pip_package=$1

    wd_logger 2 "Verifying or Installing package ${pip_package}"
    if python3 -c "import ${pip_package}" 2> /dev/null; then
        wd_logger 2 "Found that package ${pip_package} is installed"
        return 0
    fi
    wd_logger 1 "Package ${pip_package} is not installed. Checking that pip3 is installed"
    if ! pip3 -V > /dev/null 2>&1 ; then
        wd_logger 1 "Installing pip3"
        if ! sudo apt install python3-pip -y ; then
            wd_logger 1 "ERROR: can't install pip3:  'sudo apt install python3-pip -y' => $?"
            exit 1
        fi
    fi
    wd_logger 1 "Having pip3 install package ${pip_package} "
    if [[ ${pip_package} == "psycopg2" ]]; then
        wd_logger 1 "'pip3 install ${pip_package}' requires 'apt install python3-dev libpq-dev'"
        sudo apt install python3-dev libpq-dev
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'sudo apt install python3-dev libpq-dev'  => ${rc}"
            exit ${rc}
        fi
    fi
    local pip3_extra_args=""
    if [[ ${os_release} == "12" ]]; then
        pip3_extra_args="--break-system-packages"
    fi
    if ! sudo pip3 install ${pip3_extra_args}  ${pip_package} ; then
        wd_logger 1 "ERROR: 'sudo pip3 ${pip_package}' => $?"
        exit 2
    fi
    wd_logger 1 "Installed Python package ${pip_package}"
    return 0
}

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
    
declare WSPRD_VERSION_CMD=${WSPRD_CMD}.version       ### Since WSJT-x wsprd doesn't have a '-V' to identify its version, save the version here

function load_wsjtx_commands()
{
    local wsprd_version=""
    if [[ -x ${WSPRD_VERSION_CMD} ]]; then
        wsprd_version=$( ${WSPRD_VERSION_CMD} )
    elif false; then
        wsprd_version=$(awk '/wsjtx /{print $3}' <<< "${dpkg_list}")
        if [[ -n "${wsprd_version}" ]] && [[ -x ${WSPRD_CMD} ]] && [[ ! -x ${WSPRD_VERSION_CMD} ]]; then
            sudo sh -c "echo 'echo ${wsprd_version}' > ${WSPRD_VERSION_CMD}"
            sudo chmod +x ${WSPRD_VERSION_CMD}
        fi
    fi

    ### Now install wsprd if it doesn't exist or if it is the wrong version
    if [[ ! -x ${WSPRD_CMD} ]] || [[ -z "${wsprd_version}" ]] || [[ ${wsprd_version} != ${WSJTX_REQUIRED_VERSION} ]]; then
        local os_name=""
        if [[ -f /etc/os-release ]]; then
            ### See if we are running on Ubuntu 20.04
            ### can't use 'source /etc/os-release' since the variable names in that conflict with variables in WD
            os_name=$(awk -F = '/^VERSION_CODENAME=/{print $2}' /etc/os-release | sed 's/"//g')
        fi

        if [[ "${os_name}" == "bullseye" && "${CPU_ARCH}" == "aarch64" ]]; then
            if [[ "${wsprd_version}" == "${PI_64BIT_BULLSEYE_WSJTX_REQUIRED_VERSION-2.3.0}" ]]; then
                wd_logger 2 "Found the expected wsprd version '${wsprd_version}' on 64 bit Pi bulleye"
                return 0
            fi
            wd_logger 1 "Installing wsjtx on a 64 bit Pi bullseye from 'apt'"
            sudo apt install wsjtx -y
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'sudo apt install wsjtx' failed on 64 bit Pi 'bullseye'"
                exit 1
            fi
            wsjtx_version=$( /usr/bin/wsjtx_app_version -v | awk '{print $2}' )
            if [[ "${wsjtx_version}" == "${PI_64BIT_BULLSEYE_WSJTX_REQUIRED_VERSION-2.6.1}" ]]; then
                mkdir -p ${WSPRD_BIN_DIR}
                cp /usr/bin/{wsprd,jt9} ${WSPRD_BIN_DIR}
                echo "echo ${wsjtx_version}" > ${WSPRD_VERSION_CMD}
                chmod +x ${WSPRD_VERSION_CMD}
                wd_logger 1 "Installed WSJT-x version ${wsjtx_version} on this 64 bit Pi bullseye"
                return 0
            fi
            wd_logger 1 "ERROR: wrong wsjtx version '${wsjtx_version}' on 64 bit Pi bulleye.  So installing from WSJT-x repo"
        fi
        local wsjtx_pkg=""
        case ${CPU_ARCH} in
            x86_64)
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_amd64.deb
                ;;
            armv7l)
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_armhf.deb
                ;;
            aarch64)
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_arm64.deb
                ;;
            *)
                wd_logger 1 "ERROR: CPU architecture '${CPU_ARCH}' is not supported by this program"
                exit 1
                ;;
        esac
        ### Download WSJT-x and extract its files and copy wsprd to /usr/bin/
        local wsjtx_dpkg_file=${WSPRDAEMON_TMP_DIR}/${wsjtx_pkg}
        WSJTX_SERVER_URL="${WSJTX_SERVER_URL-https://sourceforge.net/projects/wsjt/files}"
        wget ${WSJTX_SERVER_URL}/${wsjtx_pkg} -O ${wsjtx_dpkg_file}
        local rc=$?
        if [[ ${rc} -ne 0 || ! -f ${wsjtx_dpkg_file} ]] ; then
            wd_logger 1 "ERROR: failed to download ${WSJTX_SERVER_URL}/${wsjtx_pkg}"
            exit 1
        fi
        local dpkg_tmp_dir=${WSPRDAEMON_TMP_DIR}/dpkg_wsjt
        mkdir -p ${dpkg_tmp_dir}
        dpkg-deb -x ${wsjtx_dpkg_file} ${dpkg_tmp_dir}
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]] ; then
            wd_logger 1 "ERROR: on ${os_name} failed to extract files from package file ${wsjtx_pkg_file}"
            exit 1
        fi
        local dpkg_wsprd_file=${dpkg_tmp_dir}/usr/bin/wsprd
        if [[ ! -x ${dpkg_wsprd_file} ]]; then
            wd_logger 1 "ERROR: failed to find executable '${dpkg_wsprd_file}' in the downloaded WSJT-x package"
            exit 1
        fi
        cp -p ${dpkg_wsprd_file} ${WSPRD_CMD} 
        echo "echo ${WSJTX_REQUIRED_VERSION}" > ${WSPRD_VERSION_CMD}
        chmod +x ${WSPRD_VERSION_CMD}
        wd_logger 1 "Installed  ${WSPRD_CMD} version ${WSJTX_REQUIRED_VERSION}"

        local dpkg_jt9_file=${dpkg_tmp_dir}/usr/bin/jt9 
        if [[ ! -x ${dpkg_jt9_file} ]]; then
            wd_logger 1 "ERROR: failed to find executable '${dpkg_jt9_file}' in the downloaded WSJT-x package"
            exit 1
        fi
        sudo apt install libboost-log1.67.0       ### Needed by jt9
        cp -p ${dpkg_jt9_file} ${JT9_CMD} 
        wd_logger 1 "Installed  ${JT9_CMD} version ${WSJTX_REQUIRED_VERSION}"
    fi
    local wsjtx_dpkg_file_list=( $(find ${WSPRDAEMON_TMP_DIR} -name 'wsjtx_*.deb' ) )
    if [[ ${#wsjtx_dpkg_file_list[@]} -gt 0 ]]; then
        wd_logger 1 "Flushing files: '${wsjtx_dpkg_file_list[*]}'"
        wd_rm ${wsjtx_dpkg_file_list[@]}
    fi
    local dpkg_tmp_dir=${WSPRDAEMON_TMP_DIR}/dpkg_wsjt
    if [[ -d ${dpkg_tmp_dir} ]]; then
        wd_logger 1 "Flushing ${dpkg_tmp_dir}"
        rm -r ${dpkg_tmp_dir}
    fi
}

### 11/1/22 - It appears that last summer a bug was introduced into Ubuntu 20.04 which casues kiwiwrecorder.py to crash if there are no active ssh sessions
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

### This is called once at startup
function check_for_needed_utilities()
{
    setup_wd_auto_ssh

    local package_needed
    for package_needed in ${PACKAGE_NEEDED_LIST[@]}; do
        wd_logger 2 "Checking for package ${package_needed}"
        if ! install_debian_package ${package_needed} ; then
            wd_logger 1 "ERROR: 'install_debian_package ${package_needed}' => $?"
            exit 1
        fi
    done
    wd_logger 2 "Checking for WSJT-x utilities 'wsprd' and 'jt9'"
    load_wsjtx_commands
    wd_logger 2 "Setting up noise graphing"
    setup_noise_graphs
}

### The configuration may determine which utilities are needed at run time, so now we can check for needed utilities
