#!/bin/bash
declare -i verbosity=${verbosity:-1}

declare -r WSPRDAEMON_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/${0##*/}"
################# Check that our recordings go to a tmpfs (i.e. RAM disk) file system ################
declare WSPRDAEMON_TMP_DIR=/tmp/wspr-captures
if df ${WSPRDAEMON_TMP_DIR} > /dev/null 2>&1; then
    ### Legacy name for /tmp file system.  Leave it alone
    true
else
    WSPRDAEMON_TMP_DIR=/tmp/wsprdaemon
fi

declare WD_TIME_FMT=${WD_TIME_FMT-%(%a %d %b %Y %H:%M:%S %Z)T}   ### Used by printf "${WD_TIME}: ..." in lieu of $(date)

declare -r CPU_ARCH=$(uname -m)
case ${CPU_ARCH} in
    armv7l)
        ### Add code to support installation on Pi's bullseye OS
        declare QT5_PACKAGE=qt5-default:armhf 
        if [[ "${OSTYPE}" == "linux-gnueabihf" ]] ; then
            QT5_PACKAGE=libqt5core5a:armhf  ### on Pi's bullseye
        fi
        declare -r PACKAGE_NEEDED_LIST=( at bc curl ntp postgresql sox libgfortran5:armhf ${QT5_PACKAGE})
        ;;
    x86_64)
        declare -r PACKAGE_NEEDED_LIST=( at bc curl ntp postgresql sox libgfortran5:amd64 qt5-default:amd64)
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

declare -r WSPRDAEMON_CONFIG_FILE=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.conf
declare -r WSPRDAEMON_CONFIG_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/wd_template.conf

### Check that there is a conf file
if [[ ! -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
    echo "WARNING: The configuration file '${WSPRDAEMON_CONFIG_FILE}' is missing, so it is being created from a template."
    echo "         Edit that file to match your Reciever(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
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

### If the user has enabled a remote proxy connection in the conf file, then start up that connection now.
declare -r WSPRDAEMON_PROXY_UTILS_FILE=${WSPRDAEMON_ROOT_DIR}/proxy_utils.sh
source ${WSPRDAEMON_PROXY_UTILS_FILE}
proxy_connection_manager      

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
declare   KIWI_RECORD_TMP_LOG_FILE="./kiwiclient.log"

function check_for_kiwirecorder_cmd() {
    local get_kiwirecorder="no"
    local apt_update_done="no"
    if [[ ! -x ${KIWI_RECORD_COMMAND} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): check_for_kiwirecorder_cmd() found no ${KIWI_RECORD_COMMAND}"
        get_kiwirecorder="yes"
    else
        ## kiwirecorder.py has been installed.  Check to see if kwr is missing some needed modules
        [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_kiwirecorder_cmd() found  ${KIWI_RECORD_COMMAND}"
        local log_file=/tmp/${KIWI_RECORD_TMP_LOG_FILE}
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
        git clone git://github.com/jks-prv/kiwiclient
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
declare WSJTX_REQUIRED_VERSION="${WSJTX_REQUIRED_VERSION:-2.5.2}"

### 10/14/20 RR: Always install the 'jt9', but only execute it if 'JT9_CMD_EANABLED="yes"' is added to wsprdaemon.conf
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare JT9_CMD_FLAGS="${JT9_CMD_FLAGS:---fst4w -p 120 -L 1400 -H 1600 -d 3}"
declare JT9_DECODE_EANABLED=${JT9_DECODE_EANABLED:-no}

declare INSTALLED_DEBIAN_PACKAGES=$(${DPKG_CMD} -l)
declare APT_GET_UPDATE_HAS_RUN="no"

function install_debian_package(){
    local package_name=$1
    local ret_code

    if [[ " ${INSTALLED_DEBIAN_PACKAGES} " =~  " ${package_name} " ]]; then
        wd_logger 2 "Package ${package_name} has already been installed"
        return 0
    fi
    if [[ ${APT_GET_UPDATE_HAS_RUN} == "no" ]]; then
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

    wd_logger 1 "Verifying or Installing package ${pip_package}"
    if python3 -c "import ${pip_package}" 2> /dev/null; then
        wd_logger 1 "Found that package ${pip_package} is installed"
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
    if ! sudo pip3 install ${pip_package} ; then
        wd_logger 1 "ERROR: 'sudo pip3 ${pip_package}' => $?"
        exit 2
    fi
    wd_logger 1 "Installed Python package ${pip_package}"
    return 0
}

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
    else
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
            os_name=$(awk -F = '/^VERSION=/{print $2}' /etc/os-release | sed 's/"//g')
        fi

        local wsjtx_pkg=""
        case ${CPU_ARCH} in
            x86_64)
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_amd64.deb
                ;;
            armv7l)
                # https://physics.princeton.edu/pulsar/K1JT/wsjtx_2.2.1_armhf.deb
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
        wget http://physics.princeton.edu/pulsar/K1JT/${wsjtx_pkg} -O ${wsjtx_dpkg_file}
        if [[ ! -f ${wsjtx_dpkg_file} ]] ; then
            wd_logger 1 "ERROR: failed to download wget http://physics.princeton.edu/pulsar/K1JT/${wsjtx_pkg}"
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
    local wsjtx_dpkg_file_list=( $(find ${WSPRDAEMON_TMP_DIR} -name wsjtx_*.deb ) )
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

function check_for_needed_utilities()
{
    local package_needed
    for package_needed in ${PACKAGE_NEEDED_LIST[@]}; do
        wd_logger 1 "Checking for package ${package_needed}"
        if ! install_debian_package ${package_needed} ; then
            wd_logger 1 "ERROR: 'install_debian_package ${package_needed}' => $?"
            exit 1
        fi
    done
    wd_logger 1 "Checking for Python's astral library"
    if ! install_python_package astral; then
        wd_logger 1 "ERROR: failed to install Python package 'astral'"
        exit 1
    fi
    wd_logger 1 "Checking for WSJT-x utilities 'wsprd' and 'jt9'"
    load_wsjtx_commands
    wd_logger 1 "Setting up noise graphing"
    setup_noise_graphs
}

### The configuration may determine which utilities are needed at run time, so now we can check for needed utilities
