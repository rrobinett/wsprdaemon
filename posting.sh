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
    local posting_receiver_modes=${3}
    local real_receiver_list=($4)
    local real_receiver_count=${#real_receiver_list[@]}

    wd_logger 1 "Starting with args ${posting_receiver_name} ${posting_receiver_band} ${posting_receiver_modes} '${real_receiver_list[*]}'"

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    source ${WSPRDAEMON_CONFIG_FILE}
    local my_call_sign="$(get_receiver_call_from_name ${posting_receiver_name})"
    local my_grid="$(get_receiver_grid_from_name ${posting_receiver_name})"
    
    ### Where to put the spots from the one or more real receivers for the upload daemon to find
    local  wsprnet_upload_dir=${UPLOADS_WSPRNET_SPOTS_DIR}/${my_call_sign//\//=}_${my_grid}/${posting_receiver_name}/${posting_receiver_band}  ## many ${my_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
    mkdir -p ${wsprnet_upload_dir}

    ### Create a /tmp/.. dir where this instance of the daemon will process and merge spotfiles.  Then it will copy them to the uploads.d directory in a persistent file system
    local posting_receiver_dir_path=$PWD
    local no_nl_real_receiver_list=( "${real_receiver_list[*]//$'\n'/ /}")
    wd_logger 1 "Starting to post '${posting_receiver_name},${posting_receiver_band}' in '${posting_receiver_dir_path}' and copy spots from real_rx(s) '${no_nl_real_receiver_list[@]}' to '${wsprnet_upload_dir}"

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
        wd_logger 1 "Created a symlink from ${this_rx_local_dir_name} to ${real_receiver_posting_dir_path}"
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
                wd_logger 1 "Checking or starting decode daemon for real receiver ${real_receiver_name} ${posting_receiver_band}"
                ### '(...) runs in subshell so it can't change the $PWD of this function
                (spawn_decode_daemon ${real_receiver_name} ${posting_receiver_band} ${posting_receiver_modes}) ### Make sure there is a decode daemon running for this receiver.  A no-op if already running
            done

            wd_logger 1 "Checking for subdirs to have the same *_wspr_spots.txt in them" 
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
                wd_logger 1 " The expected posting dir ${posting_dir} does not exist, so exiting inner while loop"
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
                wd_logger 1 "Is waiting for files. Sleeping..."
                sleep ${WAV_FILE_POLL_SECONDS}
            else
                wd_logger 1 "Found the required ${newest_all_wspr_file_name} in all the posting subdirs, so can merge and post"
            fi
        done
        if [[ ${daemon_stop} != "no" ]]; then
            wd_logger 3 "Exiting outer while loop"
            break
        fi
        ### All of the ${real_receiver_list[@]} directories have *_wspr_spot.txt files with the same time&name

        ### Clean out any older *_wspr_spots.txt files
        wd_logger 1 "Flushing old *_wspr_spots.txt files"
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
            wd_logger 1 "No spots were decoded"
            wsprd_spots_best_file_path=${wsprd_spots_all_file_path}
        else
            ### At least one of the real receiver decoder reported a spot. Create a spot file with only the strongest SNR for each call sign
             wsprd_spots_best_file_path=${posting_receiver_dir_path}/wspr_spots.txt.BEST

            local wd_arg=$(printf "Merging and sorting files '${newest_list[@]}' into ${wsprd_spots_all_file_path}")
            wd_logger 1 "${wd_arg}"

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
                    wd_logger 1 "This spot file has no spots, but copy it to the upload directory so upload_daemon knows that this wspr cycle decode has been completed"
                else
                    wd_logger 1 "Queue real rx spots file '${real_receiver_wspr_spots_file}' for upload to wsprdaemon.org"
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
                if [[ ${verbosity} -ge 1 ]]; then
                    if [[ -s ${upload_wsprd_file_path} ]]; then
                        wd_logger 1 "Copied ${real_receiver_enhanced_wspr_spots_file} to ${upload_wsprd_file_path} which contains spot(s):\n$( cat ${upload_wsprd_file_path})"
                    else
                        wd_logger 1 "Created zero length spot file ${upload_wsprd_file_path}"
                    fi
                fi
            fi
 
            ### Upload noise file
            local noise_files_list=( ${real_receiver_dir}/*_wspr_noise.txt )
            local noise_files_list_count=${#noise_files_list[@]}
            if [[ ${noise_files_list_count} -lt 1 ]]; then
                wd_logger 1 "The expected noise.txt file is missing"
            else
                local  upload_wsprdaemon_noise_dir=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/${my_call_sign//\//=}_${my_grid}/${real_receiver_name}/${real_receiver_band}  ## many ${my_call_sign}s contain '/' which can't be part of a Linux filename, so convert them to '='
                mkdir -p ${upload_wsprdaemon_noise_dir}

                mv ${noise_files_list[@]} ${upload_wsprdaemon_noise_dir}   ### The TIME_FREQ is already part of the noise file name
                wd_logger 1 "Moved noise file(s) '${noise_files_list[@]}' to '${upload_wsprdaemon_noise_dir}'"
            fi
        done
        ### We have uploaded all the spot and noise files
 
        sleep ${WAV_FILE_POLL_SECONDS}
    done
    wd_logger 1 "Finished"
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
    local receiver_modes=$3

    wd_logger 1 "Starting with args ${receiver_name} ${receiver_band} ${receiver_modes}"
    local daemon_status
    if daemon_status=$(get_posting_status $receiver_name $receiver_band) ; then
        wd_logger 1 "Daemon for '${receiver_name}','${receiver_band}' is already running"
        return
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
    WD_LOGFILE=posting_daemon.log posting_daemon ${receiver_name} ${receiver_band} ${receiver_modes} "${real_receiver_list}" &
    local posting_pid=$!
    echo ${posting_pid} > posting.pid

    cd - > /dev/null
    wd_logger 1 "Finished"
}

###
function kill_posting_daemon() {
    local receiver_name=$1
    local receiver_band=$2

    local receiver_address=$(get_receiver_ip_from_name ${receiver_name})
    if [[ -z "${receiver_address}" ]]; then
        wd_logger 1 " No address(s) found for ${receiver_name}"
        return 1
    fi
    local posting_dir=$(get_posting_dir_path ${receiver_name} ${receiver_band})
    if [[ ! -d "${posting_dir}" ]]; then
        wd_logger 1 "Caan't find expected posting daemon dir ${posting_dir}"
        return 2
    else
        local posting_daemon_pid_file=${posting_dir}/posting.pid
        if [[ ! -f ${posting_daemon_pid_file} ]]; then
            wd_logger 1 "Can't find expected posting daemon file ${posting_daemon_pid_file}"
            return 3
        else
            local posting_pid=$(cat ${posting_daemon_pid_file})
            if ps ${posting_pid} > /dev/null ; then
                kill ${posting_pid}
                wd_logger 1 " Killed active pid ${posting_pid} and deleting '${posting_daemon_pid_file}'"
            else
                wd_logger 1 "Pid ${posting_pid} was dead.  Deleting '${posting_daemon_pid_file}' it came from"
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
            wd_logger 1 "kill_posting_daemon(${receiver_name},${receiver_band}) WARNING: expect posting directory  ${real_receiver_posting_dir} does not exist"
        else 
            rm -f ${posting_suppliers_root_dir}/${real_receiver_name}     ## Remote the posting daemon's link to the source of spots
            rm -rf ${real_receiver_posting_dir}  ### Remove the directory under the recording deamon where it puts spot files for this decoding daemon to process
            local real_receiver_posting_root_dir=${real_receiver_posting_dir%/*}
            local real_receiver_posting_root_dir_count=$(ls -d ${real_receiver_posting_root_dir}/*/ 2> /dev/null | wc -w)
            if [[ ${real_receiver_posting_root_dir_count} -eq 0 ]]; then
                local real_receiver_stop_file=${real_receiver_posting_root_dir%/*}/recording.stop
                touch ${real_receiver_stop_file}
                wd_logger 1 "kill_posting_daemon(${receiver_name},${receiver_band}) by creating ${real_receiver_stop_file}"
            else
                wd_logger 1 "kill_posting_daemon(${receiver_name},${receiver_band}) a decoding client remains, so didn't signal the recoding and decoding daemons to stop"
            fi
        fi
    done
    ### decoding_daemon() will terminate themselves if this posting_daemon is the last to be a client for wspr_spots.txt files
    return 0
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


