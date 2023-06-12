#!/bin/bash 

#############################################################
################ Posting ####################################
#############################################################

declare POSTING_SUPPLIERS_SUBDIR="posting_suppliers.d"    ### Subdir under each posting daemon directory which contains symlinks to the decoding daemon(s) subdirs where spots for this daemon are copied
declare -r WAV_FILE_POLL_SECONDS=5                        ### How often to poll for the 2 minute .wav record file to be filled

function get_posting_dir_path(){
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_posting_path="${WSPRDAEMON_TMP_DIR}/posting.d/${receiver_name}/${receiver_rx_band}"

    echo ${receiver_posting_path}
}

function get_posting_pid_file_path()
{
    local __return_pid_file_path=$1
    local receiver_name=$2
    local receiver_rx_band=$3

    local receiver_posting_path="${WSPRDAEMON_TMP_DIR}/posting.d/${receiver_name}/${receiver_rx_band}"
    local pid_file_path=${receiver_posting_path}/posting_daemon.pid

    if [[ ! -f ${pid_file_path} ]]; then
        wd_logger 1 "There is no pid_file_path'${pid_file_path}"
        eval ${__return_pid_file_path}=""
        return 1
    fi
    wd_logger 1 "Found pid_file_path=${pid_file_path}"
    eval ${__return_pid_file_path}=\${pid_file_path}
    return 0
}

###############
function run_recording_daemons()
{
    local posting_receiver_band="$1"
    local posting_receiver_modes="$2"
    local real_receiver_list=( ${@:3} )

    local real_receiver
    for real_receiver  in ${real_receiver_list[@]} ; do
        (spawn_decoding_daemon ${real_receiver} ${posting_receiver_band} ${posting_receiver_modes})  ### the '()' suppresses the effects of the 'cd' executed by spawn_decoding_daemon()
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to 'spawn_decoding_daemon ${real_receiver} ${posting_receiver_band} ${posting_receiver_modes}' => ${ret_code}"
        fi
    done
}

