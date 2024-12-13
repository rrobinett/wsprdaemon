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

[[ ${v:-no} == "yes" ]] && echo "wsprdaemon.sh Copyright (C) 2020-2024  Robert S. Robinett
This program comes with ABSOLUTELY NO WARRANTY; for details type './wsprdaemon.sh -h'
This is free software, and you are welcome to redistribute it under certain conditions.  execute'./wsprdaemon.sh -h' for details.
wsprdaemon depends heavily upon the 'wsprd' program and other technologies developed by Joe Taylor K1JT and others, to whom we are grateful.
Goto https://physics.princeton.edu/pulsar/K1JT/wsjtx.html to learn more about WSJT-x
"

### This bash script logs WSPR spots from one or more Kiwi
### It differs from the autowspr mode built in to the Kiwi by:
### 1) Processing the uncompressed audio .wav file through the 'wsprd' utility program supplied as part of the WSJT-x distribution
###    The latest 'wsprd' includes algorithmic improvements over the version included in the Kiwi
### 2) Executing 'wsprd -d', a deep search mode which sometimes detects 10% more signals in the .wav file
### 3) By executing on a more powerful CPU than the single core ARM in the Beaglebone, many more signals are extracted on busy WSPR bands,'
###    e.g. 20M during daylight hours
###
###  This script depends extensively upon the 'kiwirecorder.py' utility developed by John Seamons, the Kiwi author
###  I owe him much thanks for his encouragement and support 
###  Feel free to email me with questions or problems at:  rob@robinett.us
###  This script was originally developed on Mac OSX, but this version 0.1 has been tested only on the Raspberry Pi 3b+
###  On the 3b+ I am easily running 6 simultaneous WSPR decode sessions and expect to be able to run 12 sessions covering all the 
###  LF/MF/HF WSPR bands on one Pi
###
###  Rob Robinett AI6VN   rob@robinett.us    July 1, 2018
###
###  This software is provided for free but with no guarantees of its usefullness, functionality or reliability
###  You are free to make and distribute copies and modifications as long as you include this disclaimer
###  I welcome feedback about its performance and functionality

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

#declare VERSION=3.0.9                ### Refine search for WSPR packet wav files
#declare VERSION=3.1.0               ### Add support for KA9Q-radio and RX888
#declare VERSION=3.1.1               ### Add support for KA9Q-radio and RX888
#declare VERSION=3.1.2                 ### Add support for fixed AGC level to KA9Q receivers
                                       ### Add support for WSPR ansd WWV IQ file recording into compressed files in a series of tar archives
#declare VERSION=3.1.3                 ### Add support for WSPR-2 spectral spreading reports 
#declare VERSION=3.1.4                 ### Add support for the GRAPE system
#declare VERSION=3.1.5                 ### Revert to having Kiwi and RX888 do narrow audio filtering, not sox
#declare VERSION=3.1.6                 ### Install 4/19/24 KA9Q-radio
#declare VERSION=3.1.7                 ### Fix to handle changes in respones by wsprnet.org to uploads with duplicates
#declare VERSION=3.2.0                 ### Add all weprd and jt9 binaries.  Installs on Pi 5
#declare VERSION=3.2.1                 ### Increment version number so wspr.rocks will report which WD sites have been upgraded
#declare VERSION=3.2.2                 ### Adds ka9q-web and FT4/8 reporting 
#declare VERSION=3.2.3                 ### Merge 3.2.0 branch into master, a second time

if [[ $USER == "root" ]]; then
    echo "ERROR: This command '$0' should NOT be run as user 'root' or non-root users will experience file permissions problems"
    exit 1
fi

### These need to be defined first
declare -r WSPRDAEMON_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r VERSION=$(cd ${WSPRDAEMON_ROOT_DIR}; git describe --tags --abbrev=0)-$(cd ${WSPRDAEMON_ROOT_DIR}; git rev-list --count HEAD)

declare -r RUNNING_IN_DIR=${PWD}        ### Used by the '-d' and '-D' commands so they know where to look for *.pid files
################# Check that our recordings go to a tmpfs (i.e. RAM disk) file system ################
declare WSPRDAEMON_TMP_DIR=/dev/shm/wsprdaemon
mkdir -p /dev/shm/wsprdaemon
if [[ -n "${WSPRDAEMON_TMP_DIR-}" && -d ${WSPRDAEMON_TMP_DIR} ]] ; then
    true
    ### The user has configured a TMP dir
    #wd_logger 2 "Using user configured TMP dir ${WSPRDAEMON_TMP_DIR}"
elif df /tmp/wspr-captures > /dev/null 2>&1; then
    ### Legacy name for /tmp file system.  Leave it alone
    WSPRDAEMON_TMP_DIR=/tmp/wspr-captures
elif df /tmp/wsprdaemon > /dev/null 2>&1; then
    WSPRDAEMON_TMP_DIR=/tmp/wsprdaemon
fi

cd ${WSPRDAEMON_ROOT_DIR}

source ${WSPRDAEMON_ROOT_DIR}/bash-aliases       ### Set up WD aliases for all users
source ${WSPRDAEMON_ROOT_DIR}/wd_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/config_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/wd_setup.sh
source ${WSPRDAEMON_ROOT_DIR}/ka9q-utils.sh
source ${WSPRDAEMON_ROOT_DIR}/noise_graphing.sh
source ${WSPRDAEMON_ROOT_DIR}/wsprnet-scraper.sh
source ${WSPRDAEMON_ROOT_DIR}/atsc.sh
source ${WSPRDAEMON_ROOT_DIR}/ppm.sh
source ${WSPRDAEMON_ROOT_DIR}/kiwi-utils.sh
source ${WSPRDAEMON_ROOT_DIR}/recording.sh
source ${WSPRDAEMON_ROOT_DIR}/decoding.sh
source ${WSPRDAEMON_ROOT_DIR}/posting.sh
source ${WSPRDAEMON_ROOT_DIR}/upload_client_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/upload_server_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/job_management.sh
source ${WSPRDAEMON_ROOT_DIR}/usage.sh
source ${WSPRDAEMON_ROOT_DIR}/noise_graphs_daemon.sh
source ${WSPRDAEMON_ROOT_DIR}/wav_archive.sh
source ${WSPRDAEMON_ROOT_DIR}/grape-utils.sh
source ${WSPRDAEMON_ROOT_DIR}/watchdog.sh         ### Should come last

[[ -z "$*" ]] && usage

while getopts :aAzZsg:hij:l:pvVw:dDu:U:r: opt ; do
    case $opt in
        l)
            log_file_viewing  $OPTARG
            ;;
        r)
            spawn_wav_recording ${OPTARG//,/ }
            ;;
        U)
            uploading_controls $OPTARG
            ;;
        A)
            if [[ ${WD_STARTUP_DELAY_SECS-0} -gt 0 ]]; then
                echo "Wsprdaemon is delaying startup for ${WD_STARTUP_DELAY_SECS} seconds"
                wd_sleep ${WD_STARTUP_DELAY_SECS}
            fi
            watchdog_cmd a
            ;;
        a)
            start_systemctl_daemon
            ;;
        Z)
            wd_kill_all    ## silently kill everything
            ;;
        z)
            stop_systemctl_daemon
            ;;
        s)
            jobs_cmd     s
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
            upload_server_cmd $OPTARG
            ;;
        g)
            grape_menu -$OPTARG
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
