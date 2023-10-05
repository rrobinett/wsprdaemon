#!/bin/bash

declare WAV_FILE_ARCHIVE_TMP_ROOT_DIR=${WAV_FILE_ARCHIVE_TMP_ROOT_DIR-${WSPRDAEMON_TMP_DIR}/wav-archive.d} ### Move the wav files here.  Both source and dest directories need to be on the same file system (i.e /dev/shm/...)
declare WAV_FILE_ARCHIVE_ROOT_DIR=${WAV_FILE_ARCHIVE_ROOT_DIR-${WSPRDAEMON_ROOT_DIR}/wav-archive.d}        ### Store the compressed archive of them here. This should be an SSD or HD
declare MAX_WAV_FILE_SYSTEM_PERCENT=${MAX_WAV_FILE_SYSTEM_PERCENT-75}                                      ### Limit the usage of that file system
declare MIN_WAV_ARCHIVE_FILE_COUNT=${MIN_WAV_ARCHIVE_FILE_COUNT-10}

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
        wd_logger 1 "ERROR: ${queue_file_system_percent_used}% of ${WSPRDAEMON_ROOT_DIR}/${WAV_FILE_ARCHIVE_ROOT_DIR} used, so no space for ${source_wav_file_path}, so can't queue it"
        return 1
    fi
     wd_logger 1 "${queue_file_system_percent_used}% of ${WSPRDAEMON_ROOT_DIR}/${WAV_FILE_ARCHIVE_ROOT_DIR} used, so there is space for ${source_wav_file_path}, so queue it"

    mkdir -p ${archive_dir}

    ### Since the source and destination directories are on the same file system, we can 'mv' the wav file
    ### Also, 'mv' performas no CPU intensive file copying, and it is an atomic operation and thus there is no race with the tar archiver
    if ! mv ${source_wav_file_path} ${archive_file_path} ; then
        wd_logger 1 "ERROR: 'mv ${source_wav_file_path} ${archive_file_path}' => $?"
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
    local wav_file_list=( $(find ${WAV_FILE_ARCHIVE_ROOT_DIR} -type f -printf '%T+,%p\n' | sort) )
    local wav_file_count=${#wav_file_list[@]}

    if [[ ${wav_file_count} -lt ${MIN_WAV_ARCHIVE_FILE_COUNT} ]]; then
        wd_logger 1 "File system is ${file_system_percent_used}% full, but there are only ${wav_file_count} archived wav files, so flushing them won't gain much space"
        return 0
    fi
    local wav_file_flush_max_index=$(( ${wav_file_count} / 4 ))
    wd_logger 1 "Flushing wav files [0]='${wav_file_list[0]}' through [${wav_file_flush_max_index}]='${wav_file_list[${wav_file_flush_max_index}]}" 
    local wav_info_index
    for (( wav_info_index=0; wav_info_index < ${wav_file_flush_max_index}; ++wav_info_index )); do
        wd_logger 2 "Flushing [${wav_info_index}] = '${wav_file_list[${wav_info_index}]}'"
        local wav_info_list=(${wav_file_list[${wav_info_index}]/,/ } )
        local wav_file_name=${wav_info_list[1]}

        wd_logger 2 "Flushing ${wav_file_name}"
        rm ${wav_file_name}
    done
    wd_logger 1 "Done flushing oldest 25% of files"

    return 0
}

function wd_tar_wavs()
{
    truncate_wav_file_archive

    local wav_file_list=( $(find ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} -type f -name '*.wav') )       ### Sort by start date found in wav file name.  Assumes that find is executed in WSPRDAEMON_ROOT_DIR
    if [[ ${#wav_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no wav files to archive"
        return 0
    fi
    local wav_files_size_kB=$(du -s ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} | awk '{print $1}')

    local wav_file_path_list=( ${wav_file_list[0]//\// } )

    ### Find the date of the newest wav file by sorting on the filenames
    local wav_list_sort_key=${#wav_file_path_list[@]}
    local newest_wav_file=$(IFS=$'\n'; echo "${wav_file_list[*]}" | sort -t / -k ${wav_list_sort_key} | tail -n 1)
    local newest_date=${newest_wav_file##*/}
          newest_date=${newest_date%.wav}
    local wav_list_rx_site_index=$((wav_list_sort_key - 4))
    local rx_site_id=${wav_file_path_list[${wav_list_rx_site_index}]}
    local tar_file_name=${WAV_FILE_ARCHIVE_ROOT_DIR}/${rx_site_id}_${newest_date}.tar.zst
    mkdir -p ${WAV_FILE_ARCHIVE_ROOT_DIR}

    if [[ -f ${tar_file_name} ]]; then
        local old_file_name=${tar_file_name/.tar/_a.tar}
        wd_logger 1 "Found existing ${tar_file_name}, so move it to ${old_file_name}"
        mv ${tar_file_name} ${old_file_name}
    fi

    wd_logger 1 "Found ${wav_files_size_kB} KBytes in ${#wav_file_list[@]} wav files.  Date of newest ${newest_date}. creating ${tar_file_name}"
    local wav_files_size_kB=$(du -s ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR} | awk '{print $1}')

    cd ${WAV_FILE_ARCHIVE_TMP_ROOT_DIR}

    ### have tar compress using zstd
    echo "${wav_file_list[@]#*wav-archive.d/}" | tr " " "\n" > tar_file.list    ### bash expands "${wav_file_list[@]}" into a  single long argument to tar, so use this hack to get around that
    local zstd_tar_file_size_kB=0
    if [[ ${ARCHIVE_TO_ZST-no} == "no" ]]; then
        wd_logger 1 "Configured to not create zst format tar file from wav files"
    else
        if ! tar -acf ${tar_file_name} --files-from=tar_file.list ; then
            local rc=$?
            cd - > /dev/null
            wd_logger 1 "ERROR: tar => ${rc}"
        fi
        zstd_tar_file_size_kB=$( du -s ${tar_file_name}  | awk '{print $1}' )
    fi

    ### Use flac to comoress the indiviual .wav files to .flac files, then tar the .flac files together
    local tar_file_list=( $(< tar_file.list) )
    local flac_file_list=( ${tar_file_list[@]/%.wav/.flac} )

    flac --silent --delete-input-file ${tar_file_list[@]}

    local flac_tar_file_name=${tar_file_name%.tar.zst}.flac.tar
    tar -cf ${flac_tar_file_name} ${flac_file_list[@]}
    wd_rm ${flac_file_list[@]}
    local flac_tar_file_size_kB=$( du -s ${flac_tar_file_name}  | awk '{print $1}' )

    cd - > /dev/null
    wd_logger 1 "${#wav_file_list[@]} wav files of ${wav_files_size_kB} KBytes were compressed to a zst tar file of ${zstd_tar_file_size_kB} KBytes and a flac tar of ${flac_tar_file_size_kB} KBytes"

    return 0
}