### This daemon creates links from the posting dirs of all the $4 receivers to a local subdir, then waits for YYMMDD_HHMM_wspr_spots.txt files to appear in all of those dirs, then merges them
### and 
declare POSTING_DAEMON_POLLING_RATE=${POSTING_DAEMON_POLLING_RATE-5}    ### By default poll every 5 seconds for new spot files to appear
function posting_daemon() 
{
    local posting_receiver_name=${1}
    local posting_receiver_band=${2}
    local posting_receiver_modes=${3}
    local real_receiver_list=($4)
    local real_receiver_count=${#real_receiver_list[@]}

    wd_logger 1 "Starting with args ${posting_receiver_name} ${posting_receiver_band} ${posting_receiver_modes} '${real_receiver_list[*]}'"

    setup_verbosity_traps          ## So we can increment and decrement verbosity without restarting WD
    source ${WSPRDAEMON_CONFIG_FILE}

    local posting_call_sign="$(get_receiver_call_from_name ${posting_receiver_name})"
    local posting_grid="$(get_receiver_grid_from_name ${posting_receiver_name})"
    
    ### Where to put the spots from the one or more real receivers for the upload daemon to find
    local  wsprnet_upload_dir=${UPLOADS_WSPRNET_SPOTS_DIR}/${posting_call_sign//\//=}_${posting_grid}/${posting_receiver_name}/${posting_receiver_band}  ## many ${posting_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
    mkdir -p ${wsprnet_upload_dir}

    ### Create a /tmp/.. dir where this instance of the daemon will process and merge spotfiles.  Then it will copy them to the uploads.d directory in a persistent file system
    local posting_receiver_dir_path=$PWD
    local no_nl_real_receiver_list=( "${real_receiver_list[*]//$'\n'/ /}")
    wd_logger 1 "Starting to post '${posting_receiver_name},${posting_receiver_band}' in '${posting_receiver_dir_path}' and copy spots from real_rx(s) '${no_nl_real_receiver_list[@]}' to '${wsprnet_upload_dir}"

    ### Link the real receivers to this dir
    local supplier_dirs_list=()
    local real_receiver_name
    mkdir -p ${POSTING_SUPPLIERS_SUBDIR}
    for real_receiver_name in ${real_receiver_list[@]}; do
        ### Create posting subdirs for each real recording/decoding receiver to copy spot files
        ### If a schedule change disables this receiver, we will want to signal to the real receivers that we are no longer listening to their spots
        ### To find those receivers, create a posting dir under each real receiver and make a symbolic link from our posting subdir to that real posting dir
        ### Since both dirs are under /tmp, create a hard link between that new dir and a dir under the real receiver where it will copy its spots
        local real_receiver_dir_path=$(get_recording_dir_path ${real_receiver_name} ${posting_receiver_band})
        local real_receiver_posting_dir_path=${real_receiver_dir_path}/${DECODING_CLIENTS_SUBDIR}/${posting_receiver_name}
        ### Since this posting daemon may be running before it's supplier decoding_daemon(s), create the dir path for that supplier
        mkdir -p ${real_receiver_posting_dir_path}

        ### Now create a symlink from under here to the directory where spots will appear
        local this_rx_local_link_name=${POSTING_SUPPLIERS_SUBDIR}/${real_receiver_name}
        if [[ -L ${this_rx_local_link_name} ]]; then
            wd_logger 1 "Link from ${real_receiver_posting_dir_path} to ${this_rx_local_link_name} already exists"
        else
            wd_logger 1 "Creating a symlink from ${real_receiver_posting_dir_path} to ${this_rx_local_link_name}"
            ln -s ${real_receiver_posting_dir_path} ${this_rx_local_link_name}
        fi
        supplier_dirs_list+=(${this_rx_local_link_name})
    done

    wd_logger 1 "Searching in subdirs: '${supplier_dirs_list[*]}' for '*_spots.txt' files"
    while true; do
        wd_logger 1 "Searching for at least one spot file"
        local spot_file_list=()
        while    run_recording_daemons ${posting_receiver_band} ${posting_receiver_modes} ${real_receiver_list[@]} \
              && spot_file_list=( $( find -L ${supplier_dirs_list[@]} -type f -name '*_spots.txt' -printf "%f\n") ) \
              && [[ ${#spot_file_list[@]} -eq 0 ]]; do
            wd_logger 2 "Waiting for at least one spot file to appear"
            wd_sleep ${POSTING_DAEMON_POLLING_RATE}
        done
        ### There are one or more spot files
        local filename_list=( ${spot_file_list[@]##*/} )
        local filetimes_list=(${filename_list[@]%_spots.txt})
        local unique_times_list=( $( IFS=$'\n'; echo "${filetimes_list[*]}" | sort -u ) )

        ### The last element in the array will be the time of spots from the the most recent cycle
        local newest_wspr_cycle_time=${unique_times_list[-1]}

        local spot_file_name=""
        local spot_file_time=""
        local spot_file_time_list=()
        if [[ ${#unique_times_list[@]} -gt 1 ]]; then
            wd_logger 1 "Found spots from ${#unique_times_list[@]} WSPR cycles.  Posting spots from the older cycles even if some spot files are missing from those cycles"

            unset 'unique_times_list[-1]'
            wd_logger 1 "Posting spots from the ${#unique_times_list[@]} earlier WSPR cycle(s): ${unique_times_list[*]} "
            for spot_file_time in ${unique_times_list[@]} ; do
                spot_file_name=${spot_file_time}_spots.txt
                spot_file_time_list=( $(find -L ${POSTING_SUPPLIERS_SUBDIR} -type f -name ${spot_file_name}) )
                if [[ ${#spot_file_list} -eq 0 ]]; then
                    wd_logger 1 "ERROR: can't find expected older spot files"
                else
                    wd_logger 1 "Posting the ${#spot_file_time_list[@]} spot files from an old WSPR cycle ${spot_file_time}: '${spot_file_time_list[*]}'"
                    post_files ${posting_receiver_band} ${wsprnet_upload_dir} ${spot_file_time} ${spot_file_time_list[@]}
                fi
            done
        fi

        ### There are one or more spot files from the most recent cycle
        spot_file_time=${newest_wspr_cycle_time}
        spot_file_name=${spot_file_time}_spots.txt
        spot_file_time_list=( $(find -L ${POSTING_SUPPLIERS_SUBDIR} -type f -name ${spot_file_name}) )
        if [[ ${#spot_file_time_list[@]} -lt ${#supplier_dirs_list[@]} ]]; then
            if [[ ${#spot_file_time_list[@]} -eq 0 ]]; then
                wd_logger 1 "ERROR: expected to find at least one spot file from the newest WSPR cycle ${spot_file_time}"
            else
                wd_logger 1 "Found only ${#spot_file_time_list[@]} spot files for the newest WSPR cycle ${spot_file_time}: '${spot_file_time_list[*]}'"
            fi
            wd_logger 2 "Sleep for ${POSTING_DAEMON_POLLING_RATE} seconds and then check again"
            wd_sleep ${POSTING_DAEMON_POLLING_RATE}
        else
            wd_logger 1 "Posting ${#spot_file_time_list[@]} spot files  which are equal or greater than the number of receivers for the newest WSPR cycle ${spot_file_time}: '${spot_file_time_list[*]}'"
            post_files ${posting_receiver_band} ${wsprnet_upload_dir} ${spot_file_time} ${spot_file_time_list[@]}
        fi
   done
}

### The wsprnet server processes spot lines with this block of PHP code.
### Our ALL_WSPR.TXT spot lines contain 16 or 17 fields, so to communicate the 'mode' we need to shorten type 1 spots which include the tx grid to 11 fields
### and put 'sync' in field #3 and 'mode' in field #11
###
### 352      $date = $fields[$i++];
### 353      $utc = $fields[$i++];
### 354      if ($nfields < 16) {
### 355          // in wspr 2.3-2.4, the ALL_WSPR.TXT file puts sync later, and there are 16 or 17 total fields (depending on msg format)
### 356          $sync = $fields[$i++];
### 357      }
### 358      $snr = $fields[$i++];
### 359      $dt = $fields[$i++];
### 360      $freq = $fields[$i++];
### 361      $tcall = $fields[$i++];
### 362      // In wspr 2.0, if there is a prefix/suffix, no grid is there (just power).
### 363      // We'll assume that if it's length 4 or 6, it is a grid
### 364      if (strlen($fields[$i]) == 4 || strlen($fields[$i]) == 6)
### 365        $tgrid = $fields[$i++];
### 366      else $tgrid = '';
### 367      $tpower = $fields[$i++];
### 368      if ($date && isset($fields[$i])) $drift = $fields[$i++];
### 369      else $drift = '0';
### 370      // can't tell version from log file.
### 371      // $version = '';
### 372      // accept version from form post. CJG 20210808
### 373      $version = $_REQUEST['version'] ?? '';
### 374
### 375      // If the field count is 11, assume the 11th field is `mode`
### 376      // otherwise default WSPR-2
### 377      $mode = $nfields == 11 ? get_mode($fields[$i++]) : 1;
### 378
### 379      $success = add_spot($version, $call, $grid, $date, $utc, $snr, $dt, $freq, $tcall, $tgrid, $tpower, $drift, $mode);

declare WN_FROM_WD_SPOTS_FILE_AWK_PROGRAM=${WSPRDAEMON_ROOT_DIR}/wn_from_wd_spot_file.awk
### From an extended wsprdaemon format spots file, creates a wsprnet format spots file with 12 fields.  The last field specifies the pkt mode
function format_spots_file_for_wsprnet() 
{
    local source_extended_spotlines_file=$1
    local dest_wsprnet_spotlines_file=$2

    wd_logger 1 "Create WN format spot lines from ${source_extended_spotlines_file} in ${dest_wsprnet_spotlines_file}"
    awk -f ${WN_FROM_WD_SPOTS_FILE_AWK_PROGRAM} ${source_extended_spotlines_file} > ${dest_wsprnet_spotlines_file}
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'awk -f ${WN_FROM_WD_SPOTS_FILE_AWK_PROGRAM} ${source_extended_spotlines_file} > ${dest_wsprnet_spotlines_file}' => ${rc}"
        return 1
    fi
    local error_lines
    if error_lines=$( grep ERROR ${dest_wsprnet_spotlines_file} ) ; then
       wd_logger 1 "ERROR: bad spot lines reported by awk:\n${error_lines}"
    fi
    wd_logger 1 "Created WN format spot file ${dest_wsprnet_spotlines_file}"
    return 0
}

function post_files()
{
    local receiver_band=$1
    local wsprnet_uploads_queue_directory=$2   ### This is derived from the call and grid and will differ from the real receiver when we are posting for a MERGEd (i.e.logical) receiver
    local spot_time=$3
    local spot_file_list=(${@:4})              ### The rest of the args are the *_spot.txt files in this WSPR cycle

    wd_logger 1 "Post spots from ${#spot_file_list[@]} files: '${spot_file_list[*]}'"

    cat ${spot_file_list[@]} > spots.ALL
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'cat ${spot_file_list[*]} > spots.ALL' => ${ret_code}, so sleep 5 and exit"
        sleep 5
        exit
    fi
    if [[ ! -s spots.ALL ]]; then
        wd_logger 1 "The spot file(s) are empty, so just flush them"
        wd_rm ${spot_file_list[@]}
        return 0
    fi
    ### There are spots to uploaded
    if [[ "${POST_ALL_SPOTS-no}" == "yes" ]]; then
        ### Post all spots, not just those with the best SNR
        cp -p spots.ALL spots.BEST
    else
        ### For each CALL, get the spot with the best SNR, add that spot to spots.BEST which will contain only one spot for each file.
        ### If configured for "proxy" uploads, at the same time mark the spot line in the source file for proxy upload
        > spots.BEST       ### Create and/or truncate spots.BEST
        local calls_list=( $( awk '{print $7}' spots.ALL | sort -u ) )
        wd_logger 1 "Found $(wc -l < spots.ALL) total spots in the ${#spot_file_list[@]} files. Together they report spots from ${#calls_list[@]} calls"
        local call
        for call in ${calls_list[@]}; do
            local best_line=$( awk -v call=${call} '$7 == call {printf "%s: %s\n", FILENAME, $0}' ${spot_file_list[@]} | sort -k 5,5n | tail -n 1)   ### get the "FILENAME SPOT_LINE" with the best SNR
            local best_file=${best_line%% *}                      ### awk has inserted the filename with the best spot in the first field of ${best_line}
            local best_spot=${best_line#* }                       ### The following fields are the spot line from that file with the spaces preserved
            local best_spot_marked=${best_spot::-1}1              ### Replaces the last (0 or 1) character of that spot which marks whether it could be uploaded by the upload_server with a 1

            wd_logger 2 "$( printf "For call %-12s found the best spot '${best_spot}' in '${best_file}'" "${call}" )"

            echo "${best_spot_marked}" >> spots.BEST      ### Add the best spot for this call to the file which will be uploaded to wsprnet.org
            if [[ ${SIGNAL_LEVEL_UPLOAD} == "proxy" ]]; then
                ### Mark the line in the source file for proxy upload
                wd_logger 1 "Proxy upload the best spot, but this code has not been debugged"
                grep -v -F "${best_spot}" ${best_file} > best.TMP       ### Remove any exisitng lines for this call
                echo "${best_spot_marked}" >> best.TMP                  ### Add this newly found best spot for this call
                sort -k 6,6n best.TMP > ${best_file}                    ### And sort the best 
            fi
        done
    fi

    ### Sort the spot lines in spots.BEST by ascending frequency
    sort -k 6,6n spots.BEST > best.TMP
    mv best.TMP spots.BEST

    if [[ ${posting_receiver_name} =~ MERG.* ]] ; then
        wd_logger 1 "Among the spots reported by a set of MERGEd receivers, saved the $(wc -l < spots.BEST) spots in file spots.BEST"
        wd_logger 2 "\n$(< spots.BEST)"
        if [[ ${LOG_MERGED_SNRS-yes} == "yes"  ]]; then
            ### Append to 'merged.log'
            wd_logger 1 "Log the MERGEd spot decisions with: 'log_merged_snrs  spots.BEST ${spot_file_list[*]}'"
            log_merged_snrs  spots.BEST ${spot_file_list[@]}
        fi
    fi

    if [[ ${SIGNAL_LEVEL_UPLOAD} != "proxy" ]]; then
        ### We are configured to upload the best set of spots directly to wsprnet.org
        ### The upload_to_wsprdaemon_client_dameon() could do this, but it would have to regenerate the 'spots.BEST' file.  Since we have that information now, queue spots.BEST for upload to wsprnet.org
        mkdir -p ${wsprnet_uploads_queue_directory}
        local wsprnet_uploads_queue_filename=${wsprnet_uploads_queue_directory}/${spot_time}_spots.txt
        local spots_count=$(wc -l < spots.BEST)
        wd_logger 1 "Queuing 'spots.BEST' which contains the ${spots_count} spots from the ${#calls_list[@]} calls found in the source files by moving it to ${wsprnet_uploads_queue_filename}"
        wd_logger 2 "\n$(< spots.BEST)"
        ### Format spot lines for the wsprnet.org server which now (1/22) parses spot lines for a packet mode 
        format_spots_file_for_wsprnet  spots.BEST wn_format_spots.txt
        local rc=$?
        if [[ ${rc} -eq 0 ]]; then
            if [[ ! -s wn_format_spots.txt ]]; then
                wd_logger 1 "ERROR: 'format_spots_file_for_wsprnet  spots.BEST wn_format_spots.txt' succeeeded but there are no spots in wn_format_spots.txt"
            else
                wd_logger 1 "Queuing file with $(wc -l < wn_format_spots.txt) spots to be delivered to  wsprnet.org ${wsprnet_uploads_queue_filename}"
                wd_logger 2 "\n$(< wn_format_spots.txt)"
                cp -p wn_format_spots.txt ${wsprnet_uploads_queue_filename}
            fi
        else
            wd_logger 1 "ERROR: 'format_spots_file_for_wsprnet  spots.BEST wn_format_spots.txt' => ${rc}"
        fi
    fi

    if [[ ${SIGNAL_LEVEL_UPLOAD} == "no" ]]; then
        wd_logger 1 "We are not configured to uplaod spots and noise to wsprdaemon.org, so flush the extended spots file(s): '${spot_file_list[*]}'"
        wd_rm ${spot_file_list[@]}
        return 0
    fi

    ### We are configured to upload extended spots and noise files to wsprdaemon.org and/or configured for proxy uploads
    ### If confgiured to upload to wsprdaemon, the noise files are queued by the decoding_daemon(), so we need to upload only spot files here
    wd_logger 1 "Queuing extended spot files for delivery to wsprdaemon.org: '${spot_file_list[*]}"
    local spot_file_list=( ${spot_file_list[@]} )
    local spot_file
    for spot_file in ${spot_file_list[@]} ; do
        local receiver_name=${spot_file#*/}
        receiver_name=${receiver_name%/*}

        local receiver_call_grid=$(get_call_grid_from_receiver_name ${receiver_name})    ### So that receiver_call_grid can be used as a directory name, any '/' in the receiver call has been replaced with '=' 
        local upload_wsprdaemon_spots_dir=${UPLOADS_WSPRDAEMON_SPOTS_ROOT_DIR}/${receiver_call_grid}/${receiver_name}/${receiver_band}  
        mkdir -p ${upload_wsprdaemon_spots_dir}
        cp -p ${spot_file} ${upload_wsprdaemon_spots_dir}
        wd_logger 1 "Queued ${spot_file} by copying it to ${upload_wsprdaemon_spots_dir}"
        wd_logger 2 "\n$(< ${upload_wsprdaemon_spots_dir}/${spot_file##*/})"
    done
    wd_logger 1 "Done queuing wsprdaemon.org spot files, so flush the extended spot files created by the recording daemon"
    wd_rm ${spot_file_list[@]}
    return 0
}

################### wsprdaemon uploads ####################################
### add tx and rx lat, lon, azimuths, distance and path vertex using python script. 
### In the main program, call this function with a file path/name for the input file, the tx_locator, the rx_locator and the frequency
### The appended data gets stored into ${DERIVED_ADDED_FILE} which can be examined. Overwritten each acquisition cycle.
declare DERIVED_ADDED_FILE="derived_azi.csv"
declare AZI_PYTHON_CMD="${WSPRDAEMON_ROOT_DIR}/derived_calc.py"

function add_derived() {
    local spot_grid=$1
    local my_grid=$2
    local spot_freq=$3    

    if [[ ! -f ${AZI_PYTHON_CMD} ]]; then
        wd_logger 0 "Can't find '${AZI_PYTHON_CMD}'"
        exit 1
    fi
    local rc
    tmeout ${DERIVED_NAX_RUN_SECS-20} python3 ${AZI_PYTHON_CMD} ${spot_grid} ${my_grid} ${spot_freq} 1>add_derived.txt 2> add_derived.log
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: timeout or error in running "${AZI_PYTHON_CMD} ${spot_grid} ${my_grid} ${spot_freq}" => ${rc}"
        return 1
    fi
    return 0
}

function log_merged_snrs() 
{
    local best_snrs_file=$1
    local all_spot_files_list=( ${@:2} )
    wd_logger 1 "Generate report about where spots in '${best_snrs_file}' were found in '${all_spot_files_list[*]}'"

    local source_file_count=${#all_spot_files_list[@]}
    local source_spots_count=$(cat ${all_spot_files_list[@]} | wc -l)
    if [[ ${source_spots_count} -eq 0 ]] ;then
        ## There are no spots recorded in this wspr cycle, so don't log
        wd_logger 1 "Found no spot lines in the ${source_file_count} spot files: ${all_spot_files_list[*]}"
        return 0
    fi
 
    local posted_spots_count=$(cat ${best_snrs_file} | wc -l)
    local posted_calls_list=( $(awk '{print $7}' ${best_snrs_file}) )   ### This list will have already been unique and sorted by frequency
    local posted_spots_count=${#posted_calls_list[@]}                   ### WD posts to wsprnet.org only the spot with the best SNR from each call, so the # of spots == #calls

    local real_receiver_list=( ${all_spot_files_list[@]#*/} )
          real_receiver_list=( ${real_receiver_list[@]%/*}     )
 
    wd_logger 1 "Log the source of the ${posted_spots_count} posted spots taken from the total ${source_spots_count} spots reported by the ${#real_receiver_list[@]} receivers '${real_receiver_list[*]}' in the MERGEd pool"
    
    TZ=UTC printf "${WD_TIME_FMT}: %10s %8s %10s" -1 "FREQUENCY" "CALL" "POSTED_SNR" >> merged.log
    local receiver
    for receiver in ${real_receiver_list[@]}; do
        printf "%12s" ${receiver}                            >> merged.log
    done
    printf "       TOTAL=%2s, POSTED=%2s\n" ${source_spots_count} ${posted_spots_count} >> merged.log

    local call
    for call in ${posted_calls_list[@]}; do
        local posted_freq=$(${GREP_CMD} " $call " ${best_snrs_file} | awk '{print $6}')
        local posted_snr=$( ${GREP_CMD} " $call " ${best_snrs_file} | awk '{print $4}')
        TZ=UTC printf "${WD_TIME_FMT}: %10s %8s %10s" -1 $posted_freq $call $posted_snr            >>  merged.log
        local file
        for file in ${all_spot_files_list[@]}; do
            ### Only pick the strongest SNR from each file which went into the .BEST file
            local rx_snr=$(${GREP_CMD} -F " $call " $file | sort -k 4,4n | tail -n 1 | awk '{print $4}')
            if [[ -z "$rx_snr" ]]; then
                printf "%12s" "*"                           >>  merged.log
            elif [[ $rx_snr == $posted_snr ]]; then
                printf "%11s%1s" $rx_snr "p"                >>  merged.log
            else
                printf "%11s%1s" $rx_snr " "                >>  merged.log
            fi
        done
        printf "\n"                                        >>  merged.log
    done
    truncate_file merged.log ${MAX_MERGE_LOG_FILE_SIZE-1000000}  ### Keep each of these logs to less than 1 MByte
    return 0
}
 
declare -r POSTING_DAEMON_PID_FILE="posting_daemon.pid"
declare -r POSTING_DAEMON_LOG_FILE="posting_daemon.log"

###
function spawn_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    local receiver_modes=$3

    wd_logger 1 "Starting with args ${receiver_name} ${receiver_band} ${receiver_modes}"
    local daemon_status
    if daemon_status=$(get_posting_status $receiver_name $receiver_band) ; then
        wd_logger 1 "Daemon for '${receiver_name}','${receiver_band}' is already running"
        return 0
    fi
    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
    local real_receiver_list=""

    if [[ "${receiver_name}" =~ ^MERG ]]; then
        ### This is a 'merged == virtual' receiver.  The 'real rx' which are merged to create this rx are listed in the IP address field of the config line
        real_receiver_list="${receiver_address//,/ }"
        wd_logger 1 "Creating merged rx '${receiver_name}' which includes real rx(s) '${receiver_address}' => list '${real_receiver_list[@]}'"  
    else
        wd_logger 1 "Creating real rx '${receiver_name}','${receiver_band}'"  
        real_receiver_list=${receiver_name} 
    fi
    local receiver_posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    mkdir -p ${receiver_posting_dir}
    cd ${receiver_posting_dir}
    wd_logger 1 "Spawning posting job ${receiver_name},${receiver_band},${receiver_modes} '${real_receiver_list}' in $PWD"
    WD_LOGFILE=${POSTING_DAEMON_LOG_FILE} posting_daemon ${receiver_name} ${receiver_band} ${receiver_modes} "${real_receiver_list}" &
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'posting_daemon ${receiver_name} ${receiver_band} ${receiver_modes} ${real_receiver_list}' => ${ret_code}"
        return 1
    fi
    local posting_pid=$!
    echo ${posting_pid} > ${POSTING_DAEMON_PID_FILE}

    cd - > /dev/null
    wd_logger 1 "Finished"
    return 0
}

###
function kill_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2

    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
    if [[ -z "${receiver_address}" ]]; then
        wd_logger 1 " No address(es) found for ${receiver_name}"
        return 1
    fi
    local posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    if [[ ! -d "${posting_dir}" ]]; then
        wd_logger 1 "Can't find expected posting daemon dir ${posting_dir}"
        return 2
    else
        local posting_daemon_pid_file=${posting_dir}/${POSTING_DAEMON_PID_FILE}
        if [[ ! -f ${posting_daemon_pid_file} ]]; then
            wd_logger 1 "Can't find expected posting daemon file ${posting_daemon_pid_file}"
            return 3
        else
            local posting_pid=$(cat ${posting_daemon_pid_file})
            if ps ${posting_pid} > /dev/null ; then
                wd_kill ${posting_pid}
                local rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'wd_kill ${posting_pid}' => ${rs}"
                else
                    wd_logger 1 "Killed active posting_daemon() pid ${posting_pid} and deleting '${posting_daemon_pid_file}'"
                fi
            else
                wd_logger 1 "Pid ${posting_pid} was dead. Deleting '${posting_daemon_pid_file}' it came from"
            fi
            rm -f ${posting_daemon_pid_file}
        fi
    fi

    local real_receiver_list=()
    if [[ "${receiver_name}" =~ ^MERG ]]; then
        ### This is a 'merged == virtual' receiver.  The 'real rx' which are merged to create this rx are listed in the IP address field of the config line
        wd_logger 1 "Stopping merged rx '${receiver_name}' which includes real rx(s) '${receiver_address}'"  
        real_receiver_list=(${receiver_address//,/ })
    else
        wd_logger 1 "Stopping real rx '${receiver_name}','${receiver_band}'"  
        real_receiver_list=(${receiver_name})
    fi

    if [[ -z "${real_receiver_list[@]}" ]]; then
        wd_logger 1 "Can't find expected real receiver(s) for '${receiver_name}','${receiver_band}'"
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
        wd_logger 1 "Signaling real receiver ${real_receiver_name} to stop posting to ${real_receiver_posting_dir}"
        if [[ ! -d ${real_receiver_posting_dir} ]]; then
            wd_logger 1 "ERROR: kill_posting_daemon(${receiver_name},${receiver_band}) WARNING: expect posting directory  ${real_receiver_posting_dir} does not exist"
        else 
            wd_logger 1  "Removing '${posting_suppliers_root_dir}/${real_receiver_name}' and '${real_receiver_posting_dir}'"
            rm -f ${posting_suppliers_root_dir}/${real_receiver_name}    ### Remote the posting daemon's link to the source of spots
            rm -rf ${real_receiver_posting_dir}                          ### Remove the directory under the recording daemon where it puts spot files for this decoding daemon to process
            local real_receiver_posting_root_dir=${real_receiver_posting_dir%/*}
            local real_receiver_posting_root_dir_count=$(ls -d ${real_receiver_posting_root_dir}/*/ 2> /dev/null | wc -w)
            if [[ ${real_receiver_posting_root_dir_count} -gt 0 ]]; then
                wd_logger 1 "Found that decoding_daemon for ${real_receiver_name},${receiver_band} has other posting clients, so didn't signal the recoding and decoding daemons to stop"
            else
                if kill_decoding_daemon ${real_receiver_name} ${receiver_band}; then
                    wd_logger 1 "Decoding daemon has no more posting clients, so 'kill_decoding_daemon ${real_receiver_name} ${receiver_band}' => $?"
                else
                    wd_logger 1 "ERROR: 'kill_decoding_daemon ${real_receiver_name} ${receiver_band} => $?"
                fi
            fi
       fi
    done
    ### decoding_daemon() will terminate themselves if this posting_daemon is the last to be a client for wspr_spots.txt files
    return 0
}

##
function get_posting_status() {
    local rx_name=$1
    local rx_band=$2

    local posting_dir=$(get_posting_dir_path ${rx_name} ${rx_band})
    local pid_file=${posting_dir}/${POSTING_DAEMON_PID_FILE}

    if [[ ! -f ${pid_file} ]]; then
       [[ $verbosity -ge 0 ]] && echo "No pid file"
       return 2
    fi

    local posting_pid=$(< ${pid_file})
    if ! ps ${posting_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "ERROR: Got pid '${posting_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${posting_pid}"
    return 0
}

