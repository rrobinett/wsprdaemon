#!/bin/bash

declare WSPRD_COMPARE="no"      ### If "yes" and a new version of wsprd was installed, then copy the old version and run it on each wav file and compare the spot counts to see how much improvement we got
declare WSPRDAEMON_TMP_WSPRD_DIR=${WSPRDAEMON_TMP_WSPRD_DIR-${WSPRDAEMON_TMP_DIR}/wsprd.old}
declare WSPRD_PREVIOUS_CMD="${WSPRDAEMON_TMP_WSPRD_DIR}/wsprd"   ### If WSPRD_COMPARE="yes" and a new version of wsprd was installed, then the old wsprd was moved here

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
    done
}

###
declare KIWIRECORDER_KILL_WAIT_SECS=10       ### Seconds to wait after kiwirecorder is dead so as to ensure the Kiwi detects there is on longer a client and frees that rx2...7 channel

### NOTE: This function assumes it is executing in the KIWI/BAND directory of the job to be killed
function kiwirecorder_manager_daemon_kill_handler() {
    if [[ ! -f ${KIWI_RECORDER_PID_FILE} ]]; then
        echo "$(date): kiwirecorder_manager_daemon_kill_handler() ran but found no ${KIWI_RECORDER_PID_FILE}" > kiwirecorder_manager_daemon_kill_handler.log
    else
        local kiwi_recorder_pid=$( < ${KIWI_RECORDER_PID_FILE} )
        rm ${KIWI_RECORDER_PID_FILE}
        if [[ -z "${kiwi_recorder_pid}" ]]; then
            echo "$(date): kiwirecorder_manager_daemon_kill_handler() ran but found no pid in ${KIWI_RECORDER_PID_FILE}" > kiwirecorder_manager_daemon_kill_handler.log
        else
            kill ${kiwi_recorder_pid}
            local timeout
            for (( timeout=0; timeout < ${KIWIRECORDER_KILL_WAIT_SECS}; ++timeout )); do
                if ! ps ${kiwi_recorder_pid} > /dev/null; then
                    break
                fi
                sleep 1
            done
            if ps ${kiwi_recorder_pid} > /dev/null; then
                wd_logger 1 "ERROR: kiwi_recorder_pid=${kiwi_recorder_pid} failed to die after waiting for ${timeout} seconds.  Trying 'kill -9 ${kiwi_recorder_pid}"
                kill -9 ${kiwi_recorder_pid}
                echo "$(date): kiwirecorder_manager_daemon_kill_handler() running as pid=$$ timed out after ${timeout} seconds after waiting for kiwi_recorder_pid=${kiwi_recorder_pid}, so ran 'kill -9'" > kiwirecorder_manager_daemon_kill_handler.log
            else
                wd_logger 1 "Killed kiwi_recorder_pid=${kiwi_recorder_pid}"
                echo "$(date): kiwirecorder_manager_daemon_kill_handler() running as pid=$$ found kiwi_recorder_pid=${kiwi_recorder_pid} died as expected after ${timeout} seconds" > kiwirecorder_manager_daemon_kill_handler.log
            fi
        fi
    fi
    rm ${WAV_RECORDING_DAEMON_PID_FILE}
    exit
}

