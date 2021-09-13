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
        local default_modes
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

function setup_signal_levels_log_file() {
    local return_signal_levels_log_file_variable_name=$1   ### Return the full path to the log file which will be added to during each wspr packet decode 
    local receiver_name=$2
    local receiver_band=$3

    local signal_level_logs_dir=${WSPRDAEMON_ROOT_DIR}/signal_levels/${receiver_name}/${receiver_band}
    mkdir -p ${signal_level_logs_dir}

    local local_signal_levels_log_file=${signal_level_logs_dir}/signal-levels.log
    eval ${return_signal_levels_log_file_variable_name}=${local_signal_levels_log_file}

    if [[ -f ${local_signal_levels_log_file} ]]; then
        wd_logger 1 "Signal Level log file '${local_signal_levels_log_file}' exists, so leave it alone"
        return 0
    fi
    ### these could be modified from these default values by declaring them in the .conf file.
    SIGNAL_LEVEL_PRE_TX_SEC=${SIGNAL_LEVEL_PRE_TX_SEC-.25}
    SIGNAL_LEVEL_PRE_TX_LEN=${SIGNAL_LEVEL_PRE_TX_LEN-.5}
    SIGNAL_LEVEL_TX_SEC=${SIGNAL_LEVEL_TX_SEC-1}
    SIGNAL_LEVEL_TX_LEN=${SIGNAL_LEVEL_TX_LEN-109}
    SIGNAL_LEVEL_POST_TX_SEC=${SIGNAL_LEVEL_POST_TX_LEN-113}
    SIGNAL_LEVEL_POST_TX_LEN=${SIGNAL_LEVEL_POST_TX_LEN-5}

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

function setup_fft_and_c2_level_corrections() {
    local return_corrections_variable_name=$1
    local receiver_band=$2

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
    local antenna_factor_adjust=$(get_af_db ${receiver_name} ${receiver_band})
    local rx_khz_offset=$(get_receiver_khz_offset_list_from_name ${receiver_name})
    local total_correction_db=$(bc <<< "scale = 10; ${kiwi_amplitude_versus_frequency_correction} + ${antenna_factor_adjust}")
    local rms_adjust=$(bc -l <<< "${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}" )                                       ## bc -l invokes the math extension, l(x)/l(10) == log10(x)
    local fft_adjust=$(bc -l <<< "${cal_fft_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db} + ${cal_fft_band} + ${cal_threshold}" )  ## bc -l invokes the math extension, l(x)/l(10) == log10(x)
    wd_logger 2 "calculated the Kiwi to require a ${kiwi_amplitude_versus_frequency_correction} dB correction in this band
            Adding to that the antenna factor of ${antenna_factor_adjust} dB to results in a total correction of ${total_correction_db}
            rms_adjust=${rms_adjust} comes from ${cal_rms_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db}
            fft_adjust=${fft_adjust} comes from ${cal_fft_offset} + (10 * (l( 1 / ${cal_ne_bw}) / l(10) ) ) + ${total_correction_db} + ${cal_fft_band} + ${cal_threshold}
            rms_adjust and fft_adjust will be ADDed to the raw dB levels"
    ## G3ZIL implementation of algorithm using the c2 file by Christoph Mayer
    local c2_FFT_nl_adjust=$(bc <<< "scale = 2;var=${cal_c2_correction};var+=${total_correction_db}; (var * 100)/100")   # comes from a configured value.  'scale = 2; (var * 100)/100' forces bc to ouput only 2 digits after decimal
    wd_logger 2 "c2_FFT_nl_adjust = ${c2_FFT_nl_adjust} from 'local c2_FFT_nl_adjust=\$(bc <<< 'var=${cal_c2_correction};var+=${total_correction_db};var')"  # value estimated
}


function decoding_daemon() 
{
    local receiver_name=$1                ### 'real' as opposed to 'merged' receiver
    local receiver_band=${2}
    local receiver_modes_arg=${3}

    wd_logger 1 "Starting with args ${receiver_name} ${receiver_band} ${receiver_modes_arg}"
    setup_verbosity_traps          ## So we can increment and decrement verbosity without restarting WD

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

    local c2_and_fft_correction
    setup_fft_and_c2_level_corrections  c2_and_fft_correction ${receiver_band}

    wd_logger 1 "Starting to search for raw or wav files from '${receiver_name}' tuned to WSPRBAND '${receiver_band}'"
    local decoded_spots=0        ### Maintain a running count of the total number of spots_decoded
    local old_wsprd_decoded_spots=0   ### If we are comparing the new wsprd against the old wsprd, then this will count how many were decoded by the old wsprd

    local recording_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})
    cd ${recording_dir}
    local old_kiwi_ov_lines=0

    rm -f *.raw *.wav*
    shopt -s nullglob
    while [[  -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; do    ### Keep decoding as long as there is at least one posting_daemon client
        wd_logger 1 "Getting a list of MODE:WAVE_FILE... with: 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'"
        local mode_seconds_files=""           ### This string will contain 0 or more space-seperated SECONDS:FILENAME_0[,FILENAME_1...] fields 
        get_wav_file_list mode_seconds_files  ${receiver_name} ${receiver_band} ${receiver_modes}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "Error ${ret_code} returned by 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}'. 'sleep 1' and retry"
            sleep 1
            continue
        fi
        local -a mode_wav_file_list=(${mode_seconds_files})
        wd_logger 1 "The call 'get_wav_file_list mode_wav_file_list ${receiver_name} ${receiver_band} ${receiver_modes}' returned '${mode_wav_file_list[*]}'"

        > decodes_cache.txt             ## Create or truncate to zero length a file which stores the decodes from all modes
        local returned_files
        for returned_files in ${mode_wav_file_list[@]}; do
            local returned_seconds=${returned_files%:*}
            local returned_minutes=$(( returned_seconds / 60 ))
            local comma_seperated_files=${returned_files#*:}
            local wav_files=${comma_seperated_files//,/ }
            local wav_file_list=( ${wav_files} )
            wd_logger 1 "For WSPR packets of length ${returned_seconds} seconds, got list of files ${comma_seperated_files}"

            local wsprd_input_filename="${wav_file_list[0]:2:6}_${wav_file_list[0]:9:4}.wav"
            local wav_file_freq_hz=${wav_file_list[0]#*_}   ### Remove the year/date/time
            wav_file_freq_hz=${wav_file_freq_hz%_*}      ### Remove the _usb.wav

            local processed_wav_files="no"
            if [[ " ${receiver_modes_list[*]} " =~ " W${returned_minutes} " ]]; then
                local decode_dir="W_${returned_seconds}"
                mkdir -p ${decode_dir}
                sox ${wav_file_list[@]} ${decode_dir}/${wsprd_input_filename}       ### TODO: don't make so many copies and perhaps use list of files as input to jt9

                wd_logger 1 "Decode ${returned_seconds} second WSPR mode spots in wav files '${comma_seperated_files}' by combining them into one wav file '${wsprd_input_filename}' to be processed by 'wsprd'"

                cd ${decode_dir}
                local start_time=${SECONDS}
                decode_wpsr_wav_file ${wsprd_input_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt
                local ret_code=$?
                rm ${wsprd_input_filename}
                cd - >& /dev/null
                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: After $(( SECONDS - start_time )) seconds. For mode W_${returned_seconds}: 'decode_wpsr_wav_file ${wsprd_input_filename}  ${wav_file_freq_hz} ${rx_khz_offset} wsprd_stdout.txt' => ${ret_code}"
                else
                    wd_logger 1 "After $(( SECONDS - start_time )) seconds: For mode W_${returned_seconds}: command 'decode_wpsr_wav_file ${wsprd_input_filename} wsprd_stdout.txt' decoded:  $(cat ${decode_dir}/wsprd_stdout.txt)"
                fi
                processed_wav_files="yes"
            fi
            if [[ " ${receiver_modes_list[*]} " =~ " F${returned_minutes} " ]]; then
                wd_logger 1 "Files of ${returned_seconds} will be processed by cmd: '${JT9_CMD} -p ${returned_seconds} --fst4w ${wav_files}'"

                local decode_dir="F_${returned_seconds}"
                mkdir -p ${decode_dir}
                sox ${wav_file_list[@]} ${decode_dir}/${wsprd_input_filename}       ### TODO: don't make so many copies and perhaps use list of files as input to jt9
                cd ${decode_dir}
                set -x
                local start_time=${SECONDS}
                ${JT9_CMD} -p ${returned_seconds} --fst4w ${wsprd_input_filename} >& jt9_output.txt
                local ret_code=$?
                rm ${wsprd_input_filename}
                cd - >& /dev/null
                set +x
                if [[ ${ret_code} -eq 0 ]]; then
                    wd_logger 1 "After $(( SECONDS - start_time )) seconds: cmd '${JT9_CMD} -p ${returned_seconds} --fst4w ${wsprd_input_filename} >& jt9_output.txt' printed $(cat ${decode_dir}/jt9_output.txt)"
                else
                    wd_logger 1 "After $(( SECONDS - start_time )) seconds: ERROR: cmd '${JT9_CMD} -p ${returned_seconds} --fst4w ${wsprd_input_filename} >& jt9_output.txt' => ${ret_code} and printed $(cat jt9_output.txt)"
                fi
                processed_wav_files="yes"
            fi
            if [[ ${processed_wav_files} == "no" ]]; then 
                wd_logger 1 "ERROR: created a wav file of ${returned_seconds}, but the conf file didn't specify a mode for that length"
            else
                wd_logger 1 "Processed files '${wav_files}' for WSPR packet of length ${returned_seconds} seconds"
            fi
        done
        sleep 1
    done
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

    timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "Command 'timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wav_file_name} > ${stdout_file}' returned error ${ret_code}"
    fi
    return ${ret_code}
}
 
 old_decode_daemon() {

    while true; do
        wd_logger 3 "Checking for *.wav' files in $PWD"
        shopt -s nullglob    ### *.wav expands to NULL if there are no .wav wav_file_names
        ### Wait for a wav file and synthisize a zero length spot file every two minutes so MERGed rx don't hang if one real rx fails

        local -a wav_file_list=()
        get_wav_file_list wav_file_list ${receiver_modes} 
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "Error ${ret_code} returned by get_wav_files wav_file_list ${real_receiver_name} ${real_receiver_band} '${real_receiver_modes}'"
            sleep 1
            continue
        fi
        while wav_file_list=( *.wav) && [[ ${#wav_file_list[@]} -eq 0 ]]; do
            ### recording daemon isn't outputing a wav file, so post a zero length spot file in order to signal the posting daemon to process other real receivers in a MERGed group 
            local wspr_spots_filename
            local wspr_decode_capture_date=$(date -u -d '2 minutes ago' +%g%m%d_%H%M)  ### Unlike the wav filenames used below, we can get DATE_TIME from 'date' in exactly the format we want
            local new_spots_file="${wspr_decode_capture_date}_${wspr_band_freq_hz}_wspr_spots.txt"
            rm -f ${new_spots_file}
            touch ${new_spots_file}
            local dir
            for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
                ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
                wd_logger 2 "Timeout waiting for a wav file, so copy a zero length ${new_spots_file} to ${dir}/ monitored by a posting daemon"
                cp -p ${new_spots_file} ${dir}/
            done
            rm ${new_spots_file} 
            wd_logger 2 "Found no wav files. Sleeping until next even minute."
            local next_start_time_string=$(sleep_until_next_even_minute)
        done
        for wav_file_name in *.wav; do
           if [[ ${DECODE_USE_OLD_KIWI_WAV_RECORDING--no} == "yes" ]]; then
                wd_logger 2 "Monitoring size of wav file '${wav_file_name}'"

                ### Wait until the wav_file_name size isn't changing, i.e. kiwirecorder.py has finished writting this 2 minutes of capture and has moved to the next wav_file_name
                local old_wav_file_size=0
                local new_wav_file_size=$( ${GET_FILE_SIZE_CMD} ${wav_file_name} )
                while [[ -n "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]] && [[ ${new_wav_file_size} -ne ${old_wav_file_size} ]]; do
                    old_wav_file_size=${new_wav_file_size}
                    sleep ${WAV_FILE_POLL_SECONDS}
                    new_wav_file_size=$( ${GET_FILE_SIZE_CMD} ${wav_file_name} )
                    wd_logger 4 "Old size ${old_wav_file_size}, new size ${new_wav_file_size}"
                done
                if [[ -z "$(ls -A ${DECODING_CLIENTS_SUBDIR})" ]]; then
                    wd_logger 2 "wav file size loop terminated due to no posting.d subdir"
                    break
                fi
                wd_logger 2 "Wav file '${wav_file_name}' stabilized at size ${new_wav_file_size}."
                if  [[ ${new_wav_file_size} -lt ${WSPRD_WAV_FILE_MIN_VALID_SIZE} ]]; then
                    wd_logger 2 "wav file '${wav_file_name}' size ${new_wav_file_size} is too small to be processed by wsprd.  Delete this file and go to next wav file."
                    rm -f ${wav_file_name}
                    continue
                fi
            else
                wd_logger 1 "Waiting for wav file(s)"
                wav_get_next_file 
                wd_logger 1 "Waiting for wav file(s)"
            fi

            local wspr_decode_capture_date=${wav_file_name/T*}
            wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
            local wspr_decode_capture_time=${wav_file_name#*T}
            wspr_decode_capture_time=${wspr_decode_capture_time/Z*}
            local wspr_decode_capture_sec=${wspr_decode_capture_time:4}
            if [[ ${wspr_decode_capture_sec} != "00" ]]; then
                wd_logger 2 "wav file '${wav_file_name}' size ${new_wav_file_size} shows that recording didn't start at second "00". Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi
            local wspr_decode_capture_min=${wspr_decode_capture_time:2:2}
            if [[ ! ${wspr_decode_capture_min:1} =~ [02468] ]]; then
                wd_logger 2 "wav file '${wav_file_name}' size ${new_wav_file_size} shows that recording didn't start on an even minute. Delete this file and go to next wav file."
                rm -f ${wav_file_name}
                continue
            fi
            wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
            local wsprd_input_wav_filename=${wspr_decode_capture_date}_${wspr_decode_capture_time}.wav    ### wsprd prepends the date_time to each new decode in wspr_spots.txt
            local wspr_decode_capture_freq_hz=${wav_file_name#*_}
            wspr_decode_capture_freq_hz=$( bc <<< "${wspr_decode_capture_freq_hz/_*} + (${rx_khz_offset} * 1000)" )
            local wspr_decode_capture_freq_mhz=$( printf "%2.4f\n" $(bc <<< "scale = 5; ${wspr_decode_capture_freq_hz}/1000000.0" ) )
            local wspr_decode_capture_band_center_mhz=$( printf "%2.6f\n" $(bc <<< "scale = 5; (${wspr_decode_capture_freq_hz}+1500)/1000000.0" ) )
            ### 

            local wspr_decode_capture_minute=${wspr_decode_capture_time:2}

            [[ ! -s ALL_WSPR.TXT ]] && touch ALL_WSPR.TXT
            local all_wspr_size=$(${GET_FILE_SIZE_CMD} ALL_WSPR.TXT)
            if [[ ${all_wspr_size} -gt ${MAX_ALL_WSPR_SIZE} ]]; then
                wd_logger 1 "ALL_WSPR.TXT has grown too large, so truncating it"
                tail -n 1000 ALL_WSPR.TXT > ALL_WSPR.tmp
                mv ALL_WSPR.tmp ALL_WSPR.TXT
            fi
            refresh_local_hashtable  ## In case we are using a hashtable created by merging hashes from other bands
            ln ${wav_file_name} ${wsprd_input_wav_filename}
            local wsprd_cmd_flags=${WSPRD_CMD_FLAGS}
            #if [[ ${real_receiver_band} =~ 60 ]]; then
            #    wsprd_cmd_flags=${WSPRD_CMD_FLAGS/-o 4/-o 3}   ## At KPH I found that wsprd takes 90 seconds to process 60M wav files. This speeds it up for those bands
            #fi
            local start_time=${SECONDS}
            timeout ${WSPRD_TIMEOUT_SECS-110} nice ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wsprd_input_wav_filename} > ${WSPRD_DECODES_FILE}
            local ret_code=$?
            local run_time=$(( ${SECONDS} - ${start_time} ))
            if [[ ${ret_code} -ne 0 ]]; then
                if [[ ${ret_code} -eq 124 ]]; then
                    wd_logger 1 "'wsprd' timeout with ret_code = ${ret_code} after ${run_time} seconds"
                else
                    wd_logger 1 "'wsprd' retuned error ${ret_code} after ${run_time} seconds.  It printed:\n$(cat ${WSPRD_DECODES_FILE})"
                fi
                ### A zero length wspr_spots.txt file signals the following code that no spots were decoded
                rm -f wspr_spots.txt
                touch wspr_spots.txt
                ### There is almost certainly no useful c2 noise level data
                local c2_FFT_nl_cal=-999.9
            else
                ### 'wsprd' was successful
                ### Validate, and if necessary cleanup, the spot list file created by wsprd
                local bad_wsprd_lines=$(awk 'NF < 11 || NF > 12 || $6 == 0.0 {printf "%40s: %s\n", FILENAME, $0}' wspr_spots.txt)
                if [[ -n "${bad_wsprd_lines}" ]]; then
                    ### Save this corrupt wspr_spots.txt, but leave it untouched so it can be used later to tell us how man ALL_WSPT.TXT lines to process
                    mkdir -p bad_wspr_spots.d
                    cp -p wspr_spots.txt bad_wspr_spots.d/
                    ###
                    ### awk 'NF >= 11 && NF <= 12 &&  $6 != 0.0' bad_wspr_spots.d/wspr_spots.txt > wspr_spots.txt
                    wd_logger 0 "WARNING:  wsprd created a wspr_spots.txt with corrupt line(s):\n%s" "${bad_wsprd_lines}"
                fi

                local new_spots=$(wc -l wspr_spots.txt)
                decoded_spots=$(( decoded_spots + ${new_spots/ *} ))
                wd_logger 2 "decoded ${new_spots/ *} new spots.  ${decoded_spots} spots have been decoded since this daemon started"

                ### Since they are so computationally and storage space cheap, always calculate a C2 FFT noise level
                local c2_filename="000000_0001.c2" ### -c instructs wsprd to create the C2 format file "000000_0001.c2"
                if [[ ! -f ${C2_FFT_CMD} ]]; then
                    wd_logger 0 "Can't find the '${C2_FFT_CMD}' script"
                    exit 1
                fi
                python3 ${C2_FFT_CMD} ${c2_filename}  > c2_FFT.txt 
                local c2_FFT_nl=$(cat c2_FFT.txt)
                local c2_FFT_nl_cal=$(bc <<< "scale=2;var=${c2_FFT_nl};var+=${c2_FFT_nl_adjust};(var * 100)/100")
                wd_logger 3 "c2_FFT_nl_cal=${c2_FFT_nl_cal} which is calculated from 'local c2_FFT_nl_cal=\$(bc <<< 'scale=2;var=${c2_FFT_nl};var+=${c2_FFT_nl_adjust};var/=1;var')"
                if [[ ${verbosity} -ge 1 ]] && [[ -x ${WSPRD_PREVIOUS_CMD} ]]; then
                    mkdir -p wsprd.old
                    cd wsprd.old
                    timeout ${WSPRD_TIMEOUT_SECS-60} nice ${WSPRD_PREVIOUS_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ../${wsprd_input_wav_filename} > wsprd_decodes.txt
                    local ret_code=$?

                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "error ${ret_code} reported running old wsprd"
                        cd - > /dev/null
                    else
                        local old_wsprd_spots=$(wc -l wspr_spots.txt)
                        old_wsprd_decoded_spots=$(( old_wsprd_decoded_spots + ${old_wsprd_spots/ *} ))
                        wd_logger 1 "new wsprd decoded ${new_spots/ *} new spots, ${decoded_spots} total spots.  Old wsprd decoded  ${old_wsprd_spots/ *} new spots, ${old_wsprd_decoded_spots} total spots"
                        cd - > /dev/null
                        ### Look for differences only in fields like SNR and frequency which are relevant to this comparison
                        awk '{printf "%s %s %4s %10s %-10s %-6s %s\n", $1, $2, $4, $6, $7, $8, $9 }' wspr_spots.txt                   > wspr_spots.txt.cut
                        awk '{printf "%s %s %4s %10s %-10s %-6s %s\n", $1, $2, $4, $6, $7, $8, $9 }' wsprd.old/wspr_spots.txt         > wsprd.old/wspr_spots.txt.cut
                        local spot_diffs
                        if ! spot_diffs=$(diff wsprd.old/wspr_spots.txt.cut wspr_spots.txt.cut) ; then
                            local new_count=$(cat wspr_spots.txt | wc -l)
                            local old_count=$(cat wsprd.old/wspr_spots.txt | wc -l)
                            echo -e "$(date): decoding_daemon(): '>' new wsprd decoded ${new_count} spots, '<' old wsprd decoded ${old_count} spots\n$(${GREP_CMD} '^[<>]' <<< "${spot_diffs}" | sort -n -k 5,5n)"
                        fi
                    fi
                fi
            fi

            ### If enabled, execute jt9 to attempt to decode FSTW4-120 beacons
            if [[ ${JT9_DECODE_ENABLED:-no} == "yes" ]]; then
                ${JT9_CMD} ${JT9_CMD_FLAGS} ${wsprd_input_wav_filename} >& jt9.log
                local ret_code=$?
                if [[ ${ret_code} -eq 0 ]]; then
                    wd_logger 1 "jt9 decode OK\n$(cat jt9.log)"
                else
                    wd_logger 1 "error ${ret_code} reported by jt9 decoder"
                fi
            fi

            # Get RMS levels from the wav file and adjuest them to correct for the effects of the LPF on the Kiwi's input
            local pre_tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_PRE_TX_SEC} ${SIGNAL_LEVEL_PRE_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            local wd_arg=$(printf "raw   pre_tx_levels  levels '${pre_tx_levels[@]}'")
            wd_logger 3 "${wd_arg}"
            local i
            for i in $(seq 0 $(( ${#pre_tx_levels[@]} - 1 )) ); do
                pre_tx_levels[${i}]=$(bc <<< "scale = 2; (${pre_tx_levels[${i}]} + ${rms_adjust})/1")           ### '/1' forces bc to use the scale = 2 setting
            done
            local wd_arg=$(printf "fixed pre_tx_levels  levels '${pre_tx_levels[@]}'")
            wd_logger 3 "${wd_arg}"
            local tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_TX_SEC} ${SIGNAL_LEVEL_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            for i in $(seq 0 $(( ${#tx_levels[@]} - 1 )) ); do
                tx_levels[${i}]=$(bc <<< "scale = 2; (${tx_levels[${i}]} + ${rms_adjust})/1")                   ### '/1' forces bc to use the scale = 2 setting
            done
            local post_tx_levels=($(sox ${wsprd_input_wav_filename} -t wav - trim ${SIGNAL_LEVEL_POST_TX_SEC} ${SIGNAL_LEVEL_POST_TX_LEN} 2>/dev/null | sox - -n stats 2>&1 | awk '/dB/{print $(NF)}'))
            local_wd_arg=$(printf "raw   post_tx_levels levels '${post_tx_levels[@]}'")
            wd_logger 3 "${wd_arg}"
            for i in $(seq 0 $(( ${#post_tx_levels[@]} - 1 )) ); do
                post_tx_levels[${i}]=$(bc <<< "scale = 2; (${post_tx_levels[${i}]} + ${rms_adjust})/1")         ### '/1' forces bc to use the scale = 2 setting
            done
            local wd_arg=$(printf "fixed post_tx_levels levels '${post_tx_levels[@]}'")
            wd_logger 3 "${wd_arg}"

            local rms_value=${pre_tx_levels[3]}                                           # RMS level is the minimum of the Pre and Post 'RMS Tr dB'
            if [[  $(bc --mathlib <<< "${post_tx_levels[3]} < ${pre_tx_levels[3]}") -eq "1" ]]; then
                rms_value=${post_tx_levels[3]}
                wd_logger 3 "rms_level is from post"
            else
                wd_logger 3 "rms_level is from pre"
            fi
            wd_logger 3 "rms_value=${rms_value}"

            if [[ ${SIGNAL_LEVEL_UPLOAD-no} == "no" ]] || [[ ${SIGNAL_LEVEL_SOX_FFT_STATS-no} == "no" ]]; then
                ### Don't spend a lot of CPU time calculating a value which will not be uploaded
                local fft_value="-999.9"      ## i.e. "Not Calculated"
            else
                # Apply a Hann window to the wav file in 4096 sample blocks to match length of the FFT in sox stat -freq
                wd_logger 2 "applying windowing to .wav file '${wsprd_input_wav_filename}'"
                rm -f *.tmp    ### Flush zombie wav.tmp files, if any were left behind by a previous run of this daemon
                local windowed_wav_file=${wsprd_input_wav_filename/.wav/.tmp}
                if [[ ! -f ${FFT_WINDOW_CMD} ]]; then
                    wd_logger 0 "Can't find '${FFT_WINDOW_CMD}'"
                    exit 1
                fi
                /usr/bin/python3 ${FFT_WINDOW_CMD} ${wsprd_input_wav_filename} ${windowed_wav_file}
                mv ${windowed_wav_file} ${wsprd_input_wav_filename}

                wd_logger 2 "running 'sox FFT' on .wav file '${wsprd_input_wav_filename}'"
                # Get an FFT level from the wav file.  One could perform many kinds of analysis of this data.  We are simply averaging the levels of the 30% lowest levels
                nice sox ${wsprd_input_wav_filename} -n stat -freq 2> sox_fft.txt            # perform the fft
                nice awk -v freq_min=${SNR_FREQ_MIN-1338} -v freq_max=${SNR_FREQ_MAX-1662} '$1 > freq_min && $1 < freq_max {printf "%s %s\n", $1, $2}' sox_fft.txt > sox_fft_trimmed.txt      # extract the rows with frequencies within the 1340-1660 band

                ### Check to see if we are overflowing the /tmp/wsprdaemon file system
                local df_report_fields=( $(df ${WSPRDAEMON_TMP_DIR} | ${GREP_CMD} tmpfs) )
                local tmp_size=${df_report_fields[1]}
                local tmp_used=${df_report_fields[2]}
                local tmp_avail=${df_report_fields[3]}
                local tmp_percent_used=${df_report_fields[4]::-1}

                if [[ ${tmp_percent_used} -gt ${MAX_TMP_PERCENT_USED-90} ]]; then
                    wd_logger 1 "WARNING: ${WSPRDAEMON_TMP_DIR} is ${tmp_percent_used}% full.  Increase its size in /etc/fstab!"
                fi
                rm sox_fft.txt                                                               # Get rid of that 15 MB fft file ASAP
                nice sort -g -k 2 < sox_fft_trimmed.txt > sox_fft_sorted.txt                 # sort those numerically on the second field, i.e. fourier coefficient  ascending
                rm sox_fft_trimmed.txt                                                       # This is much smaller, but don't need it again
                local hann_adjust=6.0
                local fft_value=$(nice awk -v fft_adj=${fft_adjust} -v hann_adjust=${hann_adjust} '{ s += $2} NR > 11723 { print ( (0.43429 * 10 * log( s / 2147483647)) + fft_adj + hann_adjust) ; exit }'  sox_fft_sorted.txt)
                                                                                             # The 0.43429 is simply awk using natual log
                                                                                             #  the denominator in the sq root is the scaling factor in the text info at the end of the ftt file
                rm sox_fft_sorted.txt
                wd_logger 3 "sox_fft_value=${fft_value}"
            fi
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

            ### Output a line  which contains 'DATE TIME + three sets of four space-seperated statistics'i followed by the two FFT values followed by the approximate number of overload events recorded by a Kiwi during this WSPR cycle:
            ###                           Pre Tx                                                        Tx                                                   Post TX
            ###     'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'        'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB'       'Pk lev dB'  'RMS lev dB'  'RMS Pk dB'  'RMS Tr dB      RMS_noise C2_noise  New_overload_events'
            local signal_level_line="               ${pre_tx_levels[*]}          ${tx_levels[*]}          ${post_tx_levels[*]}   ${rms_value}    ${c2_FFT_nl_cal}  ${new_kiwi_ov_count}"
            echo "${wspr_decode_capture_date}-${wspr_decode_capture_time}: ${signal_level_line}" >> ${signal_level_log_file}
            local new_noise_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_noise.txt
            echo "${signal_level_line}" > ${new_noise_file}
            wd_logger 2 "noise was: '${signal_level_line}'"

            rm -f ${wav_file_name} ${wsprd_input_wav_filename}  ### We have completed processing the wav file, so delete both names for it

            ### 'wsprd' appends the new decodes to ALL_WSPR.TXT, but we are going to post only the new decodes which it puts in the file 'wspr_spots.txt'
            update_hashtable_archive ${real_receiver_name} ${real_receiver_band}

            ### Forward the recording's date_time_freqHz spot file to the posting daemon which is polling for it.  Do this here so that it is after the very slow sox FFT calcs are finished
            local new_spots_file=${wspr_decode_capture_date}_${wspr_decode_capture_time}_${wspr_decode_capture_freq_hz}_wspr_spots.txt
            if [[ ! -f wspr_spots.txt ]] || [[ ! -s wspr_spots.txt ]]; then
                ### A zero length spots file signals the posting daemon that decodes are complete but no spots were found
                rm -f ${new_spots_file}
                touch  ${new_spots_file}
                wd_logger 2 "no spots were found.  Queuing zero length spot file '${new_spots_file}'"
            else
                ###  Spots were found. We want to add the noise level fields to the end of each spot
                local spot_for_wsprnet=0         ### the posting_daemon() will fill in this field
                local tmp_spot_file="spots.tmp"
                rm -f ${tmp_spot_file}
                touch ${tmp_spot_file}
                local new_spots_count=$(cat wspr_spots.txt | wc -l)
                local all_wspr_new_lines=$(tail -n ${new_spots_count} ALL_WSPR.TXT)     ### Take the same number of lines from the end of ALL_WSPR.TXT as are in wspr_sport.txt

                ### Further validation of the spots we are going to upload
                ### Use the date in the wspr_spots.txt to extract the corresponding lines from ALL_WSPR.TXT and verify the number of spots extracted matches the number of spots in wspr_spots.txt
                local wspr_spots_date=$( awk '{printf "%s %s\n", $1, $2}' wspr_spots.txt | sort -u )
                local all_wspr_new_date_lines=$( grep "^${wspr_spots_date}" ALL_WSPR.TXT)
                local all_wspr_new_date_lines_count=$( echo "${all_wspr_new_date_lines}" | wc -l )
                if [[ ${all_wspr_new_date_lines_count} -ne ${new_spots_count} ]]; then
                    wd_logger 0 "WARNING: the ${new_spots_count} spot lines in wspr_spots.txt don't match the ${all_wspr_new_date_lines_count} spots with the same date in ALL_WSPR.TXT\n"
                fi

                ### Cull corrupt lines from ALL_WSPR.TXT
                local all_wspr_bad_new_lines=$(awk 'NF < 16 || NF > 17 || $5 < 0.1' <<< "${all_wspr_new_lines}")
                if [[ -n "${all_wspr_bad_new_lines}" ]]; then
                    wd_logger 0 "WARNING: removing corrupt line(s) in ALL_WSPR.TXT:\n%s\n" "${all_wspr_bad_new_lines}"
                    all_wspr_new_lines=$(awk 'NF >= 16 && NF <=  17 && $5 >= 0.1' <<< "${all_wspr_new_lines}")
                fi

                wd_logger 2 "processing these ALL_WSPR.TXT lines:\n${all_wspr_new_lines}"
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

		    local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID=11
		    local ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID=10
                    local got_valid_line="yes"
		    if [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITH_GRID} ]]; then
		        read spot_grid spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric <<< "${other_fields}"
                        wd_logger 2 "this V2.2 type 1 ALL_WSPR.TXT line has GRID: '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' '${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
		    elif [[ ${other_fields_list_count} -eq ${ALL_WSPR_OTHER_FIELDS_COUNT_DECODE_LINE_WITHOUT_GRID} ]]; then
                        spot_grid=""
                        read spot_pwr spot_drift spot_sync_quality spot_ipass spot_blocksize spot_jitter spot_osd_decode spot_nhardmin spot_decode_cycles spot_metric <<< "${other_fields}"
                        wd_logger 2 "this V2.2 type 2 ALL_WSPR.TXT line has no GRID: '${spot_date}' '${spot_time}' '${spot_sync_quality}' '${spot_snr}' '${spot_dt}' '${spot_freq}' '${spot_call}' '${spot_grid}' '${spot_pwr}' '${spot_drift}' '${spot_decode_cycles}' '${spot_jitter}' ${spot_blocksize}'  '${spot_metric}' '${spot_osd_decode}'"
                    else
                        wd_logger 0 "WARNING: tossing  a corrupt (not the expected 15 or 16 fields) ALL_WSPR.TXT spot line"
                        got_valid_line="no"
                    fi
                    if [[ ${got_valid_line} == "yes" ]]; then
                        #                              %6s %4s   %3d %3.0f %5.2f %11.7f %-22s          %2d %5u %4d  %4d %4d %2u\n"       ### fprintf() line from wsjt-x.  The %22s message field appears to include power
                        #local extended_line=$( printf "%4s %4s %5.2f %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4d, %2d %5d %2d %2d %3d %2d\n" \
                        local extended_line=$( printf "%6s %4s %5.2f %3.0f %5.2f %11.7f %-14s %-6s %2d %2d %5u %4s, %4d %4d %2u %2d %3d %2d\n" \
                        "${spot_date}" "${spot_time}" "${spot_sync_quality}" "${spot_snr}" "${spot_dt}" "${spot_freq}" "${spot_call}" "${spot_grid}" "${spot_pwr}" "${spot_drift}" "${spot_decode_cycles}" "${spot_jitter}" "${spot_blocksize}"  "${spot_metric}" "${spot_osd_decode}" "${spot_ipass}" "${spot_nhardmin}" "${spot_for_wsprnet}")
                        extended_line="${extended_line//[$'\r\n\t']}"  ### //[$'\r\n'] strips out the CR and/or NL which were introduced by the printf() for reasons I could not diagnose
                        echo "${extended_line}" >> ${tmp_spot_file}
                    fi
                done <<< "${all_wspr_new_lines}"
                local wspr_spots_file=${tmp_spot_file} 
                sed "s/\$/ ${rms_value}  ${c2_FFT_nl_cal}/" ${wspr_spots_file} > ${new_spots_file}  ### add  the noise fields
                wd_logger 2 "queuing enhanced spot file:\n$(cat ${new_spots_file})\n"
            fi

            ### Copy the noise level file and the renamed wspr_spots.txt to waiting posting daemons' subdirs
            shopt -s nullglob    ### * expands to NULL if there are no .wav wav_file
            local dir
            for dir in ${DECODING_CLIENTS_SUBDIR}/* ; do
                ### The decodes of this receiver/band are copied to one or more posting_subdirs where the posting_daemon will process them for posting to wsprnet.org
                wd_logger 2 "copying ${new_spots_file} and ${new_noise_file} to ${dir}/ monitored by a posting daemon" 
                cp -p ${new_spots_file} ${new_noise_file} ${dir}/
            done
            rm ${new_spots_file} ${new_noise_file}
        done
        wd_logger 3 "Decoded and posted ALL_WSPR file."
        sleep 1   ###  No need for a long sleep, since recording daemon should be creating next wav file and this daemon will poll on the size of that wav file
    done
    wd_logger 2 "stopping recording and decoding of '${real_receiver_name},${real_receiver_band}'"
    kill_recording_daemon ${real_receiver_name} ${real_receiver_band}
}


### 
function spawn_decode_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    local receiver_modes=$3
    wd_logger 1 "Starting with args  '${receiver_name},${receiver_band},${receiver_modes}'"
    local capture_dir=$(get_recording_dir_path ${receiver_name} ${receiver_band})


    mkdir -p ${capture_dir}/${DECODING_CLIENTS_SUBDIR}     ### The posting_daemon() should have created this already
    cd ${capture_dir}
    if [[ -f decode.pid ]] ; then
        local decode_pid=$(cat decode.pid)
        if ps ${decode_pid} > /dev/null ; then
            wd_logger 2 "A decode job with pid ${decode_pid} is already running, so nothing to do"
            return 0
        else
            wd_logger 1 "Found dead decode job"
            rm -f decode.pid
        fi
    fi
    wd_logger 1 "Spawning decode daemon in $PWD"
    WD_LOGFILE=decoding_daemon.log decoding_daemon ${receiver_name} ${receiver_band} ${receiver_modes} &
    echo $! > decode.pid
    cd - > /dev/null
    wd_logger 1 ": Finished.  Spawned new decode  job '${receiver_name},${receiver_band},${receiver_modes}' with PID '$!'"
    return 0
}

###
function get_decoding_status() {
    local get_decoding_status_receiver_name=$1
    local get_decoding_status_receiver_band=$2
    local get_decoding_status_receiver_decoding_dir=$(get_recording_dir_path ${get_decoding_status_receiver_name} ${get_decoding_status_receiver_band})
    local get_decoding_status_receiver_decoding_pid_file=${get_decoding_status_receiver_decoding_dir}/decode.pid

    if [[ ! -d ${get_decoding_status_receiver_decoding_dir} ]]; then
        [[ $verbosity -ge 0 ]] && echo "Never ran"
        return 1
    fi
    if [[ ! -f ${get_decoding_status_receiver_decoding_pid_file} ]]; then
        [[ $verbosity -ge 0 ]] && echo "No pid file"
        return 2
    fi
    local get_decoding_status_decode_pid=$(cat ${get_decoding_status_receiver_decoding_pid_file})
    if ! ps ${get_decoding_status_decode_pid} > /dev/null ; then
        [[ $verbosity -ge 0 ]] && echo "Got pid '${get_decoding_status_decode_pid}' from file, but it is not running"
        return 3
    fi
    echo "Pid = ${get_decoding_status_decode_pid}"
    return 0
}


