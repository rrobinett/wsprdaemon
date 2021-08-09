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

declare SDR_RECORDING_DAEMON_PID_FILE="./sdr_recording_job.pid"
declare SDR_RECORDING_DAEMON_LOG_FILE="./sdr_recording_job.log"
declare WAV_RECORDING_DAEMON_PID_FILE="./wav_recording_daemon.pid"
declare WAV_RECORDING_DAEMON_LOG_FILE="./wav_recording_daemon.log"
declare WAV_RECORDING_DAEMON_STOP_FILE="./wav_recording_daemon.stop"

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
             wd_logger 0 "flushing old file ${file_name}"
            rm -f ${file_name}
        else
             wd_logger 0 "keeping file ${file_name}"
        fi
    done
}
 
declare RAW_FILE_FULL_SIZE=1440000   ### Number of types in a full size one kinute long raw file

### If SDR_Recording_Daemon is running we can calculate how many seconds until it starts to fill the raw file (if 0 length first file) or fills the 2nd raw file.  Sleep until then
function sleep_until_raw_file_is_full() {
    local filename=$1
    local current_file_size=$(stat -c %s ${filename})
    local sleep_secs=$(( (${RAW_FILE_FULL_SIZE} - ${current_file_size}) / ( ${RAW_FILE_FULL_SIZE} / 60 ) ))        ### If SDR_Recording_Daemon is filling the first raw file we can calculate how many seconds until it fills the raw file and sleep until then
    if [[ ${sleep_secs} -gt 0 ]]; then
        (( ++sleep_secs ))
        wd_logger 0 "file ${filename} is ${current_file_size} bytes, not full size ${RAW_FILE_FULL_SIZE}. Sleep for ${sleep_secs} seconds while it fills."
    elif [[ ${current_file_size} -lt ${RAW_FILE_FULL_SIZE} ]]; then
        sleep_secs=1
        wd_logger 0 "file ${filename} is ${current_file_size} but there is one second of raw audio needed to fill it"
    else
        wd_logger 0 "file ${filename} is is full size.  So no need to sleep."
    fi
    if [[ ${sleep_secs} -gt 0 ]]; then
        local end_seconds=$(( ${SECONDS} + ${sleep_secs} ))
        wd_logger 3 "Starting at SECONDS=${SECONDS}, loop for a total of ${sleep_secs} seconds while sleeping for 1 second"
        ### Wake up every second so a SIGTERM trap can be handled and thus we can cleanly exit
        while [[ ${SECONDS} -lt ${end_seconds} ]] ; do
            wd_logger 4 "Awake"
            sleep 1
        done
    fi
}

function wav_recording_daemon_sig_handler() {
    local sdr_recording_daemon_pid=$1

    wd_logger 0 "Got SIGTERM for sdr_recording_daemon_pid = ${sdr_recording_daemon_pid}"
    kill ${sdr_recording_daemon_pid}
}

declare WSPRD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare WSPRD_CMD=${WSPRD_BIN_DIR}/wsprd
declare JT9_CMD=${WSPRD_BIN_DIR}/jt9
declare WSPRD_CMD_FLAGS="${WSPRD_CMD_FLAGS--C 500 -o 4 -d}"
declare WSPRD_STDOUT_FILE=wsprd_stdout.txt               ### wsprd stdout goes into this file, but we use wspr_spots.txt
declare MAX_ALL_WSPR_SIZE=200000                         ### Truncate the ALL_WSPR.TXT file once it reaches this size..  Stops wsprdaemon from filling ${WSPRDAEMON_TMP_DIR}/..

