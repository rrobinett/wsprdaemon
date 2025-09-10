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


declare -i verbosity=${verbosity:-1}   ### Defaults to -1 so these wd_setup wd_logger lines are printed to the terminal

declare -r WSPRDAEMON_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/${0##*/}"
declare -r WSPRDAEMON_CONFIG_FILE=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.conf
declare -r WSPRDAEMON_CONFIG_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/wd_template.conf

### This is used by two .sh files, so it need to be declared here
declare NOISE_GRAPHS_REPORTER_INDEX_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/noise_graphs_reporter_index_template.html    ### This is put into each reporter's www/html/graphs/REPORTER directory

declare WD_TIME_FMT=${WD_TIME_FMT-%(%a %d %b %Y %H:%M:%S %Z)T}   ### Used by printf "${WD_TIME}: ..." in lieu of $(date)

### If the user has enabled ia Romote Access Channel to this machine by defining "REMOTE_ACCESS_CHANNEL=NN' in the wsprdaemon.conf file,
###     install and enable the remote access service as early as possible in WD's startup so it is more likely that I can log in an help with installation problems
### If RAC or REMOTE_ACCESS_CHANNEL is not defined, then disable and stop the 'wd_remote_access' service if it is installed and running
declare -r REMOTE_ACCESS_SERVICES=${WSPRDAEMON_ROOT_DIR}/remote-access-service.sh
source ${REMOTE_ACCESS_SERVICES}
wd_remote_access_service_manager

declare VERSION_ID    ### We are not in a function, so it can't be local
get_file_variable VERSION_ID "VERSION_ID" /etc/os-release

declare VERSION_CODENAME
get_file_variable VERSION_CODENAME "VERSION_CODENAME" /etc/os-release

declare CPU_ARCH
CPU_ARCH=$(uname -m)

wd_logger 2 "Installing on Linux '${VERSION_CODENAME}',  OS version = '${VERSION_ID}', CPU_ARCH=${CPU_ARCH}"

if [[ "$(timedatectl show -p NTPSynchronized --value)" != "yes" ]]; then
    wd_logger 1 "WARNING: the system clock is not synchronized"
fi

### Ensure this server never puts itself to sleep
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

#####################################################################################################
### Install all packages needed by WD and most of the programs it runs
declare    PACKAGE_NEEDED_LIST=( tmux iw time vim at bc curl gawk bind9-host flac postgresql sox zstd avahi-daemon libnss-mdns inotify-tools \
                libbsd-dev libavahi-client-dev libfftw3-dev libiniparser-dev libopus-dev opus-tools uuid-dev \
                libusb-dev libusb-1.0-0 libusb-1.0-0-dev libairspy-dev libairspyhf-dev portaudio19-dev librtlsdr-dev \
                libncurses-dev bzip2 wavpack libsamplerate0 libsamplerate0-dev lsof )
                ### avahi-daemon libnss-mdns are not included in the OrangePi's Armbien OS.  libnss-mymachines may also be needed

if [[ ${HOSTNAME:0:2} == "WD" ]]; then
    PACKAGE_NEEDED_LIST+=( jq )
fi

if ! grep -q "Raspbian.*buster" /etc/os-release; then
    ### 'btop' isn't part of the Pi's buster distro.  Perhaps other distros will have that problem
    PACKAGE_NEEDED_LIST+=( btop )
fi

if grep -q "Debian.*12" /etc/os-release; then
    PACKAGE_NEEDED_LIST+=(  linux-cpupower )
fi

if grep -q "Debian.*13" /etc/os-release; then
    wd_logger 2 "Running on a Debian 13 server"
    PACKAGE_NEEDED_LIST+=(  libqt5core5t64 linux-cpupower )
else
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
        PACKAGE_NEEDED_LIST+=( libsndfile1-dev python3-pip libgfortran5:arm64 ${LIB_QT5_DEFAULT_ARM64} )
         if [[ "${VERSION_ID}" == "11" ]]; then
            ### The 64 bit Pi5 OS is based upon Debian 12
            wd_logger 2 "Installing on a Pi5 which is based upon Debian ${VERSION_ID}"
            PACKAGE_NEEDED_LIST+=(  python3-matplotlib )
         fi
        ;;
    x86_64)
        wd_logger 2 "Installing on Linux VERSION_ID='${VERSION_ID}'"
        if [[ "${VERSION_ID}" =~ 2[02].04 || "${VERSION_ID}" =~ ^1[23] || "${VERSION_ID}" =~ 21.. ]]; then
            ### Ubuntu 22.04 and Debian don't use qt5-default
            PACKAGE_NEEDED_LIST+=( python3-matplotlib python3-numpy libgfortran5:amd64 ${LIB_QT5_CORE_AMD64} )
        elif [[ "${VERSION_ID}" =~ 24.04 ]]; then
            PACKAGE_NEEDED_LIST+=( libhdf5-dev  python3-matplotlib libgfortran5:amd64 python3-dev libpq-dev python3-psycopg2 ${LIB_QT5_CORE_UBUNTU_24_04})
        elif [[ "${VERSION_ID}" =~ 24.10 ]]; then
            PACKAGE_NEEDED_LIST+=( python3-numpy libgfortran5:amd64 libqt5core5t64 python3-psycopg2 )
        elif grep -q 'Linux Mint' /etc/os-release; then
            PACKAGE_NEEDED_LIST+=( python3-matplotlib python3-numpy python3-psycopg2 libgfortran5:amd64 ${LIB_QT5_LINUX_MINT} )
        else
            PACKAGE_NEEDED_LIST+=( libgfortran5:amd64 ${LIB_QT5_DEFAULT_AMD64} )
        fi
        ;;
    *)
        wd_logger 1 "ERROR: wsrpdaemon doesn't know what libraries are needed when running on CPU_ARCH=${CPU_ARCH}"
        exit 1
        ;;
