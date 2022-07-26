#!/bin/bash

declare WAV_FILE_ARCHIVE_TMP_ROOT_DIR=${WSPRDAEMON_TMP_DIR}/wav-archive.d     ### Copy/move the wav files here
declare WAV_FILE_ARCHIVE_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/wav-archive.d        ### Store the compressed archive of them here
declare MAX_WAV_FILE_SYSTEM_PERCENT=75                                        ### Limit the usage of that fiel system

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
    local wav_queue_directory=${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}/${receiver_call_grid}/${receiver_name}/${receiver_band}

    mkdir -p ${wav_queue_directory}
    eval ${__return_directory_name_return_variable}=${wav_queue_directory}

    wd_logger 1 "Wav files from receiver_name=${receiver_name} receiver_band=${receiver_band} will be queued in ${wav_queue_directory}"
    return 0
}

function wd_root_file_system_has_space()
{
    local _return_percent_used_var=$1
    local df_line_list=( $(df . | tail -n 1) )
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
        wd_logger 1 "ERROR: ${queue_file_system_percent_used}% of ${WSPRDAEMON_ROOT_DIR}/${WAV_FILE_ARCHIVE_ROOT_DIR} used, so no space for ${source_wav_file_path}, so can't queue it"
        return 1
    fi
     wd_logger 1 "${queue_file_system_percent_used}% of ${WSPRDAEMON_ROOT_DIR}/${WAV_FILE_ARCHIVE_ROOT_DIR} used, so there is space for ${source_wav_file_path}, so queue it"

    mkdir -p ${archive_dir}

    if ! mv ${source_wav_file_path} ${archive_file_path} ; then
        wd_logger 1 "ERROR: 'cp -p ${source_wav_file_path} ${archive_file_path}' => $?"
        return 1
    fi
    return 0
}

 function truncate_wav_file_archive()
{
    local file_system_percent_used
    if wd_root_file_system_has_space file_system_percent_used; then
        wd_logger 1 "The ${WAV_FILE_ARCHIVE_ROOT_DIR} file system used by the wav file archive is ${file_system_percent_used}% full, so it has enough space for more wav and tar files.  So there is no need to cull older tar files"
        return 0
    fi
    wd_logger 1 "The ${WAV_FILE_ARCHIVE_ROOT_DIR} file system used by the wav file archive is ${file_system_percent_used}% full, so we need to flush some older wav files"
    local wav_file_list=( $(find wav-archive.d -type f -name '*.wav' | sort -t / -k 5,5) )
    local wav_file_count=${#wav_file_list[@]}

    if [[ ${wav_file_count} -lt ${MIN_WAV_ARCHIVE_FILE_COUNT} ]]; then
        wd_logger 1 "File system is ${file_system_percent_used}% full, but there are only ${wav_file_count} archived wav files, so flushing them won't gain much space"
        return 0
    fi
    local wav_file_flush_max_index=$(( ${wav_file_count} / 4 ))
    local flush_list=( ${wav_file_list[@]:0:${wav_file_flush_max_index}} )
    wd_logger 1 "FLushing wav files [0] through [${wav_file_flush_max_index}]"
    rm ${flush_list[@]}

    return 0
}

function wd_tar_wavs()
{

    local wav_file_list=( $(find ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} -type f -name '*.wav') )       ### Sort by start date found in wav file name.  Assumes that find is executed in WSPRDAEMON_ROOT_DIR
    if [[ ${#wav_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no wav files"
        return 0
    fi

    truncate_wav_file_archive

    set +x
    local wav_file_path_list=( ${wav_file_list[0]//\// } )

    ### Find the date of the newest wav file by sorting on the filenames
    local wav_list_sort_key=${#wav_file_path_list[@]}
    local newest_wav_file=$(IFS=$'\n'; echo "${wav_file_list[*]}" | sort -t / -k ${wav_list_sort_key} | tail -n 1)
    local newest_date=${newest_wav_file##*/}
          newest_date=${newest_date%.wav}
    local wav_list_rx_site_index=$((wav_list_sort_key - 4))
    local rx_site_id=${wav_file_path_list[${wav_list_rx_site_index}]}
    local tar_file_name=${WAV_FILE_ARCHIVE_ROOT_DIR}/${rx_site_id}_${newest_date}.tar.zst
    set +x

    if [[ -f ${tar_file_name} ]]; then
        local old_file_name=${tar_file_name/.tar/_a.tar}
        wd_logger 1 "Found existing ${tar_file_name}, so move it to ${old_file_name}"
        mv ${tar_file_name} ${old_file_name}
    fi

    wd_logger 1 "Found ${#wav_file_list[@]} wav files.  Date of newest ${newest_date}. creating ${tar_file_name}"

    cd ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}
    echo "${wav_file_list[@]#*wav-archive.d/}" | tr " " "\n" > tar_file.list    ### bash expands "${wav_file_list[@]}" into a  single long argument to tar, so use this hack to get around that
    if ! tar -acf ${tar_file_name} --files-from=tar_file.list ; then
        cd - > /dev/null
        wd_logger 1 "ERROR: tar => $?"
    else
        cd - > /dev/null
        local tar_size=$(stat --printf="%s" ${tar_file_name})
        wd_logger 1 "Created ${tar_size} byte ${tar_file_name} from ${#wav_file_list[@]} wav files"
        rm ${wav_file_list[@]}
    fi

    return 0
}

