#!/bin/bash

declare WAV_FILE_ARCHIVE_TMP_ROOT_DIR="/mnt/wav-archive.d"  ### Move the wav files here from the recording.d/... directories.  The wav_archive_daemon will compress and move them into the permanent storage
declare WAV_FILE_ARCHIVE_TMP_ROOT_DIR_SIZE="1G"
declare MIN_WAV_TMP_FILE_SYSTEM_FREE_PERCENT=5
declare MAX_WAV_TMP_FILE_SYSTEM_USED_PERCENT=$(( 100 - ${MIN_WAV_TMP_FILE_SYSTEM_FREE_PERCENT} ))

declare WAV_FILE_ARCHIVE_ROOT_DIR=${WAV_FILE_ARCHIVE_ROOT_DIR-${WSPRDAEMON_ROOT_DIR}/wav-archive.d}        ### Store the compressed archive of them here. This should be an SSD or HD
declare COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR=${WAV_FILE_ARCHIVE_ROOT_DIR}
declare MIN_COMPRESSED_WAV_FILE_SYSTEM_FREE_PERCENT=${MIN_COMPRESSED_WAV_FILE_SYSTEM_FREE_PERCENT-25}                           ### Limit the usage of that file system
declare MAX_COMPRESSED_WAV_FILE_SYSTEM_USED_PERCENT=$(( 100 - ${MIN_COMPRESSED_WAV_FILE_SYSTEM_FREE_PERCENT} ))

declare MIN_COMPRESSED_WAV_ARCHIVE_FILE_COUNT=${MIN_COMPRESSED_WAV_ARCHIVE_FILE_COUNT-10}

### Execute this once at WD start
function wav_archive_init() {
    ### For mode I1 decodes the iq.wav files are first moved to this tmpfs file system
    if !  create_tmpfs ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR_SIZE} ; then
        wd_logger 1 "ERROR: can't create tmpfs ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}"
        exit 1
    fi
    ### Then the wav_archive_daemon flac-compresses them into non-volitile storarge under ~/wsprdaemon/wav-archive.d
    mkdir -p ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR}         ### At startup it might not exist
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

function wd_get_file_system_used_percent()
{
    local _return_percent_used_var=$1
    local file_system_path=$2
    local df_line_list=( $(df ${file_system_path}  | tail -n 1) )
    local file_system_size=${df_line_list[1]}
    local file_system_used=${df_line_list[2]}
    local __file_system_percent_used=$(( (file_system_used * 100 ) / file_system_size ))

    eval ${_return_percent_used_var}=\${__file_system_percent_used}
    wd_logger 2 "The file system containing ${file_system_path} is ${__file_system_percent_used}% full"
    return 0
}

function wd_file_system_has_space()
{
    local _return_percent_used_var=$1
    local file_system_path=$2
    local max_percent_used=$3

    wd_logger 2 "Find if the file system which contains ${file_system_path} has at least ${max_percent_used}% free space"

    local percent_used
    wd_get_file_system_used_percent percent_used ${file_system_path}

    eval ${_return_percent_used_var}=\${percent_used}
    if [[ ${percent_used} -gt ${max_percent_used} ]]; then
        wd_logger 1 "ERROR: File system containing ${file_system_path} is ${percent_used}% full, more than the ${max_percent_used}% limit"
        return 1
    fi
    wd_logger 2 "File system used by the wav file archive is only ${percent_used}% full, so there is space for more files"
    return 0
}

### Called by the decoading_daemon() for mode I1 files.
function queue_wav_file()
{
    local source_wav_file_path=$1
    local source_wav_file_dir=${source_wav_file_path%/*}
    local source_wav_file_name=${source_wav_file_path##*/}
    local archive_dir=$2
    local archive_file_path=${archive_dir}/${source_wav_file_name}
    local rc

    wd_logger 1 "Archiving ${source_wav_file_path} to ${archive_file_path}"

    local queue_file_system_percent_used
    if ! wd_file_system_has_space queue_file_system_percent_used ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} ${MAX_WAV_TMP_FILE_SYSTEM_USED_PERCENT}; then
        wd_logger 1 "ERROR: ${queue_file_system_percent_used}% of the ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} is used, so there is no space for ${source_wav_file_path}, so can't queue it.  So just 'rm' this file"
        wd_rm ${source_wav_file_path}
        rc=$?
        if (( rc} )); then
            wd_logger 1 "ERROR: failed to 'wd_rm ${source_wav_file_path}' => ${rc}"
        fi
        return 1
    fi
     wd_logger 1 "${queue_file_system_percent_used}% of the ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} file system is used, so there is space for ${source_wav_file_path}, so queue it"

    mkdir -p ${archive_dir}

    ### Since the source and destination directories are on the same file system, we can 'mv' the wav file
    ### Also, 'mv' performas no CPU intensive file copying, and it is an atomic operation and thus there is no race with the tar archiver
    mv ${source_wav_file_path} ${archive_file_path}
    rc=$?
    if (( rc )); then
        wd_logger 1 "ERROR: 'mv ${source_wav_file_path} ${archive_file_path}' => ${rc}, so flush that wav file"
        wd_rm  ${source_wav_file_path}
        return 1
    fi

    return 0
}