function spawn_sdr_recording_daemon() {
    local sdr_device_name=$1
    local tuning_frequency=$2

    wd_logger 0 "Spawning wav recording job on SDR ${sdr_device} at frequency ${tuning_frequency}"
    case ${sdr_device_name} in
        *)
            local center_frequency=$(( ${tuning_frequency} - ${ATSC_CENTER_OFFSET_HZ} ))
            (sdrTest -f ${tuning_frequency} -fc ${center_frequency} -usb -device ${sdr_device} -faudio ${SDR_AUDIO_SPS} -dumpbyminute  > ${SDR_RECORDING_DAEMON_LOG_FILE} 2>&1) &
            ret_code=$?
            sdr_recording_daemon_pid=$!
            if [[ ${ret_code} -ne 0 ]]; then
                 wd_logger 0 "ERROR: sdrTest -f ${tuning_frequency} -fc ${center_frequency} -usb -device ${sdr_device} -faudio ${SDR_AUDIO_SPS} -timeout ${SDR_SAMPLE_TIME}... => ${ret_code}"
                killall sdrTest
                sleep 5
                continue
            fi
            sleep 1
            ;;
        KIWI*)
            local tuning_frequency_khz=$(bc <<< "scale=2; ${tuning_frequency} / 1000")
            local recording_client_name=${KIWIRECORDER_CLIENT_NAME:-wsprdaemon_v${VERSION}}
            ### check_for_kiwirecorder_cmd
            ### python -u => flush diagnostic output at the end of each line so the log file gets it immediately
            python3 -u ${KIWI_RECORD_COMMAND} \
                --freq=${tuning_frequency_khz} --server-host=${receiver_ip/:*} --server-port=${receiver_ip#*:} \
                --OV --user=${recording_client_name}  --password=${my_receiver_password} \
                --agc-gain=60 --quiet --no_compression --modulation=usb  --lp-cutoff=${LP_CUTOFF-1340} --hp-cutoff=${HP_CUTOFF-1660} --dt-sec=60 > kiwi_recorder.log 2>&1 &
            recorder_pid=$!
            echo ${recorder_pid} > kiwi_recorder.pid
            ## Initialize the file which logs the date (in epoch seconds, and the number of OV errors st that time
            printf "$(date +%s) 0" > ov.log
            if [[ $verbosity -ge 2 ]]; then
                echo "$(date): kiwi_recording_daemon() PID $$ spawned kiwrecorder PID ${recorder_pid}"
                ps -f -q ${recorder_pid}
            fi
            ;;
        *)
            wd_logger 0 "ERROR: SDR named ${sdr_device_name} is not supported"
            exit 1
            ;;
    esac
    wd_logger 0 "Spawned job has pid ${sdr_recording_daemon_pid}. Sleep 1 so that sdrTest can create the output file." 
    echo ${sdr_recording_daemon_pid} > ${SDR_RECORDING_DAEMON_PID_FILE}
    trap "wav_recording_daemon_sig_handler ${sdr_recording_daemon_pid}" SIGTERM

}
 
