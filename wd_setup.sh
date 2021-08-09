
###################### Check OS ###################
if [[ "${OSTYPE}" == "linux-gnueabihf" ]] || [[ "${OSTYPE}" == "linux-gnu" ]] ; then
    ### We are running on a Rasperberry Pi or generic Debian server
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
    mv ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE}
    exit
fi
### Check that the conf file differs from the prototype conf file
if diff -q ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE} > /dev/null; then
    echo "WARNING: The configuration file '${WSPRDAEMON_CONFIG_FILE}' is the same as the template."
    echo "         Edit that file to match your Reciever(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
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

### If the user has enabled a remote proxy connection in the conf file, then start up that connecton now.
declare -r WSPRDAEMON_PROXY_UTILS_FILE=${WSPRDAEMON_ROOT_DIR}/proxy_utils.sh
source ${WSPRDAEMON_PROXY_UTILS_FILE}
proxy_connection_manager      

################# Check that our recordings go to a tmpfs (i.e. RAM disk) file system ################
declare WSPRDAEMON_TMP_DIR=/tmp/wspr-captures
if df ${WSPRDAEMON_TMP_DIR} > /dev/null 2>&1; then
    ### Legacy name for /tmp file system.  Leave it alone
    true
else
    WSPRDAEMON_TMP_DIR=/tmp/wsprdaemon
fi
function check_tmp_filesystem()
{
    if [[ ! -d ${WSPRDAEMON_TMP_DIR} ]]; then
        [[ $verbosity -ge 0 ]] && echo "The directrory system for WSPR recordings does not exist.  Creating it"
        if ! mkdir -p ${WSPRDAEMON_TMP_DIR} ; then
            "ERROR: Can't create the directrory system for WSPR recordings '${WSPRDAEMON_TMP_DIR}'"
            exit 1
        fi
    fi
    if df ${WSPRDAEMON_TMP_DIR} | grep -q tmpfs ; then
        [[ $verbosity -ge 2 ]] && echo "check_tmp_filesystem() found '${WSPRDAEMON_TMP_DIR}' is a tmpfs file system"
    else
        if [[ "${USE_TMPFS_FILE_SYSTEM-yes}" != "yes" ]]; then
            echo "WARNING: configured to record to a non-ram file system"
        else
            echo "WARNING: This server is not configured so that '${WSPRDAEMON_TMP_DIR}' is a 300 MB ram file system."
            echo "         Every 2 minutes this program can write more than 200 Mbps to that file system which will prematurely wear out a microSD or SSD"
            read -p "So do you want to modify your /etc/fstab to add that new file system? [Y/n]> "
            REPLY=${REPLY:-Y}     ### blank or no response change to 'Y'
            if [[ ${REPLY^} != "Y" ]]; then
                echo "WARNING: you have chosen to use to non-ram file system"
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
        echo "Successfully installed kwirecorder.py"
        cd - >& /dev/null
    fi
}

if ! check_for_kiwirecorder_cmd ; then
    echo "ERROR: failed to find or load Kiwi recording utility '${KIWI_RECORD_COMMAND}'"
    exit 1
fi


################################### Noise level logging 
declare -r SIGNAL_LEVELS_WWW_DIR=/var/www/html
declare -r SIGNAL_LEVELS_WWW_INDEX_FILE=${SIGNAL_LEVELS_WWW_DIR}/index.html
declare -r NOISE_GRAPH_FILENAME=noise_graph.png
declare -r SIGNAL_LEVELS_NOISE_GRAPH_FILE=${WSPRDAEMON_TMP_DIR}/${NOISE_GRAPH_FILENAME}          ## If configured, this is the png graph copied to the graphs.wsprdaemon.org site and displayed by the local Apache server
declare -r SIGNAL_LEVELS_TMP_NOISE_GRAPH_FILE=${WSPRDAEMON_TMP_DIR}/wd_tmp.png                   ## If configured, this is the file created by the python graphing program
declare -r SIGNAL_LEVELS_WWW_NOISE_GRAPH_FILE=${SIGNAL_LEVELS_WWW_DIR}/${NOISE_GRAPH_FILENAME}   ## If we have the Apache serivce running to locally display noise graphs, then this will be a symbolic link to ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}
declare -r SIGNAL_LEVELS_TMP_CSV_FILE=${WSPRDAEMON_TMP_DIR}/wd_log.csv

