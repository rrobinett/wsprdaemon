#!/bin/bash

###  Wsprdaemon:   A robust  decoding and reporting system for  WSPR

###    Copyright (C) 2020-2021  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###   GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

declare WAV_RECORDING_DAEMON_PID_FILE="./wav_recording_daemon.pid"
declare WAV_RECORDING_DAEMON_LOG_FILE="./wav_recording_daemon.log"
declare WAV_RECORDING_DAEMON_STOP_FILE="./wav_recording_daemon.stop"
declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare WSPRD_CMD=${WSPRD_BIN_DIR}/wsprd
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare WSPRD_CMD_FLAGS="${WSPRD_CMD_FLAGS--C 500 -o 4 -d}"
declare WSPRD_STDOUT_FILE=wsprd_stdout.txt               ### wsprd stdout goes into this file, but we use wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                         ### Truncate the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..

function wav_recording_daemon_sig_handler() {
    local wav_recording_daemon_pid_file=$1

    wd_logger 1 "Got SIGTERM for wav_recording_daemon_pid_file = ${wav_recording_daemon_pid_file}"
    local wav_recording_daemon_pid=0
    if get_pid_from_file wav_recording_daemon_pid ${wav_recording_daemon_pid_file}; then
        wd_logger 1 "wav_recording daemon with pid ${wav_recording_daemon_pid} is running, so kill it"
       kill ${wav_recording_daemon_pid}
    fi
    rm ${wav_recording_daemon_pid_file}
}

### The decoding daemon calls this to start a daemon which creates 1 minute long wav files
function spawn_wav_recording_daemon() {
    local receiver_name=$1
    local receiver_band=$2
    local ret_code
    local wav_recording_daemon_pid=-1

    wd_logger 2 "Starting with args ${receiver_name} ${receiver_band}"
    if get_pid_from_file wav_recording_daemon_pid ${WAV_RECORDING_DAEMON_PID_FILE} ; then
       wd_logger 2 "wav recording daemon is running with pid ${wav_recording_daemon_pid}"
       return 0
    fi

    local  tuning_frequency=$(get_wspr_band_freq ${receiver_band}) 
    wd_logger 2 "Spawning wav recording job on SDR ${receiver_name} in band ${receiver_band} by tuning to frequency ${tuning_frequency}"
    case ${receiver_name} in
        KIWI*)
            #local tuning_frequency_khz=$(bc <<< "scale=2; ${tuning_frequency} / 1000")
            local tuning_frequency_khz=${tuning_frequency}  ## $(bc <<< "scale=2; ${tuning_frequency} / 1000")
            local recording_client_name=${KIWIRECORDER_CLIENT_NAME:-wsprdaemon_v${VERSION}}
            local receiver_ip=$(get_receiver_ip_from_name ${receiver_name})
            local my_receiver_password=$(get_receiver_password_from_name ${receiver_name})
            wd_logger 2 "Spawning a kwirecorder job for kiwi ${receiver_name} at ${receiver_ip} using password ${my_receiver_password}"
            ### check_for_kiwirecorder_cmd
            ### python -u => flush diagnostic output at the end of each line so the log file gets it immediately
            python3 -u ${KIWI_RECORD_COMMAND} \
                --freq=${tuning_frequency_khz} --server-host=${receiver_ip/:*} --server-port=${receiver_ip#*:} \
                --OV --user=${recording_client_name}  --password=${my_receiver_password} \
                --agc-gain=60 --quiet --no_compression --modulation=usb  --lp-cutoff=${LP_CUTOFF-1340} --hp-cutoff=${HP_CUTOFF-1660} --dt-sec=60 > ${WAV_RECORDING_DAEMON_LOG_FILE} 2>&1 &
            ret_code=$?
            if [[ ${ret_code} -ne 0 ]]; then
                 wd_logger 1 "ERROR: ${KIWI_RECORD_COMMAND} => ${ret_code}"
                 sleep 1
             else
                 wav_recording_daemon_pid=$!
                 echo ${wav_recording_daemon_pid} > kiwi_recorder.pid
                 ## Initialize the file which logs the date (in epoch seconds, and the number of OV errors st that time
                 printf "$(date +%s) 0" > ov.log
                 wd_logger 1 "My PID $$ spawned kiwrecorder PID ${wav_recording_daemon_pid}"
            fi
            ;;
        SDR*)
            local sdr_device="TODO"   ### TODO: get address of the device which can be understood by sdrTest
            local center_frequency=$(( ${tuning_frequency} - ${ATSC_CENTER_OFFSET_HZ} ))
            (sdrTest -f ${tuning_frequency} -fc ${center_frequency} -usb -device ${sdr_device} -faudio ${SDR_AUDIO_SPS} -dumpbyminute  > ${WAV_RECORDING_DAEMON_LOG_FILE} 2>&1) &
            ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                wav_recording_daemon_pid=$!
                wd_logger 1 "sdrTest daemon was spawned with pid ${wav_recording_daemon_pid}"
            else
                 wd_logger 1 "ERROR: sdrTest -f ${tuning_frequency} -fc ${center_frequency} -usb -device ${sdr_device} -faudio ${SDR_AUDIO_SPS} -timeout ${SDR_SAMPLE_TIME}... => ${ret_code}"
            fi
            sleep 1
            ;;
        *)
            wd_logger 1 "ERROR: SDR named ${receiver_name} is not supported"
            exit 1
            ;;
    esac
    if [[ ${wav_recording_daemon_pid} -le 0 ]]; then
        wd_logger 1 "Failed to spawn wav_recording daemon"
        rm -f ${WAV_RECORDING_DAEMON_PID_FILE}
    else
       wd_logger 2 "Spawned job has pid ${wav_recording_daemon_pid}"
       echo ${wav_recording_daemon_pid} > ${WAV_RECORDING_DAEMON_PID_FILE}
       trap "wav_recording_daemon_sig_handler ${WAV_RECORDING_DAEMON_PID_FILE}" SIGTERM
   fi
   return ${ret_code}

}

