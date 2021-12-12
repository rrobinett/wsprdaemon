#!/bin/bash 

############## Decoding ################################################
### For each real receiver/band there is one decode daemon and one recording daemon
### Waits for a new wav file then decodes and posts it to all of the posting lcient


declare -r DECODING_CLIENTS_SUBDIR="decoding_clients.d"     ### Each decoding daemon will create its own subdir where it will copy YYMMDD_HHMM_wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                            ### Delete the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..
declare FFT_WINDOW_CMD=${WSPRDAEMON_ROOT_DIR}/wav_window.py

declare C2_FFT_ENABLED="yes"          ### If "yes", then use the c2 file produced by wsprd to calculate FFT noisae levels
declare C2_FFT_CMD=${WSPRDAEMON_ROOT_DIR}/c2_noise.py

function get_decode_mode_list() {
    local modes_varible_to_return=$1
    local receiver_modes_arg=$2
    local receiver_band=$3
    local temp_receiver_modes

    temp_receiver_modes=${receiver_modes_arg}
    if [[ ${receiver_modes_arg} == "DEFAULT" ]]; then
        ### Translate DEFAULT mode to a list of modes for this band
        local default_modes=""
        get_default_modes_for_band  default_modes ${receiver_band}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'get_default_modes_for_band default_modes ${receiver_band}' =>  ${ret_code}" 
            sleep 1
            return ${ret_code}
        fi
        wd_logger 1 "Translated decode mode '${receiver_modes_arg}' to '${default_modes}'"
        temp_receiver_modes=${default_modes}
    fi
    ### Validate the mode list
    is_valid_mode_list  ${temp_receiver_modes}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]] ; then
        wd_logger 1 "ERROR: 'is_valid_mode_list  ${temp_receiver_modes}' => ${ret_code}" 
        return 1
    fi
    wd_logger 2 "Returning modes ${temp_receiver_modes}"
    eval ${modes_varible_to_return}=${temp_receiver_modes}
    return 0
}