function ask_user_to_install_sw() {
    local prompt_string=$1
    local is_requried_by_wd=${2:-}

    echo ${prompt_string}
    read -p "Do you want to proceed with the installation of that this software? [Yn] > "
    REPLY=${REPLY:-Y}
    REPLY=${REPLY:0:1}
    if [[ ${REPLY^} != "Y" ]]; then
        if [[ -n "${is_requried_by_wd}" ]]; then
            echo "${is_requried_by_wd} is a software utility required by wsprdaemon and must be installed for it to run"
        else
            echo "WARNING: change wsprdaemon.conf to avoid installtion of this software"
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
declare WSJTX_REQUIRED_VERSION="${WSJTX_REQUIRED_VERSION:-2.3.0}"

### 10/14/20 RR: Always install the 'jt9', but only execute it if 'JT9_CMD_EANABLED="yes"' is added to wsprdaemon.conf
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare JT9_CMD_FLAGS="${JT9_CMD_FLAGS:---fst4w -p 120 -L 1400 -H 1600 -d 3}"
declare JT9_DECODE_EANABLED=${JT9_DECODE_EANABLED:-no}

function check_for_needed_utilities()
{
    ### TODO: Check for kiwirecorder only if there are kiwis receivers spec
    local apt_update_done="no"
    local dpkg_list=$(${DPKG_CMD} -l)

    if ! [[ ${dpkg_list} =~ " at " ]] ; then
        ### Used by the optional wsprd_vpn service
        [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
        sudo apt-get install at --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'at' which is needed iby the wspd_vpn service"
            exit 1
        fi
    fi
    if !  [[ ${dpkg_list} =~ " bc " ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
        sudo apt-get install bc --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'bc' which is needed for floating point frequency calculations"
            exit 1
        fi
    fi
    if ! [[ ${dpkg_list} =~ " curl " ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
        sudo apt-get install curl --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'curl' which is needed for uploading to wsprnet.org and wsprdaemon.org"
            exit 1
        fi
    fi
    if ! [[ ${dpkg_list} =~ " ntp " ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
        sudo apt-get install ntp --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'ntp' which is needed to ensure synchronization with the 2 minute WSPR cycle"
            exit 1
        fi
    fi
    if !  [[ ${dpkg_list} =~ " postgresql  " ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
        sudo apt-get install postgresql libpq-dev postgresql-client postgresql-client-common --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'postgresql' which is needed for logging spots and noise to wsprdaemon.org"
            exit 1
        fi
    fi
    if !  [[ ${dpkg_list} =~ " sox  " ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
        sudo apt-get install sox --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'sox' which is needed for RMS noise level calculations"
            exit 1
        fi
    fi
    ### WD uses the 'wsprd' binary from the WSJT-x package.  The following section insures that one binary we use from that package is installed
    ### 9/16/20 RR - WSJT-x doesn't yet install on Ubuntu 20.04, so special case that.
    ### 'wsprd' doesn't report its version number (e.g. with wsprd -V), so on most systems we learn the version from 'dpkt -l'.
    ### On Ubuntu 20.04 we can't install the package, so we can't learn the version number from dpkg.
    ### So on Ubuntu 20.04 we assume that if wsprd is installed it is the correct version
    ### Perhaps I will save the version number of wsprd and use this process on all OSs
    
    if !  [[ ${dpkg_list} =~ " libgfortran5:" ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
        sudo apt-get install libgfortran5 --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'libgfortran5' which is needed to run wsprd V2.3.xxxx"
            exit 1
        fi
    fi
    if !  [[ ${dpkg_list} =~ " qt5-default:" ]] ; then
        [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
        sudo apt-get install qt5-default --assume-yes
        local ret_code=$?
        if [[ $ret_code -ne 0 ]]; then
            echo "FATAL ERROR: Failed to install 'qt5-default' which is needed to run the 'jt9' copmmand in wsprd V2.3.xxxx"
            exit 1
        fi
    fi

    ### If wsprd is installed, try to get its version number
    declare WSPRD_VERSION_CMD=${WSPRD_CMD}.version       ### Since WSJT-x wsprd doesn't have a '-V' to identify its version, save the version here
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
        local cpu_arch=$(uname -m)
        local wsjtx_pkg=""
        case ${cpu_arch} in
            x86_64)
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_amd64.tar.gz
                ;;
            armv7l)
                # https://physics.princeton.edu/pulsar/K1JT/wsjtx_2.2.1_armhf.deb
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_armhf.tar.gz
                ;;
            *)
                echo "ERROR: CPU architecture '${cpu_arch}' is not supported by this program"
                exit 1
                ;;
        esac
        ### Download WSJT-x and extract its files and copy wsprd to /usr/bin/
        local wsjtx_dpkg_file=${WSPRDAEMON_TMP_DIR}/${wsjtx_pkg}
        wget http://physics.princeton.edu/pulsar/K1JT/${wsjtx_pkg} -O ${wsjtx_dpkg_file}
        if [[ ! -f ${wsjtx_dpkg_file} ]] ; then
            echo "ERROR: failed to download wget http://physics.princeton.edu/pulsar/K1JT/${wsjtx_pkg}"
            exit 1
        fi
        local dpkg_tmp_dir=${WSPRDAEMON_TMP_DIR}/dpkg_wsjt
        mkdir -p ${dpkg_tmp_dir}
        dpkg-deb -x ${wsjtx_dpkg_file} ${dpkg_tmp_dir}
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]] ; then
            echo "ERROR: on ${os_name} failed to extract files from package file ${wsjtx_pkg_file}"
            exit 1
        fi
        local dpkg_wsprd_file=${dpkg_tmp_dir}/usr/bin/wsprd
        if [[ ! -x ${dpkg_wsprd_file} ]]; then
            echo "ERROR: failed to find executable '${dpkg_wsprd_file}' in the dowloaded WSJT-x package"
            exit 1
        fi
        cp -p ${dpkg_wsprd_file} ${WSPRD_CMD} 
        echo "echo ${WSJTX_REQUIRED_VERSION}" > ${WSPRD_VERSION_CMD}
        chmod +x ${WSPRD_VERSION_CMD}
        echo "Installed  ${WSPRD_CMD} version ${WSJTX_REQUIRED_VERSION}"

        local dpkg_jt9_file=${dpkg_tmp_dir}/usr/bin/jt9 
        if [[ ! -x ${dpkg_jt9_file} ]]; then
            echo "ERROR: failed to find executable '${dpkg_jt9_file}' in the dowloaded WSJT-x package"
            exit 1
        fi
        sudo apt install libboost-log1.67.0       ### Needed by jt9
        cp -p ${dpkg_jt9_file} ${JT9_CMD} 
        echo "Installed  ${JT9_CMD} version ${WSJTX_REQUIRED_VERSION}"
    fi

    if ! python3 -c "import psycopg2" 2> /dev/null ; then
        if !  sudo pip3 install psycopg2 ; then
            [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
            sudo apt-get install python3-pip --assume-yes
            local ret_code=$?
            if [[ $ret_code -ne 0 ]]; then
                echo "FATAL ERROR: Failed to install 'pip3' which is needed for logging spots and noise to wsprdaemon.org"
                exit 1
            fi
            if !  sudo pip3 install psycopg2 ; then
                echo "FATAL ERROR: ip3 can't install the Python3 'psycopg2' library used to upload spot and noise data to wsprdaemon.org"
                exit 1
            fi
        fi
    fi
    if [[ ${SIGNAL_LEVEL_SOX_FFT_STATS:-no} == "yes" ]]; then
        local tmp_wspr_captures__file_system_size_1k_blocks=$(df ${WSPRDAEMON_TMP_DIR}/ | awk '/tmpfs/{print $2}')
        if [[ ${tmp_wspr_captures__file_system_size_1k_blocks} -lt 307200 ]]; then
            echo " WARNING: the ${WSPRDAEMON_TMP_DIR}/ file system is ${tmp_wspr_captures__file_system_size_1k_blocks} in size"
            echo "   which is less than the 307200 size needed for an all-WSPR band system"
            echo "   You should consider increasing its size by editing /etc/fstab and remounting ${WSPRDAEMON_TMP_DIR}/"
        fi
    fi
    if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]] || [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS-no} == "yes" ]] ; then
        ### Get the Python packages needed to create the graphs.png
        if !  [[ ${dpkg_list} =~ " python3-matplotlib " ]] ; then
            # ask_user_to_install_sw "SIGNAL_LEVEL_LOCAL_GRAPHS=yes and/or SIGNAL_LEVEL_UPLOAD_GRAPHS=yes require that some Python libraries be added to this server"
            [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
            sudo apt-get install python3-matplotlib --assume-yes
        fi
        if !  [[ ${dpkg_list} =~ " python3-scipy " ]] ; then
            # ask_user_to_install_sw "SIGNAL_LEVEL_LOCAL_GRAPHS=yes and/or SIGNAL_LEVEL_UPLOAD_GRAPHS=yes require that some more Python libraries be added to this server"
            [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
            sudo apt-get install python3-scipy --assume-yes
        fi
        if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]] ; then
            ## Ensure that Apache is installed and running
            if !  [[ ${dpkg_list} =~ " apache2 " ]]; then
                # ask_user_to_install_sw "SIGNAL_LEVEL_LOCAL_GRAPHS=yes requires that the Apache web service be added to this server"
                [[ ${apt_update_done} == "no" ]] && sudo apt-get update && apt_update_done="yes"
                sudo apt-get install apache2 -y --fix-missing
            fi
            local index_tmp_file=${WSPRDAEMON_TMP_DIR}/index.html
            cat > ${index_tmp_file} <<EOF
<html>
<header><title>This is title</title></header>
<body>
<img src="${NOISE_GRAPH_FILENAME}" alt="Noise Graphics" >
</body>
</html>
EOF
            if ! diff ${index_tmp_file} ${SIGNAL_LEVELS_WWW_INDEX_FILE} > /dev/null; then
                sudo cp -p  ${SIGNAL_LEVELS_WWW_INDEX_FILE} ${SIGNAL_LEVELS_WWW_INDEX_FILE}.orig
                sudo mv     ${index_tmp_file}               ${SIGNAL_LEVELS_WWW_INDEX_FILE}
            fi
            if [[ ! -f ${SIGNAL_LEVELS_WWW_NOISE_GRAPH_FILE} ]]; then
                ## /var/html/www/noise_grapsh.png doesn't exist. It can't be a symnlink ;=(
                touch        ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}
                sudo  cp -p  ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}  ${SIGNAL_LEVELS_WWW_NOISE_GRAPH_FILE}
            fi
        fi
    fi ## [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS} == "yes" ]] || [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS} == "yes" ]] ; then
    if ! python3 -c "import astral" 2> /dev/null ; then
        if ! sudo apt-get install python3-astral -y ; then
            if !  pip3 install astral ; then
                if ! sudo apt-get install python-pip3 -y ; then
                    echo "$(date) check_for_needed_utilities() ERROR: sudo can't install 'pip3' needed to install the Python 'astral' library"
                else
                    if !  pip3 install astral ; then
                        echo "$(date) check_for_needed_utilities() ERROR: pip can't install the Python 'astral' library used to calculate sunup/sunset times"
                    fi
                fi
            fi
        fi
    fi
}

### The configuration may determine which utlites are needed at run time, so now we can check for needed utilites

