#!/bin/bash 

############## Decoding ################################################
### For each real receiver/band there is one decode daemon and one recording daemon
### Waits for a new wav file then decodes and posts it to all of the posting client


declare -r DECODING_CLIENTS_SUBDIR="decoding_clients.d"     ### Each decoding daemon will create its own subdir where it will copy YYMMDD_HHMM_wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                            ### Delete the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..
declare FFT_WINDOW_CMD=${WSPRDAEMON_ROOT_DIR}/wav_window.py

declare C2_FFT_ENABLED="yes"          ### If "yes", then use the c2 file produced by wsprd to calculate FFT noise levels
declare C2_FFT_CMD=${WSPRDAEMON_ROOT_DIR}/c2_noise.py

function get_decode_mode_list() {
    local modes_variable_to_return=$1
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
    eval ${modes_variable_to_return}=${temp_receiver_modes}
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

declare WAV_MIN_LEVEL=${WAV_MIN_LEVEL--0.90}
declare WAV_MAX_LEVEL=${WAV_MAX_LEVEL=0.90}

function get_wav_levels() 
{
    local __return_levels_var=$1
    local wav_filename=$2
    local sample_start_sec=$3
    local sample_length_secs=$4
    local rms_adjust=$5

    if [[ ${sample_start_sec} == ${SIGNAL_LEVEL_PRE_TX_SEC} ]]; then
        ### This function is called three times for each wav file.  We only need to check the whole wav file once to determine the min/max values
        ### So execute this check only the first time
        ### To see if the AGC might need to change from its default 60, check to see if any samples in the whole wav  file closely approach the MAX or MIN sample values
        local full_wav_stats=$(sox ${wav_filename} -n stats 2>&1)
        local full_wav_min_level=$(echo "${full_wav_stats}" | awk '/Min level/{print $3}')
        local full_wav_max_level=$(echo "${full_wav_stats}" | awk '/Max level/{print $3}')
        local full_wav_bit_depth=$(echo "${full_wav_stats}" | awk '/Bit-depth/{print $2}')
        local full_wav_len_secs=$(echo "${full_wav_stats}" | awk '/Length/{print $3}')

        wd_logger 1 "In file ${wav_filename} of length=${full_wav_len_secs} seconds and with Bit-depth=${full_wav_bit_depth}: the min/max levels are: min=${full_wav_min_level}, max=${full_wav_max_level}"
    fi

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
    wd_logger 2 "Returning adjusted dB values: '${return_line}'"
    eval ${__return_levels_var}=\"${return_line}\"
    return 0
}

declare WAV_SECOND_RANGE=${WAV_SECOND_RANGE-10}         ### wav files of +/- this number of seconds are deemed OK for wsprd to decode

declare TARGET_RAW_WAV_SECONDS=60
declare MIN_VALID_RAW_WAV_SECONDS=${MIN_VALID_RAW_WAV_SECONDS-$(( ${TARGET_RAW_WAV_SECONDS} - ${WAV_SECOND_RANGE} )) }
declare MAX_VALID_RAW_WAV_SECONDS=${MAX_VALID_RAW_WAV_SECONDS-$(( ${TARGET_RAW_WAV_SECONDS} + ${WAV_SECOND_RANGE} )) }

declare TARGET_WSPR_WAV_SECONDS=120
declare MIN_VALID_WSPR_WAV_SECONDS=${MIN_VALID_WSPR_WAV_SECONDS-$(( ${TARGET_WSPR_WAV_SECONDS} - ${WAV_SECOND_RANGE} )) }
declare MAX_VALID_WSPR_WAV_SECONDS=${MAX_VALID_WSPR_WAV_SECONDS-$(( ${TARGET_WSPR_WAV_SECONDS} + ${WAV_SECOND_RANGE} )) }

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
        wd_logger 1 "ERROR: 'sox ${wav_filename} -n stats' reports invalid wav file length of ${wav_length_secs} seconds. valid min=${min_valid_secs}, valid max=${max_valid_secs}"
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

    if ! is_valid_wav_file ${wav_filename} ${MIN_VALID_WSPR_WAV_SECONDS} ${MAX_VALID_WSPR_WAV_SECONDS} ; then
        local rc=$?
        wd_logger 1 "ERROR: 'valid_wav_file ${wav_filename}' => ${rc}"
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
    local post_rms_value=${output_line_list[11]}                                         # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
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
    wd_logger 2 "Returning rms_value=${return_rms_value} and signal_level_line='${signal_level_line}'"
    return 0
}

