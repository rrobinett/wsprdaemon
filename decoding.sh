#!/bin/bash 

############## Decoding ################################################
### For each real receiver/band there is one decode daemon and one recording daemon
### Waits for a new wav file then decodes and posts it to all of the posting lcient


declare -r DECODING_CLIENTS_SUBDIR="decoding_clients.d"     ### Each decoding daemon will create its own subdir where it will copy YYMMDD_HHMM_wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                            ### Delete the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..
declare FFT_WINDOW_CMD=${WSPRDAEMON_ROOT_DIR}/wav_window.py

declare C2_FFT_ENABLED="yes"          ### If "yes", then use the c2 file produced by wsprd to calculate FFT noisae levels
declare C2_FFT_CMD=${WSPRDAEMON_ROOT_DIR}/c2_noise.py

#########
### For future reference, here are the spot file output lines for ALL_WSPR.TXT and wspr_spots.txt taken from the wsjt-x 2.1-2 source code:
# In WSJT-x v 2.2, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
# fprintf(fall_wspr, "%6s              %4s                                      %3.0f          %5.2f           %11.7f               %-22s                    %2d            %5.2f                          %2d                   %2d                %4d                    %2d                  %3d                   %5u                %5d\n",
# NEW     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].sync,          decodes[i].ipass+1, decodes[i].blocksize, decodes[i].jitter, decodes[i].decodetype, decodes[i].nhardmin, decodes[i].cycles/81, decodes[i].metric);
# fprintf(fall_wspr, "%6s              %4s                        %3d           %3.0f          %5.2f           %11.7f               %-22s                    %2d                        %5u                                      %4d                %4d                                                      %4d                        %2u\n",
# OLD     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, (int)(10*decodes[i].sync),                    decodes[i].blocksize, decodes[i].jitter,                                             decodes[i].cycles/81, decodes[i].metric);
# OLD                                                                                                                                                                                     , decodes[i].osd_decode);
# OLD     decodes[i].date, decodes[i].time, (int)(10*decodes[i].sync), decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift,                                      decodes[i].cycles/81, decodes[i].jitter, decodes[i].blocksize, decodes[i].metric, decodes[i].osd_decode);
# 
# In WSJT-x v 2.1, the wsprd decoder was enhanced.  That new wsprd can be detected because it outputs 17 fields to each line of ALL_WSPR.TXT
# fprintf(fall_wspr, "%6s %4s %3d %3.0f %5.2f %11.7f %-22s %2d %5u   %4d %4d %4d %2u\n",
#          decodes[i].date, decodes[i].time, (int)(10*decodes[i].sync), decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].cycles/81, decodes[i].jitter,decodes[i].blocksize,decodes[i].metric,decodes[i].osd_decode);
#
# The lines of wsprd_spots.txt are the same in all versions
#   fprintf(fwsprd, "%6s %4s %3d %3.0f %4.1f %10.6f  %-22s %2d %5u %4d\n",
#            decodes[i].date, decodes[i].time, (int)(10*decodes[i].sync), decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].cycles/81, decodes[i].jitter);

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

### these could be modified from these default values by declaring them in the .conf file.
declare    SIGNAL_LEVEL_PRE_TX_SEC=${SIGNAL_LEVEL_PRE_TX_SEC-.25}
declare    SIGNAL_LEVEL_PRE_TX_LEN=${SIGNAL_LEVEL_PRE_TX_LEN-.5}
declare    SIGNAL_LEVEL_TX_SEC=${SIGNAL_LEVEL_TX_SEC-1}
declare    SIGNAL_LEVEL_TX_LEN=${SIGNAL_LEVEL_TX_LEN-109}
declare    SIGNAL_LEVEL_POST_TX_SEC=${SIGNAL_LEVEL_POST_TX_LEN-113}
declare    SIGNAL_LEVEL_POST_TX_LEN=${SIGNAL_LEVEL_POST_TX_LEN-5}

