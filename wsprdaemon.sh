#!/bin/bash
### The previous line signals to the vim editor that it should use its 'bash' editing mode when editing this file

###  Wsprdaemon:   A robust  decoding and reporting system for  WSPR 

###    Copyright (C) 2020-2022  Robert S. Robinett
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

[[ ${v:-no} == "yes" ]] && echo "wsprdaemon.sh Copyright (C) 2020-2022  Robert S. Robinett
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

#declare -r VERSION=3.0.2.6            ### Cleanup schedule change handling
#declare -r VERSION=3.0.3              ### Finished beta testing.  Decodes FST4W except type 3 packets which require use of shared memory interface to jt9
#declare -r VERSION=3.0.3.1            ### Use /dev/shm/wsprdaemon for TMP files
#declare -r VERSION=3.0.3.2            ### Record FST4W spectral_spreading to the 'metric' field of the extended_spot lines
                                       ### Add support for archiving of wav files to WD3
#declare -r VERSION=3.0.3.3            ### Get OV count from kiwi's /status page, not by counting 'ADC OV's' from the log file
#declare -r VERSION=3.0.3.4            ### 
#declare -r VERSION=3.0.3.5           ### Watchdog checks the status of REMOTE_ACCESS_CHANNEL in the conf file every 10 seconds and opens or closes the RAC from its current value
                                     ### Protect against corrupt .pid files
                                     ### Add support for POST_ALL_SPOTS  config variable
#declare -r VERSION=3.0.4            ### Rewrite posting_daemon to resist loss of spots from one or more members of a MERGed receiver
                                     ### Fix OV logging from Kiwis running SW which reports the overload count on the Kiwi's /status page
#declare -r VERSION=3.0.5            ### Enhance frequency resolution of FST4W decoding to .1 Hz
                                     ### Upload earlier by watching for when all wspr and jtx processes are done
#declare -r VERSION=3.0.6            ### Port to run on Ubuntu 22.04.1 LTS and Raspberry Pi 'bullseye'
#declare VERSION=3.0.7                ### Optimze Kiwi status reporting by cacheing one copy of /status
#declare VERSION=3.0.8                ### Fix bug in wsprnet uploader when there are more than 1000 cached spots
declare VERSION=3.0.9                ### Refine search for WSPR packet wav files
                                     ### TODO: Upload all of Kiwi status lines to wsprdaemon.org
                                     ### TODO: Add highest WF frequency bins to kiwi_ovs.log
                                     ### TODO: Enhance WD server to record WD status report table to TS DB so Arne can display active FST4W sites on Grafana map
                                     ### TODO: Add VHF/UHF support using Soapy API

if [[ $USER == "root" ]]; then
    echo "ERROR: This command '$0' should NOT be run as user 'root' or non-root users will experience file permissions problems"
    exit 1
fi

declare -r WSPRDAEMON_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
declare -r RUNNING_IN_DIR=${PWD}        ### Used by the '-d' and '-D' commands so they know where to look for *.pid files

cd ${WSPRDAEMON_ROOT_DIR}

source ${WSPRDAEMON_ROOT_DIR}/wd_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/wd_setup.sh
source ${WSPRDAEMON_ROOT_DIR}/noise_graphing.sh
check_for_needed_utilities
source ${WSPRDAEMON_ROOT_DIR}/wsprnet-scraper.sh
source ${WSPRDAEMON_ROOT_DIR}/atsc.sh
source ${WSPRDAEMON_ROOT_DIR}/ppm.sh
source ${WSPRDAEMON_ROOT_DIR}/kiwi_management.sh
source ${WSPRDAEMON_ROOT_DIR}/recording.sh
source ${WSPRDAEMON_ROOT_DIR}/decoding.sh
source ${WSPRDAEMON_ROOT_DIR}/posting.sh
source ${WSPRDAEMON_ROOT_DIR}/upload_client_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/upload_server_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/job_management.sh
source ${WSPRDAEMON_ROOT_DIR}/watchdog.sh
source ${WSPRDAEMON_ROOT_DIR}/usage.sh
source ${WSPRDAEMON_ROOT_DIR}/noise_graphs_daemon.sh
source ${WSPRDAEMON_ROOT_DIR}/wav_archive.sh

[[ -z "$*" ]] && usage

while getopts :aAzZshij:l:pvVw:dDu:U:r: opt ; do
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
            enable_systemctl_daemon 
            sudo systemctl start wsprdaemon
            ;;
        a)
            watchdog_cmd a
            ;;
        z)
            #watchdog_cmd z
            #jobs_cmd     z
            wd_kill_all    ## silently kill everything
            ;;
        Z)
            sudo systemctl stop wsprdaemon
            disable_systemctl_daemon 
            ;;
        s)
            proxy_connection_status
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