function decode_wpsr_wav_file() {
    local wav_file_name=$1
    local wspr_decode_capture_freq_hz=$2
    local rx_khz_offset=$3
    local stdout_file=$4
    local wsprd_cmd_flags="$5"        ### ${WSPRD_CMD_FLAGS}

    wd_logger 1 "Decode file ${wav_file_name} for frequency ${wspr_decode_capture_freq_hz} and send stdout to ${stdout_file}.  rx_khz_offset=${rx_khz_offset}, wsprd_cmd_flags='${wsprd_cmd_flags}'"
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
declare RAW_FILE_FULL_SIZE=1440000                       ### Approximate number of bytes in a full size one minute long raw or wav file

### We use 'soxi' to check the length of the 1 minute long wav files created by kiwirecorder.py in a field with the form HOURS:MINUTES:SECONDS.MILLISECONDS
### Because bash can only do integer comparisons, we strip the ':'s and '.' from that field
### As a result, valid wav files will bein the ranges from  6000 - (${MIN_VALID_RAW_WAV_SECONDS} * 100) to 5999
### or in the range from 10000 to (10000 + ${MIN_VALID_RAW_WAV_SECONDS})
### So this code gets the time duration of the wave file into an integer which has the form HHMMSSUU and thus can be compared by a bash expression
### Because the field rolls over from second 59 to minute 1, There can be no fields which have the values 6000 through 9999
declare WAV_FILE_MIN_HHMMSSUU=$(( ${MIN_VALID_RAW_WAV_SECONDS}  * 100  ))       ### by default this = 55 seconds ==  5500
declare WAV_FILE_MAX_HHMMSSUU=$(( 10000 + ( ${WAV_SECOND_RANGE} * 100) ))       ### by default this = 65 seconds == 10500

### If the wav recording daemon is running, we can calculate how many seconds until it starts to fill the raw file (if 0 length first file) or fills the 2nd raw file.  Sleep until then
function flush_wav_files_older_than()
{
    local reference_file=$1

    if [[ ! -f ${reference_file} ]]; then
        wd_logger 1 "ERROR: can't find expected reference file '${reference_file}"
        return 1
    fi
    wd_logger 1 "Delete any files older than ${reference_file}"

    local olders=0
    local newers=0
    local wav_file
    for wav_file in $(find -name '*wav'); do
        if [[ ${wav_file} -ot ${reference_file} ]]; then
            (( ++olders ))
            wd_logger 1 "Deleting older wav file '${wav_file}'"
            wd_rm ${wav_file}
        elif [[ ${wav_file} -nt ${reference_file} ]]; then
            (( ++newers ))
            wd_logger 1 "ERROR: found  wav wav file '${wav_file}' is newer than ${reference_file}"
        else
            ### 'find' prepends './' to the filenames it returns, so we can't compare flenames.  But if two wav file timestamps in the same directory match each other, then they must be the same wav file
            wd_logger 1 "Found expected reference file ${reference_file}"
        fi
    done
    if [[ ${olders} -gt 0 || ${newers} -gt 0 ]]; then
        wd_logger 1 "Deleted ${olders} older wav files and/or found ${newers} new wav files"
    fi
    return 0
}

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
    wd_logger 1 "'${filename}' stopped growing after ${loop_seconds} seconds"

    local file_start_minute=${filename:11:2}
    local file_start_second=${filename:13:2}
    if [[ ${file_start_second} != "00" ]]; then
        wd_logger 1 "'${filename} starts at second ${file_start_second}, not at the required second '00', so delete this file which should be the first file created after startup"
        flush_wav_files_older_than ${filename}
        wd_rm ${filename}
        return 2
    fi

    ### Previously, I had just checked the size of the wav file to validate the duration of the recording
    ### My guesess of the min and max valid wav file size in bytes were too narrow and useful wav files were being thrown away
    local wav_file_duration_hh_mm_sec_msec=$(soxi ${filename} | awk '/Duration/{print $3}')
    local wav_file_duration_integer=$(sed 's/[\.:]//g' <<< "${wav_file_duration_hh_mm_sec_msec}")

    if [[ 10#${wav_file_duration_integer} -lt ${WAV_FILE_MIN_HHMMSSUU} ]]; then          ### The 10#... forces bash to treat wav_file_duration_integer as a decimal, since its leading zeros would otherwise identify it at an octal number
        wd_logger 1 "The wav file stabilized at invalid too short duration ${wav_file_duration_hh_mm_sec_msec} which almost always occurs at startup. Flush this file since it can't be used as part of a WSPR wav file"
        flush_wav_files_older_than ${filename}
        wd_rm ${filename}
        return 2
    fi
    if [[ 10#${wav_file_duration_integer} -gt ${WAV_FILE_MAX_HHMMSSUU} ]]; then
	### If the wav file has grown to longer than one minute, then it is likely there are two kiwirecorder jobs running 
	### We really need to know the IP address of the Kiwi recording this band, since this freq may be recorded by other other Kiwis in a Merged group
	local this_dir_path_list=( ${PWD//\// } )
        local kiwi_name=${this_dir_path_list[-2]}
	local kiwi_ip_addr=$(get_receiver_ip_from_name ${kiwi_name})
        local kiwi_freq=${filename#*_}
              kiwi_freq=${kiwi_freq::3}
        local ps_output=$(ps aux | grep "${KIWI_RECORD_COMMAND}.*${kiwi_freq}.*${kiwi_ip_addr/:*}" | grep -v grep)
        local kiwirecorder_pids=( $(awk '{print $2}' <<< "${ps_output}" ) )
        if [[ ${#kiwirecorder_pids[@]} -eq 0 ]]; then
            wd_logger 1 "ERROR: wav file stabilized at invalid too long duration ${wav_file_duration_hh_mm_sec_msec}, but can't find any kiwirecorder processes which would be creating it"
        else
            wd_kill ${kiwirecorder_pids[@]}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                 wd_logger 1 "ERROR: 'wd_kill ${kiwirecorder_pids[*]}' => ${rc}"
            fi
            wd_logger 1 "ERROR: wav file stabilized at invalid too long duration ${wav_file_duration_hh_mm_sec_msec}, so there appear to be more than one instance of the KWR running. 'ps' output was:\n${ps_output}\nSo executed 'wd_kill ${kiwirecorder_pids[*]}'"
        fi
        flush_wav_files_older_than ${filename}
        wd_rm ${filename}
        return 3
    fi
    wd_logger 1 "File ${filename} stabilized at size ${new_file_size} after ${loop_seconds} seconds"
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
    local check_file_list=( $2 )

    if [[ ${#check_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Was given an empty file list"
        eval ${__return_clean_files_string_name}=\"\"
        return 0
    fi
    wd_logger 2 "Testing list of raw files: '${check_file_list[*]}'"

    local last_file_minute=-1
    local flush_files="no"
    local test_file_name
    local return_clean_files_string=""

    local raw_file_index=$(( ${#check_file_list[@]} - 1 ))
    while [[ ${raw_file_index} -ge 0 ]]; do
        local test_file_name=${check_file_list[${raw_file_index}]}
        wd_logger 2 "Testing file ${test_file_name}"
        if [[ ${flush_files} == "yes" ]]; then
            wd_logger 1 "ERROR: flushing file ${test_file_name}"
            wd_rm ${test_file_name}
        else
            is_valid_wav_file ${test_file_name} ${MIN_VALID_RAW_WAV_SECONDS} ${MAX_VALID_RAW_WAV_SECONDS}
            local ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "ERROR: found wav file '${test_file_name}' has invalid size.  Flush it"
                rm ${test_file_name}
                flush_files="yes"
            else
                ### Size is valid, see if it is one minute earlier than the previous file
                local test_file_minute=${test_file_name:11:2}
                wd_logger 2 "Checking time fields in valid wav file '${test_file_name}' => test_file_minute=${test_file_minute}, last_file_minute=${last_file_minute}"
                if [[ ${last_file_minute} == "-1" ]]; then
                    wd_logger 2 "First clean file is at minute ${test_file_minute}"
                    last_file_minute=${test_file_minute}
                    return_clean_files_string="${test_file_name}"
                else
                    if [[ 10#${last_file_minute} -eq 0 ]]; then
                         last_file_minute=60
                         wd_logger 1 "Testing for a minute 59 file '${test_file_name}', so changed last_file_minute to ${last_file_minute}"
                    fi
                    local minute_difference=$(( 10#${last_file_minute} - 10#${test_file_minute} ))
                    if [[ ${minute_difference} -eq 1 ]]; then
                        wd_logger 2 "'${test_file_name}' size is OK and it is one minute earlier than the next file in the list"
                        return_clean_files_string="${test_file_name} ${return_clean_files_string}"
                        last_file_minute=${test_file_minute}
                    else
                        wd_logger 1 "ERROR: there is a gap of more than 1 minute between this file '${test_file_name}' and the next file in the list ${check_file_list[ $(( ++${raw_file_index} )) ]}, so flush this file and all earlier files"
                        wd_rm ${test_file_name}
                        flush_files="yes"
                    fi
                fi
            fi
        fi
        wd_logger 2 "Done checking '${test_file_name}' from index ${raw_file_index}"
        (( --raw_file_index ))
    done
    local clean_files_list=( ${return_clean_files_string} )

    wd_logger 1 "Given check_file_list[${#check_file_list[@]}]='${check_file_list[*]}'\nReturning clean_file_list[${#clean_files_list[*]}]='${clean_files_list[*]}'"
    if [[ ${#check_file_list[@]} -ne ${#clean_files_list[*]} ]]; then
        wd_logger 1 "ERROR: cleaned list check_file_list[${#check_file_list[@]}]='${check_file_list[*]}' => clean_file_list[${#clean_files_list[*]}]='${clean_files_list[*]}'"
    fi
    eval ${__return_clean_files_string_name}=\"${return_clean_files_string}\"
    return 0
} 


### Waits for wav files needed to decode one or more of the MODEs have been fully recorded
function get_wav_file_list() {
    local return_variable_name=$1  ### returns a string with a space-separated list each element of which is of the form MODE:first.wav[,second.wav,...]
    local receiver_name=$2         ### Used when we need to start or restart the wav recording daemon
    local receiver_band=$3           
    local receiver_modes=$4
    local     target_modes_list=( ${receiver_modes//:/ } )     ### Argument has form MODE1[:MODE2...] put it in local array
    local -ia target_minutes_list=( $( IFS=$'\n' ; echo "${target_modes_list[*]/?/}" | sort -nu ) )        ### Chop the "W" or "F" from each mode element to get the minutes for each mode  NOTE THE "s which are requried if arithmatic is being done on each element!!!!
    if [[ " ${target_minutes_list[*]} " =~ " 0 " ]] ; then
        ### The configuration validtor verified that jobs which have mode 'W0' specified will have no other modes
        ### In mode W0 we are only goign to run the wsprd decoder in order to get the RMS can C2 noise levels
        wd_logger 1 "Found that mode 'W0' has been specified"
        target_minutes_list=( 2 )
    fi
    local -ia target_seconds_list=( "${target_minutes_list[@]/%/*60}" ) ### Multiply the minutes of each mode by 60 to get the number of seconds of wav files needed to decode that mode  NOTE that both ' and " are needed for this to work
    local oldest_file_needed=${target_seconds_list[-1]}

    wd_logger 1 "Start with args '${return_variable_name} ${receiver_name} ${receiver_band} ${receiver_modes}', then receiver_modes => ${target_modes_list[*]} => target_minutes=( ${target_minutes_list[*]} ) => target_seconds=( ${target_seconds_list[*]} )"
    ### This code requires  that the list of wav files to be generated is in ascending seconds order, i.e "120 300 900 1800)

    if ! spawn_wav_recording_daemon ${receiver_name} ${receiver_band} ; then
        local ret_code=$?
        wd_logger 1 "ERROR: 'spawn_wav_recording_daemon ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi

    local raw_file_list=( $( find -maxdepth 1 \( -name \*.wav -o -name \*.raw \) | sed 's/\.\///' | sort ) ) ### minute-*.raw *_usb.wav)        ### Get list of the one minute long 'raw' wav files being created by the Kiwi (.wav) or SDR ((.raw)
    wd_logger 1 "Found ${#raw_file_list[@]} raw/wav files: '${raw_file_list[*]}'"

    case ${#raw_file_list[@]} in
        0 )
            wd_logger 2 "There are no raw files.  Wait up to 10 seconds for the first file to appear"

            declare WAIT_FOR_FIRST_WAV_SECS=10
            local timeout=0
            while     raw_file_list=( $( find -maxdepth 1 \( -name \*.wav -o -name \*.raw \) | sed 's/\.\///' | sort ) ) \
                   && [[ ${#raw_file_list[@]} -eq 0 ]] \
                   && [[ ${timeout} -lt ${WAIT_FOR_FIRST_WAV_SECS}  ]]; do
                sleep 1
                (( ++timeout ))
            done
            if [[ ${#raw_file_list[@]} -eq 0 ]]; then
                wd_logger 1 "Timeout after ${timeout} seconds while waiting for the first wav file to appear"
            else
                wd_logger 2 "First file appeared after waiting ${timeout} seconds"
            fi
            return 1         ### Signal to  calling function to try again
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
                wd_rm ${raw_file_list[0]}
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
        wd_logger 1 "Check to see if we can create a new ${seconds_in_wspr_pkt} seconds long wav file from ${raw_files_in_wav_file_count} raw files"

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
                wd_logger 1 "Adjusted minute_of_first_raw_sample by 1 minute to ${minute_of_first_raw_sample} which compensates for the fact that sdrTest writes the last bytes of a wav file in the following minute of the first bytes"
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
                local inner_flush_list=( ${wav_raw_pkt_list[@]:0:${flush_count}} )
                if [[ ${#inner_flush_list[*]} -gt 0 ]]; then
                    wd_logger 2 "Flushing ${#inner_flush_list[@]} files '${inner_flush_list[*]}' leaving only ${wav_raw_pkt_list[-1]}"
                    rm ${inner_flush_list[*]}
                else
                    wd_logger 1 "ERROR: wav_raw_pkt_list[] has ${#wav_raw_pkt_list[@]} files, but inner_flush_list[] is empty"
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
         wd_logger 2 "For ${seconds_in_wspr_pkt} packet, remembered that a list for this wav file has been returned to the decoder by creating the zero length file ${wav_list_returned_file}"
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

### Called by the decoding_daemon() to create an enhanced_spot file from the output of ALL_WSPR.TXT
### That enhanced_spot file is then posted to the subdirectory where the posting_daemon will process it (and other enhanced_spot files if this receiver is part of a MERGEd group)

### For future reference, here is the output lines in  ALL_WSPR.TXT taken from the wsjt-x 2.1-2 source code:
# In WSJT-x v 2.2+, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
#    fprintf(fall_wspr,    "%6s    %4s    %3.0f    %5.2f    %11.7f    %-22s            %2d    %5.2f     %2d        %2d     %4d        %2d        %3d        %5u    %5d \n",
#                         date,   time,  snr,     dt,      freq,     message, (int)drift,    sync, ipass+1, blocksize, jitter, decodetype, nhardmin, cycles/81, metric);

declare  FIELD_COUNT_DECODE_LINE_WITH_GRID=18                                              ### wsprd v2.2 adds two fields and we have added the 'upload to wsprnet.org' field, so lines with a GRID will have 17 + 1 + 2 noise level fields.  V3.x added spot_mode to the end of each line
declare  FIELD_COUNT_DECODE_LINE_WITHOUT_GRID=$((FIELD_COUNT_DECODE_LINE_WITH_GRID - 1))   ### Lines without a GRID will have one fewer field

function create_enhanced_spots_file_and_queue_to_posting_daemon () {
    local real_receiver_wspr_spots_file=$1              ### file with the new spot lines found in ALL_WSPR.TXT
    local spot_file_date=$2                             ### These are prepended to the output file name
    local spot_file_time=$3
    local wspr_cycle_rms_noise=$4                       ### The following fields are the same for every spot in the wspr cycle
    local wspr_cycle_fft_noise=$5
    local wspr_cycle_kiwi_overloads_count=$6
    local real_receiver_call_sign=$7                    ### For real receivers, these are taken from the conf file line
    local real_receiver_grid=$8                         ### But for MERGEd receivers, the posting daemon will change them to the call+grid of the MERGEd receiver
    local proxy_upload_this_spot=0    ### This is the last field of the enhanced_spot line. If ${SIGNAL_LEVEL_UPLOAD} == "proxy" AND this is the only spot (or best spot among a MERGEd group), 
                                      ### then the posting daemon will modify this last field to '1' to signal to the upload_server to forward this spot to wsprnet.org
    local cached_spots_file_name="${spot_file_date}_${spot_file_time}_spots.txt"

    wd_logger 2 "Enhance the spot lines from ALL_WSPR_TXT in ${real_receiver_wspr_spots_file} into ${cached_spots_file_name}"
    > ${cached_spots_file_name}         ### truncates or creates a zero length file
    local spot_line
    while read spot_line ; do
        wd_logger 3 "Enhance line '${spot_line}'"
        local spot_line_list=(${spot_line/,/})         
        local spot_line_list_count=${#spot_line_list[@]}
        local spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields                                                                                             ### the order of the first fields in the spot lines created by decoding_daemon()
        read  spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields <<< "${spot_line/,/}"
        local    spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_pkt_mode ### the order of the rest of the fields in the spot lines created by decoding_daemon()
        if [[ ${spot_line_list_count} -eq ${FIELD_COUNT_DECODE_LINE_WITH_GRID} ]]; then
            read spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_pkt_mode <<< "${other_fields}"    ### Most spot lines have a GRID
        elif [[ ${spot_line_list_count} -eq ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
            spot_grid="none"
            read           spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_pkt_mode <<< "${other_fields}"    ### Most spot lines have a GRID
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

        ### Output a space-separated line of enhanced spot data.  The first 14 fields are in the same order but with "none" added when the message field with CALL doesn't include a GRID field
        ### Each of these lines should be uploaded to logs.wsprdaemon.org.  If ${SIGNAL_LEVEL_UPLOAD} == "proxy" AND this is the only spot (or best spot among a MERGEd group), then the posting daemon will modify the last field to signal the upload_server to forward this spot to wsprnet.org
        ### The first row of printed variables are taken from the ALL_WSPR.TXT file lines with the 10th field sync_quality moved to field 3 so the line format is a superset of the lines created by WD 2.10
        ### The second row are the values added  by our 'add_derived' Python line
        ### The third row are values taken from WD's  rms_noise, fft_noise, WD.conf call sign and grid, etc.
        # printf "%6s        %4s            %3.2f               %3d     %5.2f         %12.7f         %-14s        %-6s          %2d           %2d         %4d             %4d              %4d             %4d             %2d              %3d             %3d             %2d               %6.1f                   %6.1f            %4d            %6s                %12s                  %5d     %6.1f      %6.1f     %6.1f      %6.1f   %6.1f     %6.1f     %6.1f    %6.1f               %4d                             %4d\n" \
        # field#:  1           2               10                 3         4              5             6           7            8             9          11              12               13              14              15               16             17               18                  19                      20             21            22                   23                   24        25         26        27         28      29        30       31      32                  33                              34    \
        printf "%6s %4s %3.2f %5.2f %5.2f %12.7f %-14s %-6s %2d %2d %4d %4d %4d %4d %2d %3d %3d %2d %6.1f %6.1f %4d %6s %12s %5d %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %4d %4d\n" \
             ${spot_date} ${spot_time} ${spot_sync_quality} ${spot_snr} ${spot_dt} ${spot_freq} ${spot_call} ${spot_grid} ${spot_pwr} ${spot_drift} ${spot_cycles} ${spot_jitter} ${spot_blocksize} ${spot_metric} ${spot_decodetype} ${spot_ipass} ${spot_nhardmin} ${spot_pkt_mode} ${wspr_cycle_rms_noise} ${wspr_cycle_fft_noise} ${band} ${real_receiver_grid} ${real_receiver_call_sign} ${km} ${rx_az}  ${rx_lat}  ${rx_lon} ${tx_az} ${tx_lat} ${tx_lon} ${v_lat} ${v_lon} ${wspr_cycle_kiwi_overloads_count} ${proxy_upload_this_spot} >> ${cached_spots_file_name}
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: printf \"%6s %4s %3.2f %3d %5.2f %12.7f %-14s %-6s %2d %2d %4d %4d %4d %4d %2d %3d %3d %2d %6.1f %6.1f %4d %6s %12s %5d %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %4d %4d\" \
             '${spot_date}' '${spot_time}' '${spot_sync_quality}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_cycles}' '${spot_jitter}' '${spot_blocksize}' '${spot_metric}' '${spot_decodetype}' \
             '${spot_ipass}' '${spot_nhardmin}' '${spot_pkt_mode}' '${wspr_cycle_rms_noise}' '${wspr_cycle_fft_noise}' '${band}' '${real_receiver_grid}' '${real_receiver_call_sign}' '${km}' '${rx_az}  ${rx_lat}  ${rx_lon}' '${tx_az}' '${tx_lat}' '${tx_lon}' \
             '${v_lat}' '${v_lon}' '${wspr_cycle_kiwi_overloads_count}' '${proxy_upload_this_spot}'   => ${rc}"
        fi

    done < ${real_receiver_wspr_spots_file}

    if [[ ! -s ${cached_spots_file_name} ]]; then
        wd_logger 2 "Found no spots to queue, so queuing zero length spot file"
    else
        wd_logger 2 "Created '${cached_spots_file_name}' of size $(wc -c < ${cached_spots_file_name}):\n$(< ${cached_spots_file_name})"
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
        if [[ -f ${decoding_client_spot_file_name} ]]; then
            wd_logger 1 "ERROR: file ${decoding_client_spot_file_name} already exists, so dropping this new ${cached_spots_file_name}"
        else
            wd_logger 2 "Creating link from ${cached_spots_file_name} to ${decoding_client_spot_file_name} which is monitored by a posting daemon"
            ln ${cached_spots_file_name} ${decoding_client_spot_file_name}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'ln ${cached_spots_file_name} ${decoding_client_spot_file_name}' => ${rc}"
            fi
        fi
    done
    rm ${cached_spots_file_name}    ### The links will persist until all the posting daemons delete them
    wd_logger 2 "Done creating and queuing '${cached_spots_file_name}'"
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
    ### Linux directory names can't have the '/' character in them which is so common in ham callsigns.  So replace all those '/' with '=' characters which (I am pretty sure) are never legal in call signs
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

    local receiver_modes
    get_decode_mode_list  receiver_modes ${receiver_modes_arg} ${receiver_band}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then 
        wd_logger 1 "ERROR: 'get_decode_mode_list receiver_modes ${receiver_modes_arg}' => ${ret_code}"
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
    
    ### The noise lines created at the end of each wspr cycle can be queued immediately here for upload to logs.wsprdemon.org
    local wsprdaemon_noise_queue_directory
    get_wsprdaemon_noise_queue_directory  wsprdaemon_noise_queue_directory ${receiver_name} ${receiver_band}
    local ret_code
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't get noise file queue directory 'get_wsprdaemon_noise_queue_directory  wsprdaemon_noise_queue_directory ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 1 "Queuing wsprdaemon noise files in ${wsprdaemon_noise_queue_directory}"

    ### It is something of a hack to derive it this way, but it avoids adding another function
    local wav_archive_dir
    get_wav_archive_queue_directory  wav_archive_dir ${receiver_name} ${receiver_band}
    local ret_code
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't get wav file queue directory 'get_wav_archive_queue_directory  wav_archive_dir  ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi
    wd_logger 1 "If ARCHIVE_WAV_FILES=\"yes\" is defined in the conf file, then wav files wll be archived to ${wav_archive_dir}"

    local rms_nl_adjust
    local fft_nl_adjust
    calculate_nl_adjustments  rms_nl_adjust fft_nl_adjust ${receiver_band}
    wd_logger 1 "Calculated rms_nl_adjust=${rms_nl_adjust} and fft_nl_adjust=${fft_nl_adjust}"

    wd_logger 1 "Starting to search for raw or wav files from '${receiver_name}' tuned to WSPRBAND '${receiver_band}'"
    local decoded_spots=0             ### Maintain a running count of the total number of spots_decoded
    local old_wsprd_decoded_spots=0   ### If we are comparing the new wsprd against the old wsprd, then this will count how many were decoded by the old wsprd

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})
    cd ${recording_dir}
    local old_kiwi_ov_lines=0

    local my_daemon_pid=$(< ${DECODING_DAEMON_PID_FILE})
    local proc_file=/proc/${my_daemon_pid}/status
    local VmRSS_val=$(awk '/VmRSS/{print $2}' ${proc_file})
    local last_rss_epoch
    wd_logger 1 "At start VmRSS_val=${VmRSS_val} for my PID ${my_daemon_pid} was found in ${PWD}/${DECODING_DAEMON_PID_FILE}"
    if [[ -n "${VM_RSS_LOG_FILENAME-}" ]]; then
        wd_logger 1 "Logging VmRSS_val for my PID ${my_daemon_pid} found in ${PWD}/${DECODING_DAEMON_PID_FILE} and finding VmRSS in ${proc_file} and logging it to ${VM_RSS_LOG_FILENAME-}"
        printf "${WD_TIME_FMT}: %8d\n" -1 ${VmRSS_val} > ${VM_RSS_LOG_FILENAME}
        last_rss_epoch=${EPOCHSECONDS}
    fi

    ### Move declarations of arrays outside the loop
    local mode_wav_file_list=()
    local wav_file_list=()
    local wav_time_list=()

    rm -f *.raw *.wav*
    shopt -s nullglob
    while [[  -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; do    ### Keep decoding as long as there is at least one posting_daemon client
        VmRSS_val=$(awk '/VmRSS/{print $2}' ${proc_file} )
        wd_logger 1 "My PID ${my_daemon_pid} VmRSS_val=${VmRSS_val}"
        if [[ -n "${VM_RSS_LOG_FILENAME-}" && $(( ${EPOCHSECONDS} - ${last_rss_epoch})) -ge 60  ]]; then
            printf "${WD_TIME_FMT}: %8d\n" -1 "${VmRSS_val}" >> ${VM_RSS_LOG_FILENAME}
            wd_logger 1 "Logged VmRSS_val=${VmRSS_val}"
            last_rss_epoch=${EPOCHSECONDS}
        fi
        wd_logger 2 "Asking for a list of MODE:WAVE_FILE... with: 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'"
        local mode_seconds_files=""           ### This string will contain 0 or more space-seperated SECONDS:FILENAME_0[,FILENAME_1...] fields 
        get_wav_file_list mode_seconds_files  ${receiver_name} ${receiver_band} ${receiver_modes}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "Error ${ret_code} returned by 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'. 'sleep 1' and retry"
            sleep 1
            continue
        fi
        mode_wav_file_list=(${mode_seconds_files})        ### I tried to pass the name of this array to get_wav_file_list(), but I couldn't get 'eval...' to populate that array
        wd_logger 1 "The call 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}' returned lists: '${mode_wav_file_list[*]}'"

        local returned_files
        for returned_files in ${mode_wav_file_list[@]}; do
            local returned_seconds=${returned_files%:*}
            local returned_minutes=$(( returned_seconds / 60 ))
            local comma_separated_files=${returned_files#*:}
            local wav_files=${comma_separated_files//,/ }
            wav_file_list=( ${wav_files} )
            wav_time_list=()                         ### I couldn't get this to work:  $( IFS=$'\n'; cut -c 12-13 <<< "${wav_file_list[@]}") )

            wd_logger 1 "For second ${returned_seconds} seconds == ${returned_minutes} minutes got list of ${#wav_file_list[*]} files '${wav_files}'"

            if [[ "${CHECK_WAV_FILES-yes}" == "yes" ]]; then
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
            fi

            local wd_string="${wav_time_list[*]}"
            wd_logger 1 "For WSPR packets of length ${returned_seconds} seconds for minutes ${wd_string}, got list of files ${comma_separated_files}"
            ### Enf of diagnostic code

            local wav_file_freq_hz=${wav_file_list[0]#*_}   ### Remove the year/date/time
            wav_file_freq_hz=${wav_file_freq_hz%_*}         ### Remove the _usb.wav

            local sox_rms_noise_level=""
            local fft_noise_level=""
            local new_kiwi_ov_count=0
            local rms_line=""
            local processed_wav_files="no"
            local sox_signals_rms_fft_and_overload_info=""  ### This string will be added on to the end of each spot and will contain:  "rms_noise fft_noise ov_count"
            ### The 'wsprd' and 'jt9' commands require a single wav file, so use 'sox to create one from the list of one minute wav files
            local decoder_input_wav_filename="${wav_file_list[0]:2:6}_${wav_file_list[0]:9:4}.wav"
            local decoder_input_wav_filepath=$(realpath ${decoder_input_wav_filename})

            sox ${wav_file_list[@]} ${decoder_input_wav_filepath}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'sox ${wav_file_list[@]} ${decoder_input_wav_filepath}' => ${rc} (probably out of file space)"
                if [[ -f ${decoder_input_wav_filepath} ]]; then
                    wd_rm ${decoder_input_wav_filepath}
                fi
                sleep 1
                continue
            fi
            wd_logger 1 "sox created ${decoder_input_wav_filepath} from ${#wav_file_list[@]} one minute wav files"
            wd_logger 2 "'soxi ${decoder_input_wav_filepath} ${wav_file_list[*]}':\n$(soxi ${decoder_input_wav_filepath} ${wav_file_list[@]})"

           > decodes_cache.txt                             ### Create or truncate to zero length a file which stores the decodes from all modes
            if [[ ${#receiver_modes_list[@]} -eq 1 && ${receiver_modes_list[0]} == "W0" || " ${receiver_modes_list[*]} " =~ " W${returned_minutes} " ]]; then
                wd_logger 1 "Starting WSPR decode of ${returned_seconds} second wav file"

                local decode_dir="W_${returned_seconds}"
                mkdir -p ${decode_dir}

                ###  For mode "W0":  wsprd -o 0 -q -s -H <everything else>
                ### -o - use a ZERO as the number
                ### -q - "quick" decoding
                ### -s - single-pass
                ### - H - Do not use the hash table
                declare DEFAULT_WO_WSPSRD_CMD_FLAGS="-o 0 -q -s -H"

                local wsprd_flags=${WSPRD_CMD_FLAGS}
                if [[ ${#receiver_modes_list[@]} -eq 1 && ${receiver_modes_list[0]} == "W0" ]]; then
                    wsprd_flags="${WO_WSPSRD_CMD_FLAGS-${DEFAULT_WO_WSPSRD_CMD_FLAGS}}"
                    wd_logger 1 "Decoding mode W0, so run 'wsprd ${wsprd_flags}"
                fi

                cd ${decode_dir}

                ### wsprd get the spotline date/time from the filename, so we can't pass the full filepath to wsprd
                ln ${decoder_input_wav_filepath} ${decoder_input_wav_filename} 

                local start_time=${SECONDS}
                decode_wpsr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt "${wsprd_flags}"
                local ret_code=$?

                rm  ${decoder_input_wav_filename}
                cd - >& /dev/null
                ### Back to recording directory

                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds. For mode W_${returned_seconds}: 'decode_wpsr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt' => ${ret_code}"
                else
                    if [[ ! -s ${decode_dir}/ALL_WSPR.TXT.new ]]; then
                        wd_logger 1 "wsprd found no spots"
                    else
                        wd_logger 1 "wsprd decoded $(wc -l < ${decode_dir}/ALL_WSPR.TXT.new) spots:\n$(< ${decode_dir}/ALL_WSPR.TXT.new)"
                        awk -v pkt_mode=${returned_minutes} '{printf "%s %s\n", $0, pkt_mode}' ${decode_dir}/ALL_WSPR.TXT.new  >> decodes_cache.txt                       ### Add the wspr pkt mode (== 2 or 15 minutes) to each ALL_WSPR.TXT spot line
                    fi

                    ### Output a noise line  which contains 'DATE TIME + three sets of four space-separated statistics'i followed by the two FFT values followed by the approximate number of overload events recorded by a Kiwi during this WSPR cycle:
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
                    fft_noise_level=$(bc <<< "scale=2;var=${c2_fft_nl};var+=${fft_nl_adjust};(var * 100)/100")
                    wd_logger 2 "fft_noise_level=${fft_noise_level} which is calculated from 'local fft_noise_level=\$(bc <<< 'scale=2;var=${c2_fft_nl};var+=${fft_nl_adjust};var/=1;var')"

                    get_rms_levels  sox_rms_noise_level rms_line ${decoder_input_wav_filename} ${rms_nl_adjust}
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR:  'get_rms_levels  sox_rms_noise_level rms_line ${decoder_input_wav_filename} ${rms_nl_adjust}' => ${ret_code}"
                        return 1
                    fi

                    ### If this is a KiwiSDR, then discover the number of 'ADC OV' events recorded since the last cycle
                    if [[ ! -f kiwi_recorder.log ]]; then
                        new_kiwi_ov_count=0
                        wd_logger 1 "Not a KiwiSDR, so there is no overload information"
                    else
                        local rc
                        get_kiwirecorder_ov_count  current_kiwi_ov_lines ${receiver_name}           ### here I'm reusing current_kiwi_ov_lines since it also equals the number of OV events since the kiwi started
                        rc=$?
                        if [[ ${rc} -eq 0 ]]; then
                            wd_logger 1 "'get_current_ov_count  current_kiwi_ov_lines ${receiver_name}' -> current_kiwi_ov_lines=${current_kiwi_ov_lines}"
                            new_kiwi_ov_count=$(( ${current_kiwi_ov_lines} - ${old_kiwi_ov_lines} ))
                            old_kiwi_ov_lines=${current_kiwi_ov_lines}
                        else
                            wd_logger 1 "ERROR: 'get_current_ov_count  current_ov_count ${receiver_name}' => ${rc}, so trying old OV count method"
                            local current_kiwi_ov_lines=0
                            current_kiwi_ov_lines=$(${GREP_CMD} "^ ADC OV" kiwi_recorder.log | wc -l)
                            if [[ ${current_kiwi_ov_lines} -lt ${old_kiwi_ov_lines} ]]; then
                                ### kiwi_recorder.log probably grew too large and the kiwirecorder.py was restarted 
                                old_kiwi_ov_lines=0
                            fi
                        fi
                        new_kiwi_ov_count=$(( ${current_kiwi_ov_lines} - ${old_kiwi_ov_lines} ))
                        old_kiwi_ov_lines=${current_kiwi_ov_lines}
                        wd_logger 1 "The KiwiSDR reported ${new_kiwi_ov_count} overload events in this 2 minute cycle"
                    fi
                    sox_signals_rms_fft_and_overload_info="${rms_line} ${fft_noise_level} ${new_kiwi_ov_count}"

                   wd_logger 1 "After $(( SECONDS - start_time )) seconds: For mode W_${returned_seconds}: reporting sox_signals_rms_fft_and_overload_info='${sox_signals_rms_fft_and_overload_info}'"
                fi

                processed_wav_files="yes"
            fi

            if [[ " ${receiver_modes_list[*]} " =~ " F${returned_minutes} " ]]; then
                ### Check for FST4W spots in the wav file

                local decode_dir="F_${returned_seconds}"
                local decode_dir_path=$(realpath ${decode_dir})
                mkdir -p ${decode_dir_path}
                rm -f ${decode_dir_path}/decoded.txt
                wd_logger 1 "FST4W decode a ${returned_seconds} second wav file by running cmd: '${JT9_CMD} -a ${decode_dir_path} --fst4w  -p ${returned_seconds} -f 1500 -F 100 ${decoder_input_wav_filename}  >& jt9_output.txt'"

                ### Don't linger in that F_xxx subdir, since wd_logger ... will get logged there
                cd ${decode_dir_path}
                touch plotspec decdata        ### Instructs jt9 to output spectral width information to jt9_output.txt and append extended resolution spot lines to fst4_decodes.dat 
                local old_fst4_decodes_dat_last_spot
                if [[ ! -s fst4_decodes.dat ]] ; then
                    wd_logger 1 "Thre is no file 'fst4_decodes.dat', so there have been no previous sucessful FST4W decodes"
                    old_fst4_decodes_dat_last_spot=""
                else
                    old_fst4_decodes_dat_last_spot=$(tail -n 1 fst4_decodes.dat)
                    wd_logger 1 "Found last spot previously decoded which is found in file 'fst4_decodes.dat':\n${old_fst4_decodes_dat_last_spot}"
                fi

                local rc
                ln ${decoder_input_wav_filepath} ${decoder_input_wav_filename}
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'ln ${decoder_input_wav_filepath} ${decoder_input_wav_filename}' => ${rc}"   ### This will be logged in the './F_xxx' sub directory
                fi
                local start_time=${SECONDS}
                ${JT9_CMD} -a ${decode_dir_path} -p ${returned_seconds} --fst4w  -p ${returned_seconds} -f 1500 -F 100 ${decoder_input_wav_filename} >& jt9_output.txt
                local ret_code=$?
                rm ${decoder_input_wav_filename}
                cd - >& /dev/null
                ### Out of the subdir

                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds: cmd '${JT9_CMD} -a ${decode_dir_path} --fst4w  -p ${returned_seconds} -f 1500 -F 100 '${decoder_input_wav_filename}' >& jt9_output.txt' => ${ret_code}"
                else
                    ### jt9 succeeded 
                    if [[ ! -s ${decode_dir_path}/decoded.txt ]]; then
                        wd_logger 1 "FST4W found no spots after $(( SECONDS - start_time )) seconds"
                    else
                        ### jt9 found spots
                        local spot_date="${decoder_input_wav_filename:0:6}"
                        local spot_time="${decoder_input_wav_filename:7:4}"
                        local pkt_mode=$(( ${returned_minutes} + 1 ))  ### FST4W packet length in minutes reported to WD are 'packet_minutes + 1', i.e. 3 => FST4W-120,  6 => FST4W-300, ...
                        if [[ -n "${sox_signals_rms_fft_and_overload_info}" ]]; then
                            ### This wav was processed by wsprd, so 'wsprd' created rms_noise, fft_noise and ov_count data.  But the mode field must be incremented to mark this as an FST4W spot
                            wd_logger 1 "FST4W spot lines can include the noise level information '${sox_signals_rms_fft_and_overload_info}' which was just generated by wsprd"
                        else
                            ### This wav file was not processed by 'wsprd', so there is no sox signal_level, rms_noise, fft_noise, or ov_count data 
                            wd_logger 1 "FST4W spot lines have no noise level information from a wsprd decode, so use filler noise level values of -999.0"
                            sox_signals_rms_fft_and_overload_info="-999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 -999.0 0"
                            sox_rms_noise_level="-999.0"
                            fft_noise_level="-999.0"
                        fi

                        ### Get new high resolution spot lines appended by jt9 to fst4_decodes.dat, a log file like ALL_WSPR.TXT where jt9 appends spot lines
                        > ${decode_dir_path}/high_res_fst4w_spots.txt          ### create or truncate 
                        if [[ ! -s ${decode_dir_path}/fst4_decodes.dat ]]; then
                            wd_logger  1 "ERROR: jt9 found the spots written to file '${decode_dir_path}/decoded.txt', but can't find the file or spot lines in the file '${decode_dir_path}/fst4_decodes.dat'"
                        else
                            wd_logger  2 "Extracting new FST4W spots expected to be in '${decode_dir_path}/fst4_decodes.dat'"
                            if [[ -z "${old_fst4_decodes_dat_last_spot}" ]]; then
                                wd_logger 1 "There were no old FST4W spots, so all spots in ${decode_dir_path}/fst4_decodes.dat are new spots:\n$(<${decode_dir_path}/fst4_decodes.dat)"
                                cp -p ${decode_dir_path}/fst4_decodes.dat ${decode_dir_path}/new_fst4w_decodes.dat 
                            else
                                grep -A 100000 "${old_fst4_decodes_dat_last_spot}" ${decode_dir_path}/fst4_decodes.dat > ${decode_dir_path}/last_and_new_fst4w_decodes.dat
                                local rc=$?
                                if [[ ${rc} -ne 0 ]]; then
                                    wd_logger 1 "ERROR: 'grep -A 100000 \"${old_fst4_decodes_dat_last_spot}\" ${decode_dir_path}/fst4_decodes.dat > ${decode_dir_path}/last_and_new_fst4w_decodes.dat' => ${rc}"
                                else
                                    grep -v "${old_fst4_decodes_dat_last_spot}" ${decode_dir_path}/last_and_new_fst4w_decodes.dat > ${decode_dir_path}/new_fst4w_decodes.dat
                                    rc=$?
                                    if [[ ${rc} -ne 0 ]]; then
                                        wd_logger 1 "ERROR: can't find expected new FST4W high res spot lines in ${decode_dir_path}/last_and_new_fst4w_decodes.dat"
                                    else
                                        wd_logger 1 "Found these newly decoded FST4W high res spot lines:\n$(< ${decode_dir_path}/new_fst4w_decodes.dat)"
                                    fi
                                fi
                            fi
                            ### Flush useless '<...>' spots with those unrefereenced hashed tx calls from the  low resolution spots found in ${decode_dir_path}/decoded.txt
                            if  grep -q -F "<...>" ${decode_dir_path}/new_fst4w_decodes.dat ; then
                                wd_logger  1 "Found one or more  '<...>' FST4W spots in the high resolution spots file.  Filtering them out"
                                grep -v  -F "<...>" ${decode_dir_path}/new_fst4w_decodes.dat > ${decode_dir_path}/decoded.tmp
                                mv ${decode_dir_path}/decoded.tmp ${decode_dir_path}/new_fst4w_decodes.dat
                            fi
                            if [[ ! -s ${decode_dir_path}/new_fst4w_decodes.dat ]]; then
                                wd_logger 1 "Found no new FST4W high res spots after filtering out '<...>' spots:\n$(< ${decode_dir_path}/new_fst4w_decodes.dat)"
                            fi
                            ### Fields in the FST4W fst4-decodes.dat file as of October 2022 in v2.5.4
                            ### Thanks to Gwyn G3ZIL
                            ###
                            ### field #     name        description                                 map to wd_spots_s field
                            ###
                            ### 1           nutc        UTC time only, no date, 00hhss
                            ### 2           icand       Spectral peaks that may be spots are
                            ###                         given a 'candidate' number on a first
                            ###                         pass for subsequent attempt at
                            ###                         decoding. Vital for getting data internal
                            ###                         to the program, but no value externally.
                            ### 3           itry        Internal, use only, mostly 1
                            ### 4           nsyncoh     Internal, set to 8, never changed
                            ### 5           iaptype     Internal, set to 0 for FST4W other
                            ###                         values for FST4
                            ### 6           ijitter     Internal, if ntype=1 always 0
                            ### 7           npct        Noise blanker %, FST4 only
                            ### 8           ntype       Values 1,2 seen, not clear what this is
                            ### 9           Keff        Internal, set to 66
                            ### 10          nsync_qual  Sync quality                                sync_quality
                            ### 11          nharderrors Number of hard errors when decode           nhardmin
                            ### 12          dmin        Internal, set to 0 not clear if it changes
                            ### 13          nhp         Internal, 'hard errors with respect to
                            ###                         N=1 soft symbols'
                            ### 14          hd          Internal, weighted distance with
                            ###                         respect to N=1 symbols
                            ### 15          sync        Internal, sync power for a complex
                            ###                         downsampled FST4W signal
                            ### 16          xsnr        SNR with 0.1 dB resolution                  SNR
                            ### 17          xdt         time difference                             dt
                            ### 18          fsig        Baseband spot frequency                     freq after conversion
                            ### 19          w50         Spectral width at 50% level (Hz)            metric (repurposed)
                            ### 20          trim(msg)   tx_call                                     tx_call
                            ### 21                      tx_grid                                     tx_grid
                            ### 22                      tx_dBm                                      tx_dBm

                            ### Format the 
                            ### We want to map  the 21 or 22 fields in the /new_fst4w_decodes.dat file into lines with the format of wsprd's out
                            ### This is the format of WSJT-x v 2.2+ spot lines in ALL_WSPR.TXT
                            ###  fprintf(fall_wspr,    "%6s    %4s    %3.0f    %5.2f    %11.7f    %-22s            %2d    %5.2f     %2d        %2d     %4d        %2d        %3d        %5u    %5d \n",
                            ###                         date,   time,  snr,     dt,      freq,     message, (int)drift,    sync, ipass+1, blocksize, jitter, decodetype, nhardmin, cycles/81, metric);
                            awk -v spot_date=${spot_date} -v spot_time=${spot_time} -v wav_file_freq_hz=${wav_file_freq_hz}  -v pkt_mode=${pkt_mode} \
                                    'NF == 21 || NF == 22 {printf "%6s %4s %5.1f %5.2f %12.7f %-22s 0 %2d 0 0 0 0 %2d 0 %5d %s\n", spot_date, spot_time, $16, $17, (wav_file_freq_hz + $18) / 1000000, $20 " " $21 " " $22, $10, $11, ($19 * 1000), pkt_mode}' \
                                    ${decode_dir_path}/new_fst4w_decodes.dat > ${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt
                            if [[ -s ${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt ]]; then
                                wd_logger  1 "Reformatted high resolution FST4W type 1 and/or type 3 spots to:\n$(<${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt)"
                            else
                                wd_logger  1 "ERROR: Failed to reformat these high resolution FST4W spots:\n$(<${decode_dir_path}/new_fst4w_decodes.dat)"
                            fi
                            cat ${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt > ${decode_dir_path}/high_res_fst4w_spots.txt       ### maybe add type 2 spots when/if they are needed
                        fi
                        truncate_file ${decode_dir_path}/fst4_decodes.dat  100000        ### Limit the file which caches old decodes to 100 KBytes

                        ### Format the low resolution FST4W spot lines (if any) for upload to wsprnet and wsprdaemon
                        > ${decode_dir_path}/low_res_fst4w_spots.txt        ### create or trucate 
                        if [[ ! -s ${decode_dir_path}/jt9_output.txt ]]; then
                            wd_logger  1 "Found no low res FST4W spot lines in '${decode_dir_path}/jt9_output.txt'"
                        else
                            ### Flush useless '<...>' spots with those unrefereenced hashed tx calls from the  low resolution spots found in ${decode_dir_path}/decoded.txt
                            if  grep -v -F "<...>" ${decode_dir_path}/jt9_output.txt > ${decode_dir_path}/decoded.tmp; then
                                wd_logger  1 "Found some low res FST4W spot lines in '${decode_dir_path}/jt9_output.txt':\n$(< ${decode_dir_path}/jt9_output.txt)"
                                mv ${decode_dir_path}/decoded.tmp ${decode_dir_path}/jt9_output.txt
                            fi
                            if [[ ! -s ${decode_dir_path}/jt9_output.txt ]]; then
                                wd_logger  1 "After filtering out '<...>' spot lines, found no low res FST4W spot lines in '${decode_dir_path}/jt9_output.txt'"
                            else
                                wd_logger  1 "Formatting $(wc -l < ${decode_dir_path}/jt9_output.txt) spots found in '${decode_dir_path}/jt9_output.txt'"
                                 # In WSJT-x v 2.2+, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
                                 #    fprintf(fall_wspr,    "%6s    %4s    %3.0f    %5.2f    %11.7f    %-22s            %2d    %5.2f     %2d        %2d     %4d        %2d        %3d        %5u    %5d \n",
                                 #                         date,   time,  snr,     dt,      freq,     message, (int)drift,    sync, ipass+1, blocksize, jitter, decodetype, nhardmin, cycles/81, metric);
                                 # jt9 outputs spots to decoded.txt    in this format:
                                 #          $1    $2   $3  $4     $5,  $6,  ...
                                 #         HHMM,  ?,  SNR, dt, freq_hz, ?  call/maiden/pwr      "FST"
                                 # jt9 outputs spots of jt9_output.txt in this format:
                                 #          $1    $2  $3    $4      $5   ...                     $NF
                                 #         HHMM, SNR, dt, freq_hz, "`", call/maiden/pwr          spectral_width in hz (.e.g: .0123)
                                awk -v spot_date=${spot_date} -v spot_time=${spot_time} -v wav_file_freq_hz=${wav_file_freq_hz}  -v pkt_mode=${pkt_mode} \
                                    'NF == 9 {printf "%6s %4s %3d %s %11.6f %s 0 0 0 0 0 0 0 0 %5d %s\n", spot_date, spot_time, $2, $3, (wav_file_freq_hz + $4) / 1000000, substr($0, 23, 32), ($NF * 1000), pkt_mode}' \
                                         ${decode_dir_path}/jt9_output.txt > ${decode_dir_path}/fst4w_type1_and_type3_spots.txt
                                if [[ -s ${decode_dir_path}/fst4w_type1_and_type3_spots.txt ]]; then
                                    wd_logger  2 "Found FST4W type 1 and/or type 3 spots:\njt9's stdout:\n$(< ${decode_dir_path}/jt9_output.txt)\nFormated for upload:\n$(<${decode_dir_path}/fst4w_type1_and_type3_spots.txt)"
                                fi
                                > ${decode_dir_path}/fst4w_type2_spots.txt
                                awk -v spot_date=${spot_date} -v spot_time=${spot_time} -v wav_file_freq_hz=${wav_file_freq_hz}  -v pkt_mode=${pkt_mode} \
                                    'NF == 8  {printf "%6s %4s %3d %s %11.6f %s 0 0 0 0 0 0 0 0 %5d %s\n", spot_date, spot_time, $2, $3, (wav_file_freq_hz + $4) / 1000000, substr($0, 23, 32), ($NF * 1000),pkt_mode}' \
                                         ${decode_dir_path}/jt9_output.txt > ${decode_dir_path}/fst4w_type2_spots.txt
                                if [[ -s ${decode_dir_path}/fst4w_type2_spots.txt ]]; then
                                    wd_logger  1 "Found FST4W type 2 spots:\n$(<${decode_dir_path}/fst4w_type2_spots.txt)"
                                fi
                                > ${decode_dir_path}/fst4w_bad_spots.txt
                                awk -v spot_date=${spot_date} -v spot_time=${spot_time} -v wav_file_freq_hz=${wav_file_freq_hz}  -v pkt_mode=${pkt_mode} \
                                     'NF != 8  && NF != 9 && NF != 4 {printf "%6s %4s %3d %s %11.6f %s 0 0 0 0 0 0 0 0 %5d %s\n", spot_date, spot_time, $3, $4, (wav_file_freq_hz + $5) / 1000000, substr($0, 23, 32), ($NF * 1000), pkt_mode}' \
                                         ${decode_dir_path}/jt9_output.txt > ${decode_dir_path}/fst4w_bad_spots.txt
                                if [[ -s ${decode_dir_path}/fst4w_bad_spots.txt ]]; then
                                    wd_logger  1 "ERROR: Dumping bad FST4W spots (i.e. NF != 9 or 10):\n$(<${decode_dir_path}/fst4w_bad_spots.txt)"
                                fi
                                cat ${decode_dir_path}/fst4w_type1_and_type3_spots.txt ${decode_dir_path}/fst4w_type2_spots.txt > ${decode_dir_path}/low_res_fst4w_spots.txt
                                wd_logger  1 "Found low res FST4W spots:\n$(< ${decode_dir_path}/low_res_fst4w_spots.txt)"
                          fi
                        fi
                        ### Done formatting low res FST4W spots

                        ### Log the spots we have found.
                        if [[ -s ${decode_dir_path}/decoded.txt ]]; then
                            ### We use the spot information in jt9_output.txt which includes the sprectral width, so don't normally log it
                            wd_logger  2 "FST4W spots in decoded.txt:          \n$(awk '{printf "%d FIELDS: %s\n", NF, $0}' ${decode_dir_path}/decoded.txt)"
                        fi
                        if [[ -s ${decode_dir_path}/low_res_fst4w_spots.txt ]]; then
                            wd_logger  1 "The formatted FST4W  low resolution spots found in '${decode_dir_path}/low_res_fst4w_spots.txt':\n$(< ${decode_dir_path}/low_res_fst4w_spots.txt)"
                        fi
                        if [[ -s ${decode_dir_path}/high_res_fst4w_spots.txt ]] ; then
                            wd_logger  1 "The formatted FST4W high resolution spots found in '${decode_dir_path}/high_res_fst4w_spots.txt':\n$(< ${decode_dir_path}/high_res_fst4w_spots.txt)"
                        fi

                        ### Add any FST4W spots found and formatted above to the file 'decodes_cache.txt' which will be queued to posting daemon
                        if [[ ! -s ${decode_dir_path}/high_res_fst4w_spots.txt ]]; then
                            wd_logger 1 "After filtering and reformating, found no valid FST4W spots"
                        else
                            wd_logger 1 "Queuing $(wc -l < ${decode_dir_path}/high_res_fst4w_spots.txt) FST4W high res mode ${pkt_mode} spots after $(( SECONDS - start_time )) seconds which were formatted into uploadable spot lines:\n$( < ${decode_dir_path}/high_res_fst4w_spots.txt )"
                            cat ${decode_dir_path}/high_res_fst4w_spots.txt >> decodes_cache.txt
                        fi
                    fi
                fi
                processed_wav_files="yes"
            fi

            ### Check the value of ARCHIVE_WAV_FILES in the conf file each time we are finished decoding
            local config_archive_wav_files
            get_config_file_variable config_archive_wav_files "ARCHIVE_WAV_FILES"

            if [[ "${config_archive_wav_files}" != "yes" ]]; then
                rm ${decoder_input_wav_filepath}
            else
                ### Queue the wav file to a directory in the /dev/shrm/wsprdaemon file system.  The watchdog daemon calls a function every odd minute which
                ### Compresses those wav files into files which are saved in non-volatile storage under ~/wsprdaemon
                if queue_wav_file ${decoder_input_wav_filepath} ${wav_archive_dir}; then
                    wd_logger 1 "Archived wav file ${decoder_input_wav_filepath}"
                else
                    wd_logger 1 "ERROR: 'queue_wav_file ${decoder_input_wav_filepath}' => $?"
                fi
            fi
            if [[ ${processed_wav_files} == "yes" ]]; then 
                wd_logger 1 "Processed files '${wav_files}' concatenated into '${decoder_input_wav_filename}' for packet of length ${returned_seconds} seconds"
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
            queue_noise_signal_levels_to_wsprdaemon  ${wspr_decode_capture_date} ${wspr_decode_capture_time} "${sox_signals_rms_fft_and_overload_info}" ${wspr_decode_capture_freq_hz} ${signal_levels_log_file} ${wsprdaemon_noise_queue_directory}

            ### Rather than the time and effort for altering the code to work on blocks of 12000 samples to get a 1 Hz quantization Gwynn suggested the alternative is simple scaling: multiply reported frequency for out-of-the-box GPS aided
            ### Kiwi by 12001.1/12000 that is 1.00009167. This is a frequency increase of 0.128 Hz at 1400 Hz and 0.147 Hz at 1600 Hz.
            ### So if  SPOT_FREQ_ADJ_HZ is not blank, then modify the frequency of each spot by that floating point HZ value.  SPOT_FREQ_ADJ_HZ defaults to +.1 Hz which is the audio frequency error of a Kiwi using its internal 66.6666 Mhz oscillator 
            if [[ -n "${SPOT_FREQ_ADJ_HZ-.1}" ]]; then
                local freq_adj_hz=${SPOT_FREQ_ADJ_HZ-.1}
                wd_logger 1 "Fixing spot frequecies by ${freq_adj_hz} Hz"
                cp decodes_cache.txt decodes_cache.txt.unfixed
                awk -v freq_adj_hz=${freq_adj_hz} \
                    'BEGIN{freq_adj_mhz = freq_adj_hz / 1000000} {fixed_freq_mhz = $5 + freq_adj_mhz; printf( "%6s %4s %5.1f %5.2f %12.7f  %-22s %2s %5s %2s %2s %4s %2s %3s %5s %5s %s\n", $1, $2, $3, $4, fixed_freq_mhz, $6 " " $7 " " $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18 )}' \
                    decodes_cache.txt > decodes_cache.txt.fixed
                cp -p decodes_cache.txt.fixed decodes_cache.txt
            fi

            ### Record the spots in decodes_cache.txt plus the sox_signals_rms_fft_and_overload_info to wsprdaemon.org
            ### The start time and frequency of the spot lines will be extracted from the first wav file of the wav file list
            create_enhanced_spots_file_and_queue_to_posting_daemon   decodes_cache.txt ${wspr_decode_capture_date} ${wspr_decode_capture_time} "${sox_rms_noise_level}" "${fft_noise_level}" "${new_kiwi_ov_count}" ${receiver_call} ${receiver_grid}
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

    wd_logger 1 "Kill '${receiver_name},${receiver_band},${receiver_modes}'"

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})

    if [[ ! -d ${recording_dir} ]]; then
        wd_logger 1 "ERROR: ${recording_dir} for '${receiver_name},${receiver_band},${receiver_modes}' does not exist"
        return 1
    fi

    local decoding_pid_file=${recording_dir}/${DECODING_DAEMON_PID_FILE}
 
    if [[ ! -s ${decoding_pid_file} ]] ; then
        wd_logger 1 "ERROR: Decoding pid file '${decoding_pid_file} for '${receiver_name},${receiver_band},${receiver_modes}' does not exist or is empty"
        return 2
    fi
 
    local decoding_pid=$( < ${decoding_pid_file} )
    wd_rm ${decoding_pid_file}
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
         cd - > /dev/null
        wd_logger 1 "ERROR: 'wd_rm ${decoding_pid_file}' => ${rc}"
        return 3
    fi

    wd_kill_and_wait_for_death  ${decoding_pid}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'wd_kill_and_wait_for_death ${decoding_pid}' => ${ret_code}"
        return 4
    fi
 
    kill_wav_recording_daemon ${receiver_name} ${receiver_band}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'kill_wav_recording_daemon ${receiver_name} ${receiver_band} => $?"
        return 5
    fi
    wd_logger 1 "Killed  $receiver_name} ${receiver_band} => $?"
    return 0
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
        [[ $verbosity -ge 0 ]] && echo "ERROR: Got pid '${get_decoding_status_decode_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_decoding_status_decode_pid}"
    return 0
}