### This daemon spawns a kiwirecorder.py session and monitor's its stdout for 'OV' lines
declare KIWI_RECORDER_PID_FILE="kiwi_recorder.pid"
declare KIWI_RECORDER_LOG_FILE="kiwi_recorder.log"
declare OVERLOADS_LOG_FILE="kiwi_recorder_overloads_count.log"   ### kiwirecorder_manager_daemon logs the 
function kiwirecorder_manager_daemon()
{
    local receiver_ip=$1
    local receiver_rx_freq_khz=$2
    local my_receiver_password=$3
    local recording_client_name=${KIWIRECORDER_CLIENT_NAME:-wsprdaemon_v${VERSION}}

    setup_verbosity_traps          ## So we can increment aand decrement verbosity without restarting WD
    trap kiwirecorder_manager_daemon_kill_handler SIGTERM

    wd_logger 1 "Starting in $PWD.  Recording from ${receiver_ip} on ${receiver_rx_freq_khz}"

    while true ; do
        local kiwi_recorder_pid=""
        if [[ -f ${KIWI_RECORDER_PID_FILE} ]]; then
            kiwi_recorder_pid=$( < ${KIWI_RECORDER_PID_FILE})
            local ps_output=$( ps ${kiwi_recorder_pid} )
            local ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                wd_logger 1 "Found there is an active kiwirercorder with pid ${kiwi_recorder_pid}"
            else
                wd_logger 1 " 'ps ${kiwi_recorder_pid}' reports error:\n${ps_output}"
                kiwi_recorder_pid=""
                rm ${KIWI_RECORDER_PID_FILE}
            fi
        fi

        if [[ -z "${kiwi_recorder_pid}" ]]; then
            ### kiwirecorder.py is not yet running, or it has crashed and we need to restart it
            wd_logger 1 "Spawning new ${KIWI_RECORD_COMMAND}"

            ### python -u => flush diagnostic output at the end of each line so the log file gets it immediately
            python3 -u ${KIWI_RECORD_COMMAND} \
                --freq=${receiver_rx_freq_khz} --server-host=${receiver_ip/:*} --server-port=${receiver_ip#*:} \
                --OV --user=${recording_client_name}  --password=${my_receiver_password} \
                --agc-gain=60 --quiet --no_compression --modulation=usb --lp-cutoff=${LP_CUTOFF-1340} --hp-cutoff=${HP_CUTOFF-1660} --dt-sec=60 > ${KIWI_RECORDER_LOG_FILE} 2>&1 &
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: Failed to spawn kiwirecorder.py job.  sleep and retry"
                sleep 1
                continue
            fi
            kiwi_recorder_pid=$!
            echo ${kiwi_recorder_pid} > ${KIWI_RECORDER_PID_FILE}
            wd_logger 1 "Spawned kiwrecorder.py job with PID ${kiwi_recorder_pid}"
        fi

        ### Monitor the operation of the kiwirecorder we spawned
        if ! ps ${kiwi_recorder_pid} > /dev/null; then
            wd_logger 1 "kiwirecorder with PID ${kiwi_recorder_pid} died unexpectedly. Wait for ${KIWIRECORDER_KILL_WAIT_SECS} seconds before restarting it."
            rm -f ${KIWI_RECORDER_PID_FILE}
            sleep ${KIWIRECORDER_KILL_WAIT_SECS}
            continue
        fi

        if [[ ! -f ${OVERLOADS_LOG_FILE} ]]; then
            ## Initialize the file which logs the date in epoch seconds, and the number of OV errors since that time
            printf "%(%s)T 0\n" -1  > ${OVERLOADS_LOG_FILE}
        fi

        local current_time=$(printf "%(%s)T" -1 )
        if [[ ${KIWI_RECORDER_LOG_FILE} -nt ${OVERLOADS_LOG_FILE} ]]; then
            ### there are new OV events.  
            local old_ov_info=( $(tail -1 ${OVERLOADS_LOG_FILE}) )
            local old_ov_count=${old_ov_info[1]}
            local new_ov_count=$( ${GREP_CMD} OV ${KIWI_RECORDER_LOG_FILE} | wc -l )
            local new_ov_time=${current_time}
            if [[ "${new_ov_count}" -le "${old_ov_count}" ]]; then
                wd_logger 1 "Found '${KIWI_RECORDER_LOG_FILE}' has changed, but new OV count '${new_ov_count}' is not greater than old count ''"
            else
                printf "\n${current_time} ${new_ov_count}" >> ${OVERLOADS_LOG_FILE}
                local ov_event_count=$(( "${new_ov_count}" - "${old_ov_count}" ))
                wd_logger 1 "Found ${new_ov_count} new - ${old_ov_count} old = ${ov_event_count} new OV events were reported by kiwirecorder.py"
            fi
        fi
        ### If there have been OV events, then every 10 minutes printout the count and mark the most recent line in ${OVERLOADS_LOG_FILE} as PRINTED
        local latest_ov_log_line=( $(tail -1 ${OVERLOADS_LOG_FILE}) )   
        local latest_ov_count=${latest_ov_log_line[1]}
        local last_ov_print_line=( $(awk '/PRINTED/{t=$1; c=$2} END {printf "%d %d", t, c}' ${OVERLOADS_LOG_FILE}) )   ### extracts the time and count from the last PRINTED line
        local last_ov_print_time=${last_ov_print_line[0]-0}   ### defaults to 0
        local last_ov_print_count=${last_ov_print_line[1]-0}  ### defaults to 0
        local secs_since_last_ov_print=$(( ${current_time} - ${last_ov_print_time} ))
        local ov_print_interval=${OV_PRINT_INTERVAL_SECS-600}        ## By default, print OV count every 10 minutes
        local ovs_since_last_print=$((${latest_ov_count} - ${last_ov_print_count}))
        if [[ ${secs_since_last_ov_print} -ge ${ov_print_interval} ]] && [[ "${ovs_since_last_print}" -gt 0 ]]; then
            wd_logger 1 "${ovs_since_last_print} overload events (OV) were reported in the last ${ov_print_interval} seconds"
            printf " PRINTED" >> ${OVERLOADS_LOG_FILE}
        fi
        truncate_file ${OVERLOADS_LOG_FILE} ${MAX_OV_FILE_SIZE-100000}

        local kiwi_recorder_log_size=$( ${GET_FILE_SIZE_CMD} ${KIWI_RECORDER_LOG_FILE} )
        if [[ ${kiwi_recorder_log_size} -gt ${MAX_KIWI_RECORDER_LOG_FILE_SIZE-200000} ]]; then
            ### Limit the kiwi_recorder.log file to less than 200 KB which is about 25000 2 minute reports
            wd_logger 1 "${KIWI_RECORDER_LOG_FILE} has grown too large (${kiwi_recorder_log_size} bytes), so killing kiwi_recorder"
            kill ${kiwi_recorder_pid}
            rm ${KIWI_RECORDER_PID_FILE}
        fi
        sleep 2
    done
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

declare WAV_RECORDING_DAEMON_PID_FILE="wav_recording_daemon.pid"
declare WAV_RECORDING_DAEMON_LOG_FILE="wav_recording_daemon.log"

### 
function spawn_wav_recording_daemon() {
    source ${WSPRDAEMON_CONFIG_FILE}   ### Get RECEIVER_LIST[*]
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_list_index=$(get_receiver_list_index_from_name ${receiver_name})
    if [[ -z "${receiver_list_index}" ]]; then
       wd_logger 1 "ERROR: Found the supplied receiver name '${receiver_name}' is invalid"
        exit 1
    fi
    local receiver_list_element=( ${RECEIVER_LIST[${receiver_list_index}]} )
    local receiver_ip=${receiver_list_element[1]}
    local receiver_rx_freq_khz=$(get_wspr_band_freq ${receiver_rx_band})
    local receiver_rx_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${receiver_rx_freq_khz}/1000.0" ) )
    local my_receiver_password=${receiver_list_element[4]}
    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})

    mkdir -p ${recording_dir}
    cd ${recording_dir}
    if [[ -f ${WAV_RECORDING_DAEMON_PID_FILE}  ]] ; then
        local recording_pid=$(< ${WAV_RECORDING_DAEMON_PID_FILE} )
        local ps_output
        if ps_output=$(ps ${recording_pid}); then
            wd_logger 2 "A recording job with pid ${recording_pid} is already running"
            return 0
        else
            wd_logger 1 "Found a stale recording job '${receiver_name},${receiver_rx_band}'"
            rm ${WAV_RECORDING_DAEMON_PID_FILE}
        fi
    fi
    ### No recoding daemon is running
    if [[ ${receiver_name} =~ ^AUDIO_ ]]; then
        [[ $verbosity -ge 1 ]] && echo "$(date): spawn_recording_daemon() record ${receiver_name}"
        WD_LOGFILE=${WAV_RECORDING_DAEMON_LOG_FILE}  audio_recording_daemon ${receiver_ip} ${receiver_rx_freq_khz} ${my_receiver_password} &
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'audio_recording_daemon ${receiver_ip} ${receiver_rx_freq_khz} ${my_receiver_password}' => ${ret_code}"
            return ${ret_code}
        fi
    elif [[ ${receiver_ip} =~ RTL-SDR ]]; then
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
        WD_LOGFILE=${WAV_RECORDING_DAEMON_LOG_FILE} rtl_daemon ${device_id} ${receiver_rx_freq_mhz} &
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'rtl_daemon ${device_id} ${receiver_rx_freq_mhz}' => ${ret_code}"
            return ${ret_code}
        fi
    else
        local kiwi_offset=$(get_receiver_khz_offset_list_from_name ${receiver_name})
        local kiwi_tune_freq=$( bc <<< " ${receiver_rx_freq_khz} - ${kiwi_offset}" )
	wd_logger 1 "Spawning wav recording daemon for Kiwi '${receiver_name}' with offset '${kiwi_offset}' to ${kiwi_tune_freq}" 
        WD_LOGFILE=${WAV_RECORDING_DAEMON_LOG_FILE}  kiwirecorder_manager_daemon ${receiver_ip} ${kiwi_tune_freq} ${my_receiver_password} &
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'kiwirecorder_manager_daemon ${receiver_ip} ${kiwi_tune_freq} ${my_receiver_password}' => ${ret_code}"
            return ${ret_code}
        fi
    fi
    echo $! > ${WAV_RECORDING_DAEMON_PID_FILE}
    wd_logger 1 "Spawned new wav recording job '${receiver_name},${receiver_rx_band}' with PID '$!'"
    return 0
}