### If the  ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR} filesystem grows too large, this function truncates the oldest 25% of the flat files found under the  ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR} directory tree 
 function truncate_compressed_wav_file_archive()
{
    local file_system_percent_used
    if wd_file_system_has_space file_system_percent_used ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR} ${MAX_COMPRESSED_WAV_FILE_SYSTEM_USED_PERCENT}; then
        wd_logger 2 "The ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR} file system used by the wav file archive is ${file_system_percent_used}% full, so it has enough space for more wav and flac files.  So there is no need to cull files"
        return 0
    fi
    wd_logger 1 "The ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR} file system used by the wav file archive is ${file_system_percent_used}% full, so we need to flush some older wav files"
    ### find returns a time-sorted array of flac files
    local wav_file_list=( $(find ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR} -type f \( -name '*.flac' -o -name '*.wv' \) -printf '%T+,%p\n' | sort) )
    local wav_file_count=${#wav_file_list[@]}

    if (( wav_file_count < MIN_COMPRESSED_WAV_ARCHIVE_FILE_COUNT )); then
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

### Called every odd two minutes by the watchdog_daemon(), this compresses all the pcm and iq wav files it finds and moves the compressed version of each file to ${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR}/YYYMMDD (of the file)/....
### So all the compressed files for one UTC day are found under the .../YYYYMMDD/... directory for the date in the wav file name
function wd_archive_wavs()
{
    truncate_compressed_wav_file_archive

    ### Flush any .flac or .wv files which were left behind by the previous execution of this function two minutes ago
    local wav_file_list=( $(find ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} -type f \( -name '*.flac' -o -name '*.wv' \)) )
    if [[  ${#wav_file_list[@]} -ne 0 ]]; then
        wd_logger 1 "ERROR: Found ${#wav_file_list[@]} zombie .flac and/or .wv files in ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}, so deleting them"
        wd_rm ${wav_file_list[@]}
    fi

    ### Create a list of wav files sorted by ascending time.
    wav_file_list=( $(find ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} -type f -name '*.wav'  -printf "%T@ %p\n" | sort -n | cut -d ' ' -f 2- ) )       ### Sort by start date found in wav file name.  Assumes that find is executed in WSPRDAEMON_ROOT_DIR
    if [[ ${#wav_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no wav files to archive"
        return 0
    fi

    wd_logger 1 "Compressing and archiving ${#wav_file_list[@]} wav files"

    ### Process the oldest wav file first
    local wav_file_path
    for wav_file_path in ${wav_file_list[@]} ; do
        local wav_file_name=${wav_file_path##*/}
        local wav_file_date=${wav_file_name:0:8}
        local wav_file_dir=${wav_file_path%/*}

        ### The HamSCI GRAPE project wants the top dir of the wav/flac archive tree for one date to have the format: 'OBSYYYY-MM-DDTHH-MM'
        local grape_top_dir_name=$(printf "%4s%2s%2s" ${wav_file_name:0:4} ${wav_file_name:4:2} ${wav_file_name:6:2} )
        local dest_date_top_dir="${COMPRESSED_WAV_FILE_ARCHIVE_ROOT_DIR}/${grape_top_dir_name}"
        local dest_file_dir=${dest_date_top_dir}/${wav_file_dir#${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}/}
        local wav_file_is_float=$(soxi ${wav_file_path} | grep "Sample Encoding: 32-bit Floating Point PCM" )   ## this will be zero length if it not a float file
        local compressed_wav_file_path
        if [[ -n "${wav_file_is_float}" ]]; then
            compressed_wav_file_path=${dest_file_dir}/${wav_file_name/.wav/.wv}
        else
            compressed_wav_file_path=${dest_file_dir}/${wav_file_name/.wav/.flac}
        fi
        wd_logger 1 "Compressing wav file ${wav_file_path} and archiving it to ${compressed_wav_file_path}"

        ### flac compresses in place, so we run 'wavpack' the same way.  So there needs to be some free space in the file's file system for the wav file, which will be larger
        declare FREE_WAV_TIMEOUT_MAX=${FREE_WAV_TIMEOUT_MAX-100}
        local free_wav_timeout=1
        local file_system_percent_used
        while   [[ ${free_wav_timeout} -le ${FREE_WAV_TIMEOUT_MAX} ]] && ! wd_file_system_has_space file_system_percent_used ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} ${MAX_WAV_TMP_FILE_SYSTEM_USED_PERCENT} ; do
            wd_logger 1 "ERROR: try #${free_wav_timeout}: the tmpfs file system containing ${wav_file_path} is ${file_system_percent_used} percent full. So flush the oldest file"
            local oldest_file=$(find ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}  -type f -exec stat --format='%Y %n' {} + | sort -n | head -n 1 | cut -d " " -f 2)
            if [[ -z "${oldest_file}" ]]; then
                wd_logger 1 "ERROR: unexpectedly couldn't find any flat files in the ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} file system"
                continue
            else
                wd_logger 1 "Deleting the oldest file '${oldest_file}', then look again to see if there is enough free space"
                wd_rm ${oldest_file}
            fi
            (( ++free_wav_timeout ))
        done
        if [[ ${free_wav_timeout} -gt ${FREE_WAV_TIMEOUT_MAX} ]]; then
             wd_logger 1 "ERROR: failed to free enough space on drive containing ${wav_file_path}, so deleting it"
             wd_rm ${wav_file_path}
             continue
        fi
        wd_logger 1 "There is enough free space to run 'flac' or 'wavpack'"

       local rc
       mkdir -p ${dest_file_dir}
       rc=$?
       if (( rc )); then
           wd_logger 1 "ERROR: 'mkdir -p ${dest_file_dir}' => ${rc}"
           continue
       fi
 
        if [[ -n ${wav_file_is_float} ]]; then
            wd_logger 1 "Compressing 32 float wav file ${wav_file_path}"
            wavpack -h ${wav_file_path} -o ${compressed_wav_file_path} >& wavpack.log
            rc=$?
            if (( rc )); then
                wd_logger 1 "ERROR: 'wavpack -h ${wav_file_path} -o ${compressed_wav_file_path}' => ${rc}:\n$(< wavpack.log)"
            else
                wd_logger 1 "'wavpack -h ${wav_file_path} -o ${compressed_wav_file_path}' successfully compressed and archived the wav file, so delete the wav file"
                wd_rm  ${wav_file_path}
            fi
        else
             wd_logger 1 "Compressing a 16 bit int file ${wav_file_path} with flac"
             local flac_extra_args=""

             if flac --version | grep -q 1\.4\.3; then
                 flac_extra_args="--keep-foreign-metadata-if-present"     ### Only flac 1.4.3 understands the wav file header metadata added by the 32 float version of wd-record 
             fi
             flac ${flac_extra_args} --delete-input-file ${wav_file_path} >& flac.log
             rc=$?
             if (( rc )); then
                 wd_logger 1 "ERROR: 'flac ${flac_extra_args} --delete-input-file ${wav_file_path}' => ${rc}, so flush that wav file"
                 wd_rm ${wav_file_path}
                 continue
             fi
             local compressed_wav_file_name=${compressed_wav_file_path##*/}
             local dest_compressed_wav_file_path="${dest_file_dir}/${compressed_wav_file_name}"
             mv ${compressed_wav_file_path} ${dest_compressed_wav_file_path}
             rc=$?
             if (( rc )); then
                 wd_logger 1 "ERROR: 'mv ${compressed_wav_file_path} ${dest_compressed_wav_file_path}' => ${rc}"
             else
                 wd_logger 1 "Compressed ${wav_file_path} to ${compressed_wav_file_path} and then moved it to ${dest_compressed_wav_file_path}"
             fi
        fi
    done
    wd_logger 1 "Finished compressing and archiving the ${#wav_file_list[@]} queued wav files"
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
        wd_logger 1 "Sleeping ${sleep_seconds} seconds in order to wake up at the next odd minute"
        wd_sleep  ${sleep_seconds}
        wd_archive_wavs
    done
}

# wd_archive_wavs
# exit
