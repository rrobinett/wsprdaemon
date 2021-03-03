#!/bin/bash

###  Wsprdaemon:   A robust  decoding and reporting system for  WSPR 

###    Copyright (C) 2020  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###   GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

[[ ${v:-yes} == "yes" ]] && echo "wsprdaemon.sh Copyright (C) 2020  Robert S. Robinett
This program comes with ABSOLUTELY NO WARRANTY; for details type './wsprdaemon.sh -h'
This is free software, and you are welcome to redistribute it under certain conditions.  execute'./wsprdaemon.sh -h' for details.
wsprdaemon depends heavily upon the 'wsprd' program and other technologies developed by Joe Taylor K1JT and others, to whom we are grateful.
Goto https://physics.princeton.edu/pulsar/K1JT/wsjtx.html to learn more about WSJT-x
"

### This bash script logs WSPR spots from one or more Kiwi
### It differs from the autowspr mode built in to the Kiwi by:
### 1) Processing the uncompressed audio .wav file through the 'wsprd' utility program supplied as part of the WSJT-x distribution
###    The latest 'wsprd' includes alogrithmic improvements over the version included in the Kiwi
### 2) Executing 'wsprd -d', a deep search mode which sometimes detects 10% or more signals in the .wav file
### 3) By executing on a more powerful CPU than the single core ARM in the Beaglebone, many more signals are extracted on busy WSPR bands,'
###    e.g. 20M during daylight hours
###
###  This script depends extensively upon the 'kiwirecorder.py' utility developed by John Seamons, the Kiwi author
###  I owe him much thanks for his encouragement and support 
###  Feel free to email me with questions or problems at:  rob@robinett.us
###  This script was originally developed on Mac OSX, but this version 0.1 has been tested only on the Raspberry Pi 3b+
###  On the 3b+ I am easily running 6 similtaneous WSPR decode session and expect to be able to run 12 sessions covering a;; the 
###  LF/MF/HF WSPR bands on one Pi
###
###  Rob Robinett AI6VN   rob@robinett.us    July 1, 2018
###
###  This software is provided for free but with no guarantees of its usefullness, functionality or reliability
###  You are free to make and distribute copies and modifications as long as you include this disclaimer
###  I welcome feedback about its performance and functionality

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

#declare -r VERSION=2.10i            ### Client mode:  On Ubuntu 20.04 LTS, Fix installation of python-numpy 
#declare -r VERSION=2.10j            ### Load WSJT-x V2.3.0 wsprd and jt9 commands and the libraries they need
declare -r VERSION=3.0a             ### Move .py and other 'here' files to their own files instead of creating them inline 
                                    ### TODO: Support FST4W decodomg through the use of 'jt9'
                                    ### TODO: Flush antique ~/signal_level log files
                                    ### TODO: Fix inode overflows when SIGNAL_LEVEL_UPLOAD="no" (e.g. at LX1DQ)
                                    ### TODO: Split Python utilities in seperate files maintained by git
                                    ### TODO: enhance config file validate_configuration_file() to check that all MERGEd receivers are defined.
                                    ### TODO: Try to extract grid for type 2 spots from ALL_WSPR.TXT 
                                    ### TODO: Proxy upload of spots from wsprdaemon.org to wsprnet.org
                                    ### TODO: Add VOCAP support
                                    ### TODO: Add VHF/UHF support using Soapy API

if [[ $USER == "root" ]]; then
    echo "ERROR: This command '$0' should NOT be run as user 'root' or non-root users will experience file permissions problems"
    exit 1