###
### This will be called by the decoding_daemon_kill_handler() 
function kill_wav_recording_daemon() 
{
    local receiver_name=$1
    local receiver_rx_band=$2

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})

    if [[ ! -d ${recording_dir} ]]; then
        wd_logger 1 "ERROR: '${recording_dir}' does not exist"
        return 1
    fi
    local recording_pid_file=${recording_dir}/${WAV_RECORDING_DAEMON_PID_FILE}
    if [[ ! -f ${recording_pid_file} ]]; then
        wd_logger 1 "No pid file '${recording_pid_file}'"
        return 0
    fi
    local recording_pid=$(cat ${recording_pid_file})
    if [[ -z "${recording_pid}" ]]; then
        wd_loger 1 "Found no pid file '${recording_pid_file}'"
        return 0
    fi
    if ! ps ${recording_pid} > /dev/null; then
        wd_logger 1 "pid '${recording_pid}' is not active"
        return 0
    fi
    kill ${recording_pid}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: kill ${recording_pid} => $?"
        return 1
    fi
    wd_logger 1 "killed ${receiver_name} ${receiver_rx_band} job which had pid ${recording_pid}"
    return 0
}


##############################################################
function get_recording_status() {
    local rx_name=$1
    local rx_band=$2
    local recording_dir=$(get_recording_dir_path ${rx_name} ${rx_band})
    local pid_file=${recording_dir}/${WAV_RECORDING_DAEMON_PID_FILE}

    if [[ ! -d ${recording_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local rx_pid=$( < ${pid_file})
    if ! ps ${rx_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid ${rx_pid} from file, but it is not running"
        return 3
    fi
    echo "Pid = ${rx_pid}"
    return 0
}

#############################################################
declare MAX_WAV_FILE_AGE_MIN=${MAX_WAV_FILE_AGE_MIN-35}
function purge_stale_recordings() {
    local find_output=$(find ${WSPRDAEMON_TMP_DIR} -type f -name '*.wav' -mmin +${MAX_WAV_FILE_AGE_MIN} -print -exec rm {} \;)
    if [[ -n "${find_output}" ]]; then
        wd_logger 1 "Found stale wav files:\n${find_output}"
    else
        wd_logger 2 "Found no stale wav files"
    fi
    return 0
}

function old_purge_stale_recordings() {
    local show_recordings_receivers
    local show_recordings_band

    for show_recordings_receivers in $(list_receivers) ; do
        for show_recordings_band in $(list_bands) ; do
            local recording_dir=$(get_recording_dir_path ${show_recordings_receivers} ${show_recordings_band})
            shopt -s nullglob    ### *.wav expands to NULL if there are no .wav wav_file_names
            for wav_file in ${recording_dir}/*.wav ; do
                local wav_file_time=$($GET_FILE_MOD_TIME_CMD ${wav_file} )
                if [[ ! -z "${wav_file_time}" ]] &&  [[ $(( $(date +"%s") - ${wav_file_time} )) -gt ${MAX_WAV_FILE_AGE_SECS} ]]; then
                    wd_logger 1 "Purging stale recording file ${wav_file}"
                    rm -f ${wav_file}
                fi
            done
        done
    done
}