function setup_signal_levels_log_file() {
    local return_signal_levels_log_file_variable_name=$1   ### Return the full path to the log file which will be added to during each wspr packet decode 
    local receiver_name=$2
    local receiver_band=$3

    local signal_level_logs_dir=${WSPRDAEMON_ROOT_DIR}/signal_levels/${receiver_name}/${receiver_band}
    mkdir -p ${signal_level_logs_dir}

    local local_signal_levels_log_file=${signal_level_logs_dir}/signal-levels.log
    eval ${return_signal_levels_log_file_variable_name}=${local_signal_levels_log_file}

    if [[ -f ${local_signal_levels_log_file} ]]; then
        wd_logger 2 "Signal Level log file '${local_signal_levels_log_file}' exists, so leave it alone"
        return 0
    fi
    local  pre_tx_header="Pre Tx (${SIGNAL_LEVEL_PRE_TX_SEC}-${SIGNAL_LEVEL_PRE_TX_LEN})"
    local  tx_header="Tx (${SIGNAL_LEVEL_TX_SEC}-${SIGNAL_LEVEL_TX_LEN})"
    local  post_tx_header="Post Tx (${SIGNAL_LEVEL_POST_TX_SEC}-${SIGNAL_LEVEL_POST_TX_LEN})"
    local  field_descriptions="    'Pk lev dB' 'RMS lev dB' 'RMS Pk dB' 'RMS Tr dB'    "
    local  date_str=$(date)

    printf "${date_str}: %20s %-55s %-55s %-55s FFT\n" "" "${pre_tx_header}" "${tx_header}" "${post_tx_header}"   >  ${local_signal_levels_log_file}
    printf "${date_str}: %s %s %s\n" "${field_descriptions}" "${field_descriptions}" "${field_descriptions}"      >> ${local_signal_levels_log_file}

    wd_logger 1 "Setup header line in a new Signal Level log file '${local_signal_levels_log_file}'"
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

function get_rms_levels() {
    local return_var_name=$1
    local return_string_name=$2
    local wav_filename=$3
    local rms_adjust=$4
    local i

    if [[ ! -s ${wav_filename} ]]; then
        wd_logger 1 "ERROR: no wav file ${wav_filename}"
        return 1
    fi

    # Get RMS levels from the wav file and adjuest them to correct for the effects of the LPF on the Kiwi's input
    local raw_pre_tx_levels=($(sox ${wav_filename} -t wav - trim ${SIGNAL_LEVEL_PRE_TX_SEC} ${SIGNAL_LEVEL_PRE_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
    local wd_arg=$(printf "Got ${#raw_pre_tx_levels[@]} raw_pre_tx_levels: '${raw_pre_tx_levels[*]}'")
    wd_logger 2 "${wd_arg}"
    local pre_tx_levels=()
    for (( i=0; i < ${#raw_pre_tx_levels[@]} ; ++i )); do 
        pre_tx_levels[${i}]=$(bc <<< "scale = 2; (${raw_pre_tx_levels[${i}]} + ${rms_adjust})/1")           ### '/1' forces bc to use the scale = 2 setting
    done
    local wd_arg=$(printf "Got ${#pre_tx_levels[@]} fixed pre_tx_levels: '${pre_tx_levels[*]}'")
    wd_logger 2 "${wd_arg}"

    local raw_tx_levels=($(sox ${wav_filename} -t wav - trim ${SIGNAL_LEVEL_TX_SEC} ${SIGNAL_LEVEL_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
    local wd_arg=$(printf "Got ${#raw_tx_levels[@]} raw_tx_levels: '${raw_tx_levels[*]}'")
    wd_logger 2 "${wd_arg}"
    local tx_levels=()
    for (( i=0; i < ${#raw_tx_levels[@]} ; ++i )); do
        tx_levels[${i}]=$(bc <<< "scale = 2; (${raw_tx_levels[${i}]} + ${rms_adjust})/1")                   ### '/1' forces bc to use the scale = 2 setting
    done
    local wd_arg=$(printf "Got ${#tx_levels[@]} fixed tx_levels: '${tx_levels[*]}'")
    wd_logger 2 "${wd_arg}"

    local raw_post_tx_levels=($(sox ${wav_filename} -t wav - trim ${SIGNAL_LEVEL_POST_TX_SEC} ${SIGNAL_LEVEL_POST_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
    local wd_arg=$(printf "Got ${#raw_post_tx_levels[@]} raw_post_tx_levels: '${raw_post_tx_levels[*]}'")
    wd_logger 2 "${wd_arg}"
    local post_tx_levels=()
    for (( i=0; i < ${#raw_post_tx_levels[@]} ; ++i )); do
        post_tx_levels[${i}]=$(bc <<< "scale = 2; (${raw_post_tx_levels[${i}]} + ${rms_adjust})/1")         ### '/1' forces bc to use the scale = 2 setting
    done
    local wd_arg=$(printf "Got ${#post_tx_levels[@]} fixed post_tx_levels levels '${post_tx_levels[*]}'")
    wd_logger 2 "${wd_arg}"

    if [[ ${#pre_tx_levels[@]} -lt 4 ]] || [[ ${#post_tx_levels[@]} -lt 4 ]]; then
        wd_logger 1 "ERROR: [[ ${#pre_tx_levels[@]} -lt 4 ]] || [[ ${#post_tx_levels[@]} -lt 4 ]]"
        eval ${return_var_name}="None"
        eval ${return_string_name}=\"Failed to get RMS noise data\"
        return 1
    fi

    local rms_value=${pre_tx_levels[3]}                                           # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
    if [[  $(bc --mathlib <<< "${post_tx_levels[3]} < ${pre_tx_levels[3]}") -eq "1" ]]; then
        rms_value=${post_tx_levels[3]}
        wd_logger 2 "So returning rms_level ${rms_value} which is from post_tx"
    else
        wd_logger 2 "So returning rms_level ${rms_value} which is from pre_tx"
    fi

    local signal_level_line="               ${pre_tx_levels[*]}          ${tx_levels[*]}          ${post_tx_levels[*]}   ${rms_value}"
    eval ${return_var_name}=${rms_value}
    eval ${return_string_name}=\"${signal_level_line}\"
    wd_logger 2 "Returning rms_value=${rms_value} and signal_level_line='${signal_level_line}'"
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
        wd_logger 1 "Command 'timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}' returned error ${ret_code}"
    fi
    grep -A 10000 "${last_line}" ALL_WSPR.TXT | grep -v "${last_line}" > ALL_WSPR.TXT.new
    return ${ret_code}
}

function queue_decoded_spots() {
    local wav_file_name=$1
    local wsprd_spots_file=$2        ### These are the new lines in ALL_
    local signal_level_line="$3"
    local signal_levels_log_file=$4
    local rx_khz_offset=0           ### only used by RTLs

    wd_logger 1 "Spots found in wav file ${wav_file_name} can be found in ${wsprd_spots_file}. Also recording signal_level_line:\n${signal_level_line}'\n$(cat ${wsprd_spots_file})"

    local signal_level_list=( ${signal_level_line} )

    local rms_nl=0
    local fft_nl=0
    if [[ ${#signal_level_list[@]} -ne 14 ]]; then
        wd_logger 1 "ERROR: signal_level_line has ${#signal_level_list[@]} fields, not the expected 14"
    else
        rms_nl=${signal_level_list[12]}
        fft_nl=${signal_level_list[13]}
        wd_logger 1 "Adding rms_nl=${rms_nl} and fft_nl=${fft_nl} to each spot line"
    fi

    local wspr_decode_capture_date=${wav_file_name/T*}
          wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
    local wspr_decode_capture_time=${wav_file_name#*T}
          wspr_decode_capture_time=${wspr_decode_capture_time/Z*}
          wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
    local wspr_decode_capture_freq_hz=${wav_file_name#*_}
          wspr_decode_capture_freq_hz=$( bc <<< "${wspr_decode_capture_freq_hz/_*} + (${rx_khz_offset} * 1000)" )

    echo "${wspr_decode_capture_date}-${wspr_decode_capture_time}: ${signal_level_line}" >> ${signal_levels_log_file}
    
    local new_noise_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_noise.txt
    echo "${signal_level_line}" > ${new_noise_file}

    ### Forward the recording's date_time_freqHz spot file to the posting daemon which is polling for it.  Do this here so that it is after the very slow sox FFT calcs are finished
    local spot_queue_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_spots.txt
    > ${spot_queue_file}   ### create or truncate file which will be queued
    if [[ ! -f ${wsprd_spots_file} ]] || [[ ! -s ${wsprd_spots_file} ]]; then
        ### A zero length spots file signals the posting daemon that decodes are complete but no spots were found
        wd_logger 1 "no spots were found.  Queuing zero length spot file '${spot_queue_file}'"
    else
        ###  Spots were found. We want to add the noise level fields to the end of each spot
        local spot_for_wsprnet=0         ### the posting_daemon() will fill in this field

        wd_logger 2 "$( wc -l < ${wsprd_spots_file}) spots were found.  Add noise levels to the end of each spot line while creating ${spot_queue_file}"
        
        local WSPRD_2_2_FIELD_COUNT=17   ## wsprd in wsjt-x v2.2 outputs 17 fields in a slightly different order than the 15 fields output by wsprd v2.1
        local WSPRD_2_2_WITHOUT_GRID_FIELD_COUNT=16   ## wsprd in wsjt-x v2.2 outputs 17 fields in a slightly different order than the 15 fields output by wsprd v2.1
        # fprintf(fall_wspr, "%6s              %4s                                      %3.0f          %5.2f           %11.7f               %-22s                    %2d            %5.2f                          %2d                   %2d                %4d                    %2d                  %3d                   %5u                %5d\n",
        # 2.2.x:     decodes[i].date, decodes[i].time,                            decodes[i].snr, decodes[i].dt, decodes[i].freq, decodes[i].message, (int)decodes[i].drift, decodes[i].sync,          decodes[i].ipass+1, decodes[i].blocksize, decodes[i].jitter, decodes[i].decodetype, decodes[i].nhardmin, decodes[i].cycles/81, decodes[i].metric);
        # 2.2.x with grid:     200724 1250 -24  0.24  28.1260734  M0UNI IO82 33           0  0.23  1  1    0  1  45     1   810
        # 2.2.x without grid:  200721 0800  -7  0.15  28.1260594  DC7JZB/B 27            -1  0.68  1  1    0  0   0     1   759
        local spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields
        while read  spot_date spot_time spot_snr spot_dt spot_freq spot_call other_fields ; do
            wd_logger 2 "read this V2.2 format ALL_WSPR.TXT line: '${spot_date}' '${spot_time}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${other_fields}'"
            local spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_decodetype spot_nhardmin spot_decode_cycles spot_metric

            local other_fields_list=( ${other_fields} )
            local other_fields_list_count=${#other_fields_list[@]}

            local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID=12
            local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID=11
            local got_valid_line="yes"
            local spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric spot_mode
            if [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID} ]]; then
                read spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric spot_mode <<< "${other_fields}"
                wd_logger 2 "this V2.2 type 1 ALL_WSPR.TXT line has GRID: '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' '${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
            elif [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
                spot_grid=""
                read spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric spot_mode <<< "${other_fields}"
                wd_logger 2 "this V2.2 type 2 ALL_WSPR.TXT line has no GRID: '${spot_date}' '${spot_time}' '${spot_sync_quality}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' ${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
            else
                wd_logger 0 "WARNING: tossing  a corrupt (not the expected 15 or 16 fields) ALL_WSPR.TXT spot line: ${other_fields}"
                got_valid_line="no"
            fi
            if [[ ${got_valid_line} == "yes" ]]; then
                #                              %6s %4s   %3d %3.0f %5.2f %11.7f %-22s          %2d %5u %4d  %4d %4d %2u\n"       ### fprintf() line from wsjt-x.  The %22s message field appears to include power
                #local extended_line=$( printf "%4s %4s %5.2f %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4d, %2d %5d %2d %2d %3d %2d\n" \
                local extended_line=$( printf "%6s %4s %5.2f %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d %s %s %s\n" \
                    "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" \
                    "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}" "${rms_nl}" "${fft_nl}" "${spot_mode}")
                extended_line="${extended_line//[$'\r\n\t']}"  ### //[$'\r\n'] strips out the CR and/or NL which were introduced by the printf() for reasons I could not diagnose
                echo "${extended_line}" >> ${spot_queue_file}
            fi
        done < ${wsprd_spots_file}

        wd_logger 1 "Created enhanced spot file:\n$(cat ${spot_queue_file})\n"
    fi
    ### Copy the noise level file and the renamed ${spot_queue_file} to waiting posting daemons' subdirs
    shopt -s nullglob    ### * expands to NULL if there are no .wav wav_file
    local dir
    for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
        ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
        wd_logger 1 "copying ${spot_queue_file} and ${new_noise_file} to ${dir}/ monitored by a posting daemon" 
        ln ${spot_queue_file} ${new_noise_file} ${dir}/
    done
    rm ${spot_queue_file} ${new_noise_file}
    wd_logger 1 "Queued the new spots and noise lines for the posting daemon"
}

declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare WSPRD_CMD=${WSPRD_BIN_DIR}/wsprd
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare WSPRD_CMD_FLAGS="${WSPRD_CMD_FLAGS--C 500 -o 4 -d}"
declare WSPRD_STDOUT_FILE=wsprd_stdout.txt               ### wsprd stdout goes into this file, but we use wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                         ### Truncate the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..
declare RAW_FILE_FULL_SIZE=1440000   ### Approximate number of bytes in a full size one minute long raw or wav file

### If the wav recording daemon is running, we can calculate how many seconds until it starts to fill the raw file (if 0 length first file) or fills the 2nd raw file.  Sleep until then
function sleep_until_raw_file_is_full() {
    local filename=$1
    if [[ ! -f ${filename} ]]; then
        wd_logger 1 "ERROR: ${filename} doesn't exist"
        return 1
    fi
    local old_file_size=$(stat -c %s ${filename})
    local new_file_size
    local start_seconds=${SECONDS}

    sleep 2
    while [[ -f ${filename} ]] && new_file_size=$(stat -c %s ${filename}) && [[ ${new_file_size} -gt ${old_file_size} ]]; do
        wd_logger 3 "Waiting for file ${filename} to stop growing in size. old_file_size=${old_file_size}, new_file_size=${new_file_size}"
        old_file_size=${new_file_size}
        sleep 2
    done
    local loop_seconds=$(( SECONDS - start_seconds ))
    if [[ ! -f ${filename} ]]; then
        wd_logger 1 "ERROR: file ${filename} disappeared after ${loop_seconds} seconds"
        return 1
    fi
    wd_logger 2 "File ${filename} stabliized at size ${new_file_size} after ${loop_seconds} seconds"
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

    wd_logger 2 "Start with args '${return_variable_name} ${receiver_name} ${receiver_band} ${receiver_modes}', then receiver_modes => ${target_modes_list[*]} => target_minutes=( ${target_minutes_list[*]} ) => target_seconds=( ${target_seconds_list[*]} )"
    ### This code requires  that the list of wav files to be generated is in ascending seconds order, i.e "120 300 900 1800)

    if ! spawn_wav_recording_daemon ${receiver_name} ${receiver_band} ; then
        local ret_code=$?
        wd_logger 1 "ERROR: 'spawn_wav_recording_daemon ${receiver_name} ${receiver_band}' => ${ret_code}"
        return ${ret_code}
    fi

    local ret_code

    shopt -s nullglob
    local raw_file_list=( minute-*.raw *_usb.wav)        ### Get list of the one minute long 'raw' wav files being created by the Kiwi (.wav) or SDR ((.raw)
    shopt -u nullglob

    wd_logger 2 "Found raw/wav files '${raw_file_list[*]}'"
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
            ;;
    esac

    wd_logger 2 "Found ${#raw_file_list[@]} full raw files. Fill return list with lists of those raw files which are part of each WSPR mode"
    ### We now have a list of two or more full size raw files
    local epoch_of_first_raw_file=$(stat -c %Y ${raw_file_list[0]})
    local index_of_first_file_which_needs_to_be_saved=${#raw_file_list[@]}                         ### Presume we will need to keep none of the raw files

    local return_list=()
    local seconds_in_wspr_pkt
    for seconds_in_wspr_pkt in  ${target_seconds_list[@]} ; do
        local raw_files_in_wav_file_count=$((seconds_in_wspr_pkt / 60))
        wd_logger 2 "Check to see if we can create a new ${seconds_in_wspr_pkt} seconds long wav file from ${raw_files_in_wav_file_count} raw files"

        local epoch_of_first_raw_file=$( stat -c %Y ${raw_file_list[0]})
        local minute_of_first_raw_file=$( date -r ${raw_file_list[0]} +%M )   ### Could b derived from epoch, I guess
        wd_logger 2 "The first raw file ${raw_file_list[0]} write time is at minute ${minute_of_first_raw_file}"

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
            local epoch_of_latest_wav_raw_file=$( stat -c %Y ${filename_of_latest_wav_raw} )
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

    echo "$(date): decoding_daemon_kill_handler() with pid $$ is processing SIGTERM to stop decoding on ${receiver_name},${receiver_band}" > decoding_daemon_kill_handler.log
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

function decoding_daemon() {
    local receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local receiver_band=${2}
    local receiver_modes_arg=${3}

    wd_logger 1 "Starting with args ${receiver_name} ${receiver_band} ${receiver_modes_arg}"
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

    ### Store the signal level logs under the ~/wsprdaemon/... directory where it won't be lost due to a reboot or power cycle.
    local signal_levels_log_file 
    setup_signal_levels_log_file  signal_levels_log_file ${receiver_name} ${receiver_band} 
    wd_logger 1 "Log signals to '${signal_levels_log_file}'"

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
            wd_logger 2 "Error ${ret_code} returned by 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'. 'sleep 1' and retry"
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

            local decoder_input_wav_filename="${wav_file_list[0]:2:6}_${wav_file_list[0]:9:4}.wav"
            sox ${wav_file_list[@]} ${decoder_input_wav_filename}       ### TODO: don't make so many copies and perhaps use list of files as input to jt9

            local wav_file_freq_hz=${wav_file_list[0]#*_}   ### Remove the year/date/time
            wav_file_freq_hz=${wav_file_freq_hz%_*}      ### Remove the _usb.wav

            local processed_wav_files="no"
            local signal_level_line=""
            > decodes_cache.txt             ## Create or truncate to zero length a file which stores the decodes from all modes
            if [[ " ${receiver_modes_list[*]} " =~ " W${returned_minutes} " ]]; then
                local decode_dir="W_${returned_seconds}"
                mkdir -p ${decode_dir}
                ln ${decoder_input_wav_filename} ${decode_dir}/

                wd_logger 1 "Decode ${returned_seconds} second wav file for WSPR mode spots"

                ### Perform decoding for each mode in its own sub directory
                cd ${decode_dir}
                local start_time=${SECONDS}
                decode_wpsr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt
                local ret_code=$?

                cd - >& /dev/null
                ### Back to recoding directory

                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds. For mode W_${returned_seconds}: 'decode_wpsr_wav_file ${decoder_input_wav_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt' => ${ret_code}"
                else
                    ### Output a noise line  which contains 'DATE TIME + three sets of four space-seperated statistics'i followed by the two FFT values followed by the approximate number of overload events recorded by a Kiwi during this WSPR cycle:
                    ###                           Pre Tx                                                        Tx                                                   Post TX
                    ###     'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'        'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'       'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB      RMS_noise C2_noise  New_overload_events'
                    local c2_filename="${decode_dir}/000000_0001.c2" ### -c instructs wsprd to create the C2 format file "000000_0001.c2"
                    if [[ ! -f ${C2_FFT_CMD} ]]; then
                        wd_logger 0 "Can't find the '${C2_FFT_CMD}' script"
                        exit 1
                    fi
                    local c2_fft_nl=$(python3 ${C2_FFT_CMD} ${c2_filename})
                    local fft_nl_cal=$(bc <<< "scale=2;var=${c2_fft_nl};var+=${fft_nl_adjust};(var * 100)/100")
                    wd_logger 1 "fft_nl_cal=${fft_nl_cal} which is calculated from 'local fft_nl_cal=\$(bc <<< 'scale=2;var=${c2_fft_nl};var+=${fft_nl_adjust};var/=1;var')"

                    local rms_nl
                    local rms_line
                    get_rms_levels  rms_nl rms_line ${decode_dir}/${decoder_input_wav_filename} ${rms_nl_adjust}
                    signal_level_line="${rms_line} ${fft_nl_cal}"
                    wd_logger 1 "Added fft_nl_cal to rms_line='${rms_line}'"
                    ### If this is a KiwiSDR, then discover the number of 'ADC OV' events recorded since the last cycle
                    local new_kiwi_ov_count=0
                    local current_kiwi_ov_lines=0
                    if [[ -f kiwi_recorder.log ]]; then
                        current_kiwi_ov_lines=$(${GREP_CMD} "^ ADC OV" kiwi_recorder.log | wc -l)
                        if [[ ${current_kiwi_ov_lines} -lt ${old_kiwi_ov_lines} ]]; then
                            ### kiwi_recorder.log probably grew too large and the kiwirecorder.py was restarted 
                            old_kiwi_ov_lines=0
                        fi
                        new_kiwi_ov_count=$(( ${current_kiwi_ov_lines} - ${old_kiwi_ov_lines} ))
                        old_kiwi_ov_lines=${current_kiwi_ov_lines}
                    fi
                   wd_logger 1 "After $(( SECONDS - start_time )) seconds: For mode W_${returned_seconds}: command 'decode_wpsr_wav_file ${decoder_input_wav_filename} wsprd_stdout.txt' measured FFT noise = ${fft_nl_cal}, RMS noise = ${rms_nl}"
                   sed "s/\$/  ${returned_minutes}/" ${decode_dir}/ALL_WSPR.TXT.new >> decodes_cache.txt          ### Add the wspr packet mode '2' or mode '15' to each line.  this will be recorded by wsprdaemon.org 
                fi
                rm ${decode_dir}/${decoder_input_wav_filename}   ### wait until now to delete it so RMS and C2 cacluations wd_logger lines go to logfile in this directory

                processed_wav_files="yes"
            fi
            if [[ " ${receiver_modes_list[*]} " =~ " F${returned_minutes} " ]]; then
                wd_logger 1 "Decode a ${returned_seconds} wave file for FST4W spots by running cmd: '${JT9_CMD} -p ${returned_seconds} --fst4w ${decoder_input_wav_filename}'"

                local decode_dir="F_${returned_seconds}"
                mkdir -p ${decode_dir}
                ln ${decoder_input_wav_filename} ${decode_dir}/

                cd ${decode_dir}
                local start_time=${SECONDS}
                ${JT9_CMD} -p ${returned_seconds} --fst4w ${decoder_input_wav_filename} >& jt9_output.txt
                local ret_code=$?
                if [[ -f ${decoder_input_wav_filename} ]]; then
                    rm ${decoder_input_wav_filename}
                else
                    wd_logger 1 "ERROR: FST4W  decode failed to find ${decoder_input_wav_filename} to be removed"
                fi
                cd - >& /dev/null
                if [[ ${ret_code} -eq 0 ]]; then
                    wd_logger 1 "After $(( SECONDS - start_time )) seconds: cmd '${JT9_CMD} -p ${returned_seconds} --fst4w ${decoder_input_wav_filename} >& jt9_output.txt' printed $(cat ${decode_dir}/jt9_output.txt)"
                else
                    wd_logger 2 "After $(( SECONDS - start_time )) seconds: ERROR: cmd '${JT9_CMD} -p ${returned_seconds} --fst4w ${decoder_input_wav_filename} >& jt9_output.txt' => ${ret_code} and printed $(cat jt9_output.txt)"
                fi
                processed_wav_files="yes"
            fi
            if [[ -f ${decoder_input_wav_filename} ]]; then
                rm ${decoder_input_wav_filename}
            else
                wd_logger 1 "ERROR: after WSPR and FST4W processing, decode loop failed to find ${decoder_input_wav_filename} to be removed"
            fi
            if [[ ${processed_wav_files} == "no" ]]; then 
                wd_logger 1 "ERROR: created a wav file of ${returned_seconds}, but the conf file didn't specify a mode for that length"
            else
                wd_logger 1 "Processed files '${wav_files}' for WSPR packet of length ${returned_seconds} seconds"
            fi
            ### Queue WSPR and/or FST4W spots for each second length packets.  The start time and frequency of the spots can be extracted from the first wav file of the wav file list
            queue_decoded_spots ${wav_file_list[0]} decodes_cache.txt "${signal_level_line}" ${signal_levels_log_file}
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
    if [[ ! -f ${DECODING_DAEMON_PID_FILE} ]] ; then
        wd_logger 1 "ERROR: Decoding pid file '${DECODING_DAEMON_PID_FILE} for '${receiver_name},${receiver_band},${receiver_modes}' does not exist"
        cd - > /dev/null
        return 2
    fi
    local decoding_pid=$( < ${DECODING_DAEMON_PID_FILE} )
    kill ${decoding_pid}
    local ret_code=$?
    rm ${DECODING_DAEMON_PID_FILE}
    cd - > /dev/null

    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'kill ${decoding_pid} => ${ret_code}"
        return 3
    fi
    wd_logger 1 "Killed decoding_daemon with pid ${decoding_pid}"

    for (( timeout=0; timeout < 10 ; ++timeout )); do
        if ! ps ${decoding_pid} > /dev/null; then
            wd_logger 1 "decoding_daemon() died after ${timeout} seconds"
            return 0
        fi
        sleep 1
    done
    wd_logger 1 "ERROR: timeout after ${timeout} seconds while waiting for decoding_daemon() to die"
    return 1
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