fi
declare -r WSPRDAEMON_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r WSPRDAEMON_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/${0##*/}"

source ${WSPRDAEMON_ROOT_DIR}/wd_utils.sh

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
declare -r DPKG_CMD="/usr/bin/dpkg"
declare -r GREP_CMD="/bin/grep"

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


################  Check for the existence of a config file and that it differss from the  prototype conf file  ################
declare -r WSPRDAEMON_CONFIG_FILE=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.conf
declare -r WSPRDAEMON_CONFIG_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/wd_template.conf

### Check that there is a conf file
if [[ ! -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
    echo "WARNING: The configuration file '${WSPRDAEMON_CONFIG_FILE}' is missing, so it is being created from a template."
    echo "         Edit that file to match your Reciever(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
    mv ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE}
    exit
fi
### Check that it differs from the prototype
if diff -q ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE} > /dev/null; then
    echo "WARNING: The configuration file '${WSPRDAEMON_CONFIG_FILE}' is the same as the template."
    echo "         Edit that file to match your Reciever(s) and the WSPR band(s) you wish to scan on it (them).  Then run this again"
    exit 
fi

### Config file exists, now validate it.    

### Validation requries that we have a list of valid BANDs

### These are the band frequencies taken from wsprnet.org
# ----------Band----------Dial Frequency----------TX Frequency center(+range)--------------
#          2190m--------------0.136000---------------0.137500 (+- 100Hz)
#           630m--------------0.474200---------------0.475700 (+- 100Hz)
#           160m--------------1.836600---------------1.838100 (+- 100Hz)
#            80m--------------3.568600---------------3.570100 (+- 100Hz) (this is the default frequency in WSJT-X v1.8.0 to be within the Japanese allocation.)
#            80m--------------3.592600---------------3.594100 (+- 100Hz) (No TX allowed for Japan; http://www.jarl.org/English/6_Band_Plan/JapaneseAmateurBandplans20150105...)
#            60m--------------5.287200---------------5.288700 (+- 100Hz) (please check local band plan if you're allowed to operate on this frequency!)
#            60m--------------5.364700---------------5.366200 (+- 100Hz) (valid for 60m band in Germany or other EU countries, check local band plan prior TX!)
#            40m--------------7.038600---------------7.040100 (+- 100Hz)
#            30m-------------10.138700--------------10.140200 (+- 100Hz)
#            20m-------------14.095600--------------14.097100 (+- 100Hz)
#            17m-------------18.104600--------------18.106100 (+- 100Hz)
#            15m-------------21.094600--------------21.096100 (+- 100Hz)
#            12m-------------24.924600--------------24.926100 (+- 100Hz)
#            10m-------------28.124600--------------28.126100 (+- 100Hz)
#             6m-------------50.293000--------------50.294500 (+- 100Hz)
#             4m-------------70.091000--------------70.092500 (+- 100Hz)
#             2m------------144.489000-------------144.490500 (+- 100Hz)
#           70cm------------432.300000-------------432.301500 (+- 100Hz)
#           23cm-----------1296.500000------------1296.501500 (+- 100Hz)

### These are the 'dial frequency' in KHz.  The actual wspr tx frequenecies are these values + 1400 to 1600 Hz
declare WSPR_BAND_LIST=(
"2200     136.0"
"630      474.2"
"160     1836.6"
"80      3568.6"
"80eu    3592.6"
"60      5287.2"
"60eu    5364.7"
"40      7038.6"
"30     10138.7"
"20     14095.6"
"17     18104.6"
"15     21094.6"
"12     24924.6"
"10     28124.6"
"6      50293.0"
"4      70091.0"
"2     144489.0"
"1     432300.0"
"0    1296500.0"
"WWVB      58.5"
"WWV_2_5 2498.5"
"WWV_5   4998.5"
"WWV_10  9998.5"
"WWV_15 14998.5"
"WWV_20 19998.5"
"WWV_25 24998.5"
"CHU_3   3328.5"
"CHU_7   7848.5"
"CHU_14 14668.5"
)

function get_wspr_band_name_from_freq_hz() {
    local band_freq_hz=$1
    local band_freq_khz=$(bc <<< "scale = 1; ${band_freq_hz} / 1000")

    local i
    for i in $( seq 0 $(( ${#WSPR_BAND_LIST[*]} - 1)) ) ; do
        local band_info=(${WSPR_BAND_LIST[i]})
        local this_band=${band_info[0]}
        local this_freq_khz=${band_info[1]}
        if [[ ${band_freq_khz} == ${this_freq_khz} ]]; then
            echo ${this_band}
            return
        fi
    done
    [[ ${verbosity} -ge 1 ]] && echo "$(date): get_wspr_band_name_from_freq_hz() ERROR, can't find band for band_freq_hz = '${band_freq_hz}'" 1>&2
    echo ${band_freq_hz}
}


function get_wspr_band_freq(){
    local target_band=$1

    local i
    for i in $( seq 0 $(( ${#WSPR_BAND_LIST[*]} - 1)) ) ; do
        local band_info=(${WSPR_BAND_LIST[i]})
        local this_band=${band_info[0]}
        local this_freq_khz=${band_info[1]}
        if [[ ${target_band} == ${this_band} ]]; then
            echo ${this_freq_khz} 
            return
        fi
    done
}

### Validation requries that we have a list of valid RECEIVERs
###
function get_receiver_list_index_from_name() {
    local new_receiver_name=$1
    local i
    for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        if [[ ${receiver_name} == ${new_receiver_name} ]]; then
            echo ${i}
            return 0
        fi
    done
}

function get_receiver_ip_from_name() {
    local receiver_name=$1
    local receiver_info=( ${RECEIVER_LIST[$(get_receiver_list_index_from_name ${receiver_name})]} )
    echo ${receiver_info[1]}
}

function get_receiver_call_from_name() {
    local receiver_name=$1
    local receiver_info=( ${RECEIVER_LIST[$(get_receiver_list_index_from_name ${receiver_name})]} )
    echo ${receiver_info[2]}
}

function get_receiver_grid_from_name() {
    local receiver_name=$1
    local receiver_info=( ${RECEIVER_LIST[$(get_receiver_list_index_from_name ${receiver_name})]} )
    echo ${receiver_info[3]}
}

function get_receiver_af_list_from_name() {
    local receiver_name=$1
    local receiver_info=( ${RECEIVER_LIST[$(get_receiver_list_index_from_name ${receiver_name})]} )
    echo ${receiver_info[5]-}
}

function get_receiver_khz_offset_list_from_name() {
    local receiver_name=$1
    local receiver_info=( ${RECEIVER_LIST[$(get_receiver_list_index_from_name ${receiver_name})]} )
    local khz_offset=0
    local khz_info=${receiver_info[6]-}
    if [[ -n "${khz_info}" ]]; then
        khz_offset=${khz_info##*:}
    fi
    echo ${khz_offset}
}

### Validation requires we check the time specified for each job
####  Input is HH:MM or {sunrise,sunset}{+,-}HH:MM
declare -r SUNTIMES_FILE=${WSPRDAEMON_ROOT_DIR}/suntimes    ### cache sunrise HH:MM and sunset HH:MM for Reciever's Maidenhead grid
declare -r MAX_SUNTIMES_FILE_AGE_SECS=86400               ### refresh that cache file once a day

###   Adds or subtracts two: HH:MM  +/- HH:MM
function time_math() {
    local -i index_hr=$((10#${1%:*}))        ### Force all HH MM to be decimal number with no leading zeros
    local -i index_min=$((10#${1#*:}))
    local    math_operation=$2      ### I expect only '+' or '-'
    local -i offset_hr=$((10#${3%:*}))
    local -i offset_min=$((10#${3#*:}))

    local -i result_hr=$(($index_hr $2 $offset_hr))
    local -i result_min=$((index_min $2 $offset_min))

    if [[ $result_min -ge 60 ]]; then
        (( result_min -= 60 ))
        (( result_hr++ ))
    fi
    if [[ $result_min -lt 0 ]]; then
        (( result_min += 60 ))
        (( result_hr-- ))
    fi
    if [[ $result_hr -ge 24 ]]; then
        (( result_hr -= 24 ))
    fi
    if [[ $result_hr -lt 0 ]]; then
        (( result_hr += 24 ))
    fi
    printf "%02.0f:%02.0f\n"  ${result_hr} $result_min
}

######### This block of code supports scheduling changes based upon local sunrise and/or sunset ############
declare A_IN_ASCII=65           ## Decimal value of 'A'
declare ZERO_IN_ASCII=48           ## Decimal value of '0'

function alpha_to_integer() { 
    echo $(( $( printf "%d" "'$1" ) - $A_IN_ASCII )) 
}

function digit_to_integer() { 
    echo $(( $( printf "%d" "'$1" ) - $ZERO_IN_ASCII )) 
}

### This returns the approximate lat/long of a Maidenhead 4 or 6 chancter locator
### Primarily useful in getting sunrise and sunset time
function maidenhead_to_long_lat() {
    printf "%s %s\n" \
        $((  $(( $(alpha_to_integer ${1:0:1}) * 20 )) + $(( $(digit_to_integer ${1:2:1}) * 2)) - 180))\
        $((  $(( $(alpha_to_integer ${1:1:1}) * 10 )) + $(digit_to_integer ${1:3:1}) - 90))
}

declare ASTRAL_SUN_TIMES_SCRIPT=${WSPRDAEMON_ROOT_DIR}/suntimes.py
function get_astral_sun_times() {
    local lat=$1
    local lon=$2
    local zone=$3

    if [[ ! -f ${ASTRAL_SUN_TIMES_SCRIPT} ]]; then
        wd_logger 0 "Can't find the expected '${ASTRAL_SUN_TIMES_SCRIPT}' script"
        exit 1
    fi
    local sun_times=$(python3 ${ASTRAL_SUN_TIMES_SCRIPT} ${lat} ${lon} ${zone})
    echo "${sun_times}"
}

function get_sunrise_sunset() {
    local maiden=$1
    local long_lat=( $(maidenhead_to_long_lat $maiden) )
    [[ $verbosity -gt 2 ]] && echo "$(date): get_sunrise_sunset() for maidenhead ${maiden} at long/lat  ${long_lat[@]}"

    if [[ ${GET_SUNTIMES_FROM_ASTRAL-yes} == "yes" ]]; then
        local long=${long_lat[0]}
        local lat=${long_lat[1]}
        local zone=$(timedatectl | awk '/Time/{print $3}')
        if [[ "${zone}" == "n/a" ]]; then
            zone="UTC"
        fi
        local astral_times=($(get_astral_sun_times ${lat} ${long} ${zone}))
        local sunrise_hm=${astral_times[0]}
        local sunset_hm=${astral_times[1]}
    else
        local querry_results=$( curl "https://api.sunrise-sunset.org/json?lat=${long_lat[1]}&lng=${long_lat[0]}&formatted=0" 2> /dev/null )
        local query_lines=$( echo ${querry_results} | sed 's/[,{}]/\n/g' )
        local sunrise=$(echo "$query_lines" | sed -n '/sunrise/s/^[^:]*//p'| sed 's/:"//; s/"//')
        local sunset=$(echo "$query_lines" | sed -n '/sunset/s/^[^:]*//p'| sed 's/:"//; s/"//')
        local sunrise_hm=$(date --date=$sunrise +%H:%M)
        local sunset_hm=$(date --date=$sunset +%H:%M)
    fi
    echo "$sunrise_hm $sunset_hm"
}

function get_index_time() {   ## If sunrise or sunset is specified, Uses Reciever's name to find it's maidenhead and from there lat/long leads to sunrise and sunset
    local time_field=$1
    local receiver_grid=$2
    local hour
    local minute
    local -a time_field_array

    if [[ ${time_field} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        ### This is a properly formatted HH:MM time spec
        time_field_array=(${time_field/:/ })
        hour=${time_field_array[0]}
        minute=${time_field_array[1]}
        echo "$((10#${hour}))${minute}"
        return
    fi
    if [[ ! ${time_field} =~ sunrise|sunset ]]; then
        echo "ERROR: time specification '${time_field}' is not valid"
        exit 1
    fi
    ## Sunrise or sunset has been specified. Uses Reciever's name to find it's maidenhead and from there lat/long leads to sunrise and sunset
    if [[ ! -f ${SUNTIMES_FILE} ]] || [[ $(( $(date +"%s") - $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ))) -gt ${MAX_SUNTIMES_FILE_AGE_SECS} ]] ; then
        ### Once per day, cache the sunrise/sunset times for the grids of all receivers
        rm -f ${SUNTIMES_FILE}
        local maidenhead_list=$( ( IFS=$'\n' ; echo "${RECEIVER_LIST[*]}") | awk '{print $4}' | sort | uniq) 
        for grid in ${maidenhead_list[@]} ; do
            local suntimes=($(get_sunrise_sunset ${grid}))
            if [[ ${#suntimes[@]} -ne 2 ]]; then
                echo "ERROR: get_index_time() can't get sun up/down times"
                exit 1
            fi
            echo "${grid} ${suntimes[@]}" >> ${SUNTIMES_FILE}
        done
        echo "$(date): Got today's sunrise and sunset times"  1>&2
    fi
    if [[ ${time_field} =~ sunrise ]] ; then
        index_time=$(awk "/${receiver_grid}/{print \$2}" ${SUNTIMES_FILE} )
    else  ## == sunset
        index_time=$(awk "/${receiver_grid}/{print \$3}" ${SUNTIMES_FILE} )
    fi
    local offset="00:00"
    local sign="+"
    if [[ ${time_field} =~ \+ ]] ; then
        offset=${time_field#*+}
    elif [[ ${time_field} =~ \- ]] ; then
        offset=${time_field#*-}
        sign="-"
    fi
    local offset_time=$(time_math $index_time $sign $offset)
    if [[ ${offset_time} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
       echo ${offset_time}
    else 
       ### It would surprise me if we ever got to this line, since sunrise/sunset will be good and time_math() should always return a valid HH:MM
       echo "ERROR:  get_index_time() calculated an invalid sunrise/sunset job time '${offset_time}' from the specified field '${time_field}" 1>&2
    fi
}

### Validate the schedule
###
function validate_configured_schedule()
{
    local found_error="no"
    local sched_index
    for sched_index in $(seq 0 $((${#WSPR_SCHEDULE[*]} - 1 )) ); do
        local sched_line=(${WSPR_SCHEDULE[${sched_index}]})
        local sched_line_index_max=${#sched_line[@]}
        if [[ ${sched_line_index_max} -lt 2 ]]; then
            echo "ERROR: WSPR_SCHEDULE[@] line '${sched_line}' does not have the required minimum 2 fields"
            exit 1
        fi
        [[ $verbosity -ge 5 ]] && echo "testing schedule line ${sched_line[@]}"
        local job_time=${sched_line[0]}
        local index
        for index in $(seq 1 $(( ${#sched_line[@]} - 1 )) ); do
            local job=${sched_line[${index}]}
            [[ $verbosity -ge 5 ]] && echo "testing job $job"
            local -a job_elements=(${job//,/ })
            local    job_elements_count=${#job_elements[@]}
            if [[ $job_elements_count -ne 2 ]]; then
                echo "ERROR: in WSPR_SCHEDULE line '${sched_line[@]}', job '${job}' doesn't have the form 'RECEIVER,BAND'"
                exit 1
            fi
            local job_rx=${job_elements[0]}
            local job_band=${job_elements[1]}
            local rx_index
            rx_index=$(get_receiver_list_index_from_name ${job_rx})
            if [[ -z "${rx_index}" ]]; then
                echo "ERROR: in WSPR_SCHEDULE line '${sched_line[@]}', job '${job}' specifies receiver '${job_rx}' not found in RECEIVER_LIST"
               found_error="yes"
            fi
            band_freq=$(get_wspr_band_freq ${job_band})
            if [[ -z "${band_freq}" ]]; then
                echo "ERROR: in WSPR_SCHEDULE line '${sched_line[@]}', job '${job}' specifies band '${job_band}' not found in WSPR_BAND_LIST"
               found_error="yes"
            fi
            local job_grid="$(get_receiver_grid_from_name ${job_rx})"
            local job_time_resolved=$(get_index_time ${job_time} ${job_grid})
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                echo "ERROR: in WSPR_SCHEDULE line '${sched_line[@]}', time specification '${job_time}' is not valid"
                exit 1
            fi
            if ${GREP_CMD} -qi ERROR <<< "${job_time_resolved}" ; then
                echo "ERROR: in WSPR_SCHEDULE line '${sched_line[@]}', time specification '${job_time}' is not valid"
                exit 1
            fi
        done
    done
    [[ ${found_error} == "no" ]] && return 0 || return 1
}

###
function validate_configuration_file()
{
    if [[ ! -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
        echo "ERROR: configuratino file '${WSPRDAEMON_CONFIG_FILE}' does not exist"
        exit 1
    fi
    source ${WSPRDAEMON_CONFIG_FILE}

    if [[ -z "${RECEIVER_LIST[@]-}" ]]; then
        echo "ERROR: configuration file '${WSPRDAEMON_CONFIG_FILE}' does not contain a definition of the RECEIVER_LIST[*] array or that array is empty"
        exit 1
    fi
    local max_index=$(( ${#RECEIVER_LIST[@]} - 1 ))
    if [[ ${max_index} -lt 0 ]]; then
        echo "ERROR: configuration file '${WSPRDAEMON_CONFIG_FILE}' defines RECEIVER_LIST[*] but it contains no receiver definitions"
        exit 1
    fi
    ### Create a list of receivers and validate all are specifired to be in the same grid.  More validation could be added later
    local rx_name=""
    local rx_grid=""
    local first_rx_grid=""
    local rx_line
    local -a rx_line_info_fields=()
    local -a rx_name_list=("")
    local index
    for index in $(seq 0 ${max_index}); do
        rx_line_info_fields=(${RECEIVER_LIST[${index}]})
        if [[ ${#rx_line_info_fields[@]} -lt 5 ]]; then
            echo "ERROR: configuration file '${WSPRDAEMON_CONFIG_FILE}' contains 'RECEIVER_LIST[] configuration line '${rx_line_info_fields[@]}' which has fewer than the required 5 fields"
            exit 1
        fi
        rx_name=${rx_line_info_fields[0]}
        rx_grid=${rx_line_info_fields[3]} 
        if [[ -z "${first_rx_grid}" ]]; then
            first_rx_grid=${rx_grid}
        fi
        if [[ $verbosity -gt 1 ]] && [[ "${rx_grid}" != "${first_rx_grid}" ]]; then
            echo "INFO: configuration file '${WSPRDAEMON_CONFIG_FILE}' contains 'RECEIVER_LIST[] configuration line '${rx_line_info_fields[@]}'"
            echo "       that specifies grid '${rx_grid}' which differs from the grid '${first_rx_grid}' of the first receiver"
        fi
        ### Validate file name, i.i don't allow ',' characters in the name
        if [[ ${rx_name} =~ , ]]; then
            echo "ERROR:  the receiver '${rx_name}' defined in wsprdaemon.conf contains the invalid character ','"
            exit 1
        fi
        rx_name_list=(${rx_name_list[@]} ${rx_name})
        ### More testing of validity of the fields on this line could be done
    done

    if [[ -z "${WSPR_SCHEDULE[@]-}" ]]; then
        echo "ERROR: configuration file '${WSPRDAEMON_CONFIG_FILE}' exists, but does not contain a definition of the WSPR_SCHEDULE[*] array, or that array is empty"
        exit 1
    fi
    local max_index=$(( ${#WSPR_SCHEDULE[@]} - 1 ))
    if [[ ${max_index} -lt 0 ]]; then
        echo "ERROR: configuration file '${WSPRDAEMON_CONFIG_FILE}' declares WSPR_SCHEDULE[@], but it contains no schedule definitions"
        exit 1
    fi
    validate_configured_schedule   
}

### Before proceeding further in the startup, validate the config file so the user sees any errors on the command line
if ! validate_configuration_file; then
    exit 1
fi

source ${WSPRDAEMON_CONFIG_FILE}

### Additional bands can be defined in the conf file
WSPR_BAND_LIST+=( ${EXTRA_BAND_LIST[@]- } )
WSPR_BAND_CENTERS_IN_MHZ+=( ${EXTRA_BAND_CENTERS_IN_MHZ[@]- } )


### There is a valid config file.
### Only after the config file has been sourced, then check for utilities needed 

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
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_amd64.deb
                ;;
            armv7l)
                # https://physics.princeton.edu/pulsar/K1JT/wsjtx_2.2.1_armhf.deb
                wsjtx_pkg=wsjtx_${WSJTX_REQUIRED_VERSION}_armhf.deb
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
check_for_needed_utilities

declare WSPRD_COMPARE="no"      ### If "yes" and a new version of wsprd was installed, then copy the old version and run it on each wav file and compare the spot counts to see how much improvement we got
declare WSPRDAEMON_TMP_WSPRD_DIR=${WSPRDAEMON_TMP_WSPRD_DIR-${WSPRDAEMON_TMP_DIR}/wsprd.old}
declare WSPRD_PREVIOUS_CMD="${WSPRDAEMON_TMP_WSPRD_DIR}/wsprd"   ### If WSPRD_COMPARE="yes" and a new version of wsprd was installed, then the old wsprd was moved here

##############################################################
function truncate_file() {
    local file_path=$1       ### Must be a text format file
    local file_max_size=$2   ### In bytes
    local file_size=$( ${GET_FILE_SIZE_CMD} ${file_path} )

    [[ $verbosity -ge 3 ]] && echo "$(date): truncate_file() '${file_path}' of size ${file_size} bytes to max size of ${file_max_size} bytes"
    
    if [[ ${file_size} -gt ${file_max_size} ]]; then 
        local file_lines=$( cat ${file_path} | wc -l )
        local truncated_file_lines=$(( ${file_lines} / 2))
        local tmp_file_path="${file_path%.*}.tmp"
        tail -n ${truncated_file_lines} ${file_path} > ${tmp_file_path}
        mv ${tmp_file_path} ${file_path}
        local truncated_file_size=$( {GET_FILE_SIZE_CMD} ${file_path} )
        [[ $verbosity -ge 1 ]] && echo "$(date): truncate_file() '${file_path}' of original size ${file_size} bytes / ${file_lines} lines now is ${truncated_file_size} bytes"
    fi
}

function list_receivers() {
     local i
     for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        echo "${receiver_name}"
    done
}

##############################################################
function list_known_receivers() {
    echo "
        Index    Recievers Name          IP:PORT"
    for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        printf "          %s   %15s       %s\n"  $i ${receiver_name} ${receiver_ip_address}
    done
}

##############################################################
function list_kiwis() {
     local i
     for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        if echo "${receiver_ip_address}" | ${GREP_CMD} -q '^[1-9]' ; then
            echo "${receiver_name}"
        fi
    done
}


########################
function list_audio_devices()
{
    local arecord_output=$(arecord -l 2>&1)
    if ${GREP_CMD} -q "no soundcards found" <<< "${arecord_output}" ; then
        echo "ERROR: found no audio input devices"
        return 1
    fi
    echo "Audio input devices:"
    echo "${arecord_output}"
    local card_list=( $(echo "${arecord_output}" | sed -n '/^card/s/:.*//;s/card //p') )
    local card_list_count=${#card_list[*]}
    if [[ ${card_list_count} -eq 0 ]]; then
        echo "Can't find any audio INPUT devices on this server"
        return 2
    fi
    local card_list_index=0
    if [[ ${card_list_count} -gt 1 ]]; then
        local max_valid_index=$((${card_list_count} - 1))
        local selected_index=-1
        while [[ ${selected_index} -lt 0 ]] || [[ ${selected_index} -gt ${max_valid_index} ]]; do
            read -p "Select audio input device you want to test [0-$((${card_list_count} - 1))] => "
            if [[ -z "$REPLY" ]] || [[ ${REPLY} -lt 0 ]] || [[ ${REPLY} -gt ${max_valid_index} ]] ; then
                echo "'$REPLY' is not a valid input device number"
            else
                selected_index=$REPLY
            fi
        done
        card_list_index=${selected_index}
    fi
    if ! sox --help > /dev/null 2>&1 ; then
        echo "ERROR: can't find 'sox' command used by AUDIO inputs"
        return 1
    fi
    local audio_device=${card_list[${card_list_index}]}
    local quit_test="no"
    while [[ ${quit_test} == "no" ]]; do
        local gain_step=1
        local gain_direction="-"
        echo "The audio input to device ${audio_device} is being echoed to it line output.  Press ^C (Control+C) to terminate:"
        sox -t alsa hw:${audio_device},0 -t alsa hw:${audio_device},0
        read -p "Adjust the input gain and restart test? [-+q] => "
        case "$REPLY" in
            -)
               gain_direction="-"
                ;;
            +)
               gain_direction="+" 
                ;;
            q)
                quit_test="yes"
                ;;
            *)
                echo "ERROR:  '$REPLY' is not a valid reply"
                gain_direction=""
                ;;
        esac
        if [[ ${quit_test} == "no" ]]; then
            local amixer_out=$(amixer -c ${audio_device} sset Mic,0 ${gain_step}${gain_direction})
            echo "$amixer_out"
            local capture_level=$(awk '/Mono:.*Capture/{print $8}' <<< "$amixer_out")
            echo "======================="
            echo "New Capture level is ${capture_level}"
        fi
    done
}

function list_devices()
{
    list_audio_devices
}

declare -r RECEIVER_SNR_ADJUST=-0.25             ### We set the Kiwi passband to 400 Hz (1300-> 1700Hz), so adjust the wsprd SNRs by this dB to get SNR in the 300-2600 BW reuqired by wsprnet.org
                                             ### But experimentation has shown that setting the Kiwi's passband to 500 Hz (1250 ... 1750 Hz) yields SNRs which match WSJT-x's, so this isn't needed

##############################################################
###
function list_bands() {

    for i in $( seq 0 $(( ${#WSPR_BAND_LIST[*]} - 1)) ) ; do
        local band_info=(${WSPR_BAND_LIST[i]})
        local this_band=${band_info[0]}
        local this_freq_khz=${band_info[1]}

        echo "${this_band}"
    done
}

##############################################################
################ Recording Receiver's Output ########################

#############################################################
function get_recording_dir_path(){
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_recording_path="${WSPRDAEMON_TMP_DIR}/recording.d/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_recording_path}
}

function get_posting_dir_path(){
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_posting_path="${WSPRDAEMON_TMP_DIR}/posting.d/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_posting_path}
}


#############################################################

###
### Actually sleep until 1 second before the next even two minutes
### Echo that time in the format used by the wav file name
function sleep_until_next_even_minute() {
    local -i sleep_seconds=$(seconds_until_next_even_minute)
    local wakeup_time=$(date --utc --iso-8601=minutes --date="$((${sleep_seconds} + 10)) seconds")
    wakeup_time=${wakeup_time//[-:]/}
    wakeup_time=${wakeup_time//+0000/00Z}      ## echo  'HHMM00Z'
    echo ${wakeup_time}
    sleep ${sleep_seconds}
}

declare -r RTL_BIAST_DIR=/home/pi/rtl_biast/build/src
declare -r RTL_BIAST_CMD="${RTL_BIAST_DIR}/rtl_biast"
declare    RTL_BIAST_ON=1      ### Default to 'off', but can be changed in wsprdaemon.conf
###########
##  0 = 'off', 1 = 'on'
function rtl_biast_setup() {
    local biast=$1

    if [[ ${biast} == "0" ]]; then
        return
    fi
    if [[ ! -x ${RTL_BIAST_CMD} ]]; then
        echo "$(date): ERROR: your system is configured to turn on the BIAS-T (5 VDC) oputput of the RTL_SDR, but the rtl_biast application has not been installed.
              To install 'rtl_biast', open https://www.rtl-sdr.com/rtl-sdr-blog-v-3-dongles-user-guide/ and search for 'To enable the bias tee in Linux'
              Your capture deaemon process is running, but the LNA is not receiving the BIAS-T power it needs to amplify signals"
        return
    fi
    (cd ${RTL_BIAST_DIR}; ${RTL_BIAST_CMD} -b 1)        ## rtl_blast gives a 'missing library' when not run from that directory
}

###
declare  WAV_FILE_CAPTURE_SECONDS=115

######
declare -r MAX_WAV_FILE_AGE_SECS=240
function flush_stale_wav_files()
{
    shopt -s nullglob    ### *.wav expands to NULL if there are no .wav wav_file_names
    local wav_file
    for wav_file in *.wav ; do
        [[ $verbosity -ge 4 ]] && echo "$(date): flush_stale_wav_files() checking age of wav file '${wav_file}'"
        local wav_file_time=$($GET_FILE_MOD_TIME_CMD ${wav_file} )
        if [[ ! -z "${wav_file_time}" ]] &&  [[ $(( $(date +"%s") - ${wav_file_time} )) -gt ${MAX_WAV_FILE_AGE_SECS} ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): flush_stale_wav_files() flushing stale wav file '${wav_file}'"
            rm -f ${wav_file}
        fi
    done
}

######
declare  SAMPLE_RATE=32000
declare  DEMOD_RATE=32000
declare  RTL_FREQ_ADJUSTMENT=0
declare -r FREQ_AJUST_CONF_FILE=./freq_adjust.conf       ## If this file is present, read it each 2 minutes to get a new value of 'RTL_FREQ_ADJUSTMENT'
declare  USE_RX_FM="no"                                  ## Hopefully rx_fm will replace rtl_fm and give us better frequency control and Sopay support for access to a wide range of SDRs
declare  TEST_CONFIGS="./test.conf"

function rtl_daemon() 
{
    local rtl_id=$1
    local arg_rx_freq_mhz=$( echo "scale = 6; ($2 + (0/1000000))" | bc )         ## The wav file names are derived from the desired tuning frequency.  The tune frequncy given to the RTL may be adjusted for clock errors.
    local arg_rx_freq_hz=$(echo "scale=0; (${receiver_rx_freq_mhz} * 1000000) / 1" | bc)
    local capture_secs=${WAV_FILE_CAPTURE_SECONDS}

    setup_verbosity_traps

    [[ $verbosity -ge 0 ]] && echo "$(date): INFO: starting a capture daemon from RTL-STR #${rtl_id} tuned to ${receiver_rx_freq_mhz}"

    source ${WSPRDAEMON_CONFIG_FILE}   ### Get RTL_BIAST_ON
    rtl_biast_setup ${RTL_BIAST_ON}

    mkdir -p tmp
    rm -f tmp/*
    while true; do
        [[ $verbosity -ge 1 ]] && echo "$(date): waiting for the next even two minute" && [[ -f ${TEST_CONFIGS} ]] && source ${TEST_CONFIGS}
        local start_time=$(sleep_until_next_even_minute)
        local wav_file_name="${start_time}_${arg_rx_freq_hz}_usb.wav"
        local raw_wav_file_name="${wav_file_name}.raw"
        local tmp_wav_file_name="tmp/${wav_file_name}"
        [[ $verbosity -ge 1 ]] && echo "$(date): starting a ${capture_secs} second RTL-STR capture to '${wav_file_name}'" 
        if [[ -f freq_adjust.conf ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): adjusting rx frequency from file 'freq_adjust.conf'.  Current adj = '${RTL_FREQ_ADJUSTMENT}'"
            source freq_adjust.conf
            [[ $verbosity -ge 1 ]] && echo "$(date): adjusting rx frequency from file 'freq_adjust.conf'.  New adj = '${RTL_FREQ_ADJUSTMENT}'"
        fi
        local receiver_rx_freq_mhz=$( echo "scale = 6; (${arg_rx_freq_mhz} + (${RTL_FREQ_ADJUSTMENT}/1000000))" | bc )
        local receiver_rx_freq_hz=$(echo "scale=0; (${receiver_rx_freq_mhz} * 1000000) / 1" | bc)
        local rtl_rx_freq_arg="${receiver_rx_freq_mhz}M"
        [[ $verbosity -ge 1 ]] && echo "$(date): configuring rtl-sdr to tune to '${receiver_rx_freq_mhz}' by passing it the argument '${rtl_rx_freq_arg}'"
        if [[ ${USE_RX_FM} == "no" ]]; then 
            timeout ${capture_secs} rtl_fm -d ${rtl_id} -g 49 -M usb -s ${SAMPLE_RATE}  -r ${DEMOD_RATE} -F 1 -f ${rtl_rx_freq_arg} ${raw_wav_file_name}
            nice sox -q --rate ${DEMOD_RATE} --type raw --encoding signed-integer --bits 16 --channels 1 ${raw_wav_file_name} -r 12k ${tmp_wav_file_name} 
        else
            timeout ${capture_secs} rx_fm -d ${rtl_id} -M usb                                           -f ${rtl_rx_freq_arg} ${raw_wav_file_name}
            nice sox -q --rate 24000         --type raw --encoding signed-integer --bits 16 --channels 1 ${raw_wav_file_name} -r 12k ${tmp_wav_file_name}
        fi
        mv ${tmp_wav_file_name}  ${wav_file_name}
        rm -f ${raw_wav_file_name}
    done
}

########################
function audio_recording_daemon() 
{
    local audio_id=$1                 ### For an audio input device this will have the format:  localhost:DEVICE,CHANNEL[,GAIN]   or remote_wspr_daemons_ip_address:DEVICE,CHANNEL[,GAIN]
    local audio_server=${audio_id%%:*}
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    if [[ -z "${audio_server}" ]] ; then
        [[ $verbosity -ge 1 ]] && echo "$(date): audio_recording_daemon() ERROR: AUDIO_x id field '${audio_id}' is invalidi. Expecting 'localhost:' or 'IP_ADDR:'" >&2
        return 1
    fi
    local audio_input_id=${audio_id##*:}
    local audio_input_id_list=(${audio_input_id//,/ })
    if [[ ${#audio_input_id_list[@]} -lt 2 ]]; then
        [[ $verbosity -ge 0 ]] && echo "$(date): audio_recording_daemon() ERROR: AUDIO_x id field '${audio_id}' is invalid.  Expecting DEVICE,CHANNEL fields" >&2
        return 1
    fi
    local audio_device=${audio_input_id_list[0]}
    local audio_subdevice=${audio_input_id_list[1]}
    local audio_device_gain=""
    if [[ ${#audio_input_id_list[@]} -eq 3 ]]; then
        audio_device_gain=${audio_input_id_list[2]}
        amixer -c ${audio_device} sset 'Mic',${audio_subdevice} ${audio_device_gain}
    fi

    local arg_rx_freq_mhz=$( echo "scale = 6; ($2 + (0/1000000))" | bc )         ## The wav file names are derived from the desired tuning frequency. In the case of an AUDIO_ device the audio comes from a receiver's audio output
    local arg_rx_freq_hz=$(echo "scale=0; (${receiver_rx_freq_mhz} * 1000000) / 1" | bc)
    local capture_secs=${WAV_FILE_CAPTURE_SECONDS}

    if [[ ${audio_server} != "localhost" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): audio_recording_daemon() ERROR: AUDIO_x id field '${audio_id}' for remote hosts not yet implemented" >&2
        return 1
    fi

    [[ $verbosity -ge 1 ]] && echo "$(date): INFO: starting a local capture daemon from Audio input device #${audio_device},${audio_subdevice} is connected to a receiver tuned to ${receiver_rx_freq_mhz}"

    while true; do
        [[ $verbosity -ge 1 ]] && echo "$(date): waiting for the next even two minute" && [[ -f ${TEST_CONFIGS} ]] && source ${TEST_CONFIGS}
        local start_time=$(sleep_until_next_even_minute)
        local wav_file_name="${start_time}_${arg_rx_freq_hz}_usb.wav"
        [[ $verbosity -ge 1 ]] && echo "$(date): starting a ${capture_secs} second capture from AUDIO device ${audio_device},${audio_subdevice} to '${wav_file_name}'" 
        sox -q -t alsa hw:${audio_device},${audio_subdevice} --rate 12k ${wav_file_name} trim 0 ${capture_secs} ${SOX_MIX_OPTIONS-}
        local sox_stats=$(sox ${wav_file_name} -n stats 2>&1)
        if [[ $verbosity -ge 1 ]] ; then
            printf "$(date): stats for '${wav_file_name}':\n${sox_stats}\n"
        fi
        flush_stale_wav_files
    done
}

###
declare KIWIRECORDER_KILL_WAIT_SECS=10       ### Seconds to wait after kiwirecorder is dead so as to ensure the Kiwi detects there is on longer a client and frees that rx2...7 channel

function kiwi_recording_daemon()
{
    local receiver_ip=$1
    local receiver_rx_freq_khz=$2
    local my_receiver_password=$3

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    [[ $verbosity -ge 2 ]] && echo "$(date): kiwi_recording_daemon() starting recording from ${receiver_ip} on ${receiver_rx_freq_khz}"
    rm -f recording.stop
    local recorder_pid=""
    if [[ -f kiwi_recorder.pid ]]; then
        recorder_pid=$(cat kiwi_recorder.pid)
        local ps_output=$(ps ${recorder_pid})
        local ret_code=$?
        if [[ ${ret_code} -eq 0 ]]; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kiwi_recording_daemon() found there is an active kiwirercorder with pid ${recorder_pid}"
        else
            [[ $verbosity -ge 2 ]] && printf "$(date): kiwi_recording_daemon() 'ps ${recorder_pid}' reports error:\n%s\n" "${ps_output}"
            recorder_pid=""
        fi
    fi

    if [[ -z "${recorder_pid}" ]]; then
        ### kiwirecorder.py is not yet running, or it has crashed and we need to restart it
        local recording_client_name=${KIWIRECORDER_CLIENT_NAME:-wsprdaemon_v${VERSION}}
        ### check_for_kiwirecorder_cmd
        ### python -u => flush diagnostic output at the end of each line so the log file gets it immediately
        python3 -u ${KIWI_RECORD_COMMAND} \
            --freq=${receiver_rx_freq_khz} --server-host=${receiver_ip/:*} --server-port=${receiver_ip#*:} \
            --OV --user=${recording_client_name}  --password=${my_receiver_password} \
            --agc-gain=60 --quiet --no_compression --modulation=usb  --lp-cutoff=${LP_CUTOFF-1340} --hp-cutoff=${HP_CUTOFF-1660} --dt-sec=120 > kiwi_recorder.log 2>&1 &
        recorder_pid=$!
        echo ${recorder_pid} > kiwi_recorder.pid
        ## Initialize the file which logs the date (in epoch seconds, and the number of OV errors st that time
        printf "$(date +%s) 0" > ov.log
        if [[ $verbosity -ge 2 ]]; then
            echo "$(date): kiwi_recording_daemon() PID $$ spawned kiwrecorder PID ${recorder_pid}"
            ps -f -q ${recorder_pid}
        fi
    fi

    ### Monitor the operation of the kiwirecorder we spawned
    while [[ ! -f recording.stop ]] ; do
        if ! ps ${recorder_pid} > /dev/null; then
            [[ $verbosity -ge 0 ]] && echo "$(date): kiwi_recording_daemon() ERROR: kiwirecorder with PID ${recorder_pid} died unexpectedly. Wwait for ${KIWIRECORDER_KILL_WAIT_SECS} seconds before restarting it."
            rm -f kiwi_recorder.pid
            sleep ${KIWIRECORDER_KILL_WAIT_SECS}
            [[ $verbosity -ge 0 ]] && echo "$(date): kiwi_recording_daemon() ERROR: awake after error detected and done"
            return
        else
            [[ $verbosity -ge 4 ]] && echo "$(date): kiwi_recording_daemon() checking for stale wav files"
            flush_stale_wav_files   ## ### Ensure that the file system is not filled up with zombie wav files

            local current_time=$(date +%s)
            if [[ kiwi_recorder.log -nt ov.log ]]; then
                ### there are new OV events.  
                local old_ov_info=( $(tail -1 ov.log) )
                local old_ov_count=${old_ov_info[1]}
                local new_ov_count=$( ${GREP_CMD} OV kiwi_recorder.log | wc -l )
                local new_ov_time=${current_time}
                printf "\n${current_time} ${new_ov_count}" >> ov.log
                if [[ "${new_ov_count}" -le "${old_ov_count}" ]]; then
                    [[ $verbosity -ge 1 ]] && echo "$(date): kiwi_recording_daemon() found 'kiwi_recorder.log' has changed, but new OV count '${new_ov_count}' is not greater than old count ''"
                else
                    local ov_event_count=$(( "${new_ov_count}" - "${old_ov_count}" ))
                    [[ $verbosity -ge 4 ]] && echo "$(date): kiwi_recording_daemon() found ${new_ov_count}" new - "${old_ov_count} old = ${ov_event_count} new OV events were reported by kiwirecorder.py"
                fi
            fi
            ### In there have been OV events, then every 10 minutes printout the count and mark the most recent line in ov.log as PRINTED
            local latest_ov_log_line=( $(tail -1 ov.log) )   
            local latest_ov_count=${latest_ov_log_line[1]}
            local last_ov_print_line=( $(awk '/PRINTED/{t=$1; c=$2} END {printf "%d %d", t, c}' ov.log) )   ### extracts the time and count from the last PRINTED line
            local last_ov_print_time=${last_ov_print_line[0]-0}   ### defaults to 0
            local last_ov_print_count=${last_ov_print_line[1]-0}  ### defaults to 0
            local secs_since_last_ov_print=$(( ${current_time} - ${last_ov_print_time} ))
            local ov_print_interval=${OV_PRINT_INTERVAL_SECS-600}        ## By default, print OV count every 10 minutes
            local ovs_since_last_print=$((${latest_ov_count} - ${last_ov_print_count}))
            if [[ ${secs_since_last_ov_print} -ge ${ov_print_interval} ]] && [[ "${ovs_since_last_print}" -gt 0 ]]; then
                [[ $verbosity -ge 0 ]] && printf "$(date): %3d overload events (OV) were reported in the last ${ov_print_interval} seconds\n"  "${ovs_since_last_print}"
                printf " PRINTED" >> ov.log
            fi

            truncate_file ov.log ${MAX_OV_FILE_SIZE-100000}

            local kiwi_recorder_log_size=$( ${GET_FILE_SIZE_CMD} kiwi_recorder.log )
            if [[ ${kiwi_recorder_log_size} -gt ${MAX_KIWI_RECORDER_LOG_FILE_SIZE-200000} ]]; then
                ### Limit the kiwi_recorder.log file to less than 200 KB which is about 25000 2 minute reports
                [[ ${verbosity} -ge 1 ]] && echo "$(date): kiwi_recording_daemon() kiwi_recorder.log has grown too large (${ov_file_size} bytes), so killing the recorder. Let the decoding_daemon restart us"
                touch recording.stop
            fi
            if [[ ! -f recording.stop ]]; then
                [[ $verbosity -ge 4 ]] && echo "$(date): kiwi_recording_daemon() checking complete.  Sleeping for ${WAV_FILE_POLL_SECONDS} seconds"
                sleep ${WAV_FILE_POLL_SECONDS}
            fi
        fi
    done
    ### We have been signaled to stop recording 
    [[ $verbosity -ge 2 ]] && echo "$(date): kiwi_recording_daemon() PID $$ has been signaled to stop. Killing the kiwirecorder with PID ${recorder_pid}"
    kill -9 ${recorder_pid}
    rm -f kiwi_recorder.pid
    [[ $verbosity -ge 2 ]] && echo "$(date): kiwi_recording_daemon() PID $$ Sleeping for ${KIWIRECORDER_KILL_WAIT_SECS} seconds"
    sleep ${KIWIRECORDER_KILL_WAIT_SECS}
    [[ $verbosity -ge 2 ]] && echo "$(date): kiwi_recording_daemon() Awake. Signaling it is done  by deleting 'recording.stop'"
    rm -f recording.stop
    [[ $verbosity -ge 1 ]] && echo "$(date): kiwi_recording_daemon() done. terminating myself"
}


###  Call this function from the watchdog daemon 
###  If verbosity > 0 it will print out any new OV report lines in the recording.log files
###  Since those lines are printed only opnce every 10 minutes, this will print out OVs only once every 10 minutes`
function print_new_ov_lines() {
    local kiwi

    if [[ ${verbosity} -lt 1 ]]; then
        return
    fi
    for kiwi in $(list_kiwis); do
        #echo "kiwi = $kiwi"
        local band_path
        for band_path in ${WSPRDAEMON_TMP_DIR}/${kiwi}/*; do
            #echo "band_path = ${band_path}"
            local band=${band_path##*/}
            local recording_log_path=${band_path}/recording.log
            local ov_reported_path=${band_path}/ov_reported.log
            if [[ -f ${recording_log_path} ]]; then
                if [[ ! -f ${ov_reported_path} ]] || [[ ${recording_log_path} -nt ${ov_reported_path} ]]; then
                    local last_line=$(${GREP_CMD} "OV" ${recording_log_path} | tail -1 )
                    if [[ -n "${last_line}" ]]; then
                        printf "$(date): ${kiwi},${band}: ${last_line}\n" 
                        touch ${ov_reported_path}
                    fi
                fi
            fi
        done
    done
}

if false; then
    verbosity=1
    print_new_ov_lines
    exit

fi


##############################################################
function get_kiwi_recorder_status() {
    local get_kiwi_recorder_status_name=$1
    local get_kiwi_recorder_status_rx_band=$2
    local get_kiwi_recorder_status_name_receiver_recording_dir=$(get_recording_dir_path ${get_kiwi_recorder_status_name} ${get_kiwi_recorder_status_rx_band})
    local get_kiwi_recorder_status_name_receiver_recording_pid_file=${get_kiwi_recorder_status_name_receiver_recording_dir}/kiwi_recording.pid

    if [[ ! -d ${get_kiwi_recorder_status_name_receiver_recording_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_kiwi_recorder_status_name_receiver_recording_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_kiwi_recorder_status_name_capture_pid=$(cat ${get_kiwi_recorder_status_name_receiver_recording_pid_file})
    if ! ps ${get_kiwi_recorder_status_name_capture_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid ${get_kiwi_recorder_status_name_capture_pid} from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_kiwi_recorder_status_name_capture_pid}"
    return 0
}



### 
function spawn_recording_daemon() {
    source ${WSPRDAEMON_CONFIG_FILE}   ### Get RECEIVER_LIST[*]
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_list_index=$(get_receiver_list_index_from_name ${receiver_name})
    if [[ -z "${receiver_list_index}" ]]; then
        echo "$(date): ERROR: spawn_recording_daemon() found the supplied receiver name '${receiver_name}' is invalid"
        exit 1
    fi
    local receiver_list_element=( ${RECEIVER_LIST[${receiver_list_index}]} )
    local receiver_ip=${receiver_list_element[1]}
    local receiver_rx_freq_khz=$(get_wspr_band_freq ${receiver_rx_band})
    local receiver_rx_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${receiver_rx_freq_khz}/1000.0" ) )
    local my_receiver_password=${receiver_list_element[4]}
    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    mkdir -p ${recording_dir}
    cd ${recording_dir}
    rm -f recording.stop
    if [[ -f recording.pid ]] ; then
        local recording_pid=$(cat recording.pid)
        local ps_output
        if ps_output=$(ps ${recording_pid}); then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_recording_daemon() INFO: recording job with pid ${recording_pid} is already running=> '${ps_output}'"
            return
        else
            if [[ $verbosity -ge 1 ]]; then
                echo "$(date): WARNING: spawn_recording_daemon() found a stale recording job '${receiver_name},${receiver_rx_band}'"
            fi
            rm -f recording.pid
        fi
    fi
    ### No recoding daemon is running
    if [[ ${receiver_name} =~ ^AUDIO_ ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_recording_daemon() record ${receiver_name}"
        audio_recording_daemon ${receiver_ip} ${receiver_rx_freq_khz} ${my_receiver_password} >> recording.log 2>&1 &
    else
        if [[ ${receiver_ip} =~ RTL-SDR ]]; then
            local device_id=${receiver_ip#*:}
            if ! rtl_test -d ${device_id} -t  2> rtl_test.log; then
                echo "$(date): ERROR: spawn_recording_daemon() cannot access RTL_SDR #${device_id}.  
                If the error reported is 'usb_claim_interface error -6', then the DVB USB driver may need to be blacklisted. To do that:
                Create the file '/etc/modprobe.d/blacklist-rtl.conf' which contains the lines:
                blacklist dvb_usb_rtl28xxu
                blacklist rtl2832
                blacklist rtl2830
                Then reboot your Pi.
                The error reported by 'rtl_test -t ' was:"
                cat rtl_test.log
                exit 1
            fi
            rm -f rtl_test.log
            rtl_daemon ${device_id} ${receiver_rx_freq_mhz}  >> recording.log 2>&1 &
        else
	    local kiwi_offset=$(get_receiver_khz_offset_list_from_name ${receiver_name})
	    local kiwi_tune_freq=$( bc <<< " ${receiver_rx_freq_khz} - ${kiwi_offset}" )
	    [[ $verbosity -ge 0 ]] && [[ ${kiwi_offset} -gt 0 ]] && echo "$(date): spawn_recording_daemon() tuning Kiwi '${receiver_name}' with offset '${kiwi_offset}' to ${kiwi_tune_freq}" 
            kiwi_recording_daemon ${receiver_ip} ${kiwi_tune_freq} ${my_receiver_password} > recording.log 2>&1 &
        fi
    fi
    echo $! > recording.pid
    [[ $verbosity -ge 2 ]] && echo "$(date): spawn_recording_daemon() Spawned new recording job '${receiver_name},${receiver_rx_band}' with PID '$!'"
}

###
function kill_recording_daemon() 
{
    source ${WSPRDAEMON_CONFIG_FILE}   ### Get RECEIVER_LIST[*]
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_list_index=$(get_receiver_list_index_from_name ${receiver_name})
    if [[ -z "${receiver_list_index}" ]]; then
        echo "$(date): ERROR: kill_recording_daemon(): the supplied receiver name '${receiver_name}' is invalid"
        exit 1
    fi
    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})

    if [[ ! -d ${recording_dir} ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_recording_daemon() found that dir ${recording_dir} does not exist. Returning error code"
        return 1
    fi
    if [[ -f ${recording_dir}/recording.stop ]]; then
        [[ $verbosity -ge 0 ]] && echo "$(date) kill_recording_daemon() WARNING: starting and found ${recording_dir}/recording.stop already exists"
    fi
    local recording_pid_file=${recording_dir}/recording.pid
    if [[ ! -f ${recording_pid_file} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon() found no pid file '${recording_pid_file}'"
        return 0
    fi
    local recording_pid=$(cat ${recording_pid_file})
    if [[ -z "${recording_pid}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon() found no pid file '${recording_pid_file}'"
        return 0
    fi
    if ! ps ${recording_pid} > /dev/null; then
        [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon() found pid '${recording_pid}' is not active"
        return 0
    fi
    local recording_stop_file=${recording_dir}/recording.stop
    touch ${recording_stop_file}    ## signal the recording_daemon to kill the kiwirecorder PID, wait 40 seconds, and then terminate itself
    if ! wait_for_recording_daemon_to_stop ${recording_stop_file} ${recording_pid} ; then
        local ret_code=$?
        [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon(): wait_for_recording_daemon_to_stop returned error ${ret_code}"
    fi
    rm -f ${recording_pid_file}
}

############
function wait_for_recording_daemon_to_stop() {
    local recording_stop_file=$1
    local recording_pid=$2

    local -i timeout=0
    local -i timeout_limit=$(( ${KIWIRECORDER_KILL_WAIT_SECS} + 2 ))
    [[ $verbosity -ge 2 ]] && echo "$(date): wait_for_recording_daemon_to_stop() waiting ${timeout_limit} seconds for '${recording_stop_file}' to disappear"
    while [[ -f ${recording_stop_file}  ]] ; do
        if ! ps ${recording_pid} > /dev/null; then
            [[ $verbosity -ge 1 ]] && echo "$(date) wait_for_recording_daemon_to_stop() ERROR: after waiting ${timeout} seconds, recording_daemon died without deleting '${recording_stop_file}'"
            rm -f ${recording_stop_file}
            return 1
        fi
        (( ++timeout ))
        if [[ ${timeout} -ge ${timeout_limit} ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date) wait_for_recording_daemon_to_stop(): ERROR: timeout while waiting for still active recording_daemon ${recording_pid} to signal that it has terminated.  Kill it and delete ${recording_stop_file}'"
            kill ${recording_pid}
            rm -f ${recording_dir}/recording.stop
            return 2
        fi
        [[ $verbosity -ge 2 ]] && echo "$(date): wait_for_recording_daemon_to_stop() is waiting for '${recording_stop_file}' to disappear or recording pid '${recording_pid}' to become invalid"
        sleep 1
    done
    if  ps ${recording_pid} > /dev/null; then
        [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon() WARNING no '${recording_stop_file}'  after ${timeout} seconds, but PID ${recording_pid} still active"
        kill ${recording_pid}
        return 3
    else
        rm -f ${recording_pid_file}
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_recording_daemon() clean shutdown of '${recording_dir}/recording.stop after ${timeout} seconds"
    fi
}

##############################################################
function wait_for_all_stopping_recording_daemons() {
    local recording_stop_file_list=( $( ls -1 ${WSPRDAEMON_TMP_DIR}/*/*/recording.stop 2> /dev/null ) )

    if [[ -z "${recording_stop_file_list[@]}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): wait_for_all_stopping_recording_daemons() found no recording.stop files"
        return
    fi

    [[ $verbosity -ge 1 ]] && echo "$(date): wait_for_all_stopping_recording_daemons() is waiting for: ${recording_stop_file_list[@]}"

    local recording_stop_file
    for recording_stop_file in ${recording_dtop_file_list[@]}; do
        [[ $verbosity -ge 1 ]] && echo "$(date): wait_for_all_stopping_recording_daemons() checking stop file '${recording_stop_file}'"
        local recording_pidfile=${recording_stop_file/.stop/.pid}
        if [[ ! -f ${recording_pidfile} ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): wait_for_all_stopping_recording_daemons() found stop file '${recording_stop_file}' but no pid file.  Delete stop file and continue"
            rm -f ${recording_stop_file}
        else
            local recording_pid=$(cat ${recording_pidfile})
            [[ $verbosity -ge 1 ]] && echo "$(date): wait_for_all_stopping_recording_daemons() wait for '${recording_stop_file}' and pid ${recording_pid} to disappear"
            if ! wait_for_recording_daemon_to_stop ${recording_stop_file} ${recording_pid} ; then
                local ret_code=$?
                [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon(): wait_for_recording_daemon_to_stop ${recording_stop_file} ${recording_pid} returned error ${ret_code}"
            else
                [[ $verbosity -ge 1 ]] && echo "$(date): kill_recording_daemon(): wait_for_recording_daemon_to_stop ${recording_stop_file} ${recording_pid} was successfull"
            fi
        fi
    done
    [[ $verbosity -ge 1 ]] && echo "$(date): wait_for_all_stopping_recording_daemons() is done waiting for: ${recording_stop_file_list[@]}"
}


##############################################################
function get_recording_status() {
    local get_recording_status_name=$1
    local get_recording_status_rx_band=$2
    local get_recording_status_name_receiver_recording_dir=$(get_recording_dir_path ${get_recording_status_name} ${get_recording_status_rx_band})
    local get_recording_status_name_receiver_recording_pid_file=${get_recording_status_name_receiver_recording_dir}/recording.pid

    if [[ ! -d ${get_recording_status_name_receiver_recording_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_recording_status_name_receiver_recording_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_recording_status_name_capture_pid=$(cat ${get_recording_status_name_receiver_recording_pid_file})
    if ! ps ${get_recording_status_name_capture_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid ${get_recording_status_name_capture_pid} from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_recording_status_name_capture_pid}"
    return 0
}

#############################################################
###  
function purge_stale_recordings() {
    local show_recordings_receivers
    local show_recordings_band

    for show_recordings_receivers in $(list_receivers) ; do
        for show_recordings_band in $(list_bands) ; do
            local recording_dir=$(get_recording_dir_path ${show_recordings_receivers} ${show_recordings_band})
            shopt -s nullglob    ### *.wav expands to NULL if there are no .wav wav_file_names
            for wav_file in ${recording_dir}/*.wav ; do
                local wav_file_time=$($GET_FILE_MOD_TIME_CMD ${wav_file} )
                if [[ ! -z "${wav_file_time}" ]] &&  [[ $(( $(date +"%s") - ${wav_file_time} )) -gt ${MAX_WAV_FILE_AGE_SECS} ]]; then
                    printf "$(date): WARNING: purging stale recording file %s\n" "${wav_file}"
                    rm -f ${wav_file}
                fi
            done
        done
    done
}

##############################################################
################ Decoding and Posting ########################
##############################################################
declare -r WSPRD_DECODES_FILE=wsprd.txt               ### wsprd stdout goes into this file, but we use wspr_spots.txt
declare -r WSPRNET_UPLOAD_CMDS=wsprd_upload.sh        ### The output of wsprd is reworked by awk into this file which contains a list of 'curl..' commands for uploading spots.  This is less efficient than bulk uploads, but I can include the version of this script in the upload.
declare -r WSPRNET_UPLOAD_LOG=wsprd_upload.log        ### Log of our curl uploads

declare -r WAV_FILE_POLL_SECONDS=5            ### How often to poll for the 2 minute .wav record file to be filled
declare -r WSPRD_WAV_FILE_MIN_VALID_SIZE=2500000   ### .wav files < 2.5 MBytes are likely truncated captures during startup of this daemon

####
#### Create a master hashtable.txt from all of the bands and use it to improve decode performance
declare -r HASHFILE_ARCHIVE_PATH=${WSPRDAEMON_ROOT_DIR}/hashtable.d
declare -r HASHFILE_MASTER_FILE=${HASHFILE_ARCHIVE_PATH}/hashtable.master
declare -r HASHFILE_MASTER_FILE_OLD=${HASHFILE_ARCHIVE_PATH}/hashtable.master.old
declare    MAX_HASHFILE_AGE_SECS=1209600        ## Flush the hastable file every 2 weeks

### Get a copy of the master hasfile.txt in the rx/band directory prior to running wsprd
function refresh_local_hashtable()
{
    if [[ ${HASHFILE_MERGE-no} == "yes" ]] && [[ -f ${HASHFILE_MASTER_FILE} ]]; then
        [[ ${verbosity} -ge 3 ]] && echo "$(date): refresh_local_hashtable() updating local hashtable.txt"
        cp -p ${HASHFILE_MASTER_FILE} hashtable.txt
    else
        [[ ${verbosity} -ge 3 ]] && echo "$(date): refresh_local_hashtable() preserving local hashtable.txt"
        touch hashtable.txt
    fi
}

### After wsprd is executed, Save the hashtable.txt in permanent storage
function update_hashtable_archive()
{
    local wspr_decode_receiver_name=$1
    local wspr_decode_receiver_rx_band=${2}

    local rx_band_hashtable_archive=${HASHFILE_ARCHIVE_PATH}/${wspr_decode_receiver_name}/${wspr_decode_receiver_rx_band}
    mkdir -p ${rx_band_hashtable_archive}/
    cp -p hashtable.txt ${rx_band_hashtable_archive}/updating
    [[ ${verbosity} -ge 3 ]] && echo "$(date): update_hashtable_archive() copying local hashtable.txt to ${rx_band_hashtable_archive}/updating"
}


###
### This function MUST BE CALLLED ONLY BY THE WATCHDOG DAEMON
function update_master_hashtable() 
{
    [[ ${verbosity} -ge 3 ]] && echo "$(date): running update_master_hashtable()"
    declare -r HASHFILE_TMP_DIR=${WSPRDAEMON_TMP_DIR}/hashfile.d
    mkdir -p ${HASHFILE_TMP_DIR}
    declare -r HASHFILE_TMP_ALL_FILE=${HASHFILE_TMP_DIR}/hash-all.txt
    declare -r HASHFILE_TMP_UNIQ_CALLS_FILE=${HASHFILE_TMP_DIR}/hash-uniq-calls.txt
    declare -r HASHFILE_TMP_UNIQ_HASHES_FILE=${HASHFILE_TMP_DIR}/hash-uniq-hashes.txt
    declare -r HASHFILE_TMP_DIFF_FILE=${HASHFILE_TMP_DIR}/hash-diffs.txt

    mkdir -p ${HASHFILE_ARCHIVE_PATH}
    if [[ ! -f ${HASHFILE_MASTER_FILE} ]]; then
        touch ${HASHFILE_MASTER_FILE}
    fi
    if [[ ! -f ${HASHFILE_MASTER_FILE_OLD} ]]; then
        cp -p ${HASHFILE_MASTER_FILE} ${HASHFILE_MASTER_FILE_OLD}
    fi
    if [[ ${MAX_HASHFILE_AGE_SECS} -gt 0 ]]; then
        local old_time=$($GET_FILE_MOD_TIME_CMD ${HASHFILE_MASTER_FILE_OLD})
        local new_time=$($GET_FILE_MOD_TIME_CMD ${HASHFILE_MASTER_FILE})
        if [[ $(( $new_time - $old_time)) -gt ${MAX_HASHFILE_AGE_SECS} ]]; then
            ### Flush the master hash table when it gets old
            [[ ${verbosity} -ge 2 ]] && echo "$(date): flushing old master hashtable.txt"
            mv ${HASHFILE_MASTER_FILE} ${HASHFILE_MASTER_FILE_OLD}
            touch ${HASHFILE_MASTER_FILE}
            return
        fi
    fi
    if ! compgen -G "${HASHFILE_ARCHIVE_PATH}/*/*/hashtable.txt" > /dev/null; then
        [[ ${verbosity} -ge 3 ]] && echo "$(date): update_master_hashtable found no rx/band directories"
    else
        ### There is at least one hashtable.txt file.  Create a clean master
        cat ${HASHFILE_MASTER_FILE} ${HASHFILE_ARCHIVE_PATH}/*/*/hashtable.txt                                                        | sort -un > ${HASHFILE_TMP_ALL_FILE}
        ### Remove all lines with duplicate calls, calls with '/', and lines with more or less than 2 fields
        awk '{print $2}' ${HASHFILE_TMP_ALL_FILE}        | uniq -d | ${GREP_CMD} -v -w -F -f - ${HASHFILE_TMP_ALL_FILE}                      > ${HASHFILE_TMP_UNIQ_CALLS_FILE}
        ### Remove both lines if their hash values match
        awk '{print $1}' ${HASHFILE_TMP_UNIQ_CALLS_FILE} | uniq -d | ${GREP_CMD} -v -w -F -f - ${HASHFILE_TMP_UNIQ_CALLS_FILE}                          > ${HASHFILE_TMP_UNIQ_HASHES_FILE}
        if diff ${HASHFILE_MASTER_FILE} ${HASHFILE_TMP_UNIQ_HASHES_FILE} > ${HASHFILE_TMP_DIFF_FILE} ; then
            [[ ${verbosity} -ge 3 ]] && echo "$(date): update_master_hashtable found no new hashes"
        else
            if [[ ${verbosity} -ge 2 ]]; then
                echo "$(date): Updating the master hashtable with new entries:"
                ${GREP_CMD} '>' ${HASHFILE_TMP_DIFF_FILE}
                local old_size=$(cat ${HASHFILE_MASTER_FILE} | wc -l)
                local new_size=$(cat ${HASHFILE_TMP_UNIQ_HASHES_FILE}       | wc -l)
                local added_lines_count=$(( $new_size - $old_size))
                echo "$(date): old hash size = $old_size, new hash size $new_size => new entries = $added_lines_count"
            fi
            cp -p ${HASHFILE_TMP_UNIQ_HASHES_FILE} ${HASHFILE_MASTER_FILE}.tmp
            cp -p ${HASHFILE_MASTER_FILE} ${HASHFILE_MASTER_FILE}.last            ### Helps for diagnosing problems with this code
            mv ${HASHFILE_MASTER_FILE}.tmp ${HASHFILE_MASTER_FILE}                ### use 'mv' to avoid potential race conditions with decode_daemon processes which are reading this file
        fi
    fi
}
        
##########
function get_af_db() {
    local local real_receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local real_receiver_rx_band=${2}
    local default_value=0

    local af_info_field="$(get_receiver_af_list_from_name ${real_receiver_name})"
    if [[ -z "${af_info_field}" ]]; then
        echo ${default_value}
        return
    fi
    local af_info_list=(${af_info_field//,/ })
    for element in ${af_info_list[@]}; do
        local fields=(${element//:/ })
        if [[ ${fields[0]} == "DEFAULT" ]]; then
            default_value=${fields[1]}
        elif [[ ${fields[0]} == ${real_receiver_rx_band} ]]; then
            echo ${fields[1]}
            return
        fi
    done
    echo ${default_value}
}

############## Decoding ################################################
### For each real receiver/band there is one decode daemon and one recording daemon
### Waits for a new wav file then decodes and posts it to all of the posting lcient


declare -r DECODING_CLIENTS_SUBDIR="decoding_clients.d"     ### Each decoding daemon will create its own subdir where it will copy YYMMDD_HHMM_wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                            ### Delete the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..
declare FFT_WINDOW_CMD=${WSPRDAEMON_ROOT_DIR}/wav_window.py

declare C2_FFT_ENABLED="yes"          ### If "yes", then use the c2 file produced by wsprd to calculate FFT noisae levels
declare C2_FFT_CMD=${WSPRDAEMON_ROOT_DIR}/c2_noise.py

#########
### For future reference, here are the spot file output lines for ALL_WSPR.TXT and wspr_spots.txt taken from the wsjt-x 2.1-2 source code:
# In WSJT-x v 2.2, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
# fprintf(fall_wspr, "%6s              %4s                                      %3.0f          %5.2f           %11.7f               %-22s                    %2d            %5.2f                          %2d                   %2d                %4d                    %2d                  %3d                   %5u                %5d\n",
# NEW     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].sync,          decodes[i].ipass+1, decodes[i].blocksize, decodes[i].jitter, decodes[i].decodetype, decodes[i].nhardmin, decodes[i].cycles/81, decodes[i].metric);
# fprintf(fall_wspr, "%6s              %4s                        %3d           %3.0f          %5.2f           %11.7f               %-22s                    %2d                        %5u                                      %4d                %4d                                                      %4d                        %2u\n",
# OLD     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, (int)(10*decodes[i].sync),                    decodes[i].blocksize, decodes[i].jitter,                                             decodes[i].cycles/81, decodes[i].metric);
# OLD                                                                                                                                                                                     , decodes[i].osd_decode);
# OLD     decodes[i].date, decodes[i].time, (int)(10*decodes[i].sync), decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift,                                      decodes[i].cycles/81, decodes[i].jitter, decodes[i].blocksize, decodes[i].metric, decodes[i].osd_decode);
# 
# In WSJT-x v 2.1, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
# fprintf(fall_wspr, "%6s %4s %3d %3.0f %5.2f %11.7f %-22s %2d %5u   %4d %4d %4d %2u\n",
#          decodes[i].date, decodes[i].time, (int)(10*decodes[i].sync), decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].cycles/81, decodes[i].jitter,decodes[i].blocksize,decodes[i].metric,decodes[i].osd_decode);
#
# The lines of wsprd_spots.txt are the same in all versions
#   fprintf(fwsprd, "%6s %4s %3d %3.0f %4.1f %10.6f  %-22s %2d %5u %4d\n",
#            decodes[i].date, decodes[i].time, (int)(10*decodes[i].sync), decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].cycles/81, decodes[i].jitter);

function decoding_daemon() 
{
    local real_receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local real_receiver_rx_band=${2}
    local real_recording_dir=$(get_recording_dir_path ${real_receiver_name} ${real_receiver_rx_band})

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    ### Since they are not CPU intensive, always calculate sox RMS and C2 FFT stats
    local real_receiver_maidenhead=$(get_my_maidenhead)

    ### Store the signal level logs under the ~/wsprdaemon/... directory where it won't be lost due to a reboot or power cycle.
    SIGNAL_LEVELS_LOG_DIR=${WSPRDAEMON_ROOT_DIR}/signal_levels/${real_receiver_name}/${real_receiver_rx_band}
    mkdir -p ${SIGNAL_LEVELS_LOG_DIR}
    ### these could be modified from these default values by declaring them in the .conf file.
    SIGNAL_LEVEL_PRE_TX_SEC=${SIGNAL_LEVEL_PRE_TX_SEC-.25}
    SIGNAL_LEVEL_PRE_TX_LEN=${SIGNAL_LEVEL_PRE_TX_LEN-.5}
    SIGNAL_LEVEL_TX_SEC=${SIGNAL_LEVEL_TX_SEC-1}
    SIGNAL_LEVEL_TX_LEN=${SIGNAL_LEVEL_TX_LEN-109}
    SIGNAL_LEVEL_POST_TX_SEC=${SIGNAL_LEVEL_POST_TX_LEN-113}
    SIGNAL_LEVEL_POST_TX_LEN=${SIGNAL_LEVEL_POST_TX_LEN-5}
    SIGNAL_LEVELS_LOG_FILE=${SIGNAL_LEVELS_LOG_DIR}/signal-levels.log
    if [[ ! -f ${SIGNAL_LEVELS_LOG_FILE} ]]; then
        local  pre_tx_header="Pre Tx (${SIGNAL_LEVEL_PRE_TX_SEC}-${SIGNAL_LEVEL_PRE_TX_LEN})"
        local  tx_header="Tx (${SIGNAL_LEVEL_TX_SEC}-${SIGNAL_LEVEL_TX_LEN})"
        local  post_tx_header="Post Tx (${SIGNAL_LEVEL_POST_TX_SEC}-${SIGNAL_LEVEL_POST_TX_LEN})"
        local  field_descriptions="    'Pk lev dB' 'RMS lev dB' 'RMS Pk dB' 'RMS Tr dB'    "
        local  date_str=$(date)
        printf "${date_str}: %20s %-55s %-55s %-55s FFT\n" "" "${pre_tx_header}" "${tx_header}" "${post_tx_header}"   >  ${SIGNAL_LEVELS_LOG_FILE}
        printf "${date_str}: %s %s %s\n" "${field_descriptions}" "${field_descriptions}" "${field_descriptions}"   >> ${SIGNAL_LEVELS_LOG_FILE}
    fi
    local wspr_band_freq_khz=$(get_wspr_band_freq ${real_receiver_rx_band})
    local wspr_band_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${wspr_band_freq_khz}/1000.0" ) )
    local wspr_band_freq_hz=$(                     bc <<< "scale = 0; ${wspr_band_freq_khz}*1000.0/1" )

    if [[ -f ${WSPRDAEMON_ROOT_DIR}/noise_plot/noise_ca_vals.csv ]]; then
        local cal_vals=($(sed -n '/^[0-9]/s/,/ /gp' ${WSPRDAEMON_ROOT_DIR}/noise_plot/noise_ca_vals.csv))
    fi
    ### In each of these assignments, if cal_vals[] was not defined above from the file 'noise_ca_vals.csv', then use the default value.  e.g. cal_c2_correction will get the default value '-187.7
    local cal_nom_bw=${cal_vals[0]-320}        ### In this code I assume this is 320 hertz
    local cal_ne_bw=${cal_vals[1]-246}
    local cal_rms_offset=${cal_vals[2]--50.4}
    local cal_fft_offset=${cal_vals[3]--41.0}
    local cal_fft_band=${cal_vals[4]--13.9}
    local cal_threshold=${cal_vals[5]-13.1}
    local cal_c2_correction=${cal_vals[6]--187.7}

    local kiwi_amplitude_versus_frequency_correction="$(bc <<< "scale = 10; -1 * ( (2.2474 * (10 ^ -7) * (${wspr_band_freq_mhz} ^ 6)) - (2.1079 * (10 ^ -5) * (${wspr_band_freq_mhz} ^ 5)) + \
                                                                                     (7.1058 * (10 ^ -4) * (${wspr_band_freq_mhz} ^ 4)) - (1.1324 * (10 ^ -2) * (${wspr_band_freq_mhz} ^ 3)) + \
                                                                                     (1.0013 * (10 ^ -1) * (${wspr_band_freq_mhz} ^ 2)) - (3.7796 * (10 ^ -1) *  ${wspr_band_freq_mhz}     ) - (9.1509 * (10 ^ -1)))" )"
    if [[ $(bc <<< "${wspr_band_freq_mhz} > 30") -eq 1 ]]; then
        ### Don't adjust Kiwi's af when fed by transverter
        kiwi_amplitude_versus_frequency_correction=0
    fi
    local antenna_factor_adjust=$(get_af_db ${real_receiver_name} ${real_receiver_rx_band})
    local rx_khz_offset=$(get_receiver_khz_offset_list_from_name ${real_receiver_name})
    local total_correction_db=$(bc <<< "scale = 10; ${kiwi_amplitude_versus_frequency_correction} + ${antenna_factor_adjust}")
    local rms_adjust=$(bc -l <<< "${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}" )                                       ## bc -l invokes the math extension, l(x)/l(10) == log10(x)
    local fft_adjust=$(bc -l <<< "${cal_fft_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db} + ${cal_fft_band} + ${cal_threshold}" )  ## bc -l invokes the math extension, l(x)/l(10) == log10(x)
    wd_logger 2 "calculated the Kiwi to require a ${kiwi_amplitude_versus_frequency_correction} dB correction in this band
            Adding to that the antenna factor of ${antenna_factor_adjust} dB to results in a total correction of ${total_correction_db}
            rms_adjust=${rms_adjust} comes from ${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}
            fft_adjust=${fft_adjust} comes from ${cal_fft_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db} + ${cal_fft_band} + ${cal_threshold}
            rms_adjust and fft_adjust will be ADDed to the raw dB levels"
    ## G3ZIL implementation of algorithm using the c2 file by Christoph Mayer
    local c2_FFT_nl_adjust=$(bc <<< "scale = 2;var=${cal_c2_correction};var+=${total_correction_db}; (var * 100)/100")   # comes from a configured value.  'scale = 2; (var * 100)/100' forces bc to ouput only 2 digits after decimal
    wd_logger 2 "c2_FFT_nl_adjust = ${c2_FFT_nl_adjust} from 'local c2_FFT_nl_adjust=\$(bc <<< 'var=${cal_c2_correction};var+=${total_correction_db};var')"  # value estimated

    wd_logger 2 "Starting daemon to record '${real_receiver_name},${real_receiver_rx_band}'"
    local decoded_spots=0        ### Maintain a running count of the total number of spots_decoded
    local old_wsprd_decoded_spots=0   ### If we are comparing the new wsprd against the old wsprd, then this will count how many were decoded by the old wsprd

    cd ${real_recording_dir}
    local old_kiwi_ov_lines=0
    rm -f *.raw *.wav
    shopt -s nullglob
    while [[  -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; do    ### Keep decoding as long as there is at least one posting_daemon client
        wd_logger 3 "Checking recording process is running in $PWD"
        spawn_recording_daemon ${real_receiver_name} ${real_receiver_rx_band}
        wd_logger 3 "Checking for *.wav' files in $PWD"
        shopt -s nullglob    ### *.wav expands to NULL if there are no .wav wav_file_names
        ### Wait for a wav file and synthisize a zero length spot file every two minutes so MERGed rx don't hang if one real rx fails
        local -a wav_file_list
        while wav_file_list=( *.wav) && [[ ${#wav_file_list[@]} -eq 0 ]]; do
            ### recording daemon isn't outputing a wav file, so post a zero length spot file in order to signal the posting daemon to process other real receivers in a MERGed group 
            local wspr_spots_filename
            local wspr_decode_capture_date=$(date -u -d '2 minutes ago' +%g%m%d_%H%M)  ### Unlike the wav filenames used below, we can get DATE_TIME from 'date' in exactly the format we want
            local new_spots_file="${wspr_decode_capture_date}_${wspr_band_freq_hz}_wspr_spots.txt"
            rm -f ${new_spots_file}
            touch ${new_spots_file}
            local dir
            for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
                ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
                wd_logger 2 "Timeout waiting for a wav file, so copy a zero length ${new_spots_file} to ${dir}/ monitored by a posting daemon"
                cp -p ${new_spots_file} ${dir}/
            done
            rm ${new_spots_file} 
            wd_logger 2 "Found no wav files. Sleeping until next even minute."
            local next_start_time_string=$(sleep_until_next_even_minute)
        done
        for wav_file_name in *.wav; do
            wd_logger 2 "Monitoring size of wav file '${wav_file_name}'"

            ### Wait until the wav_file_name size isn't changing, i.e. kiwirecorder.py has finished writting this 2 minutes of capture and has moved to the next wav_file_name
            local old_wav_file_size=0
            local new_wav_file_size=$( ${GET_FILE_SIZE_CMD} ${wav_file_name} )
            while [[ -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]] && [[ ${new_wav_file_size} -ne ${old_wav_file_size} ]]; do
                old_wav_file_size=${new_wav_file_size}
                sleep ${WAV_FILE_POLL_SECONDS}
                new_wav_file_size=$( ${GET_FILE_SIZE_CMD} ${wav_file_name} )
                wd_logger 4 "Old size ${old_wav_file_size}, new size ${new_wav_file_size}"
            done
            if [[ -z "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; then
                wd_logger 2 "wav file size loop terminated due to no posting.d subdir"
                break
            fi
            wd_logger 2 "Wav file '${wav_file_name}' stabilized at size ${new_wav_file_size}."
            if  [[ ${new_wav_file_size} -lt ${WSPRD_WAV_FILE_MIN_VALID_SIZE} ]]; then
                wd_logger 2 "wav file '${wav_file_name}' size ${new_wav_file_size} is too small to be processed by wsprd.  Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi

            local wspr_decode_capture_date=${wav_file_name/T*}
            wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
            local wspr_decode_capture_time=${wav_file_name#*T}
            wspr_decode_capture_time=${wspr_decode_capture_time/Z*}
            local wspr_decode_capture_sec=${wspr_decode_capture_time:4}
            if [[ ${wspr_decode_capture_sec} != "00" ]]; then
                wd_logger 2 "wav file '${wav_file_name}' size ${new_wav_file_size} shows that recording didn't start at second "00". Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi
            local wspr_decode_capture_min=${wspr_decode_capture_time:2:2}
            if [[ ! ${wspr_decode_capture_min:1} =~ [02468] ]]; then
                wd_logger 2 "wav file '${wav_file_name}' size ${new_wav_file_size} shows that recording didn't start on an even minute. Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi
            wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
            local wsprd_input_wav_filename=${wspr_decode_capture_date}_${wspr_decode_capture_time}.wav    ### wsprd prepends the date_time to each new decode in wspr_spots.txt
            local wspr_decode_capture_freq_hz=${wav_file_name#*_}
            wspr_decode_capture_freq_hz=$( bc <<< "${wspr_decode_capture_freq_hz/_*} + (${rx_khz_offset} * 1000)" )
            local wspr_decode_capture_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${wspr_decode_capture_freq_hz}/1000000.0" ) )
            local wspr_decode_capture_band_center_mhz=$( printf "%2.6f\n" $(bc <<< "scale = 5; (${wspr_decode_capture_freq_hz}+1500)/1000000.0" ) )
            ### 

            local wspr_decode_capture_minute=${wspr_decode_capture_time:2}

            [[ ! -s ALL_WSPR.TXT ]] && touch ALL_WSPR.TXT
            local all_wspr_size=$(${GET_FILE_SIZE_CMD} ALL_WSPR.TXT)
            if [[ ${all_wspr_size} -gt ${MAX_ALL_WSPR_SIZE} ]]; then
                wd_logger 1 "ALL_WSPR.TXT has grown too large, so truncating it"
                tail -n 1000 ALL_WSPR.TXT > ALL_WSPR.tmp
                mv ALL_WSPR.tmp ALL_WSPR.TXT
            fi
            refresh_local_hashtable  ## In case we are using a hashtable created by merging hashes from other bands
            ln ${wav_file_name} ${wsprd_input_wav_filename}
            local wsprd_cmd_flags=${WSPRD_CMD_FLAGS}
            #if [[ ${real_receiver_rx_band} =~ 60 ]]; then
            #    wsprd_cmd_flags=${WSPRD_CMD_FLAGS/-o 4/-o 3}   ## At KPH I found that wsprd takes 90 seconds to process 60M wav files. This speeds it up for those bands
            #fi
            local start_time=${SECONDS}
            timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wsprd_input_wav_filename} > ${WSPRD_DECODES_FILE}
            local ret_code=$?
            local run_time=$(( ${SECONDS} - ${start_time} ))
            if [[ ${ret_code} -ne 0 ]]; then
                if [[ ${ret_code} -eq 124 ]]; then
                    wd_logger 1 "'wsprd' timeout with ret_code = ${ret_code} after ${run_time} seconds"
                else
                    wd_logger 1 "'wsprd' retuned error ${ret_code} after ${run_time} seconds.  It printed:\n$(cat ${WSPRD_DECODES_FILE})"
                fi
                ### A zero length wspr_spots.txt file signals the following code that no spots were decoded
                rm -f wspr_spots.txt
                touch wspr_spots.txt
                ### There is almost certainly no useful c2 noise level data
                local c2_FFT_nl_cal=-999.9
            else
                ### 'wsprd' was successful
                ### Validate, and if necessary cleanup, the spot list file created by wsprd
                local bad_wsprd_lines=$(awk 'NF < 11 || NF > 12 || $6 == 0.0 {printf "%40s: %s\n", FILENAME, $0}' wspr_spots.txt)
                if [[ -n "${bad_wsprd_lines}" ]]; then
                    ### Save this corrupt wspr_spots.txt, but leave it untouched so it can be used later to tell us how man ALL_WSPT.TXT lines to process
                    mkdir -p bad_wspr_spots.d
                    cp -p wspr_spots.txt bad_wspr_spots.d/
                    ###
                    ### awk 'NF >= 11 && NF <= 12 &&  $6 != 0.0' bad_wspr_spots.d/wspr_spots.txt > wspr_spots.txt
                    wd_logger 0 "WARNING:  wsprd created a wspr_spots.txt with corrupt line(s):\n%s" "${bad_wsprd_lines}"
                fi

                local new_spots=$(wc -l wspr_spots.txt)
                decoded_spots=$(( decoded_spots + ${new_spots/ *} ))
                wd_logger 2 "decoded ${new_spots/ *} new spots.  ${decoded_spots} spots have been decoded since this daemon started"

                ### Since they are so computationally and storage space cheap, always calculate a C2 FFT noise level
                local c2_filename="000000_0001.c2" ### -c instructs wsprd to create the C2 format file "000000_0001.c2"
                if [[ ! -f ${C2_FFT_CMD} ]]; then
                    wd_logger 0 "Can't find the '${C2_FFT_CMD}' script"
                    exit 1
                fi
                python3 ${C2_FFT_CMD} ${c2_filename}  > c2_FFT.txt 
                local c2_FFT_nl=$(cat c2_FFT.txt)
                local c2_FFT_nl_cal=$(bc <<< "scale=2;var=${c2_FFT_nl};var+=${c2_FFT_nl_adjust};(var * 100)/100")
                wd_logger 3 "c2_FFT_nl_cal=${c2_FFT_nl_cal} which is calculated from 'local c2_FFT_nl_cal=\$(bc <<< 'scale=2;var=${c2_FFT_nl};var+=${c2_FFT_nl_adjust};var/=1;var')"
                if [[ ${verbosity} -ge 1 ]] && [[ -x ${WSPRD_PREVIOUS_CMD} ]]; then
                    mkdir -p wsprd.old
                    cd wsprd.old
                    timeout ${WSPRD_TIMEOUT_SECS-60} nice ${WSPRD_PREVIOUS_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ../${wsprd_input_wav_filename} > wsprd_decodes.txt
                    local ret_code=$?

                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "error ${ret_code} reported running old wsprd"
                        cd - > /dev/null
                    else
                        local old_wsprd_spots=$(wc -l wspr_spots.txt)
                        old_wsprd_decoded_spots=$(( old_wsprd_decoded_spots + ${old_wsprd_spots/ *} ))
                        wd_logger 1 "new wsprd decoded ${new_spots/ *} new spots, ${decoded_spots} total spots.  Old wsprd decoded  ${old_wsprd_spots/ *} new spots, ${old_wsprd_decoded_spots} total spots"
                        cd - > /dev/null
                        ### Look for differences only in fields like SNR and frequency which are relevant to this comparison
                        awk '{printf "%s %s %4s %10s %-10s %-6s %s\n", $1, $2, $4, $6, $7, $8, $9 }' wspr_spots.txt                   > wspr_spots.txt.cut
                        awk '{printf "%s %s %4s %10s %-10s %-6s %s\n", $1, $2, $4, $6, $7, $8, $9 }' wsprd.old/wspr_spots.txt         > wsprd.old/wspr_spots.txt.cut
                        local spot_diffs
                        if ! spot_diffs=$(diff wsprd.old/wspr_spots.txt.cut wspr_spots.txt.cut) ; then
                            local new_count=$(cat wspr_spots.txt | wc -l)
                            local old_count=$(cat wsprd.old/wspr_spots.txt | wc -l)
                            echo -e "$(date): decoding_daemon(): '>' new wsprd decoded ${new_count} spots, '<' old wsprd decoded ${old_count} spots\n$(${GREP_CMD} '^[<>]' <<< "${spot_diffs}" | sort -n -k 5,5n)"
                        fi
                    fi
                fi
            fi

            ### If enabled, execute jt9 to attempt to decode FSTW4-120 beacons
            if [[ ${JT9_DECODE_ENABLED:-no} == "yes" ]]; then
                ${JT9_CMD} ${JT9_CMD_FLAGS} ${wsprd_input_wav_filename} >& jt9.log
                local ret_code=$?
                if [[ ${ret_code} -eq 0 ]]; then
                    wd_logger 1 "jt9 decode OK\n$(cat jt9.log)"
                else
                    wd_logger 1 "error ${ret_code} reported by jt9 decoder"
                fi
            fi

            # Get RMS levels from the wav file and adjuest them to correct for the effects of the LPF on the Kiwi's input
            local pre_tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_PRE_TX_SEC} ${SIGNAL_LEVEL_PRE_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            wd_logger 3 "raw   pre_tx_levels  levels '${pre_tx_levels[@]}'"
            local i
            for i in $(seq 0 $(( ${#pre_tx_levels[@]} - 1 )) ); do
                pre_tx_levels[${i}]=$(bc <<< "scale = 2; (${pre_tx_levels[${i}]} + ${rms_adjust})/1")           ### '/1' forces bc to use the scale = 2 setting
            done
            wd_logger 3 "fixed pre_tx_levels  levels '${pre_tx_levels[@]}'"
            local tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_TX_SEC} ${SIGNAL_LEVEL_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            for i in $(seq 0 $(( ${#tx_levels[@]} - 1 )) ); do
                tx_levels[${i}]=$(bc <<< "scale = 2; (${tx_levels[${i}]} + ${rms_adjust})/1")                   ### '/1' forces bc to use the scale = 2 setting
            done
            local post_tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_POST_TX_SEC} ${SIGNAL_LEVEL_POST_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            wd_logger 3 "raw   post_tx_levels levels '${post_tx_levels[@]}'"
            for i in $(seq 0 $(( ${#post_tx_levels[@]} - 1 )) ); do
                post_tx_levels[${i}]=$(bc <<< "scale = 2; (${post_tx_levels[${i}]} + ${rms_adjust})/1")         ### '/1' forces bc to use the scale = 2 setting
            done
            wd_logger 3 "fixed post_tx_levels levels '${post_tx_levels[@]}'"

            local rms_value=${pre_tx_levels[3]}                                           # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
            if [[  $(bc --mathlib <<< "${post_tx_levels[3]} < ${pre_tx_levels[3]}") -eq "1" ]]; then
                rms_value=${post_tx_levels[3]}
                wd_logger 3 "rms_level is from post"
            else
                wd_logger 3 "rms_level is from pre"
            fi
            wd_logger 3 "rms_value=${rms_value}"

            if [[ ${SIGNAL_LEVEL_UPLOAD-no} == "no" ]] || [[ ${SIGNAL_LEVEL_SOX_FFT_STATS-no} == "no" ]]; then
                ### Don't spend a lot of CPU time calculating a value which will not be uploaded
                local fft_value="-999.9"      ## i.e. "Not Calculated"
            else
                # Apply a Hann window to the wav file in 4096 sample blocks to match length of the FFT in sox stat -freq
                wd_logger 2 "applying windowing to .wav file '${wsprd_input_wav_filename}'"
                rm -f *.tmp    ### Flush zombie wav.tmp files, if any were left behind by a previous run of this daemon
                local windowed_wav_file=${wsprd_input_wav_filename/.wav/.tmp}
                if [[ ! -f ${FFT_WINDOW_CMD} ]]; then
                    wd_logger 0 "Can't find '${FFT_WINDOW_CMD}'"
                    exit 1
                fi
                /usr/bin/python3 ${FFT_WINDOW_CMD} ${wsprd_input_wav_filename} ${windowed_wav_file}
                mv ${windowed_wav_file} ${wsprd_input_wav_filename}

                wd_logger 2 "running 'sox FFT' on .wav file '${wsprd_input_wav_filename}'"
                # Get an FFT level from the wav file.  One could perform many kinds of analysis of this data.  We are simply averaging the levels of the 30% lowest levels
                nice sox ${wsprd_input_wav_filename} -n stat -freq 2> sox_fft.txt            # perform the fft
                nice awk -v freq_min=${SNR_FREQ_MIN-1338} -v freq_max=${SNR_FREQ_MAX-1662} '$1 > freq_min && $1 < freq_max {printf "%s %s\n", $1, $2}' sox_fft.txt > sox_fft_trimmed.txt      # extract the rows with frequencies within the 1340-1660 band

                ### Check to see if we are overflowing the /tmp/wsprdaemon file system
                local df_report_fields=( $(df ${WSPRDAEMON_TMP_DIR} | ${GREP_CMD} tmpfs) )
                local tmp_size=${df_report_fields[1]}
                local tmp_used=${df_report_fields[2]}
                local tmp_avail=${df_report_fields[3]}
                local tmp_percent_used=${df_report_fields[4]::-1}

                if [[ ${tmp_percent_used} -gt ${MAX_TMP_PERCENT_USED-90} ]]; then
                    wd_logger 1 "WARNING: ${WSPRDAEMON_TMP_DIR} is ${tmp_percent_used}% full.  Increase its size in /etc/fstab!"
                fi
                rm sox_fft.txt                                                               # Get rid of that 15 MB fft file ASAP
                nice sort -g -k 2 < sox_fft_trimmed.txt > sox_fft_sorted.txt                 # sort those numerically on the second field, i.e. fourier coefficient  ascending
                rm sox_fft_trimmed.txt                                                       # This is much smaller, but don't need it again
                local hann_adjust=6.0
                local fft_value=$(nice awk -v fft_adj=${fft_adjust} -v hann_adjust=${hann_adjust} '{ s += $2} NR > 11723 { print ( (0.43429 * 10 * log( s / 2147483647)) + fft_adj + hann_adjust) ; exit }'  sox_fft_sorted.txt)
                                                                                             # The 0.43429 is simply awk using natual log
                                                                                             #  the denominator in the sq root is the scaling factor in the text info at the end of the ftt file
                rm sox_fft_sorted.txt
                wd_logger 3 "sox_fft_value=${fft_value}"
            fi
            ### If this is a KiwiSDR, then discover the number of 'ADC OV' events recorded since the last cycle
            local new_kiwi_ov_count=0
            local current_kiwi_ov_lines=0
            if [[ -f kiwi_recorder.log ]]; then
                current_kiwi_ov_lines=$(${GREP_CMD} "^ ADC OV" kiwi_recorder.log | wc -l)
                if [[ ${current_kiwi_ov_lines} -lt ${old_kiwi_ov_lines} ]]; then
                    ### kiwi_recorder.log probably grew too large and the kiwirecorder.py was restarted 
                    old_kiwi_ov_lines=0
                fi
                new_kiwi_ov_count=$(( ${current_kiwi_ov_lines} - ${old_kiwi_ov_lines} ))
                old_kiwi_ov_lines=${current_kiwi_ov_lines}
            fi

            ### Output a line  which contains 'DATE TIME + three sets of four space-seperated statistics'i followed by the two FFT values followed by the approximate number of overload events recorded by a Kiwi during this WSPR cycle:
            ###                           Pre Tx                                                        Tx                                                   Post TX
            ###     'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'        'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'       'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB      RMS_noise C2_noise  New_overload_events'
            local signal_level_line="               ${pre_tx_levels[*]}          ${tx_levels[*]}          ${post_tx_levels[*]}   ${rms_value}    ${c2_FFT_nl_cal}  ${new_kiwi_ov_count}"
            echo "${wspr_decode_capture_date}-${wspr_decode_capture_time}: ${signal_level_line}" >> ${SIGNAL_LEVELS_LOG_FILE}
            local new_noise_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_noise.txt
            echo "${signal_level_line}" > ${new_noise_file}
            wd_logger 2 "noise was: '${signal_level_line}'"

            rm -f ${wav_file_name} ${wsprd_input_wav_filename}  ### We have completed processing the wav file, so delete both names for it

            ### 'wsprd' appends the new decodes to ALL_WSPR.TXT, but we are going to post only the new decodes which it puts in the file 'wspr_spots.txt'
            update_hashtable_archive ${real_receiver_name} ${real_receiver_rx_band}

            ### Forward the recording's date_time_freqHz spot file to the posting daemon which is polling for it.  Do this here so that it is after the very slow sox FFT calcs are finished
            local new_spots_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_spots.txt
            if [[ ! -f wspr_spots.txt ]] || [[ ! -s wspr_spots.txt ]]; then
                ### A zero length spots file signals the posting daemon that decodes are complete but no spots were found
                rm -f ${new_spots_file}
                touch  ${new_spots_file}
                wd_logger 2 "no spots were found.  Queuing zero length spot file '${new_spots_file}'"
            else
                ###  Spots were found. We want to add the noise level fields to the end of each spot
                local spot_for_wsprnet=0         ### the posting_daemon() will fill in this field
                local tmp_spot_file="spots.tmp"
                rm -f ${tmp_spot_file}
                touch ${tmp_spot_file}
                local new_spots_count=$(cat wspr_spots.txt | wc -l)
                local all_wspr_new_lines=$(tail -n ${new_spots_count} ALL_WSPR.TXT)     ### Take the same number of lines from the end of ALL_WSPR.TXT as are in wspr_sport.txt

                ### Further validation of the spots we are going to upload
                ### Use the date in the wspr_spots.txt to extract the corresponding lines from ALL_WSPR.TXT and verify the number of spots extracted matches the number of spots in wspr_spots.txt
                local wspr_spots_date=$( awk '{printf "%s %s\n", $1, $2}' wspr_spots.txt | sort -u )
                local all_wspr_new_date_lines=$( grep "^${wspr_spots_date}" ALL_WSPR.TXT)
                local all_wspr_new_date_lines_count=$( echo "${all_wspr_new_date_lines}" | wc -l )
                if [[ ${all_wspr_new_date_lines_count} -ne ${new_spots_count} ]]; then
                    wd_logger 0 "WARNING: the ${new_spots_count} spot lines in wspr_spots.txt don't match the ${all_wspr_new_date_lines_count} spots with the same date in ALL_WSPR.TXT\n"
                fi

                ### Cull corrupt lines from ALL_WSPR.TXT
                local all_wspr_bad_new_lines=$(awk 'NF < 16 || NF > 17 || $5 < 0.1' <<< "${all_wspr_new_lines}")
                if [[ -n "${all_wspr_bad_new_lines}" ]]; then
                    wd_logger 0 "WARNING: removing corrupt line(s) in ALL_WSPR.TXT:\n%s\n" "${all_wspr_bad_new_lines}"
                    all_wspr_new_lines=$(awk 'NF >= 16 && NF <=  17 && $5 >= 0.1' <<< "${all_wspr_new_lines}")
                fi

                wd_logger 2 "processing these ALL_WSPR.TXT lines:\n${all_wspr_new_lines}"
                local WSPRD_2_2_FIELD_COUNT=17   ## wsprd in wsjt-x v2.2 outputs 17 fields in a slightly different order than the 15 fields output by wsprd v2.1
                local WSPRD_2_2_WITHOUT_GRID_FIELD_COUNT=16   ## wsprd in wsjt-x v2.2 outputs 17 fields in a slightly different order than the 15 fields output by wsprd v2.1
                # fprintf(fall_wspr, "%6s              %4s                                      %3.0f          %5.2f           %11.7f               %-22s                    %2d            %5.2f                          %2d                   %2d                %4d                    %2d                  %3d                   %5u                %5d\n",
		# 2.2.x:     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].sync,          decodes[i].ipass+1, decodes[i].blocksize, decodes[i].jitter, decodes[i].decodetype, decodes[i].nhardmin, decodes[i].cycles/81, decodes[i].metric);
		# 2.2.x with grid:     200724 1250 -24  0.24  28.1260734  M0UNI IO82 33           0  0.23  1  1    0  1  45     1   810
		# 2.2.x without grid:  200721 0800  -7  0.15  28.1260594  DC7JZB/B 27            -1  0.68  1  1    0  0   0     1   759
		local spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields
		while read  spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields ; do
		    wd_logger 2 "read this V2.2 format ALL_WSPR.TXT line: '${spot_date}' '${spot_time}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${other_fields}'"
		    local spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype spot_nhardmin spot_decode_cycles spot_metric

		    local other_fields_list=( ${other_fields} )
		    local other_fields_list_count=${#other_fields_list[@]}

		    local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID=11
		    local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID=10
                    local got_valid_line="yes"
		    if [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID} ]]; then
		        read spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric <<< "${other_fields}"
                        wd_logger 2 "this V2.2 type 1 ALL_WSPR.TXT line has GRID: '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' '${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
		    elif [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
                        spot_grid=""
                        read spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric <<< "${other_fields}"
                        wd_logger 2 "this V2.2 type 2 ALL_WSPR.TXT line has no GRID: '${spot_date}' '${spot_time}' '${spot_sync_quality}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' ${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
                    else
                        wd_logger 0 "WARNING: tossing  a corrupt (not the expected 15 or 16 fields) ALL_WSPR.TXT spot line"
                        got_valid_line="no"
                    fi
                    if [[ ${got_valid_line} == "yes" ]]; then
                        #                              %6s %4s   %3d %3.0f %5.2f %11.7f %-22s          %2d %5u %4d  %4d %4d %2u\n"       ### fprintf() line from wsjt-x.  The %22s message field appears to include power
                        #local extended_line=$( printf "%4s %4s %5.2f %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4d, %2d %5d %2d %2d %3d %2d\n" \
                        local extended_line=$( printf "%6s %4s %5.2f %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
                        extended_line="${extended_line//[$'\r\n\t']}"  ### //[$'\r\n'] strips out the CR and/or NL which were introduced by the printf() for reasons I could not diagnose
                        echo "${extended_line}" >> ${tmp_spot_file}
                    fi
                done <<< "${all_wspr_new_lines}"
                local wspr_spots_file=${tmp_spot_file} 
                sed "s/\$/ ${rms_value}  ${c2_FFT_nl_cal}/" ${wspr_spots_file} > ${new_spots_file}  ### add  the noise fields
                wd_logger 2 "queuing enhanced spot file:\n$(cat ${new_spots_file})\n"
            fi

            ### Copy the noise level file and the renamed wspr_spots.txt to waiting posting daemons' subdirs
            shopt -s nullglob    ### * expands to NULL if there are no .wav wav_file
            local dir
            for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
                ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
                wd_logger 2 "copying ${new_spots_file} and ${new_noise_file} to ${dir}/ monitored by a posting daemon" 
                cp -p ${new_spots_file} ${new_noise_file} ${dir}/
            done
            rm ${new_spots_file} ${new_noise_file}
        done
        wd_logger 3 "Decoded and posted ALL_WSPR file."
        sleep 1   ###  No need for a long sleep, since recording daemon should be creating next wav file and this daemon will poll on the size of that wav file
    done
    wd_logger 2 "stopping recording and decoding of '${real_receiver_name},${real_receiver_rx_band}'"
    kill_recording_daemon ${real_receiver_name} ${real_receiver_rx_band}
}


### 
function spawn_decode_daemon() {
    local receiver_name=$1
    local receiver_rx_band=$2
    local capture_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})

    [[ $verbosity -ge 4 ]] && echo "$(date): spawn_decode_daemon(): starting decode of '${receiver_name},${receiver_rx_band}'"

    mkdir -p ${capture_dir}/${DECODING_CLIENTS_SUBDIR}     ### The posting_daemon() should have created this already
    cd ${capture_dir}
    if [[ -f decode.pid ]] ; then
        local decode_pid=$(cat decode.pid)
        if ps ${decode_pid} > /dev/null ; then
            [[ ${verbosity} -ge 4 ]] && echo "$(date): spawn_decode_daemon(): INFO: decode job with pid ${decode_pid} is already running, so nothing to do"
            return
        else
            [[ ${verbosity} -ge 2 ]] && echo "$(date): spawn_decode_daemon(): INFO: found dead decode job"
            rm -f decode.pid
        fi
    fi
    WD_LOGFILE=decoding_daemon.log decoding_daemon ${receiver_name} ${receiver_rx_band} &
    echo $! > decode.pid
    cd - > /dev/null
    [[ $verbosity -ge 2 ]] && echo "$(date): spawn_decode_daemon(): INFO: Spawned new decode  job '${receiver_name},${receiver_rx_band}' with PID '$!'"
}

###
function get_decoding_status() {
    local get_decoding_status_receiver_name=$1
    local get_decoding_status_receiver_rx_band=$2
    local get_decoding_status_receiver_decoding_dir=$(get_recording_dir_path ${get_decoding_status_receiver_name} ${get_decoding_status_receiver_rx_band})
    local get_decoding_status_receiver_decoding_pid_file=${get_decoding_status_receiver_decoding_dir}/decode.pid

    if [[ ! -d ${get_decoding_status_receiver_decoding_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_decoding_status_receiver_decoding_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_decoding_status_decode_pid=$(cat ${get_decoding_status_receiver_decoding_pid_file})
    if ! ps ${get_decoding_status_decode_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid '${get_decoding_status_decode_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_decoding_status_decode_pid}"
    return 0
}

#############################################################
################ Posting ####################################
#############################################################

declare POSTING_SUPPLIERS_SUBDIR="posting_suppliers.d"    ### Subdir under each posting deamon directory which contains symlinks to the decoding deamon(s) subdirs where spots for this daemon are copied

### This daemon creates links from the posting dirs of all the $3 receivers to a local subdir, then waits for YYMMDD_HHMM_wspr_spots.txt files to appear in all of those dirs, then merges them
### and 
function posting_daemon() 
{
    local posting_receiver_name=${1}
    local posting_receiver_band=${2}
    local real_receiver_list=(${3})
    local real_receiver_count=${#real_receiver_list[@]}

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    source ${WSPRDAEMON_CONFIG_FILE}
    local my_call_sign="$(get_receiver_call_from_name ${posting_receiver_name})"
    local my_grid="$(get_receiver_grid_from_name ${posting_receiver_name})"
    
    ### Where to put the spots from the one or more real receivers for the upload daemon to find
    local  wsprnet_upload_dir=${UPLOADS_WSPRNET_SPOTS_DIR}/${my_call_sign//\//=}_${my_grid}/${posting_receiver_name}/${posting_receiver_band}  ## many ${my_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
    mkdir -p ${wsprnet_upload_dir}

    ### Create a /tmp/.. dir where this instance of the daemon will process and merge spotfiles.  Then it will copy them to the uploads.d directory in a persistent file system
    local posting_receiver_dir_path=$PWD
    wd_logger 1 "Starting to post '${posting_receiver_name},${posting_receiver_band}' in '${posting_receiver_dir_path}' and copy spots from real_rx(s) '${real_receiver_list[@]}' to '${wsprnet_upload_dir}"

    ### Link the real receivers to this dir
    local posting_source_dir_list=()
    local real_receiver_name
    mkdir -p ${POSTING_SUPPLIERS_SUBDIR}
    for real_receiver_name in ${real_receiver_list[@]}; do
        ### Create posting subdirs for each real recording/decoding receiver to copy spot files
        ### If a schedule change disables this receiver, we will want to signal to the real receivers that we are no longer listening to their spots
        ### To find those receivers, create a posting dir under each real reciever and make a sybolic link from our posting subdir to that real posting dir
        ### Since both dirs are under /tmp, create a hard link between that new dir and a dir under the real receiver where it will copy its spots
        local real_receiver_dir_path=$(get_recording_dir_path ${real_receiver_name} ${posting_receiver_band})
        local real_receiver_posting_dir_path=${real_receiver_dir_path}/${DECODING_CLIENTS_SUBDIR}/${posting_receiver_name}
        ### Since this posting daemon may be running before it's supplier decoding_daemon(s), create the dir path for that supplier
        mkdir -p ${real_receiver_posting_dir_path}
        ### Now create a symlink from under here to the directory where spots will apper
        local this_rx_local_dir_name=${POSTING_SUPPLIERS_SUBDIR}/${real_receiver_name}
        [[ ! -f ${this_rx_local_dir_name} ]] && ln -s ${real_receiver_posting_dir_path} ${this_rx_local_dir_name}
        posting_source_dir_list+=(${this_rx_local_dir_name})
        wd_logger 2 "Created a symlink from ${this_rx_local_dir_name} to ${real_receiver_posting_dir_path}"
    done

    shopt -s nullglob    ### * expands to NULL if there are no file matches
    local daemon_stop="no"
    while [[ ${daemon_stop} == "no" ]]; do
        wd_logger 2 "Starting check for all posting subdirs to have a YYMMDD_HHMM_wspr_spots.txt file in them"
        local newest_all_wspr_file_path=""
        local newest_all_wspr_file_name=""

        ### Wait for all of the real receivers to decode ands post a *_wspr_spots.txt file
        local waiting_for_decodes=yes
        local printed_waiting=no   ### So we print out the 'waiting...' message only once at the start of each wait cycle
        while [[ ${waiting_for_decodes} == "yes" ]]; do
            ### Start or keep alive decoding daemons for each real receiver
            local real_receiver_name
            for real_receiver_name in ${real_receiver_list[@]} ; do
                wd_logger 4 "Checking or starting decode daemon for real receiver ${real_receiver_name} ${posting_receiver_band}"
                ### '(...) runs in subshell so it can't change the $PWD of this function
                (spawn_decode_daemon ${real_receiver_name} ${posting_receiver_band}) ### Make sure there is a decode daemon running for this receiver.  A no-op if already running
            done

            wd_logger 3 "Checking for subdirs to have the same *_wspr_spots.txt in them" 
            waiting_for_decodes=yes
            newest_all_wspr_file_path=""
            local posting_dir
            for posting_dir in ${posting_source_dir_list[@]}; do
                wd_logger 4 "Checking dir ${posting_dir} for wspr_spots.txt files"
                if [[ ! -d ${posting_dir} ]]; then
                    wd_logger 2 "Expected posting dir ${posting_dir} does not exist, so exiting inner for loop"
                    daemon_stop="yes"
                    break
                fi
                for file in ${posting_dir}/*_wspr_spots.txt; do
                    if [[ -z "${newest_all_wspr_file_path}" ]]; then
                        wd_logger 4 "Found first wspr_spots.txt file ${file}"
                        newest_all_wspr_file_path=${file}
                    elif [[ ${file} -nt ${newest_all_wspr_file_path} ]]; then
                        wd_logger 4 "Found ${file} is newer than ${newest_all_wspr_file_path}"
                        newest_all_wspr_file_path=${file}
                    else
                        wd_logger 4 "Found ${file} is older than ${newest_all_wspr_file_path}"
                    fi
                done
            done
            if [[ ${daemon_stop} != "no" ]]; then
                wd_logger 3 " The expected posting dir ${posting_dir} does not exist, so exiting inner while loop"
                daemon_stop="yes"
                break
            fi
            if [[ -z "${newest_all_wspr_file_path}" ]]; then
                wd_logger 4 "Found no wspr_spots.txt files"
            else
                [[ ${verbosity} -ge 3 ]] && printed_waiting=no   ### We have found some spots.txt files, so signal to print 'waiting...' message at the start of the next wait cycle
                newest_all_wspr_file_name=${newest_all_wspr_file_path##*/}
                wd_logger 3 "Found newest wspr_spots.txt == ${newest_all_wspr_file_path} => ${newest_all_wspr_file_name}"
                ### Flush all *wspr_spots.txt files which don't match the name of this newest file
                local posting_dir
                for posting_dir in ${posting_source_dir_list[@]}; do
                    cd ${posting_dir}
                    local file
                    for file in *_wspr_spots.txt; do
                        if [[ ${file} != ${newest_all_wspr_file_name} ]]; then
                            wd_logger 3 "Flushing file ${posting_dir}/${file} which doesn't match ${newest_all_wspr_file_name}"
                            rm -f ${file}
                        fi
                    done
                    cd - > /dev/null
                done
                ### Check that an wspr_spots.txt with the same date/time/freq is present in all subdirs
                waiting_for_decodes=no
                local posting_dir
                for posting_dir in ${posting_source_dir_list[@]}; do
                    if [[ ! -f ${posting_dir}/${newest_all_wspr_file_name} ]]; then
                        waiting_for_decodes=yes
                        wd_logger 3 "Found no file ${posting_dir}/${newest_all_wspr_file_name}"
                    else
                        wd_logger 3 "Found    file ${posting_dir}/${newest_all_wspr_file_name}"
                    fi
                done
            fi
            if [[  ${waiting_for_decodes} == "yes" ]]; then
                wd_logger 4 "Is waiting for files. Sleeping..."
                sleep ${WAV_FILE_POLL_SECONDS}
            else
                wd_logger 3 "Found the required ${newest_all_wspr_file_name} in all the posting subdirs, so can merge and post"
            fi
        done
        if [[ ${daemon_stop} != "no" ]]; then
            wd_logger 3 "Exiting outer while loop"
            break
        fi
        ### All of the ${real_receiver_list[@]} directories have *_wspr_spot.txt files with the same time&name

        ### Clean out any older *_wspr_spots.txt files
        wd_logger 3 "Flushing old *_wspr_spots.txt files"
        local posting_source_dir
        local posting_source_file
        for posting_source_dir in ${posting_source_dir_list[@]} ; do
            cd -P ${posting_source_dir}
            for posting_source_file in *_wspr_spots.txt ; do
                if [[ ${posting_source_file} -ot ${newest_all_wspr_file_path} ]]; then
                    wd_logger 3 "Flushing file ${posting_source_file} which is older than the newest complete set of *_wspr_spots.txt files"
                    rm $posting_source_file
                else
                    wd_logger 3 "Preserving file ${posting_source_file} which is same or newer than the newest complete set of *_wspr_spots.txt files"
                fi
            done
            cd - > /dev/null
        done

        ### The date and time of the spots are prepended to the spots and noise files when they are queued for upload 
        local recording_info=${newest_all_wspr_file_name/_wspr_spots.txt/}     ### extract the date_time_freq part of the file name
        local recording_freq_hz=${recording_info##*_}
        local recording_date_time=${recording_info%_*}

        ### Queue spots (if any) for this real or MERGed receiver to wsprnet.org
        ### Create one spot file containing the best set of CALLS/SNRs for upload to wsprnet.org
        local newest_list=(${posting_source_dir_list[@]/%/\/${newest_all_wspr_file_name}})
        local wsprd_spots_all_file_path=${posting_receiver_dir_path}/wspr_spots.txt.ALL
        cat ${newest_list[@]} > ${wsprd_spots_all_file_path}
        local wsprd_spots_best_file_path
        if [[ ! -s ${wsprd_spots_all_file_path} ]]; then
            ### The decode daemon of each real receiver signaled it had decoded a wave file with zero spots by creating a zero length spot.txt file 
            wd_logger 2 "No spots were decoded"
            wsprd_spots_best_file_path=${wsprd_spots_all_file_path}
        else
            ### At least one of the real receiver decoder reported a spot. Create a spot file with only the strongest SNR for each call sign
             wsprd_spots_best_file_path=${posting_receiver_dir_path}/wspr_spots.txt.BEST

            wd_logger 2 "Merging and sorting files '${newest_list[@]}' into ${wsprd_spots_all_file_path}"

            ### Get a list of all calls found in all of the receiver's decodes
            local posting_call_list=$( cat ${wsprd_spots_all_file_path} | awk '{print $7}'| sort -u )
            [[ -n "${posting_call_list}" ]] && wd_logger 3 " found this set of unique calls: '${posting_call_list}'"

            ### For each of those calls, get the decode line with the highest SNR
            rm -f best_snrs.tmp
            touch best_snrs.tmp
            local call
            for call in ${posting_call_list}; do
                ${GREP_CMD} " ${call} " ${wsprd_spots_all_file_path} | sort -k4,4n | tail -n 1 > this_calls_best_snr.tmp  ### sorts by SNR and takes only the highest
                cat this_calls_best_snr.tmp >> best_snrs.tmp
                wd_logger 2 "Found the best SNR report for call '${call}' was '$(cat this_calls_best_snr.tmp)'"
            done
            sed 's/,.*//' best_snrs.tmp | sort -k 6,6n > ${wsprd_spots_best_file_path}   ### Chop off the RMS and FFT fields, then sort by ascending frequency.  
            rm -f best_snrs.tmp this_calls_best_snr.tmp 
            ### Now ${wsprd_spots_best_file_path} contains one decode per call from the highest SNR report sorted in ascending signal frequency

            ### If this is a MERGed rx, then log SNR decsions to "merged.log" file
            if [[ ${posting_receiver_name} =~ MERG.* ]] && [[ ${LOG_MERGED_SNRS-yes} == "yes"  ]]; then
                local merged_log_file="merged.log"
                log_merged_snrs >> ${merged_log_file}
                truncate_file ${merged_log_file} ${MAX_MERGE_LOG_FILE_SIZE-1000000}        ## Keep each of these logs to less than 1 MByte
            fi
            ### TODO: get a per-rx list of spots so the operation below can mark which real-rx should be uploaded by the proxy upload service on the wsprdaemon.org server
        fi

        mkdir -p ${wsprnet_upload_dir}
        local upload_wsprnet_file_path=${wsprnet_upload_dir}/${recording_date_time}_${recording_freq_hz}_wspr_spots.txt
        source ${RUNNING_JOBS_FILE}
        if [[ "${RUNNING_JOBS[@]}" =~ ${posting_receiver_name} ]]; then
            ### Move the wspr_spot.tx.BEST file we have just created to a uniquely named file in the uploading directory
            mv ${wsprd_spots_best_file_path} ${upload_wsprnet_file_path} 
            if [[ -s ${upload_wsprnet_file_path} ]]; then
                wd_logger 1 "Moved ${wsprd_spots_best_file_path} to ${upload_wsprnet_file_path} which contains spots:\n$(cat ${upload_wsprnet_file_path})"
            else
                wd_logger 1 " created zero length spot file ${upload_wsprnet_file_path}"
            fi
        else
            ### This real rx is a member of a MERGed rx, so its spots are being merged with other real rx
            wd_logger 1 "Not queuing ${wsprd_spots_best_file_path} for upload to wsprnet.org since this rx is not a member of RUNNING_JOBS '${RUNNING_JOBS[@]}'"
        fi
 
        ###  Queue spots and noise from all real receivers for upload to wsprdaemon.org
        local real_receiver_band=${PWD##*/}
        ### For each real receiver, queue any *wspr_spots.txt files containing at least on spot.  there should always be *noise.tx files to upload
        for real_receiver_dir in ${POSTING_SUPPLIERS_SUBDIR}/*; do
            local real_receiver_name=${real_receiver_dir#*/}

            ### Upload spots file
            local real_receiver_wspr_spots_file_list=( ${real_receiver_dir}/*_wspr_spots.txt )
            local real_receiver_wspr_spots_file_count=${#real_receiver_wspr_spots_file_list[@]}
            if [[ ${real_receiver_wspr_spots_file_count} -ne 1 ]]; then
                if [[ ${real_receiver_wspr_spots_file_count} -eq 0 ]]; then
                    wd_logger 1 " INTERNAL ERROR: found real rx dir ${real_receiver_dir} has no *_wspr_spots.txt file."
                else
                    wd_logger 1 " INTERNAL ERROR: found real rx dir ${real_receiver_dir} has ${real_receiver_wspr_spots_file_count} spot files. Flushing them."
                    rm -f ${real_receiver_wspr_spots_file_list[@]}
                fi
            else
                ### There is one spot file for this rx
                local real_receiver_wspr_spots_file=${real_receiver_wspr_spots_file_list[0]}
                local filtered_receiver_wspr_spots_file="filtered_spots.txt"   ### Remove all but the strongest SNR for each CALL
                rm -f ${filtered_receiver_wspr_spots_file}
                touch ${filtered_receiver_wspr_spots_file}    ### In case there are no spots in the real rx
                if [[ ! -s ${real_receiver_wspr_spots_file} ]]; then
                    wd_logger 2 " spot file has no spots, but copy it to the upload directory so upload_daemon knows that this wspr cycle decode has been completed"
                else
                    wd_logger 2 " queue real rx spots file '${real_receiver_wspr_spots_file}' for upload to wsprdaemon.org"
                    ### Make sure there is only one spot for each CALL in this file.
                    ### Get a list of all calls found in all of the receiver's decodes
                    local posting_call_list=$( cat ${real_receiver_wspr_spots_file} | awk '{print $7}'| sort -u )
                    wd_logger 3 " found this set of unique calls: '${posting_call_list}'"

                    ### For each of those calls, get the decode line with the highest SNR
                    rm -f best_snrs.tmp
                    touch best_snrs.tmp       ## In case there are no calls, ensure there is a zero length file
                    local call
                    for call in ${posting_call_list}; do
                        ${GREP_CMD} " ${call} " ${real_receiver_wspr_spots_file} | sort -k4,4n | tail -n 1 > this_calls_best_snr.tmp  ### sorts by SNR and takes only the highest
                        cat this_calls_best_snr.tmp >> best_snrs.tmp
                        wd_logger 2 " found the best SNR report for call '${call}' was '$(cat this_calls_best_snr.tmp)'"
                    done
                    ### Now ${wsprd_spots_best_file_path} contains one decode per call from the highest SNR report sorted in ascending signal frequency
                    if [[ ${verbosity} -ge 2 ]]; then
                        if ! diff ${real_receiver_wspr_spots_file} best_snrs.tmp  > /dev/null; then
                            echo -e "$(date): posting_daemon() found duplicate calls in:\n$(cat ${real_receiver_wspr_spots_file})\nSo uploading only:\n$(cat best_snrs.tmp)"
                        fi
                    fi
                    sed 's/,//' best_snrs.tmp | sort -k 6,6n > ${filtered_receiver_wspr_spots_file}   ### remove the ',' in the spot lines, but leave the noise fields
                    rm -f best_snrs.tmp this_calls_best_snr.tmp 
                fi
                local real_receiver_enhanced_wspr_spots_file="enhanced_wspr_spots.txt"
                create_enhanced_spots_file ${filtered_receiver_wspr_spots_file} ${real_receiver_enhanced_wspr_spots_file} ${my_grid}

                local  upload_wsprdaemon_spots_dir=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/${my_call_sign//\//=}_${my_grid}/${real_receiver_name}/${real_receiver_band}  ## many ${my_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
                mkdir -p ${upload_wsprdaemon_spots_dir}
                local upload_wsprd_file_path=${upload_wsprdaemon_spots_dir}/${recording_date_time}_${recording_freq_hz}_wspr_spots.txt
                mv ${real_receiver_enhanced_wspr_spots_file} ${upload_wsprd_file_path}
                rm -f ${real_receiver_wspr_spots_file}
                if [[ ${verbosity} -ge 2 ]]; then
                    if [[ -s ${upload_wsprd_file_path} ]]; then
                        echo -e "$(date): posting_daemon() copied ${real_receiver_enhanced_wspr_spots_file} to ${upload_wsprd_file_path} which contains spot(s):\n$( cat ${upload_wsprd_file_path})"
                    else
                        echo -e "$(date): posting_daemon() created zero length spot file ${upload_wsprd_file_path}"
                    fi
                fi
            fi
 
            ### Upload noise file
            local noise_files_list=( ${real_receiver_dir}/*_wspr_noise.txt )
            local noise_files_list_count=${#noise_files_list[@]}
            if [[ ${noise_files_list_count} -lt 1 ]]; then
                [[ ${verbosity} -ge 2 ]] && printf "$(date): posting_daemon() expected noise.txt file is missing\n"
            else
                local  upload_wsprdaemon_noise_dir=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/${my_call_sign//\//=}_${my_grid}/${real_receiver_name}/${real_receiver_band}  ## many ${my_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
                mkdir -p ${upload_wsprdaemon_noise_dir}

                mv ${noise_files_list[@]} ${upload_wsprdaemon_noise_dir}   ### The TIME_FREQ is already part of the noise file name
                [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() moved noise file '${noise_files_list[@]}' to '${upload_wsprdaemon_noise_dir}'"
            fi
        done
        ### We have uploaded all the spot and noise files
 
        sleep ${WAV_FILE_POLL_SECONDS}
    done
    [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() has stopped"
}

### Called by the posting_daemon() to create a spot file which will be uploaded to wsprdaemon.org
###
### Takes the spot file created by 'wsprd' which has 10 or 11 fields and creates a fixed field length  enhanced spot file with tx and rx azi vectors added
###  The lines in wspr_spots.txt output by wsprd will not contain a GRID field for type 2 reports
###  Date  Time SyncQuality   SNR    DT  Freq  CALL   GRID  PWR   Drift  DecodeCycles  Jitter  Blocksize  Metric  OSD_Decode)
###  [0]    [1]      [2]      [3]   [4]   [5]   [6]  -/[7]  [7/8] [8/9]   [9/10]      [10/11]   [11/12]   [12/13   [13:14]   )]
### The input spot lines also have two fields added by WD:  ', RMS_NOISE C2_NOISE
declare  FIELD_COUNT_DECODE_LINE_WITH_GRID=20                                              ### wspd v2.2 adds two fields and we have added the 'upload to wsprnet.org' field, so lines with a GRID will have 17 + 1 + 2 noise level fields
declare  FIELD_COUNT_DECODE_LINE_WITHOUT_GRID=$((FIELD_COUNT_DECODE_LINE_WITH_GRID - 1))   ### Lines without a GRID will have one fewer field

function create_enhanced_spots_file() {
    local real_receiver_wspr_spots_file=$1
    local real_receiver_enhanced_wspr_spots_file=$2
    local my_grid=$3

    wd_logger 2 "Enhance ${real_receiver_wspr_spots_file} into ${real_receiver_enhanced_wspr_spots_file} at ${my_grid}"
    rm -f ${real_receiver_enhanced_wspr_spots_file}
    touch ${real_receiver_enhanced_wspr_spots_file}
    local spot_line
    while read spot_line ; do
        wd_logger 3 "Enhance line '${spot_line}'"
        local spot_line_list=(${spot_line/,/})         
        local spot_line_list_count=${#spot_line_list[@]}
        local spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call other_fields                                                                                             ### the order of the first fields in the spot lines created by decoding_daemon()
        read  spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call other_fields <<< "${spot_line/,/}"
        local    spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_for_wsprnet spot_rms_noise spot_c2_noise   ### the order of the rest of the fields in the spot lines created by decoding_daemon()
        if [[ ${spot_line_list_count} -eq ${FIELD_COUNT_DECODE_LINE_WITH_GRID} ]]; then
            read spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_for_wsprnet spot_rms_noise spot_c2_noise <<< "${other_fields}"    ### Most spot lines have a GRID
        elif [[ ${spot_line_list_count} -eq ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
            spot_grid="none"
            read           spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_for_wsprnet spot_rms_noise spot_c2_noise <<< "${other_fields}"    ### Type 2 spots have no grid
        else
            ### The decoding daemon formated a line we don't recognize
            wd_logger 1 "INTERNAL ERROR: unexpected number of fields ${spot_line_list_count} rather than the expected ${FIELD_COUNT_DECODE_LINE_WITH_GRID} or ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} in wsprnet format spot line '${spot_line}'" 
            return 1
        fi
        ### G3ZIL 
        ### April 2020 V1    add azi
        wd_logger 1 "'add_derived ${spot_grid} ${my_grid} ${spot_freq}'"
        add_derived ${spot_grid} ${my_grid} ${spot_freq}
        if [[ ! -f ${DERIVED_ADDED_FILE} ]] ; then
            wd_logger 1 "spots.txt ${DERIVED_ADDED_FILE} file not found"
            return 1
        fi
        local derived_fields=$(cat ${DERIVED_ADDED_FILE} | tr -d '\r')
        derived_fields=${derived_fields//,/ }   ### Strip out the ,s
        wd_logger 3 "derived_fields='${derived_fields}'"

        local band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon
        read band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${derived_fields}"

        ### Output a space-seperated line of enhanced spot data.  The first 13/14 fields are in the same order as in the ALL_WSPR.TXT and wspr_spot.txt files created by 'wsprd'
        echo "${spot_date} ${spot_time} ${spot_sync_quality} ${spot_snr} ${spot_dt} ${spot_freq} ${spot_call} ${spot_grid} ${spot_pwr} ${spot_drift} ${spot_decode_cycles} ${spot_jitter} ${spot_blocksize} ${spot_metric} ${spot_osd_decode} ${spot_ipass} ${spot_nhardmin} ${spot_for_wsprnet} ${spot_rms_noise} ${spot_c2_noise} ${band} ${my_grid} ${my_call_sign} ${km} ${rx_az} ${rx_lat} ${rx_lon} ${tx_az} ${tx_lat} ${tx_lon} ${v_lat} ${v_lon}" >> ${real_receiver_enhanced_wspr_spots_file}

    done < ${real_receiver_wspr_spots_file}
    wd_logger 2 "Created '${real_receiver_enhanced_wspr_spots_file}':\n'$(cat ${real_receiver_enhanced_wspr_spots_file})'\n========\n"
}

################### wsprdaemon uploads ####################################
### add tx and rx lat, lon, azimuths, distance and path vertex using python script. 
### In the main program, call this function with a file path/name for the input file, the tx_locator, the rx_locator and the frequency
### The appended data gets stored into ${DERIVED_ADDED_FILE} which can be examined. Overwritten each acquisition cycle.
declare DERIVED_ADDED_FILE=derived_azi.csv
declare AZI_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/derived_calc.py

function add_derived() {
    local spot_grid=$1
    local my_grid=$2
    local spot_freq=$3    

    if [[ ! -f ${AZI_PYTHON_CMD} ]]; then
        wd_logger 0 "Can't find '${AZI_PYTHON_CMD}'"
        exit 1
    fi
    python3 ${AZI_PYTHON_CMD} ${spot_grid} ${my_grid} ${spot_freq} 1>add_derived.txt 2> add_derived.log
}

### WARNING: diag printouts would go into merged.logs file
function log_merged_snrs() {
    local source_file_count=${#newest_list[@]}
    local source_line_count=$(cat ${wsprd_spots_all_file_path} | wc -l)
    local sorted_line_count=$(cat ${wsprd_spots_best_file_path} | wc -l)
    local sorted_call_list=( $(awk '{print $7}' ${wsprd_spots_best_file_path}) )   ## this list will be sorted by frequency
    local sorted_call_list_count=${#sorted_call_list[@]}

    if [[ ${sorted_call_list_count} -eq 0 ]] ;then
        ## There are no spots recorded in this wspr cycle, so don't log
        return
    fi
    local date_string="$(date)"

    
    printf "$date_string: %10s %8s %10s" "FREQUENCY" "CALL" "POSTED_SNR"
    local receiver
    for receiver in ${real_receiver_list[@]}; do
        printf "%8s" ${receiver}
    done
    printf "       TOTAL=%2s, POSTED=%2s\n" ${source_line_count} ${sorted_line_count}
    local call
    for call in ${sorted_call_list[@]}; do
        local posted_freq=$(${GREP_CMD} " $call " ${wsprd_spots_best_file_path} | awk '{print $6}')
        local posted_snr=$( ${GREP_CMD} " $call " ${wsprd_spots_best_file_path} | awk '{print $4}')
        printf "$date_string: %10s %8s %10s" $posted_freq $call $posted_snr
        local file
        for file in ${newest_list[@]}; do
            ### Only pick the strongest SNR from each file which went into the .BEST file
            local rx_snr=$(${GREP_CMD} -F " $call " $file | sort -k 4,4n | tail -n 1 | awk '{print $4}')
            if [[ -z "$rx_snr" ]]; then
                printf "%8s" "*"
            elif [[ $rx_snr == $posted_snr ]]; then
                printf "%7s%1s" $rx_snr "p"
            else
                printf "%7s%1s" $rx_snr " "
            fi
        done
        printf "\n"
    done
}
 
###
function spawn_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2

    local daemon_status
    
    if daemon_status=$(get_posting_status $receiver_name $receiver_band) ; then
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_posting_daemon(): daemon for '${receiver_name}','${receiver_band}' is already running"
        return
    fi
    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
    local real_receiver_list=""

    if [[ "${receiver_name}" =~ ^MERG ]]; then
        ### This is a 'merged == virtual' receiver.  The 'real rx' which are merged to create this rx are listed in the IP address field of the config line
        real_receiver_list="${receiver_address//,/ }"
        [[ $verbosity -ge 3 ]] && echo "$(date): spawn_posting_daemon(): creating merged rx '${receiver_name}' which includes real rx(s) '${receiver_address}' => list '${real_receiver_list[@]}'"  
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): spawn_posting_daemon(): creating real rx '${receiver_name}','${receiver_band}'"  
        real_receiver_list=${receiver_name} 
    fi
    local receiver_posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    mkdir -p ${receiver_posting_dir}
    cd ${receiver_posting_dir}
    WD_LOG_FILE=posting_daemon.log posting_daemon ${receiver_name} ${receiver_band} "${real_receiver_list}" &
    local posting_pid=$!
    echo ${posting_pid} > posting.pid

    [[ $verbosity -ge 3 ]] && echo "$(date): spawn_posting_daemon(): spawned posting daemon in '$PWD' with pid ${posting_pid}"
    cd - > /dev/null
}

###
function kill_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    local real_receiver_list=()
    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})

    if [[ -z "${receiver_address}" ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): ERROR: no address(s) found for ${receiver_name}"
        return 1
    fi
    local posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    if [[ ! -d "${posting_dir}" ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): ERROR: can't find expected posting daemon dir ${posting_dir}"
        return 2
    else
        local posting_daemon_pid_file=${posting_dir}/posting.pid
        if [[ ! -f ${posting_daemon_pid_file} ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): ERROR: can't find expected posting daemon file ${posting_daemon_pid_file}"
            return 3
        else
            local posting_pid=$(cat ${posting_daemon_pid_file})
            if ps ${posting_pid} > /dev/null ; then
                kill ${posting_pid}
              [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): killed active pid ${posting_pid} and deleting '${posting_daemon_pid_file}'"
            else
                [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): pid ${posting_pid} was dead.  Deleting '${posting_daemon_pid_file}' it came from"
            fi
            rm -f ${posting_daemon_pid_file}
        fi
    fi

    if [[ "${receiver_name}" =~ ^MERG ]]; then
        ### This is a 'merged == virtual' receiver.  The 'real rx' which are merged to create this rx are listed in the IP address field of the config line
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): INFO: stopping merged rx '${receiver_name}' which includes real rx(s) '${receiver_address}'"  
        real_receiver_list=(${receiver_address//,/ })
    else
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): INFO: stopping real rx '${receiver_name}','${receiver_band}'"  
        real_receiver_list=(${receiver_name})
    fi

    if [[ -z "${real_receiver_list[@]}" ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): ERROR: can't find expected real receiver(s) for '${receiver_name}','${receiver_band}'"
        return 3
    fi
    ### Signal all of the real receivers which are contributing ALL_WSPR files to this posting daemon to stop sending ALL_WSPRs by deleting the 
    ### associated subdir in the real receiver's posting.d subdir
    ### That real_receiver_posting_dir is in the /tmp/ tree and is a symbolic link to the real ~/wsprdaemon/.../real_receiver_posting_dir
    ### Leave ~/wsprdaemon/.../real_receiver_posting_dir alone so it retains any spot data for later uploads
    local posting_suppliers_root_dir=${posting_dir}/${POSTING_SUPPLIERS_SUBDIR}
    local real_receiver_name
    for real_receiver_name in ${real_receiver_list[@]} ; do
        local real_receiver_posting_dir=$(get_recording_dir_path ${real_receiver_name} ${receiver_band})/${DECODING_CLIENTS_SUBDIR}/${receiver_name}
        [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(): INFO: signaling real receiver ${real_receiver_name} to stop posting to ${real_receiver_posting_dir}"
        if [[ ! -d ${real_receiver_posting_dir} ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(${receiver_name},${receiver_band}) WARNING: posting directory  ${real_receiver_posting_dir} does not exist"
        else 
            rm -f ${posting_suppliers_root_dir}/${real_receiver_name}     ## Remote the posting daemon's link to the source of spots
            rm -rf ${real_receiver_posting_dir}  ### Remove the directory under the recording deamon where it puts spot files for this decoding daemon to process
            local real_receiver_posting_root_dir=${real_receiver_posting_dir%/*}
            local real_receiver_posting_root_dir_count=$(ls -d ${real_receiver_posting_root_dir}/*/ 2> /dev/null | wc -w)
            if [[ ${real_receiver_posting_root_dir_count} -eq 0 ]]; then
                local real_receiver_stop_file=${real_receiver_posting_root_dir%/*}/recording.stop
                touch ${real_receiver_stop_file}
                [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(${receiver_name},${receiver_band}) by creating ${real_receiver_stop_file}"
            else
                [[ $verbosity -ge 2 ]] && echo "$(date): kill_posting_daemon(${receiver_name},${receiver_band}) a decoding client remains, so didn't signal the recoding and decoding daemons to stop"
            fi
        fi
    done
    ### decoding_daemon() will terminate themselves if this posting_daemon is the last to be a client for wspr_spots.txt files
}

###
function get_posting_status() {
    local get_posting_status_receiver_name=$1
    local get_posting_status_receiver_rx_band=$2
    local get_posting_status_receiver_posting_dir=$(get_posting_dir_path ${get_posting_status_receiver_name} ${get_posting_status_receiver_rx_band})
    local get_posting_status_receiver_posting_pid_file=${get_posting_status_receiver_posting_dir}/posting.pid

    if [[ ! -d ${get_posting_status_receiver_posting_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_posting_status_receiver_posting_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_posting_status_decode_pid=$(cat ${get_posting_status_receiver_posting_pid_file})
    if ! ps ${get_posting_status_decode_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid '${get_posting_status_decode_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_posting_status_decode_pid}"
    return 0
}

##########################################################################################################################################################
########## Section which manaages creating and later/remote uploading of the spot and noise level caches ##################################################
##########################################################################################################################################################

### We cache spots and noise data under ~/wsprdaemon/.. Three upload daemons run at second 110:
### 1)  Upload spots to wsprnet.org using the curl MEPT bulk transfer metho
### 2)  Upload those same spots to logs.wsprdaemon.org using 'curl ...'
### 3)  Upload noise level data to logs.wsprdaemon.org using 'curl ...'

###### uploading to wsprnet.org
### By consolidating spots for all bands of each CALL/GRID into one curl MEPT upload, we dramtically increase the effeciency of the upload for 
### both the Pi and wsprnet.org while also ensuring that when we view the wsprnet.org database sorted by CALL and TIME, the spots for
### each 2 minute cycle are displayed in ascending or decending frequency order.
### To achieve that:
### Wait for all of the CALL/GRID/BAND jobs in a two minute cycle to complete, 
###    then cat all of the wspr_spot.txt files together and sorting them into a single file in time->freq order
### The posting daemons put the wspr_spots.txt files in ${UPLOADS_WSPRNET_ROOT_DIR}/CALL/..
### There is a potential problem in the way I've implemented this algorithm:
###   If all of the wsprds don't complete their decdoing in the 2 minute WSPR cycle, then those tardy band results will be delayed until the following upload
###   I haven't seen that problem and if it occurs the only side effect is that a time sorted display of the wsprnet.org database may have bands that don't
###   print out in ascending frequency order for that 2 minute cycle.  Avoiding that unlikely and in any case lossless event would require a lot more logic
###   in the upload_to_wsprnet_daemon() and I would rather work on VHF/UHF support

declare uploading_status="enabled"    ### For testing.  If not "enabled", the the uploading daemons will not attempt 'curl...' and leave signals and noise in local cache
declare uploading_last_record_time=0 

### We save those variables in the ~/wsprdaemon/wspdaemon.status file where they can be accessed by NN_the uploaading_daemons
declare UPLOADING_CONTROL_FILE=${WSPRDAEMON_CONFIG_FILE/.conf/.status}
if [[ ! -f ${UPLOADING_CONTROL_FILE} ]] ; then
    cat > ${UPLOADING_CONTROL_FILE} <<EOF
declare uploading_status="enabled"
declare uploading_last_record_time=0
EOF
fi

function uploading_status() {
    source ${UPLOADING_CONTROL_FILE}
    echo "Spot and noise level uploading is ${uploading_status}"
    echo "Last cache record time ${uploading_last_record_time}"
}
function uploading_status_change() {
    local var_val=$1
    local var=${var_val%=*}
    local val=${var_val#*=}
    local cur_file="$(cat ${UPLOADING_CONTROL_FILE})"
    local new_file=$(sed "/${var}=/s/=.*/=${val}/" <<< ${cur_file})
    echo "${new_file}" > ${UPLOADING_CONTROL_FILE}.tmp
    mv ${UPLOADING_CONTROL_FILE}.tmp ${UPLOADING_CONTROL_FILE}
}

### implements '-u ...' cmd
function uploading_controls(){
    local cmd=$1
    case ${cmd} in
        z)
            uploading_status_change 'uploading_status="disabled"'
            uploading_status
            ;;
        a)
            uploading_status_change 'uploading_status="enabled"'
            uploading_status
            ;;
        r)
            uploading_record_cache
            ;;
        f)
            uploading_flush_cache
            ;;
        u)
            uploading_upload_cache
            ;;
        s)
            uploading_status
            ;;
        *)
            uploading_status
            ;;
    esac
}

### The spot and noise data is saved in permanent file systems, while temp files are not saved 
declare UPLOADS_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/uploads.d           ### Put under here all the spot, noise and log files here so they will persist through a reboot/power cycle
declare UPLOADS_TMP_ROOT_DIR=${WSPRDAEMON_TMP_DIR}/uploads.d        ### Put under here all files which can or should be flushed when the system is started

declare UPLOADS_WSPRDAEMON_ROOT_DIR=${UPLOADS_ROOT_DIR}/wsprdaemon.d
declare UPLOADS_TMP_WSPRDAEMON_ROOT_DIR=${UPLOADS_TMP_ROOT_DIR}/wsprdaemon.d

### spots.logs.wsprdaemon.org
declare UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}/spots.d
declare UPLOADS_WSPRDAEMON_SPOTS_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_SPOTS_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/uploads.pid

declare UPLOADS_TMP_WSPRDAEMON_SPOTS_ROOT_DIR=${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}/spots.d

### noise.logs.wsprdaemon.org
declare UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}/noise.d
declare UPLOADS_WSPRDAEMON_NOISE_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/uploads.pid

declare UPLOADS_TMP_WSPRDAEMON_NOISE_ROOT_DIR=${UPLOADS_TMP_WSPRDAEMON_ROOT_DIR}/noise.d

### wsprnet.org upload daemon files
declare UPLOADS_TMP_WSPRNET_ROOT_DIR=${UPLOADS_TMP_ROOT_DIR}/wsprnet.d
mkdir -p ${UPLOADS_TMP_WSPRNET_ROOT_DIR}
declare UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/wspr_spots.txt
declare UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/curl.log
declare UPLOADS_TMP_WSPRNET_SUCCESSFUL_LOGFILE=${UPLOADS_TMP_WSPRNET_ROOT_DIR}/successful_spot_uploads.log

### wsprnet.org 
declare UPLOADS_WSPRNET_ROOT_DIR=${UPLOADS_ROOT_DIR}/wsprnet.d      
declare UPLOADS_WSPRNET_SPOTS_DIR=${UPLOADS_WSPRNET_ROOT_DIR}/spots.d
declare UPLOADS_WSPRNET_PIDFILE_PATH=${UPLOADS_WSPRNET_SPOTS_DIR}/uploads.pid
declare UPLOADS_WSPRNET_LOGFILE_PATH=${UPLOADS_WSPRNET_SPOTS_DIR}/uploads.log
declare UPLOADS_WSPRNET_SUCCESSFUL_LOGFILE=${UPLOADS_WSPRNET_SPOTS_DIR}/successful_spot_uploads.log

declare UPLOADS_MAX_LOG_LINES=100000    ### LImit our local spot log file size

### The curl POST call requires the band center of the spot being uploaded, but the default is now to use curl MEPT, so this code isn't normally executed
declare MAX_SPOT_DIFFERENCE_IN_MHZ_FROM_BAND_CENTER="0.000200"  ### WSPR bands are 200z wide, but we accept wsprd spots which are + or - 200 Hz of the band center

### This is an ugly and slow way to find the band center of spots.  To speed execution, put the bands with the most spots at the top of the list.
declare WSPR_BAND_CENTERS_IN_MHZ=(
       7.040100
      14.097100
      10.140200
       3.570100
       3.594100
       0.475700
       0.137500
       1.838100
       5.288700
       5.366200
      18.106100
      21.096100
      24.926100
      28.126100
      50.294500
      70.092500
     144.490500
     432.301500
    1296.501500
       0.060000
       2.500000
       5.000000
      10.000000
      15.000000
      20.000000
      25.000000
       3.330000
       7.850000
      14.670000
)

function band_center_mhz_from_spot_freq()
{
    local spot_freq=$1
    local band_center_freq
    for band_center_freq in ${WSPR_BAND_CENTERS_IN_MHZ[@]}; do
        if [[ $(bc <<< "define abs(x) {if (x<0) {return -x}; return x;}; abs(${band_center_freq} - ${spot_freq}) < ${MAX_SPOT_DIFFERENCE_IN_MHZ_FROM_BAND_CENTER}") == "1" ]]; then
            echo ${band_center_freq}
            return
        fi
    done
    echo "ERROR"
}

############
declare MAX_UPLOAD_SPOTS_COUNT=${MAX_UPLOAD_SPOTS_COUNT-999}           ### Limit of number of spots to upload in one curl MEPT upload transaction
declare UPLOAD_SPOT_FILE_LIST_FILE=${UPLOADS_WSPRNET_ROOT_DIR}/upload_spot_file_list.txt

### Creates a file containing a list of all the spot files to be the sources of spots in the next MEPT upload
function upload_wsprnet_create_spot_file_list_file()
{
    local wspr_spots_files="$@"         ### i.e. a list of spot files in the format:  /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI/BAND/YYMMDD_HHMM_BAND_wspr_spots.txt
    [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() starting with list '${wspr_spots_files}'"

    local wspr_spots_files_count=$(wc -w <<< "${wspr_spots_files}")
    local wspr_spots_count=$(cat ${wspr_spots_files} | wc -l )
    local wspr_spots_root_path=$(echo "${wspr_spots_files}" | tr ' ' '\n' | head -1)  ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI/BAND/YYMMDD_HHMM_FREQ_wspr_spots.txt
          wspr_spots_root_path=${wspr_spots_root_path%/*}      ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI/BAND
          wspr_spots_root_path=${wspr_spots_root_path%/*}      ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/KIWI
          wspr_spots_root_path=${wspr_spots_root_path%/*}      ### Get /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID
    local cycles_list=$(echo "${wspr_spots_files}" | tr ' ' '\n' | sed 's;.*/;;' | cut -c 1-11 | sort -u )
    local cycles_count=$(echo "${cycles_list}" | wc -l)
    [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() under '${wspr_spots_root_path}' found ${wspr_spots_count} spots in ${wspr_spots_files_count} files from ${cycles_count} wspr cycles"

    local spots_file_list=""
    local spots_file_list_count=0
    local file_spots=""
    local file_spots_count=0
    for cycle in ${cycles_list} ; do
        local cycle_root_name="${wspr_spots_root_path}/*/*/${cycle}"  ### e.g.: /home/pi/wsprdaemon/uploads.d/wsprnet.d/wspr_spots.d/CALL_GRID/*/*/YYMMDD_HHMM
        [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() checking for spots in cycle ${cycle} using pattern ${cycle_root_name}"

        local cycle_files=$( ls -1  ${cycle_root_name}_* | sort -u )        ### globbing double expanding some of the files.  This hack supresses that. Probably was due to bug in creating $wspr_spots_root_path
        [[ $verbosity -ge 3 ]] && printf "$(date): upload_wsprnet_create_spot_file_list_file() checking for number of spots in \n%s\n" "${cycle_files}"

        local cycle_spots_count=$(cat ${cycle_files} | wc -l)
        [[ $verbosity -ge 3 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found ${cycle_spots_count} spots in cycle ${cycle}"

        local new_count=$(( ${spots_file_list_count} + ${cycle_spots_count} ))
        if [[ ${cycle_spots_count} -eq 0 ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found the complete set of files in cycle ${cycle_root_name} contain no spots.  So flush those files"
            rm ${cycle_files}
        else
            if [[ ${new_count} -gt ${MAX_UPLOAD_SPOTS_COUNT} ]]; then
                [[ $verbosity -ge 2 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found that adding the ${cycle_spots_count} spots in cycle ${cycle} will exceed the max ${MAX_UPLOAD_SPOTS_COUNT} spots for an MEPT upload, so upload list is complete"
                echo "${spots_file_list}" > ${UPLOAD_SPOT_FILE_LIST_FILE}
                return
            fi
            spots_file_list=$(echo -e "${spots_file_list}\n${cycle_files}")
            spots_file_list_count=$(( ${spots_file_list_count} + ${cycle_spots_count}))
       fi
   done
   [[ $verbosity -ge 2 ]] && echo "$(date): upload_wsprnet_create_spot_file_list_file() found that all of the ${spots_file_list_count} spots in the current spot files can be uploaded"
   echo "${spots_file_list}" > ${UPLOAD_SPOT_FILE_LIST_FILE}
}

function get_call_grid_from_receiver_name() {
    local target_rx=$1

    local rx_entry
    for rx_entry in "${RECEIVER_LIST[@]}" ; do
        local rx_entry_list=( ${rx_entry} )
        local rx_entry_rx_name=${rx_entry_list[0]}
        if [[ "${rx_entry_rx_name}" == "${target_rx}" ]]; then
            echo "${rx_entry_list[2]}_${rx_entry_list[3]}"
            return 0
        fi
    done
    echo ""
    return 1
}

function get_wsprnet_uploading_job_dir_path(){
    local job=$1
    local job_list=(${job/,/ })
    local receiver_name=${job_list[0]}
    local receiver_rx_band=${job_list[1]}
    local call_grid=$(get_call_grid_from_receiver_name ${receiver_name})
    local call=${call_grid%_*}
    if [[ -z "${call}" ]]; then
        [[ ${verbosity} -ge 0 ]] && echo "$(date): ERROR: can't find call for running job '${job}'"
        exit 1
    fi
    local grid=${call_grid#*_}
    if [[ -z "${call_grid}" ]]; then
        [[ ${verbosity} -ge 0 ]] && echo "$(date): ERROR: can't find grid for running job '${job}'"
        exit 1
    fi
    local call_dir_name=${call/\//=}_${grid}
    local receiver_posting_path="${UPLOADS_WSPRNET_SPOTS_DIR}/${call_dir_name}/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_posting_path}
}


function upload_to_wsprnet_daemon()
{
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    mkdir -p ${UPLOADS_WSPRNET_SPOTS_DIR}
    shopt -s nullglob    ### * expands to NULL if there are no file matches
    while true; do
        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() checking for spot files to upload in all running jobs directories"
        local all_call_grid_list=()
        source ${RUNNING_JOBS_FILE}
        local job
        for job in ${RUNNING_JOBS[@]} ; do
            [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprnet_daemon() check to see if job ${job} should be added to \$all_call_grid_list[@]"
            local call_grid=$( get_call_grid_from_receiver_name ${job%,*} )
            if [[ ! ${all_call_grid_list[@]} =~ ${call_grid} ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() adding '${call_grid}' to list of CALL_GRIDs to be searched for spot files to upload"
                all_call_grid_list+=(${call_grid})
            else 
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprnet_daemon() call_grid '${call_grid}' is already in \$all_call_grid_list+[@]"
            fi
        done
        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found ${#all_call_grid_list[@]} CALL_GRIDS to search for uploads: '${all_call_grid_list[@]}'"

        for call_grid in ${all_call_grid_list[@]} ; do
            local call=${call_grid%_*}
            local grid=${call_grid#*_}

            ### Get a list of all bands which are reported with this CALL_GRID.  Frequently bands are on differnet Kiwis
            local call_grid_job_list=()
            local call_grid_band_list=()
            for job in ${RUNNING_JOBS[@]} ; do
                local job_rx=${job%,*}
                local job_band=${job#*,}
                local job_call_grid=$( get_call_grid_from_receiver_name ${job_rx} )
                local job_call=${job_call_grid%_*}
                local job_grid=${job_call_grid#*_}
                if [[ ${job_call} == ${call} ]] && [[ ${job_grid} == ${grid} ]]; then
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() adding band '${job_band}' to list for call ${call} grid ${grid}"
                    call_grid_band_list+=( ${job_band} )
                    call_grid_job_list+=( ${job} )
                else
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() job '${job}' is not uploaded with call ${call} grid ${grid}"
                fi
            done
            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() '${call_grid}' reports on bands '${call_grid_band_list[@]}' from jobs '${call_grid_job_list[@]}'"

            ### Check to see that spot files are present for all bands for this CALL_GRID before uploading.  This results in time and frequency ordered printouts from wsprnet.org 
            local all_spots_file_list=()
            local missing_job_spots="no"
            for job in ${call_grid_job_list[@]} ; do
                local call_grid_rx_band_path=$( get_wsprnet_uploading_job_dir_path ${job} )
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() checking running job '${job}' spot directory ${call_grid_rx_band_path}"
                local job_spot_file_list=(${call_grid_rx_band_path}/*.txt)
                if [[ ${#job_spot_file_list[@]} -eq 0 ]]; then
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found no spot files in ${call_grid_rx_band_path}"
                    missing_job_spots="yes"
                else
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found ${#job_spot_file_list[@]} spot files in ${call_grid_rx_band_path}"
                    all_spots_file_list+=( ${job_spot_file_list[@]} )
                fi
            done

            if [[ ${missing_job_spots} == "yes" ]]; then
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprnet_daemon() found some job dirs have no spots, so wait for all job dirs to have at least one spot file"
            else
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() found ${#all_spots_file_list[@]} spot files in '\${all_spots_file_list}'.  Create file with at most ${MAX_UPLOAD_SPOTS_COUNT} spots for upload"
                upload_wsprnet_create_spot_file_list_file ${all_spots_file_list[@]}
                local wspr_spots_files=( $(cat ${UPLOAD_SPOT_FILE_LIST_FILE})  )
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() uploading spots from ${#wspr_spots_files[@]} files"

                ### sort ascending by fields of wspr_spots.txt: YYMMDD HHMM .. FREQ
                cat ${wspr_spots_files[@]} | sort -k 1,1 -k 2,2 -k 6,6n > ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE}
                local    spots_to_xfer=$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} | wc -l)
                if [[ ${spots_to_xfer} -eq 0 ]] || [[ ${SIGNAL_LEVEL_UPLOAD-no} == "proxy" ]]; then
                    if [[ ${spots_to_xfer} -eq 0 ]] ; then
                        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() no spots to upload in the ${#wspr_spots_files[@]} spot files.  Purging '${wspr_spots_files[@]}'"
                    else
                        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() in proxy upload mode, so don't upload to wsprnet.org.  Purging '${wspr_spots_files[@]}'"
                    fi
                    rm -f ${all_spots_file_list[@]}
                else
                    ### Upload all the spots for one CALL_GRID in one curl transaction 
                    [[ ${verbosity} -ge 1 ]] && printf "$(date): upload_to_wsprnet_daemon() uploading ${call}_${grid} spots file ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} with $(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} | wc -l) spots in it.\n"
                    [[ ${verbosity} -ge 3 ]] && printf "$(date): upload_to_wsprnet_daemon() uploading spot file ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE}:\n$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE})\n"
                    curl -m ${UPLOADS_WSPNET_CURL_TIMEOUT-300} -F allmept=@${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE} -F call=${call} -F grid=${grid} http://wsprnet.org/meptspots.php > ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH} 2>&1
                    local ret_code=$?
                    if [[ $ret_code -ne 0 ]]; then
                        [[ ${verbosity} -ge 2 ]] && echo -e "$(date): upload_to_wsprnet_daemon() curl returned error code => ${ret_code} and logged:\n$( cat ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})\nSo leave spot files for next loop iteration"
                    else
                        local spot_xfer_counts=( $(awk '/spot.* added/{print $1 " " $4}' ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH} ) )
                        if [[ ${#spot_xfer_counts[@]} -ne 2 ]]; then
                            [[ ${verbosity} -ge 2 ]] && echo -e "$(date): upload_to_wsprnet_daemon() couldn't extract 'spots added' from the end of the server's response:\n$( tail -n 2 ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})So presume no spots were recorded and the our spots queued for the next upload attempt."
                            [[ ${verbosity} -ge 2 ]] && echo -e "$(date): upload_to_wsprnet_daemon() couldn't extract 'spots added' into '${spot_xfer_counts[@]}' from curl log, so presume no spots were recorded and try again:\n$( cat ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})\n"
                        else
                            local spots_xfered=${spot_xfer_counts[0]}
                            local spots_offered=${spot_xfer_counts[1]}
                            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() wsprnet reported ${spots_xfered} of the ${spots_offered} offered spots were added"
                            if [[ ${spots_offered} -ne ${spots_to_xfer} ]]; then
                                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprnet_daemon() UNEXPECTED ERROR: spots offered '${spots_offered}' reported by curl doesn't match the number of spots in our upload file '${spots_to_xfer}'"
                            fi
                            local curl_msecs=$(awk '/milliseconds/{print $3}' ${UPLOADS_TMP_WSPRNET_CURL_LOGFILE_PATH})
                            if [[ ${spots_xfered} -eq 0 ]]; then
                                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() the curl upload was successful in ${curl_msecs} msecs, but 0 spots were added. Don't try them again"
                            else
                                ## wsprnet responded with a message which includes the number of spots we are attempting to transfer,  
                                ### Assume we are done attempting to transfer those spots
                                [[ ${verbosity} -ge 1 ]] && printf "$(date): upload_to_wsprnet_daemon() successful curl upload has completed. ${spots_xfered} of these offered ${spots_offered} spots were accepted by wsprnet.org:\n$(cat ${UPLOADS_TMP_WSPRNET_SPOTS_TXT_FILE})\n"
                            fi
                            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() flushing spot files '${all_spots_file_list[@]}'"
                            rm -f ${all_spots_file_list[@]}
                        fi
                    fi
                fi
            fi
        done
        ### Pole every 10 seconds for a complete set of wspr_spots.txt files
        local sleep_secs=10
        [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprnet_daemon() sleeping for ${sleep_secs} seconds"
        sleep ${sleep_secs}
    done
}

function spawn_upload_to_wsprnet_daemon()
{
    local uploading_pid_file_path=${UPLOADS_WSPRNET_PIDFILE_PATH}
    mkdir -p ${uploading_pid_file_path%/*}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_upload_to_wsprnet_daemon() INFO: uploading job with pid ${uploading_pid} is already running"
            return
        else
            echo "$(date): WARNING: spawn_upload_to_wsprnet_daemon() found a stale uploading.pid file with pid ${uploading_pid}. Deleting file ${uploading_pid_file_path}"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    mkdir -p ${UPLOADS_WSPRNET_LOGFILE_PATH%/*}
    upload_to_wsprnet_daemon > ${UPLOADS_WSPRNET_LOGFILE_PATH} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_to_wsprnet_daemon() Spawned new uploading job with PID '$!'"
}

function kill_upload_to_wsprnet_daemon()
{
    local uploading_pid_file_path=${UPLOADS_WSPRNET_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprnet_daemon() killing active upload_to_wsprnet_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_to_wsprnet_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprnet_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}

function upload_to_wsprnet_daemon_status()
{
    local uploading_pid_file_path=${UPLOADS_WSPRNET_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "The wsprnet.org    spots uploading daemon is running"
            else
                echo "$(date): upload_to_wsprnet_daemon_status() with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprnet Uploading daemon pid file records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): upload_to_wsprnet_daemon_status() found a stale uploading.pid file with pid ${uploading_pid}"
            fi
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "No wsprnet.org upload daemon is running"
        else
            echo "$(date): upload_to_wsprnet_daemon_status() found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

declare TS_HOSTNAME=logs.wsprdaemon.org
declare TS_IP_ADDRESS=$(host ${TS_HOSTNAME})
if [[ $? -eq 0 ]]; then
    TS_IP_ADDRESS=$(awk '{print $NF}' <<< "${TS_IP_ADDRESS}")
    declare MY_IP_ADDRESS=$(ifconfig eth0 2> /dev/null | awk '/inet[^6]/{print $2}')
    if [[ -n "${MY_IP_ADDRESS}" ]] && [[ "${MY_IP_ADDRESS}" == "${TS_IP_ADDRESS}" ]]  || [[ -z "${MY_IP_ADDRESS}" ]]; then
        TS_HOSTNAME=localhost
    fi
fi

function upload_line_to_wsprdaemon() {
    local file_path=$1
    local file_type=${file_path##*_wspr_}
    local file_line="${2/,/ }"   ## (probably no longer needed) Remove the ',' from an enhanced spot report line

    local ts_server_url="${TS_HOSTNAME}"

    [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() upload file '${file_path}' containing line '${file_line}'"
    local line_array=(${file_line})
    local path_array=( ${file_path//\// } ) 
    local path_array_count=${#path_array[@]}
    local my_receiver_index=$(( ${path_array_count} - 3 ))
    local my_receiver=${path_array[${my_receiver_index}]}
    local path_call_grid_index=$(( ${path_array_count} - 4 ))
    local call_grid=( ${path_array[${path_call_grid_index}]/_/ } )
    local my_call_sign=${call_grid[0]/=//}
    local my_grid=${call_grid[1]}
    local file_name=${file_path##*/}
    local file_name_elements=( ${file_name//_/ } )

    case ${file_type} in
        spots.txt)
            ### in the field  order of the extended spot lines version 2 which include the wsprd v2.2 additional 2 decode values and the 'spot_for_wsprnet' signal from the client that this server should recreate a wsprnet.org spot and queue it for uploading 
            local spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_rms_noise spot_c2_noise spot_for_wsprnet band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon
            if [[ ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} -eq 1 ]]; then
                ### These fields are not present in version 1 spot files
                spot_ipass=0
                spot_nhardmin=0
                spot_for_wsprnet=0
                read  spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode                                          spot_rms_noise spot_c2_noise band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${file_line}"
            elif [[ ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} -eq 2 ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() processing VERSION = ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} extended spot line"
                read  spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_for_wsprnet spot_rms_noise spot_c2_noise band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${file_line}"
            else
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() INTERNAL ERROR: UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION = ${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION} is not supported"
                return 1
            fi
            local timestamp="${spot_date} ${spot_time}"
            local sql1='Insert into wsprdaemon_spots (time, band, rx_grid, rx_id, tx_call, tx_grid, "SNR", c2_noise, drift, freq, km, rx_az, rx_lat, rx_lon, tx_az, "tx_dBm", tx_lat, tx_lon, v_lat, v_lon, sync_quality, dt, decode_cycles, jitter, rms_noise, blocksize, metric, osd_decode, ipass, nhardmin, receiver) values '
            local sql2="('${timestamp}', '${band}', '${my_grid}', '${my_call_sign}', '${spot_call}', '${spot_grid}', ${spot_snr}, ${spot_c2_noise}, ${spot_drift}, ${spot_freq}, ${km}, ${rx_az}, ${rx_lat}, ${rx_lon}, ${tx_az}, ${spot_pwr}, ${tx_lat}, ${tx_lon}, ${v_lat}, ${v_lon}, ${spot_sync_quality}, ${spot_dt}, ${spot_decode_cycles}, ${spot_jitter}, ${spot_rms_noise}, ${spot_blocksize}, ${spot_metric}, ${spot_osd_decode}, ${spot_ipass}, ${spot_nhardmin}, '${my_receiver}' )"
            #echo "PGPASSWORD=Whisper2008 psql -U wdupload -d tutorial -h ${ts_server_url} -A -F, -c '${sql1} ${sql2}' &> add_derived_psql.txt"
            PGPASSWORD=Whisper2008 psql -U wdupload -d tutorial -h ${ts_server_url} -A -F, -c "${sql1} ${sql2}" &> add_derived_psql.txt

            ### If running on a server and the client signals the server to perform a proxy upload, synthesize a wsprnet.org spot line
            if [[ ${spot_for_wsprnet} -ne 0 ]]; then
                ### Don't upload rx members of a MERG* rx.  Those spot files were uploaded by the client in the tar file
                if [[ "${spot_grid}" == "none" ]]; then
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() WD spot line has no grid to add to wsprnet.org spot line"
                    spot_grid=""
                fi
                local wsprnet_spot_line="${spot_date} ${spot_time} ${spot_sync_quality} ${spot_snr} ${spot_dt} ${spot_freq} ${spot_call} ${spot_grid} ${spot_pwr} ${spot_drift} ${spot_decode_cycles} ${spot_jitter}"
                # echo "${wsprnet_spot_line}" >> ${UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH}
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() NOT YET IMPLENTED: client marked this spot '${wsprnet_spot_line}' for proxy upload to wsprnet.org byu copying it to ${UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH}"
            fi

            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon(): uploaded spot '$sql2'"  ### add c2
            if ! ${GREP_CMD} -q "INSERT" add_derived_psql.txt ; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() failed upload of spots file '${file_path}' containing line '${file_line}'. psql '${sql1} ${sql2}' returned '$(cat add_derived_psql.txt)'"
                 return 1
            fi
            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() uploaded spots file '${file_path}' containing line '${file_line}'"
            return 0
            ;;
       noise.txt)
            declare NOISE_LINE_EXPECTED_FIELD_COUNT=15     ## Each report line must include ( 3 * pre/sig/post ) + sox_fft + c2_fft + ov = 15 fields
            local line_field_count=${#line_array[@]}
            if [[ ${line_field_count} -lt ${NOISE_LINE_EXPECTED_FIELD_COUNT} ]]; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() tossing corrupt noise.txt line '${file_line}'in '${file_path}'"
                return  1
            fi
            local real_receiver_name_index=$(( ${path_array_count} - 3 ))
            local real_receiver_name=${path_array[${real_receiver_name_index}]}
            local real_receiver_maidenhead=${my_grid}
            local real_receiver_rx_band=$(get_wspr_band_name_from_freq_hz ${file_name_elements[2]})
            [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_line_to_wsprdaemon() noise freq '${file_name_elements[2]}'  => band '${real_receiver_rx_band}'"
            local sox_fft_value=${line_array[12]}
            local pre_rms_level=${line_array[3]}
            local post_rms_level=${line_array[11]}
            if [[ $(bc <<< "${post_rms_level} < ${pre_rms_level}") -eq 1 ]] ; then
                local rms_value=${post_rms_level}
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_line_to_wsprdaemon() choosing post_rms for rms_value=${post_rms_level}.  pre= ${pre_rms_level}"
            else
                local rms_value=${pre_rms_level}
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_line_to_wsprdaemon() choosing pre_rms for rms_value=${pre_rms_level}. post=${post_rms_level}"
            fi
            local c2_fft_value=${line_array[13]}
            local ov_value=${line_array[14]}
            ### Time comes from the filen2me 
            local time_year=20${file_name_elements[0]:0:2}
            local time_month=${file_name_elements[0]:2:2}
            local time_day=${file_name_elements[0]:4:2}
            local time_hour=${file_name_elements[1]:0:2}
            local time_minute=${file_name_elements[1]:2:2}
            local time_epoch=$(TZ=UTC date --date="${time_year}-${time_month}-${time_day} ${time_hour}:${time_minute}" +%s)
            local timestamp_ms=$(( ${time_epoch} * 1000))

            # G3ZIL added function to write to Timescale DB. And format the timestamp to suit Timescale DB.
            local datestamp_ts="${time_year}-${time_month}-${time_day}"
            local timestamp_ts="${time_hour}:${time_minute}"
            local time_ts="${datestamp_ts} ${timestamp_ts}:00+00"
            # 
            local sql1='Insert into wsprdaemon_noise (time,  site,receiver,  rx_grid, band, rms_level, c2_level, ov) values '
            local sql2="('${time_ts}', '${my_call_sign}', '${real_receiver_name}', '${real_receiver_maidenhead}', '${real_receiver_rx_band}', ${rms_value}, ${c2_fft_value}, ${ov_value} )"
            PGPASSWORD=Whisper2008 psql -U wdupload -d tutorial -h ${ts_server_url} -A -F, -c "${sql1}${sql2}" &> add_derived_psql.txt
            local py_retcode=$?
            if [[ ${py_retcode} -ne 0 ]]; then
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() upload of noise from ${real_receiver_name}/${real_receiver_rx_band}  failed"
                return ${py_retcode}
            fi
            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_line_to_wsprdaemon() upload of noise from ${real_receiver_name}/${real_receiver_rx_band} complete"
            return 0
            ;;
        *)
            [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_line_to_wsprdaemon() ERROR file_type '${file_type}' is invalid"
            return 2
            ;;
    esac
 }
 
### Polls for wspr_spots.txt or wspr_noise.txt files and uploads them to wsprdaemon.org 
function upload_to_wsprdaemon_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    local source_root_dir=$1

    mkdir -p ${source_root_dir}
    cd ${source_root_dir}
    while true; do
        [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() checking for files to upload under '${source_root_dir}/*/*'"
        shopt -s nullglob    ### * expands to NULL if there are no file matches
        local call_grid_path
        for call_grid_path in $(ls -d ${source_root_dir}/*/) ; do
            call_grid_path=${call_grid_path%/*}      ### Chop off the trailing '/'
            [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() checking for files under call_grid_path directory '${call_grid_path}'" 
            ### Spots from all recievers with the same call/grid are put into this one directory
            local call_grid=${call_grid_path##*/}
            call_grid=${call_grid/=/\/}         ### Restore the '/' in the reporter call sign
            local my_call_sign=${call_grid%_*}
            local my_grid=${call_grid#*_}
            shopt -s nullglob    ### * expands to NULL if there are no file matches
            unset all_upload_files
            local all_upload_files=( $(echo ${call_grid_path}/*/*/*.txt) )
            if [[ ${#all_upload_files[@]} -eq 0  ]] ; then
                [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() found no files to  upload under '${my_call_sign}_${my_grid}'"
            else
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() found upload files under '${my_call_sign}_${my_grid}': '${all_upload_files[@]}'"
                local upload_file
                for upload_file in ${all_upload_files[@]} ; do
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() starting to upload '${upload_file}"
                    local xfer_success=yes
                    local upload_line
                    while read upload_line; do
                        ### Parse the spots.txt or noise.txt line to determine the curl URL and arg`
                        [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() starting curl upload from '${upload_file}' of line ${upload_line}"
                        upload_line_to_wsprdaemon ${upload_file} "${upload_line}" 
                        local ret_code=$?
                        if [[ ${ret_code} -eq 0 ]]; then
                            [[ ${verbosity} -ge 2 ]] && echo "$(date): upload_to_wsprdaemon_daemon() upload_line_to_wsprdaemon()  eports successful upload of line '${upload_line}'"
                        else
                            [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() curl reports failed upload of line '${upload_line}'"
                            xfer_success=no
                        fi
                    done < ${upload_file}

                    if [[ ${xfer_success} == yes ]]; then
                        [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() sucessfully uploaded all the lines from '${upload_file}', delete the file"
                    else 
                        [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() failed to  upload all the lines from '${upload_file}', delete the file"
                    fi
                    rm ${upload_file}
                done ## for upload_file in ${all_upload_files[@]} ; do
                [[ ${verbosity} -ge 1 ]] && echo "$(date): upload_to_wsprdaemon_daemon() finished upload files under '${my_call_sign}_${my_grid}': '${all_upload_files[@]}'"
            fi  ### 
        done

        ### Sleep until 10 seconds before the end of the current two minute WSPR cycle by which time all of the previous cycle's spots will have been decoded
        local sleep_secs=5
        [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_to_wsprdaemon_daemon() sleeping for ${sleep_secs} seconds"
        sleep ${sleep_secs}
    done
}

function spawn_upload_to_wsprdaemon_daemon() {
    local uploading_root_dir=$1
    mkdir -p ${uploading_root_dir}
    local uploading_log_file_path=${uploading_root_dir}/uploads.log
    local uploading_pid_file_path=${uploading_root_dir}/uploads.pid  ### Must match UPLOADS_WSPRDAEMON_SPOTS_PIDFILE_PATH or UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH

    local uploading_tmp_root_dir=$2
    mkdir -p ${uploading_tmp_root_dir}

    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_upload_to_wsprdaemon_daemon() INFO: uploading job for '${uploading_root_dir}' with pid ${uploading_pid} is already running"
            return
        else
            echo "$(date): WARNING: spawn_upload_to_wsprdaemon_daemon() found a stale file '${uploading_pid_file_path}' with pid ${uploading_pid}, so deleting it"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    upload_to_wsprdaemon_daemon ${uploading_root_dir} ${uploading_tmp_root_dir} > ${uploading_log_file_path} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 2 ]] && echo "$(date): spawn_upload_to_wsprdaemon_daemon() Spawned new uploading job  with PID '$!'"
}

function kill_upload_to_wsprdaemon_daemon()
{
    local uploading_pid_file_path=${1}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprdaemon_daemon() killing active upload_to_wsprdaemon_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_to_wsprdaemon_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_to_wsprdaemon_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}

function upload_to_wsprdaemon_daemon_status()
{
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} == "no" ]]; then
        ## wsprdaemon uploading is not enabled
        return
    fi
    local uploading_pid_file_path=$1
    if [[ ${uploading_pid_file_path} == ${UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH} ]] ; then
        local data_type="noise"
    else
        local data_type="spots"
    fi
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprdaemon ${data_type} uploading daemon with pid '${uploading_pid}' is running"
            else
                echo "$(date): upload_to_wsprdaemon_daemon_status() '${uploading_pid_file_path}' with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprdaemon uploading daemon pid file ${uploading_pid_file_path}' records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): upload_to_wsprdaemon_daemon_status() found a stale pid file '${uploading_pid_file_path}'with pid ${uploading_pid}"
            fi
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "Wsprdaemon uploading daemon found no pid file '${uploading_pid_file_path}'"
        else
            echo "$(date): upload_to_wsprdaemon_daemon_status() found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

### Upload using FTP mode
### There is only one upload daemon in FTP mode
declare UPLOADS_WSPRDAEMON_FTP_ROOT_DIR=${UPLOADS_WSPRDAEMON_ROOT_DIR}
declare UPLOADS_WSPRDAEMON_FTP_LOGFILE_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads.log
declare UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads.pid
declare UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/uploads_config.txt  ## Communicates client FTP mode to FTP server
declare UPLOADS_WSPRDAEMON_FTP_TMP_WSPRNET_SPOTS_PATH=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}/wsprnet_spots.txt  ## On FTP server, TMP file synthesized from WD spots line



##############
#############
### FTP upload mode functions
declare UPLOADS_FTP_MODE_SECONDS=${UPLOADS_FTP_MODE_SECONDS-10}       ### Defaults to upload every 60 seconds
declare UPLOADS_FTP_MODE_MAX_BPS=${UPLOADS_FTP_MODE_MAX_BPS-100000}   ### Defaults to upload at 100 kbps
declare UPOADS_MAX_FILES=${UPOADS_MAX_FILES-10000}                    ### Limit the number of *txt files in one upload tar file.  bash limits this to < 24000
declare UPLOADS_WSPRNET_LINE_FORMAT_VERSION=1                         ### I don't expect this will change
declare UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION=2
declare UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION=1
function ftp_upload_to_wsprdaemon_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    local source_root_dir=${UPLOADS_ROOT_DIR}

    mkdir -p ${source_root_dir}
    cd ${source_root_dir}
    while true; do
        ### find all *.txt files under spots.d and noise.d.  Don't upload wsprnet.d/... files
        [[ ${verbosity} -ge 1 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() starting search for *wspr*.txt files"
        local -a file_list
        while file_list=( $(find wsprdaemon.d/ -name '*wspr*.txt' | head -n ${UPOADS_MAX_FILES} ) ) && [[ ${#file_list[@]} -eq 0 ]]; do   ### bash limits the # of cmd line args we will pass to tar to about 24000
            [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() found no .txt files. sleeping..."
            sleep 10
        done
        [[ ${verbosity} -ge 1 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() found ${#file_list[@]} '*wspr*.txt' files. Wait until there are no more new files."
        local old_file_count=${#file_list[@]}
        sleep 20
        while file_list=( $(find wsprdaemon.d/ -name '*wspr*.txt' | head -n ${UPOADS_MAX_FILES} ) ) && [[ ${#file_list[@]} -ne ${old_file_count} ]]; do
            local new_file_count=${#file_list[@]}
            [[ ${verbosity} -ge 1 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() file count increased from ${old_file_count} to ${new_file_count}. sleep 5 and check again."
            old_file_count=${new_file_count}
            sleep 5
        done
        [[ ${verbosity} -ge 1 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() file count stabilized at ${old_file_count}, so proceed to create tar file and upload"

        ### Get list of MERGed rx for use by server FTP proxy service
        local -a MERGED_RX_LIST=()
        for rx_line in "${RECEIVER_LIST[@]}"; do
            local rx_line_array=(${rx_line})
            if [[ "${rx_line_array[0]}" =~ ^MERG ]]; then
                MERGED_RX_LIST+=(${rx_line_array[0]}:${rx_line_array[1]})
            fi
        done

        ### Communicate this client's configuraton to the wsprdaemon.org server through lines in ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}
        echo -e "CLIENT_VERSION=${VERSION}
                 UPLOADS_WSPRNET_LINE_FORMAT_VERSION=${UPLOADS_WSPRNET_LINE_FORMAT_VERSION}
                 UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION=${UPLOADS_WSPRDAEMON_SPOT_LINE_FORMAT_VERSION}
                 UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION=${UPLOADS_WSPRDAEMON_NOISE_LINE_FORMAT_VERSION}
                 SIGNAL_LEVEL_UPLOAD=${SIGNAL_LEVEL_UPLOAD-no}
                 MERGED_RX_LIST=( ${MERGED_RX_LIST[@]} )
                 $(cat ${RUNNING_JOBS_FILE})" | sed 's/^ *//'                         > ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}         ### sed strips off the leading spaces in each line of the file
        local config_relative_path=${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH#$PWD/}
        [[ ${verbosity} -ge 2 ]] && echo -e "$(date): ftp_upload_to_wsprdaemon_daemon() created ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH}:\n$(cat ${UPLOADS_WSPRDAEMON_FTP_CONFIG_PATH})"

        local tar_file_name="${SIGNAL_LEVEL_UPLOAD_ID}_$(date -u +%g%m%d_%H%M_%S).tbz"
        [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() creating tar file '${tar_file_name}'"
        if ! tar cfj ${tar_file_name} ${config_relative_path} ${file_list[@]}; then
            local ret_code=$?
            [[ ${verbosity} -ge 1 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() ERROR 'tar cfj ${tar_file_name} \${file_list[@]}' => ret_code ${ret_code}"
        else
            if [[ ${verbosity} -ge 1 ]]; then
                local tar_file_size=$( ${GET_FILE_SIZE_CMD} ${tar_file_name} )
                local source_file_bytes=$(cat ${file_list[@]} | wc -c)
                echo "$(date): ftp_upload_to_wsprdaemon_daemon() uploading tar file '${tar_file_name}' of size ${tar_file_size} which contains ${source_file_bytes} bytes transfering ${#file_list[@]} spot and noise files."
            fi
            local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-noisegraphs}
            local upload_password=${SIGNAL_LEVEL_FTP_PASSWORD-xahFie6g}    ## Hopefully this default password never needs to change
            local upload_url=${SIGNAL_LEVEL_FTP_URL-graphs.wsprdaemon.org/upload}/${tar_file_name}
            curl -s --limit-rate ${UPLOADS_FTP_MODE_MAX_BPS} -T ${tar_file_name} --user ${upload_user}:${upload_password} ftp://${upload_url}
            local ret_code=$?
            if [[ ${ret_code} -eq  0 ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() curl FTP upload was successful. Deleting wspr*.txt files."
                rm -f ${file_list[@]}
            else
                [[ ${verbosity} -ge 1 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() curl FTP upload failed. ret_code = ${ret_code}"
            fi
            rm -f ${tar_file_name} 
        fi
        [[ ${verbosity} -ge 2 ]] && echo "$(date): ftp_upload_to_wsprdaemon_daemon() sleeping for ${UPLOADS_FTP_MODE_SECONDS} seconds"
        sleep ${UPLOADS_FTP_MODE_SECONDS}
    done
}

function spawn_ftp_upload_to_wsprdaemon_daemon() {
    local uploading_root_dir=${UPLOADS_WSPRDAEMON_FTP_ROOT_DIR}
    mkdir -p ${uploading_root_dir}
    local uploading_log_file_path=${UPLOADS_WSPRDAEMON_FTP_LOGFILE_PATH}
    local uploading_pid_file_path=${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}

    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): spawn_ftp_upload_to_wsprdaemon_daemon() INFO: uploading job for '${uploading_root_dir}' with pid ${uploading_pid} is already running"
            return
        else
            echo "$(date): WARNING: spawn_ftp_upload_to_wsprdaemon_daemon() found a stale file '${uploading_pid_file_path}' with pid ${uploading_pid}, so deleting it"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    ftp_upload_to_wsprdaemon_daemon > ${uploading_log_file_path} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_ftp_upload_to_wsprdaemon_daemon() Spawned new uploading job  with PID '$!'"
}

function kill_ftp_upload_to_wsprdaemon_daemon()
{
    local uploading_pid_file_path=${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_ftp_upload_to_wsprdaemon_daemon() killing active upload_to_wsprdaemon_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_ftp_upload_to_wsprdaemon_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): ftp_kill_upload_to_wsprdaemon_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}
function ftp_upload_to_wsprdaemon_daemon_status()
{
    local uploading_pid_file_path=${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "The wsprdaemon.org uploading daemon is running"
            else
                echo "$(date): ftp_upload_to_wsprdaemon_daemon_status() with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "The wsprdemon.org uploading daemon pid file ${uploading_pid_file_path}' records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): ftp_upload_to_wsprdaemon_daemon_status() found a stale pid file '${uploading_pid_file_path}'with pid ${uploading_pid}"
            fi
            rm -f ${uploading_pid_file_path}
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "No wsprdaemon.org uploading daemon is running"
        else
            echo "$(date): ftp_upload_to_wsprdaemon_daemon_status() found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

############## Top level which spawns/kill/shows status of all of the upload daemons
function spawn_upload_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): spawn_upload_daemons() start"
    spawn_upload_to_wsprnet_daemon
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then
        spawn_ftp_upload_to_wsprdaemon_daemon 
    fi
}

function kill_upload_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): kill_upload_daemons() start"
    kill_upload_to_wsprnet_daemon
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then
        kill_ftp_upload_to_wsprdaemon_daemon
    fi
}

function upload_daemons_status(){
    [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_daemons_status() start"
    upload_to_wsprnet_daemon_status
    if [[ ${SIGNAL_LEVEL_UPLOAD-no} != "no" ]]; then
        ftp_upload_to_wsprdaemon_daemon_status
    fi
}

############## Implents the '-u' cmd which runs only on wsprdaemon.org to process the tar .tbz files uploaded by WD sites

declare UPLOAD_FTP_PATH=~/ftp/upload       ### Where the FTP server leaves tar.tbz files
declare UPLOAD_BATCH_PYTHON_CMD=${WSPRDAEMON_ROOT_DIR}/ts_upload_batch.py
declare TS_NOISE_AWK_SCRIPT=${WSPRDAEMON_ROOT_DIR}/ts_noise.awk

#     
#  local extended_line=$( printf "%6s %4s %3d %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
#                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
declare UPLOAD_SPOT_SQL='INSERT INTO wsprdaemon_spots (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon, receiver) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s); '
declare UPLOAD_NOISE_SQL='INSERT INTO wsprdaemon_noise (time, site, receiver, rx_grid, band, rms_level, c2_level, ov) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);'

### This deamon runs on wsprdaemon.org and processes tgz files FTPed to it by WD clients
### It optionally queues a copy of each tgz for FTP transfer to WD1
function wsprdaemon_tgz_service_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD

    mkdir -p ${UPLOADS_TMP_ROOT_DIR}
    cd ${UPLOADS_TMP_ROOT_DIR}
    echo "UPLOAD_SPOT_SQL=${UPLOAD_SPOT_SQL}" > upload_spot.sql       ### helps debugging from cmd line
    echo "UPLOAD_NOISE_SQL=${UPLOAD_NOISE_SQL}" > upload_noise.sql
    shopt -s nullglob
    [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() starting in $PWD"
    while true; do
        [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() waiting for *.tbz files to appear in ${UPLOAD_FTP_PATH}"
        local -a tar_file_list
        while tar_file_list=( ${UPLOAD_FTP_PATH}/*.tbz) && [[ ${#tar_file_list[@]} -eq 0 ]]; do
            [[ $verbosity -ge 3 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() waiting for *.tbz files"
            sleep 10
        done
        if [[ ${#tar_file_list[@]} -gt 1000 ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() processing only first 1000 tar files of the ${#tar_file_list[@]} in ~/ftp/uploads directory"
            tar_file_list=( ${tar_file_list[@]:0:1000} )
        fi
        [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() validating ${#tar_file_list[@]} tar.tbz files..."
        local valid_tbz_list=()
        local tbz_file 
        for tbz_file in ${tar_file_list[@]}; do
            if tar tf ${tbz_file} &> /dev/null ; then
                [[ $verbosity -ge 3 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found valid tar file ${tbz_file}"
                valid_tbz_list+=(${tbz_file})
                if [[ ${tbz_file} =~ "[fF]6*" ]]; then
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() copying ${tbz_file} to /tmp"
                    cp -p {tbz_file} /tmp/
                fi
            else
                if [[ -f ${tbz_file} ]]; then
                    ### A client may be in the process of uploading a tar file.
                    [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found invalid tar file ${tbz_file}"
                    local file_mod_time=0
                    file_mod_time=$( $GET_FILE_MOD_TIME_CMD ${tbz_file})
                    local current_time=$(date +"%s")
                    local file_age=$(( ${current_time}  - ${file_mod_time} ))
                    if [[ ${file_age} -gt ${MAX_TAR_AGE_SECS-600} ]] ; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() deleting invalid file ${tbz_file} which is ${file_age} seconds old"
                        rm ${tbz_file}
                    fi
                else
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() unexpectedly found tar file ${tbz_file} was deleted during validation"
                fi
            fi
        done
        if [[ ${#valid_tbz_list[@]} -eq 0 ]]; then
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found no valid tar files among the ${#tar_file_list[@]} raw tar files"
            sleep 1
            continue
        else
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() extracting ${#valid_tbz_list[@]} valid tar files"
            queue_files_for_upload_to_wd1 ${valid_tbz_list[@]}
            cat  ${valid_tbz_list[@]} | tar jxf - -i
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() ERROR: tar returned error code ${ret_code}"
            fi
            if [[ ! -d wsprdaemon.d ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() ERROR: tar sources didn't create wsprdaemon.d"
            fi

            ### Record the spot files
            local spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_wspr_spots.txt')  )
            local raw_spot_file_list_count=${#spot_file_list[@]}
            if [[ ${#spot_file_list[@]} -eq 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found no spot files in any of the tar files.  Checking for noise files in $(ls -d wsprdaemon.d/*) ."
            else
                ### There are spot files 
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${raw_spot_file_list_count} spot files.  Flushing zero length spot files"

                ### Remove zero length spot files (that is common, since they are used by the decoding daemon to signal the posting daemon that decoding has been completed when no spots are decoded
                local zero_length_spot_file_list=( $(find wsprdaemon.d/spots.d -name '*wspr_spots.txt' -size 0) )
                local zero_length_spot_file_list_count=${#zero_length_spot_file_list[@]}
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${#zero_length_spot_file_list[@]} zero length spot files"
                local rm_file_list=()
                while rm_file_list=( ${zero_length_spot_file_list[@]:0:10000} ) && [[ ${#rm_file_list[@]} -gt 0 ]]; do     ### Remove in batches of 10000 files.
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() deleting batch of the first ${#rm_file_list[@]} of the remaining ${#zero_length_spot_file_list[@]}  zero length spot files"
                    rm ${rm_file_list[@]}
                    zero_length_spot_file_list=( ${zero_length_spot_file_list[@]:10000} )          ### Chop off the 10000 files we just rm'd
                done
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() finished flushing zero length spot files.  Reload list of remaining non-zero length files"
                spot_file_list=( $(find wsprdaemon.d/spots.d -name '*_wspr_spots.txt')  )
                [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${raw_spot_file_list_count} spot files, of which ${zero_length_spot_file_list_count} were zero length spot files.  After deleting those zero length files there are now ${#spot_file_list[@]} files with spots in them."

                ###
                if [[ ${#spot_file_list[@]} -eq 0 ]]; then
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() there were no non-zero length spot files. Go on to check for noise files under wsprdaemon.noise."
                else
                    ### There are spot files with spot lines
                    ### If the sync_quality in the third field is a float (i.e. has a '.' in it), then this spot was decoded by wsprd v2.1
                    local calls_delivering_jtx_2_1_lines=( $(awk 'NF == 32 && $3  !~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
                    if [[ ${#calls_delivering_jtx_2_1_lines[@]} -ne 0 ]]; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() Calls using WSJT-x V2.1 wsprd: ${calls_delivering_jtx_2_1_lines[@]}"
                    fi
                    local calls_delivering_jtx_2_2_lines=( $(awk 'NF == 32 && $3  ~ /\./ { print $23}' ${spot_file_list[@]} | sort -u) )
                    if [[ ${#calls_delivering_jtx_2_2_lines[@]} -ne 0 ]]; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() Calls using WSJT-x V2.2 wsprd: ${calls_delivering_jtx_2_2_lines[@]}"
                    fi
                    ###   spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin spot_rms_noise spot_c2_noise spot_for_wsprnet band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon

                    ###  awk 'NF == 32' ${spot_file_list[@]:0:20000}  => filters out corrupt spot lines.  Only lines with 32 fields are fed to TS.  The bash cmd line can process no more than about 23,500 arguments, so pass at most 20,000 txt file names to awk.  If there are more, they will get processed in the next loop iteration
                    ###  sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/;'"s/\"/'/g"
                    ###          s/\S+\s+//18;  => deletes the 18th field, the 'proxy upload this spot to wsprnet.org'
                    ###                        s/ /,/g; => replace all spaces with ','s
                    ###                                   s/,/:/; => change the first two fields from DATE,TIME to DATE:TIME
                    ###                                          s/./&"/11; => add '"' to get DATE:TIME"
                    ###                                                      s/./&:/9; => insert ':' to get YYMMDD:HH:MM"
                    ###                                                                s/./&-/4; s/./&-/2;   => insert ':' to get YY-MM-DD:HH:MM"
                    ###                                                                                   s/^/"20/;  => insert '"20' to get "20YY-MM-DD:HH:MM"
                    ###                                                                                             s/",0\./",/; => WSJT-x V2.2+ outputs a floting point sync value.  this chops off the leading '0.' to make it a decimal number for TS 
                    ###                                                                                                          "s/\"/'/g" => replace those two '"'s with ''' to get '20YY-MM-DD:HH:MM'.  Since this expression includes a ', it has to be within "s
                    local TS_SPOTS_CSV_FILE=./ts_spots.csv
                    local TS_BAD_SPOTS_CSV_FILE=./ts_bad_spots.csv
                    ### the awk expression forces the tx_call and rx_id to be all upper case letters and the tx_grid and rx_grid to by UU99ll, just as is done by wsprnet.org
                    ### 9/5/20:  RR added receiver name to end of each line.  It is extracted from the path of the wsprdaemon_spots.txt file
                    awk 'NF == 32 && $7 != "none" && $8 != "none" {\
                        $7=toupper($7); \
                        $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4))); \
                        $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4))); \
                        $23=toupper($23); \
                        n = split(FILENAME, a, "/"); \
                        printf "%s %s\n", $0, a[n-2]} ' ${spot_file_list[@]}  > awk.out
                        cat awk.out | sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" > ${TS_SPOTS_CSV_FILE}

                    ### 9/5/20:  RR include receiver name in bad spots lines
                    awk 'NF != 32 || $7 == "none" || $8 == "none" {\
                        $7=toupper($7); \
                        $8 = ( toupper(substr($8, 1, 2)) tolower(substr($8, 3, 4))); \
                        $22 = ( toupper(substr($22, 1, 2)) tolower(substr($22, 3, 4))); \
                        $23=toupper($23); \
                        n = split(FILENAME, a, "/"); \
                        printf "%s %s\n", $0, a[n-2]} ' ${spot_file_list[@]}  > awk_bad.out
                        cat awk_bad.out | sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/; s/",0\./",/;'"s/\"/'/g" > ${TS_BAD_SPOTS_CSV_FILE}

                    if [[ $verbosity -ge 1 ]] && [[ -s ${TS_BAD_SPOTS_CSV_FILE} ]] ; then
                        local bad_spots_count=$(cat ${TS_BAD_SPOTS_CSV_FILE} | wc -l)
                        echo -e "$(date): wsprdaemon_tgz_service_daemon() found ${bad_spots_count} bad spots:\n$(head -n 4 ${TS_BAD_SPOTS_CSV_FILE})"
                    fi
                    if [[ -s ${TS_SPOTS_CSV_FILE} ]]; then
                        python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_SPOTS_CSV_FILE}  "${UPLOAD_SPOT_SQL}"
                        local ret_code=$?
                        if [[ ${ret_code} -eq 0 ]]; then
                            if [[ $verbosity -ge 1 ]]; then
                                echo "$(date): wsprdaemon_tgz_service_daemon() recorded $( cat ${TS_SPOTS_CSV_FILE} | wc -l) spots to the wsprdaemon_spots table from ${#spot_file_list[@]} spot files which were extracted from ${#valid_tbz_list[@]} tar files."
                                grep -i f6bir ${spot_file_list[@]}
                            fi
                            rm ${spot_file_list[@]} 
                        else
                            [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() python failed to record $( cat ${TS_SPOTS_CSV_FILE} | wc -l) spots to the wsprdaemon_spots table from \${spot_file_list[@]}"
                        fi
                    else
                        if [[ $verbosity -ge 1 ]]; then
                            echo "$(date): wsprdaemon_tgz_service_daemon() found zero valid spot lines in the ${#spot_file_list[@]} spot files which were extracted from ${#valid_tbz_list[@]} tar files."
                            awk 'NF != 32 || $7 == "none" {printf "Skipped line in %s which contains invalid spot line %s\n", FILENAME, $0}' ${spot_file_list[@]}
                        fi
                        rm ${spot_file_list[@]} 
                    fi
                fi
            fi

            ### Record the noise files
            local noise_file_list=( $(find wsprdaemon.d/noise.d -name '*_wspr_noise.txt') )
            if [[ ${#noise_file_list[@]} -eq 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() unexpectedly found no noise files"
                sleep 1
            else
                [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() found ${#noise_file_list[@]} noise files"
                local TS_NOISE_CSV_FILE=ts_noise.csv

                local csv_files_left_list=(${noise_file_list[@]})
                local csv_file_list=( )
                CSV_MAX_FILES=5000
                local csv_files_left_list=(${noise_file_list[@]})
                local csv_file_list=( )
                while csv_file_list=( ${csv_files_left_list[@]::${CSV_MAX_FILES}} ) && [[ ${#csv_file_list[@]} -gt 0 ]] ; do
                    [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() processing batch of ${#csv_file_list[@]} of the remaining ${#csv_files_left_list[@]} noise_files into ${TS_NOISE_CSV_FILE}"
                    awk -f ${TS_NOISE_AWK_SCRIPT} ${csv_file_list[@]} > ${TS_NOISE_CSV_FILE}
                    if [[ $verbosity -ge 1 ]]; then
                        [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() awk created ${TS_NOISE_CSV_FILE} which contains $( cat ${TS_NOISE_CSV_FILE} | wc -l ) noise lines"
                        local UPLOAD_NOISE_SKIPPED_FILE=ts_noise_skipped.txt
                        awk 'NF != 15 {printf "%s: %s\n", FILENAME, $0}' ${csv_file_list[@]} > ${UPLOAD_NOISE_SKIPPED_FILE}
                        if [[ -s ${UPLOAD_NOISE_SKIPPED_FILE} ]]; then
                            echo "$(date): wsprdaemon_tgz_service_daemon() awk found $(cat ${UPLOAD_NOISE_SKIPPED_FILE} | wc -l) invalid noise lines which are saved in ${UPLOAD_NOISE_SKIPPED_FILE}:"
                            head -n 10 ${UPLOAD_NOISE_SKIPPED_FILE}
                        fi
                    fi
                    python3 ${UPLOAD_BATCH_PYTHON_CMD} ${TS_NOISE_CSV_FILE}  "${UPLOAD_NOISE_SQL}"
                    local ret_code=$?
                    if [[ ${ret_code} -eq 0 ]]; then
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() recorded $( cat ${TS_NOISE_CSV_FILE} | wc -l) noise lines to the wsprdaemon_noise table from ${#noise_file_list[@]} noise files which were extracted from ${#valid_tbz_list[@]} tar files."
                        rm ${csv_file_list[@]}
                    else
                        [[ $verbosity -ge 1 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() python failed to record $( cat ${TS_NOISE_CSV_FILE} | wc -l) noise lines to  the wsprdaemon_noise table from \${noise_file_list[@]}"
                    fi
                    csv_files_left_list=( ${csv_files_left_list[@]:${CSV_MAX_FILES}} )            ### Chops off the first 1000 elements of the list 
                    [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() finished with csv batch"
                done
                [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() finished with all noise files"
            fi
            [[ $verbosity -ge 2 ]] && echo "$(date): wsprdaemon_tgz_service_daemon() deleting the ${#valid_tbz_list[@]} valid tar files"
            rm ${valid_tbz_list[@]} 
        fi
    done
}

declare UPLOAD_TO_MIRROR_SERVER_URL="${UPLOAD_TO_MIRROR_SERVER_URL-}"
declare UPLOAD_TO_MIRROR_QUEUE_DIR          ## setup when upload daemon is spawned
declare UPLOAD_TO_MIRROR_SERVER_SECS=10       ## How often to attempt to upload tar files to log1.wsprdaemon.org
declare UPLOAD_MAX_FILE_COUNT=1000          ## curl will upload only a ?? number of files, so limit the number of files given to curl

### Copies the valid tar files found by the upload_server_daemon() to logs1.wsprdaemon.org
function upload_to_mirror_daemon() {
    local mirror_files_path=${UPLOAD_TO_MIRROR_QUEUE_DIR}
    local parsed_server_url_list=( ${UPLOAD_TO_MIRROR_SERVER_URL//,/ } )
    if [[ ${#parsed_server_url_list[@]} -ne 3 ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon(): ERROR: invalid configuration variable UPLOAD_TO_MIRROR_SERVER_URL  = '${UPLOAD_TO_MIRROR_SERVER_URL}'"
        return 1
    fi
    local upload_url=${parsed_server_url_list[0]}
    local upload_user=${parsed_server_url_list[1]}
    local upload_password=${parsed_server_url_list[2]}

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    mkdir -p ${mirror_files_path}
    cd ${UPLOAD_TO_MIRROR_QUEUE_DIR}

    [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon starting in ${UPLOAD_TO_MIRROR_QUEUE_DIR}"
    while true; do
        [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_mirror_daemon() looking for files to upload"
        shopt -s nullglob
        local files_queued_for_upload_list=( * )
        if [[ ${#files_queued_for_upload_list[@]} -gt 0 ]]; then
            local curl_upload_file_list=(${files_queued_for_upload_list[@]::${UPLOAD_MAX_FILE_COUNT}})  ### curl limits the number of files to upload, so curl only the first UPLOAD_MAX_FILE_COUNT files 
            [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon() starting curl of ${#curl_upload_file_list[@]} files using: '.. --user ${upload_user}:${upload_password} ftp://${upload_url}'"
            local curl_upload_file_string=${curl_upload_file_list[@]}
            curl_upload_file_string=${curl_upload_file_string// /,}     ### curl wants a comma-seperated list of files
            curl -s -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${upload_user}:${upload_password} ftp://${upload_url} 
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon() curl xfer was successful, so delete ${#curl_upload_file_list[@]} local files"
                rm ${curl_upload_file_list[@]}
            else
                [[ $verbosity -ge 1 ]] && echo "$(date): upload_to_mirror_daemon() curl xfer failed => ${ret_code}"
            fi
        fi
        [[ $verbosity -ge 2 ]] && echo "$(date): upload_to_mirror_daemon() sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function queue_files_for_upload_to_wd1() {
    local files="$@"

    if [[ -n "${UPLOAD_TO_MIRROR_SERVER_URL}" ]]; then
        if [[ $verbosity -ge 1 ]]; then
            local files_path_list=(${files})
            local files_name_list=(${files_path_list[@]##*/})
            echo "$(date): queue_files_for_upload_to_wd1() queuing ${#files_name_list[@]} files '${files_name_list[@]}' in '${UPLOAD_TO_MIRROR_QUEUE_DIR}'"
        fi
        ln ${files} ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    else
        [[ $verbosity -ge 2 ]] && echo "$(date): queue_files_for_upload_to_wd1() queuing disabled, so ignoring '${files}'"
    fi
}

### Spawns 2 daemons:  one to process the WD extended spots and noise delivered to the 'noisegrahs' user in .tgz files
###                    a second (optional) daemon mirrors those tgz files to a backup WD server
function spawn_upload_server_to_wsprdaemon_daemon() {
    local uploading_root_dir=$1
    mkdir -p ${uploading_root_dir}
    local uploading_log_file_path=${uploading_root_dir}/uploads.log
    local uploading_pid_file_path=${uploading_root_dir}/uploads.pid  
    local mirror_log_file_path=${uploading_root_dir}/mirror.log
    local mirror_pid_file_path=${uploading_root_dir}/mirror.pid  
    UPLOAD_TO_MIRROR_QUEUE_DIR=${uploading_root_dir}/mirror_queue.d
    if [[ ! -d ${UPLOAD_TO_MIRROR_QUEUE_DIR} ]]; then
        mkdir -p ${UPLOAD_TO_MIRROR_QUEUE_DIR}
    fi

    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() start"
    setup_systemctl_deamon "-u a"  "-u z"
    if [[ -f ${mirror_pid_file_path} ]]; then
        local mirror_pid=$(cat ${mirror_pid_file_path})
        if ps ${mirror_pid} > /dev/null ; then
            [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() mirror daemon in '${mirror_pid_file_path}' with pid ${mirror_pid} is already running"
            kill ${mirror_pid}
        fi
        rm ${mirror_pid_file_path}
    fi
    if [[ -n "${UPLOAD_TO_MIRROR_SERVER_URL}" ]]; then
        upload_to_mirror_daemon  > ${mirror_log_file_path} 2>&1 &
        local mirror_pid=$!
        echo ${mirror_pid}  > ${mirror_pid_file_path}
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() started mirror daemon with pid ${mirror_pid}"
    fi

    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() uploading job for '${uploading_root_dir}' with pid ${uploading_pid} is already running"
            return 0
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): WARNING: spawn_upload_server_to_wsprdaemon_daemon() found a stale file '${uploading_pid_file_path}' with pid ${uploading_pid}, so deleting it"
            rm -f ${uploading_pid_file_path}
        fi
    fi
    wsprdaemon_tgz_service_daemon ${uploading_root_dir} > ${uploading_log_file_path} 2>&1 &
    echo $! > ${uploading_pid_file_path}
    [[ $verbosity -ge 1 ]] && echo "$(date): spawn_upload_server_to_wsprdaemon_daemon() Spawned new uploading job  with PID '$!'"
    return 0
}

function kill_upload_server_to_wsprdaemon_daemon()
{
    local mirror_pid_file_path=${1}/mirror.pid
    if [[ -f ${mirror_pid_file_path} ]]; then
        local mirror_pid=$(cat ${mirror_pid_file_path})
        if ps ${mirror_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() killing active mirror_server_to_wsprdaemon_daemon() with pid ${mirror_pid}"
            kill ${mirror_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found a stale mirror.pid file with pid ${mirror_pid}"
        fi
        rm -f ${mirror_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found no mirror.pid file ${mirror_pid_file_path}"
    fi
    local uploading_pid_file_path=${1}/uploads.pid
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() killing active upload_server_to_wsprdaemon_daemon() with pid ${uploading_pid}"
            kill ${uploading_pid}
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found a stale uploading.pid file with pid ${uploading_pid}"
        fi
        rm -f ${uploading_pid_file_path}
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): kill_upload_server_to_wsprdaemon_daemon() found no uploading.pid file ${uploading_pid_file_path}"
    fi
}

function upload_server_to_wsprdaemon_daemon_status()
{
    local mirror_pid_file_path=${1}/mirror.pid
    if [[ -f ${mirror_pid_file_path} ]]; then
        local mirror_pid=$(cat ${mirror_pid_file_path})
        if ps ${mirror_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "Mirror daemon with pid '${mirror_pid}' is running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): mirror service daemon file '${mirror_pid_file_path}' with pid ${mirror_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Wsprdaemon mirror daemon pid file ${mirror_pid_file_path}' records pid '${mirror_pid}', but that pid is not running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): found a stale pid file '${mirror_pid_file_path}'with pid ${mirror_pid}"
            fi
        fi
    else
        if [[ $verbosity -ge 2 ]] ; then
            echo "$(date): upload_to_wsprdaemon_daemon_status(): found no mirror.pid file ${mirror_pid_file_path}"
        fi
    fi
    local uploading_pid_file_path=${1}/uploads.pid
    if [[ -f ${uploading_pid_file_path} ]]; then
        local uploading_pid=$(cat ${uploading_pid_file_path})
        if ps ${uploading_pid} > /dev/null ; then
            if [[ $verbosity -eq 0 ]] ; then
                echo "Uploading daemon with pid '${uploading_pid}' is running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): upload service daemon file '${uploading_pid_file_path}' with pid ${uploading_pid} id running"
            fi
        else
            if [[ $verbosity -eq 0 ]] ; then
                echo "Uploading daemon pid file ${uploading_pid_file_path}' records pid '${uploading_pid}', but that pid is not running"
            else
                echo "$(date): upload_server_to_wsprdaemon_daemon_status(): found a stale pid file '${uploading_pid_file_path}'with pid ${uploading_pid}"
            fi
            return 1
        fi
    else
        if [[ $verbosity -eq 0 ]] ; then
            echo "Uploading daemon found no pid file '${uploading_pid_file_path}'"
        else
            echo "$(date): upload_server_to_wsprdaemon_daemon_status(): found no uploading.pid file ${uploading_pid_file_path}"
        fi
    fi
    return 0
}

function spawn_upload_server_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): spawn_upload_server_daemons() start"
    spawn_upload_server_to_wsprdaemon_daemon ${UPLOADS_ROOT_DIR}
}

function kill_upload_server_daemons() {
    [[ ${verbosity} -ge 3 ]] && echo "$(date): kill_upload_server_daemons() start"
    kill_upload_server_to_wsprdaemon_daemon ${UPLOADS_ROOT_DIR}
}

function upload_server_daemons_status(){
    [[ ${verbosity} -ge 3 ]] && echo "$(date): upload_server_daemons_status() start"
    upload_server_to_wsprdaemon_daemon_status ${UPLOADS_ROOT_DIR}
}

### function which handles 'wd -u ...'
function upload_server_daemon() {
    local action=$1
    
    [[ $verbosity -ge 3 ]] && echo "$(date): upload_server_daemon() process cmd '${action}'"
    case ${action} in
        a)
            spawn_upload_server_daemons     ### Ensure there are upload daemons to consume the spots and noise data
            ;;
        z)
            kill_upload_server_daemons
            ;;
        s)
            upload_server_daemons_status
            ;;
        *)
            echo "ERROR: start_stop_job() aargument action '${action}' is invalid"
            exit 1
            ;;
    esac
}

source ${WSPRDAEMON_ROOT_DIR}/kiwi_management.sh
source ${WSPRDAEMON_ROOT_DIR}/job_management.sh
source ${WSPRDAEMON_ROOT_DIR}/watchdog.sh
source ${WSPRDAEMON_ROOT_DIR}/noise_graphing.sh
source ${WSPRDAEMON_ROOT_DIR}/usage.sh

[[ -z "$*" ]] && usage

while getopts :aAzZshij:pvVw:dDu:U: opt ; do
    case $opt in
        U)
            uploading_controls $OPTARG
            ;;
        A)
            enable_systemctl_deamon
            watchdog_cmd a
            ;;
        a)
            watchdog_cmd a
            ;;
        z)
            watchdog_cmd z
            jobs_cmd     z
            check_for_zombies yes   ## silently kill any zombies
            ;;
        Z)
            check_for_zombies no   ## prompt before killing any zombies
            ;;
        s)
            jobs_cmd     s
            upload_daemons_status
            watchdog_cmd s
            ;;
        i)
            list_devices 
            ;;
        w)
            watchdog_cmd $OPTARG
            ;;
        j)
            jobs_cmd $OPTARG
            ;;
        p)
            plot_noise
            ;;
        h)
            usage
            ;;
        u)
            upload_server_daemon $OPTARG
            ;;
        v)
            ((verbosity++))
            [[ $verbosity -ge 4 ]] && echo "Verbosity = ${verbosity}"
            ;;
        V)
            echo "Version = ${VERSION}"
            ;;
        d)
            increment_verbosity
            ;;
        D)
            decrement_verbosity
            ;;
        \?)
            echo "Invalid option: -$OPTARG" 1>&2
            ;;
        : )
            echo "Invalid option: -$OPTARG requires an argument" 1>&2
            ;;
    esac
done
