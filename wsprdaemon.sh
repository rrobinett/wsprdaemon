#!/bin/bash

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

#declare -r VERSION=2.9e            ### Fix exchanged values of ipass and nhdwrmin when posting to TS.  This section of code runs only at wsprdaemon.org
#declare -r VERSION=2.9f             ### Fix wsprnet upload client to support multiple CALL_GRID in conf file
                                    ### Fix CHU_14 frequency
                                    ### Tweek comments in prototype WD.conf file
                                    ### WD upload service (-u a/s/z) which runs on the wsprdaemon.org server has been enhanced to run 1000x faster, really!  It now used batch mode to record 4000+ spots per second to TimeScale 
                                    ### WD upload service better filters out corrupt spot lines.
#declare -r VERSION=2.9g             ### Cleanup installation of WSJT-x which suppplies the 'wsprd' decoder
                                    ### Check for and install if needed 'ntp' and 'at'
                                    ### Cleanup systemctl setup so startup after boot functions on Ubuntu
                                    ### Wsprnet upload client daemon flushes files of completed cycles where no bands have spots
                                    ### Fix wrong start/stop args in wsprdeamon.service
                                    ### Stop checking the Pi OS version number, since we run on almost every Pi
                                    ### Add validation of spots in wspr_spots.txt and ALL_WSPR.TXT files
#declare -r VERSION=2.9h             ### Install at beta sites
                                    ### WD server: Force call signs and rx_id to upppercase and grids to UUNNll
                                    ### Add support for VHF/UHF transverter ahead of rx device.  Set KIWIRECORDER_FREQ_OFFSET to offset in KHz
#declare -r VERSION=2.9i             ### Change to support per-Kiwi OFFSET defined in conf file
                                    ### Fix noise level calcs and graphs for transcoder-fed Kiwis
                                    ### Fix mirror deaemon to handle 50,000+ cached files
                                    ### Cleaup handling of WD spots and noise file mirroring to logs1...
                                    ### Fix bash arg overflow error when startup after long time finds 50,000+ tar files in the ftp/upload directory
#declare -r VERSION=2.9j             ### WD server: fix recording of rx and tx GRID.  Add recording of receiver name to each spot
#declare -r VERSION=2.10a            ### Support Ubuntu 20.04 and streamline installation of wsprd by extracting only wsprd from the package file.
                                    ### Execute the astral python sunrise/sunset calculation script with python3
declare -r VERSION=2.10b            ### Fix installation problems on Ubuntu 20.04.  Download and run 'wsprd' v2.3.0-rc0
                                    ### TODO: Flush antique ~/signal_level log files
                                    ### TODO: Fix inode overflows when SIGNAL_LEVEL_UPLOAD="no" (e.g. at LX1DQ)
                                    ### TODO: Split Python utilities in seperate files maintained by git
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

export TZ=UTC LC_TIME=POSIX          ### Ensures that log dates will be in UTC

lc_numeric=$(locale | sed -n '/LC_NUMERIC/s/.*="*\([^"]*\)"*/\1/p')        ### There must be a better way, but locale sometimes embeds " in it output and this gets rid of them
if [[ "${lc_numeric}" != "en_US" ]] && [[ "${lc_numeric}" != "en_US.UTF-8" ]] && [[ "${lc_numeric}" != "en_GB.UTF-8" ]] && [[ "${lc_numeric}" != "C.UTF-8" ]] ; then
    echo "WARNING:  LC_NUMERIC '${lc_numeric}' on your server is not the expected value 'en_US.UTF-8'."     ### Try to ensure that the numeric frequency comparisons use the format nnnn.nnnn
    echo "          If the spot frequencies reported by your server are not correct, you may need to change the 'locale' of your server"
fi

#############################################
declare -i verbosity=${v:-0}         ### default to level 0, but can be overridden on the cmd line.  e.g "v=2 wsprdaemon.sh -V"

function verbosity_increment() {
    verbosity=$(( $verbosity + 1))
    echo "$(date): verbosity_increment() verbosity now = ${verbosity}"
}
function verbosity_decrement() {
    [[ ${verbosity} -gt 0 ]] && verbosity=$(( $verbosity - 1))
    echo "$(date): verbosity_decrement() verbosity now = ${verbosity}"
}

function setup_verbosity_traps() {
    trap verbosity_increment SIGUSR1
    trap verbosity_decrement SIGUSR2
}

function signal_verbosity() {
    local up_down=$1
    local pid_files=$(shopt -s nullglob ; echo *.pid)

    if [[ -z "${pid_files}" ]]; then
        echo "No *.pid files in $PWD"
        return
    fi
    local file
    for file in ${pid_files} ; do
        local debug_pid=$(cat ${file})
        if ! ps ${debug_pid} > /dev/null ; then
            echo "PID ${debug_pid} from ${file} is not running"
        else
            echo "Signaling verbosity change to PID ${debug_pid} from ${file}"
            kill -SIGUSR${up_down} ${debug_pid}
        fi
    done
}

### executed by cmd line '-d'
function increment_verbosity() {
    signal_verbosity 1
}
### executed by cmd line '-D'
function decrement_verbosity() {
    signal_verbosity 2
}

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
        [[ $verbosity -ge 1 ]] && "check_tmp_filesystem() found '{WSPRDAEMON_TMP_DIR}' is a tmpfs file system"
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
declare   KIWI_RECORD_TMP_LOG_FILE="${WSPRDAEMON_TMP_DIR}/kiwiclient.log"

