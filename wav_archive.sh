#!/bin/bash

declare WAV_FILE_ARCHIVE_TMP_ROOT_DIR="/mnt/wav-archive.d"  ### Move the wav files here from the recording.d/... directories.  The wav_archive_daemon will compress and move them into the permanent storage
declare WAV_FILE_ARCHIVE_TMP_ROOT_DIR_SIZE="1G"

declare WAV_FILE_ARCHIVE_ROOT_DIR=${WAV_FILE_ARCHIVE_ROOT_DIR-${WSPRDAEMON_ROOT_DIR}/wav-archive.d}        ### Store the compressed archive of them here. This should be an SSD or HD
declare MAX_WAV_FILE_SYSTEM_PERCENT=${MAX_WAV_FILE_SYSTEM_PERCENT-75}                                      ### Limit the usage of that file system
declare MIN_WAV_ARCHIVE_FILE_COUNT=${MIN_WAV_ARCHIVE_FILE_COUNT-10}

### Execute this once at WD start
function wav_archive_init() {
    if !  create_tmpfs ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR_SIZE} ; then
        wd_logger 1 "ERROR: can't create tmpfs ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}"
        exit 1
    fi
}
if ! wav_archive_init ; then
    wd_logger 1 "ERROR: init failed"
    exit 1
fi

function get_wav_archive_queue_directory()
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
    ### Linux directory names can't have the '/' character in them which is so common in ham callsigns.  So replace all those '/' with '=' characters which (I am pretty sure) are never legal
    local call_dir_name=${receiver_call_grid//\//=}
    local grape_id=""
    if [[ -n "${GRAPE_PSWS_ID-}" ]]; then
         grape_id="@${GRAPE_PSWS_ID}"     ### If the user has registered his site/receiver with HamSCI's GRAPE, then append it to the rx directory name
    fi
    local wav_queue_directory=${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}/${receiver_call_grid}/${receiver_name}${grape_id}/${receiver_band}

    mkdir -p ${wav_queue_directory}
    eval ${__return_directory_name_return_variable}=${wav_queue_directory}

    wd_logger 1 "Wav files from receiver_name=${receiver_name} receiver_band=${receiver_band} will be queued in ${wav_queue_directory}"
    return 0
}

function wd_root_file_system_has_space()
{
    local _return_percent_used_var=$1
    mkdir -p ${WAV_FILE_ARCHIVE_ROOT_DIR}         ### At startup it might not exist
    local df_line_list=( $(df ${WAV_FILE_ARCHIVE_ROOT_DIR}  | tail -n 1) )
    local file_system_size=${df_line_list[1]}
    local file_system_used=${df_line_list[2]}
    local __file_system_percent_used=$(( (file_system_used * 100 ) / file_system_size ))

    eval ${_return_percent_used_var}=\${__file_system_percent_used}
    if [[ ${__file_system_percent_used} -gt ${MAX_WAV_FILE_SYSTEM_PERCENT} ]]; then
        wd_logger 1 "ERROR: File system used by the wav file archive is  ${__file_system_percent_used}% full, so there is no space for more files"
        return 1
    fi
    wd_logger 1 "File system used by the wav file archive is only ${__file_system_percent_used}% full, so there is space for more files"
    return 0
}

function queue_wav_file()
{
    local source_wav_file_path=$1
    local source_wav_file_dir=${source_wav_file_path%/*}
    local source_wav_file_name=${source_wav_file_path##*/}
    local archive_dir=$2
    local archive_file_path=${archive_dir}/${source_wav_file_name}

    wd_logger 1 "Archiving ${source_wav_file_path} to ${archive_file_path}"

    local queue_file_system_percent_used
    if ! wd_root_file_system_has_space queue_file_system_percent_used; then
        wd_logger 1 "ERROR: ${queue_file_system_percent_used}% of the ${WAV_FILE_ARCHIVE_ROOT_DIR} is used, so there is no space for ${source_wav_file_path}, so can't queue it.  So just 'rm' this file"
        local rc
        wd_rm ${source_wav_file_path}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to 'wd_rm ${source_wav_file_path}' => ${rc}"
        fi
        return 1
    fi
     wd_logger 1 "${queue_file_system_percent_used}% of the ${WAV_FILE_ARCHIVE_ROOT_DIR} file system is used, so there is space for ${source_wav_file_path}, so queue it"

    mkdir -p ${archive_dir}

    ### Since the source and destination directories are on the same file system, we can 'mv' the wav file
    ### Also, 'mv' performas no CPU intensive file copying, and it is an atomic operation and thus there is no race with the tar archiver
    if ! mv ${source_wav_file_path} ${archive_file_path} ; then
        wd_logger 1 "ERROR: 'mv ${source_wav_file_path} ${archive_file_path}' => $?, so flush that wav file"
        wd_rm  ${source_wav_file_path}
        return 1
    fi

    return 0
}