##########
function get_af_db() {
    local return_variable_name=$1
    local local real_receiver_name=$2                ### 'real' as opposed to 'merged' receiver
    local real_receiver_rx_band=$3
    local default_value

    local af_info_field="$(get_receiver_af_list_from_name ${real_receiver_name})"
    if [[ -z "${af_info_field}" ]]; then
        wd_logger 2 "Found no AF field for receiver ${real_receiver_name}, so return AF=0"
        eval ${return_variable_name}=0
        return 0
    fi
    local af_info_list=(${af_info_field//,/ })
    wd_logger 1 "af_info_list= ${af_info_list[*]}"
    for element in ${af_info_list[@]}; do
        local fields=(${element//:/ })
        if [[ ${fields[0]} == "DEFAULT" ]]; then
            default_value=${fields[1]}
            wd_logger 1 "Found default value ${default_value}"
        elif [[ ${fields[0]} == ${real_receiver_rx_band} ]]; then
            wd_logger 1 "Found AF value ${fields[1]} for receiver ${real_receiver_name}, band ${real_receiver_rx_band}"
            eval ${return_variable_name}=${fields[1]}
            return 0
        fi
    done
    wd_logger 1 "Returning default value ${default_value} for receiver ${real_receiver_name}, band ${real_receiver_rx_band}"
    eval ${return_variable_name}=${default_value}
    return 0
}

function calculate_nl_adjustments() {
    local return_rms_corrections_variable_name=$1
    local return_fft_corrections_variable_name=$2
    local receiver_band=$3

    local wspr_band_freq_khz=$(get_wspr_band_freq ${receiver_band})
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
    local antenna_factor_adjust
    get_af_db antenna_factor_adjust ${receiver_name} ${receiver_band}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find AF for ${receiver_name} ${receiver_band}"
        exit 1
    fi
    wd_logger 1 "Got AF = ${antenna_factor_adjust} for ${receiver_name} ${receiver_band}"

    local rx_khz_offset=$(get_receiver_khz_offset_list_from_name ${receiver_name})
    local total_correction_db=$(bc <<< "scale = 10; ${kiwi_amplitude_versus_frequency_correction} + ${antenna_factor_adjust}")
    local calculated_rms_nl_adjust=$(bc -l <<< "var=(${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}); scale=2; var/1.0" )                                       ## bc -l invokes the math extension, l(x)/l(10) == log10(x)
    wd_logger 1 "calculated_rms_nl_adjust=\$(bc -l <<< \"var=(${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}); scale=2; var/1.0\" )"
    eval ${return_rms_corrections_variable_name}=${calculated_rms_nl_adjust}

    ## G3ZIL implementation of algorithm using the c2 file by Christoph Mayer
    local calculated_fft_nl_adjust=$(bc <<< "scale = 2;var=${cal_c2_correction};var+=${total_correction_db}; (var * 100)/100")
    wd_logger 1 "calculated_fft_nl_adjust = ${calculated_fft_nl_adjust} from calculated_fft_nl_adjust=\$(bc <<< \"scale = 2;var=${cal_c2_correction};var+=${total_correction_db}; (var * 100)/100\")"
    eval ${return_fft_corrections_variable_name}="'${calculated_fft_nl_adjust}'"
}

declare WAV_SAMPLES_LIST=(
    "${SIGNAL_LEVEL_PRE_TX_SEC} ${SIGNAL_LEVEL_PRE_TX_LEN}"
    "${SIGNAL_LEVEL_TX_SEC} ${SIGNAL_LEVEL_TX_LEN}"
    "${SIGNAL_LEVEL_POST_TX_SEC} ${SIGNAL_LEVEL_POST_TX_LEN}"
)

function get_wav_levels() 
{
    local __return_levels_var=$1
    local wav_filename=$2
    local sample_start_sec=$3
    local sample_length_secs=$4
    local rms_adjust=$5

    local wav_levels_list=( $(sox ${wav_filename} -t wav - trim ${sample_start_sec} ${sample_length_secs} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
    if [[ ${#wav_levels_list[@]} -ne 4 ]]; then
        wd_logger 1 "ERROR: found only ${#wav_levels_list[@]} dB lines, not the four expected dB lines from 'sox ${wav_filename} -t wav - trim ${sample_start_sec} ${sample_length_secs}'"
        return 1
    fi
    wd_logger 2 "Got sox dB values: '${wav_levels_list[*]}'"

    local return_line=""
    for db_val in ${wav_levels_list[@]}; do
        local adjusted_val=$(bc <<< "scale = 2; (${db_val} + ${rms_adjust})/1")           ### '/1' forces bc to use the scale = 2 setting
        return_line="${return_line} ${adjusted_val}"
    done
    wd_logger 2 "Returning ajusted dB values: '${return_line}'"
    eval ${__return_levels_var}=\"${return_line}\"
    return 0
}

declare MIN_VALID_RAW_WAV_SECCONDS=${MIN_VALID_RAW_WAV_SECCONDS-59}
declare MAX_VALID_RAW_WAV_SECONDS=${MAX_VALID_RAW_WAV_SECONDS-60}
declare MIN_VALID_WSPR_WAV_SECCONDS=${MIN_VALID_WSPR_WAV_SECCONDS-119}
declare MAX_VALID_WSPR_WAV_SECONDS=${MAX_VALID_WSPR_WAV_SECONDS-120}

function is_valid_wav_file()
{
    local wav_filename=$1
    local min_valid_secs=$2
    local max_valid_secs=$3

    if [[ ! -f ${wav_filename} ]]; then
        wd_logger 1 "ERROR: no wav file ${wav_filename}"
        return 1
    fi
    if [[ ! -s ${wav_filename} ]]; then
        wd_logger 1 "ERROR: zero length wav file ${wav_filename}"
        return 1
    fi
    local wav_stats=$(sox ${wav_filename} -n stats 2>&1 )
    local ret_code=$?    
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'sox ${wav_filename} -n stats' => ${ret_code}"
        return 1
    fi
    wd_logger 2 "'sox ${wav_filename} -n stats 2>&1' =>\n${wav_stats}"
    local wav_length_line_list=( $(grep '^Length' <<< "${wav_stats}") )
    if [[ ${#wav_length_line_list[@]} -eq 0 ]]; then
         wd_logger 1 "ERROR: can't find wav file 'Length' line in output of 'sox ${wav_filename} -n stats'"
        return 1
    fi
    if [[ ${#wav_length_line_list[@]} -ne 3 ]]; then
        wd_logger 1 "ERROR: 'sox ${wav_filename} -n stats' ouput 'Length' line has ${#wav_length_line_list[@]} fields in it instead of the expected 3 fields"
        return 1
    fi
    local wav_length_secs=${wav_length_line_list[2]/.*}
    if [[ -z "${wav_length_secs}" ]]; then
        wd_logger 1 "ERROR: 'sox ${wav_filename} -n stats' reports invalid wav file length '${wav_length_line_list[2]}'"
        return 1
    fi
    if [[ ! ${wav_length_secs} =~ ^[0-9]+$ ]]; then
        wd_logger 1 "ERROR: 'sox ${wav_filename} -n stats' reports wav file length ${wav_length_line_list[2]} which doesn't contain an integer number"
        return 1
    fi
    if [[ ${wav_length_secs} -lt ${min_valid_secs} || ${wav_length_secs} -gt ${max_valid_secs} ]]; then
        wd_logger 1 "ERROR: 'sox ${wav_filename} -n stats' reports invalid wav file length of ${wav_length_secs} seconds"
        return 1
    fi
    return 0
}
 
function get_rms_levels() 
{
    local __return_var_name=$1
    local __return_string_name=$2
    local wav_filename=$3
    local rms_adjust=$4

    if ! is_valid_wav_file ${wav_filename} ${MIN_VALID_WSPR_WAV_SECCONDS} ${MAX_VALID_WSPR_WAV_SECONDS} ; then
        wd_logger 1 "ERROR: 'valid_wav_file ${wav_filename}' => $?"
        return 1
    fi
    local output_line=""
    local sample_info
    for sample_info in "${WAV_SAMPLES_LIST[@]}"; do
        local sample_line_list=( ${sample_info} )
        local sample_start_sec=${sample_line_list[0]}
        local sample_length_secs=${sample_line_list[1]}
        local sample_vals
        get_wav_levels  sample_vals ${wav_filename} ${sample_start_sec} ${sample_length_secs} ${rms_adjust}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'get_wav_levels  sample_vals ${wav_filename} ${sample_start_sec} ${sample_length_secs}' => {ret_code}"
            return 1
        fi
        output_line="${output_line} ${sample_vals}"
    done
    local output_line_list=( ${output_line} )
    if [[ ${#output_line_list[@]} -ne 12 ]]; then
        wd_logger 1 "ERROR: expected 12 fields of dB info, but got only ${#output_line_list[@]} fields from calls to get_wav_levels()"
        return 1
    fi
    local return_rms_value
    local pre_rms_value=${output_line_list[3]}                                           # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
    local post_rms_value=${output_line_list[11]}                                           # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
    if [[  $(bc --mathlib <<< "${pre_rms_value} <  ${post_rms_value}") -eq "1" ]]; then
        return_rms_value=${pre_rms_value}
        wd_logger 2 "So returning rms_level ${return_rms_value} which is from pre_tx"
    else
        return_rms_value=${post_rms_value}
        wd_logger 2 "So returning rms_level ${return_rms_value} which is from post_tx"
    fi

    local signal_level_line="              ${output_line}   ${return_rms_value}"
    eval ${__return_var_name}=${return_rms_value}
    eval ${__return_string_name}=\"${signal_level_line}\"
    wd_logger 1 "Returning rms_value=${return_rms_value} and signal_level_line='${signal_level_line}'"
    return 0
}

function decode_wpsr_wav_file() {
    local wav_file_name=$1
    local wspr_decode_capture_freq_hz=$2
    local rx_khz_offset=$3
    local stdout_file=$4

    wd_logger 1 "Decode file ${wav_file_name} for frequency ${wspr_decode_capture_freq_hz} and send stdout to ${stdout_file}.  rx_khz_offset=${rx_khz_offset}"
    local wsprd_cmd_flags=${WSPRD_CMD_FLAGS}
    local wspr_decode_capture_freq_hzx=${wav_file_name#*_}                                                 ### Remove the year/date/time
    wspr_decode_capture_freq_hzx=${wspr_decode_capture_freq_hz%_*}    ### Remove the _usb.wav
    local wspr_decode_capture_freq_hzx=$( bc <<< "${wspr_decode_capture_freq_hz} + (${rx_khz_offset} * 1000)" )
    local wspr_decode_capture_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${wspr_decode_capture_freq_hz}/1000000.0" ) )

    if [[ ! -s ALL_WSPR.TXT ]]; then
        touch ALL_WSPR.TXT
    fi
    local all_wspr_size=$(${GET_FILE_SIZE_CMD} ALL_WSPR.TXT)
    if [[ ${all_wspr_size} -gt ${MAX_ALL_WSPR_SIZE} ]]; then
        wd_logger 1 "ALL_WSPR.TXT has grown too large, so truncating it"
        tail -n 1000 ALL_WSPR.TXT > ALL_WSPR.tmp
        mv ALL_WSPR.tmp ALL_WSPR.TXT
    fi
    local last_line=$(tail -n 1 ALL_WSPR.TXT)

    timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: Command 'timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}' returned error ${ret_code}"
        return ${ret_code}
    fi
    grep -A 10000 "${last_line}" ALL_WSPR.TXT | grep -v "${last_line}" > ALL_WSPR.TXT.new
    return ${ret_code}
}

declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare WSPRD_CMD=${WSPRD_BIN_DIR}/wsprd
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare WSPRD_CMD_FLAGS="${WSPRD_CMD_FLAGS--C 500 -o 4 -d}"
declare WSPRD_STDOUT_FILE=wsprd_stdout.txt               ### wsprd stdout goes into this file, but we use wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                         ### Truncate the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..
declare RAW_FILE_FULL_SIZE=1440000   ### Approximate number of bytes in a full size one minute long raw or wav file
declare ONE_MINUTE_WAV_FILE_MIN_SIZE=${ONE_MINUTE_WAV_FILE_MIN_SIZE-1438000}   ### In bytes
declare ONE_MINUTE_WAV_FILE_MAX_SIZE=${ONE_MINUTE_WAV_FILE_MAX_SIZE-1450000}


### If the wav recording daemon is running, we can calculate how many seconds until it starts to fill the raw file (if 0 length first file) or fills the 2nd raw file.  Sleep until then
function sleep_until_raw_file_is_full() {
    local filename=$1
    if [[ ! -f ${filename} ]]; then
        wd_logger 1 "ERROR: ${filename} doesn't exist"
        return 1
    fi
    local old_file_size=$( ${GET_FILE_SIZE_CMD} ${filename} )
    local new_file_size
    local start_seconds=${SECONDS}

    sleep 2
    while [[ -f ${filename} ]] && new_file_size=$( ${GET_FILE_SIZE_CMD} ${filename}) && [[ ${new_file_size} -gt ${old_file_size} ]]; do
        wd_logger 3 "Waiting for file ${filename} to stop growing in size. old_file_size=${old_file_size}, new_file_size=${new_file_size}"
        old_file_size=${new_file_size}
        sleep 2
    done
    local loop_seconds=$(( SECONDS - start_seconds ))
    if [[ ! -f ${filename} ]]; then
        wd_logger 1 "ERROR: file ${filename} disappeared after ${loop_seconds} seconds"
        return 1
    fi
    if [[ ${new_file_size} -lt ${ONE_MINUTE_WAV_FILE_MIN_SIZE} ]]; then
        wd_logger 1 "The wav file stablized at invalid too small size ${new_file_size} which almost always occurs at startup. Flush this file since it can't be used as part of a WSPR wav file"
        wd_rm ${filename}
        return 2
    fi
    if [[ ${new_file_size} -gt ${ONE_MINUTE_WAV_FILE_MAX_SIZE} ]]; then
        local kiwi_freq=${filename#*_}
              kiwi_freq=${kiwi_freq::3}
        local ps_output=$(ps au | grep "kiwirecorder.*freq=${kiwi_freq}" | grep -v grep)
        local kiwirecorder_pids=( $(awk '{print $2}' <<< "${ps_output}" ) )
        if [[ ${#kiwirecorder_pids[@]} -eq 0 ]]; then
            wd_logger 1 "ERROR: wav file stablized at invalid too large size ${new_file_size}, but can't find any kiwirecorder processes which would be creating it"
        else
            kill ${kiwirecorder_pids[@]}
            wd_logger 1 "ERROR: wav file stablized at invalid too large size ${new_file_size}, so there may be more than one instance of the KWR running. 'ps' output was:\n${ps_output}\nSo executed 'kill ${kiwirecorder_pids[*]}'"
        fi
        return 1
    fi
    wd_logger 2 "File ${filename} stabliized at size ${new_file_size} after ${loop_seconds} seconds"
    return 0
}

### Returns the minute and epoch of the first sample in 'filename'.  Variations in CPU and OS make using the file's timestamp a poor choice for the time source.
### So use the time in the file's name
function get_file_start_time_info() 
{
    local __epoch_return_variable_name=$1
    local __minute_return_variable_name=$2
    local file_name=$3

    local epoch_from_file_stat=$( ${GET_FILE_MOD_TIME_CMD} ${file_name})
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: '${GET_FILE_MOD_TIME_CMD} ${file_name}' => ${ret_code}"
        return 1
    fi
    local minute_from_file_epoch=$( printf "%(%M)T" ${epoch_from_file_stat}  )

    local year_from_file_name="${file_name:0:4}"
    local month_from_file_name=${file_name:4:2}
    local day_from_file_name=${file_name:6:2}
    local hour_from_file_name=${file_name:9:2}
    local minute_from_file_name=${file_name:11:2}
    local file_spec_for_date_cmd="${month_from_file_name}/${day_from_file_name}/${year_from_file_name} ${hour_from_file_name}:${minute_from_file_name}:00"
    local epoch_from_file_name=$( date --date="${file_spec_for_date_cmd}" +%s )

    if [[ ${minute_from_file_epoch} != ${minute_from_file_name} ]]; then
        wd_logger 1 "INFO: minute_from_file_epoch=${minute_from_file_epoch} != minute_from_file_name=${minute_from_file_name}, but always use file_name times"
    fi
    
    wd_logger 1 "File '${file_name}' => epoch_from_file_stat=${epoch_from_file_stat}, epoch_from_file_name=${epoch_from_file_name}, minute_from_file_epoch=${minute_from_file_epoch}, minute_from_file_name=${minute_from_file_name}"

    eval ${__epoch_return_variable_name}=${epoch_from_file_name}
    eval ${__minute_return_variable_name}=${minute_from_file_name}
    return 0
}

function cleanup_wav_file_list()
{
    local __return_clean_files_string_name=$1
    local raw_file_list=( $2 )

    if [[ ${#raw_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Was given an empty file list"
        eval ${__return_clean_files_string_name}=\"\"
        return 0
    fi
    wd_logger 1 "Testing list of raw files: '${raw_file_list[*]}'"

    local last_file_minute=-1
    local flush_files="no"
    local test_file_name
    local return_clean_files_string=""

    local raw_file_index=$(( ${#raw_file_list[@]} - 1 ))
    while [[ ${raw_file_index} -ge 0 ]]; do
        local test_file_name=${raw_file_list[${raw_file_index}]}
        wd_logger 1 "Testing file ${test_file_name}"
        if [[ ${flush_files} == "yes" ]]; then
            wd_logger 1 "ERROR: flushing file ${test_file_name}"
            rm ${test_file_name}
        else
            is_valid_wav_file ${test_file_name} ${MIN_VALID_RAW_WAV_SECCONDS} ${MAX_VALID_RAW_WAV_SECONDS}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: found wav file '${test_file_name}' has invalid size.  Flush it"
                rm ${test_file_name}
                flush_files="yes"
            else
                ### Size is valid, see if it is one minute earlier than the previous file
                local test_file_minute=${test_file_name:11:2}
                if [[ 10#${last_file_minute} -lt 0 ]]; then
                    wd_logger 1 "First clean file is at minute ${test_file_minute}"
                    last_file_minute=${test_file_minute}
                    return_clean_files_string="${test_file_name}"
                else
                    if [[ 10#${last_file_minute} -eq 0 ]]; then
                         last_file_minute=60
                         wd_logger 1 "Testing for a minute 59 file '${test_file_name}', so changed last_file_minute to ${last_file_minute}"
                    fi
                    local minute_difference=$(( 10#${last_file_minute} - 10#${test_file_minute} ))
                    if [[ ${minute_difference} -eq 1 ]]; then
                        wd_logger 1 "'${test_file_name}' size is OK and it is one minute earlier than the next file in the list"
                        return_clean_files_string="${test_file_name} ${return_clean_files_string}"
                        last_file_minute=${test_file_minute}
                    else
                        wd_logger 1 "ERROR: there is a gap of more than 1 minute between this file '${test_file_name}' and the next file in the list ${raw_file_list[ $(( ++${raw_file_index} )) ]}, so flush this file and all earlier files"
                        rm ${test_file_name}
                        flush_files="yes"
                    fi
                fi
            fi
        fi
        wd_logger 1 "Done checking '${test_file_name}' from index ${raw_file_index}"
        (( --raw_file_index ))
    done
    local clean_files_list=( ${return_clean_files_string} )

    wd_logger 1 "Given raw_file_list[${#raw_file_list[@]}]='${raw_file_list[*]}', returning clean_file_list[${#clean_files_list[*]}]='${clean_files_list[*]}'"
    if [[ ${#raw_file_list[@]} -ne ${#clean_files_list[*]} ]]; then
        wd_logger 1 "ERROR: cleaned list raw_file_list[${#raw_file_list[@]}]='${raw_file_list[*]}' => clean_file_list[${#clean_files_list[*]}]='${clean_files_list[*]}'"
    fi
    eval ${__return_clean_files_string_name}=\"${return_clean_files_string}\"
    return 0
} 


### Waits for wav files needed to decode one or more of the MODEs have been fully recorded
function get_wav_file_list() {
    local return_variable_name=$1  ### returns a string with a sapce-seperated list each element of which is of the form MODE:first.wav[,second.wav,...]
    local receiver_name=$2              ### Used when we need to start or restart the wav recording daemon
    local receiver_band=$3           
    local receiver_modes=$4
    local      target_modes_list=( ${receiver_modes//:/ } )    ### Argument has form MODE1[:MODE2...] put it in local array  
    local -ia 'target_minutes_list=( $( tr " " "\n" <<< "${target_modes_list[@]/?/}" | sort -u | tr "\n" " " ) )'        ### Chop the "W" or "F" from each mode element to get the minutes for each mode  NOTE THE "s which are requried if arithmatic is being done on each element!!!!
    local -ia 'target_seconds_list=( "${target_minutes_list[@]/%/*60}" )' ### Multiply the minutes of each mode by 60 to get the number of seconds of wav files needed to decode that mode  NOTE that both ' and " are needed for this to work
    local oldest_file_needed=${target_seconds_list[-1]}

    wd_logger 1 "Start with args '${return_variable_name} ${receiver_name} ${receiver_band} ${receiver_modes}', then receiver_modes => ${target_modes_list[*]} => target_minutes=( ${target_minutes_list[*]} ) => target_seconds=( ${target_seconds_list[*]} )"
    ### This code requires  that the list of wav files to be generated is in ascending seconds order, i.e "120 300 900 1800)

    if ! spawn_wav_recording_daemon ${receiver_name} ${receiver_band} ; then
        local ret_code=$?
        wd_logger 1 "ERROR: 'spawn_wav_recording_daemon ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi

    shopt -s nullglob
    local raw_file_list=( minute-*.raw *_usb.wav)        ### Get list of the one minute long 'raw' wav files being created by the Kiwi (.wav) or SDR ((.raw)
    shopt -u nullglob

    wd_logger 1 "Found raw/wav files '${raw_file_list[*]}'"

    case ${#raw_file_list[@]} in
        0 )
            wd_logger 2 "There are no raw files.  Wait up to 10 seconds for the first file to appear"
            shopt -s nullglob
            local timeout=0
            while raw_file_list=( minute-*.raw *_usb.wav) && [[ ${#raw_file_list[@]} -eq 0 ]] && [[ ${timeout} -lt 10 ]]; do
                sleep 1
                (( ++timeout ))
            done
            shopt -u nullglob
            if [[ ${#raw_file_list[@]} -eq 0 ]]; then
                wd_logger 1 "Timeout after ${timeout} seconds while waiting for the first wav file to appear"
            else
                wd_logger 2 "First file appeared after waiting ${timeout} seconds"
            fi
            return 1
            ;;
        1 )
            wd_logger 2 "There is only 1 raw file ${raw_file_list[0]} and all modes need at least 2 minutes. So wait for this file to be filled"
            sleep_until_raw_file_is_full ${raw_file_list[0]}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "Error while waiting for the first  wav file to fill, 'sleep_until_raw_file_is_full ${raw_file_list[0]}' => ${ret_code} "
            fi
            return 2
            ;;
       * )
            wd_logger 2 "Found ${#raw_file_list[@]} files, so we *may* have enough 1 minute wav files to make up a WSPR pkt. Wait until the last file is full, then proceed to process the list."
            local second_from_file_name=${raw_file_list[0]:13:2}
            if [[ 10#${second_from_file_name} -ne 0 ]]; then
                wd_logger 2 "Raw file '${raw_file_list[0]}' name says the first file recording starts at second ${second_from_file_name}, not at second 0, so flushing it"
                rm ${raw_file_list[0]}
                return 3
            fi
            sleep_until_raw_file_is_full ${raw_file_list[-1]}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: while waiting for the last of ${#raw_file_list[@]} wav files to fill, 'sleep_until_raw_file_is_full ${raw_file_list[-1]}' => ${ret_code} "
                return 4
            fi
            ;;
    esac

    wd_logger 2 "Found ${#raw_file_list[@]} full raw files. Fill return list with lists of those raw files which are part of each WSPR mode"

    local clean_files_string
    cleanup_wav_file_list  clean_files_string "${raw_file_list[*]}"
    local clean_file_list=( ${clean_files_string} )
    if [[ ${#clean_file_list[@]} -ne ${#raw_file_list[@]} ]]; then
        if [[ ${#clean_file_list[@]} -eq 0 ]]; then
            wd_logger 1 "ERROR: clean_file_list[] has no files"
            return 1
        fi
        if [[ ${#clean_file_list[@]} -lt 2 ]]; then
            wd_logger 1 "ERROR: clean_file_list[]='${clean_file_list[*]}' has less than the minimum 2 packets needed for the smallest WSPR packet.  So return error and try again to find a good list"
            return 1
        fi
        raw_file_list=( ${clean_file_list[@]} )
        wd_logger 1 "ERROR: After cleanup, raw_file_list[]='${raw_file_list[*]}' which is enough for a minimm sized WSPR packet"
    fi
    ### We now have a list of two or more full size raw files
    get_file_start_time_info epoch_of_first_raw_file minute_of_first_raw_file ${raw_file_list[0]}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'get_file_start_time_info epoch_of_first_raw_file minute_of_first_raw_file ${raw_file_list[0]}' => ${ret_code}"
        return 4
    fi

    wd_logger 1 "The first raw file ${raw_file_list[0]} write time is at minute ${minute_of_first_raw_file}"
    local index_of_first_file_which_needs_to_be_saved=${#raw_file_list[@]}                         ### Presume we will need to keep none of the raw files

    local return_list=()
    local seconds_in_wspr_pkt
    for seconds_in_wspr_pkt in  ${target_seconds_list[@]} ; do
        local raw_files_in_wav_file_count=$((seconds_in_wspr_pkt / 60))
        wd_logger 2 "Check to see if we can create a new ${seconds_in_wspr_pkt} seconds long wav file from ${raw_files_in_wav_file_count} raw files"

        ### Check to see if we have previously returned some of these files in a previous call to this function
        shopt -s nullglob
        local wav_raw_pkt_list=( *.wav.${seconds_in_wspr_pkt}-secs )
        shopt -u nullglob

        local index_of_first_unreported_raw_file
        local index_of_last_unreported_file
        if [[ ${#wav_raw_pkt_list[@]} -eq 0 ]]; then
            wd_logger 2 "Found no wav_secs files for wspr pkts of this length, so there were no previously reported packets of this length. So find index of first raw file that would start a wav file of this many seconds"
            local minute_of_first_raw_sample=$(( 10#${minute_of_first_raw_file}))
            if [[ ${receiver_name} =~ "SDR" ]]; then
                $(( --minute_of_first_raw_sample ))
                if [[ ${minute_of_first_raw_sample} -lt 0 ]]; then
                    minute_of_first_raw_sample=59
                fi
                wd_logger 1 "Adjusted minute_of_first_raw_sample by 1 minute to ${minute_of_first_raw_sample} which compensates for the façt that sdrTest writes the last bytes of a wav file in the following minute of the first bytes"
            fi

            local first_minute_raw_wspr_pkt_index=$(( minute_of_first_raw_sample % raw_files_in_wav_file_count ))
            index_of_first_unreported_raw_file=$(( (raw_files_in_wav_file_count - first_minute_raw_wspr_pkt_index) % raw_files_in_wav_file_count ))
            wd_logger 2 "Raw_file ${raw_file_list[0]} of minute ${minute_of_first_raw_sample} is raw pkt #${first_minute_raw_wspr_pkt_index} of a ${seconds_in_wspr_pkt} second long wspr packet. So start of next wav_raw will be found at raw_file index ${index_of_first_unreported_raw_file}"
        else
            wd_logger 2 "Found that we previously returned ${#wav_raw_pkt_list[@]} wav files of this length"
            
            if [[ ${#wav_raw_pkt_list[@]} -eq 1 ]]; then
                wd_logger 2 "There is only one wav_raw pkt ${wav_raw_pkt_list[@]}, so leave it alone"
            else
                local flush_count=$(( ${#wav_raw_pkt_list[@]} - 1 ))
                local flush_list=( ${wav_raw_pkt_list[@]:0:${flush_count}} )
                if [[ ${#flush_list[*]} -gt 0 ]]; then
                    wd_logger 2 "Flushing ${#flush_list[@]} files '${flush_list[*]}' leaving only ${wav_raw_pkt_list[-1]}"
                    rm ${flush_list[*]}
                else
                    wd_logger 1 "ERROR: wav_raw_pkt_list[] has ${#wav_raw_pkt_list[@]} files, but flush_list[] is empty"
                fi
            fi

            local filename_of_latest_wav_raw=${wav_raw_pkt_list[-1]}
            local epoch_of_latest_wav_raw_file
            local minute_of_latest_wav_raw_file
            get_file_start_time_info  epoch_of_latest_wav_raw_file minute_of_latest_wav_raw_file ${filename_of_latest_wav_raw}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'get_file_start_time_info  epoch_of_latest_wav_raw_file minute_of_latest_wav_raw_file ${filename_of_latest_wav_raw}' => ${ret_code}"
                return 5
            fi
            local index_of_first_reported_raw_file=$(( ( epoch_of_latest_wav_raw_file - epoch_of_first_raw_file ) / 60 ))
            index_of_first_unreported_raw_file=$(( index_of_first_reported_raw_file + raw_files_in_wav_file_count ))

            wd_logger 2 "Latest wav_raw ${filename_of_latest_wav_raw} has epoch ${epoch_of_latest_wav_raw_file}. epoch_of_first_raw_file == ${epoch_of_first_raw_file}.  So index_of_first_unreported_raw_file = ${index_of_first_unreported_raw_file}"
        fi
        if [[ ${index_of_first_unreported_raw_file} -ge ${#raw_file_list[@]} ]]; then
            wd_logger 2 "The first first raw file of a wav_raw file is not yet in the list of minute_raw[] files.  So continue to search for the next WSPR pkt length"
            continue
        fi

        ### The first file is present, now see if the last file is also present
        index_of_last_raw_file_for_this_wav_file=$(( index_of_first_unreported_raw_file + raw_files_in_wav_file_count - 1))

        if [[ ${index_of_last_raw_file_for_this_wav_file} -ge ${#raw_file_list[@]} ]]; then
            ### The last file isn't present
            if [[ ${index_of_first_unreported_raw_file} -lt ${index_of_first_file_which_needs_to_be_saved} ]]; then
                wd_logger 1 "For ${seconds_in_wspr_pkt} second packet, the first unreported file '${raw_file_list[${index_of_first_unreported_raw_file}]}' is at index ${index_of_first_unreported_raw_file}, so adjust the current index_of_first_file_which_needs_to_be_saved from ${index_of_first_file_which_needs_to_be_saved} down to that index"
                index_of_first_file_which_needs_to_be_saved=${index_of_first_unreported_raw_file}
            fi
            wd_logger 2 "The first unreported ${seconds_in_wspr_pkt} seconds raw file is at index ${index_of_first_unreported_raw_file}, but the last raw file is not yet present, so we can't yet create a wav file. So continue to search for the next WSPR pkt length"
            continue
         fi
         ### There is a run of files which together form a wav file of this seconds in length
         local this_seconds_files="${seconds_in_wspr_pkt}:${raw_file_list[*]:${index_of_first_unreported_raw_file}:${raw_files_in_wav_file_count} }"
         local this_seconds_comma_separated_file=${this_seconds_files// /,}
         return_list+=( ${this_seconds_comma_separated_file} )
         wd_logger 2 "Added file list for ${seconds_in_wspr_pkt} second long wav file to return list from index [${index_of_first_unreported_raw_file}:${index_of_last_raw_file_for_this_wav_file}] => ${this_seconds_comma_separated_file}"

         local wav_list_returned_file=${raw_file_list[${index_of_first_unreported_raw_file}]}.${seconds_in_wspr_pkt}-secs
         shopt -s nullglob
         local flush_list=( *.${seconds_in_wspr_pkt}-secs )
         shopt -u nullglob
         if [[ ${#flush_list[@]} -gt 0 ]]; then
             wd_logger 1 "For ${seconds_in_wspr_pkt} second packet, flushing ${#flush_list[@]} old wav_raw file(s): ${flush_list[*]}"
             rm -f ${flush_list[@]}    ### We only need to remember this new wav_raw file, so flush all older ones.
         fi
         if [[ ${seconds_in_wspr_pkt} == "120" ]]; then
             local minute_of_first_unreported_raw_file=${wav_list_returned_file:11:2}
             local decimal_minute=$(( 10#${minute_of_first_unreported_raw_file} % 2))
             if [[ ${decimal_minute} -eq 0 ]]; then
                 wd_logger 1 "For 120 second wav file, returning an even minute start wav file '${wav_list_returned_file}'"
             else
                 wd_logger 1 "ERROR: for 120 second wav file, returning an odd minute start wav file '${wav_list_returned_file}'"
             fi
         fi

         touch -r ${raw_file_list[${index_of_first_unreported_raw_file}]} ${wav_list_returned_file}

         if [[ ${index_of_first_unreported_raw_file} -lt ${index_of_first_file_which_needs_to_be_saved} ]]; then
             wd_logger 1 "Added a new report list to be returned and remembering to save the files in it by changing the current index_of_first_file_which_needs_to_be_saved=${index_of_first_file_which_needs_to_be_saved} to index_of_first_unreported_raw_file=${index_of_first_unreported_raw_file}"
             index_of_first_file_which_needs_to_be_saved=${index_of_first_unreported_raw_file}
         fi
         wd_logger 2 "For ${seconds_in_wspr_pkt} packet, Remembered that a list for this wav file has been returned to the decoder by creating the zero length file ${wav_list_returned_file}"
    done
    
    if [[ ${index_of_first_file_which_needs_to_be_saved} -lt ${#raw_file_list[@]} ]] ; then
        local count_of_raw_files_to_flush=$(( index_of_first_file_which_needs_to_be_saved ))
        wd_logger 1 "After searching for all requested wav file lengths, found file [${index_of_first_file_which_needs_to_be_saved}] '${raw_file_list[${index_of_first_file_which_needs_to_be_saved}]}' is the oldest file which needs to be saved" 
        if [[ ${count_of_raw_files_to_flush} -gt 0 ]]; then
            wd_logger 1 "So purging files '${raw_file_list[*]:0:${count_of_raw_files_to_flush}}'"
            rm ${raw_file_list[@]:0:${count_of_raw_files_to_flush}}
        fi
    fi
    wd_logger 2 "Returning ${#return_list[@]} wav file lists: '${return_list[*]}'"
    eval ${return_variable_name}=\"${return_list[*]}\"
    return 0
}

function decoding_daemon_kill_handler() {
    local receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local receiver_band=${2}

    echo "$(date): decoding_daemon_kill_handler() running in $PWD with pid $$ is processing SIGTERM to stop decoding on ${receiver_name},${receiver_band}" > decoding_daemon_kill_handler.log
    kill_wav_recording_daemon ${receiver_name} ${receiver_band}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        echo "$(date): ERROR: 'kill_wav_recording_daemon ${receiver_name} ${receiver_band} => $?" >> decoding_daemon_kill_handler.log
    else
        echo "$(date): Successful: 'kill_wav_recording_daemon running as pid $$ for ${receiver_name} ${receiver_band} => $?" >> decoding_daemon_kill_handler.log
    fi
    rm ${DECODING_DAEMON_PID_FILE}
    exit
}

### Called by the decoding_daemon() to create an enhanced_spot file from the output of ALL_WSPR.TXT
### That enhanced_spot file is then posted to the subdirectory where the posting_daemon will process it (and other enhnced_spot filed if this receiver is part of a MERGEd group)

### For future reference, here is the output lines in  ALL_WSPR.TXT taken from the wsjt-x 2.1-2 source code:
# In WSJT-x v 2.2+, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
#    fprintf(fall_wspr,    "%6s    %4s    %3.0f    %5.2f    %11.7f    %-22s            %2d    %5.2f     %2d        %2d     %4d        %2d        %3d        %5u    %5d \n",
#                         date,   time,  snr,     dt,      freq,     message, (int)drift,    sync, ipass+1, blocksize, jitter, decodetype, nhardmin, cycles/81, metric);

declare  FIELD_COUNT_DECODE_LINE_WITH_GRID=18                                              ### wspd v2.2 adds two fields and we have added the 'upload to wsprnet.org' field, so lines with a GRID will have 17 + 1 + 2 noise level fields.  V3.x added spot_mode to the end of each line
declare  FIELD_COUNT_DECODE_LINE_WITHOUT_GRID=$((FIELD_COUNT_DECODE_LINE_WITH_GRID - 1))   ### Lines without a GRID will have one fewer field

function create_enhanced_spots_file_and_queue_to_posting_daemon () {
    local real_receiver_wspr_spots_file=$1              ### file with the new spot lines found in ALL_WSPR.TXT
    local spot_file_date=$2              ### These are prepended to the output file name
    local spot_file_time=$3
    local wspr_cycle_rms_noise=$4                       ### The folowing fields are the same for every spot in the wspr cycle
    local wspr_cycle_fft_noise=$5
    local wspr_cycle_kiwi_overloads_count=$6
    local real_receiver_call_sign=$7                    ### For real receivers, these are taken from the conf file line
    local real_receiver_grid=$8                         ### But for MERGEd receivers, the posting daemon will change them to the call+grid of the MERGEd receiver
    local proxy_upload_this_spot=0    ### This is the last field of the enhanced_spot line. If ${SIGNAL_LEVEL_UPLOAD} == "proxy" AND this is the only spot (or best spot among a MERGEd group), 
                                      ### then the posting daemon will modify this last field to '1' to signal to the upload_server to forward this spot to wsprnet.org
    local cached_spots_file_name="${spot_file_date}_${spot_file_time}_spots.txt"

    wd_logger 1 "Enhance the spot lines from ALL_WSPR_TXT in ${real_receiver_wspr_spots_file} into ${cached_spots_file_name}"
    > ${cached_spots_file_name}         ### truncates or creates a zero length file
    local spot_line
    while read spot_line ; do
        wd_logger 3 "Enhance line '${spot_line}'"
        local spot_line_list=(${spot_line/,/})         
        local spot_line_list_count=${#spot_line_list[@]}
        local spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields                                                                                             ### the order of the first fields in the spot lines created by decoding_daemon()
        read  spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields <<< "${spot_line/,/}"
        local    spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_pkt_minutes ### the order of the rest of the fields in the spot lines created by decoding_daemon()
        if [[ ${spot_line_list_count} -eq ${FIELD_COUNT_DECODE_LINE_WITH_GRID} ]]; then
            read spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_pkt_minutes <<< "${other_fields}"    ### Most spot lines have a GRID
        elif [[ ${spot_line_list_count} -eq ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
            spot_grid="none"
            read           spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_pkt_minutes <<< "${other_fields}"    ### Most spot lines have a GRID
        else
            ### The decoding daemon formated a line we don't recognize
            wd_logger 1 "INTERNAL ERROR: unexpected number of fields ${spot_line_list_count} rather than the expected ${FIELD_COUNT_DECODE_LINE_WITH_GRID} or ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} in ALL_WSPR.TXT spot line '${spot_line}'" 
            continue
        fi
        ### G3ZIL April 2020 V1    add azi to each spot line
        wd_logger 2 "'add_derived ${spot_grid} ${real_receiver_grid} ${spot_freq}'"
        add_derived ${spot_grid} ${real_receiver_grid} ${spot_freq}
        if [[ ! -f ${DERIVED_ADDED_FILE} ]] ; then
            wd_logger 2 "spots.txt ${DERIVED_ADDED_FILE} file not found"
            return 1
        fi
        local derived_fields=$(cat ${DERIVED_ADDED_FILE} | tr -d '\r')
        derived_fields=${derived_fields//,/ }   ### Strip out the ,s
        wd_logger 2 "derived_fields='${derived_fields}'"

        local band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon
        read  band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon <<< "${derived_fields}"

        if [[ ${spot_date} != ${spot_file_date} ]]; then
            wd_logger 1 "WARNING: the date in spot line ${spot_date} doesn't match the date in the filename: ${spot_file_date}"
        fi
        if [[ ${spot_time} != ${spot_file_time} ]]; then
            wd_logger 1 "WARNING: the time in spot line ${spot_time} doesn't match the time in the filename: ${spot_file_time}"
        fi

        ### Output a space-seperated line of enhanced spot data.  The first 14 fields are in the same order but with "none" added when the message field with CALL doesn't include a GRID field
        ### Each of these lines should be uploaded to logs.wsprdaemon.org.  If ${SIGNAL_LEVEL_UPLOAD} == "proxy" AND this is the only spot (or best spot among a MERGEd group), then the posting daemon will modify the last field to signal the upload_server to forward this spot to wsprnet.org
        ### The first row of printed variables are taken from the ALL_WSPR.TXT file lines and are printed in the same order as they were found there
        ### The second row are the values added  by our 'add_derived' Python line
        ### The third row are values taken from WD's  rms_noise, fft_noise, WD.conf call sign and grid, etc.
        printf "%6s %4s %3.0f %5.2f %12.7f %-22s %2d %5.2f %2d %2d %4d %2d %3d %5u %5d %4d %5d %2d %4d %6.1f %6.1f %4d %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6s %12s %4d %1d\n" \
             ${spot_date} ${spot_time} ${spot_snr} ${spot_dt} ${spot_freq} "${spot_call} ${spot_grid} ${spot_pwr}" ${spot_drift} ${spot_sync_quality} ${spot_ipass} ${spot_blocksize} ${spot_jitter} ${spot_decodetype} ${spot_nhardmin} ${spot_cycles} ${spot_metric} ${spot_pkt_minutes} \
              ${band} ${km} ${rx_az} ${rx_lat} ${rx_lon} ${tx_az} ${tx_lat} ${tx_lon} ${v_lat} ${v_lon} \
              ${wspr_cycle_rms_noise} ${wspr_cycle_fft_noise} ${real_receiver_grid} ${real_receiver_call_sign} ${wspr_cycle_kiwi_overloads_count} ${proxy_upload_this_spot} >> ${cached_spots_file_name} 
        if [[ -f debug_printf.conf ]]; then
            source debug_printf.conf
            if [[ -n "${debug_printf_fmt}" ]]; then
                local debug_printf=$( printf "${debug_printf_fmt}" \
                  ${spot_date} ${spot_time} ${spot_snr} ${spot_dt} ${spot_freq} "${spot_call} ${spot_grid} ${spot_pwr}" ${spot_drift} ${spot_sync_quality} ${spot_ipass} ${spot_blocksize} ${spot_jitter} ${spot_decodetype} ${spot_nhardmin} ${spot_cycles} ${spot_metric} ${spot_pkt_minutes} \
                  ${band} ${km} ${rx_az} ${rx_lat} ${rx_lon} ${tx_az} ${tx_lat} ${tx_lon} ${v_lat} ${v_lon} \
                  ${wspr_cycle_rms_noise} ${wspr_cycle_fft_noise} ${real_receiver_grid} ${real_receiver_call_sign} ${wspr_cycle_kiwi_overloads_count} ${proxy_upload_this_spot})
                wd_logger 1 "debug_printf: ${debug_printf}"
            fi
        fi
    done < ${real_receiver_wspr_spots_file}

    if [[ ! -s ${cached_spots_file_name} ]]; then
        wd_logger 1 "Found no spots to queue, so queuing zero length spot file"
    else
        wd_logger 1 "Created '${cached_spots_file_name}' of size $(wc -c < ${cached_spots_file_name}):\n$(< ${cached_spots_file_name})"
    fi

    if grep "<...>" ${cached_spots_file_name} > bad_spots.txt; then
        wd_logger 1 "Removing $(wc -l < bad_spots.txt) bad spot line(s) from upload:\n$(< bad_spots.txt)"
        grep -v  "<...>" ${cached_spots_file_name} > cleaned_spots.txt
        mv cleaned_spots.txt ${cached_spots_file_name}
    fi

    ### Queue the enhanced_spot file we have just created to all of the posting daemons 
    shopt -s nullglob    ### * expands to NULL if there are no .wav wav_file
    local dir
    for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
        ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
        local decoding_client_spot_file_name=${dir}/${cached_spots_file_name}
        if [[ -s ${decoding_client_spot_file_name} ]]; then
            wd_logger 1 "ERROR: file ${decoding_client_spot_file_name} already exisits, so dropping this new ${cached_spots_file_name}"
        else
            wd_logger 1 "Creating link from ${cached_spots_file_name} to ${decoding_client_spot_file_name} which is monitored by a posting daemon"
            ln ${cached_spots_file_name} ${decoding_client_spot_file_name}
        fi
    done
    rm ${cached_spots_file_name}    ### The links will persist until all the posting daemons delete them
    wd_logger 1 "Done creating and queuing '${cached_spots_file_name}'"
}

function get_wsprdaemon_noise_queue_directory()
{
    local __return_directory_name_return_variable=$1
    local receiver_name=$2
    local receiver_band=$3

    local receiver_call_grid
    
    receiver_call_grid=$( get_call_grid_from_receiver_name ${receiver_name} )
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find receiver '${receiver_name}"
        return 1
    fi
    ### Linux directory names can't have the '/' character in them which is so common in ham call signs.  So replace all those '/' with '=' characters which (I am pretty sure) are never legal in call signs
    local call_dir_name=${receiver_call_grid//\//=}
    local noise_directory=${UPLOADS_WSPRDAEMON_NOISE_ROOT_DIR}/${receiver_call_grid}/${receiver_name}/${receiver_band}

    mkdir -p ${noise_directory}
    eval ${__return_directory_name_return_variable}=${noise_directory}

    wd_logger 1 "Noise files from receiver_name=${receiver_name} receiver_band=${receiver_band} will be queued in ${noise_directory}"
    return 0
}


function decoding_daemon() {
    local receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local receiver_band=${2}
    local receiver_modes_arg=${3}

    local receiver_call
    receiver_call=$( get_receiver_call_from_name ${receiver_name} )
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find receiver call from '${receiver_name}"
        return 1
    fi
    local receiver_grid
    receiver_grid=$( get_receiver_grid_from_name ${receiver_name} )
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find receiver grid 'from ${receiver_name}"
        return 1
    fi

    wd_logger 1 "Starting with args ${receiver_name} ${receiver_band} ${receiver_modes_arg}, receiver_call=${receiver_call} receiver_grid=${receiver_grid}"
    setup_verbosity_traps          ## So we can increment and decrement verbosity without restarting WD
    trap "decoding_daemon_kill_handler ${receiver_name} ${receiver_band}" SIGTERM

    local receiver_modes
    get_decode_mode_list  receiver_modes ${receiver_modes_arg} ${receiver_band}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then 
        wd_logger 1 "ERROR: 'get_decode_mode_list receiver_modes ${receiver_modes_arg}' => ${retCode}"
        return ${ret_code}
    fi
    ### Put the list of configured decoding modes into the array receiver_modes_list[]
    local receiver_modes_list=( ${receiver_modes//:/ } ) 
    wd_logger 1 "Got a list of ${#receiver_modes_list[*]} modes to be decoded from the wav files: '${receiver_modes_list[*]}'"

    local receiver_maidenhead=$(get_my_maidenhead)

    local rx_khz_offset=$(get_receiver_khz_offset_list_from_name ${receiver_name})    ### used by wsprd
    wd_logger 2 "Setup rx_khz_offset=${rx_khz_offset}"

    ### Store the signal level logs under the ~/wsprdaemon/signal_levels.d/... directory where it won't be lost due to a reboot or power cycle.
    local signal_levels_log_file 
    setup_signal_levels_log_file  signal_levels_log_file ${receiver_name} ${receiver_band} 
    wd_logger 1 "Log signals to '${signal_levels_log_file}'"
    
    ### 4he noise lines created at the end of each wspr cycle can be queued immediately here for upload to logs.wsprdemon.org
    local wsprdaemon_noise_queue_directory
    get_wsprdaemon_noise_queue_directory  wsprdaemon_noise_queue_directory ${receiver_name} ${receiver_band}
    local ret_code
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't get noise file queue directory 'get_wsprdaemon_noise_queue_directory  wsprdaemon_noise_queue_directory ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 1 "Queuing wsprdaemon noise files in ${wsprdaemon_noise_queue_directory}"

    local rms_nl_adjust
    local fft_nl_adjust
    calculate_nl_adjustments  rms_nl_adjust fft_nl_adjust ${receiver_band}
    wd_logger 1 "Calculated rms_nl_adjust=${rms_nl_adjust} and fft_nl_adjust=${fft_nl_adjust}"

    wd_logger 1 "Starting to search for raw or wav files from '${receiver_name}' tuned to WSPRBAND '${receiver_band}'"
    local decoded_spots=0        ### Maintain a running count of the total number of spots_decoded
    local old_wsprd_decoded_spots=0   ### If we are comparing the new wsprd against the old wsprd, then this will count how many were decoded by the old wsprd

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})
    cd ${recording_dir}
    local old_kiwi_ov_lines=0

    rm -f *.raw *.wav*
    shopt -s nullglob
    while [[  -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; do    ### Keep decoding as long as there is at least one posting_daemon client
        wd_logger 2 "Asking for a list of MODE:WAVE_FILE... with: 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'"
        local mode_seconds_files=""           ### This string will contain 0 or more space-seperated SECONDS:FILENAME_0[,FILENAME_1...] fields 
        get_wav_file_list mode_seconds_files  ${receiver_name} ${receiver_band} ${receiver_modes}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "Error ${ret_code} returned by 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'. 'sleep 1' and retry"
            sleep 1
            continue
        fi
        local -a mode_wav_file_list=(${mode_seconds_files})        ### I tried to pass the name of this array to get_wav_file_list(), but I couldn't get 'eval...' to populate that array
        wd_logger 1 "The call 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}' returned lists: '${mode_wav_file_list[*]}'"


        local returned_files
        for returned_files in ${mode_wav_file_list[@]}; do
            local returned_seconds=${returned_files%:*}
            local returned_minutes=$(( returned_seconds / 60 ))
            local comma_seperated_files=${returned_files#*:}
            local wav_files=${comma_seperated_files//,/ }
            local wav_file_list=( ${wav_files} )
            local wav_time_list=()                         ### I couldn't get this to work:  $( IFS=$'\n'; cut -c 12-13 <<< "${wav_file_list[@]}") )

            wd_logger 1 "For second ${returned_seconds} seconds == ${returned_minutes} minutes got list of ${#wav_file_list[*]} files '${wav_files}'"

            ### This is a block of diagnostic code 
            local found_all_files="yes"
            local index
            for (( index=0; index < ${#wav_file_list[@]}; ++index )); do
                local file_to_test=${wav_file_list[${index}]}
                 wav_time_list+=( ${file_to_test:11:2} )
                if ! [[ -f ${file_to_test} ]]; then
                    wd_logger 1 "ERROR: minute ${wav_time_list[${index}]} file ${file_to_test} from wav_file_list[${index}] does not exist"
                    found_all_files="no"
                fi
            done
            if [[ ${found_all_files} == "no" ]]; then
               wd_logger 1 "ERROR: one or more wav files returned by get_wav_file_list are missing, so skip processing minute ${returned_minutes} wav files"
               continue
            fi

            local wd_string="${wav_time_list[*]}"
            wd_logger 1 "For WSPR packets of length ${returned_seconds} seconds for minutes ${wd_string}, got list of files ${comma_seperated_files}"
            ### Enf of diagnostic code

            local wav_file_freq_hz=${wav_file_list[0]#*_}   ### Remove the year/date/time
            wav_file_freq_hz=${wav_file_freq_hz%_*}      ### Remove the _usb.wav

            local processed_wav_files="no"
            local sox_signals_rms_fft_and_overload_info=""                     ### This string will be added on to the end of each spot and will contain:  "rms_noise fft_noise ov_count"
            > decodes_cache.txt             ## Create or truncate to zero length a file which stores the decodes from all modes
            if [[ " ${receiver_modes_list[*]} " =~ " W${returned_minutes} " ]]; then
                wd_logger 1 "Starting WSPR decode of ${returned_seconds} second wav file"

                local decode_dir="W_${returned_seconds}"
                mkdir -p ${decode_dir}

                ### The 'wsprd' cmd requires a single 2/15 wav file, so use 'sox to create one from 2/15 one minute wav files
                local decoder_input_wav_filename="${wav_file_list[0]:2:6}_${wav_file_list[0]:9:4}.wav"
                sox ${wav_file_list[@]} ${decode_dir}/${decoder_input_wav_filename} 

                cd ${decode_dir}

                local start_time=${SECONDS}
                decode_wpsr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt
                local ret_code=$?

                cd - >& /dev/null
                ### Back to recoding directory

                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds. For mode W_${returned_seconds}: 'decode_wpsr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt' => ${ret_code}"
                else
                    if [[ ! -s ${decode_dir}/ALL_WSPR.TXT.new ]]; then
                        wd_logger 1 "wsprd found no spots"
                    else
                        wd_logger 2 "wsprd decoded $(wc -l < ${decode_dir}/ALL_WSPR.TXT.new) spots:\n$(< ${decode_dir}/ALL_WSPR.TXT.new)"
                        awk -v wspr_pkt_minutes=${returned_minutes} '{printf "%s %s\n", $0, wspr_pkt_minutes}' ${decode_dir}/ALL_WSPR.TXT.new  >> decodes_cache.txt   ### Add the wspr pkt length in seconds to each spot line
                    fi

                    ### Output a noise line  which contains 'DATE TIME + three sets of four space-seperated statistics'i followed by the two FFT values followed by the approximate number of overload events recorded by a Kiwi during this WSPR cycle:
                    ###                           Pre Tx                                                        Tx                                                   Post TX
                    ###     'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'        'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'       'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB      RMS_noise C2_noise  New_overload_events'
                    local c2_filename="${decode_dir}/000000_0001.c2" ### -c instructs wsprd to create the C2 format file "000000_0001.c2"
                    if [[ ! -f ${C2_FFT_CMD} ]]; then
                        wd_logger 0 "Can't find the '${C2_FFT_CMD}' script"
                        exit 1
                    fi
                    local c2_fft_nl=$(python3 ${C2_FFT_CMD} ${c2_filename})
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR: 'python3 ${C2_FFT_CMD} ${c2_filename}' => ${ret_code}"
                        c2_fft_nl=0
                    fi
                    local fft_noise_level=$(bc <<< "scale=2;var=${c2_fft_nl};var+=${fft_nl_adjust};(var * 100)/100")
                    wd_logger 1 "fft_noise_level=${fft_noise_level} which is calculated from 'local fft_noise_level=\$(bc <<< 'scale=2;var=${c2_fft_nl};var+=${fft_nl_adjust};var/=1;var')"

                    local sox_rms_noise_level
                    local rms_line
                    get_rms_levels  sox_rms_noise_level rms_line ${decode_dir}/${decoder_input_wav_filename} ${rms_nl_adjust}
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR:  'get_rms_levels  sox_rms_noise_level rms_line ${decode_dir}/${decoder_input_wav_filename} ${rms_nl_adjust}' => ${ret_code}"
                        return 1
                    fi

                    ### If this is a KiwiSDR, then discover the number of 'ADC OV' events recorded since the last cycle
                    local new_kiwi_ov_count
                    if [[ ! -f kiwi_recorder.log ]]; then
                        new_kiwi_ov_count=0
                        wd_logger 1 "Not a KiwiSDR, so there is no overload information"
                    else
                        local current_kiwi_ov_lines=0
                        current_kiwi_ov_lines=$(${GREP_CMD} "^ ADC OV" kiwi_recorder.log | wc -l)
                        if [[ ${current_kiwi_ov_lines} -lt ${old_kiwi_ov_lines} ]]; then
                            ### kiwi_recorder.log probably grew too large and the kiwirecorder.py was restarted 
                            old_kiwi_ov_lines=0
                        fi
                        new_kiwi_ov_count=$(( ${current_kiwi_ov_lines} - ${old_kiwi_ov_lines} ))
                        old_kiwi_ov_lines=${current_kiwi_ov_lines}
                        wd_logger 1 "The KiwiSDR reported ${new_kiwi_ov_count} overload events in this 2 minute cycle"
                    fi
                    sox_signals_rms_fft_and_overload_info="${rms_line} ${fft_noise_level} ${new_kiwi_ov_count}"

                   wd_logger 1 "After $(( SECONDS - start_time )) seconds: For mode W_${returned_seconds}: reporting sox_signals_rms_fft_and_overload_info='${sox_signals_rms_fft_and_overload_info}'"
                fi
                rm ${decode_dir}/${decoder_input_wav_filename}   ### wait until now to delete it so RMS and C2 cacluations wd_logger lines go to logfile in this directory

                processed_wav_files="yes"
            fi
            if [[ " ${receiver_modes_list[*]} " =~ " F${returned_minutes} " ]]; then
                wd_logger 1 "FST4W decode a ${returned_seconds} wav file by running cmd: '${JT9_CMD} --fst4w  -p ${returned_seconds} -f 1500 -F 100 \"${wav_file_list[*]}\" >& jt9_output.txt'"

                local decode_dir="F_${returned_seconds}"
                mkdir -p ${decode_dir}
                ln ${wav_file_list[*]} ${decode_dir}     ### Create links so that jt8 refers to $CWD files
                rm -f ${decode_dir}/decoded.txt
                ### NOTE; wd_logger output will go to log file in that directory
                cd ${decode_dir}
                local start_time=${SECONDS}
                ${JT9_CMD} -p ${returned_seconds} --fst4w  -p ${returned_seconds} -f 1500 -F 100 "${wav_file_list[@]}" >& jt9_output.txt
                local ret_code=$?
                rm ${wav_file_list[@]}   ### Flush the links we just used
                cd - >& /dev/null
                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds: cmd '${JT9_CMD} --fst4w  -p ${returned_seconds} -f 1500 -F 100 '${wav_file_list[*]}' >& jt9_output.txt' => ${ret_code}"
                else
                    if [[ ! -s ${decode_dir}/decoded.txt ]]; then
                        wd_logger 1 "FST4W found no spots after $(( SECONDS - start_time )) seconds"
                    else
                        local spot_date="${wav_file_list[0]:2:6}"
                        local spot_time="${wav_file_list[0]:9:4}"
                        local wspr_pkt_minutes=$(( ${returned_minutes} + 1 ))  ### FST4W packet length in minutes reported to WD are 'packet_minutes + 1', i.e. 2 => 3, 15 => 16
                        if [[ -n "${sox_signals_rms_fft_and_overload_info}" ]]; then
                            ### This wav was processed, so 'wsprd' (and the Kiwi, if it created the wav) gave us rms_noise, fft_noise and ov_count data.  But the mode field must be incremented to mark this as an FST4W spot
                            wd_logger 1 "FST4W noise line '${sox_signals_rms_fft_and_overload_info}' was generated by WSPR code"
                        else
                            ### This wav file was not processed by 'wsprd', so there is no sox signal_level, rms_noise, fft_noise, or ov_count data 
                            sox_signals_rms_fft_and_overload_info="-999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 0"
                        fi
                           
                        awk -v spot_date=${spot_date} -v spot_time=${spot_time} -v wav_file_freq_hz=${wav_file_freq_hz}  -v wspr_pkt_minutes=${wspr_pkt_minutes} \
                                 '{printf "%6s %4s %3d %s %s %s 0 0 0 0 0 0 0 0 0 %s\n", spot_date, spot_time, $3, $4, (wav_file_freq_hz + $5) / 1000000, substr($0, 32, 32), wspr_pkt_minutes}' \
                                         ${decode_dir}/decoded.txt > ${decode_dir}/fst4w_spots.txt
                        wd_logger 1 "FST4W found spots after $(( SECONDS - start_time )) seconds:\n$( < ${decode_dir}/decoded.txt)\nconverted to uploadable lines:\n$( < ${decode_dir}/fst4w_spots.txt )"
                        cat ${decode_dir}/fst4w_spots.txt >> decodes_cache.txt
                    fi
                fi
                processed_wav_files="yes"
            fi
            if [[ ${processed_wav_files} == "yes" ]]; then 
                wd_logger 1 "Processed files '${wav_files}' for WSPR packet of length ${returned_seconds} seconds"
            else
                wd_logger 1 "ERROR: created a wav file of ${returned_seconds}, but the conf file didn't specify a mode for that length"
            fi
            ### Record the 12 signal levels + rms_noise + fft_noise + new_overloads to the ../signal_levels/...csv log files
            local wspr_decode_capture_date=${wav_file_list[0]/T*}
                  wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
            local wspr_decode_capture_time=${wav_file_list[0]#*T}
                  wspr_decode_capture_time=${wspr_decode_capture_time/Z*}
                  wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
            local wspr_decode_capture_freq_hz=${wav_file_list[0]#*_}
                  wspr_decode_capture_freq_hz=$( bc <<< "${wspr_decode_capture_freq_hz/_*} + (${rx_khz_offset} * 1000)" )

            ### Log the noise for the noise_plot which generates the graphs, and create a time-stamped file with all the noise data for upload to wsprdaemon.org
            queue_noise_signal_levels_to_wsprdeamon  ${wspr_decode_capture_date} ${wspr_decode_capture_time} "${sox_signals_rms_fft_and_overload_info}" ${wspr_decode_capture_freq_hz} ${signal_levels_log_file} ${wsprdaemon_noise_queue_directory}

            ### Record the spots in decodes_cache.txt to wsprnet.org
            ### Record the spots in decodes_cache.txt plus the sox_signals_rms_fft_and_overload_info to wsprnet.org
            ### The start time and frequency of the spot lines will be extracted from the first wav file of the wav file list
            create_enhanced_spots_file_and_queue_to_posting_daemon   decodes_cache.txt ${wspr_decode_capture_date} ${wspr_decode_capture_time} ${sox_rms_noise_level} ${fft_noise_level} ${new_kiwi_ov_count} ${receiver_call} ${receiver_grid}
        done
        sleep 1
    done
}

declare DECODING_DAEMON_PID_FILE=decoding_daemon.pid
declare DECODING_DAEMON_LOG_FILE=decoding_daemon.log
function spawn_decoding_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    local receiver_modes=$3
    wd_logger 2 "Starting with args  '${receiver_name},${receiver_band},${receiver_modes}'"
    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})

    mkdir -p ${recording_dir}/${DECODING_CLIENTS_SUBDIR}     ### The posting_daemon() should have created this already
    cd ${recording_dir}
    local decoding_pid
    if [[ -f ${DECODING_DAEMON_PID_FILE} ]] ; then
        local decoding_pid=$(< ${DECODING_DAEMON_PID_FILE})
        if ps ${decoding_pid} > /dev/null ; then
            wd_logger 2 "A decode job with pid ${decoding_pid} is already running, so nothing to do"
            return 0
        else
            wd_logger 1 "Found dead decode job"
            rm ${DECODING_DAEMON_PID_FILE}
        fi
    fi
    wd_logger 1 "Spawning decode daemon in $PWD"
    WD_LOGFILE=${DECODING_DAEMON_LOG_FILE}  decoding_daemon ${receiver_name} ${receiver_band} ${receiver_modes} &
    echo $! > ${DECODING_DAEMON_PID_FILE}
    cd - > /dev/null
    wd_logger 1 "Finished.  Spawned new decode  job '${receiver_name},${receiver_band},${receiver_modes}' with PID '$!'"
    return 0
}

function kill_decoding_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    wd_logger 2 "Starting with args  '${receiver_name},${receiver_band},${receiver_modes}'"
    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})

    if [[ ! -d ${recording_dir} ]]; then
        wd_logger 1 "ERROR: ${recording_dir} for '${receiver_name},${receiver_band},${receiver_modes}' does not exist"
        return 1
    fi
    cd ${recording_dir}
    if [[ ! -s ${DECODING_DAEMON_PID_FILE} ]] ; then
        wd_logger 1 "ERROR: Decoding pid file '${DECODING_DAEMON_PID_FILE} for '${receiver_name},${receiver_band},${receiver_modes}' does not exist or is empty"
        cd - > /dev/null
        return 2
    fi
    local decoding_pid=$( < ${DECODING_DAEMON_PID_FILE} )
    cd - > /dev/null

    kill_and_wait_for_death  ${decoding_pid}
    local ret_code=$?

    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'kill ${decoding_pid} => ${ret_code}"
        return 3
    fi
    wd_logger 1 "Killed decoding_daemon with pid ${decoding_pid}"
}

###
function get_decoding_status() {
    local get_decoding_status_receiver_name=$1
    local get_decoding_status_receiver_band=$2
    local get_decoding_status_receiver_decoding_dir=$(get_recording_dir_path ${get_decoding_status_receiver_name} ${get_decoding_status_receiver_band})
    local get_decoding_status_receiver_decoding_pid_file=${get_decoding_status_receiver_decoding_dir}/${DECODING_DAEMON_PID_FILE}

    if [[ ! -d ${get_decoding_status_receiver_decoding_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_decoding_status_receiver_decoding_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_decoding_status_decode_pid=$( < ${get_decoding_status_receiver_decoding_pid_file})
    if ! ps ${get_decoding_status_decode_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid '${get_decoding_status_decode_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_decoding_status_decode_pid}"
    return 0
}