function check_for_kiwirecorder_cmd() {
    local get_kiwirecorder="no"
    local apt_update_done="no"
    if [[ ! -x ${KIWI_RECORD_COMMAND} ]]; then
        get_kiwirecorder="yes"
    else
        ## kiwirecorder.py has been installed.  Check to see if kwr is missing some needed modules
        if ! python3 ${KIWI_RECORD_COMMAND} --help >& ${KIWI_RECORD_TMP_LOG_FILE} ; then
            echo "Currently installed version of kiwirecorder.py fails to run."
            if ! ${GREP_CMD} "No module named 'numpy'" ${KIWI_RECORD_TMP_LOG_FILE}; then
                echo "Found unknown error in ${KIWI_RECORD_TMP_LOG_FILE} when running 'python3 ${KIWI_RECORD_COMMAND}'"
                exit 1
            fi
            if ! pip3 install numpy; then 
                echo "Installation command 'pip3 install numpy' failed"
                exit 1
            fi
            echo "Installation command 'pip3 install numpy' was successful"
            if ! python3 ${KIWI_RECORD_COMMAND} --help >& ${KIWI_RECORD_TMP_LOG_FILE} ; then
                echo "urrently installed version of kiwirecorder.py fails to run even after installing module numpy"
                exit 1
            fi
            exit 0
        fi
        ### kwirecorder.py ran successfully
        if ! ${GREP_CMD} "ADC OV" ${KIWI_RECORD_TMP_LOG_FILE} > /dev/null 2>&1 ; then
            get_kiwirecorder="yes"
            echo "Currently installed version of kiwirecorder.py does not support overload reporting, so getting new version"
            rm -rf ${KIWI_RECORD_DIR}.old
            mv ${KIWI_RECORD_DIR} ${KIWI_RECORD_DIR}.old
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
declare -r WSPRDAEMON_CONFIG_TEMPLATE_FILE=${WSPRDAEMON_TMP_DIR}/template.conf

if [[ ! -f ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ]]; then

cat << 'EOF'  > ${WSPRDAEMON_CONFIG_TEMPLATE_FILE}
# To enable these options, remove the leading '#' and modify SIGNAL_LEVEL_UPLOAD_ID from "AI6VN" to your call sign:
#SIGNAL_LEVEL_UPLOAD="proxy"        ### If this variable is defined and not "no", AND SIGNAL_LEVEL_UPLOAD_ID is defined, then upload signal levels to the wsprdaemon cloud database
                                   ### SIGNAL_LEVEL_UPLOAD_MODE="no"    => (Default) Upload spots directly to wsprnet.org
                                   ### SIGNAL_LEVEL_UPLOAD_MODE="noise" => Upload extended spots and noise data.  Upload spots directly to wsprnet.org
                                   ### SIGNAL_LEVEL_UPLOAD_MODE="proxy" => In addition to "noise", don't upload to wsprnet.org from this server.  Regenerate and upload spots to wsprnet.org on the wsprdaemon.org server
#SIGNAL_LEVEL_UPLOAD="yes"          ### If this variable is defined as "yes" AND SIGNAL_LEVEL_UPLOAD_ID is defined, then upload extended spots and noise levels to the logs.wsprdaemon.org database and graphics file server.
#SIGNAL_LEVEL_UPLOAD_ID="AI6VN"     ### The name put in upload log records, the the title bar of the graph, and the name used to view spots and noise at that server.
#SIGNAL_LEVEL_UPLOAD_GRAPHS="yes"   ### If this variable is defined as "yes" AND SIGNAL_LEVEL_UPLOAD_ID is defined, then FTP graphs of the last 24 hours to http://wsprdaemon.org/graphs/SIGNAL_LEVEL_UPLOAD_ID
#SIGNAL_LEVEL_LOCAL_GRAPHS="yes"    ### If this variable is defined as "yes" AND SIGNAL_LEVEL_UPLOAD_ID is defined, then make graphs visible at http://localhost/

##############################################################
### The RECEIVER_LIST() array defines the physical (KIWI_xxx,AUDIO_xxx,SDR_xxx) and logical (MERG...) receive devices available on this server
### Each element of RECEIVER_LIST is a string with 5 space-seperated fields:
###   " ID(no spaces)             IP:PORT or RTL:n    MyCall       MyGrid  KiwPassword    Optional SIGNAL_LEVEL_ADJUSTMENTS
###                                                                                       [[DEFAULT:ADJUST,]BAND_0:ADJUST[,BAND_N:ADJUST_N]...]
###                                                                                       A comma-separated list of BAND:ADJUST pairs
###                                                                                       BAND is one of 2200..10, while ADJUST is in dBs TO BE ADDED to the raw data 
###                                                                                       So If you have a +10 dB LNA, ADJUST '-10' will LOWER the reported level so that your reports reflect the level at the input of the LNA
###                                                                                       DEFAULT defaults to zero and is applied to all bands not specified with a BAND:ADJUST

declare RECEIVER_LIST=(
        "KIWI_0                  10.11.12.100:8073     AI6VN         CM88mc    NULL"
        "KIWI_1                  10.11.12.101:8073     AI6VN         CM88mc  foobar       DEFAULT:-10,80:-12,30:-8,20:2,15:6"
        "KIWI_2                  10.11.12.102:8073     AI6VN         CM88mc  foobar"
        "AUDIO_0                     localhost:0,0     AI6VN         CM88mc  foobar"               ### The id AUDIO_xxx is special and defines a local audio input device as the source of WSPR baseband 1400-1600 Hz signals
        "AUDIO_1                     localhost:1,0     AI6VN         CM88mc  foobar"  
        "SDR_0                           RTL-SDR:0     AI6VN         CM88mc  foobar"               ### The id SDR_xxx   is special and defines a local RTL-SDR or other Soapy-suported device
        "SDR_1                           RTL-SDR:1     AI6VN         CM88mc  foobar"
        "MERG_0    KIWI_1,KIWI2,AUDIO_1,SDR_1     AI6VN         CM88mc  foobar"
)

### This table defines a schedule of configurations which will be applied by '-j a,all' and thus by the watchdog daemon when it runs '-j a,all' ev ery odd two minutes
### The first field of each entry in the start time for the configuration defined in the following fields
### Start time is in the format HH:MM (e.g 13:15) and by default is in the time zone of the host server unless ',UDT' is appended, e.g '01:30,UDT'
### Following the time are one or more fields of the format 'RECEIVER,BAND'
### If the time of the first entry is not 00:00, then the latest (not necessarily the last) entry will be applied at time 00:00
### So the form of each line is  "START_HH:MM[,UDT]   RECEIVER,BAND... ".  Here are some examples:

declare WSPR_SCHEDULE_simple=(
    "00:00                       KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
)

declare WSPR_SCHEDULE_merged=(
    "00:00                       MERG_0,630 MERG_0,160"
)

declare WSPR_SCHEDULE_complex=(
    "sunrise-01:00               KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12          "
    "sunrise+01:00                          KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "09:00                       KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12          "
    "10:00                                  KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "11:00                                             KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "18:00           KIWI_0,2200 KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15                    "
    "sunset-01:00                           KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "sunset+01:00                KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
)

### This array WSPR_SCHEDULE defines the running configuration.  Here we make the simple configuration defined above the active one:
declare WSPR_SCHEDULE=( "${WSPR_SCHEDULE_simple[@]}" )

EOF

fi
 
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

declare ASTRAL_SUN_TIMES_SCRIPT=${WSPRDAEMON_TMP_DIR}/suntimes.py
function get_astral_sun_times() {
    local lat=$1
    local lon=$2
    local zone=$3

    ## This is run only once every 24 hours, so recreate it to be sure it is from this version of WD
    cat > ${ASTRAL_SUN_TIMES_SCRIPT} << EOF
import datetime, sys
from astral import Astral, Location
from datetime import date
lat=float(sys.argv[1])
lon=float(sys.argv[2])
zone=sys.argv[3]
l = Location(('wsprep', 'local', lat, lon, zone, 0))
l.sun()
d = date.today()
sun = l.sun(local=True, date=d)
print( str(sun['sunrise'])[11:16] + " " + str(sun['sunset'])[11:16] )
EOF
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

    [[ $verbosity -ge 2 ]] && echo "$(date): truncate_file() '${file_path}' of size ${file_size} bytes to max size of ${file_max_size} bytes"
    
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
        check_for_kiwirecorder_cmd
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
declare FFT_WINDOW_CMD=${WSPRDAEMON_TMP_DIR}/wav_window.py

declare C2_FFT_ENABLED="yes"          ### If "yes", then use the c2 file produced by wsprd to calculate FFT noisae levels
declare C2_FFT_CMD=${WSPRDAEMON_TMP_DIR}/c2_noise.py

function decode_create_c2_fft_cmd() {
    cat > ${C2_FFT_CMD} <<EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Filename: c2_noise.py
# Program to extract the noise level from the 'wsprd -c' C2 format file
## V1 by Christoph Mayer. This version V1.1 by Gwyn Griffiths to output a single value
## being the total power (dB arbitary scale) in the lowest 30% of the Fourier coefficients
## between 1369.5 and 1630.5 Hz where the passband is flat.

import struct
import sys
import numpy as np

fn = sys.argv[1] ## '000000_0001.c2'

with open(fn, 'rb') as fp:
     ## decode the header:
     filename,wspr_type,wspr_freq = struct.unpack('<14sid', fp.read(14+4+8))

     ## extract I/Q samples
     samples = np.fromfile(fp, dtype=np.float32)
     z = samples[0::2]+1j*samples[1::2]
     #print(filename,wspr_type,wspr_freq,samples[:100], len(samples), z[:10])

     ## z contains 45000 I/Q samples
     ## we perform 180 FFTs, each 250 samples long
     a     = z.reshape(180,250)
     a    *= np.hanning(250)
     freqs = np.arange(-125,125, dtype=np.float32)/250*375 ## was just np.abs, square to get power
     w     = np.square(np.abs(np.fft.fftshift(np.fft.fft(a, axis=1), axes=1)))
     ## these expressions first trim the frequency range to 1369.5 to 1630.5 Hz to ensure
     ## a flat passband without bias from the shoulders of the bandpass filter
     ## i.e. array indices 38:213
     w_bandpass=w[0:179,38:213]
     ## partitioning is done on the flattened array of coefficients
     w_flat_sorted=np.partition(w_bandpass, 9345, axis=None)
     noise_level_flat=10*np.log10(np.sum(w_flat_sorted[0:9344]))
     print(' %6.2f' % (noise_level_flat))
EOF
    chmod +x ${C2_FFT_CMD}
}


function decode_create_hanning_window_cmd() {
    cat > ${FFT_WINDOW_CMD} <<EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Filename: wav_window_v1.py
# January  2020  Gwyn Griffiths
# Program to apply a Hann window to a wsprdaemon wav file for subsequent processing by sox stat -freq (initially at least)
 
from __future__ import print_function
import math
import scipy
import scipy.io.wavfile as wavfile
import numpy as np
import wave
import sys

WAV_INPUT_FILENAME=sys.argv[1]
WAV_OUTPUT_FILENAME=sys.argv[2]

# Set up the audio file parameters for windowing
# fs_rate is passed to the output file
fs_rate, signal = wavfile.read(WAV_INPUT_FILENAME)   # returns sample rate as int and data as numpy array
# set some constants
N_FFT=352                                   # this being the number expected
N_FFT_POINTS=4096                           # number of input samples in each sox stat -freq FFT (fixed)
                                            # so N_FFT * N_FFT_POINTS = 1441792 samples, which at 12000 samples per second is 120.15 seconds
                                            # while we have only 120 seconds, so for now operate with N_FFT-1 to have all filled
                                            # may decide all 352 are overkill anyway
N=N_FFT*N_FFT_POINTS
w=np.zeros(N_FFT_POINTS)

output=np.zeros(N, dtype=np.int16)          # declaring as dtype=np.int16 is critical as the wav file needs to be 16 bit integers

# create a N_FFT_POINTS array with the Hann weighting function
for i in range (0, N_FFT_POINTS):
  x=(math.pi*float(i))/float(N_FFT_POINTS)
  w[i]=np.sin(x)**2

for j in range (0, N_FFT-1):
  offset=j*N_FFT_POINTS
  for i in range (0, N_FFT_POINTS):
     output[i+offset]=int(w[i]*signal[i+offset])
wavfile.write(WAV_OUTPUT_FILENAME, fs_rate, output)
EOF
    chmod +x ${FFT_WINDOW_CMD}
}

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
    if [[ ${verbosity} -ge 0 ]]; then
            echo "decoding_daemon() calculated the Kiwi to require a ${kiwi_amplitude_versus_frequency_correction} dB correction in this band
            Adding to that the antenna factor of ${antenna_factor_adjust} dB to results in a total correction of ${total_correction_db}
            rms_adjust=${rms_adjust} comes from ${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}
            fft_adjust=${fft_adjust} comes from ${cal_fft_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db} + ${cal_fft_band} + ${cal_threshold}
            rms_adjust and fft_adjust will be ADDed to the raw dB levels"
    fi
    ## G3ZIL implementation of algorithm using the c2 file by Christoph Mayer
    local c2_FFT_nl_adjust=$(bc <<< "scale = 2;var=${cal_c2_correction};var+=${total_correction_db}; (var * 100)/100")   # comes from a configured value.  'scale = 2; (var * 100)/100' forces bc to ouput only 2 digits after decimal
    [[ ${verbosity} -ge 2 ]] && "$(date): decoding_daemon() c2_FFT_nl_adjust = ${c2_FFT_nl_adjust} from 'local c2_FFT_nl_adjust=\$(bc <<< 'var=${cal_c2_correction};var+=${total_correction_db};var')"  # value estimated
    decode_create_c2_fft_cmd
    decode_create_hanning_window_cmd

    [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): starting daemon to record '${real_receiver_name},${real_receiver_rx_band}'"
    local decoded_spots=0        ### Maintain a running count of the total number of spots_decoded
    local old_wsprd_decoded_spots=0   ### If we are comparing the new wsprd against the old wsprd, then this will count how many were decoded by the old wsprd

    cd ${real_recording_dir}
    local old_kiwi_ov_lines=0
    rm -f *.raw *.wav
    shopt -s nullglob
    while [[  -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; do    ### Keep decoding as long as there is at least one posting_daemon client
        [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon() checking recording process is running in $PWD"
        spawn_recording_daemon ${real_receiver_name} ${real_receiver_rx_band}
        [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon() checking for *.wav' files in $PWD"
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
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): timeout waiting for a wav file, so copy a zero length ${new_spots_file} to ${dir}/ monitored by a posting daemon"
                cp -p ${new_spots_file} ${dir}/
            done
            rm ${new_spots_file} 
            [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon() found no wav files. Sleeping until next even minute."
            local next_start_time_string=$(sleep_until_next_even_minute)
        done
        for wav_file_name in *.wav; do
            [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): monitoring size of wav file '${wav_file_name}'"

            ### Wait until the wav_file_name size isn't changing, i.e. kiwirecorder.py has finished writting this 2 minutes of capture and has moved to the next wav_file_name
            local old_wav_file_size=0
            local new_wav_file_size=$( ${GET_FILE_SIZE_CMD} ${wav_file_name} )
            while [[ -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]] && [[ ${new_wav_file_size} -ne ${old_wav_file_size} ]]; do
                old_wav_file_size=${new_wav_file_size}
                sleep ${WAV_FILE_POLL_SECONDS}
                new_wav_file_size=$( ${GET_FILE_SIZE_CMD} ${wav_file_name} )
                [[ ${verbosity} -ge 4 ]] && echo "$(date): decoding_daemon(): old size ${old_wav_file_size}, new size ${new_wav_file_size}"
            done
            if [[ -z "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): wav file size loop terminated due to no posting.d subdir"
                break
            fi
            [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): wav file '${wav_file_name}' stabilized at size ${new_wav_file_size}."
            if  [[ ${new_wav_file_size} -lt ${WSPRD_WAV_FILE_MIN_VALID_SIZE} ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): wav file '${wav_file_name}' size ${new_wav_file_size} is too small to be processed by wsprd.  Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi

            local wspr_decode_capture_date=${wav_file_name/T*}
            wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
            local wspr_decode_capture_time=${wav_file_name#*T}
            wspr_decode_capture_time=${wspr_decode_capture_time/Z*}
            local wspr_decode_capture_sec=${wspr_decode_capture_time:4}
            if [[ ${wspr_decode_capture_sec} != "00" ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): wav file '${wav_file_name}' size ${new_wav_file_size} shows that recording didn't start at second "00". Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi
            local wspr_decode_capture_min=${wspr_decode_capture_time:2:2}
            if [[ ! ${wspr_decode_capture_min:1} =~ [02468] ]]; then
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): wav file '${wav_file_name}' size ${new_wav_file_size} shows that recording didn't start on an even minute. Delete this file and go to next wav file."
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
                [[ ${verbosity} -ge 1 ]] && echo "$(date): decoding_daemon(): ALL_WSPR.TXT has grown too large, so truncating it"
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
                    [[ ${verbosity} -ge 1 ]] && echo -e "$(date): decoding_daemon(): 'wsprd' timeout with ret_code = ${ret_code} after ${run_time} seconds"
                else
                    [[ ${verbosity} -ge 1 ]] && echo -e "$(date): decoding_daemon(): 'wsprd' retuned error ${ret_code} after ${run_time} seconds.  It printed:\n$(cat ${WSPRD_DECODES_FILE})"
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
                    [[ ${verbosity} -ge 0 ]] && printf "$(date): decoding_daemon(): WARNING:  wsprd created a wspr_spots.txt with corrupt line(s):\n%s" "${bad_wsprd_lines}"
                fi

                local new_spots=$(wc -l wspr_spots.txt)
                decoded_spots=$(( decoded_spots + ${new_spots/ *} ))
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): decoded ${new_spots/ *} new spots.  ${decoded_spots} spots have been decoded since this daemon started"

                ### Since they are so computationally and storage space cheap, always calculate a C2 FFT noise level
                local c2_filename="000000_0001.c2" ### -c instructs wsprd to create the C2 format file "000000_0001.c2"
                /usr/bin/python2 ${C2_FFT_CMD} ${c2_filename}  > c2_FFT.txt 
                local c2_FFT_nl=$(cat c2_FFT.txt)
                local c2_FFT_nl_cal=$(bc <<< "scale=2;var=${c2_FFT_nl};var+=${c2_FFT_nl_adjust};(var * 100)/100")
                [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): c2_FFT_nl_cal=${c2_FFT_nl_cal} which is calculated from 'local c2_FFT_nl_cal=\$(bc <<< 'scale=2;var=${c2_FFT_nl};var+=${c2_FFT_nl_adjust};var/=1;var')"
                if [[ ${verbosity} -ge 1 ]] && [[ -x ${WSPRD_PREVIOUS_CMD} ]]; then
                    mkdir -p wsprd.old
                    cd wsprd.old
                    timeout ${WSPRD_TIMEOUT_SECS-60} nice ${WSPRD_PREVIOUS_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ../${wsprd_input_wav_filename} > wsprd_decodes.txt
                    local ret_code=$?

                    if [[ ${ret_code} -ne 0 ]]; then
                        [[ ${verbosity} -ge 1 ]] && echo "$(date): decoding_daemon(): error ${ret_code} reported running old wsprd"
                        cd - > /dev/null
                    else
                        local old_wsprd_spots=$(wc -l wspr_spots.txt)
                        old_wsprd_decoded_spots=$(( old_wsprd_decoded_spots + ${old_wsprd_spots/ *} ))
                        [[ ${verbosity} -ge 1 ]] && echo "$(date): decoding_daemon(): new wsprd decoded ${new_spots/ *} new spots, ${decoded_spots} total spots.  Old wsprd decoded  ${old_wsprd_spots/ *} new spots, ${old_wsprd_decoded_spots} total spots"
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

            # Get RMS levels from the wav file and adjuest them to correct for the effects of the LPF on the Kiwi's input
            local pre_tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_PRE_TX_SEC} ${SIGNAL_LEVEL_PRE_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): raw   pre_tx_levels  levels '${pre_tx_levels[@]}'"
            local i
            for i in $(seq 0 $(( ${#pre_tx_levels[@]} - 1 )) ); do
                pre_tx_levels[${i}]=$(bc <<< "scale = 2; (${pre_tx_levels[${i}]} + ${rms_adjust})/1")           ### '/1' forces bc to use the scale = 2 setting
            done
            [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): fixed pre_tx_levels  levels '${pre_tx_levels[@]}'"
            local tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_TX_SEC} ${SIGNAL_LEVEL_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            for i in $(seq 0 $(( ${#tx_levels[@]} - 1 )) ); do
                tx_levels[${i}]=$(bc <<< "scale = 2; (${tx_levels[${i}]} + ${rms_adjust})/1")                   ### '/1' forces bc to use the scale = 2 setting
            done
            local post_tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_POST_TX_SEC} ${SIGNAL_LEVEL_POST_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): raw   post_tx_levels levels '${post_tx_levels[@]}'"
            for i in $(seq 0 $(( ${#post_tx_levels[@]} - 1 )) ); do
                post_tx_levels[${i}]=$(bc <<< "scale = 2; (${post_tx_levels[${i}]} + ${rms_adjust})/1")         ### '/1' forces bc to use the scale = 2 setting
            done
            [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): fixed post_tx_levels levels '${post_tx_levels[@]}'"

            local rms_value=${pre_tx_levels[3]}                                           # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
            if [[  $(bc --mathlib <<< "${post_tx_levels[3]} < ${pre_tx_levels[3]}") -eq "1" ]]; then
                rms_value=${post_tx_levels[3]}
                [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): rms_level is from post"
            else
                [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): rms_level is from pre"
            fi
            [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): rms_value=${rms_value}"

            if [[ ${SIGNAL_LEVEL_UPLOAD-no} == "no" ]] || [[ ${SIGNAL_LEVEL_SOX_FFT_STATS-no} == "no" ]]; then
                ### Don't spend a lot of CPU time calculating a value which will not be uploaded
                local fft_value="-999.9"      ## i.e. "Not Calculated"
            else
                # Apply a Hann window to the wav file in 4096 sample blocks to match length of the FFT in sox stat -freq
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): applying windowing to .wav file '${wsprd_input_wav_filename}'"
                rm -f *.tmp    ### Flush zombie wav.tmp files, if any were left behind by a previous run of this daemon
                local windowed_wav_file=${wsprd_input_wav_filename/.wav/.tmp}
                /usr/bin/python3 ${FFT_WINDOW_CMD} ${wsprd_input_wav_filename} ${windowed_wav_file}
                mv ${windowed_wav_file} ${wsprd_input_wav_filename}

                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): running 'sox FFT' on .wav file '${wsprd_input_wav_filename}'"
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
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): decoding_daemon(): WARNING: ${WSPRDAEMON_TMP_DIR} is ${tmp_percent_used}% full.  Increase its size in /etc/fstab!"
                fi
                rm sox_fft.txt                                                               # Get rid of that 15 MB fft file ASAP
                nice sort -g -k 2 < sox_fft_trimmed.txt > sox_fft_sorted.txt                 # sort those numerically on the second field, i.e. fourier coefficient  ascending
                rm sox_fft_trimmed.txt                                                       # This is much smaller, but don't need it again
                local hann_adjust=6.0
                local fft_value=$(nice awk -v fft_adj=${fft_adjust} -v hann_adjust=${hann_adjust} '{ s += $2} NR > 11723 { print ( (0.43429 * 10 * log( s / 2147483647)) + fft_adj + hann_adjust) ; exit }'  sox_fft_sorted.txt)
                                                                                             # The 0.43429 is simply awk using natual log
                                                                                             #  the denominator in the sq root is the scaling factor in the text info at the end of the ftt file
                rm sox_fft_sorted.txt
                [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): sox_fft_value=${fft_value}"
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
            [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): noise was: '${signal_level_line}'"

            rm -f ${wav_file_name} ${wsprd_input_wav_filename}  ### We have completed processing the wav file, so delete both names for it

            ### 'wsprd' appends the new decodes to ALL_WSPR.TXT, but we are going to post only the new decodes which it puts in the file 'wspr_spots.txt'
            update_hashtable_archive ${real_receiver_name} ${real_receiver_rx_band}

            ### Forward the recording's date_time_freqHz spot file to the posting daemon which is polling for it.  Do this here so that it is after the very slow sox FFT calcs are finished
            local new_spots_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_spots.txt
            if [[ ! -f wspr_spots.txt ]] || [[ ! -s wspr_spots.txt ]]; then
                ### A zero length spots file signals the posting daemon that decodes are complete but no spots were found
                rm -f ${new_spots_file}
                touch  ${new_spots_file}
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon():no spots were found.  Queuing zero length spot file '${new_spots_file}'"
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
                    [[ ${verbosity} -ge 0 ]] && printf "$(date): decoding_daemon(): WARNING: the ${new_spots_count} spot lines in wspr_spots.txt don't match the ${all_wspr_new_date_lines_count} spots with the same date in ALL_WSPR.TXT\n"
                fi

                ### Cull corrupt lines from ALL_WSPR.TXT
                local all_wspr_bad_new_lines=$(awk 'NF < 16 || NF > 17 || $5 < 0.1' <<< "${all_wspr_new_lines}")
                if [[ -n "${all_wspr_bad_new_lines}" ]]; then
                    [[ ${verbosity} -ge 0 ]] && printf "$(date): decoding_daemon(): WARNING: removing corrupt line(s) in ALL_WSPR.TXT:\n%s\n" "${all_wspr_bad_new_lines}"
                    all_wspr_new_lines=$(awk 'NF >= 16 && NF <=  17 && $5 >= 0.1' <<< "${all_wspr_new_lines}")
                fi

                [[ ${verbosity} -ge 2 ]] && echo -e "$(date): decoding_daemon() processing these ALL_WSPR.TXT lines:\n${all_wspr_new_lines}"
                local WSPRD_2_2_FIELD_COUNT=17   ## wsprd in wsjt-x v2.2 outputs 17 fields in a slightly different order than the 15 fields output by wsprd v2.1
                local WSPRD_2_2_WITHOUT_GRID_FIELD_COUNT=16   ## wsprd in wsjt-x v2.2 outputs 17 fields in a slightly different order than the 15 fields output by wsprd v2.1
                # fprintf(fall_wspr, "%6s              %4s                                      %3.0f          %5.2f           %11.7f               %-22s                    %2d            %5.2f                          %2d                   %2d                %4d                    %2d                  %3d                   %5u                %5d\n",
		# 2.2.x:     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].sync,          decodes[i].ipass+1, decodes[i].blocksize, decodes[i].jitter, decodes[i].decodetype, decodes[i].nhardmin, decodes[i].cycles/81, decodes[i].metric);
		# 2.2.x with grid:     200724 1250 -24  0.24  28.1260734  M0UNI IO82 33           0  0.23  1  1    0  1  45     1   810
		# 2.2.x without grid:  200721 0800  -7  0.15  28.1260594  DC7JZB/B 27            -1  0.68  1  1    0  0   0     1   759
		local spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields
		while read  spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields ; do
		    [[ ${verbosity} -ge 2 ]] && echo -e "$(date): decoding_daemon() read this V2.2 format ALL_WSPR.TXT line: '${spot_date}' '${spot_time}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${other_fields}'"
		    local spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype spot_nhardmin spot_decode_cycles spot_metric

		    local other_fields_list=( ${other_fields} )
		    local other_fields_list_count=${#other_fields_list[@]}

		    local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID=11
		    local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID=10
                    local got_valid_line="yes"
		    if [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID} ]]; then
		        read spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric <<< "${other_fields}"
                        [[ ${verbosity} -ge 2 ]] && echo -e "$(date): decoding_daemon() this V2.2 type 1 ALL_WSPR.TXT line has GRID: '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' '${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
		    elif [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
                        spot_grid=""
                        read spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric <<< "${other_fields}"
                        [[ ${verbosity} -ge 2 ]] && echo -e "$(date): decoding_daemon() this V2.2 type 2 ALL_WSPR.TXT line has no GRID: '${spot_date}' '${spot_time}' '${spot_sync_quality}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' ${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
                    else
                        [[ ${verbosity} -ge 0 ]] && echo -e "$(date): decoding_daemon() WARNING: tossing  a corrupt (not the expected 15 or 16 fields) ALL_WSPR.TXT spot line"
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
                [[ ${verbosity} -ge 2 ]] && printf "$(date): decoding_daemon(): queuing enhanced spot file:\n$(cat ${new_spots_file})\n"
            fi

            ### Copy the noise level file and the renamed wspr_spots.txt to waiting posting daemons' subdirs
            shopt -s nullglob    ### * expands to NULL if there are no .wav wav_file
            local dir
            for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
                ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
                [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): copying ${new_spots_file} and ${new_noise_file} to ${dir}/ monitored by a posting daemon" 
                cp -p ${new_spots_file} ${new_noise_file} ${dir}/
            done
            rm ${new_spots_file} ${new_noise_file}
        done
        [[ ${verbosity} -ge 3 ]] && echo "$(date): decoding_daemon(): decoding_daemon() decoded and posted ALL_WSPR file."
        sleep 1   ###  No need for a long sleep, since recording daemon should be creating next wav file and this daemon will poll on the size of that wav file
    done
    [[ ${verbosity} -ge 2 ]] && echo "$(date): decoding_daemon(): stopping recording and decoding of '${real_receiver_name},${real_receiver_rx_band}'"
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
    decoding_daemon ${receiver_name} ${receiver_rx_band} > decode.log 2>&1 &
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
    
    ### This Python command creates the enhanced azi infomation added to each spot
    create_azi_python

    ### Where to put the spots from the one or more real receivers for the upload daemon to find
    local  wsprnet_upload_dir=${UPLOADS_WSPRNET_SPOTS_DIR}/${my_call_sign//\//=}_${my_grid}/${posting_receiver_name}/${posting_receiver_band}  ## many ${my_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
    mkdir -p ${wsprnet_upload_dir}

    ### Create a /tmp/.. dir where this instance of the daemon will process and merge spotfiles.  Then it will copy them to the uploads.d directory in a persistent file system
    local posting_receiver_dir_path=$PWD
    [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() starting to post '${posting_receiver_name},${posting_receiver_band}' in '${posting_receiver_dir_path}' and copy spots from real_rx(s) '${real_receiver_list[@]}' to '${wsprnet_upload_dir}"

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
        [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() created a symlink from ${this_rx_local_dir_name} to ${real_receiver_posting_dir_path}"
    done

    shopt -s nullglob    ### * expands to NULL if there are no file matches
    local daemon_stop="no"
    while [[ ${daemon_stop} == "no" ]]; do
        [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() starting check for all posting subdirs to have a YYMMDD_HHMM_wspr_spots.txt file in them"
        local newest_all_wspr_file_path=""
        local newest_all_wspr_file_name=""

        ### Wait for all of the real receivers to decode ands post a *_wspr_spots.txt file
        local waiting_for_decodes=yes
        local printed_waiting=no   ### So we print out the 'waiting...' message only once at the start of each wait cycle
        while [[ ${waiting_for_decodes} == "yes" ]]; do
            ### Start or keep alive decoding daemons for each real receiver
            local real_receiver_name
            for real_receiver_name in ${real_receiver_list[@]} ; do
                [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() checking or starting decode daemon for real receiver ${real_receiver_name} ${posting_receiver_band}"
                ### '(...) runs in subshell so it can't change the $PWD of this function
                (spawn_decode_daemon ${real_receiver_name} ${posting_receiver_band}) ### Make sure there is a decode daemon running for this receiver.  A no-op if already running
            done

            [[ ${verbosity} -ge 3 ]] && [[ ${printed_waiting} == "no" ]] && printed_waiting=yes && echo "$(date): posting_daemon() checking for subdirs to have the same *_wspr_spots.txt in them" 
            waiting_for_decodes=yes
            newest_all_wspr_file_path=""
            local posting_dir
            for posting_dir in ${posting_source_dir_list[@]}; do
                [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() checking dir ${posting_dir} for wspr_spots.txt files"
                if [[ ! -d ${posting_dir} ]]; then
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() expected posting dir ${posting_dir} does not exist, so exiting inner for loop"
                    daemon_stop="yes"
                    break
                fi
                for file in ${posting_dir}/*_wspr_spots.txt; do
                    if [[ -z "${newest_all_wspr_file_path}" ]]; then
                        [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() found first wspr_spots.txt file ${file}"
                        newest_all_wspr_file_path=${file}
                    elif [[ ${file} -nt ${newest_all_wspr_file_path} ]]; then
                        [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() found ${file} is newer than ${newest_all_wspr_file_path}"
                        newest_all_wspr_file_path=${file}
                    else
                        [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() found ${file} is older than ${newest_all_wspr_file_path}"
                    fi
                done
            done
            if [[ ${daemon_stop} != "no" ]]; then
                [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() the expected posting dir ${posting_dir} does not exist, so exiting inner while loop"
                daemon_stop="yes"
                break
            fi
            if [[ -z "${newest_all_wspr_file_path}" ]]; then
                [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() found no wspr_spots.txt files"
            else
                [[ ${verbosity} -ge 3 ]] && printed_waiting=no   ### We have found some spots.txt files, so signal to print 'waiting...' message at the start of the next wait cycle
                newest_all_wspr_file_name=${newest_all_wspr_file_path##*/}
                [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() found newest wspr_spots.txt == ${newest_all_wspr_file_path} => ${newest_all_wspr_file_name}"
                ### Flush all *wspr_spots.txt files which don't match the name of this newest file
                local posting_dir
                for posting_dir in ${posting_source_dir_list[@]}; do
                    cd ${posting_dir}
                    local file
                    for file in *_wspr_spots.txt; do
                        if [[ ${file} != ${newest_all_wspr_file_name} ]]; then
                            [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() is flushing file ${posting_dir}/${file} which doesn't match ${newest_all_wspr_file_name}"
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
                        [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() found no file ${posting_dir}/${newest_all_wspr_file_name}"
                    else
                        [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() found    file ${posting_dir}/${newest_all_wspr_file_name}"
                    fi
                done
            fi
            if [[  ${waiting_for_decodes} == "yes" ]]; then
                [[ ${verbosity} -ge 4 ]] && echo "$(date): posting_daemon() is waiting for files. Sleeping..."
                sleep ${WAV_FILE_POLL_SECONDS}
            else
                [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() found the required ${newest_all_wspr_file_name} in all the posting subdirs, so can merge and post"
            fi
        done
        if [[ ${daemon_stop} != "no" ]]; then
            [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() exiting outer while loop"
            break
        fi
        ### All of the ${real_receiver_list[@]} directories have *_wspr_spot.txt files with the same time&name

        ### Clean out any older *_wspr_spots.txt files
        [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() flushing old *_wspr_spots.txt files"
        local posting_source_dir
        local posting_source_file
        for posting_source_dir in ${posting_source_dir_list[@]} ; do
            cd -P ${posting_source_dir}
            for posting_source_file in *_wspr_spots.txt ; do
                if [[ ${posting_source_file} -ot ${newest_all_wspr_file_path} ]]; then
                    [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() is flushing file ${posting_source_file} which is older than the newest complete set of *_wspr_spots.txt files"
                    rm $posting_source_file
                else
                    [[ ${verbosity} -ge 3 ]] && echo "$(date): posting_daemon() is preserving file ${posting_source_file} which is same or newer than the newest complete set of *_wspr_spots.txt files"
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
            [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() no spots were decoded"
            wsprd_spots_best_file_path=${wsprd_spots_all_file_path}
        else
            ### At least one of the real receiver decoder reported a spot. Create a spot file with only the strongest SNR for each call sign
             wsprd_spots_best_file_path=${posting_receiver_dir_path}/wspr_spots.txt.BEST

            if [[ ${verbosity} -ge 2 ]]; then
                echo "$(date): posting_daemon() merging and sorting files '${newest_list[@]}' to ${wsprd_spots_all_file_path}"
                echo "$(date): posting_daemon() cat ${newest_list[@]} > ${wsprd_spots_all_file_path}.  Files contain spots:"
                ${GREP_CMD} . ${newest_list[@]}
                printf ">>>>>>>> which were put into '${wsprd_spots_all_file_path}' which contains:\n$( cat ${wsprd_spots_all_file_path})\n=============\n"
            fi

            ### Get a list of all calls found in all of the receiver's decodes
            local posting_call_list=$( cat ${wsprd_spots_all_file_path} | awk '{print $7}'| sort -u )
            [[ ${verbosity} -ge 3 ]] && [[ -n "${posting_call_list}" ]] && echo "$(date): posting_daemon() found this set of unique calls: '${posting_call_list}'"

            ### For each of those calls, get the decode line with the highest SNR
            rm -f best_snrs.tmp
            touch best_snrs.tmp
            local call
            for call in ${posting_call_list}; do
                ${GREP_CMD} " ${call} " ${wsprd_spots_all_file_path} | sort -k4,4n | tail -n 1 > this_calls_best_snr.tmp  ### sorts by SNR and takes only the highest
                cat this_calls_best_snr.tmp >> best_snrs.tmp
                [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() found the best SNR report for call '${call}' was '$(cat this_calls_best_snr.tmp)'"
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
            if [[ ${verbosity} -ge 1 ]]; then
                if [[ -s ${upload_wsprnet_file_path} ]]; then
                    echo -e "$(date): posting_daemon() moved ${wsprd_spots_best_file_path} to ${upload_wsprnet_file_path} which contains spots:\n$(cat ${upload_wsprnet_file_path})"
                else
                    echo -e "$(date): posting_daemon() created zero length spot file ${upload_wsprnet_file_path}"
                fi
            fi
        else
            ### This real rx is a member of a MERGed rx, so its spots are being merged with other real rx
            [[ ${verbosity} -ge 1 ]] && echo "$(date): posting_daemon() not queuing ${wsprd_spots_best_file_path} for upload to wsprnet.org since this rx is not a member of RUNNING_JOBS '${RUNNING_JOBS[@]}'"
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
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): posting_daemon() INTERNAL ERROR: found real rx dir ${real_receiver_dir} has no *_wspr_spots.txt file."
                else
                    [[ ${verbosity} -ge 1 ]] && echo "$(date): posting_daemon() INTERNAL ERROR: found real rx dir ${real_receiver_dir} has ${real_receiver_wspr_spots_file_count} spot files. Flushing them."
                    rm -f ${real_receiver_wspr_spots_file_list[@]}
                fi
            else
                ### There is one spot file for this rx
                local real_receiver_wspr_spots_file=${real_receiver_wspr_spots_file_list[0]}
                local filtered_receiver_wspr_spots_file="filtered_spots.txt"   ### Remove all but the strongest SNR for each CALL
                rm -f ${filtered_receiver_wspr_spots_file}
                touch ${filtered_receiver_wspr_spots_file}    ### In case there are no spots in the real rx
                if [[ ! -s ${real_receiver_wspr_spots_file} ]]; then
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() spot file has no spots, but copy it to the upload directory so upload_daemon knows that this wspr cycle decode has been completed"
                else
                    [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() queue real rx spots file '${real_receiver_wspr_spots_file}' for upload to wsprdaemon.org"
                    ### Make sure there is only one spot for each CALL in this file.
                    ### Get a list of all calls found in all of the receiver's decodes
                    local posting_call_list=$( cat ${real_receiver_wspr_spots_file} | awk '{print $7}'| sort -u )
                    [[ ${verbosity} -ge 3 ]] && [[ -n "${posting_call_list}" ]] && echo "$(date): posting_daemon() found this set of unique calls: '${posting_call_list}'"

                    ### For each of those calls, get the decode line with the highest SNR
                    rm -f best_snrs.tmp
                    touch best_snrs.tmp       ## In case there are no calls, ensure there is a zero length file
                    local call
                    for call in ${posting_call_list}; do
                        ${GREP_CMD} " ${call} " ${real_receiver_wspr_spots_file} | sort -k4,4n | tail -n 1 > this_calls_best_snr.tmp  ### sorts by SNR and takes only the highest
                        cat this_calls_best_snr.tmp >> best_snrs.tmp
                        [[ ${verbosity} -ge 2 ]] && echo "$(date): posting_daemon() found the best SNR report for call '${call}' was '$(cat this_calls_best_snr.tmp)'"
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

    rm -f ${real_receiver_enhanced_wspr_spots_file}
    touch ${real_receiver_enhanced_wspr_spots_file}
    local spot_line
    while read spot_line ; do
        [[ ${verbosity} -ge 3 ]] && echo "$(date): create_enhanced_spots_file() enhance line '${spot_line}'"
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
            [[ ${verbosity} -ge 1 ]] && echo "$(date): create_enhanced_spots_file()  INTERNAL ERROR: unexpected number of fields ${spot_line_list_count} rather than the expected ${FIELD_COUNT_DECODE_LINE_WITH_GRID} or ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} in wsprnet format spot line '${spot_line}'" 
            return 1
        fi
        ### G3ZIL 
        ### April 2020 V1    add azi
        [[ ${verbosity} -ge 3 ]] && echo "$(date): create_enhanced_spots_file() 'add_derived ${spot_grid} ${my_grid} ${spot_freq}'"
        add_derived ${spot_grid} ${my_grid} ${spot_freq}
        if [[ ! -f ${DERIVED_ADDED_FILE} ]] ; then
            [[ ${verbosity} -ge 1 ]] && echo "$(date): create_enhanced_spots_file() spots.txt $INPUT file not found"
            return 1
        fi
        local derived_fields=$(cat ${DERIVED_ADDED_FILE} | tr -d '\r')
        derived_fields=${derived_fields//,/ }   ### Strip out the ,s
        [[ ${verbosity} -ge 3 ]] && echo "$(date): create_enhanced_spots_file() derived_fields='${derived_fields}'"

        local band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon
        read band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${derived_fields}"

        ### Output a space-seperated line of enhanced spot data.  The first 13/14 fields are in the same order as in the ALL_WSPR.TXT and wspr_spot.txt files created by 'wsprd'
        echo "${spot_date} ${spot_time} ${spot_sync_quality} ${spot_snr} ${spot_dt} ${spot_freq} ${spot_call} ${spot_grid} ${spot_pwr} ${spot_drift} ${spot_decode_cycles} ${spot_jitter} ${spot_blocksize} ${spot_metric} ${spot_osd_decode} ${spot_ipass} ${spot_nhardmin} ${spot_for_wsprnet} ${spot_rms_noise} ${spot_c2_noise} ${band} ${my_grid} ${my_call_sign} ${km} ${rx_az} ${rx_lat} ${rx_lon} ${tx_az} ${tx_lat} ${tx_lon} ${v_lat} ${v_lon}" >> ${real_receiver_enhanced_wspr_spots_file}

    done < ${real_receiver_wspr_spots_file}
    [[ ${verbosity} -ge 3 ]] && printf "$(date): create_enhanced_spots_file() created '${real_receiver_enhanced_wspr_spots_file}':\n'$(cat ${real_receiver_enhanced_wspr_spots_file})'\n========\n"
}

################### wsprdaemon uploads ####################################
### add tx and rx lat, lon, azimuths, distance and path vertex using python script. 
### In the main program, call this function with a file path/name for the input file, the tx_locator, the rx_locator and the frequency
### The appended data gets stored into ${DERIVED_ADDED_FILE} which can be examined. Overwritten each acquisition cycle.
declare DERIVED_ADDED_FILE=derived_azi.csv
declare AZI_PYTHON_CMD=derived_calc.py

function add_derived() {
    local spot_grid=$1
    local my_grid=$2
    local spot_freq=$3    

    python3 ${AZI_PYTHON_CMD} ${spot_grid} ${my_grid} ${spot_freq} 1>add_derived.txt 2 > add_derived.log
}

### G3ZIL python script that gets copied into derived_calc.py and is run there
function create_azi_python() {
    cat > ${AZI_PYTHON_CMD} <<EOF
# -*- coding: utf-8 -*-
# April  2020  Gwyn Griffiths. Based on the add_azi used in the ts-wspr-scraper.sh script

# Takes receiver and transmitter Maidenhead locators and calculates azimuths at tx and rx, lats and lons, distance and vertes lat and lon
# Needs the two locators and frequency as arguments. If spot_grid="none" puts absent data in the calculated fields.
# The operating band is derived from the frequency, 60 and 60eu and 80 and 80eu are reported as 60 and 80
# Miles are not copied to the azi-appended file
# In the script the following lines preceed this code and there's an EOF added at the end
# G3ZIL python script that gets copied into /tmp/derived_calc.py and is run there

import numpy as np
from numpy import genfromtxt
import sys
import csv

absent_data=-999.0

# define function to convert 4 or 6 character Maidenhead locator to lat and lon in degrees
def loc_to_lat_lon (locator):
    locator=locator.strip()
    decomp=list(locator)
    lat=(((ord(decomp[1])-65)*10)+(ord(decomp[3])-48)+(1/2)-90)
    lon=(((ord(decomp[0])-65)*20)+((ord(decomp[2])-48)*2)+(1)-180)
    if len(locator)==6:
        if (ord(decomp[4])) >88:    # check for case of the third pair, likely to  be lower case
            ascii_base=96
        else:
            ascii_base=64
        lat=lat-(1/2)+((ord(decomp[5])-ascii_base)/24)-(1/48)
        lon=lon-(1)+((ord(decomp[4])-ascii_base)/12)-(1/24)
    return(lat, lon)

# get the rx_locator, tx_locator and frequency from the command line arguments
tx_locator=sys.argv[1]
print(tx_locator)
rx_locator=sys.argv[2]
print(rx_locator)
frequency=sys.argv[3]

print(tx_locator, rx_locator, frequency)

# open file for output as a csv file, to which we will put the calculated values
with open("${DERIVED_ADDED_FILE}", "w") as out_file:
    out_writer=csv.writer(out_file, delimiter=',', quotechar='"', quoting=csv.QUOTE_MINIMAL)
    # loop to calculate  azimuths at tx and rx (wsprnet only does the tx azimuth)
    if tx_locator!="none":
        (tx_lat,tx_lon)=loc_to_lat_lon (tx_locator)    # call function to do conversion, then convert to radians
        phi_tx_lat = np.radians(tx_lat)
        lambda_tx_lon = np.radians(tx_lon)
        (rx_lat,rx_lon)=loc_to_lat_lon (rx_locator)    # call function to do conversion, then convert to radians
        phi_rx_lat = np.radians(rx_lat)
        lambda_rx_lon = np.radians(rx_lon)
        delta_phi = (phi_tx_lat - phi_rx_lat)
        delta_lambda=(lambda_tx_lon-lambda_rx_lon)

        # calculate azimuth at the rx
        y = np.sin(delta_lambda) * np.cos(phi_tx_lat)
        x = np.cos(phi_rx_lat)*np.sin(phi_tx_lat) - np.sin(phi_rx_lat)*np.cos(phi_tx_lat)*np.cos(delta_lambda)
        rx_azi = (np.degrees(np.arctan2(y, x))) % 360

        # calculate azimuth at the tx
        p = np.sin(-delta_lambda) * np.cos(phi_rx_lat)
        q = np.cos(phi_tx_lat)*np.sin(phi_rx_lat) - np.sin(phi_tx_lat)*np.cos(phi_rx_lat)*np.cos(-delta_lambda)
        tx_azi = (np.degrees(np.arctan2(p, q))) % 360
        # calculate the vertex, the lat lon at the point on the great circle path nearest the nearest pole, this is the highest latitude on the path
        # no need to calculate special case of both transmitter and receiver on the equator, is handled OK
        # Need special case for any meridian, where vertex longitude is the meridian longitude and the vertex latitude is the lat nearest the N or S pole
        if tx_lon==rx_lon:
            v_lon=tx_lon
            v_lat=max([tx_lat, rx_lat], key=abs)
        else:
            v_lat=np.degrees(np.arccos(np.sin(np.radians(rx_azi))*np.cos(phi_rx_lat)))
        if v_lat>90.0:
            v_lat=180-v_lat
        if rx_azi<180:
            v_lon=((rx_lon+np.degrees(np.arccos(np.tan(phi_rx_lat)/np.tan(np.radians(v_lat)))))+360) % 360
        else:
            v_lon=((rx_lon-np.degrees(np.arccos(np.tan(phi_rx_lat)/np.tan(np.radians(v_lat)))))+360) % 360
        if v_lon>180:
            v_lon=-(360-v_lon)
        # now test if vertex is not  on great circle track, if so, lat/lon nearest pole is used
        if v_lon < min(tx_lon, rx_lon) or v_lon > max(tx_lon, rx_lon):
        # this is the off track case
            v_lat=max([tx_lat, rx_lat], key=abs)
            if v_lat==tx_lat:
                v_lon=tx_lon
            else:
                v_lon=rx_lon
        # now calculate the short path great circle distance
        a=np.sin(delta_phi/2)*np.sin(delta_phi/2)+np.cos(phi_rx_lat)*np.cos(phi_tx_lat)*np.sin(delta_lambda/2)*np.sin(delta_lambda/2)
        c=2*np.arctan2(np.sqrt(a), np.sqrt(1-a))
        km=6371*c
    else: 
        v_lon=absent_data
        v_lat=absent_data
        tx_lon=absent_data  
        tx_lat=absent_data
        rx_lon=absent_data
        rx_lat=absent_data
        rx_azi=absent_data
        tx_azi=absent_data
        km=absent_data
        # end of list of absent data values for where tx_locator = "none"
     
    # derive the band in metres (except 70cm and 23cm reported as 70 and 23) from the frequency
    band=9999
    freq=int(10*float(frequency))
    if freq==1:
        band=2200
    if freq==4:
        band=630
    if freq==18:
        band=160
    if freq==35:
        band=80
    if freq==52 or freq==53:
       band=60
    if freq==70:
        band=40
    if freq==101:
        band=30
    if freq==140:
        band=20
    if freq==181:
        band=17
    if freq==210:
        band=15
    if freq==249:
        band=12
    if freq==281:
        band=10
    if freq==502:
        band=6
    if freq==700:
        band=4
    if freq==1444:
        band=2
    if freq==4323:
        band=70
    if freq==12965:
        band=23
    # output the original data, except for pwr in W and miles, and add lat lon at tx and rx, azi at tx and rx, vertex lat lon and the band
    out_writer.writerow([band, "%.0f" % (km), "%.0f" % (rx_azi), "%.3f" % (rx_lat),  "%.3f" % (rx_lon), "%.0f" % (tx_azi),  "%.1f" % (tx_lat), "%.1f" % (tx_lon), "%.3f" % (v_lat), "%.3f" % (v_lon)])

EOF
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
    posting_daemon ${receiver_name} ${receiver_band} "${real_receiver_list}" > ${receiver_posting_dir}/posting.log 2>&1 &
    local posting_pid=$!
    echo ${posting_pid} > ${receiver_posting_dir}/posting.pid

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
declare UPLOAD_BATCH_PYTHON_CMD=${UPLOADS_TMP_ROOT_DIR}/ts_upload_batch.py

#G3ZIL python script that gets copied into /tmp/ts_bath_upload.py and is run there
function create_spots_batch_upload_python() {
    cat > ${UPLOAD_BATCH_PYTHON_CMD} <<EOF
# -*- coding: utf-8 -*-
#!/usr/bin/python3
# March-May  2020  Gwyn Griffiths
# ts_batch_upload.py   a program to read in a spots file scraped from wsprnet.org by scraper.sh and upload to a TimescaleDB
# Version 1.2 May 2020 batch upload from a parsed file. Takes about 1.7s compared with 124s for line by line
# that has been pre-formatted with an awk line to be in the right order and have single quotes around the time and character fields
# Added additional diagnostics to identify which part of the upload fails (12 in 1936 times)
import psycopg2                  # This is the main connection tool, believed to be written in C
import psycopg2.extras           # This is needed for the batch upload functionality
import csv                       # To import the csv file
import sys                       # to get at command line argument with argv

# initially set the connection flag to be None
conn=None
connected="Not connected"
cursor="No cursor"
execute="Not executed"
commit="Not committed"
ret_code=0

# get the path to the latest_log.txt file from the command line
batch_file_path=sys.argv[1]
sql=sys.argv[2]
#sql_orig="""INSERT INTO wsprdaemon_spots (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon)
#                          VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s);"""
#
#print("sql:       ", sql,
#       "sql_orig: ", sql_orig)

try:
    with open (batch_file_path) as csv_file:
        csv_data = csv.reader(csv_file, delimiter=',')
        try:
               # connect to the PostgreSQL database
               #print ("Trying to  connect")
               conn = psycopg2.connect("dbname='tutorial' user='postgres' host='localhost' password='GW3ZIL'")
               connected="Connected"
               #print ("Appear to have connected")
               # create a new cursor
               cur = conn.cursor()
               cursor="Got cursor"
               # execute the INSERT statement
               psycopg2.extras.execute_batch(cur,sql,csv_data)
               execute="Executed"
               #print ("After the execute")
               # commit the changes to the database
               conn.commit()
               commit="Committed"
               # close communication with the database
               cur.close()
               #print (connected,cursor, execute,commit)
        except:
               print ("Unable to record spot file do the database:",connected,cursor, execute,commit)
               ret_code=1
finally:
        if conn is not None:
            conn.close()
        sys.exit(ret_code)
EOF
}

declare TS_NOISE_AWK_SCRIPT=${UPLOADS_TMP_ROOT_DIR}/ts_noise.awk

function create_ts_noise_awk_script() {
    local ts_noise_awk_script=$1

    cat > ${ts_noise_awk_script} << 'EOF'
NF == 15 {
    no_head=FILENAME

    split (FILENAME, path_array, /\//)
    call_grid=path_array[3]

    split (call_grid, call_grid_array, "_")
    site=call_grid_array[1]
    gsub(/=/,"/",site)
    rx_grid=call_grid_array[2]

    receiver=path_array[4]
    band=path_array[5]
    time_freq=path_array[6]

    split (time_freq, time_freq_array, "_")
    date=time_freq_array[1]
    split (date,date_array,"")
    date_ts="20"date_array[1]date_array[2]"-"date_array[3]date_array[4]"-"date_array[5]date_array[6]
    time=time_freq_array[2]
    split (time, time_array,"")
    time_ts=time_array[1]time_array[2]":"time_array[3]time_array[4]

    rms_level=$13
    c2_level=$14
    ov=$15
    #printf "time='%s:%s' \nsite='%s' \nreceiver='%s' \nrx_grid='%s' \nband='%s' \nrms_level:'%s' \nc2_level:'%s' \nov='%s'\n", date_ts, time_ts, site, receiver, rx_grid, band, rms_level, c2_level, ov
    printf "%s:%s,%s,%s,%s,%s,%s,%s,%s\n", date_ts, time_ts, site, receiver, rx_grid, band, rms_level, c2_level, ov
}
EOF
}

#     
#  local extended_line=$( printf "%6s %4s %3d %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
#                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
declare UPLOAD_SPOT_SQL='INSERT INTO wsprdaemon_spots (time,     sync_quality, "SNR", dt, freq,   tx_call, tx_grid, "tx_dBm", drift, decode_cycles, jitter, blocksize, metric, osd_decode, ipass, nhardmin,            rms_noise, c2_noise,  band, rx_grid,        rx_id, km, rx_az, rx_lat, rx_lon, tx_az, tx_lat, tx_lon, v_lat, v_lon, receiver) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s); '
declare UPLOAD_NOISE_SQL='INSERT INTO wsprdaemon_noise (time, site, receiver, rx_grid, band, rms_level, c2_level, ov) VALUES (%s, %s, %s, %s, %s, %s, %s, %s);'

### This deamon runs on wsprdaemon.org and processes tgz files FTPed to it by WD clients
### It optionally queues a copy of each tgz for FTP transfer to WD1
function wsprdaemon_tgz_service_daemon() {
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    create_spots_batch_upload_python

    mkdir -p ${UPLOADS_TMP_ROOT_DIR}
    create_ts_noise_awk_script ${TS_NOISE_AWK_SCRIPT}
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

##########################################################################################################################################################
########## Section which implements the job control system  ########################################################################################################
##########################################################################################################################################################
function start_stop_job() {
    local action=$1
    local receiver_name=$2
    local receiver_band=$3

    [[ $verbosity -ge 3 ]] && echo "$(date): start_stop_job() begining '${action}' for ${receiver_name} on band ${receiver_band}"
    case ${action} in
        a) 
            spawn_upload_daemons     ### Ensure there are upload daemons to consume the spots and noise data
            spawn_posting_daemon        ${receiver_name} ${receiver_band}
            ;;
        z)
            kill_posting_daemon        ${receiver_name} ${receiver_band}
            ;;
        *)
            echo "ERROR: start_stop_job() aargument action '${action}' is invalid"
            exit 1
            ;;
    esac
    add_remove_jobs_in_running_file ${action} ${receiver_name},${receiver_band}
}


##############################################################
###  -Z or -j o cmd, also called at the end of -z, also called by the watchdog daemon every two minutes
declare ZOMBIE_CHECKING_ENABLED=${ZOMBIE_CHECKING_ENABLED:=yes}

function check_for_zombie_daemon(){
    local pid_file_path=$1

    if [[ -f ${pid_file_path} ]]; then
        local daemon_pid=$(cat ${pid_file_path})
        if ps ${daemon_pid} > /dev/null ; then
            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombie_daemon() daemon pid ${daemon_pid} from '${pid_file_path} is active" 1>&2
            echo ${daemon_pid}
        else
            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombie_daemon() daemon pid ${daemon_pid} from '${pid_file_path} is dead" 1>&2
            rm -f ${pid_file_path}
        fi
    fi
}
 
function check_for_zombies() {
    local force_kill=${1:-yes}   
    local job_index
    local job_info
    local receiver_name
    local receiver_band
    local found_job="no"
    local expected_and_running_pids=""

    if [[ ${ZOMBIE_CHECKING_ENABLED} != "yes" ]]; then
        return
    fi
    ### First check if the watchdog and the upload daemons are running
    for pid_file_path in ${PATH_WATCHDOG_PID} ${UPLOADS_WSPRNET_PIDFILE_PATH} ${UPLOADS_WSPRDAEMON_SPOTS_PIDFILE_PATH} ${UPLOADS_WSPRDAEMON_NOISE_PIDFILE_PATH} ${UPLOADS_WSPRDAEMON_FTP_PIDFILE_PATH}; do
        local daemon_pid=$(check_for_zombie_daemon ${pid_file_path} )
        if [[ -n "${daemon_pid}" ]]; then
            expected_and_running_pids="${expected_and_running_pids} ${daemon_pid}"
            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombies() is adding pid ${daemon_pid} of daemon '${pid_file_path}' to the expected pid list"
        else
            [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_zombies() found no pid for daemon '${pid_file_path}'"
        fi
    done

    ### Next check that all of the pids associated with RUNNING_JOBS are active
    ### Create ${running_rx_list} with  all the expected real rx devices. If there are MERGED jobs, then ensure that the real rx they depend upon is in ${running_rx_list}
    source ${RUNNING_JOBS_FILE}        ### populates the array RUNNING_JOBS()
    local running_rx_list=""           ### remember the rx rx devices
    for job_index in $(seq 0 $(( ${#RUNNING_JOBS[*]} - 1 )) ) ; do
        local job_info=(${RUNNING_JOBS[job_index]/,/ } )
        local receiver_name=${job_info[0]}
        local receiver_band=${job_info[1]}
        local job_id=${receiver_name},${receiver_band}
             
        if [[ ! "${receiver_name}" =~ ^MERG ]]; then
            ### This is a KIWI,AUDIO or SDR reciever
            if [[ ${running_rx_list} =~ " ${job_id} " ]] ; then
                [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() real rx job ${job_id}' is already listed in '${running_rx_list}'\n"
            else
                [[ ${verbosity} -ge 3 ]] && printf "$(date): check_for_zombies() real rx job ${job_id}' is not listed in running_rx_list ${running_rx_list}', so add it\n"
                ### Add it to the rx list
                running_rx_list="${running_rx_list} ${job_id}"
                ### Verify that pid files exist for it
                local rx_dir_path=$(get_recording_dir_path ${receiver_name} ${receiver_band})
                local posting_dir_path=$(get_posting_dir_path ${receiver_name} ${receiver_band})
                shopt -s nullglob
                local rx_pid_files=$( ls ${rx_dir_path}/{kiwi_recorder,recording,decode}.pid ${posting_dir_path}/posting.pid 2> /dev/null | tr '\n' ' ')
                shopt -u nullglob
                local expected_pid_files=4
                if [[ ${receiver_name} =~ ^AUDIO ]]; then
                    expected_pid_files=3
                elif [[ ${receiver_name} =~ ^SDR ]]; then
                    expected_pid_files=3
                fi
                if [[ $(wc -w <<< "${rx_pid_files}") -eq ${expected_pid_files}  ]]; then
                    [[ ${verbosity} -ge 3 ]] && printf "$(date): check_for_zombies() adding the ${expected_pid_files} expected real rx ${receiver_name}' recording pid files\n"
                    local pid_file
                    for pid_file in ${rx_pid_files} ; do
                        local pid_value=$(cat ${pid_file})
                        if ps ${pid_value} > /dev/null; then
                            [[ ${verbosity} -ge 3 ]] && echo "$(date): check_for_zombies() rx pid ${pid_value} found in '${pid_file}'is active"
                            expected_and_running_pids="${expected_and_running_pids} ${pid_value}"
                        else
                            [[ ${verbosity} -ge 1 ]] && echo "$(date): check_for_zombies() ERROR: rx pid ${pid_value} found in '${pid_file}' is not active, so deleting that pid file"
                            rm -f ${pid_file}
                        fi
                    done
                else
                    [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() WARNING: real rx ${receiver_name}' recording dir missing some or all of the expeted 4 pid files.  Found only: '${rx_pid_files}'\n"
                fi
            fi
        else  ### A MERGED device
            local merged_job_id=${job_id}
            ### This is a MERGED device.  Get its posting.pid
            local rx_dir_path=$(get_posting_dir_path ${receiver_name} ${receiver_band})
            local posting_pid_file=${rx_dir_path}/posting.pid
            if [[ ! -f ${posting_pid_file} ]]; then
                [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}' has no pid file '${posting_pid_file}'\n"
            else ## Has a posting.od file
                local pid_value=$(cat ${posting_pid_file})
                if ! ps  ${pid_value} > /dev/null ; then
                    [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}'  pid '${pid_value}' is dead from pid file '${posting_pid_file}'\n"
                else ### posting.pid is active
                    ### Add the postind.pid to the list and check the real rx devices 
                    [[ ${verbosity} -ge 2 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}'  pid '${pid_value}' is active  from file '${posting_pid_file}'\n"
                    expected_and_running_pids="${expected_and_running_pids} ${pid_value}"

                    ### Check the MERGED device's real rx devices are in the list
                    local merged_receiver_address=$(get_receiver_ip_from_name ${receiver_name})   ### In a MERGed rx, the real rxs feeding it are in a comma-seperated list in the IP column
                    local merged_receiver_name_list=${merged_receiver_address//,/ }
                    local rx_device 
                    for rx_device in ${merged_receiver_name_list}; do  ### Check each real rx
                        ### Check each real rx
                        job_id=${rx_device},${receiver_band}
                        if ${GREP_CMD} -wq ${job_id} <<< "${running_rx_list}" ; then 
                            [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}' is fed by real job '${job_id}' which is already listed in '${running_rx_list}'\n"
                        else ### Add new real rx
                            [[ ${verbosity} -ge 2 ]] && printf "$(date): check_for_zombies() merged job '${merged_job_id}' is fed by real job '${job_id}' which needs to be added to '${running_rx_list}'\n"
                            running_rx_list="${running_rx_list} ${rx_device}"
                            ### Verify that pid files exist for it
                            local rx_dir_path=$(get_recording_dir_path ${rx_device} ${receiver_band})
                            shopt -s nullglob
                            local rx_pid_files=$( ls ${rx_dir_path}/{kiwi_recorder,recording,decode}.pid 2> /dev/null | tr '\n' ' ' )
                            shopt -u nullglob
                            local expected_pid_files=3
                            if [[ ${rx_device} =~ ^AUDIO ]]; then
                                expected_pid_files=2
                            elif [[ ${rx_device} =~ ^SDR ]]; then
                                expected_pid_files=2
                            fi
                            if [[ $(wc -w <<< "${rx_pid_files}") -ne  ${expected_pid_files} ]]; then
                                [[ ${verbosity} -ge 1 ]] && printf "$(date): check_for_zombies() WARNING: real rx ${rx_device}' recording dir missing some or all of the expeted 3 pid files.  Found only: '${rx_pid_files}'\n"
                            else  ### Check all 3 pid files 
                                [[ ${verbosity} -ge 2 ]] && printf "$(date): check_for_zombies() adding the 3 expected real rx ${rx_device}' pid files\n"
                                local pid_file
                                for pid_file in ${rx_pid_files} ; do ### Check one pid 
                                    local pid_value=$(cat ${pid_file})
                                    if ps ${pid_value} > /dev/null; then ### Is pid active
                                        [[ ${verbosity} -ge 2 ]] && echo "$(date): check_for_zombies() rx pid ${pid_value} found in '${pid_file}'is active"
                                        expected_and_running_pids="${expected_and_running_pids} ${pid_value}"
                                    else
                                        [[ ${verbosity} -ge 1 ]] && echo "$(date): check_for_zombies() ERROR: rx pid ${pid_value} found in '${pid_file}' is not active, so deleting that pid file"
                                        rm -f ${pid_file}
                                    fi ### Is pid active
                                done ### Check one pid
                            fi ### Check all 3 pid files
                        fi ### Add new real rx
                    done ### Check each real rx
                fi ### posting.pid is active
            fi ## Has a posting.od file
        fi ## A MERGED device
    done

    ### We have checked all the pid files, now look at all running kiwirecorder programs reported by 'ps'
    local kill_pid_list=""
    local ps_output_lines=$(ps auxf)
    local ps_running_list=$( awk '/wsprdaemon/ && !/vi / && !/ssh/ && !/scp/ && !/-v*[zZ]/ && !/\.log/ && !/wav_window.py/ && !/psql/ && !/derived_calc.py/ && !/curl/ && !/avahi-daemon/ {print $2}' <<< "${ps_output_lines}" )
    [[ $verbosity -ge 3 ]] && echo "$(date): check_for_zombies() filtered 'ps usxf' output '${ps_output_lines}' to get list '${ps_running_list}"
    for running_pid in ${ps_running_list} ; do
       if ${GREP_CMD} -qw ${running_pid} <<< "${expected_and_running_pids}"; then
           [[ $verbosity -ge 3 ]] && printf "$(date): check_for_zombies() Found running_pid '${running_pid}' in expected_pids '${expected_and_running_pids}'\n"
       else
           if [[ $verbosity -ge 2 ]] ; then
               printf "$(date): check_for_zombies() WARNING: did not find running_pid '${running_pid}' in expected_pids '${expected_and_running_pids}'\n"
               ${GREP_CMD} -w ${running_pid} <<< "${ps_output_lines}"
           fi
           if ps ${running_pid} > /dev/null; then
               [[ $verbosity -ge 1 ]] && printf "$(date): check_for_zombies() adding running  zombie '${running_pid}' to kill list\n"
               kill_pid_list="${kill_pid_list} ${running_pid}"
           else
               [[ $verbosity -ge 2 ]] && printf "$(date): check_for_zombies()  zombie ${running_pid} is phantom which is no longer running\n"
           fi
       fi
    done
    local ps_running_count=$(wc -w <<< "${ps_running_list}")
    local ps_expected_count=$(wc -w <<< "${expected_and_running_pids}")
    local ps_zombie_count=$(wc -w <<< "${kill_pid_list}")
    if [[ -n "${kill_pid_list}" ]]; then
        if [[ "${force_kill}" != "yes" ]]; then
            echo "check_for_zombies() pid $$ expected ${ps_expected_count}, found ${ps_running_count}, so there are ${ps_zombie_count} zombie pids: '${kill_pid_list}'"
            read -p "Do you want to kill these PIDs? [Yn] > "
            REPLY=${REPLY:-Y}     ### blank or no response change to 'Y'
            if [[ ${REPLY^} == "Y" ]]; then
                force_kill="yes"
            fi
        fi
        if [[ "${force_kill}" == "yes" ]]; then
            if [[ $verbosity -ge 1 ]]; then
                echo "$(date): check_for_zombies() killing pids '${kill_pid_list}'"
                ps ${kill_pid_list}
            fi
            kill -9 ${kill_pid_list}
        fi
    else
        ### Found no zombies
        [[ $verbosity -ge 2 ]] && echo "$(date): check_for_zombies() pid $$ expected ${ps_expected_count}, found ${ps_running_count}, so there are no zombies"
    fi
}


##############################################################
###  -j s cmd   Argument is 'all' OR 'RECEIVER,BAND'
function show_running_jobs() {
    local args_val=${1:-all}      ## -j s  defaults to 'all'
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    local show_band=${args_array[1]:-}
    if [[ "${show_target}" != "all" ]] && [[ -z "${show_band}" ]]; then
        echo "ERROR: missing RECEIVER,BAND argument"
        exit 1
    fi
    local job_index
    local job_info
    local receiver_name_list=()
    local receiver_name
    local receiver_band
    local found_job="no"
 
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "There is no RUNNING_JOBS_FILE '${RUNNING_JOBS_FILE}'"
        return 1
    fi
    source ${RUNNING_JOBS_FILE}
    
    for job_index in $(seq 0 $(( ${#RUNNING_JOBS[*]} - 1 )) ) ; do
        job_info=(${RUNNING_JOBS[job_index]/,/ } )
        receiver_band=${job_info[1]}
        if [[ ${job_info[0]} =~ ^MERG ]]; then
            ### For merged rx devices, there is only one posting pid, but one or more recording and decoding pids
            local merged_receiver_name=${job_info[0]}
            local receiver_address=$(get_receiver_ip_from_name ${merged_receiver_name})
            receiver_name_list=(${receiver_address//,/ })
            printf "%2s: %12s,%-4s merged posting  %s (%s)\n" ${job_index} ${merged_receiver_name} ${receiver_band} "$(get_posting_status ${merged_receiver_name} ${receiver_band})" "${receiver_address}"
        else
            ### For a simple rx device, the recording, decdoing and posting pids are all in the same directory
            receiver_name=${job_info[0]}
            receiver_name_list=(${receiver_name})
            printf "%2s: %12s,%-4s posting  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_posting_status   ${receiver_name} ${receiver_band})"
        fi
        if [[ ${verbosity} -gt 0 ]]; then
            for receiver_name in ${receiver_name_list[@]}; do
                if [[ ${show_target} == "all" ]] || ( [[ ${receiver_name} == ${show_target} ]] && [[ ${receiver_band} == ${show_band} ]] ) ; then
                    printf "%2s: %12s,%-4s capture  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_recording_status ${receiver_name} ${receiver_band})"
                    printf "%2s: %12s,%-4s decode   %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_decoding_status  ${receiver_name} ${receiver_band})"
                    found_job="yes"
                fi
            done
            if [[ ${found_job} == "no" ]]; then
                if [[ "${show_target}" == "all" ]]; then
                    echo "No spot recording jobs are running"
                else
                    echo "No job found for RECEIVER '${show_target}' BAND '${show_band}'"
                fi
           fi
        fi
    done
}

##############################################################
###  -j l RECEIVER,BAND cmd
function tail_wspr_decode_job_log() {
    local args_val=${1:-}
    if [[ -z "${args_val}" ]]; then
        echo "ERROR: missing ',RECEIVER,BAND'"
        exit 1
    fi
    local args_array=(${args_val/,/ })
    local show_target=${args_array[0]}
    if [[ -z "${show_target}" ]]; then
        echo "ERROR: missing RECEIVER"
        exit 1
    fi
    local show_band=${args_array[1]:-}
    if [[ -z "${show_band}" ]]; then
        echo "ERROR: missing BAND argument"
        exit 1
    fi
    local job_index
    local job_info
    local receiver_name
    local receiver_band
    local found_job="no"

    source ${RUNNING_JOBS_FILE}

    for job_index in $(seq 0 $(( ${#RUNNING_JOBS[*]} - 1 )) ) ; do
        job_info=(${RUNNING_JOBS[${job_index}]/,/ })
        receiver_name=${job_info[0]}
        receiver_band=${job_info[1]}
        if [[ ${show_target} == "all" ]] || ( [[ ${receiver_name} == ${show_target} ]] && [[ ${receiver_band} == ${show_band} ]] )  ; then
            printf "%2s: %12s,%-4s capture  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_recording_status ${receiver_name} ${receiver_band})"
            printf "%2s: %12s,%-4s decode   %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_decoding_status  ${receiver_name} ${receiver_band})"
            printf "%2s: %12s,%-4s posting  %s\n" ${job_index} ${receiver_name} ${receiver_band}  "$(get_posting_status   ${receiver_name} ${receiver_band})"
            local decode_log_file=$(get_recording_dir_path ${receiver_name} ${receiver_band})/decode.log
            if [[ -f ${decode_log_file} ]]; then
                less +F ${decode_log_file}
            else
                echo "ERROR: can't file expected decode log file '${decode_log_file}"
                exit 1
            fi
            found_job="yes"
        fi
    done
    if [[ ${found_job} == "no" ]]; then
        echo "No job found for RECEIVER '${show_target}' BAND '${show_band}'"
    fi
}

###
function add_remove_jobs_in_running_file() {
    local action=$1    ## 'a' or 'z'
    local job=$2       ## in form RECEIVER,BAND

    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "RUNNING_JOBS=( )" > ${RUNNING_JOBS_FILE}
    fi
    source ${RUNNING_JOBS_FILE}
    case $action in
        a)
            if ${GREP_CMD} -w ${job} ${RUNNING_JOBS_FILE} > /dev/null; then
                ### We come here when restarting a dead capture jobs, so this condition is already printed out
                [[ $verbosity -ge 2 ]] && \
                    echo "$(date): add_remove_jobs_in_running_file():  WARNING: found job ${receiver_name},${receiver_band} was already listed in ${RUNNING_JOBS_FILE}"
                return 1
            fi
            source ${RUNNING_JOBS_FILE}
            RUNNING_JOBS+=( ${job} )
            ;;
        z)
            if ! ${GREP_CMD} -w ${job} ${RUNNING_JOBS_FILE} > /dev/null; then
                echo "$(date) WARNING: start_stop_job(remove) found job ${receiver_name},${receiver_band} was already not listed in ${RUNNING_JOBS_FILE}"
                return 2
            fi
            ### The following line is a little obscure, so here is an explanation
            ###  We are deleting the version of RUNNING_JOBS[] to delete one job.  Rather than loop through the array I just use sed to delete it from
            ###  the array declaration statement in the ${RUNNING_JOBS_FILE}.  So this statement redeclares RUNNING_JOBS[] with the delect job element removed 
            eval $( sed "s/${job}//" ${RUNNING_JOBS_FILE})
            ;;
        *)
            echo "$(date): add_remove_jobs_in_running_file(): ERROR: action ${action} invalid"
            return 2
    esac
    ### Sort RUNNING_JOBS by ascending band frequency
    IFS=$'\n'
    RUNNING_JOBS=( $(sort --field-separator=, -k 2,2n <<< "${RUNNING_JOBS[*]-}") )    ### TODO: this doesn't sort.  
    unset IFS
    echo "RUNNING_JOBS=( ${RUNNING_JOBS[*]-} )" > ${RUNNING_JOBS_FILE}
}

###

#############
###################
declare -r HHMM_SCHED_FILE=${WSPRDAEMON_ROOT_DIR}/hhmm.sched      ### Contains the schedule from kwiwwspr.conf with sunrise/sunset entries fixed in HHMM_SCHED[]
declare -r EXPECTED_JOBS_FILE=${WSPRDAEMON_ROOT_DIR}/expected.jobs    ### Based upon current HHMM, this is the job list from EXPECTED_JOBS_FILE[] which should be running in EXPECTED_LIST[]
declare -r RUNNING_JOBS_FILE=${WSPRDAEMON_ROOT_DIR}/running.jobs      ### This is the list of jobs we programmed to be running in RUNNING_LIST[]

### Once per day, cache the sunrise/sunset times for the grids of all receivers
function update_suntimes_file() {
    if [[ -f ${SUNTIMES_FILE} ]] \
        && [[ $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ) -gt $( $GET_FILE_MOD_TIME_CMD ${WSPRDAEMON_CONFIG_FILE} ) ]] \
        && [[ $(( $(date +"%s") - $( $GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} ))) -lt ${MAX_SUNTIMES_FILE_AGE_SECS} ]] ; then
        ## Only update once a day
        return
    fi
    rm -f ${SUNTIMES_FILE}
    source ${WSPRDAEMON_CONFIG_FILE}
    local maidenhead_list=$( ( IFS=$'\n' ; echo "${RECEIVER_LIST[*]}") | awk '{print $4}' | sort | uniq)
    for grid in ${maidenhead_list[@]} ; do
        echo "${grid} $(get_sunrise_sunset ${grid} )" >> ${SUNTIMES_FILE}
    done
    [[ $verbosity -ge 2 ]] && echo "$(date): Got today's sunrise and sunset times"
}

### reads wsprdaemon.conf and if there are sunrise/sunset job times it gets the current sunrise/sunset times
### After calculating HHMM for sunrise and sunset array elements, it creates hhmm.sched with job times in HHMM_SCHED[]
function update_hhmm_sched_file() {
    update_suntimes_file      ### sunrise/sunset times change daily

    ### EXPECTED_JOBS_FILE only should need to be updated if WSPRDAEMON_CONFIG_FILE or SUNTIMES_FILE has changed
    local config_file_time=$($GET_FILE_MOD_TIME_CMD ${WSPRDAEMON_CONFIG_FILE} )
    local suntimes_file_time=$($GET_FILE_MOD_TIME_CMD ${SUNTIMES_FILE} )
    local hhmm_sched_file_time

    if [[ ! -f ${HHMM_SCHED_FILE} ]]; then
        hhmm_sched_file_time=0
    else
        hhmm_sched_file_time=$($GET_FILE_MOD_TIME_CMD ${HHMM_SCHED_FILE} )
    fi

    if [[ ${hhmm_sched_file_time} -ge ${config_file_time} ]] && [[ ${hhmm_sched_file_time} -ge ${suntimes_file_time} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): update_hhmm_sched_file() found HHMM_SCHED_FILE file newer than config file and suntimes file, so no file update is needed."
        return
    fi

    if [[ ! -f ${HHMM_SCHED_FILE} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): update_hhmm_sched_file() found no HHMM_SCHED_FILE"
    else
        if [[ ${hhmm_sched_file_time} -lt ${suntimes_file_time} ]] ; then
            [[ $verbosity -ge 2 ]] && echo "$(date): update_hhmm_sched_file() found HHMM_SCHED_FILE file is older than SUNTIMES_FILE, so update needed"
        fi
        if [[ ${hhmm_sched_file_time} -lt ${config_file_time}  ]] ; then
            [[ $verbosity -ge 2 ]] && echo "$(date): update_hhmm_sched_file() found HHMM_SCHED_FILE is older than config file, so update needed"
        fi
    fi

    local -a job_array_temp=()
    local -i job_array_temp_index=0
    local -a job_line=()

    source ${WSPRDAEMON_CONFIG_FILE}      ### declares WSPR_SCHEDULE[]
    ### Examine each element of WSPR_SCHEDULE[] and Convert any sunrise or sunset times to HH:MM in job_array_temp[]
    local -i wspr_schedule_index
    for wspr_schedule_index in $(seq 0 $(( ${#WSPR_SCHEDULE[*]} - 1 )) ) ; do
        job_line=( ${WSPR_SCHEDULE[${wspr_schedule_index}]} )
        if [[ ${job_line[0]} =~ sunrise|sunset ]] ; then
            local receiver_name=${job_line[1]%,*}               ### I assume that all of the Reciever in this job are in the same grid as the Reciever in the first job 
            local receiver_grid="$(get_receiver_grid_from_name ${receiver_name})"
            job_line[0]=$(get_index_time ${job_line[0]} ${receiver_grid})
            local job_time=${job_line[0]}
            if [[ ! ${job_line[0]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
                ### I don't think that get_index_time() can return a bad time for a sunrise/sunset job, but this is to be sure of that
                echo "$(date): ERROR: in update_hhmm_sched_file(): found and invalid configured sunrise/sunset job time '${job_line[0]}' in wsprdaemon.conf, so skipping this job."
                continue ## to the next index
            fi
        fi
        if [[ ! ${job_line[0]} =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
            ### validate all lines, whether a computed sunrise/sunset or simple HH:MM
            echo "$(date): ERROR: in update_hhmm_sched_file(): invalid job time '${job_line[0]}' in wsprdaemon.conf, expecting HH:MM so skipping this job."
            continue ## to the next index
        fi
        job_array_temp[${job_array_temp_index}]="${job_line[*]}"
        ((job_array_temp_index++))
    done

    ### Sort the now only HH:MM elements of job_array_temp[] by time into jobs_sorted[]
    IFS=$'\n' 
    local jobs_sorted=( $(sort <<< "${job_array_temp[*]}") )
    ### The elements are now sorted by schedule time, but the jobs are stil in the wsprdaemon.conf order
    ### Sort the times for each schedule
    local index_sorted
    for index_sorted in $(seq 0 $(( ${#jobs_sorted[*]} - 1 )) ); do
        job_line=( ${jobs_sorted[${index_sorted}]} )
        local job_time=${job_line[0]}
        job_line[0]=""    ### delete the time 
        job_line=$( $(sort --field-separator=, -k 2,2n <<< "${job_line[*]}") ) ## sort by band
        jobs_sorted[${index_sorted}]="${job_time} ${job_line[*]}"              ## and put the sorted shedule entry back where it came from
    done
    unset IFS

    ### Now that all jobs have numeric HH:MM times and are sorted, ensure that the first job is at 00:00
    unset job_array_temp
    local -a job_array_temp
    job_array_temp_index=0
    job_line=(${jobs_sorted[0]})
    if [[ ${job_line[0]} != "00:00" ]]; then
        ### The config schedule doesn't start at midnight, so use the last config entry as the config for start of the day
        local -i jobs_sorted_index_max=$(( ${#jobs_sorted[*]} - 1 ))
        job_line=(${jobs_sorted[${jobs_sorted_index_max}]})
        job_line[0]="00:00"
        job_array_temp[${job_array_temp_index}]="${job_line[*]}" 
        ((++job_array_temp_index))
    fi
    for index in $(seq 0 $(( ${#jobs_sorted[*]} - 1 )) ) ; do
        job_array_temp[$job_array_temp_index]="${jobs_sorted[$index]}"
        ((++job_array_temp_index))
    done

    ### Save the sorted schedule strting with 00:00 and with only HH:MM jobs to ${HHMM_SCHED_FILE}
    echo "declare HHMM_SCHED=( \\" > ${HHMM_SCHED_FILE}
    for index in $(seq 0 $(( ${#job_array_temp[*]} - 1 )) ) ; do
        echo "\"${job_array_temp[$index]}\" \\" >> ${HHMM_SCHED_FILE}
    done
    echo ") " >> ${HHMM_SCHED_FILE}
    [[ $verbosity -ge 1 ]] && echo "$(date): INFO: update_hhmm_sched_file() updated HHMM_SCHED_FILE"
}

###################
### Setup EXPECTED_JOBS[] in expected.jobs to contain the list of jobs which should be running at this time in EXPECTED_JOBS[]
function setup_expected_jobs_file () {
    update_hhmm_sched_file                     ### updates hhmm_schedule file if needed
    source ${HHMM_SCHED_FILE}

    local    current_time=$(date +%H%M)
    current_time=$((10#${current_time}))   ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
    local -a expected_jobs=()
    local -a hhmm_job
    local    index_max_hhmm_sched=$(( ${#HHMM_SCHED[*]} - 1))
    local    index_time

    ### Find the current schedule
    local index_now=0
    local index_now_time=0
    for index in $(seq 0 ${index_max_hhmm_sched}) ; do
        hhmm_job=( ${HHMM_SCHED[${index}]}  )
        local receiver_name=${hhmm_job[1]%,*}   ### I assume that all of the Recievers in this job are in the same grid as the Kiwi in the first job
        local receiver_grid="$(get_receiver_grid_from_name ${receiver_name})"
        index_time=$(get_index_time ${hhmm_job[0]} ${receiver_grid})  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        if [[ ! ${index_time} =~ ^[0-9]+ ]]; then
            echo "$(date): setup_expected_jobs_file() ERROR: invalid configured job time '${index_time}'"
            continue ## to the next index
        fi
        index_time=$((10#${index_time}))  ## remove the ':' from HH:MM, then force it to be a decimal number (i.e suppress leading 0s)
        if [[ ${current_time} -ge ${index_time} ]] ; then
            expected_jobs=(${HHMM_SCHED[${index}]})
            expected_jobs=(${expected_jobs[*]:1})          ### Chop off first array element which is the scheudle start time
            index_now=index                                ### Remember the index of the HHMM job which should be active at this time
            index_now_time=$index_time                     ### And the time of that HHMM job
            if [[ $verbosity -ge 3 ]] ; then
                echo "$(date): INFO: setup_expected_jobs_file(): current time '$current_time' is later than HHMM_SCHED[$index] time '${index_time}', so expected_jobs[*] ="
                echo "         '${expected_jobs[*]}'"
            fi
        fi
    done
    if [[ -z "${expected_jobs[*]}" ]]; then
        echo "$(date): setup_expected_jobs_file() ERROR: couldn't find a schedule"
        return 
    fi

    if [[ ! -f ${EXPECTED_JOBS_FILE} ]]; then
        echo "EXPECTED_JOBS=()" > ${EXPECTED_JOBS_FILE}
    fi
    source ${EXPECTED_JOBS_FILE}
    if [[ "${EXPECTED_JOBS[*]-}" == "${expected_jobs[*]}" ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): setup_expected_jobs_file(): at time ${current_time} the entry for time ${index_now_time} in EXPECTED_JOBS[] is present in EXPECTED_JOBS_FILE, so update of that file is not needed"
    else
        [[ $verbosity -ge 2 ]] && echo "$(date): setup_expected_jobs_file(): a new schedule from EXPECTED_JOBS[] for time ${current_time} is needed for current time ${current_time}"

        ### Save the new schedule to be read by the calling function and for use the next time this function is run
        printf "EXPECTED_JOBS=( ${expected_jobs[*]} )\n" > ${EXPECTED_JOBS_FILE}
    fi
}

###################################################
function check_kiwi_wspr_channels() {
    local kiwi_name=$1
    local kiwi_ip=$(get_receiver_ip_from_name ${kiwi_name})

    local users_max=$(curl -s --connect-timeout 5 ${kiwi_ip}/status | awk -F = '/users_max/{print $2}')
    if [[ -z "${users_max}" ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' not present or its SW doesn't report 'users_max', so nothing to do"
        return
    fi
    if [[ ${users_max} -lt 8 ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' is configured for ${users_max} users, not in 8 channel mode.  So nothing to do"
        return
    fi

    local active_receivers_list=$( curl -s --connect-timeout 5 ${kiwi_ip}/users | sed -n '/"i":\([0-9]\),"n"/s//\n\1/gp' | ${GREP_CMD} "^[0-9]" )
    if [[ -z "${active_receivers_list}" ]];  then
        [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' not reporting users status or there are no active rx channels on it.  So nothing to do"
        return
    fi
    [[ $verbosity -ge 4 ]] && printf "$(date): check_kiwi_wspr_channels() Kiwi '%s' active listeners:\n%s\n" "${kiwi_name}" "${active_receivers_list}"

    if ! ${GREP_CMD} -q "wsprdaemon" <<< "${active_receivers_list}" ; then
        [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' has no active WD listeners"
        return
    fi
    local wd_listeners_count=$( ${GREP_CMD} wsprdaemon <<< "${active_receivers_list}" | wc -l) 
    local wd_ch_01_listeners_count=$( ${GREP_CMD} "^[01]:.wsprdaemon" <<< "${active_receivers_list}" | wc -l) 
    [[ $verbosity -ge 3 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' has ${wd_listeners_count} WD listeners of which ${wd_ch_01_listeners_count} listeners are on ch 0 or ch 1"
    if [[ ${wd_listeners_count} -le 6 && ${wd_ch_01_listeners_count} -gt 0 ]]; then
        if [[ $verbosity -ge 1 ]] ; then
            echo   "$(date): check_kiwi_wspr_channels() WARNING, Kiwi '${kiwi_name}' configured in 8 channel mode has ${wd_listeners_count} WD listeners."
            printf "$(date):    So all of them should be on rx ch 2-7,  but %s isteners are on ch 0 or ch 1: \n%s\n" "${wd_ch_01_listeners_count}" "${active_receivers_list}"
        fi
        if ${GREP_CMD} -q ${kiwi_name} <<< "${RUNNING_JOBS[@]}"; then
            [[ $verbosity -ge 1 ]] && echo "$(date): check_kiwi_wspr_channels() found '${kiwi_name}' is in use by this instance of WD, so add code to clean up the RX channels used"
            ### TODO: recover from listener on rx 0/1 code here 
        else
            [[ $verbosity -ge 1 ]] && echo "$(date): check_kiwi_wspr_channels() do nothing, since '${kiwi_name}' is not in my RUNNING_JOBS[]= ${RUNNING_JOBS[@]}'"
        fi
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): check_kiwi_wspr_channels() Kiwi '${kiwi_name}' configured for 8 rx channels found WD usage is OK"
    fi
}

### Check that WD listeners are on channels 2...7
function check_kiwi_rx_channels() {
    local kiwi
    local kiwi_list=$(list_kiwis)
    [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_rx_channels() starting a check of rx channel usage on all Kiwis"

    for kiwi in ${kiwi_list} ; do
        [[ $verbosity -ge 4 ]] && echo "$(date): check_kiwi_rx_channels() check active users on KIWI '${kiwi}'"
        check_kiwi_wspr_channels ${kiwi}
    done
}

### If there are no GPS locks and it has been 24 hours since the last attempt to let the Kiwi get lock, stop all jobs for X seconds
declare KIWI_GPS_LOCK_CHECK=${KIWI_GPS_LOCK_CHECK-yes} ## :=no}
declare KIWI_GPS_LOCK_CHECK_INTERVAL=600 #$((24 * 60 * 60))  ### Seconds between checks
declare KIWI_GPS_STARUP_LOCK_WAIT_SECS=60               ### Wher first starting and the Kiwi reports no GPS lock, poll for lock this many seconds
declare KIWI_GPS_LOCK_LOG_DIR=${WSPRDAEMON_TMP_DIR}/kiwi_gps_status

function check_kiwi_gps() {
    [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_gps() start check of all known Kiwis"

    local kiwi
    local kiwi_list=$(list_kiwis)
    [[ $verbosity -ge 4 ]] && echo "$(date): check_kiwi_gps() got list of all defined KIWIs = '${kiwi_list}'"

    for kiwi in ${kiwi_list} ; do
        [[ $verbosity -ge 4 ]] && echo "$(date): check_kiwi_gps() check lock on KIWI '${kiwi}'"
        let_kiwi_get_gps_lock ${kiwi}
    done
    [[ $verbosity -ge 2 ]] && echo "$(date): check_kiwi_gps() check completed"
}

### Once every KIWI_GPS_LOCK_CHECK_INTERVAL seconds check to see if the Kiwi is in GPS lock by seeing that the 'fixes' counter is incrementing
function let_kiwi_get_gps_lock() {
    [[ ${KIWI_GPS_LOCK_CHECK} != "yes" ]] && return
    local kiwi_name=$1
    local kiwi_ip=$(get_receiver_ip_from_name ${kiwi_name})

    ### Check to see if Kiwi reports gps status and if the Kiwi is locked to enough satellites
    local kiwi_status=$(curl -s --connect-timeout 5 ${kiwi_ip}/status)
    if [[ -z "${kiwi_status}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() got no response from kiwi '${kiwi_name}'"
        return
    fi
    local kiwi_gps_good_count=$(awk -F = '/gps_good=/{print $2}' <<< "${kiwi_status}" )
    if [[ -z "${kiwi_gps_good_count}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' is running SW which doesn't report gps_good status"
        return
    fi
    declare GPS_MIN_GOOD_COUNT=4
    if [[ ${kiwi_gps_good_count} -lt ${GPS_MIN_GOOD_COUNT} ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' reports '${kiwi_gps_good_count}' good GPS which is less than the min of ${GPS_MIN_GOOD_COUNT} we require.  So GPS is bad on this Kiwi"
        ### TODO: don't perturb the Kiwi too often if it doesn't have GPS lock
    else
        [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' reports '${kiwi_gps_good_count}' good GPS which is greater than or equal to the min of ${GPS_MIN_GOOD_COUNT} we require.  So GPS is OK on this Kiwi"
        ### TODO:  just return here once I am confident that further checks are not needed
        ### return
    fi

    ### Double check the GPS status by seeing if the fixes count has gone up
     ## Check to see if/when we last checked the Kiwi's GPS status
    if [[ ! -d ${KIWI_GPS_LOCK_LOG_DIR} ]]; then
        mkdir -p ${KIWI_GPS_LOCK_LOG_DIR}
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() created dir '${KIWI_GPS_LOCK_LOG_DIR}'"
    fi
    local kiwi_gps_log_file=${KIWI_GPS_LOCK_LOG_DIR}/${kiwi_name}_last_gps_fixes.log
    if [[ ! -f ${kiwi_gps_log_file} ]]; then 
        echo "0" > ${kiwi_gps_log_file}
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() created log file '${kiwi_gps_log_file}'"
    fi
    local kiwi_last_fixes_count=$(cat ${kiwi_gps_log_file})
    local current_time=$(date +%s)
    local kiwi_last_gps_check_time=$(date -r ${kiwi_gps_log_file} +%s)
    local seconds_since_last_check=$(( ${current_time} - ${kiwi_last_gps_check_time} ))

    if [[ ${kiwi_last_fixes_count} -gt 0 ]] && [[ ${seconds_since_last_check} -lt ${KIWI_GPS_LOCK_CHECK_INTERVAL} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() too soon to check KIWI '${kiwi_name}'.  Only ${seconds_since_last_check} seconds since last check"
        return
    fi
    ### fixes is 0 OR it is time to check again
    local kiwi_fixes_count=$(awk -F = '/fixes=/{print $2}' <<< "${kiwi_status}" )
    if [[ -z "${kiwi_fixes_count}" ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): let_kiwi_get_gps_lock() kiwi '${kiwi_name}' is running SW which doesn't report fixes status"
        return
    fi
    [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() got new fixes count '${kiwi_fixes_count}' from kiwi '${kiwi_name}'"
    if [[ ${kiwi_fixes_count} -gt ${kiwi_last_fixes_count} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): let_kiwi_get_gps_lock() Kiwi '${kiwi_name}' is locked since new count ${kiwi_fixes_count} is larger than old count ${kiwi_last_fixes_count}"
        echo ${kiwi_fixes_count} > ${kiwi_gps_log_file}
        return
    fi
    if [[ ${kiwi_fixes_count} -lt ${kiwi_last_fixes_count} ]]; then
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() Kiwi '${kiwi_name}' is locked but new count ${kiwi_fixes_count} is less than old count ${kiwi_last_fixes_count}. Our old count may be stale (from a previous run), so save this new count"
        echo ${kiwi_fixes_count} > ${kiwi_gps_log_file}
        return
    fi
    [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() Kiwi '${kiwi_name}' reporting ${GPS_MIN_GOOD_COUNT} locks, but new count ${kiwi_fixes_count} == old count ${kiwi_last_fixes_count}, so fixes count has not changed"
    ### GPS fixes count has not changed.  If there are active users or WD clients, kill those sessions so as to free the Kiwi to search for sats
    local active_receivers_list=$( curl -s --connect-timeout 5 ${kiwi_ip}/users | sed -n '/"i":\([0-9]\),"n"/s//\n\1/gp' | ${GREP_CMD} "^[0-9]" )
    if [[ -z "${active_receivers_list}" ]];  then
        [[ $verbosity -ge 2 ]] && echo "$(date): let_kiwi_get_gps_lock() found no active rx channels on Kiwi '${kiwi_name}, so it is already searching for GPS"
        touch ${kiwi_gps_log_file}
        return
    fi
    [[ $verbosity -ge 2 ]] && printf "$(date): let_kiwi_get_gps_lock() this is supposed to no longer be needed, but it appears that we terminate active users on Kiwi '${kiwi_name}' so it can get GPS lock: \n%s\n" "${active_receivers_list}"
}

### Read the expected.jobs and running.jobs files and terminate and/or add jobs so that they match
function update_running_jobs_to_match_expected_jobs() {
    setup_expected_jobs_file
    source ${EXPECTED_JOBS_FILE}

    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        echo "RUNNING_JOBS=()" > ${RUNNING_JOBS_FILE}
    fi
    source ${RUNNING_JOBS_FILE}
    local temp_running_jobs=( ${RUNNING_JOBS[*]-} )

    ### Check that posting jobs which should be running are still running, and terminate any jobs currently running which will no longer be running 
    ### posting_daemon() will ensure that decoding_daemon() and recording_deamon()s are running
    local index_temp_running_jobs
    local schedule_change="no"
    for index_temp_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
        local running_job=${temp_running_jobs[${index_temp_running_jobs}]}
        local running_reciever=${running_job%,*}
        local running_band=${running_job#*,}
        local found_it="no"
        [[ $verbosity -ge 3 ]] && echo "$(date): update_running_jobs_to_match_expected_jobs(): checking posting_daemon() status of job $running_job"
        for index_schedule_jobs in $( seq 0 $(( ${#EXPECTED_JOBS[*]} - 1)) ) ; do
            if [[ ${running_job} == ${EXPECTED_JOBS[$index_schedule_jobs]} ]]; then
                found_it="yes"
                ### Verify that it is still running
                local status
                if status=$(get_posting_status ${running_reciever} ${running_band}) ; then
                    [[ $verbosity -ge 3 ]] && echo "$(date): update_running_jobs_to_match_expected_jobs() found job ${running_reciever} ${running_band} is running"
                else
                    [[ $verbosity -ge 1 ]] && printf "$(date): update_running_jobs_to_match_expected_jobs() found dead recording job '%s,%s'. get_recording_status() returned '%s', so starting job.\n"  \
                        ${running_reciever} ${running_band} "$status"
                    start_stop_job a ${running_reciever} ${running_band}
                fi
                break    ## No need to look further
            fi
        done
        if [[ $found_it == "no" ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): INFO: update_running_jobs_to_match_expected_jobs() found Schedule has changed. Terminating posting job '${running_reciever},${running_band}'"
            ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE} and tell the posting_dameon to stop.  Ot polls every 5 seconds and if there are no more clients will signal the recording deamon to stop
            start_stop_job z ${running_reciever} ${running_band} 
            schedule_change="yes"
        fi
    done

    if [[ ${schedule_change} == "yes" ]]; then
        ### A schedule change deleted a job.  Since it could be either a MERGED or REAL job, we can't be sure if there was a real job terminated.  
        ### So just wait 10 seconds for the 'running.stop' files to appear and then wait for all of them to go away
        sleep ${STOPPING_MIN_WAIT_SECS:-30}            ### Wait a minimum of 30 seconds to be sure the Kiwi to terminates rx sessions 
        wait_for_all_stopping_recording_daemons
    fi

    ### Find any jobs which will be new and start them
    local index_expected_jobs
    for index_expected_jobs in $( seq 0 $(( ${#EXPECTED_JOBS[*]} - 1)) ) ; do
        local expected_job=${EXPECTED_JOBS[${index_expected_jobs}]}
        local found_it="no"
        ### RUNNING_JOBS_FILE may have been changed each time through this loop, so reload it
        unset RUNNING_JOBS
        source ${RUNNING_JOBS_FILE}                           ### RUNNING_JOBS_FILE may have been changed above, so reload it
        temp_running_jobs=( ${RUNNING_JOBS[*]-} ) 
        for index_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
            if [[ ${expected_job} == ${temp_running_jobs[$index_running_jobs]} ]]; then
                found_it="yes"
            fi
        done
        if [[ ${found_it} == "no" ]]; then
            [[ $verbosity -ge 1 ]] && echo "$(date): update_running_jobs_to_match_expected_jobs() found that the schedule has changed. Starting new job '${expected_job}'"
            local expected_receiver=${expected_job%,*}
            local expected_band=${expected_job#*,}
            start_stop_job a ${expected_receiver} ${expected_band}       ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE}
            schedule_change="yes"
        fi
    done
    
    if [[ $schedule_change == "yes" ]]; then
        [[ $verbosity -ge 1 ]] && printf "$(date): update_running_jobs_to_match_expected_jobs() The schedule has changed so a new schedule has been applied: '${EXPECTED_JOBS[*]}'\n"
    else
        [[ $verbosity -ge 2 ]] && printf "$(date): update_running_jobs_to_match_expected_jobs() Checked the schedule and found that no jobs need to be changed\n"
    fi
}

### Read the running.jobs file and terminate one or all jobs listed there
function stop_running_jobs() {
    local stop_receiver=$1
    local stop_band=${2-}    ## BAND or no arg if $1 == 'all'

    [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs(${stop_receiver},${stop_band}) INFO: begin"
    if [[ ! -f ${RUNNING_JOBS_FILE} ]]; then
        [[ $verbosity -ge 1 ]] && echo "INFO: stop_running_jobs() found no RUNNING_JOBS_FILE, so nothing to do"
        return
    fi
    source ${RUNNING_JOBS_FILE}

    ### Since RUNNING_JOBS[] will be shortened by our stopping a job, we need to use a copy of it
    local temp_running_jobs=( ${RUNNING_JOBS[*]-} )

    ### Terminate any jobs currently running which will no longer be running 
    local index_running_jobs
    for index_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
        local running_job=(${temp_running_jobs[${index_running_jobs}]/,/ })
        local running_reciever=${running_job[0]}
        local running_band=${running_job[1]}
        [[ $verbosity -ge 3 ]] && echo "$(date): stop_running_jobs(${stop_receiver},${stop_band}) INFO: compare against running job ${running_job[@]}"
        if [[ ${stop_receiver} == "all" ]] || ( [[ ${stop_receiver} == ${running_reciever} ]] && [[ ${stop_band} == ${running_band} ]]) ; then
            [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO: is terminating running  job '${running_job[@]/ /,}'"
            start_stop_job z ${running_reciever} ${running_band}       ### start_stop_job() will fix up the ${RUNNING_JOBS_FILE}
        else
            [[ $verbosity -ge 3 ]] && echo "$(date): stop_running_jobs() INFO: does not match running  job '${running_job[@]}'"
        fi
    done
    ### Jobs signal they are terminated after the 40 second timeout when the running.stop files created by the above calls are no longer present
    local -i timeout=0
    local -i timeout_limit=$(( ${KIWIRECORDER_KILL_WAIT_SECS} + 20 ))
    [[ $verbosity -ge 0 ]] && echo "Waiting up to $(( ${timeout_limit} + 10 )) seconds for jobs to terminate..."
    sleep 10         ## While we give the dameons a change to create recording.stop files
    local found_running_file="yes"
    while [[ "${found_running_file}" == "yes" ]]; do
        found_running_file="no"
        for index_running_jobs in $(seq 0 $((${#temp_running_jobs[*]} - 1 )) ); do
            local running_job=(${temp_running_jobs[${index_running_jobs}]/,/ })
            local running_reciever=${running_job[0]}
            local running_band=${running_job[1]}
            if [[ ${stop_receiver} == "all" ]] || ( [[ ${stop_receiver} == ${running_reciever} ]] && [[ ${stop_band} == ${running_band} ]]) ; then
                [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO: checking to see if job '${running_job[@]/ /,}' is still running"
                local recording_dir=$(get_recording_dir_path ${running_reciever} ${running_band})
                if [[ -f ${recording_dir}/recording.stop ]]; then
                    [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO: found file '${recording_dir}/recording.stop'"
                    found_running_file="yes"
                else
                    [[ $verbosity -ge 2 ]] && echo "$(date): stop_running_jobs() INFO:    no file '${recording_dir}/recording.stop'"
                fi
            fi
        done
        if [[ "${found_running_file}" == "yes" ]]; then
            (( ++timeout ))
            if [[ ${timeout} -ge ${timeout_limit} ]]; then
                [[ $verbosity -ge 1 ]] && echo "$(date) stop_running_jobs() ERROR: timeout while waiting for all jobs to stop"
                return
            fi
            [[ $verbosity -ge 2 ]] && echo "$(date): kill_recording_daemon() is waiting for recording.stop files to disappear"
            sleep 1
        fi
    done
    [[ $verbosity -ge 1 ]] && echo "All running jobs have been stopped after waiting $(( ${timeout} + 10 )) seconds"
}
 
##############################################################
###  -j a cmd and -j z cmd
function start_or_kill_jobs() {
    local action=$1      ## 'a' === start or 'z' === stop
    local target_arg=${2:-all}            ### I got tired of typing '-j a/z all', so default to 'all'
    local target_info=(${target_arg/,/ })
    local target_receiver=${target_info[0]}
    local target_band=${target_info[1]-}
    if [[ ${target_receiver} != "all" ]] && [[ -z "${target_band}" ]]; then
        echo "ERROR: missing ',BAND'"
        exit 1
    fi

    [[ $verbosity -ge 2 ]] && echo "$(date): start_or_kill_jobs($action,$target_arg)"
    case ${action} in 
        a)
            if [[ ${target_receiver} == "all" ]]; then
                update_running_jobs_to_match_expected_jobs
            else
                start_stop_job ${action} ${target_receiver} ${target_band}
            fi
            ;;
        z)
            stop_running_jobs ${target_receiver} ${target_band} 
            ;;
        *)
            echo "ERROR: invalid action '${action}' specified.  Valid values are 'a' (start) and 'z' (kill/stop).  RECEIVER,BAND defaults to 'all'."
            exit
            ;;
    esac
}

### '-j ...' command
function jobs_cmd() {
    local args_array=(${1/,/ })           ### Splits the first comma-seperated field
    local cmd_val=${args_array[0]:- }     ### which is the command
    local cmd_arg=${args_array[1]:-}      ### For command a and z, we expect RECEIVER,BAND as the second arg, defaults to ' ' so '-j i' doesn't generate unbound variable error

    case ${cmd_val} in
        a|z)
            start_or_kill_jobs ${cmd_val} ${cmd_arg}
            ;;
        s)
            show_running_jobs ${cmd_arg}
            ;;
        l)
            tail_wspr_decode_job_log ${cmd_arg}
            ;;
	o)
	    check_for_zombies no
	    ;;
        *)
            echo "ERROR: '-j ${cmd_val}' is not a valid command"
            exit
    esac
}

##########################################################################################################################################################
########## Section which implements the watchdog system  ########################################################################################################
##########################################################################################################################################################
declare -r    PATH_WATCHDOG_PID=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.pid
declare -r    PATH_WATCHDOG_LOG=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.log

function seconds_until_next_even_minute() {
    local current_min_secs=$(date +%M:%S)
    local current_min=$((10#${current_min_secs%:*}))    ### chop off leading zeros
    local current_secs=$((10#${current_min_secs#*:}))   ### chop off leading zeros
    local current_min_mod=$(( ${current_min} % 2 ))
    current_min_mod=$(( 1 - ${current_min_mod} ))     ### Invert it
    local secs_to_even_min=$(( $(( ${current_min_mod} * 60 )) + $(( 60 - ${current_secs} )) ))
    echo ${secs_to_even_min}
}

function seconds_until_next_odd_minute() {
    local current_min_secs=$(date +%M:%S)
    local current_min=$((10#${current_min_secs%:*}))    ### chop off leading zeros
    local current_secs=$((10#${current_min_secs#*:}))   ### chop off leading zeros
    local current_min_mod=$(( ${current_min} % 2 ))
    local secs_to_odd_min=$(( $(( ${current_min_mod} * 60 )) + $(( 60 - ${current_secs} )) ))
    if [[ -z "${secs_to_odd_min}" ]]; then
        secs_to_odd_min=105   ### Default in case of math errors above
    fi
    echo ${secs_to_odd_min}
}

### Configure systemctl so this watchdog daemon runs at startup of the Pi
declare -r SYSTEMNCTL_UNIT_PATH=/lib/systemd/system/wsprdaemon.service
function setup_systemctl_deamon() {
    local start_args=${1--a}         ### Defaults to client start/stop args, but '-u a' (run as upload server) will configure with '-u a/z'
    local stop_args=${2--z} 
    local systemctl_dir=${SYSTEMNCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        echo "$(date): setup_systemctl_deamon() WARNING, this server appears to not be configured to use 'systemnctl' needed to start the kiwiwspr daemon at startup"
        return
    fi
    if [[ -f ${SYSTEMNCTL_UNIT_PATH} ]]; then
        [[ $verbosity -ge 3 ]] && echo "$(date): setup_systemctl_deamon() found this server already has a ${SYSTEMNCTL_UNIT_PATH} file. So leaving it alone."
        return
    fi
    local my_id=$(id -u -n)
    local my_group=$(id -g -n)
    cat > ${SYSTEMNCTL_UNIT_PATH##*/} <<EOF
    [Unit]
    Description= WSPR daemon
    After=multi-user.target

    [Service]
    User=${my_id}
    Group=${my_group}
    WorkingDirectory=${WSPRDAEMON_ROOT_DIR}
    ExecStart=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.sh ${start_args}
    ExecStop=${WSPRDAEMON_ROOT_DIR}/wsprdaemon.sh ${stop_args}
    Type=forking
    Restart=on-abort

    [Install]
    WantedBy=multi-user.target
EOF
   ask_user_to_install_sw "Configuring this computer to run the watchdog daemon after reboot or power up.  Doing this requires root priviledge" "wsprdaemon.service"
   sudo mv ${SYSTEMNCTL_UNIT_PATH##*/} ${SYSTEMNCTL_UNIT_PATH}    ### 'sudo cat > ${SYSTEMNCTL_UNIT_PATH} gave me permission errors
   sudo systemctl daemon-reload
   sudo systemctl enable wsprdaemon.service
   ### sudo systemctl start  kiwiwspr.service       ### Don't start service now, since we are already starting.  Service is setup to run during next reboot/powerup
   echo "Created '${SYSTEMNCTL_UNIT_PATH}'."
   echo "Watchdog daemon will now automatically start after a powerup or reboot of this system"
}

function enable_systemctl_deamon() {
    sudo systemctl enable wsprdaemon.service
}
function disable_systemctl_deamon() {
    sudo systemctl disable wsprdaemon.service
}

##########################################################################################################################################################
########## Section which creates and manages the 'top level' watchdog daemon  ############################################################################
##########################################################################################################################################################
### Wake up every odd minute and verify that the system is running properly
function watchdog_daemon() 
{
    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    printf "$(date): watchdog_daemon() starting as pid $$\n"
    while true; do
        [[ $verbosity -ge 2 ]] && echo "$(date): watchdog_daemon() is awake"
        validate_configuration_file
        update_master_hashtable
        spawn_upload_daemons
        check_for_zombies
        start_or_kill_jobs a all
        purge_stale_recordings
        if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]] || [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS-no} == "yes" ]]; then
            plot_noise 24
        fi
        check_kiwi_rx_channels
        check_kiwi_gps
        print_new_ov_lines          ## 
        local sleep_secs=$( seconds_until_next_odd_minute )
        [[ $verbosity -ge 2 ]] && echo "$(date): watchdog_daemon() complete.  Sleeping for $sleep_secs seconds."
        sleep ${sleep_secs}
    done
}


### '-a' and '-w a' cmds run this:
function spawn_watchdog_daemon(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}
    local watchdog_pid

    if [[ -f ${watchdog_pid_file} ]]; then
        watchdog_pid=$(cat ${watchdog_pid_file})
        if [[ ${watchdog_pid} =~ ^[0-9]+$ ]]; then
            if ps ${watchdog_pid} > /dev/null ; then
                echo "Watchdog deamon with pid '${watchdog_pid}' is already running"
                return
            else
                echo "Deleting watchdog pid file '${watchdog_pid_file}' with stale pid '${watchdog_pid}'"
            fi
        fi
        rm -f ${watchdog_pid_file}
    fi
    setup_systemctl_deamon
    watchdog_daemon > ${PATH_WATCHDOG_LOG} 2>&1  &   ### Redriecting stderr in watchdog_daemon() left stderr still output to PATH_WATCHDOG_LOG
    echo $! > ${PATH_WATCHDOG_PID}
    watchdog_pid=$(cat ${watchdog_pid_file})
    echo "Watchdog deamon with pid '${watchdog_pid}' is now running"
}

### '-w l cmd runs this
function tail_watchdog_log() {
    less +F ${PATH_WATCHDOG_LOG}
}

### '-w s' cmd runs this:
function show_watchdog(){
    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}

    if [[ ! -f ${watchdog_pid_file} ]]; then
        if [[ ${verbosity} -ge 1 ]]; then
            echo "$(date): show_watchdog() found no watchdog daemon pid file '${watchdog_pid_file}'"
        else
            echo "No Watchdog deaemon is running"
        fi
        return
    fi
    local watchdog_pid=$(cat ${watchdog_pid_file})
    if [[ ! ${watchdog_pid} =~ ^[0-9]+$ ]]; then
        echo "Watchdog pid file '${watchdog_pid_file}' contains '${watchdog_pid}' which is not a decimal integer number"
        return
    fi
    if ! ps ${watchdog_pid} > /dev/null ; then
        echo "Watchdog deamon with pid '${watchdog_pid}' not running"
        rm ${watchdog_pid_file}
        return
    fi
    if [[ ${verbosity} -ge 1 ]]; then
        echo "$(date): Watchdog daemon with pid ${watchdog_pid} is running"
    else
        echo "The watchdog daemon is running"
    fi
}

### '-w z' runs this:
function kill_watchdog() {
    show_watchdog

    local watchdog_pid_file=${PATH_WATCHDOG_PID}
    local watchdog_file_dir=${watchdog_pid_file%/*}
    if [[ ! -f ${watchdog_pid_file} ]]; then
        echo "Watchdog pid file '${watchdog_pid_file}' doesn't exist"
        return
    fi
    local watchdog_pid=$(cat ${watchdog_pid_file})    ### show_watchog returns only if this file is valid
    [[ ${verbosity} -ge 2 ]] && echo "$(date): kill_watchdog() file '${watchdog_pid_file} which contains pid ${watchdog_pid}"

    kill ${watchdog_pid}
    echo "Killed watchdog with pid '${watchdog_pid}'"
    rm ${watchdog_pid_file}
}

#### -w [i,a,z] command
function watchdog_cmd() {
    [[ ${verbosity} -ge 2 ]] && echo "$(date): watchdog_cmd() got cmd $1"
    
    case ${1} in
        a)
            spawn_watchdog_daemon
            ;;
        z)
            kill_watchdog
            kill_upload_daemons
            ;;
        s)
            show_watchdog
            ;;
        l)
            tail_watchdog_log
            ;;
        *)
            echo "ERROR: argument '${1}' not valid"
            exit 1
    esac
}

##########################################################################################################################################################
########## Section which creates and uploads the noise level graphs ######################################################################################
##########################################################################################################################################################

### This is a hack, but use the maidenhead value of the first receiver as the global locator for signal_level graphs and logging
function get_my_maidenhead() {
    local first_rx_line=(${RECEIVER_LIST[0]})
    local first_rx_maidenhead=${first_rx_line[3]}
    echo ${first_rx_maidenhead}
}

function plot_noise() {
    local my_maidenhead=$(get_my_maidenhead)
    local signal_levels_root_dir=${WSPRDAEMON_ROOT_DIR}/signal_levels
    local noise_plot_dir=${WSPRDAEMON_ROOT_DIR}/noise_plot
    mkdir -p ${noise_plot_dir}
    local noise_calibration_file=${noise_plot_dir}/noise_ca_vals.csv

    if [[ -f ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} ]] ; then
        local now_secs=$(date +%s)
        local graph_secs=$(date -r ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} +%s)
        local graph_age_secs=$(( ${now_secs} - ${graph_secs} ))

        if [[ ${graph_age_secs} -lt ${GRAPH_UPDATE_RATE-480} ]]; then
            ### The python script which creates the graph file is very CPU intensive and causes the KPH Pis to fall behind
            ### So create a new graph file only every 480 seconds (== 8 minutes), i.e. every fourth WSPR 2 minute cycle
            [[ ${verbosity} -gt 2 ]] && echo "plot_noise() found graphic file is only ${graph_age_secs} seconds old, so don't update it"
            return
        fi
    fi

    if [[ ! -f ${noise_calibration_file} ]]; then
        echo "# Cal file for use with 'wsprdaemon.sh -p'" >${noise_calibration_file}
        echo "# Values are: Nominal bandwidth, noise equiv bandwidth, RMS offset, freq offset, FFT_band, Threshold, see notes for details" >>${noise_calibration_file}
        ## read -p 'Enter nominal kiwirecorder.py bandwidth (500 or 320Hz):' nom_bw
        ## echo "Using defaults -50.4dB for RMS offset, -41.0dB for FFT offset, and +13.1dB for FFT %coefficients correction"
        ### echo "Using equivalent RMS and FFT noise bandwidths based on your nominal bandwidth"
        local nom_bw=320     ## wsprdaemon.sh always uses 320 hz BW
        if [ $nom_bw == 500 ]; then
            local enb_rms=427
            local fft_band=-12.7
        else
            local enb_rms=246
            local fft_band=-13.9
        fi
        echo $nom_bw","$enb_rms",-50.4,-41.0,"$fft_band",13.1" >> ${noise_calibration_file}
    fi
    # noise records are all 2 min apart so 30 per hour so rows = hours *30. The max number of rows we need in the csv file is (24 *30), so to speed processing only take that number of rows from the log file
    local -i rows=$((24*30))

    ### convert wsprdaemon AI6VN  sox stats format to csv for excel or Python matplotlib etc

    for log_file in ${signal_levels_root_dir}/*/*/signal-levels.log ; do
        local csv_file=${log_file%.log}.csv
        if [[ ! -f ${log_file} ]]; then
            [[ ${verbosity} -gt 1 ]] && echo "$(date): plot_noise() found no expected log file ${log_file}"
            rm -f ${csv_file}
            continue
        fi
        local log_file_lines=$(( $(cat ${log_file} | wc -l ) - 2 ))  
        if [[ "${log_file_lines}" -le 0 ]]; then
            ### The log file has only the two header lines
            [[ ${verbosity} -gt 1 ]] && echo "$(date): plot_noise() found log file ${log_file} has only the header lines"
            rm -f ${csv_file}
            continue
        fi
            
        local csv_lines=${rows}
        if [[ ${csv_lines} -gt ${log_file_lines} ]]; then
            [[ ${verbosity} -gt 1 ]] && echo "$(date): plot_noise() log file ${log_file} has only ${log_file_lines} lines in it, which is less than 24 hours of data."
            csv_lines=${log_file_lines}
        fi
        #  format conversion is by Rob AI6VN - could work directly from log file, but nice to have csv files GG using tail rather than cat
        tail -n ${csv_lines} ${log_file} \
            | sed -nr '/^[12]/s/\s+/,/gp' \
            | sed 's=^\(..\)\(..\)\(..\).\(..\)\(..\):=\3/\2/\1 \4:\5=' \
            | awk -F ',' '{ if (NF == 16) print $0 }'  > ${SIGNAL_LEVELS_TMP_CSV_FILE}
	[[ -s ${SIGNAL_LEVELS_TMP_CSV_FILE} ]] && mv ${SIGNAL_LEVELS_TMP_CSV_FILE} ${log_file%.log}.csv  ### only create .csv if it has at least one line of data
    done
    local band_paths=(${signal_levels_root_dir}/*/*/signal-levels.csv)  
    IFS=$'\n' 
    local sorted_paths=$(sort -t / -rn -k 7,7  <<< "${band_paths[*]}" | tr '\n' ' ' )
    unset IFS
    local signal_band_count=${#band_paths[*]}
    ### local band_file_lines=$(cat ${sorted_paths[@]} | wc -l )
    if [[ ${signal_band_count} -eq 0 ]] ; then ### || [[ ${signal_band_count} -ne ${band_file_lines} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): plot_noise() ERROR, no noise log files signal_band_count=${signal_band_count}.  Don't plot"  ### , or ${signal_band_count} -ne ${band_file_lines}.  Don't plot"
    else
        create_noise_graph ${SIGNAL_LEVEL_UPLOAD_ID-wsprdaemon.sh}  ${my_maidenhead} ${SIGNAL_LEVELS_TMP_NOISE_GRAPH_FILE} ${noise_calibration_file} "${sorted_paths[@]}"
        mv ${SIGNAL_LEVELS_TMP_NOISE_GRAPH_FILE} ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}
        if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]]; then
            [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() is configured to display local web page graphs"
            sudo  cp -p  ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}  ${SIGNAL_LEVELS_WWW_NOISE_GRAPH_FILE}
        fi
        if [[ "${SIGNAL_LEVEL_UPLOAD_GRAPHS-no}" == "yes" ]] && [[ ${SIGNAL_LEVEL_UPLOAD_ID-none} != "none" ]]; then
            if [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS_FTP_MODE:-yes} == yes ]]; then
                local upload_file_name=${SIGNAL_LEVEL_UPLOAD_ID}-$(date -u +"%y-%m-%d-%H-%M")-noise_graph.png
                local upload_url=${SIGNAL_LEVEL_FTP_URL-graphs.wsprdaemon.org/upload}/${upload_file_name}
                local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-noisegraphs}
                declare SIGNAL_LEVEL_FTP_PASSWORD_DEFAULT="xahFie6g"  ## Hopefully this never needs to change 
                local upload_password=${SIGNAL_LEVEL_FTP_PASSWORD-${SIGNAL_LEVEL_FTP_PASSWORD_DEFAULT}}
                local upload_rate_limit=$(( ${SIGNAL_LEVEL_FTP_RATE_LIMIT_BPS-1000000} / 8 ))        ## SIGNAL_LEVEL_FTP_RATE_LIMIT_BPS can be declared in .conf. It is in bits per second.

                [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() starting ftp upload of ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} to ftp://${upload_url}"
                curl -s --limit-rate ${upload_rate_limit} -T ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} --user ${upload_user}:${upload_password} ftp://${upload_url}
                [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() ftp upload is complete"
            else
                local graphs_server_address=${GRAPHS_SERVER_ADDRESS:-graphs.wsprdaemon.org}
                local graphs_server_password=${SIGNAL_LEVEL_UPLOAD_GRAPHS_PASSWORD-wsprdaemon-noise}
                sshpass -p ${graphs_server_password} ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -p ${LOG_SERVER_PORT-22} wsprdaemon@${graphs_server_address} "mkdir -p ${SIGNAL_LEVEL_UPLOAD_ID}" 2>/dev/null
                sshpass -p ${graphs_server_password} scp -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -P ${LOG_SERVER_PORT-22} ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} \
                    wsprdaemon@${graphs_server_address}:${SIGNAL_LEVEL_UPLOAD_ID}/${SIGNAL_LEVELS_NOISE_GRAPH_FILE##*/} > /dev/null 2>&1
                [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() configured to upload  web page graphs, so 'scp ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} wsprdaemon@${graphs_server_address}:${SIGNAL_LEVEL_UPLOAD_ID}/${SIGNAL_LEVELS_NOISE_GRAPH_FILE##*/}'"
            fi
        fi
    fi
}

declare -r NOISE_PLOT_CMD=${WSPRDAEMON_TMP_DIR}/noise_plot.py

###
function create_noise_graph() {
    local receiver_name=$1
    local receiver_maidenhead=$2
    local output_pngfile_path=$3
    local calibration_file_path=$4
    local csv_file_list="$5"        ## This is a space-seperated list of the .csv file paths, so "" are required

    create_noise_python_script 
    python3 ${NOISE_PLOT_CMD} ${receiver_name} ${receiver_maidenhead} ${output_pngfile_path} ${calibration_file_path} "${csv_file_list}"
}

function create_noise_python_script() {
    source ${WSPRDAEMON_CONFIG_FILE}      ### To read NOISE_GRAPHS_* parameters, if they are defined

    cat > ${NOISE_PLOT_CMD} << EOF
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Filename: noise_plot.py
# April-May  2019  Gwyn Griffiths G3ZIL
# Use matplotlib to plot noise levels recorded by wsprdaemon by the sox stats RMS and sox stat -freq methods
# V0 Testing prototype 

# Import the required Python modules and methods some may need downloading 
from __future__ import print_function
import math
import datetime
#import scipy
import numpy as np
from numpy import genfromtxt
import csv
import matplotlib as mpl
mpl.use('Agg')
import matplotlib.pyplot as plt
#from matplotlib import cm
import matplotlib.dates as mdates
import sys

# Get cmd line args
reporter=sys.argv[1]
maidenhead=sys.argv[2]
output_png_filepath=sys.argv[3]
calibration_file_path=sys.argv[4]
csv_file_path_list=sys.argv[5].split()    ## noise_plot.py KPH "/home/pi/.../2200 /home/pi/.../630 ..."

# read in the reporter-specific calibration file and print out
# if one didn't exist the bash script would have created one
# the user can of course manually edit the specific noise_cal_vals.csv file if need be
cal_vals=genfromtxt(calibration_file_path, delimiter=',')
nom_bw=cal_vals[0]
ne_bw=cal_vals[1]
rms_offset=cal_vals[2]
freq_offset=cal_vals[3]
fft_band=cal_vals[4]
threshold=cal_vals[5]

# need to set the noise equiv bw for the -freq method. It is 322 Hz if nom bw is 500Hz else it is ne_bw as set
if nom_bw==500:
    freq_ne_bw=322
else:
    freq_ne_bw=ne_bw

x_pixel=${NOISE_GRAPHS_X_PIXEL-40}
y_pixel=${NOISE_GRAPHS_Y_PIXEL-30}
my_dpi=${NOISE_GRAPHS_DPI-50}         # set dpi and size for plot - these values are largest I can get on Pi window, resolution is good
fig = plt.figure(figsize=(x_pixel, y_pixel), dpi=my_dpi)
fig.subplots_adjust(hspace=0.4, wspace=0.4)
plt.rcParams.update({'font.size': 18})

# get, then set, start and stop time in UTC for use in overall title of charts
stop_t=datetime.datetime.utcnow()
start_t=stop_t-datetime.timedelta(days=1)   ### Plot last 24 hours
stop_time=stop_t.strftime('%Y-%m-%d %H:%M')
start_time=start_t.strftime('%Y-%m-%d %H:%M')

fig.suptitle("Site: '%s' Maidenhead: '%s'\n Calibrated noise (dBm in 1Hz, Temperature in K) red=RMS blue=FFT\n24 hour time span from '%s' to '%s' UTC" % (reporter, maidenhead, start_time, stop_time), x=0.5, y=0.99, fontsize=24)

# Process the list of csv  noise files
j=1
# get number of csv files to plot then divide by three and round up to get number of rows
plot_rows=int(math.ceil((len(csv_file_path_list)/3.0)))
for csv_file_path in csv_file_path_list:
    # matplotlib x axes with time not straightforward, get timestamp in separate 1D array as string
    timestamp  = genfromtxt(csv_file_path, delimiter=',', usecols=0, dtype=str)
    noise_vals = genfromtxt(csv_file_path, delimiter=',')[:,1:]  

    n_recs=int((noise_vals.size)/15)              # there are 15 comma separated fields in each row, all in one dimensional array as read
    noise_vals=noise_vals.reshape(n_recs,15)      # reshape to 2D array with n_recs rows and 15 columns

    # now  extract the freq method data and calibrate
    freq_noise_vals=noise_vals[:,13]  ### +freq_offset+10*np.log10(1/freq_ne_bw)+fft_band+threshold
    rms_trough_start=noise_vals[:,3]
    rms_trough_end=noise_vals[:,11]
    rms_noise_vals=np.minimum(rms_trough_start, rms_trough_end)
    rms_noise_vals=rms_noise_vals     #### +rms_offset+10*np.log10(1/ne_bw)
    ov_vals=noise_vals[:,14]          ### The OV (overload counts) reported by Kiwis have been added in V2.9

    # generate x axis with time
    fmt = mdates.DateFormatter('%H')          # fmt line sets the format that will be printed on the x axis
    timeArray = [datetime.datetime.strptime(k, '%d/%m/%y %H:%M') for k in timestamp]     # here we extract the fields from our original .csv timestamp

    ax1 = fig.add_subplot(plot_rows, 3, j)
    ax1.plot(timeArray, freq_noise_vals, 'b.', ms=2)
    ax1.plot(timeArray, rms_noise_vals, 'r.', ms=2)
    # ax1.plot(timeArray, ov_vals, 'g.', ms=2)       # OV values will need to be scaled if they are to appear on the graph along with noise levels

    ax1.xaxis.set_major_formatter(fmt)
 
    path_elements=csv_file_path.split('/')
    plt.title("Receiver %s   Band:%s" % (path_elements[len(path_elements)-3], path_elements[len(path_elements)-2]), fontsize=24)
    
    #axes = plt.gca()
    # GG chart start and stop UTC time as end now and start 1 day earlier, same time as the x axis limits
    ax1.set_xlim([datetime.datetime.utcnow()-datetime.timedelta(days=1), datetime.datetime.utcnow()])
    # first get 'loc' for the hour tick marks at an interval of 2 hours then use 'loc' to set the major tick marks and grid
    loc=mpl.dates.HourLocator(byhour=None, interval=2, tz=None)
    ax1.xaxis.set_major_locator(loc)

    #   set y axes lower and upper limits
    y_dB_lo=${NOISE_GRAPHS_Y_MIN--175}
    y_dB_hi=${NOISE_GRAPHS_Y_MAX--105}
    y_K_lo=10**((y_dB_lo-30)/10.)*1e23/1.38
    y_K_hi=10**((y_dB_hi-30)/10.)*1e23/1.38
    ax1.set_ylim([y_dB_lo, y_dB_hi])
    ax1.grid()

    # set up secondary y axis
    ax2 = ax1.twinx()
    # automatically set its limits to be equivalent to the dBm limits
    ax2.set_ylim([y_K_lo, y_K_hi])
    ax2.set_yscale("log")

    j=j+1  
fig.savefig(output_png_filepath)
EOF
}

##########################################################################################################################################################
########## Section which implements the help menu ########################################################################################################
##########################################################################################################################################################
function usage() {
    echo "usage:                VERSION = ${VERSION}
    ${WSPRDAEMON_ROOT_PATH} -[asz} Start,Show Status, or Stop the watchdog daemon
    
     This program reads the configuration file wsprdaemon.conf which defines a schedule to capture and post WSPR signals from one or more KiwiSDRs 
     and/or AUDIO inputs and/or RTL-SDRs.
     Each KiwiSDR can be configured to run 8 separate bands, so 2 Kiwis can spot every 2 minute cycle from all 14 LF/MF/HF bands.
     In addition, the operator can configure 'MERG_..' receivers which posts decodes from 2 or more 'real' receivers 
     but selects only the best SNR for each received callsign (i.e no double-posting)

     Each 2 minute WSPR cycle this script creates a separate .wav recording file on this host from the audio output of each configured [receiver,band]
     At the end of each cycle, each of those files is processed by the 'wsprd' WSPR decode application included in the WSJT-x application
     which must be installed on this server. The decodes output by 'wsprd' are then spotted to the WSPRnet.org database. 
     The script allows individual [receiver,band] control as well as automatic scheduled band control via a watchdog process 
     which is automatically started during the server's bootup process.

    -h                            => print this help message (execute '-vh' to get a description of the architecture of this program)

    -a                            => stArt watchdog daemon which will start all scheduled jobs ( -w a )
    -z                            => stop watchdog daemon and all jobs it is currently running (-w z )   (i.e.zzzz => go to sleep)
    -s                            => show Status of watchdog and jobs it is currently running  (-w s ; -j s )
    -p HOURS                      => generate ~/wsprdaemon/signal-levels.jpg for the last HOURS of SNR data

    These flags are mostly intended for advanced configuration:

    -i                            => list audio and RTL-SDR devices attached to this computer
    -j ......                     => Start, Stop and Monitor one or more WSPR jobs.  Each job is composed of one capture daemon and one decode/posting daemon 
    -j a,RECEIVER_NAME[,WSPR_BAND]    => stArt WSPR jobs(s).             RECEIVER_NAME = 'all' (default) ==  All RECEIVER,BAND jobs defined in wsprdaemon.conf
                                                                OR       RECEIVER_NAME from list below
                                                                     AND WSPR_BAND from list below
    -j z,RECEIVER_NAME[,WSPR_BAND]    => Stop (i.e zzzzz)  WSPR job(s). RECEIVER_NAME defaults to 'all'
    -j s,RECEIVER_NAME[,WSPR_BAND]    => Show Status of WSPR job(s). 
    -j l,RECEIVER_NAME[,WSPR_BAND]    => Watch end of the decode/posting.log file.  RECEIVER_ANME = 'all' is not valid
    -j o                          => Search for zombie jobs (i.e. not in current scheduled jobs list) and kill them

    -w ......                     => Start, Stop and Monitor the Watchdog daemon
    -w a                          => stArt the watchdog daemon
    -w z                          => Stop (i.e put to sleep == zzzzz) the watchdog daemon
    -w s                          => Show Status of watchdog daemon
    -w l                          => Watch end of watchdog.log file by executing 'less +F watchdog.log'

    -v                            => Increase verbosity of diagnotic printouts 
    -d                            => Signal all running processes as found in the *.pid files in the current directory to increment the logging verbosity
                                     This permits changes to logging verbosity without restarting WD
    -D                            => Signal all to decrement verbosity
    -u CMD                        => Runs on wsprdaemon.org to process uploaded *.tbz files.  CMD: 'a' => start, s => 'status', 'z' => stop

    Examples:
     ${0##*/} -a                      => stArt the watchdog daemon which will in turn run '-j a,all' starting WSPR jobs defined in '${WSPRDAEMON_CONFIG_FILE}'
     ${0##*/} -z                      => Stop the watchdog daemon but WSPR jobs will continue to run 
     ${0##*/} -s                      => Show the status of the watchdog and all of the currently running jobs it has created
     ${0##*/} -j a,RECEIVER_LF_MF_0,2200   => on RECEIVER_LF_MF_0 start a WSPR job on 2200M
     ${0##*/} -j a                     => start WSPR jobs on all receivers/bands configured in ${WSPRDAEMON_CONFIG_FILE}
     ${0##*/} -j z                     => stop all WSPR jobs on all receivers/bands configured in ${WSPRDAEMON_CONFIG_FILE}, but note 
                                          that the watchdog will restart them if it is running

    Valid RECEIVER_NAMEs which have been defined in '${WSPRDAEMON_CONFIG_FILE}':
    $(list_known_receivers)

    WSPR_BAND  => {2200|630|160|80|80eu|60|60eu|40|30|20|17|15|12|10|6|2|1|0} 

    Author Rob Robinett AI6VN rob@robinett.us   with much help from John Seamons and a group of beta testers
    I would appreciate reports which compare the number of reports and the SNR values reported by wsprdaemon.sh 
        against values reported by the same Kiwi's autowspr and/or that same Kiwi fed to WSJT-x 
    In my testing wsprdaemon.sh always reports the same or more signals and the same SNR for those detected by autowspr,
        but I cannot yet guarantee that wsprdaemon.sh is always better than those other reporting methods.
    "
    [[ ${verbosity} -ge 1 ]] && echo "
    An overview of the SW architecture of wsprdaemon.sh:

    This program creates a error-resilient stand-alone WSPR receiving appliance which should run 24/7/365 without user attention and will recover from 
    loss of power and/or Internet connectivity. 
    It has been  primarily developed and deployed on Rasberry Pi 3Bs which can support 20 or more WSPR decoding bands when KiwiSDRs are used as the demodulated signal sources. 
    However it is runing on other Debian 16.4 servers like the odroid and x86 servers (I think) without and modifications.  Even Windows runs bash today, so perhaps
    it could be ported to run there too.  It has run on Max OSX, but I haven't check its operation there in many months.
    It is almost entirely a bash script which excutes the 'wsprd' binary supplied in the WSJT-x distribution.  To use a KiwiSDR as the signal soure it
    uses a Python script supplied by the KiwiSDR author 
    "
}

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