function wav_recording_daemon() {
    local sdr_device=$1
    local wspr_band=${2//[^[:ascii:]]/}    ### Strip off any non-printing characters
    shift 2
    local wspr_lengths_secs=( $* )

    wd_logger 0 "Tune SDR '${sdr_device}' to WSPR band ${wspr_band} and create wav files" 

    local tuning_frequency
    get_wspr_tuning_frquency   tuning_frequency ${wspr_band}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
         wd_logger 0 "ERROR: get_wspr_tuning_frquency tuning_frequency ${wspr_band} => ${ret_code}"
        return 1
    fi

    ### We expect that the list of wav files to be generated is in ascending seconds order, i.e "120 300 900 1800)
    local index_last=$(( ${#wspr_lengths_secs[@]} - 1 ))
    local oldest_file_needed=$(( ${wspr_lengths_secs[index_last]} + 1 ))

    wd_logger 0 "Tune SDR '${sdr_device}' to WSPR band ${wspr_band} which is at tuning frequency ${tuning_frequency}.  Flush raw files older than ${oldest_file_needed} seconds"

    while [[ ! -f ${WAV_RECORDING_DAEMON_STOP_FILE} ]]; do
        local ret_code

        local sdr_recording_daemon_pid=0
        if [[ -f ${SDR_RECORDING_DAEMON_PID_FILE} ]]; then
            sdr_recording_daemon_pid=$(< ${SDR_RECORDING_DAEMON_PID_FILE})
            ps ${sdr_recording_daemon_pid} > /dev/null
            ret_code=$?
            if [[ ${ret_code} -eq 0 ]]; then
                wd_logger 2 "found a SDR_Recording_Daemon job with pid ${sdr_recording_daemon_pid} is running, so no need to spawn a SDR_Recording_Daemon job"
            else
                wd_logger 0 "file ${SDR_RECORDING_DAEMON_PID_FILE} contains pid #${sdr_recording_daemon_pid}, but 'ps ${sdr_recording_daemon_pid} => ${ret_code}', so flush that dead pid file"
                sdr_recording_daemon_pid=0
                rm -f ${SDR_RECORDING_DAEMON_PID_FILE}
            fi

        fi
        if [[ ${sdr_recording_daemon_pid} -eq 0 ]] ; then
            wd_logger 0 "Spawning new SDR_Recording_Daemon job"
            spawn_sdr_recording_daemon ${sdr_device} ${tuning_frequency} 
        fi
        shopt -s nullglob
        local minute_raw_file_list=( minute-*.raw )
        shopt -u nullglob

        case ${#minute_raw_file_list[@]} in
            0 )
                 wd_logger 0 "SDR_Recording_Daemon is running or was spawned, but there is no raw file. Sleep 5, then go to top, check for running SDR_Recording_Daemon and spawn again if needed."
                sleep 5
                continue
                ;;
            1 )
                sleep_until_raw_file_is_full ${minute_raw_file_list[-1]}
                continue
                ;;
            *)
                 wd_logger 0 "found ${#minute_raw_file_list[@]} files. Wait until the last file is full, then proceed to process the list."
                sleep_until_raw_file_is_full ${minute_raw_file_list[-1]}
                ;;
        esac

        ### We now have a list of two or more full size raw files
        local first_minute_raw_file_epoch=$(stat -c %Y ${minute_raw_file_list[0]})
        local first_needed_minute_raw_file_index=${#minute_raw_file_list[@]}                         ### Presume we will need to keep none of the raw files
     
        local wspr_pkt_len_seconds
        for wspr_pkt_len_seconds in  ${wspr_lengths_secs[@]} ; do
            wd_logger 0 "Check to see if we can create a new ${wspr_pkt_len_seconds} seconds wav file"

            local raw_files_in_wav_file_count=$((wspr_pkt_len_seconds / 60))

            local first_minute_raw_file_epoch=$( stat -c %Y ${minute_raw_file_list[0]})
            local first_minute_raw_file_minute=$( date -r ${minute_raw_file_list[0]} +%M )   ### Could b derived from epoch, I guess

            shopt -s nullglob
            local wav_raw_pkt_list=( *-${wspr_pkt_len_seconds}-secs.wav )
            shopt -u nullglob

            local first_unsaved_minute_raw_index
            local last_unsaved_raw_index
            if [[ ${#wav_raw_pkt_list[@]} -gt 0 ]]; then
                local latest_wav_raw_filename=${wav_raw_pkt_list[-1]}
                local latest_wav_raw_file_epoch=$( stat -c %Y ${latest_wav_raw_filename} )
                local latest_wav_raw_file_index=$(( ( latest_wav_raw_file_epoch - first_minute_raw_file_epoch ) / 60 ))

                first_unsaved_minute_raw_index=$(( latest_wav_raw_file_index + raw_files_in_wav_file_count ))
                wd_logger 0 "Found most recent wav_raw file ${latest_wav_raw_filename}. So start of next wav_raw  will be found at index ${first_unsaved_minute_raw_index}"
           else
                local first_audio_sample_minute=$(( 10#${first_minute_raw_file_minute} - 1))
                local first_minute_raw_wspr_pkt_index=$(( first_audio_sample_minute % raw_files_in_wav_file_count ))
                first_unsaved_minute_raw_index=$(( (raw_files_in_wav_file_count - first_minute_raw_wspr_pkt_index) % raw_files_in_wav_file_count ))
                 wd_logger 0 "Found no wav_raw files.  So start of next wav_raw will be found at index ${first_unsaved_minute_raw_index}"
            fi
            last_unsaved_minute_raw_index=$(( first_unsaved_minute_raw_index + raw_files_in_wav_file_count - 1))

            if [[ ${first_unsaved_minute_raw_index} -ge ${#minute_raw_file_list[@]} ]]; then
                wd_logger 0 "The first first raw file of a wav_raw file is not yet in the list of minute_raw[] files.  So continue to search for the next WSPR pkt length"
               continue
            fi
            if [[ ${last_unsaved_minute_raw_index} -ge ${#minute_raw_file_list[@]} ]]; then
                if [[ ${first_unsaved_minute_raw_index} -lt ${first_needed_minute_raw_file_index} ]]; then
                    wd_logger 0 "The first unsaved file is at index ${first_unsaved_minute_raw_index}, but the last index is not yet present. This is now the oldest file needed to create the next ${wspr_pkt_len_seconds} seconds wav file"
                    first_needed_minute_raw_file_index=${first_unsaved_minute_raw_index}
                else
                    wd_logger 0 "The first unsaved ${wspr_pkt_len_seconds} seconds raw file is at index ${first_unsaved_minute_raw_index}, but the last index raw file is not yet present, so we can't yet create a wav file"
                fi
                continue
            fi
            wd_logger 0 "Found a whole wav file can be created from files  starting at index ${first_unsaved_minute_raw_index} and ending at ${last_unsaved_minute_raw_index}"

            ### kwirecorder.py creates wave files with names which reflect the record minute of the first audio byte in the file
            ### In contrast, sdrTest just increments the file number and the file timestamp is for the last audio byte in the file.
            ### So subtract 60 seconds from the last write time of the sdrTest minute-xxx.raw file to get the time of the first audio byte and use that to create a wav file with the same name format as kiwirecorder.py
            local wav_raw_filename=$(date -u -d @$(( $(stat -c %Y ${minute_raw_file_list[${first_unsaved_minute_raw_index}]} ) - 60 ))  +%G%m%dT%H%M00-${wspr_pkt_len_seconds}-secs.wav)
            wd_logger 0 "Created ${wav_raw_filename} starting with '${minute_raw_file_list[${first_unsaved_minute_raw_index}]}'"
            cat ${minute_raw_file_list[@]:${first_unsaved_minute_raw_index}:${raw_files_in_wav_file_count}} | sox -r 12000 -t raw  -e s -b 16 -c 1 - ${wav_raw_filename}
            touch -r ${minute_raw_file_list[${first_unsaved_minute_raw_index}]}   ${wav_raw_filename}

            ### wsprd extracts the spot times from the wav file's name, so 
            local wspr_decode_capture_date=${wav_raw_filename/T*}
            wspr_decode_capture_date=${wspr_decode_capture_date:2:8}      ## chop off the '20' from the front
            local wspr_decode_capture_time=${wav_raw_filename#*T}
            wspr_decode_capture_time=${wspr_decode_capture_time/-*}
            local wspr_decode_capture_sec=${wspr_decode_capture_time:4}
            if [[ ${wspr_decode_capture_sec} != "00" ]]; then
                wd_logger 0 "ERROR: wav file named '${wav_raw_filename}' shows that recording didn't start at second "00". Delete this file and go to next wav file."
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
                    wd_logger 0 "Decoding WSPR: '${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wsprd_input_wav_filename}'"
                    ${WSPRD_CMD} -c ${wsprd_cmd_flags} -f ${wspr_decode_capture_freq_mhz} ${wsprd_input_wav_filename} > ${WSPRD_STDOUT_FILE}
                    touch ALL_WSPR.TXT
                    local all_wspr_size=$(stat -c %s ALL_WSPR.TXT)
                    if [[ ${all_wspr_size} -gt ${MAX_ALL_WSPR_SIZE} ]]; then
                        local all_wspr_lines=$(wc -l < ALL_WSPR.TXT)
                        local lines_to_delete=$(( all_wspr_lines / 4 ))
                        wd_logger 0 "ALL_WSPR.TXT of size ${all_wspr_size} bytes / ${all_wspr_lines} has grown too large.  Truncate the first ${lines_to_delete} lines to shrink it"
                        sed -i "1,${lines_to_delete} d" ALL_WSPR.TXT 
                    fi
                else
                    wd_logger 0 "Decoding FST4W: '${JT9_CMD} --fst4w -p ${wspr_pkt_len_seconds} ${wsprd_input_wav_filename} > ${WSPRD_STDOUT_FILE}'"
                    ${JT9_CMD} --fst4w -p ${wspr_pkt_len_seconds} ${wsprd_input_wav_filename} > ${WSPRD_STDOUT_FILE}
                fi
                rm ${wsprd_input_wav_filename}
                local stdout_text=$(grep "^[0-9]" ${WSPRD_STDOUT_FILE})
                if [[ $(wc -l <<< "${stdout_text}" ) -gt 0 ]]; then
                    wd_logger 0 "Decoded ${decode_mode} spots: ${stdout_text}"
                fi
                cd - > /dev/null
           done
           ### We have finished decoding the wav file, so leave behind a zero length version of it that saves disk space while signaling that raw files are no longer needed
           truncate -s 0 ${wav_raw_filename}
           touch -r ${minute_raw_file_list[${first_unsaved_minute_raw_index}]} ${wav_raw_filename}
           ### wav_raw_filename will be the most recent wav file, so we can delete all the other existing wav files
           if [[ ${#wav_raw_pkt_list[@]} -gt 0 ]]; then
               wd_logger 0 "Decoding done. Remove the older wav_raw files: '${wav_raw_pkt_list[@]}'"
               rm ${wav_raw_pkt_list[@]}
           fi
           set +x
 
            first_unsaved_minute_raw_index=$(( first_unsaved_minute_raw_index + raw_files_in_wav_file_count ))
            if [[ ${first_unsaved_minute_raw_index} -lt ${first_needed_minute_raw_file_index} ]]; then
                first_needed_minute_raw_file_index=${first_unsaved_minute_raw_index}
                wd_logger 0 "We need to save files starting at minute_raw index ${first_unsaved_minute_raw_index}" 
            fi
        done   ### with: wspr_pkt_len_seconds in ${wspr_lengths_secs[@]}; do

        if [[ ${first_needed_minute_raw_file_index} -gt 0  ]]; then
            rm -f ${minute_raw_file_list[@]:0:${first_needed_minute_raw_file_index}}
            wd_logger 0 "Deleted minute_raw files [0:${first_needed_minute_raw_file_index}] which  will not be needed in future wav_raw files"
        else
            wd_logger 0 "Keeping all ${#minute_raw_file_list[@]} minute_raw files since tbe first file will be needed in future wav_raw files"
        fi
       wd_logger 0 "Finished processing all wav file lengths"
    done    ### with:  while [[ ! -f ${WAV_RECORDING_DAEMON_STOP_FILE} ]]; do

    ### We have been instructed to terminate...
    if [[ ${sdr_recording_daemon_pid} -ne 0 ]]; then
        kill ${sdr_recording_daemon_pid}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
             wd_logger 0 "ERROR: terminating after detecting '${WAV_RECORDING_DAEMON_STOP_FILE}' while SDR_Recording_Daemon is running, but 'kill ${sdr_recording_daemon_pid}' => ${ret_code}"
        else
             wd_logger 0 "clean termination after detecting '${WAV_RECORDING_DAEMON_STOP_FILE}' while SDR_Recording_Daemon is running, after sucessfull 'kill ${sdr_recording_daemon_pid}'"
        fi
    else
         wd_logger 0 "clean termination after detecting '${WAV_RECORDING_DAEMON_STOP_FILE}' when no sdr_recording_daemon_pid"
    fi
    rm -f ${SDR_RECORDING_DAEMON_PID_FILE} ${WAV_RECORDING_DAEMON_STOP_FILE}
}

function kill_wav_recording() {
     wd_logger 0 "killing daemon"

    if [[ ! -f ${WAV_RECORDING_DAEMON_PID_FILE} ]]; then
        wd_logger 0 "No pid file ${WAV_RECORDING_DAEMON_PID_FILE}"
        return 0
    fi
    local wav_recording_daemon_pid=$(cat ${WAV_RECORDING_DAEMON_PID_FILE})

    ps ${wav_recording_daemon_pid} > /dev/null
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 0 "Found dead pid ${wav_recording_daemon_pid} in ${WAV_RECORDING_DAEMON_PID_FILE}"
        rm -f ${WAV_RECORDING_DAEMON_PID_FILE}
        return 0
    fi
    wd_logger 0 "Signaling deamon with pid ${wav_recording_daemon_pid} to stop by creating '${WAV_RECORDING_DAEMON_STOP_FILE}'"
    touch ${WAV_RECORDING_DAEMON_STOP_FILE}
    local loop_count
    for (( loop_count=10; loop_count > 0; --loop_count ))  ; do
        wd_logger 0 "Waiting for deamon to stop"
        if [[ ! -f ${WAV_RECORDING_DAEMON_STOP_FILE} ]]; then
            wd_logger 0 "'${WAV_RECORDING_DAEMON_STOP_FILE}' disappeared while waiting for deamon to stop, so this is a clean exit"
            break
        fi
        sleep 1
    done
    if [[ ${loop_count} -eq 0 ]]; then
        wd_logger 0 "Timeout waiting for daemon to stop, so killing pid ${wav_recording_daemon_pid}, and also 'killall SDR_Recording_Daemon'"
        kill ${wav_recording_daemon_pid}
        killall sdrTest
    else
        wd_logger 0 "Deamon stopped on its own"
    fi
    rm -f ${WAV_RECORDING_DAEMON_STOP_FILE} ${WAV_RECORDING_DAEMON_PID_FILE}
    return 0
}

declare SPAWN_SUFFIX="" # "&"
function spawn_wav_recording() {
    local sdr_device=$1
    local wspr_band=$2
    local wspr_lengths_secs="${@:3}"

    wd_logger 0 "Spawn daemon wav_recording_daemon on SDR ${sdr_device}, band '${wspr_band}' producing wav files of '${wspr_lengths_secs}' seconds"

    if [[ -f ${WAV_RECORDING_DAEMON_PID_FILE} ]]; then
        local wav_recording_daemon_pid=$(cat ${WAV_RECORDING_DAEMON_PID_FILE})
        
        ps ${wav_recording_daemon_pid}
        local ret_code=$?
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 0 "wav_recording_daemon() is running with pid ${wav_recording_daemon_pid}"
            return 0
        fi
        wd_logger 0 "Found wav_recording_daemon() with pid ${wav_recording_daemon_pid}"
    fi

    rm -f ${WAV_RECORDING_DAEMON_STOP_FILE}
    
    if [[ -n "${SPAWN_SUFFIX}" ]]; then
        WD_LOGFILE=wav_recording_daemon.log  wav_recording_daemon ${sdr_device} ${wspr_band} ${wspr_lengths_secs} &
    else
        wav_recording_daemon ${sdr_device} ${wspr_band} ${wspr_lengths_secs}
    fi
    local ret_code=$?
    local wav_recording_daemon_pid=$!
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 0 "ERROR spawning daemon wav_recording_daemon on device #${sdr_device}, band '${wspr_band}' producing wav files of '${wspr_lengths_secs}' seconds => ${ret_code}"
        return 1
    fi
    echo ${wav_recording_daemon_pid} > ${WAV_RECORDING_DAEMON_PID_FILE}

    wd_logger 0 "Spawned recording daemon with pid ${wav_recording_daemon_pid}"
}