### If the  ${WAV_FILE_ARCHIVE_ROOT_DIR} filesystem grows too large, this function truncates the oldest 25% of the flat files found under the  ${WAV_FILE_ARCHIVE_ROOT_DIR} directory tree 
 function truncate_wav_file_archive()
{
    local file_system_percent_used
    if wd_root_file_system_has_space file_system_percent_used; then
        wd_logger 1 "The ${WAV_FILE_ARCHIVE_ROOT_DIR} file system used by the wav file archive is ${file_system_percent_used}% full, so it has enough space for more wav and flac files.  So there is no need to cull files"
        return 0
    fi
    wd_logger 1 "The ${WAV_FILE_ARCHIVE_ROOT_DIR} file system used by the wav file archive is ${file_system_percent_used}% full, so we need to flush some older wav files"
    ### find returns a time-sorted array of flac files
    local wav_file_list=( $(find ${WAV_FILE_ARCHIVE_ROOT_DIR} -type f -name '*.flac' -printf '%T+,%p\n' | sort) )
    local wav_file_count=${#wav_file_list[@]}

    if [[ ${wav_file_count} -lt ${MIN_WAV_ARCHIVE_FILE_COUNT} ]]; then
        wd_logger 1 "File system is ${file_system_percent_used}% full, but there are only ${wav_file_count} archived wav files, so flushing them won't gain much space"
        return 0
    fi
    ### delete the oldest 25% of those flac files
    local wav_file_flush_max_index=$(( ${wav_file_count} / 4 ))
    wd_logger 1 "Flushing the oldest 25% of files [0]='${wav_file_list[0]}' through [${wav_file_flush_max_index}]='${wav_file_list[${wav_file_flush_max_index}]}" 
    local wav_info_index
    for (( wav_info_index=0; wav_info_index < ${wav_file_flush_max_index}; ++wav_info_index )); do
        wd_logger 2 "Flushing [${wav_info_index}] = '${wav_file_list[${wav_info_index}]}'"
        local wav_info_list=(${wav_file_list[${wav_info_index}]/,/ } )
        local wav_file_name=${wav_info_list[1]}

        wd_logger 2 "Flushing ${wav_file_name}"
        rm -f ${wav_file_name}
    done
    wd_logger 1 "Done flushing oldest 25% of files"

    return 0
}

### Called every odd two minutes by the watchdog_daemon(), this compresses all the pcm and iq wav files it finds and moves the compressed version of each file to ${WAV_FILE_ARCHIVE_ROOT_DIR}/YYYMMDD (of the file)/....
### So all the compressed files for one UTC day are found under the .../YYYYMMDD/... directory for the date in the wav file name
function wd_archive_wavs()
{
    truncate_wav_file_archive

    local wav_file_list=( $(find ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} -type f -name '*.wav') )       ### Sort by start date found in wav file name.  Assumes that find is executed in WSPRDAEMON_ROOT_DIR
    if [[ ${#wav_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no wav files to archive"
        return 0
    fi

    wd_logger 1 "Starting to compress and archive ${#wav_file_list[@]} wav files"

    local wav_file_name
    for wav_file_path in ${wav_file_list[@]} ; do
        local wav_file_name=${wav_file_path##*/}
        local wav_file_date=${wav_file_name:0:8}
        local wav_file_dir=${wav_file_path%/*}
        local flac_file_path=${wav_file_path%.wav}.flac

        ### The HamSCI GRAPE project wants the top dir of the wav/flac archive tree for one date to have the format: 'OBSYYYY-MM-DDTHH-MM'
        local grape_top_dir_name=$(printf "%4s%2s%2s" ${wav_file_name:0:4} ${wav_file_name:4:2} ${wav_file_name:6:2} )
        local dest_date_top_dir="${WAV_FILE_ARCHIVE_ROOT_DIR}/${grape_top_dir_name}"

        local dest_file_dir=${dest_date_top_dir}/${wav_file_dir#${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}/}
        local dest_flac_path=${dest_file_dir}/${wav_file_name/.wav/.flac}
        wd_logger 2 "Flac compressing wav file ${wav_file_path} and archiving it to ${dest_flac_path}"

        local rc
        flac --silent --delete-input-file ${wav_file_path}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: ' flac --silent --delete-input-file ${wav_file_path}' => ${rc}, so flush that wav file"
            wd_rm ${wav_file_path}
            continue
        fi
        mkdir -p ${dest_file_dir}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'mkdir -p ${dest_file_dir}' => ${rc}"
            continue
        fi
        mv ${flac_file_path} ${dest_flac_path}
        rc=$?
         if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'mv ${flac_file_path} ${dest_file_dir}' => ${rc}"
            continue
        fi
    done
    return 0
}

### Spawned by watchdog daemon at startup and every odd minute it looks for wav files to compress and archive 
function wav_archive_daemon() {
    local root_dir=$1

    mkdir -p ${root_dir}
    cd ${root_dir}
    wd_logger 1 "Starting in $PWD"

    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD
    while true; do
        local sleep_seconds=$(seconds_until_next_odd_minute)
        wd_logger 1 "Sleeping ${sleep_seconds} in order to wake up at the next odd minute"
        wd_sleep  ${sleep_seconds}
        wd_archive_wavs
    done
}