function kill_wav_recording() {
    wd_logger 1 "killing daemon"

    local wav_recording_daemon_pid=0
    if ! get_pid_from_file wav_recording_daemon_pid ${WAV_RECORDING_DAEMON_PID_FILE} ]]; then
        wd_logger 1 "No ${WAV_RECORDING_DAEMON_PID_FILE} or no job with that pid is running, so nothing to do"
        return 0
    fi

    kill ${wav_recording_daemon_pid}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "Killed ${wav_recording_daemon_pid} found in '${WAV_RECORDING_DAEMON_PID_FILE}'"
    else
        wd_logger 1 "Error ${ret_code} was returned when executing 'kill ${wav_recording_daemon_pid}' found in '${WAV_RECORDING_DAEMON_PID_FILE}'"
    fi
    return ${ret_code}
    
    ### TODO: If this is an AUDIO device, then single that recording daemon for a clean shudown

    wd_logger 1 "Signaling deamon with pid ${wav_recording_daemon_pid} to stop by creating '${WAV_RECORDING_DAEMON_STOP_FILE}'"
    touch ${WAV_RECORDING_DAEMON_STOP_FILE}
    local loop_count
    for (( loop_count=10; loop_count > 0; --loop_count ))  ; do
        wd_logger 1 "Waiting for deamon to stop"
        if [[ ! -f ${WAV_RECORDING_DAEMON_STOP_FILE} ]]; then
            wd_logger 1 "'${WAV_RECORDING_DAEMON_STOP_FILE}' disappeared while waiting for deamon to stop, so this is a clean exit"
            break
        fi
        sleep 1
    done
    if [[ ${loop_count} -eq 0 ]]; then
        wd_logger 1 "Timeout waiting for daemon to stop, so killing pid ${wav_recording_daemon_pid}, and also 'killall SDR_Recording_Daemon'"
        kill ${wav_recording_daemon_pid}
        killall sdrTest
    else
        wd_logger 1 "Deamon stopped on its own"
    fi
    rm -f ${WAV_RECORDING_DAEMON_STOP_FILE} ${WAV_RECORDING_DAEMON_PID_FILE}
    return 0
}

