#!/bin/bash

declare MAX_WAV_FILE_SYSTEM_PERCENT=75
declare WAV_FILE_ARCHIVE_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/wav-archive.d

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

    if ! cp -p ${source_wav_file_path} ${archive_file_path} ; then
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

    set +x
    local wav_file_list=( $(find wav-archive.d -type f -name '*.wav' | sort -t / -k 5,5) )       ### Sort by start date found in wav file name.  Assumes that find is executed in WSPRDAEMON_ROOT_DIR
    if [[ ${#wav_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no wav files"
        return 0
    fi

    truncate_wav_file_archive

    local newest_date=${wav_file_list[-1]##*/}
          newest_date=${newest_date%.wav}
    local file_path_list=( ${wav_file_list[-1]//\// } )
    local rx_site_id=${file_path_list[1]}
    local tar_file_name=${WAV_FILE_ARCHIVE_ROOT_DIR}/${rx_site_id}_${newest_date}.tar.zst

    if [[ -f ${tar_file_name} ]]; then
        local old_file_name=${tar_file_name/.tar/_a.tar}
        wd_logger 1 "Found existing ${tar_file_name}, so move it to ${old_file_name}"
        mv ${tar_file_name} ${old_file_name}
    fi

    wd_logger 1 "Found ${#wav_file_list[@]} wav files.  Date of newest ${newest_date}. creating ${tar_file_name}"

    echo "${wav_file_list[@]}" | tr " " "\n" > tar_file.list    ### bash expands "${wav_file_list[@]}" into a  single long argument to tar, so use this hack to get around that
    if ! tar -acf ${tar_file_name} --files-from=tar_file.list ; then
        wd_logger 1 "ERROR: tar => $?"
    else
        local tar_size=$(stat --printf="%s" ${tar_file_name})
        wd_logger 1 "Created ${tar_size} byte ${tar_file_name} from ${#wav_file_list[@]} wav files"
        rm ${wav_file_list[@]}
    fi
    return 0
}

