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
    wd_logger 1 "af_info_list= '${af_info_list[*]}'"
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
    if [[ -z "${default_value-}" ]]; then
        wd_logger 1 "ERROR:  can't find af value for receiver ${real_receiver_name}, band ${real_receiver_rx_band}, AND there is no DEFAULT.  So return 0"
        default_value=0
    else
        wd_logger 1 "Returning default value ${default_value} for receiver ${real_receiver_name}, band ${real_receiver_rx_band}"
    fi
    eval ${return_variable_name}=${default_value}
    return 0
}

function calculate_nl_adjustments() {
    local return_rms_corrections_variable_name=$1
    local return_fft_corrections_variable_name=$2
    local receiver_band=$3

    local wspr_band_freq_khz=$(get_wspr_band_freq_khz ${receiver_band})
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

### Record an error line to the log file if the wav file contains audio samples which exceed these levels
declare WAV_MIN_LEVEL=${WAV_MIN_LEVEL--1.0}
declare WAV_MAX_LEVEL=${WAV_MAX_LEVEL-1.0}

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
        ### 'sox -n stats' output this information on seperate line:
        ###           DC offset 	Min level 	Max level 	Pk lev dB 	RMS lev dB 	RMS Pk dB 	RMS Tr dB 	Crest factor 	Flat factor 	Pk count 	Bit-depth 	Num samples 	Length s 	Scale max 	Window s
        ### Field #:  0                 1               2               3               4               5               6               7               8               9               10              11              12              13              14  
        ### Run 'man sox' and search for 'stats' to find a description of those statistic fields

        local full_wav_stats=$(sox ${wav_filename} -n stats 2>&1)                                     ### sox -n stats prints those to stderr
        local full_wav_stats_list=( $(echo "${full_wav_stats}" | awk '{printf "%s\t", $NF }')  )      ### store them in an array

        if [[ ${#full_wav_stats_list[@]} -ne ${EXPECTED_SOX_STATS_FIELDS_COUNT-15} ]]; then
            wd_logger 1 "ERROR:  Got ${#full_wav_stats_list[@]} stats from 'sox -n stats', not the expected ${EXPECTED_SOX_STATS_FIELDS_COUNT-15} fields:\n${full_wav_stats}"
        else
            local full_wav_min_level=${full_wav_stats_list[1]}
            local full_wav_max_level=${full_wav_stats_list[2]}
            local full_wav_peak_level_count=${full_wav_stats_list[9]}
            local full_wav_bit_depth=${full_wav_stats_list[10]}
            local full_wav_len_secs=${full_wav_stats_list[12]}

            ### Min and Max level are floating point numbers and their absolute values are  less than or equal to 1.0000
            if [[ $( echo "${full_wav_min_level} <=  ${WAV_MIN_LEVEL}" | bc ) == "1"  || $( echo "${full_wav_max_level} >=  ${WAV_MAX_LEVEL}" | bc ) == "1"  ]] ; then
                wd_logger 1 "ERROR: ${full_wav_peak_level_count} full level (+/-1.0) samples detected in file ${wav_filename} of length=${full_wav_len_secs} seconds and with Bit-depth=${full_wav_bit_depth}: the min/max levels are: min=${full_wav_min_level}, max=${full_wav_max_level}"
            else
                wd_logger 2  "In file ${wav_filename} of length=${full_wav_len_secs} seconds and with Bit-depth=${full_wav_bit_depth}: the min/max levels are: min=${full_wav_min_level}, max=${full_wav_max_level}"
            fi
            ### Create a status file associated with this indsividual wav file from which the decoding daemon will extract wav overload information for the spots decoded from this wav file
            echo "WAV_stats: ${full_wav_min_level} ${full_wav_max_level} ${full_wav_peak_level_count}" > ${wav_filename}.stats

            ### Append these stats to a log file which can be searched by a yet-to-be-implemented 'wd-...' command
            local wav_status_file="${WAV_STATUS_LOG_FILE-wav_status.log}"
            touch ${wav_status_file}          ### In case it doesn't yet exist
            if grep -q "${wav_filename}" ${wav_status_file} ; then
                wd_logger 1 "ERROR: unexpectly found log line for wav file ${wav_filename} in ${wav_status_file}"
            else
                wd_logger 1 "Appending '${wav_filename}: ${full_wav_min_level} ${full_wav_max_level} ${full_wav_peak_level_count}' to the log file '${wav_status_file}'"
                echo "${wav_filename}:  ${full_wav_min_level}  ${full_wav_max_level}  ${full_wav_peak_level_count}" >> ${wav_status_file}
                truncate_file ${wav_status_file} 100000      ### Limit the size of this log file to 100 Kb
            fi
        fi
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
    local wav_stats=$(sox ${wav_filename} -n stats 2>&1 )    ### Don't add ' --keep-foreign-metadata"
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

### Runs wsprd and outputs new spots to ALL_WSPR.TXT.new
function decode_wspr_wav_file() {
    local wav_file_name=$1
    local wspr_decode_capture_freq_hz=$2
    local rx_khz_offset=$3
    local stdout_file=$4
    local wsprd_cmd_flags="$5"                  ### ${WSPRD_CMD_FLAGS}
    local wsprd_spreading_cmd_flags="$6"        ### ${WSPRD_CMD_FLAGS}

    wd_logger 2 "Decode file ${wav_file_name} for frequency ${wspr_decode_capture_freq_hz} and send stdout to ${stdout_file}.  rx_khz_offset=${rx_khz_offset}, wsprd_cmd_flags='${wsprd_cmd_flags}'"
    local wspr_decode_capture_freq_hzx=${wav_file_name#*_}                                                 ### Remove the year/date/time
    wspr_decode_capture_freq_hzx=${wspr_decode_capture_freq_hz%_*}    ### Remove the _usb.wav
    local wspr_decode_capture_freq_hzx=$( bc <<< "${wspr_decode_capture_freq_hz} + (${rx_khz_offset} * 1000)" )
    local wspr_decode_capture_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${wspr_decode_capture_freq_hz}/1000000.0" ) )

    if ! [[  -f ALL_WSPR.TXT ]]; then
        touch  ALL_WSPR.TXT
    fi
    sort -k 1,2 -k 5,5 ALL_WSPR.TXT > ALL_WSPR.TXT.save
    cp -p ALL_WSPR.TXT.save ALL_WSPR.TXT

    timeout ${WSPRD_TIMEOUT_SECS-110} nice -n ${WSPR_CMD_NICE_LEVEL} ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: Command 'timeout ${WSPRD_TIMEOUT_SECS-110} nice -n ${WSPR_CMD_NICE_LEVEL} ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}' returned error ${ret_code}"
        return ${ret_code}
    fi  
    sort -k 1,2 -k 5,5 ALL_WSPR.TXT > sort.tmp
    mv sort.tmp ALL_WSPR.TXT
    comm --nocheck-order -13 ALL_WSPR.TXT.save ALL_WSPR.TXT | sort -k 1,2 -k 5,5 > ALL_WSPR.TXT.new.tmp
    wd_logger 1 "wsprd added $(wc -l < ALL_WSPR.TXT.new.tmp) spots to ALL_WSPR.txt and we saved those new spots in ALL_WSPR.TXT.new.tmp:\n$(<  ALL_WSPR.TXT.new.tmp)"

    ### Start with the original ALL_WSPR.TXT and see what spots are reported by  wsprd.spreading 
    wd_logger 2 "Decoding WSPR a second time to obtain spreading information"
    cp -p ALL_WSPR.TXT.save ALL_WSPR.TXT
    local n_arg="-n"

    if [[ ${OS_RELEASE} =~ 20.04 ]]; then
        n_arg=""    ## until we get a wsprd.spreading for U 20.04
    fi
    if [[ ${WSPRD_TWO_PASS-no} == "no" ]]; then
        wd_logger 2 "Skipping wsprd second pass because WSPRD_TWO_PASS == 'no'"
        >  ${stdout_file}.spreading
    else
        timeout ${WSPRD_TIMEOUT_SECS-110} nice -n ${WSPR_CMD_NICE_LEVEL} ${WSPRD_SPREADING_CMD} ${n_arg} -c ${wsprd_spreading_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}.spreading
        local rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: Command 'timeout ${WSPRD_TIMEOUT_SECS-110} nice -n ${WSPR_CMD_NICE_LEVEL} ${WSPRD_SPREADING_CMD} -n -c ${wsprd_spreading_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}.spreading' returned error ${rc}"
            # return ${ret_code}
        fi
    fi
    sort -k 1,2 -k 5,5 ALL_WSPR.TXT > sort.tmp
    mv sort.tmp ALL_WSPR.TXT
    comm --nocheck-order -13 ALL_WSPR.TXT.save ALL_WSPR.TXT | sort -k 1,2 -k 5,5 > ALL_WSPR.TXT.new.tmp.spreading
    wd_logger 1 "wsprd.spreading added $(wc -l < ALL_WSPR.TXT.new.tmp.spreading) spots to ALL_WSPR.txt and added those new spots in ALL_WSPR.TXT.nspreading_ew.tmp:\n$(<  ALL_WSPR.TXT.new.tmp.spreading)"
    cat  ALL_WSPR.TXT.new.tmp.spreading  >> ALL_WSPR.TXT.new.tmp
    ### Restore ALL_WSPR.TXT to its state before either of the decodes added spots
    mv   ALL_WSPR.TXT.save  ALL_WSPR.TXT

    ### Find the best set of spots from the two passes, giving preference to spots with WSPR-2 spreading information, and append them to ALL_WSPR.TXT so it can use them in the next decoding 
    awk -f ${AWK_FIND_BEST_SPOT_LINES} ALL_WSPR.TXT.new.tmp | sort -k 1,2 -k 5,5  >  ALL_WSPR.TXT.new
    cat  ALL_WSPR.TXT.new  >> ALL_WSPR.TXT
    wd_logger 1 "Added the $(wc -l < ALL_WSPR.TXT.new) spots which are the union of the standard and spreading decodes:\n$(< ALL_WSPR.TXT.new)" 

    truncate_file  ALL_WSPR.TXT  ${MAX_ALL_WSPR_SIZE}
    return ${ret_code}
}

declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare WSPRD_X86_SPREADING_CMD=${WSPRD_BIN_DIR}/wsprd.spread_nodrift.x86
declare WSPRD_ARM_SPREADING_CMD=${WSPRD_BIN_DIR}/wsprd.spread_nodrift.arm
declare AWK_FIND_BEST_SPOT_LINES=${WSPRDAEMON_ROOT_DIR}/best_spots.awk
declare WSPR_CMD_NICE_LEVEL="${WSPR_CMD_NICE_LEVEL-19}"
declare JT9_CMD_NICE_LEVEL="${JT9_CMD_NICE_LEVEL-19}"

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
            local rc
            wd_rm ${wav_file}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: Deleting older wav file '${wav_file}', 'wd_rm ${wav_file}' => ${rc}"
            fi
        elif [[ ${wav_file} -nt ${reference_file} ]]; then
            (( ++newers ))
            wd_logger 2 "Found wav file '${wav_file}' is newer than ${reference_file}"
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

declare WD_RECORD_HDR_SIZE_BYTES=44                                ## wd-record writes a wav file header and then waits until the first sample of the next minute before starting to write samples to the file
declare WAV_FILE_SIZE_POLL_SECS=${WAV_FILE_SIZE_POLL_SECS-2}       ## Check that the wav file is growing every NN seconds, 2 seconds by default
function sleep_until_raw_file_is_full() {
    local filename=$1
    if [[ ! -f ${filename} ]]; then
        wd_logger 1 "ERROR: ${filename} doesn't exist"
        return 1
    fi
    local old_file_size=$( ${GET_FILE_SIZE_CMD} ${filename} )
    local new_file_size
    local start_seconds=${SECONDS}

    sleep ${WAV_FILE_SIZE_POLL_SECS}
    while [[ -f ${filename} ]] && new_file_size=$( ${GET_FILE_SIZE_CMD} ${filename}) && [[ ${new_file_size} -eq ${WD_RECORD_HDR_SIZE_BYTES} || ${new_file_size} -gt ${old_file_size} ]]; do
        wd_logger 3 "Waiting for file ${filename} to stop growing in size. old_file_size=${old_file_size}, new_file_size=${new_file_size}"
        old_file_size=${new_file_size}
        sleep ${WAV_FILE_SIZE_POLL_SECS}
    done
    local loop_seconds=$(( SECONDS - start_seconds ))
    if [[ ! -f ${filename} ]]; then
        wd_logger 1 "ERROR: file ${filename} disappeared after ${loop_seconds} seconds"
        return 1
    fi
    wd_logger 2 "'${filename}' stopped growing after ${loop_seconds} seconds"

    local file_start_minute=${filename:11:2}
    local file_start_second=${filename:13:2}
    if [[ ${file_start_second} != "00" ]]; then
        wd_logger 2 "'${filename} starts at second ${file_start_second}, not at the required second '00', so delete this file which should be the first file created after startup AND any older wav files"
        local rc

        flush_wav_files_older_than ${filename}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: Deleting non 00 second wav file'${filename}', 'flush_wav_files_older_than ${filename}' => ${rc}"
        fi

        wd_rm ${filename}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: Deleting non 00 second wav file'${filename}', 'wd_rm ${filename}' => ${rc}"
        fi
        return 2
    fi

    ### Previously, I had just checked the size of the wav file to validate the duration of the recording
    ### My guesess of the min and max valid wav file size in bytes were too narrow and useful wav files were being thrown away
    local wav_file_duration_hh_mm_sec_msec=$(soxi ${filename} | awk '/Duration/{print $3}')
    local wav_file_duration_integer=$(sed 's/[\.:]//g' <<< "${wav_file_duration_hh_mm_sec_msec}")

    wd_logger 1 "Got wav file ${filename} header which reports duration = ${wav_file_duration_hh_mm_sec_msec} => wav_file_duration_integer = ${wav_file_duration_integer}. WAV_FILE_MIN_HHMMSSUU=${WAV_FILE_MIN_HHMMSSUU}, WAV_FILE_MAX_HHMMSSUU=${WAV_FILE_MAX_HHMMSSUU}"

    if [[ 10#${wav_file_duration_integer} -lt ${WAV_FILE_MIN_HHMMSSUU} ]]; then          ### The 10#... forces bash to treat wav_file_duration_integer as a decimal, since its leading zeros would otherwise identify it at an octal number
        wd_logger 2 "The wav file stabilized at invalid too short duration ${wav_file_duration_hh_mm_sec_msec} which almost always occurs at startup. Flush this file since it can't be used as part of a WSPR wav file"
        local rc

        flush_wav_files_older_than ${filename}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: While flushing too short wav file'${filename}', 'flush_wav_files_older_than ${filename}' => ${rc}"
        fi

        wd_rm ${filename}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: While flushing too shortwav file'${filename}', 'wd_rm ${filename}' => ${rc}"
        fi
        return 2
    fi
    if [[ 10#${wav_file_duration_integer} -gt ${WAV_FILE_MAX_HHMMSSUU} ]]; then
        ### If the wav file has grown to longer than one minute, then it is likely there are two kiwirecorder jobs running 
        ### We really need to know the IP address of the Kiwi recording this band, since this freq may be recorded by other other Kiwis in a Merged group
        local this_dir_path_list=( ${PWD//\// } )
        local kiwi_name=${this_dir_path_list[-2]}
        local kiwi_freq=${filename#*_}
              kiwi_freq=${kiwi_freq::3}
        local ps_output=$(ps aux | grep "${KIWI_RECORD_COMMAND}.*${kiwi_freq}.*${receiver_ip_address/:*}" | grep -v grep)
        local kiwirecorder_pids=( $(awk '{print $2}' <<< "${ps_output}" ) )
        if [[ ${#kiwirecorder_pids[@]} -eq 0 ]]; then
            wd_logger 1 "ERROR: wav file stabilized at invalid too long duration ${wav_file_duration_hh_mm_sec_msec}, but can't find any kiwirecorder processes which would be creating it;\n$(soxi ${filename})"
        else
            wd_kill ${kiwirecorder_pids[@]}
            local rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'wd_kill ${kiwirecorder_pids[*]}' => ${rc}"
            fi
            wd_logger 1 "ERROR: wav file stabilized at invalid too long duration ${wav_file_duration_hh_mm_sec_msec}, so there appear to be more than one instance of the KWR running. 'ps' output was:\n${ps_output}\nSo executed 'wd_kill ${kiwirecorder_pids[*]}'"
        fi
        local rc

        flush_wav_files_older_than ${filename}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: Deleting non 00 second wav file'${filename}', 'flush_wav_files_older_than ${filename}' => ${rc}"
        fi

        wd_rm ${filename}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: Deleting non 00 second wav file'${filename}', 'wd_rm ${filename}' => ${rc}"
        fi
        return 3
    fi
    wd_logger 2 "File ${filename} for minute ${filename:11:2} stabilized at size ${new_file_size} after ${loop_seconds} seconds"
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

###
### Get the epoch from the wav filename

function epoch_from_filename() 
{
    local file_name=${1##*/}  ## strip off the path leaving only the filename 
    local rc

    local file_date_format="${file_name:0:8} ${file_name:9:2}:${file_name:11:2}:${file_name:13:2}"
    local file_epoch=$(date -d "${file_date_format}" +%s)
    rc=$?
    if (( ${rc} != 0 )); then
        wd_1ogger 1 "ERROR: 'date -d "${file_date_format}" +%s' => ${rc}"
        return ${rc}
    fi

    echo "${file_epoch}"
    return 0
}

 ###
### Get the minute from the wav filename

function minute_from_filename() 
{
    local file_name=${1##*/}  ## strip off the path leaving only the filename 

    echo "${file_name:11:2}"
    return 0
}


### Given a list of filenames, start from the newest file, the one at the end of the list (i.e. [-1]), and work towards the front of the list
### Make sure that each earlier filename is 1 minute earlier.  If not, then flush all the older files from the list
function cleanup_wav_file_list()
{
    local __return_clean_files_string_name=$1
    local check_file_list=( $2 )

    if [[ ${#check_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Was given an empty file list"
        eval ${__return_clean_files_string_name}=\"\"
        return 0
    fi
    wd_logger 2 "Testing list of ${#check_file_list[@]} raw files: '${check_file_list[*]}'"

    if [[ ${#check_file_list[@]} -lt 1 ]]; then
        wd_logger 1 "ERROR: check_file_list[] is empty"
        return 1
    fi
    local epoch_of_newest_file=$( epoch_from_filename "${check_file_list[-1]}" )
    wd_logger 2 "Checking for valid list of wav_raw files which end with file ${check_file_list[-1]} = epoch ${epoch_of_newest_file} = minute $(( ( ${epoch_of_newest_file} % 3600 ) / 60 ))"

    local flush_files="no"

    ### Walk back from the end of the file list verifying that each preceeding file starts one minute earlier and is full sized.
    ### If a invalid file is found, flush it and all earlier files
    local raw_file_index=$(( ${#check_file_list[@]} - 2 ))  ### Start testing the second to last file in the list
    local epoch_of_last_file=${epoch_of_newest_file}        ### So the epoch of the last file is the last
    local return_clean_files_string="${check_file_list[-1]}" ### The last file is clean

    ### Now walk backwards through the check_file_list[] verifying that each file is full length and 60 seconds earlier than than its successor file
    while [[ ${raw_file_index} -ge 0 ]]; do
        local test_file_name
        test_file_name=${check_file_list[${raw_file_index}]}
        wd_logger 2 "Testing file ${test_file_name}"
        if [[ ${flush_files} == "yes" ]]; then
            wd_logger 1 "flush_files == 'yes', so flushing file ${test_file_name}"
            wd_rm ${test_file_name}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: for flush_files == 'yes' ${test_file_name}',  'wd_rm ${test_file_name}' => ${rc}"
            fi
            (( --raw_file_index ))
            continue
        fi
        local ret_code
        is_valid_wav_file ${test_file_name} ${MIN_VALID_RAW_WAV_SECONDS} ${MAX_VALID_RAW_WAV_SECONDS}
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            ### Found a wav file with invalid size
            wd_logger 1 "ERROR: found wav file '${test_file_name}' has invalid size.  Flush it and all earlier wav files"
            wd_rm ${test_file_name}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: Failed to flush the first invalid file we found, ${test_file_name}',  'wd_rm ${test_file_name}' => ${rc}"
            fi
            flush_files="yes"
            (( --raw_file_index ))
            continue
        fi
        ### wav file size is valid
    
        local epoch_of_test_file=$( epoch_from_filename ${test_file_name} )
        wd_logger 2 "test_file_name=${test_file_name} = ${epoch_of_test_file} = minute $(( ( ${epoch_of_test_file} % 3600 ) / 60 ))"
: <<'COMMENTED_OUT_LINES'
       ### see if it is one minute (60 second) earlier than the previous file
        local file_epoch_gap=$(( ${epoch_of_last_file} - ${epoch_of_test_file} ))
        if [[ ${file_epoch_gap} -ne 60 ]]; then
            wd_logger 1 "ERROR: test_file_name=${test_file_name} is file_epoch_gap=${file_epoch_gap} seocnds, not 1 minute (60 seconds), earlier than the next file in the list.  So delete it and all earlier files in the list"
            local rc
            wd_rm ${test_file_name}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: Failed to flush ${test_file_name}' which is not one minute earlier than the next wav file in the list: 'wd_rm ${test_file_name}' => ${rc}"
            fi
            flush_files="yes"
            wd_logger 1 "test_file_name=${test_file_name} is 1 minute (60 seconds) earlier than the next file in the list"
            epoch_of_last_file=${epoch_of_test_file}
            (( --raw_file_index ))
            continue
        fi
COMMENTED_OUT_LINES
        wd_logger 2 "test_file_name='${test_file_name}' from index ${raw_file_index} is clean and 60 seconds earlier the the next file in the list.  Proceed to check previous file on the list"
        epoch_of_last_file=${epoch_of_test_file}
        return_clean_files_string="${return_clean_files_string} ${test_file_name}"
        (( --raw_file_index ))
    done
 
    local clean_files_list=( ${return_clean_files_string} )

    wd_logger 2 "Given check_file_list[${#check_file_list[@]}]     ='${check_file_list[*]}'"
    wd_logger 2 "Returning clean_file_list[${#clean_files_list[*]}] ='${clean_files_list[*]}'"
    if [[ ${#check_file_list[@]} -ne ${#clean_files_list[*]} ]]; then
        wd_logger 1 "ERROR: Found errors in wav file list, so cleaned list check_file_list[${#check_file_list[@]}]='${check_file_list[*]}' => clean_file_list[${#clean_files_list[*]}]='${clean_files_list[*]}'"
    fi
    eval ${__return_clean_files_string_name}=\"${return_clean_files_string}\"
    return 0
} 

### Waits for wav files needed to decode one or more of the WSPR packet length wav file  have been fully recorded
### Then returns zero or more space-seperated strings each of which has the form 'WSPR_PKT_SECONDS:ONE_MINUTE_WAV_FILENAME_0,ONE_MINUTE_WAV_FILENAME_1[,ONE_MINUTE_WAV_FILENAME_2...]'
function get_wav_file_list() {
    local return_variable_name=$1  ### returns a string with a space-separated list each element of which is of the form MODE:first.wav[,second.wav,...]
    local receiver_name=$2         ### Used when we need to start or restart the wav recording daemon
    local receiver_band=$3           
    local receiver_modes=$4

    local     target_modes_list=( ${receiver_modes//:/ } )     ### Argument has form MODE1[:MODE2...] put it in local array
    local -ia target_minutes_list=( $( IFS=$'\n' ; echo "${target_modes_list[*]/?/}" | sort -nu ) )        ### Chop the "W" or "F" from each mode element to get the minutes for each mode  NOTE THE "s which are requried if arithmatic is being done on each element!!!!
    if [[ " ${target_minutes_list[*]} " =~ " 0 " ]] ; then
        ### The configuration validtor verified that jobs which have mode 'W0' specified will have no other modes
        ### In mode W0 we are only going to run the wsprd decoder in order to get the RMS can C2 noise levels
        wd_logger 1 "Found that mode 'W0' has been specified"
        target_minutes_list=( 2 )
    fi
    local -ia target_seconds_list=( "${target_minutes_list[@]/%/*60}" ) ### Multiply the minutes of each mode by 60 to get the number of seconds of wav files needed to decode that mode  NOTE that both ' and " are needed for this to work
    local oldest_file_needed=${target_seconds_list[-1]}

    wd_logger 1 ""
    wd_logger 1 "Start with args '${return_variable_name} ${receiver_name} ${receiver_band} ${receiver_modes}', then receiver_modes => ${target_modes_list[*]} => target_minutes=( ${target_minutes_list[*]} ) => target_seconds=( ${target_seconds_list[*]} )"
    ### This code requires  that the list of wav files to be generated is in ascending seconds order, i.e "120 300 900 1800)

    if [[ "${SPAWN_RECORDING_DAEMON-yes}" != "yes" ]]; then
        wd_logger 1 "Configured not to spawn_wav_recording_daemon()"
    else
        wd_logger 2 "Execute 'spawn_wav_recording_daemon ${receiver_name} ${receiver_band}' to be sure the wav file recorder is running"
        if ! spawn_wav_recording_daemon ${receiver_name} ${receiver_band} ; then
            local ret_code=$?
            wd_logger 1 "ERROR: 'spawn_wav_recording_daemon ${receiver_name} ${receiver_band}' => ${ret_code}"
            return ${ret_code}
        fi
        wd_logger 2 "'spawn_wav_recording_daemon ${receiver_name} ${receiver_band}' has checked and spawned the wav file recorder"
    fi

    ### An instance of kiwirecorders run and outputs wav files in the same directory as decoding, i.e. /dev/shm/recording.d/KIWI_0/20/
    ### There is one instance of the KA9Q stream recorder which outputs all wav files from the stream in the parent directory, i.e. /dev/shm/recording.d/KA9Q_0/
    local wav_recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})

    ### The pcmrecord wav files are created with names which different from those created by kiwirecorder
    local band_freq_hz=$( get_wspr_band_freq_hz ${receiver_band} )
    local wav_file_regex="*_${band_freq_hz}_usb.wav"

    # Start:
    # Find all wav files for this band abd sort by reverse time (i.e newest in [0]
    # if there are no files, then
    #    goto Start
    # if the newest is open
    #    remove it from the list
    # if there are less than 2 open files
    #    goto Start
    # go through the list and if there is a gap
    #    delete all files after the gap
    # if there are now less than 2 files 
    #    goto Start
    # for each pkt length MINs (2/5/15/30)
    #    If there is a packet of length MIN
    #        add list for MIN to return list
    # if return list is empty
    #    goto Start
    # Remove all files older than the longest pkt length we searched for
    # Return list

    wd_logger 2 "Starting 'while (( \${#return_list[@]} == 0 )); do ...'."
    local wait_for_newest_file_to_close="no"
    local return_list=()
    while (( ${#return_list[@]} == 0 )); do
        ### Get a list of all wav files for this band
        wd_logger 2 "Get new find_files_list[] by running 'find ${wav_recording_dir} -maxdepth 1 -name '${wav_file_regex}' | sort -r '"
        local find_files_list=()
        find_files_list=( $( find ${wav_recording_dir} -maxdepth 1 -name "${wav_file_regex}" | sort -r ) )

        if (( ${#find_files_list[@]} < 1 )); then
            wd_logger 2 "Found no wav files.  Sleep 5 and then search again"
            sleep 5
            continue
        fi
        ### There is at least one file on the list
        wd_logger 2 "find_files_list[] has ${#find_files_list[@]} entries: ${find_files_list[@]##*/}"

        local newest_file_name=${find_files_list[0]}

        if [[ ${wait_for_newest_file_to_close} == "yes" ]]; then
            ### We found a list but couldn't create a return_list[]
            while lsof ${newest_file_name} >& /dev/null; do
                wd_logger 1 "We found a list but couldn't create a return_list[], so waiting for the newest file for minute '$(minute_from_filename ${newest_file_name})' is not being written by running 'inotifywait -e close ${newest_file_name##*/}'"
                inotifywait -e close ${newest_file_name} >& /dev/null
                wd_logger 2 "File ${newest_file_name##*/} has been closed"
            done
            wd_logger 2 "This newest File ${newest_file_name##*/} has been closed, so sleep 1 and then refresh the file list"
            wait_for_newest_file_to_close="no"
            sleep 5
            continue
        fi

        if lsof ${newest_file_name} >& /dev/null; then
            wd_logger 2 "The newest file ${newest_file_name##*/} in the list of ${#find_files_list[@]} files is open, so remove it from find_files_list[]"
            find_files_list=( ${find_files_list[@]:1} )
            wd_logger 2 "There are now ${#find_files_list[@]} elements in find_files_list[@]"
            if (( ${#find_files_list[@]} < 1 )); then
                wd_logger 2 "There are no closed files on the list, so leave it to the next block of code to sleep until it is closed"
            fi
        fi
        wd_logger 2 "After removing any open file there are now ${#find_files_list[@]} closed files: ${find_files_list[@]##*/}"

        if (( ${#find_files_list[@]} < 2 )); then
            wd_logger 2 "Found only ${#find_files_list[@]} closed wav files in ${wav_recording_dir}, so wait until the newest (minute '$(minute_from_filename ${newest_file_name})') file ${newest_file_name##*/} is not being written by running 'inotifywait -e close ${newest_file_name##*/}'"
            while lsof ${newest_file_name} >& /dev/null; do
                wd_logger 2 "Running inotifywait -e close ${newest_file_name##*/}"
                inotifywait -e close ${newest_file_name} >& /dev/null
                wd_logger 2 "File ${newest_file_name##*/} has been closed"
            done
            wd_logger 2 "File ${newest_file_name##*/} has been closed, so sleep 5 and then refresh the file list"
            sleep 5
            continue
        fi
        ### ${#find_files_list[@]} has 2 or more closed files in it list
        ### [0] is newest file

        ### Cleanup the file list so that it contains only a contiguous list of files, each starting one minute later than the previous file
        local find_files_count=${#find_files_list[@]}
        wd_logger 2 "The 'find' command found ${find_files_count} closed wav files in '${wav_recording_dir}': '${find_files_list[*]##*/}'"
        wd_logger 2 "Removing any files in the list which preceed any gap"

        local last_file_name="${find_files_list[0]}"
        local checked_files_list=( ${last_file_name} )
        local index
        for (( index = 1; index < ${#find_files_list[@]}; ++index )); do
            local checking_file_name=${find_files_list[index]}

            wd_logger 2 "Checking that index=${index} with file ${checking_file_name##*/} is one minute older than ${last_file_name##*/}"
            
            ### Checking the write times of the files
            local checking_file_epoch=$(epoch_from_filename ${checking_file_name})
            local last_file_epoch=$(epoch_from_filename ${last_file_name})
            wd_logger 2 "Checking that the filename time of ${checking_file_name##*/} with epoch ${checking_file_epoch} is about one minute older than filename time  ${last_file_name##*/} of the next file with epoch ${last_file_epoch}"

            if (( checking_file_epoch > last_file_epoch )); then
                ### This file's epoch is newer rather than the expected one minute older than the previous file in the list, so flush it and any subsequent files in the list
                local flush_files_list=( ${find_files_list[@]:index} )
                wd_logger 1 "ERROR: at index ${index} unexpected that the checking file ${checking_file_name##*/} epoch ${checking_file_epoch} is newer than the last file ${last_file_name##*/} epoch ${last_file_epoch}"
                wd_logger 1 "ERROR: So flush it and all the rest of the ${#flush_files_list[@]} files in the rest of the find_fileslist[]: ${flush_files_list[@]##*/}"
                wd_rm ${flush_files_list[@]}
                wd_logger 1 "After flushing the ${#flush_files_list[@]} files after the gap, we are finished checking the list and left with ${#checked_files_list[@]} contiguous files"
                break
            fi
            local write_epoch_gap=$(( last_file_epoch - checking_file_epoch ))
            if (( write_epoch_gap != 60  )); then
                 ### This file's epoch is more than the expected one minute older than the previous file in the list, so flush it and any subsequent files in the list
                local flush_files_list=( ${find_files_list[@]:index} )
                wd_logger 1 "ERROR: At index ${index} found a too large gap of ${write_epoch_gap} seconds between ${checking_file_name##*/} and the previous (newer) file ${last_file_name##*/}"
                wd_logger 1 "So flush ${checking_file_name##*/} and all the rest of the ${#flush_files_list[@]} files in find_fileslist[]: ${flush_files_list[@]##*/}"
                wd_rm ${flush_files_list[@]}
                wd_logger 1 "After flushing the ${#flush_files_list[@]} files after the gap, we are finished checking the list and left with ${#checked_files_list[@]} contiguous files"
                break
            fi

            ### Checking the file names minutes
            ### This file is older than the last file but not more than 61 seconds older
            ### Now check the file names differ by one minute 
            ### Both kiwirecorder and 'pcmrecorder --jt' create files with names with the format:
            ####    YYYYMMDDTHHMMSSZ_<FREQ_IN_HZ>_usb.wav
            local file_write_time_difference_seconds=$(( checking_file_epoch - last_file_epoch ))

            local last_file_minute
            last_file_minute=${last_file_name##*/}
            last_file_minute=$(( 10#${last_file_minute:11:2} ))   ### 

            local checking_file_minute
            checking_file_minute=${checking_file_name##*/}
            checking_file_minute=$(( 10#${checking_file_minute:11:2} ))

            wd_logger 2 "Checking that minute '${checking_file_minute}' file ${checking_file_name##*/} is one minute older than the previous minute '${last_file_minute}' file ${last_file_name##*/}"

            local expected_minute
            if (( last_file_minute == 0  )); then
                expected_minute=59
            else
                expected_minute=$(( last_file_minute - 1 ))
            fi
            wd_logger 2 "last_file_minute=${last_file_minute}, so file next file should be one minute older: expected_minute=${expected_minute}"

            if (( checking_file_minute != expected_minute )); then
                local flush_files_list=( ${find_files_list[@]:index} )
                wd_logger 1 "Found the minute ${checking_file_minute} name of file ${checking_file_name##*/} is not one minute older than the minute name ${last_file_minute} of the previous file ${last_file_name##*/}"
                wd_rm ${flush_files_list[@]}
                wd_logger 1 "After flushing the ${#flush_files_list[@]} files after the gap, we are finished checking the list and left with ${#find_files_list[@]} contiguous files"
                break
            fi
            wd_logger 2 "Adding the checked File ${checking_file_name##*/} for minute ${checking_file_minute} to the checked_files_list[] since it preceeds ${last_file_name##*/} by one minute"
            last_file_name=${checking_file_name}
            checked_files_list=( ${checking_file_name} ${checked_files_list[@]} ) 
        done          ### Checking the find_files_list[] and creating a list of 2 or more contiguous files

        ### We should have a clean/contiguous list of wav files
        local checked_files_count=${#checked_files_list[@]}
        if (( checked_files_count != find_files_count )); then
            wd_logger 1 "'find' returned a list of ${find_files_count}, but only the last ${checked_files_count} were contiguous one minute long files"
        fi
        if (( checked_files_count < 2 )); then
            wd_logger 2 "After checking found only ${checked_files_count} files, so search again"
            sleep 1
            continue
        fi

        ### We have a list of 2 or more contiguous files.  checked_files_list[0] is the oldest, checked_files_list[-1] the newest
        ### See if any previously unreported list of 2/5/15/30 minute files can be found in this list

       ### For each 2/5/15/30 minute wav file we have been asked to return, serach for earliest run of one minute wav files which satisfy the needed run of needed minute wav files
       local epoch_of_oldest_checked_file=$( epoch_from_filename ${checked_files_list[0]} ) ## instead of stat --format=%Y  ${checked_files_list[0]} )
       local minute_of_oldest_checked_file
       minute_of_oldest_checked_file=${checked_files_list[0]##*/}
       minute_of_oldest_checked_file=${minute_of_oldest_checked_file:11:2}
       local epoch_of_newest_checked_file=$( epoch_from_filename ${checked_files_list[-1]} )  ## instead of stat --format=%Y ${checked_files_list[-1]} )
       local minute_of_newest_checked_file
       minute_of_newest_checked_file=${checked_files_list[-1]##*/}
       minute_of_newest_checked_file=${minute_of_newest_checked_file:11:2}
       local index_of_last_file_in_checked_files_list=$(( ${#checked_files_list[@]} - 1 ))

       wd_logger 2 "Found ${#checked_files_list[@]} contiguous and closed files starting at minute ${minute_of_oldest_checked_file} and ending at minute ${minute_of_newest_checked_file}"

       local seconds_in_wspr_pkt
       for seconds_in_wspr_pkt in ${target_seconds_list[@]} ; do
           local minutes_in_wspr_pkt=$(( seconds_in_wspr_pkt / 60 ))
           local seconds_into_wspr_pkt_of_oldest_checked_file=$(( epoch_of_oldest_checked_file % seconds_in_wspr_pkt ))
           local pkt_number_of_oldest_checked_file_in_wspsr_pkt_of_this_length=$(( seconds_into_wspr_pkt_of_oldest_checked_file / 60 ))

           wd_logger 2 "============== Checked_files_list[0] contains ${#checked_files_list[@]} elements, the first of which is the minute ${pkt_number_of_oldest_checked_file_in_wspsr_pkt_of_this_length} of a ${minutes_in_wspr_pkt} minute long WSPR packet"

           ### Check to see if we have returned some of these files in a previous call to this function
           ### The '-secs'  files contain the name of the first file of a complete ${seconds_in_wspr_pkt} wav file which was previously reporeted
           local index_of_first_minute_of_wspr_pkt
           local wav_checked_pkt_sec_list=( $(  find ${wav_recording_dir} -maxdepth 1 -name "${wav_file_regex}.${seconds_in_wspr_pkt}-secs" | sort -r ) ) 
           if (( ${#wav_checked_pkt_sec_list[@]} == 0 )); then
               ### There is no previosuly reported wspr pkt of this length,  Check to see if a complete wspr pkt starts and ends in the filled 
               index_of_first_minute_of_wspr_pkt=$(( (minutes_in_wspr_pkt - pkt_number_of_oldest_checked_file_in_wspsr_pkt_of_this_length) % minutes_in_wspr_pkt ))   ### but this index may not be in checked_files_list[]
               if (( index_of_first_minute_of_wspr_pkt < 0 )); then
                   wd_logger 1 "ERROR: index_of_first_minute_of_wspr_pkt=${index_of_first_minute_of_wspr_pkt} is< 0 which is an invalid index.  Sleeping 20 seconds  for diags..."
                   sleep 20
                   continue
               fi
           else
               ### We have previously reported a wspr file for this wspr pkt length, so we are looking for the end of the wspr pkt which follows that one to be in the checked_files_list[]
               if (( ${#wav_checked_pkt_sec_list[@]} > 1 )); then
                   wd_logger 2 "Flushing the $(( ${#wav_checked_pkt_sec_list[@]} - 1 )) no longer needed 'pkt has been returned' files: ${wav_checked_pkt_sec_list[@]:1}"
                   wd_rm ${wav_checked_pkt_sec_list[@]:1}
               fi
               local epoch_of_previously_reported_wspr_pkt=$( epoch_from_filename ${wav_checked_pkt_sec_list[0]} )
               local epoch_of_pkt_we_want=$(( epoch_of_previously_reported_wspr_pkt + seconds_in_wspr_pkt ))
               local seconds_after_oldest_check_file=$(( epoch_of_pkt_we_want - epoch_of_oldest_checked_file ))
               index_of_first_minute_of_wspr_pkt=$(( seconds_after_oldest_check_file / 60 ))
               if (( index_of_first_minute_of_wspr_pkt < 0 )); then
                   wd_logger 1 "ERROR: got invalid index after starting from time of last reported pkt which was saved in file  ${wav_checked_pkt_sec_list[0]##*/}"
                   wd_logger 1 "ERROR:  index_of_first_minute_of_wspr_pkt=${index_of_first_minute_of_wspr_pkt} epoch_of_previously_reported_wspr_pkt=${epoch_of_previously_reported_wspr_pkt} from ${wav_checked_pkt_sec_list[0]}"
                   wd_logger 1 "ERROR:  started with epoch_of_previously_reported_wspr_pkt=${epoch_of_previously_reported_wspr_pkt} of ${wav_checked_pkt_sec_list[0]}"
                   wd_logger 1 "ERROR:  so the epoch of the first file we want is ${seconds_after_oldest_check_file} seconds after the epoch_of_previously_reported_wspr_pkt"
                   wd_logger 1 "ERROR:  so the first file we want will be checked_files_list[${index_of_first_minute_of_wspr_pkt}"
                   sleep 10
                   continue
               fi
           fi
          if (( index_of_first_minute_of_wspr_pkt >= ${#checked_files_list[@]} )); then
               wd_logger 2 "Can't find the first minute of this ${minutes_in_wspr_pkt} minute wspr pkt which would be in checked_files_list[${index_of_first_minute_of_wspr_pkt}] because that is beyond the last element [$(( ${#checked_files_list[@]} - 1 ))]"
               continue
           fi
           local index_of_last_minute_of_wspr_pkt
           index_of_last_minute_of_wspr_pkt=$(( index_of_first_minute_of_wspr_pkt + minutes_in_wspr_pkt - 1 ))                            ### even if that index is valid, this one may not
           if (( index_of_last_minute_of_wspr_pkt >= ${#checked_files_list[@]} )); then
               wd_logger 2 "First minute of this ${minutes_in_wspr_pkt} minute wspr pkt is in checked_files_list[${index_of_first_minute_of_wspr_pkt}], but the last wanted element [${index_of_last_minute_of_wspr_pkt}] is beyond the last element [$(( ${#checked_files_list[@]} - 1 ))]"
               continue
           fi
           wd_logger 2 "In checked_files_list[${#checked_files_list[@]}] we Found a complete ${minutes_in_wspr_pkt} minute wspr packet which starts at checked_files_list[${index_of_first_minute_of_wspr_pkt}] and ends at checked_files_list[${index_of_last_minute_of_wspr_pkt}]"

           if (( seconds_in_wspr_pkt == ${target_seconds_list[-1]} )) ; then
               wd_logger 2 "We have found a complete set of minute files for the longest wspr packet we seek, a ${seconds_in_wspr_pkt} second packet, which starts at checked_files_list[${index_of_first_minute_of_wspr_pkt}] and ends at checked_files_list[${index_of_last_minute_of_wspr_pkt}], so we can flush checked_files_list[0:${index_of_first_minute_of_wspr_pkt}]"
               wd_rm ${checked_files_list[@]:0:${index_of_first_minute_of_wspr_pkt}} 
           fi

           local comma_seperated_file_list_of_minute_checked_files=$( IFS=, ; echo -n "${checked_files_list[*]:${index_of_first_minute_of_wspr_pkt}:${minutes_in_wspr_pkt}}" )
           local add_to_return_list="${seconds_in_wspr_pkt}:${comma_seperated_file_list_of_minute_checked_files}"
           wd_logger 2 "The checked_files_list[] file ${checked_files_list[${index_of_first_minute_of_wspr_pkt}]##*/} file at index ${index_of_first_minute_of_wspr_pkt} is the start of a full ${minutes_in_wspr_pkt} minute WSPR pkt, so add '${add_to_return_list}' to the return list"
           return_list+=( ${add_to_return_list} )

           local wav_list_returned_file=${checked_files_list[${index_of_first_minute_of_wspr_pkt}]}.${seconds_in_wspr_pkt}-secs
           touch -r ${checked_files_list[${index_of_first_minute_of_wspr_pkt}]} ${wav_list_returned_file}
           wd_logger 2 "Created '${wav_list_returned_file##*/}' so we won't again return this list of wav files which make up this wspr pkt"
       done       ### with search for all the different wspr wav file lengths
       if (( ${#return_list[@]} == 0 )); then
           wd_logger 2 "return_list[] is empty, so go back to top of this search and wait for newest open file to be closed, then check again"
           wait_for_newest_file_to_close="yes"
       fi
   done

   wd_logger 2 "Returning ${#return_list[@]} wspr pkt lists: '${return_list[*]}'\n"
   eval ${return_variable_name}=\"${return_list[*]}\"
   return 0
}

function flush_or_archive_checked_wav_files() {
    local wav_archive_dir=$1
    local wav_file_list=( ${@:2} )     ### Get list of variable number of arguments from $2 to last argument
    local config_archive_raw_wav_files
    local rc

    wd_logger 1 "wav_archive_dir=${wav_archive_dir}, rm or archive: ${wav_file_list[*]}"

    get_config_file_variable config_archive_raw_wav_files "ARCHIVE_RAW_WAV_FILES"
    if [[  "${config_archive_raw_wav_files}" != "yes" && -f "archive-raw-wav-files" ]]; then
        wd_logger 1 "Found file 'archive-raw-wav-file', so save this raw file"
        config_archive_raw_wav_files="yes"
    fi
    if [[ "${config_archive_raw_wav_files}" != "yes" ]]; then
        wd_rm ${wav_file_list[@]}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: Failed flushing old checked_lists_list[]: 'wd_rum ${wav_file_list[*]}' => ${rc}"
        fi
        return ${rc}
    else
        local rrc=0
        local raw_wav_file
        for raw_wav_file in ${wav_file_list[@]} ; do
            queue_wav_file ${raw_wav_file} ${wav_archive_dir}
            rc=$?
            if [[ ${rc} -eq 0 ]]; then
                wd_logger 1 "INFO: Archived wav file ${raw_wav_file}"
            else
                wd_logger 1 "ERROR: 'queue_wav_file ${raw_wav_file}' => $?"
                rrc=${rc}
            fi
        done
        if [[ ${rrc} -eq 0 ]]; then
            wd_logger 1 "INFO: Archived all wav files"
        else
            wd_logger 1 "ERROR: 'queue_wav_file ${raw_wav_file}' failed one or more times=> $${rrc}"
        fi
        return ${rrc}
    fi
}


### Called by the decoding_daemon() to create an enhanced_spot file from the output of ALL_WSPR.TXT
### That enhanced_spot file is then posted to the subdirectory where the posting_daemon will process it (and other enhanced_spot files if this receiver is part of a MERGEd group)

### For future reference, here is the output lines in  ALL_WSPR.TXT taken from the wsjt-x 2.1-2 source code:
# In WSJT-x v 2.2+, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
#    fprintf(fall_wspr,    "%6s    %4s    %3.0f    %5.2f    %11.7f    %-22s            %2d    %5.2f     %2d        %2d     %4d        %2d        %3d        %5u    %5d \n",
#                         date,   time,  snr,     dt,      freq,     message, (int)drift,    sync, ipass+1, blocksize, jitter, decodetype, nhardmin, cycles/81, metric);

declare  FIELD_COUNT_DECODE_LINE_WITH_GRID=19                                              ### wsprd v2.2 adds two fields and we have added the 'upload to wsprnet.org' field, so lines with a GRID will have 17 + 1 + 2 noise level fields.  V3.x added spot_mode to the end of each line
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
    local freq_adj_mhz=$9
    local proxy_upload_this_spot=0    ### This is the last field of the enhanced_spot line. If ${SIGNAL_LEVEL_UPLOAD} == "proxy" AND this is the only spot (or best spot among a MERGEd group), 
                                      ### then the posting daemon will modify this last field to '1' to signal to the upload_server to forward this spot to wsprnet.org
    local cached_spots_file_name="${spot_file_date}_${spot_file_time}_spots.txt"

    if grep -q "<...>" ${real_receiver_wspr_spots_file} ; then
        grep -v "<...>" ${real_receiver_wspr_spots_file} > no_unknown_type3_spots.txt
        wd_logger 1 "Posting 'no_unknown_type3_spots.txt' since found '<...>' calls in ${real_receiver_wspr_spots_file}"
        real_receiver_wspr_spots_file=no_unknown_type3_spots.txt
    fi

    if [[ ! ${REMOVE_WD_DUP_SPOTS-yes} =~ [Yy][Ee][Ss] ]]; then
        wd_logger 1 "WD is configured to record duplicate spots, so skip duplicate removal"
    else
        local spot_count=$(wc -l < ${real_receiver_wspr_spots_file} )
        local tx_calls=$( awk '{print $6}' ${real_receiver_wspr_spots_file} | sort -u )
        local tx_calls_list=( ${tx_calls} )
        if [[ ${#tx_calls_list[@]} -eq ${spot_count} ]]; then
            wd_logger 1 "Found no dup spots among the ${#tx_calls_list[@]} spots in ${real_receiver_wspr_spots_file}, so record all the spots"
        else
            local no_dups_spot_file=${real_receiver_wspr_spots_file}.nodups
            > ${no_dups_spot_file}
            wd_logger 1 "Found some dup spots in ${real_receiver_wspr_spots_file} since the spot_count=${spot_count} is greater than the number of calls #tx_calls_list[@]=${#tx_calls_list[@]} "
            local tx_call
            for tx_call in ${tx_calls_list[@]} ; do
                grep "${tx_call}" ${real_receiver_wspr_spots_file} > spot_lines.txt
                if [[ $(wc -l < spot_lines.txt) -eq 1 ]]; then
                    ### There is only one spot line for this call, so there can be no duplicate lines
                    wd_logger 2 "There is only one spot line for call ${tx_call}, so queue it for posting"
                    cat spot_lines.txt >> ${no_dups_spot_file}
                else
                    ### There are more than one spot line, but the duplicates could be from the same TX sending in different modes
                    local modes_list=($( awk  '{print $NF}' spot_lines.txt | sort -u ) )   ## last field is the mode of the spot
                    wd_logger 1 "Found ${#modes_list[@]} spot lines for tx_call=${tx_call}:\n$(< spot_lines.txt)\nSo for each spot mode in modes_list=${modes_list[*]} adding only the spot line with the best SNR"
                    > add_spot_lines.txt
                    for mode in ${modes_list[@]}; do
                        ### The spot mode is the last field in the spot line
                        grep " ${mode}\$" spot_lines.txt | sort -k 3,3n | tail -n 1 > best_spot_line.txt 
                        wd_logger 1 "For mode ${mode} adding only this spot line which has the best SNR:\n$( < best_spot_line.txt)"
                        cat best_spot_line.txt >> add_spot_lines.txt
                    done
                    cat add_spot_lines.txt >> ${no_dups_spot_file}
                fi
            done
            sort -k 5,5n ${no_dups_spot_file} > no_dup_spots.txt   ### sort by frequency
            wd_logger 2 "Posting the newly created 'no_dup_spots.txt' which differs from ${real_receiver_wspr_spots_file}:\n$(diff ${real_receiver_wspr_spots_file} no_dup_spots.txt)"
            real_receiver_wspr_spots_file=no_dup_spots.txt
        fi
    fi

    wd_logger 2 "Enhance the spot lines from ALL_WSPR_TXT in ${real_receiver_wspr_spots_file} into ${cached_spots_file_name}"
    > ${cached_spots_file_name}         ### truncates or creates a zero length file
    local spot_line
    while read spot_line ; do
        local spot_line_list=(${spot_line/,/})         
        local spot_line_list_count=${#spot_line_list[@]}
        if [[ ${spot_line_list_count} -ne  ${FIELD_COUNT_DECODE_LINE_WITH_GRID} && ${spot_line_list_count} -ne ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
            wd_logger 1 "ERROR: input spot line has ${spot_line_list_count} fields instead of the expected  ${FIELD_COUNT_DECODE_LINE_WITH_GRID} or ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} fields"
            continue
        fi
        wd_logger 2 "Creating an enhanced spot line from file ${real_receiver_wspr_spots_file} which has ${spot_line_list_count} fields and store them in ${cached_spots_file_name}:\n${spot_line}"

        wd_logger 2 "Extracting fields from the spot line and assigning them to their associated bash variables"
        ### Name of the fields in their order on the input line
        local input_spot_field_name_list=(spot_date spot_time spot_snr spot_dt spot_freq spot_call spot_grid \
                                          spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype  spot_nhardmin spot_cycles spot_metric spot_spreading spot_pkt_mode)
        local input_spot_grid_field_index=6
        local input_spot_field_name_list_count=${#input_spot_field_name_list[@]}
        local type1_field_count=${input_spot_field_name_list_count}
        local type3_field_count=$((  ${type1_field_count} - 1 ))
        if [[ ${spot_line_list_count} -eq ${type1_field_count} ]]; then
            wd_logger 2 "Found a spot line with the normal ${type1_field_count} fields of a type 1 spot"
        elif [[ ${spot_line_list_count} -eq ${type3_field_count} ]]; then
            wd_logger 1 "Found a spot line with the normal ${type3_field_count} fields of a type 3 spot"
        else
            wd_logger 1 "ERROR: Found a spot line with ${spot_line_list_count} fields, not the expected ${type1_field_count} type 1 or ${type3_field_count} type 3 fields"
        fi

        ### Assign the field values to their associated bash variables
        local i
        local j=0
        for (( i = 0; i <  ${spot_line_list_count}; ++i )) ; do
            local field_name="${input_spot_field_name_list[i]}"
            wd_logger 2 "Checking field ${field_name} found at index ${i}"
            if [[ ${i} == ${input_spot_grid_field_index} && ${spot_line_list_count} == ${FIELD_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
                wd_logger 1 "This spot line contains no GRID, so assign it the value 'none'"
                eval ${field_name}="none"
            else
                local field_value=${spot_line_list[${j}]}
                eval ${field_name}=\${field_value}
                wd_logger 2 "Assigned input field value ${field_value} to variable ${field_name}"
                (( ++j ))
            fi
        done

        if [[ ${freq_adj_mhz} != "0" ]]; then
            local adj_spot_freq=$( echo "scale=7; ${spot_freq} + ${freq_adj_mhz} " | bc )
            wd_logger 2 "Adjusting spot freqency by ${freq_adj_mhz} MHz from ${spot_freq} to ${adj_spot_freq}"
            spot_freq=${adj_spot_freq}
        else
            wd_logger 3 "Not adjusting spot frequency ${spot_freq}"
        fi

        ### AI6VN 21 Nov 2023      add spot-sopreading to WSP=R-2 lines and copy that speading in hertz * 1000 into the metric field, then remove anty leading 0s with the 10#
        local spreading_metric=$(( 10#${spot_spreading##*.} ))   ### Instead of performing a floatin gpoint *1000.0 with 'bc', just chop off the leading 'N.' 
        wd_logger 2 "Overwrite the metric fiele value field value ${spot_metric} with 1000 * the spreading value ${spot_spreading}. So spot_metric becomes  ${spreading_metric}"
        spot_metric=${spreading_metric}

        ### G3ZIL April 2020 V1    add azi to each spot line
        wd_logger 2 "'add_derived ${spot_grid} ${real_receiver_grid} ${spot_freq}'"
        add_derived ${spot_grid} ${real_receiver_grid} ${spot_freq}
        if [[ ! -f ${DERIVED_ADDED_FILE} ]] ; then
            wd_logger 2 "spots.txt ${DERIVED_ADDED_FILE} file not found"
            return 1
        fi
        local derived_fields=$(cat ${DERIVED_ADDED_FILE} | tr -d '\r')
        derived_fields=${derived_fields//,/ }   ### Strip out the ,s
        local  derived_field_list=( ${derived_fields} )
        wd_logger 2 "derived_fields='${derived_fields}'"

        local derived_veriables_list=( band km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon )
        if [[ ${#derived_field_list[@]} -ne ${#derived_veriables_list[@]} ]]; then
            wd_logger 1 "ERROR: Number of fields in derived_field_list[]=${#derived_field_list[@]} is not equal to the number of bash variables ${#derived_veriables_list[@]} they are being assigned to.  So initialize those variables to 0"
            for variable in ${derived_veriables_list[@]} ]]; do
                ${variable}=0
            done
        fi
        read ${derived_veriables_list[@]} <<< "${derived_fields}"

        if [[ ${spot_date} != ${spot_file_date} ]]; then
            wd_logger 1 "WARNING: the date in spot line ${spot_date} doesn't match the date in the filename: ${spot_file_date}"
        fi
        if [[ ${spot_time} != ${spot_file_time} ]]; then
            wd_logger 1 "WARNING: the time in spot line ${spot_time} doesn't match the time in the filename: ${spot_file_time}"
        fi

        ### We are done gathering data and assigning it to the associated bash variables.
        ### Now print the extended spot format line from the values in those variables.

        ### Output a space-separated line of enhanced spot data.  The first 14 fields are in the same order but with "none" added when the message field with CALL doesn't include a GRID field
        ### Each of these lines should be uploaded to logs.wsprdaemon.org.  If ${SIGNAL_LEVEL_UPLOAD} == "proxy" AND this is the only spot (or best spot among a MERGEd group), then the posting daemon will modify the last field to signal the upload_server to forward this spot to wsprnet.org
        ### The first row of printed variables are taken from the ALL_WSPR.TXT file lines with the 10th field sync_quality moved to field 3 so the line format is a superset of the lines created by WD 2.10
        ### The second row are the values added  by our 'add_derived' Python line
        ### The third row are values taken from WD's  rms_noise, fft_noise, WD.conf call sign and grid, etc.
        # printf "%6s        %4s            %3.2f               %3d     %5.2f         %12.7f         %-14s        %-6s          %2d           %2d         %4d             %4d              %4d             %4d             %2d              %3d             %3d             %2d               %6.1f                   %6.1f            %4d            %6s                %12s                  %5d     %6.1f      %6.1f     %6.1f      %6.1f   %6.1f     %6.1f     %6.1f    %6.1f               %4d                             %4d\n" \
        # field#:  1           2               10                 3         4              5             6           7            8             9          11              12               13              14              15               16             17               18                  19                      20             21            22                   23                   24        25         26        27         28      29        30       31      32                  33                              34    \
        local output_field_name_list=(spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid \
                                          spot_pwr spot_drift spot_cycles spot_jitter spot_blocksize spot_metric spot_decodetype \
                                          spot_ipass spot_nhardmin spot_pkt_mode wspr_cycle_rms_noise wspr_cycle_fft_noise \
                                          band real_receiver_grid real_receiver_call_sign \
                                          km rx_az  rx_lat  rx_lon tx_az tx_lat tx_lon v_lat v_lon wspr_cycle_kiwi_overloads_count proxy_upload_this_spot)
         local output_field_name_list_count=${#output_field_name_list[@]}

         local output_field_format_string="%6s %4s %5.2f %6.2f %5.2f %12.7f %-14s %-6s %2d %2d %4d %4d %4d %4d %2d %3d %3d %2d %6.1f %6.1f %4d %6s %12s %5d %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %6.1f %4d %4d"
         local output_field_format_string_list=( ${output_field_format_string} )
         local output_field_format_string_list_count=${#output_field_format_string_list[@]}

         ### It would be even better to verify that the format of the variables' contents match the printf format fields , but this a first layer check
         if [[ ${output_field_format_string_list_count} != ${output_field_name_list_count} ]]; then
             wd_logger 1 "ERROR:  (INTERNAL) output_field_format_string_list_count=${output_field_format_string_list_count} != output_field_name_list_count=${output_field_name_list_count}"
             exit 1
         fi

         ###  Create the list of values which will be passed to printf
         local printf_values_list=()
         local i
         for (( i=0; i < ${output_field_name_list_count}; ++i )) ; do
             local field_name=${output_field_name_list[i]}
             local field_value
             if false && [[ -z ${!field_name+} ]]; then
                 wd_logger 1 "ERROR: there is no field name at output_field_name_list[${i}]"
                 field_value="0"
             else
                 field_value="${!field_name}"
                 wd_logger 2 "Output value for field '${field_name}' with expected format '${output_field_format_string_list[i]}' = ${field_value}"
                 if ! printf ${output_field_format_string_list[i]} ${field_value} >& printf.log ; then
                     wd_logger 1 "ERROR: for field ${i}:, 'printf ${output_field_format_string_list[i]} ${field_value}' returned error $?:$(< printf.log)"
                 fi
             fi
             printf_values_list+=( ${field_value} )
        done
        ### 
        printf "${output_field_format_string}\n" ${printf_values_list[@]}  >> ${cached_spots_file_name}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            local printf_error_output_lines=$(printf ${output_field_format_string} ${printf_values_list[@]})
            wd_logger 1 "ERROR: output printf reports error ${rc}:\n printf ${output_field_format_string} ${printf_values_list[@]}:\n ${printf_error_output_lines}"
        fi
    done < ${real_receiver_wspr_spots_file}

    if [[ ! -s ${cached_spots_file_name} ]]; then
        wd_logger 1 "Found no spots to queue, so queuing zero length spot file"
    else
        wd_logger 1 "Created '${cached_spots_file_name}' of size $(wc -c < ${cached_spots_file_name}) which contains $( wc -l < ${cached_spots_file_name}) spots:\n$(< ${cached_spots_file_name})"
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

declare KA9Q_DEFAULT_CHANNEL_GAIN_DEFAULT="60.0"

declare KA9Q_OUTPUT_DBFS_TARGET="${KA9Q_OUTPUT_DBFS_TARGET--30.0}"                   ### For KA9Q-radio receivers, adjust the channel gain to obtain -15 dbFS in the PCM output stream
declare SOX_OUTPUT_DBFS_TARGET=${SOX_OUTPUT_DBFS_TARGET--10.0}     ### Find the peak RMS level in the last minute wav file and adjust the channel gain so the peak level doesn't overload the next wav file
declare KA9Q_PEAK_LEVEL_SOURCE="${KA9Q_PEAK_LEVEL_SOURCE-WAV}"     ### By default adjust the channel gain from the peak level in the most recent wav file, else use peak level reported by 'metadump'

declare KA9Q_CHANNEL_GAIN_ADJUST_MIN=${KA9Q_CHANNEL_GAIN_ADJUST_MIN-6}               ### Don't adjust if within 6 dB of that level 
declare KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX=${KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX-6}         ### By default increase the channel gain by at most  6 dB at the beginning of each WSPR cycle
declare KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX=${KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX--10}   ### By default decrease the channel gain by at most 10 dB at the beginning of each WSPR cycle

declare ADC_OVERLOADS_LOG_FILE_NAME="./adc_overloads.log"                            ### Per channel log of overload counts and other SDR information
declare SOX_LOG_FILE="./sox.log"                                                     ### The output of sox goes to this file for log printouts and wav file stats

declare SOX_MAX_PEAK_LEVEL="${SOX_MAX_PEAK_LEVEL--1.0}"                              ### Log an ERROR if sox reports the peak level of the wav file it created is greater than this value

function decoding_daemon() {
    local receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local receiver_band=${2}
    local receiver_modes_arg=${3}
    local adc_overloads_print_line_count=0                                 ### Used to determine when to print a  header line in the adc_overloads.log file 
    local ret_code
    local rc

    local receiver_call
    receiver_call=$( get_receiver_call_from_name ${receiver_name} )
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find receiver call from '${receiver_name}"
        return 1
    fi

    local receiver_ip_address
    receiver_ip_address=$(get_receiver_ip_from_name ${receiver_name})
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find receiver IP from '${receiver_name}"
        return 1
    fi

    local receiver_grid
    receiver_grid=$( get_receiver_grid_from_name ${receiver_name} )
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't find receiver grid 'from ${receiver_name}"
        return 1
    fi

    local receiver_freq_khz=$( get_wspr_band_freq_khz ${receiver_band} )
    local receiver_freq_hz=$( echo "scale = 0; ${receiver_freq_khz}*1000.0/1" | bc )

    wd_logger 1 "Given ${receiver_name} ${receiver_band} ${receiver_modes_arg} => receiver_ip_address=${receiver_ip_address}, receiver_call=${receiver_call} receiver_grid=${receiver_grid}, receiver_freq_hz=${receiver_freq_hz}"

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
    get_wsprdaemon_noise_queue_directory  "wsprdaemon_noise_queue_directory" ${receiver_name} ${receiver_band}
    ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: can't get noise file queue directory 'get_wsprdaemon_noise_queue_directory  wsprdaemon_noise_queue_directory ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi
    mkdir -p ${wsprdaemon_noise_queue_directory}
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

    local last_adc_overloads_count=-1     ### Remember the count from 2 minutes ago

    ### Rather than the time and effort for altering the code to work on blocks of 12000 samples to get a 1 Hz quantization Gwynn suggested the alternative is simple scaling: multiply reported frequency for out-of-the-box GPS aided
    ### Kiwi by 12001.1/12000 that is 1.00009167. This is a frequency increase of 0.128 Hz at 1400 Hz and 0.147 Hz at 1600 Hz.
    ### So if  SPOT_FREQ_ADJ_HZ is not blank, then modify the frequency of each spot by that floating point HZ value.  SPOT_FREQ_ADJ_HZ defaults to +.1 Hz which is the audio frequency error of a Kiwi using its internal 66.6666 Mhz oscillator 
    local freq_adj_mhz=0
    if [[ ${receiver_name} =~ KA9Q || -n "${GPS_KIWIS-}"  && ${GPS_KIWIS} =~ ${receiver_name} ]] ; then
        ### One could learn if the Kiwi is GPS controlled from the Kiwi's status page
        wd_logger 2 "No frequency adjustment for this KA9Q RX888 or GPS controlled Kiwi '${receiver_name}'"
    elif [[ -n "${SPOT_FREQ_ADJ_HZ-.1}" ]]; then
        ### The default is to add 0.1 Hz to spot frequencies, or by the value of SPOT_FREQ_ADJ_HZ specified in the wsprdaemon.conf file
        local freq_adj_hz=${SPOT_FREQ_ADJ_HZ-.1}
        freq_adj_hz=${freq_adj_hz/+/}     ## 'bc' doesn't like leading '+' signs in numbers
        freq_adj_mhz=$( echo "scale=9;(${freq_adj_hz} / 1000000)" | bc)
        wd_logger 1 "Because  [[ -n "${SPOT_FREQ_ADJ_HZ-.1}" ]] is TRUE, fixing spot frequencies of receiver '${receiver_name} by ${freq_adj_hz} Hz == ${freq_adj_mhz} MHz"
    else
         wd_logger 1 " [[ ${receiver_name} =~ KA9Q || -n "${GPS_KIWIS-}"  && ${GPS_KIWIS} =~ ${receiver_name} ]] FAILED and [[ -n "${SPOT_FREQ_ADJ_HZ-.1}" ] FAILED so no frequency adjustment for this KIWI"
    fi

    wd_logger 1 "Starting to search for wav files from '${receiver_name}' tuned to WSPRBAND '${receiver_band}'"
    local decoded_spots=0             ### Maintain a running count of the total number of spots_decoded
    local old_wsprd_decoded_spots=0   ### If we are comparing the new wsprd against the old wsprd, then this will count how many were decoded by the old wsprd

    local decoding_dir=$(get_decoding_dir_path ${receiver_name} ${receiver_band})
    cd ${decoding_dir}
    local old_kiwi_ov_count=0

    local my_daemon_pid=$(< ${DECODING_DAEMON_PID_FILE})
    local proc_file=/proc/${my_daemon_pid}/status
    local VmRSS_val=$(awk '/VmRSS/{print $2}' ${proc_file})
    local last_rss_epoch
    wd_logger 2 "At start VmRSS_val=${VmRSS_val} for my PID ${my_daemon_pid} was found in ${PWD}/${DECODING_DAEMON_PID_FILE}"
    if [[ -n "${VM_RSS_LOG_FILENAME-}" ]]; then
        wd_logger 2 "Logging VmRSS_val for my PID ${my_daemon_pid} found in ${PWD}/${DECODING_DAEMON_PID_FILE} and finding VmRSS in ${proc_file} and logging it to ${VM_RSS_LOG_FILENAME-}"
        printf "${WD_TIME_FMT}: %8d\n" -1 ${VmRSS_val} > ${VM_RSS_LOG_FILENAME}
        last_rss_epoch=${EPOCHSECONDS}
    fi

    ### Move declarations of arrays outside the loop
    local mode_wav_file_list=()
    local wav_file_list=()
    local wav_time_list=()

    rm -f "*.wav*"
    shopt -s nullglob
    wd_logger 1 "Looking for decoding client directories in ${PWD}/${DECODING_CLIENTS_SUBDIR}"
    while true; do
        if [[ ! -d ${DECODING_CLIENTS_SUBDIR} ]]; then
            wd_logger 1 "ERROR: while running in ${PWD} can't find expected dir ${DECODING_CLIENTS_SUBDIR}.  So stop trying to decode"
            break;
        fi
        local posting_clients_list=( $(find ${DECODING_CLIENTS_SUBDIR} -maxdepth 1 -type d) )
        if (( ${#posting_clients_list[@]} == 0 )); then
            wd_logger 1 "While running in ${PWD} can't find any posting_client subdirs in ${DECODING_CLIENTS_SUBDIR}.  So stop trying to decode"
            break;
        fi

        VmRSS_val=$(awk '/VmRSS/{print $2}' ${proc_file} )
        wd_logger 2 "My PID ${my_daemon_pid} VmRSS_val=${VmRSS_val}"
        if [[ -n "${VM_RSS_LOG_FILENAME-}" && $(( ${EPOCHSECONDS} - ${last_rss_epoch})) -ge 60  ]]; then
            printf "${WD_TIME_FMT}: %8d\n" -1 "${VmRSS_val}" >> ${VM_RSS_LOG_FILENAME}
            wd_logger 1 "Logged VmRSS_val=${VmRSS_val}"
            last_rss_epoch=${EPOCHSECONDS}
        fi

        wd_logger 1 "Asking for a list of MODE:WAVE_FILE... with: 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'"
        local ret_code
        local mode_seconds_files=""           ### This string will contain 0 or more space-seperated SECONDS:FILENAME_0[,FILENAME_1...] fields 
        get_wav_file_list mode_seconds_files  ${receiver_name} ${receiver_band} ${receiver_modes} 
        ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "Error ${ret_code} returned by 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'. 'sleep 1' and retry"
            sleep 1
            continue
        fi
        mode_wav_file_list=( ${mode_seconds_files} )        ### I tried to pass the name of this array to get_wav_file_list(), but I couldn't get 'eval...' to populate that array
        if [[ ${#mode_wav_file_list[@]} -le 0 ]]; then
            wd_logger 2 "ERROR: get_wav_file_list() returned no error, but it unexpectadly has returned no lists.  So sleep 1 and retry"
            sleep 1
            continue
        fi
        wd_logger 1 "The call 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}' returned lists: '${mode_wav_file_list[*]}'"
        if [[ "${SPAWN_RECORDING_DAEMON-yes}" != "yes" ]]; then
            local mode_seconds
            local seconds_files
            local index
            wd_logger 1 "get_wav_file_list() returned ${#mode_wav_file_list[@]} wspr packet files lists"
            for (( index=0; index < ${#mode_wav_file_list[@]}; ++index )); do
                local mode_seconds="${mode_wav_file_list[index]%%:*}"
                local mode_minutes=$(( mode_seconds / 60 ))
                local mode_files_string=${mode_wav_file_list[index]#*:}
                local mode_files_list=( ${mode_files_string//,/ } )
                if (( ${#mode_files_list[@]} != mode_minutes )); then
                    wd_logger 1 "ERROR:  mode_fileslist[${#mode_files_list[@]}] != mode_minutes=${mode_minutes}, so skip to next mode"
                    continue
                fi
                local file_minutes_list=()
                local one_minutes_list=()
                local minute
                local index2
                for (( index2=0; index2 < ${#mode_files_list[@]}; ++index2 )) ; do
                    local one_minute_file=${mode_files_list[index2]##*/}
                    local file_minute=${one_minute_file:11:2}
                    one_minute_list+=( ${file_minute} )
                    file_minutes_list+=( ${mode_files_list[index2]##*/} )
                done
                wd_logger 1 "We have been given a list of one minute files which together create a ${mode_minutes} minute wspr pkt of minutes '${one_minute_list[*]}': ${file_minutes_list[*]}"
            done
            wd_logger 1 "Report of retuned lists is complete. Go back and call get_wav_file_list() to get new lists"
            continue
        fi
 
        ### We append the count of the A/D overload events in the last 2 minutes to the ADC_OVERLOADS_LOG_FILE_NAME file and add them to the spots reported
        local adc_overloads_count=0        ### Report by radiod and KiwiSDR of the number of OVs since radiod started, a 64 bit number
        local ka9q_rf_gain_float="20.0"   ### Report by radiod of setting it's AGC selected
        local ka9q_adc_dbfs_float="-15.0" ### Report by radiod of measurement of ADC's dbFS which should be -15.0 or lower
        local ka9q_n0_float="-999.99"     ### Report by radio of N0 in dB/Hz
        local ka9q_channel_gain_float="${KA9Q_DEFAULT_CHANNEL_GAIN_DEFAULT}"      ### Setting of radiod 's rx channel gain which can be changed by WD
        local ka9q_channel_output_float="15.0"    ### Report by radiod of the current dbFS level in PCM output stream
        if [[ ${receiver_name} =~ ^KA9Q ]]; then
            ### Get the rx channel status and settings from the metadump output.  The return values have to be individually parsed, so I see only complexity in creating a subroutine for this

            ka9q_get_current_status_value adc_overloads_count ${receiver_ip_address} ${receiver_freq_hz} "A/D overrange:"
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR:  ka9q_get_status_value() => ${rc}"
                adc_overloads_count=0   ## Make sure this is an integer
            else
                adc_overloads_count="${adc_overloads_count//[ ,]}"   ### Remove the space and commas put there by KA9Q's metsdump
                if [[ -z "${adc_overloads_count}" ]] || ! is_uint ${adc_overloads_count} ; then
                    wd_logger 1 "ERROR:  ka9q_get_status_value() returned '${adc_overloads_count}' which is not an unsigned integer"
                    adc_overloads_count=0
                else
                    wd_logger 2 "Metadump reports ${adc_overloads_count} ADC overloads occured since radiod started"
                fi
            fi

            local channel_rf_gain_value
            ka9q_get_current_status_value "channel_rf_gain_value" ${receiver_ip_address} ${receiver_freq_hz} "rf gain"   ### There is also a 'rf gain cal' value in the status file
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                channel_rf_gain_value="-99.9"
                wd_logger 1 "ERROR:  ka9q_get_current_status_value() => ${rc}, so report error rf_gain='${channel_rf_gain_value}'"
            fi
            ka9q_rf_gain_float=${channel_rf_gain_value/dB*/}      ### remove the trailing 'dB' returned by metadump
            ka9q_rf_gain_float=${ka9q_rf_gain_float// /}     ### remove spaces
            wd_logger 1 "ka9q_get_current_status_value() => channel_rf_gain_value='${channel_rf_gain_value}' => ka9q_rf_gain_float='${ka9q_rf_gain_float}'"

            local channel_adc_dbfs_value
            ka9q_get_current_status_value "channel_adc_dbfs_value" ${receiver_ip_address} ${receiver_freq_hz} "IF pwr"
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                channel_adc_dbfs_value="-99.9"
                wd_logger 1 "ERROR:  ka9q_get_current_status_value() => ${rc}, so report error adc_dbfs='${channel_adc_dbfs_value}'"
            fi
            ka9q_adc_dbfs_float=${channel_adc_dbfs_value/dB*/}      ### remove the trailing 'dB' returned by metadump
            ka9q_adc_dbfs_float=${ka9q_adc_dbfs_float// /}     ### remove spaces
            wd_logger 1 "ka9q_get_current_status_value() => channel_adc_dbfs_value='${channel_adc_dbfs_value}' => ka9q_adc_dbfs_float='${ka9q_adc_dbfs_float}'"

            local channel_n0_value
            ka9q_get_current_status_value "channel_n0_value" ${receiver_ip_address} ${receiver_freq_hz} "N0"
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                channel_n0_value="-999.9"
                wd_logger 1 "ERROR:  ka9q_get_current_status_value() => ${rc}, so report error N0='${channel_n0_value}'"
            fi
            ka9q_n0_float=${channel_n0_value/dB*/}   ### remove the trailing 'dB/Hz' returned by metadump
            ka9q_n0_float=${ka9q_n0_float// /}     ### remove spaces
            wd_logger 1 "ka9q_get_current_status_value() => channel_n0_value='${channel_n0_value}' => ka9q_n0_float='${ka9q_n0_float}'"

            local channel_gain_value
            ka9q_get_current_status_value "channel_gain_value" ${receiver_ip_address} ${receiver_freq_hz} "gain"
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                channel_gain_value="60" ### The default in the radiod.conf file
                wd_logger 1 "ERROR:  ka9q_get_current_status_value() => ${rc}, so report default gain='${channel_gain_value}'"
            fi
            ka9q_channel_gain_float=${channel_gain_value/dB*/}   ### remove the trailing ' dB' returned by metadump
            ka9q_channel_gain_float=${ka9q_channel_gain_float// /}   ### remove spaces
            wd_logger 1 "ka9q_get_current_status_value() => channel_gain_value='${channel_gain_value}' => ka9q_channel_gain_float='${ka9q_channel_gain_float}'"

            local channel_output_level_value    ### Report of The output level to the pcm stream and thus ot the wav files.
            ka9q_get_current_status_value "channel_output_level_value" ${receiver_ip_address} ${receiver_freq_hz} "output level"
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                channel_output_level_value="60 dB" ### The default in the radiod.conf file
                wd_logger 1 "ERROR:  ka9q_get_current_status_value() => ${rc}, so report default gain='${channel_output_level_value}'"
            fi
            ka9q_channel_output_float=${channel_output_level_value/dB*/}   ### removed the ' db" returned by metadump
            ka9q_channel_output_float=${ka9q_channel_output_float// /}    ### remove the spaces
            wd_logger 1 "ka9q_get_current_status_value() => channel_output_level_value='${channel_output_level_value}' => ka9q_channel_output_float='${ka9q_channel_output_float}'"

            local first_mode_files=${mode_wav_file_list[0]}     ### each entry has the form:  <MODE_SECONDS>:<WAV_FILE_0>,<WAV_FILE_1>[,<WAV_FILE_.>]
                  first_mode_files=${first_mode_files#*:}        ### Chop off the  <MODE_SECONDS>:
            local first_mode_wav_files_list=( ${first_mode_files//,/ } )
            local newest_one_minute_wav_file=${first_mode_wav_files_list[-1]}

            local sox_stats_list=( $(sox ${newest_one_minute_wav_file} -n stats |&  awk '/Pk lev dB/{printf "%s ", $4};  /RMS Pk dB/{printf "%s ", $4};  /RMS Tr dB/{printf "%s\n", $4}' ) )
            local sox_peak_dBFS_value=${sox_stats_list[0]}   ### Always a float less than 1 with the format '0.xxxx', so chop off the '0.' to convert it to an integer for easy bash compmarisons
            local sox_channel_level_adjust=$(echo "scale=0; (${SOX_OUTPUT_DBFS_TARGET} - ${sox_peak_dBFS_value})/1" | bc ) ### Find the peak RMS level in the last minute wav file and adjust the channel gain so the peak level doesn'
            wd_logger 1 "sox reports the peak dBFS value of the most recent 2 minute wave file '${newest_one_minute_wav_file}' is ${sox_peak_dBFS_value}, so sox suggests a ${sox_channel_level_adjust} dB adjustment in channel gain"
 
            local ka9q_status_ip=""
            ka9q_get_current_status_value "ka9q_status_ip" ${receiver_ip_address} ${receiver_freq_hz} "status dest"
            rc=$?
            ka9q_status_ip="${ka9q_status_ip// /}"     ### Removes any leading or trailing spaces present in the status message
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR:  ka9q_get_current_status_value() => ${rc}, so can't find ka9q_status_ip => can't change output gain with 'tune'"
            elif ! wd_ip_is_valid "${ka9q_status_ip}" && ! [[ "${ka9q_status_ip}" =~ \.local:[0-9] ]]; then
                wd_logger 1 "ERROR: got invalid IP address ka9q_get_current_status_value() => ka9q_status_ip='${ka9q_status_ip}', so can't change output gain with 'tune'"
            else
                wd_logger 1 "ka9q_get_current_status_value() => ka9q_status_ip=${ka9q_status_ip}, so we have the IP address for executing a channel gain adjustment with 'tune' if it is needed"
                local ka9q_channel_level_adjust=$( echo "scale=0; (${KA9Q_OUTPUT_DBFS_TARGET} - ${ka9q_channel_output_float})/1" | bc )
                local channel_level_adjust
                if [[ -n "${last_adc_overloads_count}" && ${last_adc_overloads_count} -eq -1 ]]; then
                    ### We are processing the first WSPR packet
                    wd_logger 1 "Applying the full ka9q_channel_level_adjust channel gain adjustment channel_level_adjust=${ka9q_channel_level_adjust} at startup of WD"
                    channel_level_adjust=${ka9q_channel_level_adjust}
                else
                    ### We are processing the second or subsequent WSPR packet
                    wd_logger 1 "radiod says adjust channel gain by ${ka9q_channel_level_adjust} dB, while sox says adjust by ${sox_channel_level_adjust} dB"
                    if [[ ${KA9Q_PEAK_LEVEL_SOURCE} == "WAV" ]]; then
                        channel_level_adjust=${sox_channel_level_adjust}
                        wd_logger 1 "Using peak RMS level reported by sox to specify the desired channel gain change to be ${channel_level_adjust}"
                    else
                        channel_level_adjust=${ka9q_channel_level_adjust}
                        wd_logger 1 "Using peak RMS level reported by 'metadump' to specify the desired channel gain change to be ${channel_level_adjust}"
                    fi
                    if [[ ${channel_level_adjust} -gt 0 && ${channel_level_adjust#-} -gt ${KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX} ]]; then
                        wd_logger 1 "channel_level_adjust=${channel_level_adjust} up is greater than the max KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX=${KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX}, so limiting gain increase to ${KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX}"
                        channel_level_adjust=${KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX}
                    elif [[ ${channel_level_adjust} -lt 0 && ${channel_level_adjust#-} -lt ${KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX} ]]; then
                        wd_logger 1 "channel_level_adjust=${channel_level_adjust} up is greater than the max KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX=${KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX}, so limiting gain decrease to ${KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX}"
                        channel_level_adjust=${KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX}
                    else
                        wd_logger 1 "channel_level_adjust=${channel_level_adjust} is within the range of ${KA9Q_CHANNEL_GAIN_ADJUST_DOWN_MAX} to ${KA9Q_CHANNEL_GAIN_ADJUST_UP_MAX}, so apply it"
                    fi
                fi
                local new_channel_level=$(echo "scale=0; (${ka9q_channel_gain_float} + ${channel_level_adjust} )/1" | bc)
                wd_logger 1 "A channel gain adjustment of ${channel_level_adjust} dB from ${ka9q_channel_gain_float} dB to ${new_channel_level} dB is needed"

                local change_channel_gain="yes"                    ### By default Channel gain AGC is applied to all channels at the end of each WSPR cycle, including to the WWV/CHU channels at the end of the first cycle
                if [[  ${last_adc_overloads_count} -ne -1 ]]; then
                    ### This is WSPR cycle #2 or later
                    if [[  ${KA9Q_CHANNEL_GAIN_ADJUSTMENT_ENABLED-yes} == "no" ]]; then
                         wd_logger 1 "Changes on all channels are disabled after the first WSPR cycle"
                         change_channel_gain="no"
                    fi
                    if [[ ${receiver_band} =~ ^WWV|^CHU ]]; then
                       if [[ ${KA9Q_WWV_CHANNEL_GAIN_ADJUSTMENT_ENABLED-no} == "no" ]]; then
                           if [[ $( echo "${sox_peak_dBFS_value} > ${KA9Q_WWV_CHANNEL_MAX_DBFS--6.0}" | bc ) == 1 ]]; then
                                wd_logger 1 "Changes on this WWWV/CHU channel '${receiver_band}' are disabled, but the measured sox_peak_dBFS_value=${sox_peak_dBFS_value} is greater than the peak allowed value ${KA9Q_WWV_CHANNEL_MAX_DBFS--6.0}, so reduce the gain"
                            else
                                wd_logger 1 "Changes on this WWWV/CHU channel '${receiver_band}' are disabled after the first WSPR cycle and the measured sox_peak_dBFS_value=${sox_peak_dBFS_value} shows that the wav file isn't overranging"
                                change_channel_gain="no"
                           fi
                       else
                           wd_logger 1 "Changes on this WWWV/CHU channel '${receiver_band}' are enabled after the first WSPR cycle becasue WD.conf contains the line:  KA9Q_WWV_CHANNEL_GAIN_ADJUSTMENT_ENABLE='${KA9Q_WWV_CHANNEL_GAIN_ADJUSTMENT_ENABLED-no}"
                       fi
                    fi
                fi
                if [[ ${change_channel_gain} == "no" ]]; then
                    wd_logger 1 "Channel gain changes are disabled"
                else
                    wd_logger 1 "Changing channel gain to ${new_channel_level}"
                    timeout 5 tune --radio ${ka9q_status_ip} --ssrc ${receiver_freq_hz} --gain ${new_channel_level}
                    rc=$?
                    if [[ ${rc} -ne 0 ]]; then
                        wd_logger 1 "ERROR: 'timeout 5 tune --radio  ${receiver_ip_address} --ssrc ${receiver_freq_hz} --gain ${new_channel_level}i ' => ${rc}"
                    fi
                fi
            fi
            ### End of section which monitors and controls a KA9Q-radio SDR
        elif [[ -f  kiwi_recorder.log ]]; then
            ### Monitor a KiwiSDR
            wd_logger 1 "Getting the new overload count value from the Kiwi '${receiver_name}'"
            get_kiwirecorder_ov_count  adc_overloads_count ${receiver_name}           ### here I'm reusing current_kiwi_ov_count since it also equals the number of OV events since the kiwi started
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'get_kiwirecorder_ov_count  adc_overloads_count ${receiver_name}'  => ${rc}"
            else
                wd_logger 1 "'get_kiwirecorder_ov_count  adc_overloads_count ${receiver_name}'  => ${rc}"
            fi
        else
            wd_logger 1 "Not a KA9Q or KiwiSDR, so there is no overload information"
        fi

        ### Calculate overloads which occured during this WSPR cycle
        local new_sdr_overloads_count=0
        if [[ -z "${last_adc_overloads_count}" || ${last_adc_overloads_count} -eq -1 ]]; then
            wd_logger 1 "This is the first overloads count after startup, so just set last_adc_overloads_count equal to adc_overloads_count=${adc_overloads_count}"
            new_sdr_overloads_count=0
        else
            declare  MAX_ACCEPTABLE_ADC_OVERLOADS_COUNT=${MAX_ACCEPTABLE_ADC_OVERLOADS_COUNT-2147483646}          ### The Timescale field can't store integers larger than this

            new_sdr_overloads_count=$(( ${adc_overloads_count} - ${last_adc_overloads_count} ))
            wd_logger 1 "adc_overloads_count '${adc_overloads_count}' - last_adc_overloads_count '${last_adc_overloads_count}' =>  new_sdr_overloads_count '${new_sdr_overloads_count}'"
            if [[ ${new_sdr_overloads_count} -lt 0 ]]; then
                wd_logger 1 "new_sdr_overloads_count '${new_sdr_overloads_count}' is less than 0, so count has rolled over and just use {adc_overloads_count '${adc_overloads_count}'"
                new_sdr_overloads_count=${adc_overloads_count}
            elif [[  ${new_sdr_overloads_count} -gt ${MAX_ACCEPTABLE_ADC_OVERLOADS_COUNT}  ]]; then
                wd_logger 1 "WARNING: new_sdr_overloads_count=${new_sdr_overloads_count} is greater than MAX_ACCEPTABLE_ADC_OVERLOADS_COUNT=${MAX_ACCEPTABLE_ADC_OVERLOADS_COUNT}, so report that max value"
                new_sdr_overloads_count=${MAX_ACCEPTABLE_ADC_OVERLOADS_COUNT}
            fi
        fi
        ### Extract the time of the first wav file in the first list of wav files (e.e the 2 minute list) and use that time for the wav file time in the first field of the ad-overloads.log file line
        local ov_returned_files=${mode_wav_file_list[0]}
        local ov_comma_separated_files=${ov_returned_files#*:}        ### Chop off the SECONDS: leading the list
        local ov_wav_file_list=( ${ov_comma_separated_files//,/ } )
        local ov_first_input_wav_filename="${ov_wav_file_list[0]:2:6}_${ov_wav_file_list[0]:9:4}.wav"

        if (( ${adc_overloads_print_line_count} % ${ADC_LOG_HEADER_RATE-16} == 0)) ; then
             printf "DATE_TIME          OV_COUNT  NEW_OVs  RF_GAIN     ADC_DBFS        N0   CH_DBFS   CH_GAIN\n"  >> ${ADC_OVERLOADS_LOG_FILE_NAME}
        fi
        (( ++adc_overloads_print_line_count ))
        printf "%s: %10d  %7d    %5.1f        %5.1f    %6.1f     %5.1f     %5.1f\n"  ${ov_first_input_wav_filename} ${adc_overloads_count} ${new_sdr_overloads_count} ${ka9q_rf_gain_float} ${ka9q_adc_dbfs_float} ${ka9q_n0_float} ${ka9q_channel_output_float} ${ka9q_channel_gain_float} >> ${ADC_OVERLOADS_LOG_FILE_NAME}
        truncate_file ${ADC_OVERLOADS_LOG_FILE_NAME} 1000000       ## limit the size of the file

        wd_logger 1 "The SDR reported ${new_sdr_overloads_count} new overload events in this 2 minute cycle"

        last_adc_overloads_count=${adc_overloads_count}

        local returned_files
        for returned_files in ${mode_wav_file_list[@]}; do
            local returned_seconds=${returned_files%:*}
            local returned_minutes=$(( returned_seconds / 60 ))
            local comma_separated_files=${returned_files#*:}
            local wav_files=${comma_separated_files//,/ }
            local wav_files_list=( ${wav_files} )

            wd_logger 1 "For second ${returned_seconds} seconds == ${returned_minutes} minutes got list of ${#wav_files_list[*]} files '${wav_files}'"

            ### This is a block of diagnostic code 
            local  wav_time_list=()                         ### I couldn't get this to work:  $( IFS=$'\n'; cut -c 12-13 <<< "${wav_files_list[@]}") )
            if [[ "${CHECK_WAV_FILES-yes}" == "yes" ]]; then
                local found_all_files="yes"
                local index
                for (( index=0; index < ${#wav_files_list[@]}; ++index )); do
                    local file_to_test=${wav_files_list[${index}]}
                    local file_name=${file_to_test##*/}
                    wav_time_list+=( ${file_name:11:2} )
                    if ! [[ -f ${file_to_test} ]]; then
                        wd_logger 1 "ERROR: minute ${wav_time_list[${index}]} file ${file_to_test} from wav_files_list[${index}] does not exist"
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
            ### End of diagnostic code

            if [[ ${receiver_modes_list[0]} =~ ^[IJK] ]]; then
                wd_logger 1 "We are configured to only record and archive IQ files"
                ### Queue the wav file to a directory in the /dev/shrm/wsprdaemon file system.  The watchdog daemon calls a function every odd minute which
                ### Compresses those wav files into files which are saved in non-volatile storage under ~/wsprdaemon
                if [[ ${#wav_files_list[@]} -ne 1 ]]; then
                    wd_logger 1 "ERROR: IQ recording should return only one 1 minute long file at a time"
                fi
                ### wd-record names all wav files as '_usr.wav' (Upper Sideband), but in this mode the wav file contains IQ sameples
                local iq_file_name=${wav_files_list[0]/_usb.wav/_iq.wav}
                mv ${wav_files_list[0]} ${iq_file_name}
                local wav_file_stat_list=( $(sox ${iq_file_name} -n stat |&  awk '/Samples read/{printf "%s ", $3};  /Maximum amplitude/{printf "%s ", $3};  /Minimum amplitude/{printf "%s\n", $3}' ) )
                local wav_file_stats_list=( $(sox ${iq_file_name} -n stats |&  awk '/Pk lev dB/{printf "%s ", $4};  /RMS Pk dB/{printf "%s ", $4};  /RMS Tr dB/{printf "%s\n", $4}' ) )
                local wav_file_samples=${wav_file_stat_list[0]}            ### Always an integer which should be 1920000
                local wav_file_peak_dBFS_value=${wav_file_stats_list[0]}   ### Always a float less than 1 with the format '0.xxxx', so chop off the '0.' to convert it to an integer for easy bash compmarisons
                local wav_file_RMS_dBFS_value=${wav_file_stats_list[1]}    ### Always a float greatthan -1 with the format '-0.xxxx', so chop off the '-0.' to convert it to an integer for easy bash compmarison   
                local wav_file_RMS_Trough_value=${wav_file_stats_list[2]}  ### Always a float greatthan -1 with the format '-0.xxxx', so chop off the '-0.' to convert it to an integer for easy bash compmarison   

                wd_logger 1 "IQ file INFO: '${iq_file_name}' contains ${wav_file_samples} 16 bit samples. dbFS peak value = ${wav_file_peak_dBFS_value}, RMS_dBFS = ${wav_file_RMS_dBFS_value}, RMS Trough dB = ${wav_file_RMS_Trough_value}"

                local expected_samples
                case ${receiver_modes_list[0]} in
                    I1)
                        expected_samples=${WWV_IQ_SAMPLES_PER_MINUTE-1920000}          ### mode I1 is 16000 sps which is used to record WWV and CHU
                        ;;
                    J1)
                        expected_samples=5760000                                       ### mode J1 is 100000 sps which is used to record SUPERDARN signals
                        ;;
                    K1)
                        expected_samples=960000                                       ### mode K1 is 12000 sps which is used to record N6NC signals
                        ;;
                    *)
                        wd_logger 1 "ERROR: invalid mode ${receiver_modes_list[0]} was specified"
                        wd_rm ${iq_file_name}
                        continue
                        ;;
                esac

                if [[ ${wav_file_samples} -ne ${expected_samples} ]]; then
                    wd_logger 1 "ERROR: IQ file ' ${iq_file_name}' has ${wav_file_samples} samples, not the expected ${expected_samples} samples, so flush it;\n$(sox  ${iq_file_name} -n stat 2>&1 )"
                    wd_rm ${iq_file_name}
                else
                    wd_logger 2 "IQ file ${iq_file_name} has ${wav_file_samples} samples"
                    queue_wav_file ${iq_file_name} ${wav_archive_dir}
                    rc=$?
                    if [[ ${rc} -eq 0 ]]; then
                        wd_logger 1 "Archived wav file ${iq_file_name}"
                    else
                        wd_logger 1 "ERROR: 'queue_wav_file ${iq_file_name}' => $?"
                    fi
                fi
                continue
            fi

            local wav_file_freq_hz=${wav_files_list[0]##*Z_}   ### Remove the year/date/time
            wav_file_freq_hz=${wav_file_freq_hz%_*}         ### Remove the _usb.wav

            local sox_rms_noise_level_float="-999.9"
            local fft_noise_level_float="-999.9"
            local rms_line=""
            local processed_wav_files="no"
            local sox_signals_rms_fft_and_overload_info=""  ### This string will be added on to the end of each spot and will contain:  "rms_noise fft_noise ov_count"
            ### The 'wsprd' and 'jt9' commands require a single wav file, so use 'sox to create one from the list of one minute wav files
            local first_wav_file_name=${wav_files_list[0]##*/}
            local decoder_input_wav_filename="${first_wav_file_name:2:6}_${first_wav_file_name:9:4}.wav"
            local decoder_input_wav_filepath=$(realpath ${decoder_input_wav_filename})

            local sox_effects="${SOX_ASSEMBLE_WAV_FILE_EFFECTS-}"

            wd_logger 1 "sox is creating a 2/5/15/30 minute long wav file ${decoder_input_wav_filepath} using '${sox_effects}' effects"

            ### Concatenate the one minute files to create a single 2/5/15/30 minute file
            local rc
            sox ${wav_files_list[@]} ${decoder_input_wav_filepath} ${sox_effects} >& ${SOX_LOG_FILE}
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: 'sox ${wav_files_list[*]} ${decoder_input_wav_filepath}  ${sox_effects} -n stat' => ${rc}:\n$(<  ${SOX_LOG_FILE})"
                if [[ -f ${decoder_input_wav_filepath} ]]; then
                    local rc1
                    wd_rm ${decoder_input_wav_filepath}
                    rc1=$?
                    if [[ ${rc1} -ne 0 ]]; then
                        wd_logger 1 "ERROR: after sox returned error ${rc}, then 'wd_rm ${decoder_input_wav_filepath} returned error ${rc1}"
                    fi
                fi
                sleep 1
                continue
            fi
            wd_logger 1 "sox created ${decoder_input_wav_filepath} from ${#wav_files_list[@]} one minute wav files"

            ### Get statistics about the newly created wav file
            sox ${decoder_input_wav_filepath} -n stats >& ${SOX_LOG_FILE}
            local sox_peak_level_db_float=$(awk '/^Pk lev/{print $NF}' ${SOX_LOG_FILE})
            rc=$( echo "${sox_peak_level_db_float} > ${SOX_MAX_PEAK_LEVEL}" | bc )
            if [[ ${rc} -eq 1 ]]; then
                wd_logger 1 "ERROR: sox reports a wav file overrange: $( awk '/^Pk lev/ || /RMS/ { printf "%s, ", $0 }' ${SOX_LOG_FILE})"
            else
                wd_logger 1 "sox created a wav file with these characteristics:  $( awk '/^Pk lev/ || /RMS/ { printf "%s, ", $0 }' ${SOX_LOG_FILE})"
            fi

            ### To mimnimize the amount of Linux process schedule thrashing, limit the number of active decoding jobs to the number of physical CPUs
            local got_cpu_semaphore=""
            if [[ ${DECODING_FREE_CPUS-0} -eq 0 ]]; then
                wd_logger 2 "We are not configured to limit the number of active decoding CPUs"
            else
                wd_logger 1 "We are configured to limit the number of active decoding CPUs to ${DECODING_FREE_CPUS}"
                local max_running_decodes
                max_running_decodes=$(( $(nproc) - ${DECODING_FREE_CPUS} ))
                if [[ ${max_running_decodes} -lt 1 ]] ; then
                    wd_logger 1 "ERROR: configured value DECODING_FREE_CPUS=${DECODING_FREE_CPUS} would leave none of the $(nproc) cpus free to run WSPR decodes.  So setting max_running_decodes to 1 cpu"
                    max_running_decodes=1
                else
                    wd_logger 1 "The configured value DECODING_FREE_CPUS=${DECODING_FREE_CPUS} on this CPU with $(nproc) cores has resulted in max_running_decodes=${max_running_decodes}"
                fi
                local max_job_wait_secs=${DECODE_CPU_MAX_WAIT_SECS-60}   ### Proceed with decoding after 60 seconds whether or not there is a free CPU
                claim_cpu ${max_running_decodes} ${max_job_wait_secs}
                rc=$?
                if [[ ${rc} -eq 0 ]]; then
                    got_cpu_semaphore="yes"
                    wd_logger 1 "Got semaphore and so can start decoding"
                else
                    got_cpu_semaphore="no"
                    wd_logger 1 "ERROR: 'claim_cpu ${max_running_decodes} ${max_job_wait_secs}' => ${rc}, but start decoding anyway"
                fi
            fi

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

                local wsprd_flags="${WSPRD_CMD_FLAGS}"
                local wsprd_spreading_flags="${wsprd_flags}"
                if [[ ${#receiver_modes_list[@]} -eq 1 && ${receiver_modes_list[0]} == "W0" ]]; then
                    wsprd_flags="${WO_WSPSRD_CMD_FLAGS-${DEFAULT_WO_WSPSRD_CMD_FLAGS}}"
                    wsprd_spreading_flags="${wsprd_flags}"
                    wd_logger 1 "Decoding mode W0, so run 'wsprd ${wsprd_flags}"
                fi

                cd ${decode_dir}

                ### wsprd get the spotline date/time from the filename, so we can't pass the full filepath to wsprd
                ln ${decoder_input_wav_filepath} ${decoder_input_wav_filename} 

                local start_time=${SECONDS}
                decode_wspr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt "${wsprd_flags}" "${wsprd_spreading_flags}"
                local ret_code=$?

                rm  ${decoder_input_wav_filename}
                cd - >& /dev/null
                ### Back to recording directory

                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds. For mode W_${returned_seconds}: 'decode_wspr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt' => ${ret_code}"
                else
                    if [[ ! -s ${decode_dir}/ALL_WSPR.TXT.new ]]; then
                        wd_logger 1 "wsprd found no spots"
                    else
                        wd_logger 1 "wsprd decoded $(wc -l < ${decode_dir}/ALL_WSPR.TXT.new) spots:\n$(< ${decode_dir}/ALL_WSPR.TXT.new)"
                        awk -v pkt_mode=${returned_minutes} '{printf "%s %s\n", $0, pkt_mode}' ${decode_dir}/ALL_WSPR.TXT.new  >> decodes_cache.txt                       ### Add the wspr pkt mode (== 2 or 15 minutes) to each ALL_WSPR.TXT spot line
                    fi

                    local sdr_noise_level_adjust_float=""
                    if [[ "${ka9q_channel_gain_float}" != "${KA9Q_DEFAULT_CHANNEL_GAIN_DEFAULT}" ]]; then
                        sdr_noise_level_adjust_float=$( echo "scale=1; (${ka9q_channel_gain_float} - ${KA9Q_DEFAULT_CHANNEL_GAIN_DEFAULT})/1" | bc )
                        wd_logger 1 "Adjust the FFT/C2 and RMS data by (ka9q_channel_gain_float=${ka9q_channel_gain_float} - KA9Q_DEFAULT_CHANNEL_GAIN_DEFAULT-${KA9Q_DEFAULT_CHANNEL_GAIN_DEFAULT}) = ${sdr_noise_level_adjust_float}"
                    fi

                    ### Output a noise line  which contains 'DATE TIME + three sets of four space-separated statistics'i followed by the two FFT values followed by the approximate number of overload events recorded by a Kiwi during this WSPR cycle:
                    ###                           Pre Tx                                                        Tx                                                   Post TX
                    ###     'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'        'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'       'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB      RMS_noise C2_noise  New_overload_events'
                    local c2_filename="${decode_dir}/000000_0001.c2" ### -c instructs wsprd to create the C2 format file "000000_0001.c2"
                    if [[ ! -f ${C2_FFT_CMD} ]]; then
                        wd_logger 0 "Can't find the '${C2_FFT_CMD}' script"
                        exit 1
                    fi
                    local c2_fft_noise_level_float
                    local ret_code
                    nice -n ${WSPR_CMD_NICE_LEVEL} python3 ${C2_FFT_CMD} ${c2_filename} > ${c2_filename}.out 2> ${c2_filename}.stderr
                    ret_code=$?
                    if [[ ${ret_code} -eq 0 ]]; then
                        c2_fft_noise_level_float=$(< ${c2_filename}.out)
                   else
                        wd_logger 1 "ERROR: 'python3 ${C2_FFT_CMD} ${c2_filename}' => ${ret_code}:\n$(< ${c2_filename}.stderr)"
                        c2_fft_noise_level_float="0.0"
                    fi
                    fft_noise_level_float=$(bc <<< "scale=2;var=${c2_fft_noise_level_float};var+=${fft_nl_adjust};(var * 100)/100")
                    if [[ -n "${sdr_noise_level_adjust_float}" ]]; then
                        local corrected_fft_noise_level_float
                        corrected_fft_noise_level_float=$( echo "scale=1;(${fft_noise_level_float} - ${sdr_noise_level_adjust_float})/1" | bc )
                        wd_logger 1 "Correcting measured FFT noise from ${fft_noise_level_float} to ${corrected_fft_noise_level_float}"
                        fft_noise_level_float=${corrected_fft_noise_level_float}
                    fi
                    wd_logger 1 "fft_noise_level_float=${fft_noise_level_float} which is calculated from 'local fft_noise_level_float=\$(bc <<< 'scale=2;var=${c2_fft_noise_level_float};var+=${fft_nl_adjust};var/=1;var')"
 
                    get_rms_levels  "sox_rms_noise_level_float" "rms_line" ${decoder_input_wav_filename} ${rms_nl_adjust}
                    ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR:  'get_rms_levels  sox_rms_noise_level_float rms_line ${decoder_input_wav_filename} ${rms_nl_adjust}' => ${ret_code}"
                        return 1
                    fi
                    if [[ -n "${sdr_noise_level_adjust_float}" ]]; then
                        local corrected_sox_rms_noise_level_float
                        corrected_sox_rms_noise_level_float=$( echo "scale=1;(${sox_rms_noise_level_float} - ${sdr_noise_level_adjust_float})/1" | bc )
                        wd_logger 1 "Correcting measured FFT noise from ${sox_rms_noise_level_float} to ${corrected_sox_rms_noise_level_float}"
                        sox_rms_noise_level_float=${corrected_sox_rms_noise_level_float}

                        wd_logger 1 "Sox reports rms_line '${rms_line}'"
                        local adjusted_rms_line=""
                        for rms_value_float in ${rms_line} ; do
                            local adjusted_rms_value_float
                            adjusted_rms_value_float=$(echo "scale=2;(${rms_value_float} - ${sdr_noise_level_adjust_float})/1" | bc )
                            adjusted_rms_line="${adjusted_rms_line} ${adjusted_rms_value_float}"
                        done
                        wd_logger 1 "Adjusted rms_line to '${adjusted_rms_line}'"
                        rms_line="${adjusted_rms_line}"
                    fi
                    wd_logger 1 "sox_rms_noise_level_float=${sox_rms_noise_level_float}"

                    ### The two noise levels and the count of A/D overloads will be added to the extended spots record
                    sox_signals_rms_fft_and_overload_info="${rms_line} ${fft_noise_level_float} ${new_sdr_overloads_count}"

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

                touch ${decode_dir_path}/plotspec ${decode_dir_path}/decdata        ### Instructs jt9 to output spectral width information to jt9_output.txt and append extended resolution spot lines to fst4_decodes.dat 
                local old_fst4_decodes_dat_last_spot
                if [[ ! -s ${decode_dir_path}/fst4_decodes.dat ]] ; then
                    wd_logger 2 "There is no file '${decode_dir_path}/fst4_decodes.dat', so there have been no previous successful FST4W decodes"
                    old_fst4_decodes_dat_last_spot=""
                else
                    old_fst4_decodes_dat_last_spot=$(tail -n 1 ${decode_dir_path}/fst4_decodes.dat)
                    wd_logger 2 "Found last spot previously decoded which is found in file '${decode_dir_path}/fst4_decodes.dat':\n${old_fst4_decodes_dat_last_spot}"
                fi

                local rc
                local start_time=${SECONDS}
                ln ${decoder_input_wav_filepath} ${decode_dir_path}/${decoder_input_wav_filename}
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'ln ${decoder_input_wav_filepath} ${decode_dir_path}/${decoder_input_wav_filename}' => ${rc}"   ### This will be logged in the './F_xxx' sub directory
                else
                    ### Don't linger in that F_xxx subdir, since wd_logger ... would get logged there
                    cd ${decode_dir_path}
                    timeout ${WSPRD_TIMEOUT_SECS-110} nice -n ${JT9_CMD_NICE_LEVEL} ${JT9_CMD} -a ${decode_dir_path} -p ${returned_seconds} --fst4w  -p ${returned_seconds} -f 1500 -F 100 ${decoder_input_wav_filename} >& jt9_output.txt
                    rc=$?
                    cd - >& /dev/null
                    ### Out of the subdir
                fi
                local rc1
                wd_rm ${decode_dir_path}/${decoder_input_wav_filename}
                rc1=$?
                if [[ ${rc1} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'wd_rm ${decode_dir_path}/${decoder_input_wav_filename}' => ${rc1}"
                fi

                if [[ ${rc} -ne 0 ]]; then
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
                            sox_rms_noise_level_float="-999.0"
                            fft_noise_level_float="-999.0"
                        fi

                        ### Get new high resolution spot lines appended by jt9 to fst4_decodes.dat, a log file like ALL_WSPR.TXT where jt9 appends spot lines
                        > ${decode_dir_path}/high_res_fst4w_spots.txt          ### create or truncate 
                        if [[ ! -s ${decode_dir_path}/fst4_decodes.dat ]]; then
                            wd_logger  1 "ERROR: jt9 found the spots written to file '${decode_dir_path}/decoded.txt', but can't find the file or spot lines in the file '${decode_dir_path}/fst4_decodes.dat'"
                        else
                            wd_logger  2 "Extracting new FST4W spots expected to be in '${decode_dir_path}/fst4_decodes.dat'"
                            if [[ -z "${old_fst4_decodes_dat_last_spot}" ]]; then
                                wd_logger 1 "There were no old FST4W spots, so all spots in ${decode_dir_path}/fst4_decodes.dat are new spots:\n$(<${decode_dir_path}/fst4_decodes.dat)"
                                ### This sed expression fixes lines output by jt9 where the $16 = 'sync' value overflows the width of the  wh
                                sed 's/./& /56;s/\*\*\*\*\*\*\*\*\*/999999.99/' ${decode_dir_path}/fst4_decodes.dat > ${decode_dir_path}/new_fst4w_decodes.dat 
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
                                        wd_logger 2 "Found these newly decoded FST4W high res spot lines:\n$(< ${decode_dir_path}/new_fst4w_decodes.dat)"
                                        ### This sed expression fixes lines output by jt9 where the $16 = 'sync' value overflows the width of the field and as a result mereges with field $14.
                                        sed -i 's/./& /56;s/\*\*\*\*\*\*\*\*\*/999999.99/' ${decode_dir_path}/new_fst4w_decodes.dat 
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
                                    'NF == 21 || NF == 22 {printf "%6s %4s %5.1f %5.2f %12.7f %-22s 0 %2d     0   0   0   0   %2d   0   0 %6.3f %s\n", spot_date, spot_time, $16, $17, (wav_file_freq_hz + $18) / 1000000, $20 " " $21 " " $22, $10, $11, $19, pkt_mode}' \
                                    ${decode_dir_path}/new_fst4w_decodes.dat > ${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt
                            if [[ -s ${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt ]]; then
                                wd_logger  2 "Reformatted high resolution FST4W type 1 and/or type 3 spots to:\n$(<${decode_dir_path}/hi_res_fst4w_type1_and_type3_spots.txt)"
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
                                wd_logger  2 "Found some low res FST4W spot lines in '${decode_dir_path}/jt9_output.txt':\n$(< ${decode_dir_path}/jt9_output.txt)"
                                mv ${decode_dir_path}/decoded.tmp ${decode_dir_path}/jt9_output.txt
                            fi
                            if [[ ! -s ${decode_dir_path}/jt9_output.txt ]]; then
                                wd_logger  1 "After filtering out '<...>' spot lines, found no low res FST4W spot lines in '${decode_dir_path}/jt9_output.txt'"
                            else
                                wd_logger  2 "Formatting $(wc -l < ${decode_dir_path}/jt9_output.txt) spots found in '${decode_dir_path}/jt9_output.txt'"
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
                                    wd_logger  2 "ERROR: Dumping bad FST4W spots (i.e. NF != 9 or 10):\n$(<${decode_dir_path}/fst4w_bad_spots.txt)"
                                fi
                                cat ${decode_dir_path}/fst4w_type1_and_type3_spots.txt ${decode_dir_path}/fst4w_type2_spots.txt > ${decode_dir_path}/low_res_fst4w_spots.txt
                                wd_logger  2 "Found low res FST4W spots:\n$(< ${decode_dir_path}/low_res_fst4w_spots.txt)"
                          fi
                        fi
                        ### Done formatting low res FST4W spots

                        ### Log the spots we have found.
                        if [[ -s ${decode_dir_path}/decoded.txt ]]; then
                            ### We use the spot information in jt9_output.txt which includes the sprectral width, so don't normally log it
                            wd_logger  2 "FST4W spots in decoded.txt:          \n$(awk '{printf "%d FIELDS: %s\n", NF, $0}' ${decode_dir_path}/decoded.txt)"
                        fi
                        if [[ -s ${decode_dir_path}/low_res_fst4w_spots.txt ]]; then
                            wd_logger  2 "The formatted FST4W  low resolution spots found in '${decode_dir_path}/low_res_fst4w_spots.txt':\n$(< ${decode_dir_path}/low_res_fst4w_spots.txt)"
                        fi
                        if [[ -s ${decode_dir_path}/high_res_fst4w_spots.txt ]] ; then
                            wd_logger  2 "The formatted FST4W high resolution spots found in '${decode_dir_path}/high_res_fst4w_spots.txt':\n$(< ${decode_dir_path}/high_res_fst4w_spots.txt)"
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

            if [[ ${got_cpu_semaphore} == "yes" ]]; then
                free_cpu
                rc=$?
                if [[ ${rc} -eq 0 ]]; then
                    wd_logger 1 "Put semaphore now that decoding is done"
                else
                    wd_logger 1 "ERROR: 'free_cpu' => ${rc}, but ignoring since decoding is done"
                fi
            fi

            ### Check the value of ARCHIVE_WAV_FILES in the conf file each time we are finished decoding
            local config_archive_wav_files
            get_config_file_variable config_archive_wav_files "ARCHIVE_WAV_FILES"

            if [[ "${config_archive_wav_files}" != "yes" ]]; then
                local rc
                wd_rm ${decoder_input_wav_filepath}
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'wd_rm ${decoder_input_wav_filepath}' => ${rc}"
                fi
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

            ### Obtain wav and ADC overlaod information so they can be appended to the spot lines
            wd_logger 1 "Flushing wav stats file ${decoder_input_wav_filepath}.stats"
            if [[ -f ${decoder_input_wav_filepath}.stats ]]; then
                local rc
                wd_rm ${decoder_input_wav_filepath}.stats
                rc=$?
                if [[ ${rc} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'wd_rm ${decoder_input_wav_filepath}.stats' => ${rc}"
                fi
            fi

            ### Record the 12 signal levels + rms_noise + fft_noise + new_overloads to the ../signal_levels/...csv log files
            local wspr_decode_capture_date=${wav_files_list[0]##*/}
                  wspr_decode_capture_date=${wspr_decode_capture_date%T*}
                  wspr_decode_capture_date=${wspr_decode_capture_date:2:6}      ## chop off the '20' from the front to get YYMMDD
            local wspr_decode_capture_time=${wav_files_list[0]##*/}
                  wspr_decode_capture_time=${wspr_decode_capture_time#*T}
                  wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
            local wspr_decode_capture_freq_hz=${wav_files_list[0]##*Z_}
                  wspr_decode_capture_freq_hz=${wspr_decode_capture_freq_hz%_*}
                  wspr_decode_capture_freq_hz=$( bc <<< "${wspr_decode_capture_freq_hz} + (${rx_khz_offset} * 1000)" )

            ### Log the noise for the noise_plot which generates the graphs, and create a time-stamped file with all the noise data for upload to wsprdaemon.org
            wd_logger 2 "Execute: queue_noise_signal_levels_to_wsprdaemon  '${wspr_decode_capture_date}' '${wspr_decode_capture_time}' '${sox_signals_rms_fft_and_overload_info}' '${wspr_decode_capture_freq_hz}' '${signal_levels_log_file}' '${wsprdaemon_noise_queue_directory}'"
            queue_noise_signal_levels_to_wsprdaemon  ${wspr_decode_capture_date} ${wspr_decode_capture_time} "${sox_signals_rms_fft_and_overload_info}" ${wspr_decode_capture_freq_hz} ${signal_levels_log_file} ${wsprdaemon_noise_queue_directory}

            ### Record the spots in decodes_cache.txt plus the sox_signals_rms_fft_and_overload_info to wsprdaemon.org
            ### The start time and frequency of the spot lineszz will be extracted from the first wav file of the wav file list
            wd_logger 2 "Execute: create_enhanced_spots_file_and_queue_to_posting_daemon   'decodes_cache.txt' '${wspr_decode_capture_date}' '${wspr_decode_capture_time}' '${sox_rms_noise_level_float}' '${fft_noise_level_float}' '${new_sdr_overloads_count}' '${receiver_call}' '${receiver_grid}' '${freq_adj_mhz}'"
            create_enhanced_spots_file_and_queue_to_posting_daemon   "decodes_cache.txt" ${wspr_decode_capture_date} ${wspr_decode_capture_time} "${sox_rms_noise_level_float}" "${fft_noise_level_float}" "${new_sdr_overloads_count}" ${receiver_call} ${receiver_grid} ${freq_adj_mhz}
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
    local decoding_dir=$(get_decoding_dir_path ${receiver_name} ${receiver_band})

    mkdir -p ${decoding_dir}/${DECODING_CLIENTS_SUBDIR}     ### The posting_daemon() should have created this already
    cd ${decoding_dir}
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

    local decoding_dir=$(get_decoding_dir_path ${receiver_name} ${receiver_band})

    if [[ ! -d ${decoding_dir} ]]; then
        wd_logger 1 "ERROR: ${decoding_dir} for '${receiver_name},${receiver_band},${receiver_modes}' does not exist"
        return 1
    fi

    local decoding_pid_file=${decoding_dir}/${DECODING_DAEMON_PID_FILE}
 
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
    local get_decoding_status_receiver_decoding_dir=$(get_decoding_dir_path ${get_decoding_status_receiver_name} ${get_decoding_status_receiver_band})
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

### Stores the number of CPUs currently running decode jobs
declare ACTIVE_DECODING_CPU_DIR="${WSPRDAEMON_TMP_DIR}/recording.d"
mkdir -p ${ACTIVE_DECODING_CPU_DIR}   ### Just to be sure

declare ACTIVE_DECODING_CPU_SEMAPHORE_NAME="active_cpus"
declare ACTIVE_DECODING_CPU_COUNT_FILE="${ACTIVE_DECODING_CPU_DIR}/active_cpus_count"

function active_decoding_cpus_init()
{
    echo "0" > ${ACTIVE_DECODING_CPU_COUNT_FILE}
}

### 
### This waits until it gets the semaphore and then tests and increments the value in 'active_count' which is the number of running decodes
function claim_cpu()
{
    local semaphore_max_count=$1
    local semaphore_timeout=$2        ### How many seconds to wait

    local start_epoch=${EPOCHSECONDS}
    local end_epoch=$(( ${start_epoch} + ${semaphore_timeout} ))

    local semaphore_count_filename=${ACTIVE_DECODING_CPU_COUNT_FILE}

    wd_logger 1 "Starting an attempt to get one of the ${semaphore_max_count} semaphores in ${ACTIVE_DECODING_CPU_DIR}. Timeout after ${semaphore_timeout} seconds"

    while [[ ${EPOCHSECONDS} -lt ${end_epoch} ]]; do
        local rc
        wd_mutex_lock ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} ${ACTIVE_DECODING_CPU_DIR}
        rc=$?
        if [[ ${rc} -ne 0 ]] ; then
            wd_logger 1 "ERROR: timeout after waiting to get mutex within its default ${MUTEX_DEFAULT_TIMEOUT} seconds, but try again"
        else
            wd_logger 2 "Got ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} in dir ${ACTIVE_DECODING_CPU_DIR} mutex"
            if [[ ! -f ${semaphore_count_filename} ]]; then
                wd_logger 1 "Creating ${semaphore_count_filename} with count of 0" 
                echo "0" > ${semaphore_count_filename}
            fi
            local current_semaphore_count=$(< ${semaphore_count_filename})
            local new_semaphore_count=-1
            if [[ ${current_semaphore_count} -lt ${semaphore_max_count} ]]; then
                new_semaphore_count=$(( current_semaphore_count + 1 ))
                echo ${new_semaphore_count} > ${semaphore_count_filename}
            fi
            wd_mutex_unlock ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} ${ACTIVE_DECODING_CPU_DIR}
            rc=$?
            if [[ ${rc} -eq 0 ]]; then
                wd_logger 2 "Freed ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} in dir ${ACTIVE_DECODING_CPU_DIR} mutex"
            else
                wd_logger 1 "ERROR: When freeing ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} in dir ${ACTIVE_DECODING_CPU_DIR} muxtex, got unexpected error from 'wd_mutex_unlock ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} ${ACTIVE_DECODING_CPU_DIR}' => ${rc}"
            fi
            if [[ ${new_semaphore_count} -gt 0 ]]; then
                wd_logger 1 "Current semaphone count ${current_semaphore_count} was less than max value ${semaphore_max_count}, so saved new count ${new_semaphore_count} and returning to caller"
                return 0
            else
                wd_logger 2 "Current semaphone count ${current_semaphore_count} is greater than or equal to the max value ${semaphore_max_count}. So sleep and try again"
            fi
        fi
        wd_logger 2 "Sleeping 1 second"
        sleep 1
    done
    wd_logger 1 "ERROR: timeout after ${semaphore_timeout} seconds while waiting to get semaphore"
    return 1
}

### Decrements the semaphore count and returns
function free_cpu()
{
    local semaphore_count_filename=${ACTIVE_DECODING_CPU_COUNT_FILE}

    local rc
    wd_mutex_lock ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} ${ACTIVE_DECODING_CPU_DIR} 
    rc=$?
    if [[ ${rc} -ne 0 ]] ; then
        wd_logger 1 "ERROR: timeout after waiting to get mutex since we should get it within its default ${MUTEX_DEFAULT_TIMEOUT} seconds"
        return 1
    else
        wd_logger 1 "Got ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} in dir ${ACTIVE_DECODING_CPU_DIR} mutex"
        if [[ ! -f ${semaphore_count_filename} ]]; then
            wd_logger 1 "ERROR: expected count file ${semaphore_count_filename} does not exist, so wd_semaphore_pget() never ran" 
        else
            local current_semaphore_count=$(< ${semaphore_count_filename})
            if [[ ${current_semaphore_count} -lt 1 ]]; then
                wd_logger 1 "ERROR: found current count ${current_semaphore_count} is less than the expected >= 1"
            else
                (( --current_semaphore_count ))
                echo ${current_semaphore_count} > ${semaphore_count_filename}
            fi
        fi
        wd_mutex_unlock ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} ${ACTIVE_DECODING_CPU_DIR}
        rc=$?
        if [[ ${rc} -eq 0 ]]; then
            wd_logger 1 "Decremented semaphore count to ${current_semaphore_count} and returning"
        else
            wd_logger 1 "ERROR: unexpected error from 'wd_mutex_unlock ${ACTIVE_DECODING_CPU_SEMAPHORE_NAME} ${ACTIVE_DECODING_CPU_DIR}' => ${rc}, but anyway decremented semaphore count to ${current_semaphore_count} and returning"
        fi
        return 0
    fi
    ### Should neveer get here
}