declare flush_zombie_raw_files="no"
function flush_zombie_raw_files {
    local oldest_file_needed=$1
    if [[ ${flush_zombie_raw_files} != "yes" ]]; then
        return 0
    fi
    
    shopt -s nullglob
    local wav_file_list=( minute-*.raw )
    shopt -u nullglob
    local current_epoch=$(date +%s)
    local oldest_file_epoch=$(( ${current_epoch} - ${oldest_file_needed} ))
     wd_logger 2 "current epoch is ${current_epoch}, so flushing files older than ${oldest_file_epoch} from list of ${#wav_file_list[@]} minute-*raw files in $PWD"

    local index
    for (( index=0 ; index < ${#wav_file_list[@]}; ++index )); do
        local file_name=${wav_file_list[index]}
        local file_epoch=$(stat -c %Y ${file_name})
         wd_logger 2 "file ${file_name} epoch is ${file_epoch}"
        if [[ ${file_epoch} -lt ${oldest_file_epoch} ]]; then
             wd_logger 1 "flushing old file ${file_name}"
            rm -f ${file_name}
        else
             wd_logger 1 "keeping file ${file_name}"
        fi
    done
}
 
declare RAW_FILE_FULL_SIZE=1440000   ### Approximate number of bytes in a full size one minute long raw or wav file

### If the wav recording daemon is running, we can calculate how many seconds until it starts to fill the raw file (if 0 length first file) or fills the 2nd raw file.  Sleep until then
function sleep_until_raw_file_is_full() {
    local filename=$1
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
    wd_logger 1 "File ${filename} stabliized at size ${new_file_size} after ${loop_seconds} seconds"
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

    spawn_wav_recording_daemon ${receiver_name} ${receiver_band}     ### Make sure the wav recorder is running

    local ret_code

    shopt -s nullglob
    local raw_file_list=( minute-*.raw *_usb.wav)        ### Get list of the one minute long 'raw' wav files being created by the Kiwi (.wav) or SDR ((.raw)
    shopt -u nullglob

    wd_logger 2 "Found raw/wav files '${raw_file_list[*]}'"
    case ${#raw_file_list[@]} in
        0 )
            wd_logger 1 "There are no raw files.  Wait up to 10 seconds for the first file to appear"
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
                wd_logger 1 "First file appeared after waiting ${timeout} seconds"
            fi
            return 1
            ;;
        1 )
            wd_logger 1 "There is only 1 raw file ${raw_file_list[0]} and all modes need at least 2 minutes. So wait for this file to be filled"
            sleep_until_raw_file_is_full ${raw_file_list[0]}
            local second_from_file_name=${raw_file_list[0]:13:2}
            if [[ 10#${second_from_file_name} -ne 0 ]]; then
                wd_logger 1 "Raw file '${raw_file_list[0]}' name says this file recording start at second ${second_from_file_name}, not at second 0, so flushing it"
                rm ${raw_file_list[0]}
            fi
            return 2
            ;;
        *)
            wd_logger 1 "Found ${#raw_file_list[@]} files, so we *may* have enough 1 minute wav files to make up a WSPR pkt. Wait until the last file is full, then proceed to process the list."
            sleep_until_raw_file_is_full ${raw_file_list[-1]}
            ;;
    esac

    wd_logger 1 "Found ${#raw_file_list[@]} full raw files. Fill return list with lists of those raw files which are part of each WSPR mode"
    ### We now have a list of two or more full size raw files
    local epoch_of_first_raw_file=$(stat -c %Y ${raw_file_list[0]})
    local index_of_first_file_which_needs_to_be_saved=${#raw_file_list[@]}                         ### Presume we will need to keep none of the raw files

    local return_list=()
    local seconds_in_wspr_pkt
    for seconds_in_wspr_pkt in  ${target_seconds_list[@]} ; do
        local raw_files_in_wav_file_count=$((seconds_in_wspr_pkt / 60))
        wd_logger 1 "Check to see if we can create a new ${seconds_in_wspr_pkt} seconds long wav file from ${raw_files_in_wav_file_count} raw files"

        local epoch_of_first_raw_file=$( stat -c %Y ${raw_file_list[0]})
        local minute_of_first_raw_file=$( date -r ${raw_file_list[0]} +%M )   ### Could b derived from epoch, I guess
        wd_logger 1 "The first raw file ${raw_file_list[0]} write time is at minute ${minute_of_first_raw_file}"

        ### Check to see if we have previously returned some of these files in a previous call to this function
        shopt -s nullglob
        local wav_raw_pkt_list=( *.wav.${seconds_in_wspr_pkt}-secs )
        shopt -u nullglob

        local index_of_first_unreported_raw_file
        local index_of_last_unreported_file
        if [[ ${#wav_raw_pkt_list[@]} -eq 0 ]]; then
            wd_logger 1 "Found no wav_secs files for wspr pkts of this length, so there were no previously reported packets of this length. So find index of first raw file that would start a wav file of this many seconds"
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
            wd_logger 1 "Raw_file ${raw_file_list[0]} of minute ${minute_of_first_raw_sample} is raw pkt #${first_minute_raw_wspr_pkt_index} of a ${seconds_in_wspr_pkt} second long wspr packet. So start of next wav_raw will be found at raw_file index ${index_of_first_unreported_raw_file}"
        else
            wd_logger 1 "Found that we previously returned ${#wav_raw_pkt_list[@]} wav files of this length"
            
            if [[ ${#wav_raw_pkt_list[@]} -eq 1 ]]; then
                wd_logger 1 "There is only one wav_raw pkt ${wav_raw_pkt_list[@]}, so leave it alone"
            else
                local flush_count=$(( ${#wav_raw_pkt_list[@]} - 1 ))
                local flush_list=( ${wav_raw_pkt_list[@]:0:${flush_count}} )
                if [[ ${#flush_list[*]} -gt 0 ]]; then
                    wd_logger 1 "Flushing ${#flush_list[@]} files '${flush_list[*]}' leaving only ${wav_raw_pkt_list[-1]}"
                    rm ${flush_list[*]}
                else
                    wd_logger 1 "ERROR: wav_raw_pkt_list[] has ${#wav_raw_pkt_list[@]} files, but flush_list[] is empty"
                fi
            fi

            local filename_of_latest_wav_raw=${wav_raw_pkt_list[-1]}
            local epoch_of_latest_wav_raw_file=$( stat -c %Y ${filename_of_latest_wav_raw} )
            local index_of_first_reported_raw_file=$(( ( epoch_of_latest_wav_raw_file - epoch_of_first_raw_file ) / 60 ))
            index_of_first_unreported_raw_file=$(( index_of_first_reported_raw_file + raw_files_in_wav_file_count ))

            wd_logger 1 "Latest wav_raw ${filename_of_latest_wav_raw} has epoch ${epoch_of_latest_wav_raw_file}. epoch_of_first_raw_file == ${epoch_of_first_raw_file}.  So index_of_first_unreported_raw_file = ${index_of_first_unreported_raw_file}"
        fi
        if [[ ${index_of_first_unreported_raw_file} -ge ${#raw_file_list[@]} ]]; then
            wd_logger 1 "The first first raw file of a wav_raw file is not yet in the list of minute_raw[] files.  So continue to search for the next WSPR pkt length"
            continue
        fi

        ### The first file is present, now see if the last file is also present
        index_of_last_raw_file_for_this_wav_file=$(( index_of_first_unreported_raw_file + raw_files_in_wav_file_count - 1))

        if [[ ${index_of_last_raw_file_for_this_wav_file} -ge ${#raw_file_list[@]} ]]; then
            ### The last file isn't present
            if [[ ${index_of_first_unreported_raw_file} -lt ${index_of_first_file_which_needs_to_be_saved} ]]; then
                wd_logger 1 "The first unsaved file is at index ${index_of_first_unreported_raw_file}, but the last index is not yet present. Adjust index_of_first_file_which_needs_to_be_saved to ${index_of_first_file_which_needs_to_be_saved}"
                index_of_first_file_which_needs_to_be_saved=${index_of_first_unreported_raw_file}
            fi
            wd_logger 1 "The first unreported ${seconds_in_wspr_pkt} seconds raw file is at index ${index_of_first_unreported_raw_file}, but the last raw file is not yet present, so we can't yet create a wav file. So continue to search for the next WSPR pkt length"
            continue
         fi
         ### There is a run of files which together form a wav file of this seconds in length
         local this_seconds_files="${seconds_in_wspr_pkt}:${raw_file_list[*]:${index_of_first_unreported_raw_file}:${raw_files_in_wav_file_count} }"
         local this_seconds_comma_separated_file=${this_seconds_files// /,}
         return_list+=( ${this_seconds_comma_separated_file} )
         wd_logger 1 "Added file list for ${seconds_in_wspr_pkt} second long wav file to return list from index [${index_of_first_unreported_raw_file}:${index_of_last_raw_file_for_this_wav_file}] => ${this_seconds_comma_separated_file}"

         local wav_list_returned_file=${raw_file_list[${index_of_first_unreported_raw_file}]}.${seconds_in_wspr_pkt}-secs
         shopt -s nullglob
         local flush_list=( *.${seconds_in_wspr_pkt}-secs )
         shopt -u nullglob
         if [[ ${#flush_list[@]} -gt 0 ]]; then
             wd_logger 1 "Flushing ${#flush_list[@]} old wav_raw file(s): ${flush_list[*]}"
             rm -f ${flush_list[@]}    ### We only need to remember this new wav_raw file, so flush all older ones.
         fi
         touch -r ${raw_file_list[${index_of_first_unreported_raw_file}]} ${wav_list_returned_file}
         
         wd_logger 1 "Remembered that this wav file has been returned to the decoder by creating the zero length file ${wav_list_returned_file}"
    done
    
    if [[ ${index_of_first_file_which_needs_to_be_saved} -lt ${#raw_file_list[@]} ]] ; then
        local count_of_raw_files_to_flush=$(( index_of_first_file_which_needs_to_be_saved ))
        wd_logger 1 "After searching for all requested wav file lengths, found file [${index_of_first_file_which_needs_to_be_saved}] '${raw_file_list[${index_of_first_file_which_needs_to_be_saved}]}' is the oldest file which needs to be saved" 
        if [[ ${count_of_raw_files_to_flush} -gt 0 ]]; then
            wd_logger 1 "So purging files '${raw_file_list[*]:0:${count_of_raw_files_to_flush}}'"
            rm ${raw_file_list[@]:0:${count_of_raw_files_to_flush}}
        fi
    fi
    wd_logger 1 "Returning ${#return_list[@]} wav file lists: '${return_list[*]}'"
    eval ${return_variable_name}="${return_list[*]}"
    return 0
 }

function old_decode() {

    while true; do
        ### kwirecorder.py creates wave files with names which reflect the record minute of the first audio byte in the file
        ### In contrast, sdrTest just increments the file number and the file timestamp is for the last audio byte in the file.
        ### So subtract 60 seconds from the last write time of the sdrTest minute-xxx.raw file to get the time of the first audio byte and use that to create a wav file with the same name format as kiwirecorder.py
        local wav_raw_filename=$(date -u -d @$(( $(stat -c %Y ${minute_raw_file_list[${first_unsaved_minute_raw_index}]} ) - 60 ))  +%G%m%dT%H%M00-${wspr_pkt_len_seconds}-secs.wav)
        wd_logger 1 "Created ${wav_raw_filename} starting with '${minute_raw_file_list[${first_unsaved_minute_raw_index}]}'"
        cat ${minute_raw_file_list[@]:${first_unsaved_minute_raw_index}:${raw_files_in_wav_file_count}} | sox -r 12000 -t raw  -e s -b 16 -c 1 - ${wav_raw_filename}
        touch -r ${minute_raw_file_list[${first_unsaved_minute_raw_index}]}   ${wav_raw_filename}

        ### wsprd extracts the spot times from the wav file's name, so 
        local wspr_decode_capture_date=${wav_raw_filename/T*}
        wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
        local wspr_decode_capture_time=${wav_raw_filename#*T}
        wspr_decode_capture_time=${wspr_decode_capture_time/-*}
        local wspr_decode_capture_sec=${wspr_decode_capture_time:4}
        if [[ ${wspr_decode_capture_sec} != "00" ]]; then
            wd_logger 1 "ERROR: wav file named '${wav_raw_filename}' shows that recording didn't start at second "00". Delete this file and go to next wav file."
            rm -f ${wav_raw_filename}
            continue
        fi
        local wspr_decode_capture_min=${wspr_decode_capture_time:2:2}
        wspr_decode_capture_time=${wspr_decode_capture_time:0:4}
        local wsprd_input_wav_filename=${wspr_decode_capture_date}_${wspr_decode_capture_time}.wav    ### wsprd prepends the date_time to each new decode in wspr_spots.txt

        ### Decode the wav file we have just created
        set +x
        for decode_mode in wspr fst4w ; do
            local subdir=${wspr_pkt_len_seconds}/${decode_mode}
            mkdir -p ${subdir}
            ln ${wav_raw_filename} ${subdir}/${wsprd_input_wav_filename}
            cd ${subdir}
            local wsprd_cmd_flags=${WSPRD_CMD_FLAGS}
            local wspr_decode_capture_freq_mhz=$(bc <<< "scale=7;${tuning_frequency}/1000000")
            if [[ ${decode_mode} == "wspr" ]]; then
                wd_logger 1 "Decoding WSPR: '${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wsprd_input_wav_filename}'"
                ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wsprd_input_wav_filename} > ${WSPRD_STDOUT_FILE}
                touch ALL_WSPR.TXT
                local all_wspr_size=$(stat -c %s ALL_WSPR.TXT)
                if [[ ${all_wspr_size} -gt ${MAX_ALL_WSPR_SIZE} ]]; then
                    local all_wspr_lines=$(wc -l < ALL_WSPR.TXT)
                    local lines_to_delete=$(( all_wspr_lines / 4 ))
                    wd_logger 1 "ALL_WSPR.TXT of size ${all_wspr_size} bytes / ${all_wspr_lines} has grown too large.  Truncate the first ${lines_to_delete} lines to shrink it"
                    sed -i "1,${lines_to_delete} d" ALL_WSPR.TXT 
                fi
            else
                wd_logger 1 "Decoding FST4W: '${JT9_CMD} --fst4w -p ${wspr_pkt_len_seconds} ${wsprd_input_wav_filename} > ${WSPRD_STDOUT_FILE}'"
                echo ${JT9_CMD} --fst4w -p ${wspr_pkt_len_seconds} ${wsprd_input_wav_filename} > ${WSPRD_STDOUT_FILE}
            fi
            rm ${wsprd_input_wav_filename}
            local stdout_text=$(grep "^[0-9]" ${WSPRD_STDOUT_FILE})
            if [[ $(wc -l <<< "${stdout_text}" ) -gt 0 ]]; then
                wd_logger 1 "Decoded ${decode_mode} spots: ${stdout_text}"
            fi
            cd - > /dev/null
        done
        ### We have finished decoding the wav file, so leave behind a zero length version of it that saves disk space while signaling that raw files are no longer needed
        truncate -s 0 ${wav_raw_filename}
        touch -r ${minute_raw_file_list[${first_unsaved_minute_raw_index}]} ${wav_raw_filename}
        ### wav_raw_filename will be the most recent wav file, so we can delete all the other existing wav files
        if [[ ${#wav_raw_pkt_list[@]} -gt 0 ]]; then
            wd_logger 1 "Decoding done. Remove the older wav_raw files: '${wav_raw_pkt_list[@]}'"
            rm ${wav_raw_pkt_list[@]}
        fi
        set +x

        first_unsaved_minute_raw_index=$(( first_unsaved_minute_raw_index + raw_files_in_wav_file_count ))
        if [[ ${first_unsaved_minute_raw_index} -lt ${index_of_first_file_which_needs_to_be_saved} ]]; then
            index_of_first_file_which_needs_to_be_saved=${first_unsaved_minute_raw_index}
            wd_logger 1 "We need to save files starting at minute_raw index ${first_unsaved_minute_raw_index}" 
        fi
    done   ### with: wspr_pkt_len_seconds in ${wspr_lengths_secs[@]}; do

    if [[ ${index_of_first_file_which_needs_to_be_saved} -gt 0  ]]; then
        rm -f ${minute_raw_file_list[@]:0:${index_of_first_file_which_needs_to_be_saved}}
        wd_logger 1 "Deleted minute_raw files [0:${index_of_first_file_which_needs_to_be_saved}] which  will not be needed in future wav_raw files"
    else
        wd_logger 1 "Keeping all ${#minute_raw_file_list[@]} minute_raw files since tbe first file will be needed in future wav_raw files"
    fi
    wd_logger 1 "Finished processing all wav file lengths"

    return 1
    ### We have been instructed to terminate...
    if [[ ${wav_recording_daemon_pid} -ne 0 ]]; then
        kill ${wav_recording_daemon_pid}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: terminating after detecting '${WAV_RECORDING_DAEMON_STOP_FILE}' while SDR_Recording_Daemon is running, but 'kill ${wav_recording_daemon_pid}' => ${ret_code}"
        else
            wd_logger 1 "clean termination after detecting '${WAV_RECORDING_DAEMON_STOP_FILE}' while SDR_Recording_Daemon is running, after sucessfull 'kill ${wav_recording_daemon_pid}'"
        fi
    else
        wd_logger 1 "clean termination after detecting '${WAV_RECORDING_DAEMON_STOP_FILE}' when no wav_recording_daemon_pid"
    fi
    rm -f ${SDR_RECORDING_DAEMON_PID_FILE} ${WAV_RECORDING_DAEMON_STOP_FILE}
}