esac
fi

### The configuration may determine which utilities are needed at run time, so now we can check for needed utilities
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
    wd_logger 2 "Done"
}
if ! install_needed_dpkgs ; then
    wd_logger 1  "ERROR: failed to load all the libraries needed on this server"
    exit 1
fi

########################################### 
function is_orange_pi_5() {
    if grep -q 'Rockchip RK3588' /proc/cpuinfo 2>/dev/null || \
       grep -q "Orange Pi 5" /sys/firmware/devicetree/base/model 2>/dev/null; then
        return 0  # Success (Orange Pi5 detected)
    else
        return 1  # Failure (Not an Orange Pi5)
    fi
}

### Debug who is calling kill
kill() {
    local stderr
    stderr="$(command kill "$@" 2>&1 1>&3)"
    local status=$?
    if [[ -n "$stderr" ]]; then
        {
            echo "[kill wrapper] ${BASH_SOURCE[1]}:${BASH_LINENO[0]}: kill $*"
            echo "$stderr"
        } >&2
    fi
    return $status
}
exec 3>&1
export -f kill


### Change to find() in order to debug spurious find errors which are printed stderr output
function find() {
    local tmp
    tmp=$(mktemp)
    command find "$@" 2> "$tmp"
    local rc=$?
    if [[ -s $tmp ]]; then
        echo -e "'find() $@' -> called from function ${FUNCNAME[1]} in file ${BASH_SOURCE[1]} line #${BASH_LINENO[0]} printed:\n$(<"$tmp")" >&2
        rm -f "$tmp"
        exit 1
    fi
    rm -f "$tmp"
    return $rc
}
 export -f find

declare CPU_CGROUP_PATH="/sys/fs/cgroup"
declare WD_CPUSET_PATH="${CPU_CGROUP_PATH}/wsprdaemon"

