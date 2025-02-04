#!/bin/bash

declare WSPRD_COMPARE="no"      ### If "yes" and a new version of wsprd was installed, then copy the old version and run it on each wav file and compare the spot counts to see how much improvement we got
declare WSPRDAEMON_TMP_WSPRD_DIR=${WSPRDAEMON_TMP_WSPRD_DIR-${WSPRDAEMON_TMP_DIR}/wsprd.old}
declare WSPRD_PREVIOUS_CMD="${WSPRDAEMON_TMP_WSPRD_DIR}/wsprd"   ### If WSPRD_COMPARE="yes" and a new version of wsprd was installed, then the old wsprd was moved here

function list_receivers() 
{
     local i
     for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        echo "${receiver_name}"
    done
}

##############################################################
function list_known_receivers() 
{
    echo "
        Index    Recievers Name          IP:PORT"
    for i in $(seq 0 $(( ${#RECEIVER_LIST[*]} - 1 )) ) ; do
        local receiver_info=(${RECEIVER_LIST[i]})
        local receiver_name=${receiver_info[0]}
        local receiver_ip_address=${receiver_info[1]}

        printf "          %s   %15s       %s\n"  $i ${receiver_name} ${receiver_ip_address}
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
        echo "The audio input to device ${audio_device} is being echoed to its line output.  Press ^C (Control+C) to terminate:"
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

declare -r RECEIVER_SNR_ADJUST=-0.25         ### We set the Kiwi passband to 400 Hz (1300-> 1700Hz), so adjust the wsprd SNRs by this dB to get SNR in the 300-2600 BW reuqired by wsprnet.org
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
    local receiver_recording_path

    if [[ ${receiver_name} =~ ^KA9Q ]]; then
        receiver_recording_path="${WSPRDAEMON_TMP_DIR}/recording.d/${receiver_name}"   ### pcmrecord creates all wav files in the 
    else
        receiver_recording_path="${WSPRDAEMON_TMP_DIR}/recording.d/${receiver_name}/${receiver_rx_band}"
    fi
    echo ${receiver_recording_path}
    return 0
}

function get_decoding_dir_path(){
    local receiver_name=$1
    local receiver_rx_band=$2
    local receiver_recording_path

    receiver_recording_path="${WSPRDAEMON_TMP_DIR}/recording.d/${receiver_name}/${receiver_rx_band}"
    echo ${receiver_recording_path}
    return 0
}

############################################################

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
        echo "$(date): ERROR: your system is configured to turn on the BIAS-T (5 VDC) output of the RTL_SDR, but the rtl_biast application has not been installed.
              To install 'rtl_biast', open https://www.rtl-sdr.com/rtl-sdr-blog-v-3-dongles-user-guide/ and search for 'To enable the bias tee in Linux'
              Your capture daemon process is running, but the LNA is not receiving the BIAS-T power it needs to amplify signals"
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
declare  USE_RX_FM="no"                                  ## Hopefully rx_fm will replace rtl_fm and give us better frequency control and Soapy support for access to a wide range of SDRs
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
        [[ $verbosity -ge 1 ]] && echo "$(date): starting a ${capture_secs} second RTL-SDR capture to '${wav_file_name}'" 
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
    setup_verbosity_traps          ## So we can increment and decrement verbosity without restarting WD
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

###  Call this function from the watchdog daemon 
###  If verbosity > 0 it will print out any new OV report lines in the recording.log files
###  Since those lines are printed only once every 10 minutes, this will print out OVs only once every 10 minutes`
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

function ka9q_recording_daemon()
{ 
    local receiver_ip=$1                 ### The multicast IP address from wsprdaemon.conf
    local receiver_band=$2
    local rc

    setup_verbosity_traps          ## So we can increment and decrement verbosity without restarting WD

    if [[ ${PCMRECORD_ENABLED-yes} != "yes" ]]; then
        local receiver_rx_freq_hz=$(get_wspr_band_freq_hz ${receiver_band} )
        wd_logger 1 "Start recording pcm wav files from ${receiver_ip} ${receiver_band} using ${KA9Q_RADIO_WD_RECORD_CMD}"
        local wd_record_args=""
        if [[ ${WD_RECORD_FLOAT-no} == "yes" ]]; then
            wd_record_args="${KA9Q_RADIO_WD_RECORD_CMD_FLOAT_ARGS}"
            wd_logger 1 "Record 32bit float wav files"
        fi
        local running_jobs_pid_list=()
        while    running_jobs_pid_list=( $( ps x | grep "${KA9Q_RADIO_WD_RECORD_CMD} .*-s ${receiver_rx_freq_hz} ${receiver_ip}" | grep -v grep | awk '{ print $1 }' ) ) \
            && [[ ${#running_jobs_pid_list[@]} -ne 0 ]] ; do
            wd_logger 1 "ERROR: found ${#running_jobs_pid_list[@]} running '${KA9Q_RADIO_WD_RECORD_CMD} .*-s ${receiver_rx_freq_hz} ${receiver_ip}' jobs: '${running_jobs_pid_list[*]}'.  Killing them"
            kill ${running_jobs_pid_list[@]}
            rc=$?
            if [[ ${rc} -eq 0 ]]; then
                wd_logger 1 "ERROR: 'kill ${running_jobs_pid_list[*]}' => ${rc}"
            fi
            sleep 10
        done

        local verbosity_args_list=( -v -v -v -v )
        local ka9q_verbosity_args="${verbosity_args_list[@]:0:$(( ${verbosity} + ${WD_RECORD_EXTRA_VERBOSITY-0} ))}"
        wd_logger 1 "Starting '${KA9Q_RADIO_WD_RECORD_CMD} -v -s ${receiver_rx_freq_hz} ${receiver_ip} >& wd-record-${receiver_band}.log"
        ${KA9Q_RADIO_WD_RECORD_CMD} -v ${wd_record_args} -s ${receiver_rx_freq_hz} ${receiver_ip} >& wd-record-${receiver_band}.log    ## wd-record prints to stderr, but we want it in wd-record.log
        rc=$?
        if [[ ${rc} -eq 0 ]]; then
            wd_logger 1 "ERROR: Unexpectedly '${KA9Q_RADIO_WD_RECORD_CMD} -v -s ${receiver_rx_freq_hz} ${receiver_ip} >  >& wd-record-${receiver_band}.log' ' terminated with no error"
        else
            wd_logger 1 "ERROR: Unexpectedly '${KA9Q_RADIO_WD_RECORD_CMD} -v -s ${receiver_rx_freq_hz} ${receiver_ip} >  >& wd-record-${receiver_band}.log' => ${rc}"
        fi
    else
        wd_logger 1 "Start recording wav files from ${receiver_ip} ${receiver_band} using ${KA9Q_RADIO_PCMRECORD_CMD}"
        local running_jobs_pid_list=()
        while    running_jobs_pid_list=( $( ps x | grep "${KA9Q_RADIO_PCMRECORD_CMD} -L 60 ${receiver_ip}" | grep -v grep | awk '{ print $1 }' ) ) \
            && [[ ${#running_jobs_pid_list[@]} -ne 0 ]] ; do
            wd_logger 1 "ERROR: found ${#running_jobs_pid_list[@]} running '${KA9Q_RADIO_PCMRECORD_CMD} -s ${receiver_rx_freq_hz} ${receiver_ip}' jobs: '${running_jobs_pid_list[*]}'.  Killing them"
            kill ${running_jobs_pid_list[@]}
            rc=$?
            if [[ ${rc} -eq 0 ]]; then
                wd_logger 1 "ERROR: 'kill ${running_jobs_pid_list[*]}' => ${rc}"
            fi
            sleep 10
        done

        local verbosity_args_list=( -v -v -v -v )
        local ka9q_verbosity_args="${verbosity_args_list[@]:0:$(( ${verbosity} + ${WD_RECORD_EXTRA_VERBOSITY-0} ))}"
        wd_logger 1 "Starting '${KA9Q_RADIO_PCMRECORD_CMD} ${PCMRECORD_CMD_EXTRA_ARGS-} -L 60 ${receiver_ip}' in ${PWD}"
        ${KA9Q_RADIO_PCMRECORD_CMD} ${PCMRECORD_CMD_EXTRA_ARGS-} -W -L 60 --jt ${receiver_ip} > wd-record.log 2>&1   ## wd-record prints to stderr, but we want it in wd-record.log
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: Unexpectedly '${KA9Q_RADIO_PCMRECORD_CMD} -L 60 ${receiver_ip}' => ${rc}"
        else
            wd_logger 1 "ERROR: Unexpectedly '${KA9Q_RADIO_PCMRECORD_CMD} -L 60 ${receiver_ip}' terminated with no error"
        fi
    fi
    return 1
}

declare KA9Q_RADIO_TUNE_CMD_LOG_FILE="./ka9q_status.log"

function get_ka9q_rx_channel_report(){
    local __return_ka9q_agc_val=$1
    local __return_wav_files_ka9q_noise_val=$2
    local receiver_name=$3
    local receiver_rx_freq_hz=$4
    local receiver_ip="hf.local"
    local rc

    receiver_ip=$(get_receiver_ip_from_name ${receiver_name})
    if [[ -z "${receiver_ip}" ]]; then
        qwd_logger 1 "ERROR: can't find the IP for receiver '${receiver_name}'"
        exit 1
    fi
    wd_logger 1 "Get status of receiver '${receiver_name}' channel which is demodulating ip ${receiver_ip} freq ${receiver_rx_freq_hz}"

    set +x
    receiver_ip="hf.local"
    ${KA9Q_RADIO_TUNE_CMD}  -s ${receiver_rx_freq_hz} ${receiver_ip} >& ${KA9Q_RADIO_TUNE_CMD_LOG_FILE}
    rc=$?
    set +x
    if [[ ${rc} -eq 0 ]]; then
        wd_logger 1 "Got status:\n$(< ${KA9Q_RADIO_TUNE_CMD_LOG_FILE})"
     else
        wd_logger 1 "ERROR:  rc=${rc}:\n$(< ${KA9Q_RADIO_TUNE_CMD_LOG_FILE})"
     fi
     local ka9q_agc_val=99
     local ka9q_noise_val=-999
     eval ${__return_ka9q_agc_val}=\${ka9q_agc_val}
     eval ${__return_wav_files_ka9q_noise_val}=\${ka9q_noise_val}
     return 0
}

### 
function spawn_wav_recording_daemon() {
    source ${WSPRDAEMON_CONFIG_FILE}   ### Get RECEIVER_LIST[*]
    local receiver_name=$1
    local receiver_rx_band=$2   ### Ignored now that we use pcmrecord

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})

    local receiver_list_index=$(get_receiver_list_index_from_name ${receiver_name})
    if [[ -z "${receiver_list_index}" ]]; then
        wd_logger 1 "ERROR: Found the supplied receiver name '${receiver_name}' is invalid"
        exit 1
    fi
    
    mkdir -p ${recording_dir}

    local wav_recording_mutex_name
    local wav_recording_pid_file
    if [[ ${PCMRECORD_ENABLED-yes} == "yes" ]]; then
        wav_recording_mutex_name="wav-recorder-all"
        wav_recording_pid_file="wav-recorder-all.pid"
     else
         wav_recording_mutex_name="wav-recorder-${receiver_rx_band}"
         wav_recording_pid_file="wav-recorder-${receiver_rx_band}.pid"
    fi

    wd_logger 2 "Locking mutex ${wav_recording_mutex_name} in ${recording_dir}"

    local rc
    wd_mutex_lock ${wav_recording_mutex_name} ${recording_dir}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: failed to lock mutex '${wav_recording_mutex_name}' in ${recording_dir}"
        return 1
    fi
    wd_logger 2 "Locked mutex '${wav_recording_mutex_name}' in ${recording_dir}"

    local pid_file=${recording_dir}/${wav_recording_pid_file}
    if [[ -f ${pid_file}  ]] ; then
        local recording_pid=$(< ${pid_file} )
        if ps -e -o pid | grep -q ${recording_pid}; then         ## 'ps  ${recording_pid}' would block for many seconds.  This never blocks
            wd_logger 2 "A recording job in ${recording_dir} with pid ${recording_pid} is already running"
            wd_mutex_unlock ${wav_recording_mutex_name} ${recording_dir}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: failed to unlock mutex '${wav_recording_mutex_name}' in ${recording_dir}"
                return 1
            fi
            wd_logger 2 "Unlocked mutex '${wav_recording_mutex_name}' in ${recording_dir} and returning without spawning new job"
            return 0
        else
            wd_rm ${pid_file}
            wd_logger 1 "Found a stale recording job '${receiver_name},${receiver_rx_band}', so we need to spawn one"
        fi
    fi

    ### No wav_recording daemon is running
    local receiver_list_element=( ${RECEIVER_LIST[${receiver_list_index}]} )
    local receiver_ip=${receiver_list_element[1]}
    local receiver_rx_freq_khz=$(get_wspr_band_freq_khz ${receiver_rx_band})
    local wav_record_daemon_log_filename="wav-record-daemon-${receiver_rx_band}.log"
    if [[ ${receiver_name} =~ ^KA9Q ]]; then
        if [[ ${PCMRECORD_ENABLED-yes} == "yes" ]]; then
            wav_record_daemon_log_filename="wav-record-daemon-all.log"
        fi
        wd_logger 1 "Spawning a KA9Q wd-record daemon for receiver '${receiver_name}' in directory ${recording_dir} where it will log to ${wav_record_daemon_log_filename}"
        cd  ${recording_dir}
        WD_LOGFILE=${wav_record_daemon_log_filename} ka9q_recording_daemon ${receiver_ip} ${receiver_rx_band}  &    ### Once instance of pcmrecord outputs all the bands in the stream to a series of wav files
        cd - > /dev/null
    else
        local my_receiver_password=${receiver_list_element[4]}

        wd_logger 2 "Spawning a kiwirecorder daemon for receiver '${receiver_name}' in directory ${recording_dir}"
        cd  ${recording_dir}
        WD_LOGFILE=${wav_record_daemon_log_filename}  kiwirecorder_manager_daemon ${receiver_name} ${receiver_ip} ${receiver_rx_freq_khz} ${my_receiver_password} &
        cd - > /dev/null
    fi
    local rc1=$?
    if [[ ${rc1} -eq 0 ]]; then
        echo $! >  ${recording_dir}/${wav_recording_pid_file}
        wd_logger 2 "Spawned wav_recorder for receiver '${receiver_name}' which has PID = $!"
    else
        wd_logger 1 "ERROR: Failed to spwan wav_recorder for '${receiver_name}' => ${rc1}"
    fi

    wd_mutex_unlock ${wav_recording_mutex_name} ${recording_dir}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: Spawned wav_recorder for receiver '${receiver_name}' which has PID = $! but failed to unload mutex"
    else
        wd_logger 1 "Spawned wav_recorder for receiver '${receiver_name}' which has PID = $! and unlocked mutex"
    fi

    return ${rc1}
}

##############################################################
function get_recording_status() {
    local rx_name=$1
    local rx_band=$2

    local recording_dir=$(get_recording_dir_path ${rx_name} ${rx_band})
    local pid_file="${recording_dir}/wav-recorder-${rx_band}.pid"
    if [[ ${PCMRECORD_ENABLED-yes} == "yes" ]]; then
        pid_file="${recording_dir}/wav-recorder-all.pid"
    fi

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
        [[ $verbosity -ge 0 ]] && echo "ERROR: Got pid ${rx_pid} from file, but it is not running"
        return 3
    fi
    echo "Pid = ${rx_pid}"
    return 0
}

### This will be called by decoding_daemon() 
function kill_wav_recording_daemon() 
{
    local receiver_name=$1
    local receiver_rx_band=$2

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_rx_band})
    local pid_file="${recording_dir}/wav-recorder-${rx_band}.pid"
    if [[ ${PCMRECORD_ENABLED-yes} == "yes" ]]; then
        pid_file="${recording_dir}/wav-recorder-all.pid"
    fi
 
    if [[ ! -d ${recording_dir} ]]; then
        wd_logger 1 "ERROR: '${recording_dir}' does not exist"
        return 1
    fi
    if [[ ! -f ${pid_file} ]]; then
        wd_logger 1 "There is no PID file ${pid_file}, so nothing to kill"
        return 0
    fi

    local rc
    wd_kill_pid_file ${pid_file}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'wd_kill_pid_file ${pid_file}' => ${rc}"
        return 1
    fi

: <<'COMMENT_OUT_LINES'
    ### Kill the daemon which it spawned which is recording the series of 1 minute long wav files
    for recorder_app in kiwi_recorder; do
        local recording_pid_file=${recording_dir}/${recorder_app}.pid
        wd_kill_pid_file ${recording_pid_file}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'wd_kill_pid_file ${recording_pid_file}' => ${rc}"
        fi
    done
COMMENT_OUT_LINES

    wd_logger 1 "Killed the wav recording daemon for ${receiver_name} ${receiver_rx_band}"
    return 0
}

#############################################################
declare MAX_WAV_FILE_AGE_MIN=${MAX_WAV_FILE_AGE_MIN-35}
function purge_stale_recordings() 
{
    local old_wav_file_list=( $(find ${WSPRDAEMON_TMP_DIR}/recording.d -name '*.wav' -mmin +${MAX_WAV_FILE_AGE_MIN}) )

    if [[ ${#old_wav_file_list[@]} -eq 0 ]]; then
        return 0
    fi
    wd_logger 1 "Found ${#old_wav_file_list[@]} old files"
    local old_file
    for old_file in ${old_wav_file_list[@]} ; do
        wd_rm ${old_file}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'wd_rm ${old_file}' => ${rc}"
        else
             wd_logger 1 "INFO: deleted ${old_file}"
        fi
    done
    wd_logger 1 "Done flushing ${#old_wav_file_list[@]} old files"
    return 0
}

