#!/bin/bash

# Version 0.2  Add mutex 
# Version 0.3  upload to TIMESCALE rather than keeping in local log file and azimuths at tx and rx in that order added, km only, no miles
# Version 0.4  add_azi vertex corrected, use GG suggested fields and tags, add Band as a tag and add placeholder for c2_noise from WD users with absent data for now
# Version 0.5  GG using Droplet this acount for testing screening of tx_calls against list of first two characters
# Version 0.6  GG First version to upload to a Timescale database rather than Influx
# Version 0.7  RR shorten poll loop to 30 seconds.  Don't try to truncate the daemon.log file
# Version 0.8  RR spawn a daemon to FTP clean scrape files to logs1.wsprdaemon.org
# Version 0.9  RR Optionally use ~/ftp_uploads/* as source for new scrapes rather than going to wsprnet.org
# Version 1.0  RR Optionally use API interface to get new spots from wsprnet.org and populate the TS database 'wsprnet' table 'spots'
# Version 2.0  RR Add to github and use wd_utils.sh

shopt -s -o nounset          ### bash stops with error if undeclared variable is referenced

declare -r WSPRDAEMON_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd ${WSPRDAEMON_ROOT_DIR}

source wd_utils.sh
source wd_setup.sh

declare -r VERSION=2.0

source ${WSPRDAEMON_ROOT_DIR}/wsprnet-scraper.sh

declare scraper_daemon_list=(
   "wsprnet_scrape_daemon ${WSPRNET_SCRAPER_HOME_PATH}"
)

### Prints the help message
function usage(){
    echo "usage: $0  VERSION=$VERSION
    -a             stArt WSPRNET scraping daemon
    -s             Show daemon Status
    -z             Kill (put to sleep == ZZZZZ) running daemon
    -d/-D          increment / Decrement the verbosity of a running daemon
    -e/-E          enable / disablE starting daemon at boot time
    -v             Increment verbosity of diagnotic printouts
    -h             Print this message
    "
}

### Print out an error message if the command line arguments are wrong
function bad_args(){
    echo "ERROR: command line arguments not valid: '$1'" >&2
    echo
    usage
}

cmd=bad_args
cmd_arg="$*"

while getopts :aszdDeEnuvh opt ; do
    case $opt in
        a)
            cmd=daemons_list_action cmd_arg="a scraper_daemon_list"
            ;;
        s)
            cmd=daemons_list_action cmd_arg="s scraper_daemon_list"
            ;;
        z)
            cmd=daemons_list_action cmd_arg="z scraper_daemon_list"
            ;;
        d)
            cmd=increment_verbosity;
            ;;
        D)
            cmd=decrement_verbosity;
            ;;
        h)
            cmd=usage
            ;;
        v)
            let verbosity++
            echo "Verbosity = $verbosity" >&2
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit
            ;;
    esac
done

$cmd $cmd_arg