### Restrict WD and its children so two CPU cores are always free for KA9Q-radio
# This should be undone later on systems not running KA9Q-radio
function wd_run_in_cgroup() {
    local rc
    local wd_core_range

    if [[ "${VERSION_ID}" =~ 20.04 ]]; then
        wd_logger 2 "Skipping CPUAffinity setup which isn't supported on '${VERSION_CODENAME}' version = '${VERSION_ID}'"
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
        wd_logger 2 "Restricting WD to run in the default range '$wd_core_range'"
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
                 wd_logger 2 "update_ini_file_section_variable $wd_service_file 'Service' 'CPUAffinity' '$wd_core_range'  was already setup"
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
    wd_logger 2 "WD is being run by a terminal session, so set CPUAffinity to run on cores '$wd_core_range'"
 
    echo  "+cpuset"         | sudo tee "${CPU_CGROUP_PATH}/cgroup.subtree_control" > /dev/null
    sudo mkdir -p  "${WD_CPUSET_PATH}"
    echo  "+cpuset"         | sudo tee "${WD_CPUSET_PATH}/cgroup.subtree_control"  > /dev/null
    echo  0                 | sudo tee "${WD_CPUSET_PATH}/cpuset.mems"             > /dev/null  ### This must be done before the next line
    echo  ${wd_core_range}  | sudo tee "${WD_CPUSET_PATH}/cpuset.cpus"             > /dev/null  ###
    echo $$                 | sudo tee "${WD_CPUSET_PATH}/cgroup.procs"            > /dev/null

    wd_logger 2 "Restricted current WD shell $$ and its children to CPU cores ${wd_core_range}"
}
wd_run_in_cgroup

declare CPU_FREQ_MIN_KHZ=${CPU_FREQ_MIN_KHZ-1000000}
declare CPU_FREQ_MAX_KHZ=${CPU_FREQ_MAX_KHZ-5000000}

function turbo_control() {
    action="${1:-off}"   # default to "off" if no argument
    case "$action" in
        off|disable)
            desired_intel=1   # no_turbo=1 means disabled
            desired_amd=0     # boost=0 means disabled
            ;;
        on|enable)
            desired_intel=0   # no_turbo=0 means enabled
            desired_amd=1     # boost=1 means enabled
            ;;
        *)
            wd_logger 1 "Usage: turbo_control [on|off]"
            return 1
            ;;
    esac

    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        current=$(< /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [[ $current -ne $desired_intel ]]; then
            wd_logger 1 "Setting Intel turbo $action..."
            echo "$desired_intel" | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo >/dev/null
        else
            wd_logger 2 "Intel turbo already $action"
        fi

    elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        current=$(< /sys/devices/system/cpu/cpufreq/boost)
        if [[ $current -ne $desired_amd ]]; then
            wd_logger 1 "Setting AMD/ACPI boost $action..."
            echo "$desired_amd" | sudo tee /sys/devices/system/cpu/cpufreq/boost >/dev/null
        else
            wd_logger 2 "AMD/ACPI boost already $action"
        fi

    else
        wd_logger 2 "Turbo/Boost control not supported on this CPU+kernel"
        return 1
    fi
}

