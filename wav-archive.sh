#!/bin/bash

### Called by the decoading_daemon() for mode I1 files.

declare MIN_ARCHIVE_FILE_SYSTEM_FREE_PERCENT=${MIN_ARCHIVE_FILE_SYSTEM_FREE_PERCENT-25}
declare MAX_ARCHIVE_FILE_SYSTEM_USED_PERCENT=$(( 100 - MIN_ARCHIVE_FILE_SYSTEM_FREE_PERCENT ))

function is_integer() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

function archive_file_system_has_free_space() {
    local file_system_path=$1

    local percent_used=$(df ${file_system_path} | awk '$(NF -1) ~ "%"{print $(NF-1)}' | sed 's/%//' )

    if [[ -z "${percent_used}" ]]; then
        wd_logger 1 "ERROR: didn't get any free space percent value for file_system_path=${file_system_path}"
        return 1
    fi
    if ! is_integer  "${percent_used}" ; then
         wd_logger 1 "ERROR: the free space percent value '${percent_used}' for file_system_path=${file_system_path} is not an integer"
        return 2
    fi
    if (( percent_used >  MAX_ARCHIVE_FILE_SYSTEM_USED_PERCENT )); then
         wd_logger 1 "The used space percent value '${percent_used}' for file_system_path=${file_system_path} is greater than the allowed MAX_ARCHIVE_FILE_SYSTEM_USED_PERCENT=${MAX_ARCHIVE_FILE_SYSTEM_USED_PERCENT}"
        return 3
    fi
    wd_logger 1 "${percent_used} percent used is less than the allowed MAX_ARCHIVE_FILE_SYSTEM_USED_PERCENT=${MAX_ARCHIVE_FILE_SYSTEM_USED_PERCENT}, so there is enough free space to add .wz files to the archive"
    return 0
}

function purge_oldest_archive() {
    local archive_root_path=$1

    wd_logger 1 "Purge in ${archive_root_path}"

    local date_dir_list=( $( find -L ${archive_root_path} -maxdepth 1 -type d -name '20*' | sort) )
    if (( ! ${#date_dir_list[@]} )); then
        wd_logger 1 "ERROR: can't find any '20*' directories in ${archive_root_path}"
        return 1
    fi
    wd_logger 1 "Found ${#date_dir_list[@]} '20*' archive dirctories"
    local purged_files=0
    for date_dir in ${date_dir_list[@]} ; do
        local wv_file_list=( $( find -L ${date_dir} -type f \( -name '*.wv' -o  -name '*.flac' -o  -name '*.wav' \) ) )
        if (( ! ${#wv_file_list[@]} )); then
            wd_logger 1 "There are no .wv to purge under ${date_dir}"
        else
             wd_logger 1 "Purging ${#wv_file_list[@]} files under ${date_dir}"
             echo ${wv_file_list[@]} | xargs -n 1000 rm > /dev/null
             rc=$? ; if (( rc )); then
                 wd_logger 1 "ERROR: failed to delete some or all of the ${#wv_file_list[@]} .wv files with 'rm ${wv_file_list[0]} ..."
             else
                  purged_files=${#wv_file_list[@]}
             fi
             break
        fi
    done
    if (( ${purged_files} )); then
        wd_logger 1 "purged ${purged_files} .wz files"
        return 0
    else
         wd_logger 1 "ERROR: failed to find any files to purge, or purging failed"
        return 1
    fi
}

function archive_wav_file()
{
    local source_wav_file_path=$1
    local receiver_name=$2
    local receiver_band=$3
    local rc

    wd_logger 2 "Archive IQ file '${source_wav_file_path}' from receiver ${receiver_name} on band ${receiver_band}"

    if [[ ! -f ${source_wav_file_path} ]]; then
        wd_logger 1 "ERROR: can't find source_wav_file_path=${source_wav_file_path}"
        return 1
    fi

    wd_mutex_lock "archive-wav-file" ${GRAPE_WAV_ARCHIVE_ROOT_PATH}
    rc=$? ; if (( rc )) ; then
        wd_logger 1 "ERROR: 'wd_mutex_lock 'archive-wav-file' ${GRAPE_WAV_ARCHIVE_ROOT_PATH}' => ${rc}' which is a timeout after waiting to get mutex within its default ${MUTEX_DEFAULT_TIMEOUT} seconds, but try to archive anyway"
    fi
    while ! archive_file_system_has_free_space ${GRAPE_WAV_ARCHIVE_ROOT_PATH} ; do
        rc=$?
        wd_logger 1 "Archive file system is too full, so purge the .wv files from the oldest date"
        purge_oldest_archive ${GRAPE_WAV_ARCHIVE_ROOT_PATH}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: can't free space with 'purge_oldest_archive ${GRAPE_WAV_ARCHIVE_ROOT_PATH}' => ${rc}"
            sleep 1
        else
            wd_logger 1 "Freed space on ${GRAPE_WAV_ARCHIVE_ROOT_PATH}, so check again"
        fi
    done
    wd_mutex_unlock "archive-wav-file" ${GRAPE_WAV_ARCHIVE_ROOT_PATH}
    rc=$? ; if (( rc )) ; then
        wd_logger 1 "ERROR: 'wd_mutex_unlock 'archive-wav-file' ${GRAPE_WAV_ARCHIVE_ROOT_PATH}' => ${rc}', but try to archive anyway"
    fi
    wd_logger 1 "There is enough free space to add this .wv file"

    local source_file_date=${source_wav_file_path##*/}   ### The wav file name starts with YYYYMMDD
    source_file_date=${source_file_date:0:8}

    local rc

    local reporter_call_grid
    reporter_call_grid=$( get_call_grid_from_receiver_name ${receiver_name} )
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: can't find reporter ID for receiver '${receiver_name}'"
        return 1
    fi
    ### Linux directory names can't have the '/' character in them which is so common in ham callsigns.  So replace all those '/' with '=' characters which (I am pretty sure) are never legal
    local call_dir_name=${reporter_call_grid//\//=}
    local grape_id="${GRAPE_PSWS_ID-NOT_DEFINED}"     ### always add @... to the directory name so it can be easily found and updated if a GRAPE_PSWS_ID is later obtained
    if [[ ${grape_id} =~ @ ]]; then
        wd_logger 1 "ERROR: GRAPE_PSWS_ID includes an '@'"
    fi
    local archive_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${source_file_date}/${reporter_call_grid}/${receiver_name}@${grape_id}/${receiver_band}"
    if [[ ${archive_dir} =~ @@ ]]; then
        wd_logger 1 "ERROR: archive_dir=${archive_dir} includes an '@@'"
    fi
 
    local source_wav_file_name="${source_wav_file_path##*/}"
    local archive_file_name="${source_wav_file_name/.wav/.wv}"
    local archive_file_path="${archive_dir}/${archive_file_name}"
    wd_logger 1 "Archiving ${source_wav_file_path} to ${archive_file_path}"

    mkdir -p ${archive_dir}

    wavpack -hh ${source_wav_file_path} -o ${archive_file_path}  >& wavpack.log    ##w avpacket's -m (move compressed file) doesn't work as I expect
    rc=$? 
    wd_rm ${source_wav_file_path}        ### Remove the source wav whether or not a compressed version was created
    if (( rc )); then
        wd_logger 1 "ERROR: 'wavpack -hh ${source_wav_file_path} -o ${archive_file_path}' => ${rc}:\n$(< wavpack.log)"
        return 1
    fi
    wd_logger 1 "Compressed ${source_wav_file_path} into ${archive_file_path}"
    return 0
}
