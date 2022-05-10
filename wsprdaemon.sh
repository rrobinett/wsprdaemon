#!/bin/bash

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

[[ ${v:-yes} == "yes" ]] && echo "wsprdaemon.sh Copyright (C) 2020-2022  Robert S. Robinett
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

#declare -r VERSION=2.10i            ### Client mode:  On Ubuntu 20.04 LTS, Fix installation of python-numpy 
#declare -r VERSION=2.10j            ### Load WSJT-x V2.3.0 wsprd and jt9 commands and the libraries they need
#declare -r VERSION=3.0a             ### Move python code and other 'here' files to their own files instead of creating them inline 
#declare -r VERSION=3.0.1             ### Fix selections of best SNR in MERGEd receivers.  Change VERSION to 3.0.N
#declare -r VERSION=3.0.2             ### Enhance the Remote Acccess service to accept configuration of "no" 
#declare -r VERSION=3.0.2.1             ### Move remote access startup to startup.  Add support for 64 Pi OS
declare -r VERSION=3.0.2.2            ### Fix installaion of python 'astral' package on both buster and bullseye
                                     ### and  direct tunnel ssh traffice to local ssh server which is not configured to listen on the standard port 22
                                     ### and after spawning the frpc client service, check its status report to be sure it says is is "running"
                                    ### TODO: Fix kiwirecorder arguments
                                    ### TODO: Support FST4W decoding through the use of 'jt9'
                                    ### TODO: Flush antique ~/signal_level log files
                                    ### TODO: Fix inode overflows when SIGNAL_LEVEL_UPLOAD="no" (e.g. at LX1DQ)
                                    ### TODO: Split Python utilities in separate files maintained by git
                                    ### TODO: enhance config file validate_configuration_file() to check that all MERGEd receivers are defined.
                                    ### TODO: Try to extract grid for type 2 spots from ALL_WSPR.TXT 
                                    ### TODO: Proxy upload of spots from wsprdaemon.org to wsprnet.org
                                    ### TODO: Add VOACAP support
                                    ### TODO: Add VHF/UHF support using Soapy API
                                    ### TODO: Uploader should flush all spots, not just ones for current scheduled rxs 

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
source ${WSPRDAEMON_ROOT_DIR}/recording.sh
source ${WSPRDAEMON_ROOT_DIR}/decoding.sh
source ${WSPRDAEMON_ROOT_DIR}/posting.sh
source ${WSPRDAEMON_ROOT_DIR}/upload_client_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/upload_server_utils.sh
source ${WSPRDAEMON_ROOT_DIR}/kiwi_management.sh
source ${WSPRDAEMON_ROOT_DIR}/job_management.sh
source ${WSPRDAEMON_ROOT_DIR}/watchdog.sh
source ${WSPRDAEMON_ROOT_DIR}/usage.sh
source ${WSPRDAEMON_ROOT_DIR}/noise_graphs_daemon.sh

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
            watchdog_cmd z
            jobs_cmd     z
            check_for_zombies yes   ## silently kill any zombies
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