function wd-set-cpu-speed() {
    local cpu_core_khz="${1}"
    local config_list=( ${cpu_core_khz//,/ } ) G
    if (( ${#config_list[@]} == 0 )); then
        wd_logger 1 "ERROR: CPU_CORE_KHZ is defined but empty "
        return 0
    fi
    if ! [[ " ${config_list[@]} " == *DEFAULT* ]] ; then
        wd_logger 1 "ERROR: CPU_CORE_KHZ is defined but has no 'DEFAULT:<KHZ>' defined"
    fi
    local config="$1"
    if [[ -z "$config" ]]; then
        wd_logger 1 "Usage: wd_set_core_freqs \"DEFAULT:<freq>,<core>:<freq>,...\""
        return 0
    fi
    wd_logger 2 "Parsing the ${#config_list[@]} elements of CPU_CORE_KHZ='${cpu_core_khz}'"

    local default_khz=""
    local element
    for element in ${config_list[@]}; do
        wd_logger 2 "Checking element='${element}'"
        if [[ ${element} == DEFAULT:* ]]; then
            wd_logger 2 "Found a default DEFAULT element '${element}'"
            default_khz=${element##*:}
            if [[ -z "${default_khz}" ]]; then
                wd_logger 1 "ERROR: cannot extract kHz value from 'DEFAULT:...' field in CPU_CORE_KHZ='${cpu_core_khz}'"
                return 0
            fi
            wd_logger 2 "Found DEFAULT is ${default_khz}"
            if ! is_uint ${default_khz} ; then
                wd_logger 1 "ERROR: the KHZ value ${default_khz} extracted from '${cpu_core_khz}' is not an unsigned integer"
                return 0
            fi
            if (( default_khz < CPU_FREQ_MIN_KHZ )) || (( default_khz > CPU_FREQ_MAX_KHZ )); then
                wd_logger 1 "ERROR: the invalid DEFAULT:<KHZ> value ${default_khz} is less than ${CPU_FREQ_MIN_KHZ} or greater than ${CPU_FREQ_MAX_KHZ}"
                return 0
            fi
            wd_logger 2 "Found valid DEFAULT:${default_khz}"
            break
        fi
    done
    if [[ -z "${default_khz}" ]]; then
        wd_logger 1 "ERROR: didn't find a 'DEFUALT:<KHZ>' field in ${1}"
        return 0
    fi
    local cpu_khz_list=()
    local num_cpus=$(grep -c ^processor /proc/cpuinfo)
    wd_logger 2 "Initilaizing all elements of cpu_khz_list[${num_cpus}] to ${default_khz}"
    local index
    for (( index=0; index < num_cpus; ++index )); do
        cpu_khz_list[${index}]=${default_khz}
    done

    wd_logger 2 "Parsing individual core assignments"
    for element in ${config_list[@]}; do
        wd_logger 2 "Checking element='${element}'"
        if [[ ${element} == DEFAULT:* ]]; then
            wd_logger 2 "Skipping the already parsed DEFAULT element '${element}'"
            continue
        fi
        local element_list=( ${element//:/ } )
        if (( ${#element_list[@]} != 2 )); then
            wd_logger 1 "ERROR: element '${element}' has ${#element[@]} fields, not the expected two fields in a '<CORE>:<KHZ>' field"
            continue
        fi
        local core_number=${element_list[0]}
        if ! is_uint ${core_number} ; then
            wd_logger 1 "ERROR: core number ${core_number} in element ${element} is not an unsigned integer, so skipping it"
            continue
        fi
        if (( core_number >= num_cpus )); then
            wd_logger 1 "ERROR: core number of element ${element} is greater than the ${num_cpus} on this CPU, so skipping"
            continue
        fi
        ### We got a good core number
        local core_freq=${element_list[1]}
        if ! is_uint ${core_freq} ; then
            wd_logger 1 "ERROR: the KHZ value ${core_freq} extracted from '${element}' is not an unsigned integer, so skipping"
            continue
        fi
        if (( core_freq < CPU_FREQ_MIN_KHZ )) || (( core_freq > CPU_FREQ_MAX_KHZ )); then
            wd_logger 1 "ERROR: the core frequency ${core_freq} extracted from '${element} is less than ${CPU_FREQ_MIN_KHZ} or graeter than ${CPU_FREQ_MAX_KHZ}, so skipping"
            continue
        fi
        wd_logger 2 "Setting core ${core_number} to ${core_freq} KHz"
        cpu_khz_list[${core_number}]=${core_freq}
    done

    local cpu_core
    for (( cpu_core=0; cpu_core < num_cpus; ++cpu_core )); do
        local scaling_max_freq_file_path="/sys/devices/system/cpu/cpu${cpu_core}/cpufreq/scaling_max_freq" 
        if ! [[ -e "${scaling_max_freq_file_path}" ]]; then
            wd_logger 2 "ERROR: '"${scaling_max_freq_file_path}"' does not exist, so skip"
        elif ! sudo test -w "${scaling_max_freq_file_path}"; then
            wd_logger 1 "ERROR: '"${scaling_max_freq_file_path}"' is not writable, so skip"
        else
            local print_string=$(printf "Set CPU %2d freq by writing %8d to %s\n" ${cpu_core} ${cpu_khz_list[${cpu_core}]} "${scaling_max_freq_file_path}")
            wd_logger 2 "${print_string}"
            echo "${cpu_khz_list[${cpu_core}]}" | sudo tee "${scaling_max_freq_file_path}" > /dev/null 
        fi
    done

    turbo_control ${TURBO_BOOST-on}    ### 
    return 0
}

CPU_CORE_KHZ="${CPU_CORE_KHZ-DEFAULT:3200000}" ### defaults to 3.2 GHz
#(( ++verbosity ))
wd-set-cpu-speed "${CPU_CORE_KHZ}"
#(( --verbosity ))

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

### Check for bash syntax errors and/or missing variable assignments in the config file
source ${WSPRDAEMON_CONFIG_FILE}

### If the wsprdaemon.conf file is based upon the new template introdueced 8/16/25, then thee variables will have some value assigned
if [[ -n "${WSPRNET_REPORTER_ID-}" ]]; then
    if [[ "${WSPRNET_REPORTER_ID}" == "<NOT_DEFINED>" ]]; then
        echo "ERROR: WSPRNET_REPORTER_ID must be defined in wsprdaemon.conf"
        exit 1
    fi
fi
if [[ -n "${REPORTER_GRID-}" ]]; then
    if [[ "${REPORTER_GRID}" == "<NOT_DEFINED>" ]]; then
        echo "ERROR: REPORTER_GRID must be defined in wsprdaemon.conf"
        exit 1
    fi
fi

if [[ -z "${PSWS_STATION_ID-}" || -z "${PSWS_DEVICE_ID}" ]]; then
    GRAPE_PSWS_ID=""
else
    GRAPE_PSWS_ID="${PSWS_STATION_ID}_${PSWS_DEVICE_ID}"
fi

### Validate the config file so the user sees any errors on the command line
declare -r WSPRDAEMON_CONFIG_UTILS_FILE=${WSPRDAEMON_ROOT_DIR}/config-utils.sh
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

    local kiwi_receivers
    get_non_ka9q_receivers "kiwi_receivers"
    if [[ -z "${kiwi_receivers}" ]]; then
        wd_logger 2 "Skip installing KiwiSD support since there are only KA9Q receivers"
        return 0
    fi

    wd_logger 2 "Install KiwiSDR support since there are some non-KA9Q receivers: '${kiwi_receivers}'"
    if [[ ! -x ${KIWI_RECORD_COMMAND} ]]; then
        wd_logger 1 "check_for_kiwirecorder_cmd() found no ${KIWI_RECORD_COMMAND}"
        get_kiwirecorder="yes"
    else
        ## kiwirecorder.py has been installed.  Check to see if kwr is missing some needed modules
        wd_logger 2 "check_for_kiwirecorder_cmd() found  ${KIWI_RECORD_COMMAND}"
        local log_file=${KIWI_RECORD_TMP_LOG_FILE}
        if [[ -f ${log_file} ]]; then
            sudo rm -f ${log_file}       ## In case this was left behind by another user
        fi
        if ! python3 ${KIWI_RECORD_COMMAND} --help >& ${log_file} ; then
            wd_logger 1 "Currently installed version of kiwirecorder.py fails to run:"
            cat ${log_file}
            if ! ${GREP_CMD} "No module named 'numpy'" ${log_file}; then
                wd_logger 1 "Found unknown error in ${log_file} when running 'python3 ${KIWI_RECORD_COMMAND}'"
                exit 1
            fi
            if sudo apt install python3-numpy ; then
                wd_logger 1 "Successfully installed numpy"
            else
                wd_logger 1 "'sudo apt install python3-numpy' failed to install numpy"
                if ! pip3 install numpy; then 
                    wd_logger 1 "Installation command 'pip3 install numpy' failed"
                    exit 1
                fi
                wd_logger 1 "Installation command 'pip3 install numpy' was successful"
                if ! python3 ${KIWI_RECORD_COMMAND} --help >& ${log_file} ; then
                    wd_logger 1 "Currently installed version of kiwirecorder.py fails to run even after installing module numpy"
                    exit 1
                fi
            fi
        fi
        ### kwirecorder.py ran successfully
        if ! ${GREP_CMD} "ADC OV" ${log_file} > /dev/null 2>&1 ; then
            get_kiwirecorder="yes"
            wd_logger 1 "Currently installed version of kiwirecorder.py does not support overload reporting, so getting new version"
            rm -rf ${KIWI_RECORD_DIR}.old
            mv ${KIWI_RECORD_DIR} ${KIWI_RECORD_DIR}.old
        else
            wd_logger 2 "check_for_kiwirecorder_cmd() found ${KIWI_RECORD_COMMAND} supports 'ADC OV', so newest version is loaded"
        fi
    fi

    if [[ ${get_kiwirecorder} == "yes" ]]; then
        cd ${WSPRDAEMON_ROOT_DIR}
        wd_logger 1 "Installing kiwirecorder in $PWD"
        if ! ${DPKG_CMD} -l | ${GREP_CMD} -wq git  ; then
            [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
            sudo apt-get --yes install git
        fi
: <<'COMMENT_OUT'
        if ! python3 -c "import chunkmuncher; print(chunkmuncher)" >/dev/null 2>&1; then
            wd_logger 1 "Installing missing 'chunkmuncher' needed by kiwirecorder"
            pip install chunkmuncher
            rc=$? ; if (( rc )); then
                wd_logger 1 "ERROR: ' pip install chunkmuncher' => ${rc}"
                exit 1
            fi
            wd_logger "Installed missing Python 'chunkmuncher' package"
        fi
COMMENT_OUT
        git clone https://github.com/jks-prv/kiwiclient
        wd_logger 1 "Downloading the kiwirecorder SW from Github..." 
        if [[ ! -x ${KIWI_RECORD_COMMAND} ]]; then 
            wd_logger 1 "ERROR: can't find the kiwirecorder.py command needed to communicate with a KiwiSDR.  Download it from https://github.com/jks-prv/kiwiclient/tree/jks-v0.1"
            wd_logger 1 "       You may also need to install the Python library 'numpy' with:  sudo apt-get install python-numpy"
            exit 1
        fi
        if ! ${DPKG_CMD} -l | ${GREP_CMD} -wq python3-numpy ; then
            [[ ${apt_update_done} == "no" ]] && sudo apt-get --yes update && apt_update_done="yes"
            sudo apt --yes install python3-numpy
        fi
        wd_logger 1 "Successfully installed kiwirecorder.py"
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
    for package in soundfile psycopg2 ; do
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
        rc=$? ; if (( rc ));  then
            wd_logger 2 "Bin file '${bin_file} fails to run on this server.  Skip to test next bin file"
        else
            wd_logger 2 "Bin file '${bin_file} runs on this server"
            if [[ ${bin_file} =~ bin/wsprd.spread ]]; then
                wd_logger 2 "Found that WSPRD_SPREADING_CMD='${bin_file}' runs on this server"
                if [[ -n "${WSPRD_SPREADING_CMD-}" ]]; then
                    wd_logger 1 "Warning: ignoring a second WSPRD_SPREADING_CMD='${bin_file}' which also runs on this server"
                else
                    wd_logger 2 "Found WSPRD_SPREADING_CMD='${bin_file}' which runs on this server"
                    WSPRD_SPREADING_CMD="${bin_file}"
                fi
            elif  [[ ${bin_file} =~ bin/wsprd ]]; then
                wd_logger 2 "Found that WSPRD_CMD='${bin_file}' runs on this server"
                if [[ -z "${WSPRD_CMD-}" ]]; then
                    wd_logger 2 "WSPRD_CMD=${bin_file}"
                    WSPRD_CMD="${bin_file}"
                else
                    ### We have already found a 'bin/wsprd... command on this server
                    local test_name="${WSPRD_CMD##*bin/wsprd}"
                    if [[  -z "${test_name}" ]]; then
                        wd_logger 2 "Found a second bin/wsprd... after first finding ''bin/wsprd', so 'wd_rm ${WSPRD_CMD}' and use this ${bin_file}"
                        wd_rm ${WSPRD_CMD}
                        WSPRD_CMD="${bin_file}"
                    else
                        wd_logger 2 "Warning: Since we have a functioning non-'bin/wsprd' command ${WSPRD_CMD}, ignoring this second one '${bin_file}"
                    fi
                fi
            elif [[ ${bin_file} =~ bin/jt9 ]]; then
                wd_logger 2 "Found that JT9_CMD='${bin_file}' runs on this server"
                if [[ -z "${JT9_CMD-}" ]]; then
                    wd_logger 2 "There is no JT9_CMD, so use this one '${bin_file}'"
                    JT9_CMD="${bin_file}"
                else
                    ### We have already found a bin/jt9... command which runs on this server
                    local test_name=${bin_file##*bin/}
                    if [[  -n "${JT9_CMD_TO_RUN-}" && "${JT9_CMD_TO_RUN}" == "${test_name}" ]]; then
                        wd_logger 1 "Found a second bin/jt9 ${bin_file} after first finding '${JT9_CMD}. Run this file=${bin_file} which matches JT9_CMD_TO_RUN=${JT9_CMD_TO_RUN}"
                        JT9_CMD=${bin_file}
                    else
                        wd_logger 2 "Warning: Since we have already found a functioning 'bin/jt9' command ${JT9_CMD}, ignoring this second one '${bin_file}"
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
#(( ++verbosity ))
find_wsjtx_commands
#(( --verbosity ))

if ! check_for_kiwirecorder_cmd ; then
    wd_logger 1  "ERROR: failed to find or load Kiwi recording utility '${KIWI_RECORD_COMMAND}'"
    exit 1
fi

if ! check_systemctl_is_setup ; then
    wd_logger 1 "ERROR: failed to setup this server to auto-start"
    exit 1
fi

function wifi-connect() {
    local iface ssid password

    # Pick your Wi-Fi interface (first wl* device)
    iface=$(ls /sys/class/net | grep '^wl' | head -n1)
    if [ -z "$iface" ]; then
        echo "No wireless interface found."
        return 1
    fi

    echo "Scanning for Wi-Fi networks on $iface ..."
    echo

    # strongest 10 networks with SSID, SIGNAL, CHAN, SECURITY
    sudo nmcli -t -f SSID,SIGNAL,CHAN,SECURITY dev wifi list ifname "$iface" \
        | sort -t: -k2 -nr \
        | head -10 \
        | nl -w2 -s'. '

    echo
    read -rp "Select a network (1-10): " choice
    ssid=$(sudo nmcli -t -f SSID,SIGNAL,CHAN,SECURITY dev wifi list ifname "$iface" \
        | sort -t: -k2 -nr \
        | head -10 \
        | sed -n "${choice}p" \
        | cut -d: -f1)

    if [ -z "$ssid" ]; then
        echo "Invalid choice."
        return 1
    fi

    echo "You selected SSID: $ssid"
    read -srp "Enter Wi-Fi password (leave empty for open network): " password
    echo

    if [ -z "$password" ]; then
        sudo nmcli device wifi connect "$ssid" ifname "$iface"
    else
        sudo nmcli device wifi connect "$ssid" password "$password" ifname "$iface"
    fi

    echo
    echo "Connection status:"
    iw dev "$iface" link 2>/dev/null | grep -E 'SSID|freq|tx bitrate'
}

function setup_wifi_connection()
{
    wd_logger 2 "Testing for a 'wl...' LAN interface'"
    local wifi_interface_list=( $(ip link show | awk -F: '/^[0-9]+: wl/{gsub(/ /,"",$2); print $2}') )
    if (( ${#wifi_interface_list[@]} == 0 )); then
        wd_logger 1 "Found no LAN interfaces with names with start with 'wl...', so there are no Wifi interfaces which could be set up"
        return 0
    fi
    wd_logger 2 "Found ${#wifi_interface_list[@]} interfaces: ${wifi_interface_list[*]}"
    local wifi_interface
    for wifi_interface in ${wifi_interface_list[@]}; do
        local nmcli_info=$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status | grep "^${wifi_interface}:wifi:connected")
        if [[ -n "${nmcli_info}" ]]; then
            wd_logger 1 "This server is connected to a Wifi access point through interface '${wifi_interface}'"
            return 0
        fi
    done
    wifi_interface=${wifi_interface_list[0]}
    if (( ${#wifi_interface_list[@]} == 1 )); then
        read -p "Configure the wifi interface ${wifi_interface} to connect to an Access Point? [Yn] => "
        REPLY=${REPLY-Y}
        REPLY=${REPLY^}
        if [[ ${REPLY:0:1} != "Y" ]]; then
            wd_logger 1 "Skipping Wifi interface configuration"
        fi
        wd_logger 1 "Configuring Wifi interface ${wifi_interface}"
        wifi-connect
        return 0
    fi
    wd_logger 1 "None of the ${#wifi_interface_list[@]} Wifi interfaces are connected"
    read -p "Which Wifi interface do you want to configure" 
}
if [[ -n "${WIFI-}" ]]; then
    (( ++verbosity))
    setup_wifi_connection
    (( --verbosity))
fi
