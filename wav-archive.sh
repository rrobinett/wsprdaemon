### Called by the decoading_daemon() for mode I1 files.
function archive_wav_file()
{
    local source_wav_file_path=$1
    local receiver_name=$2
    local receiver_band=$3

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
    local grape_id="@${GRAPE_PSWS_ID-NOT_DEFINED}"     ### always add @... to the directory name so it can be easily found and updated if a GRAPE_PSWS_ID is later obtained
    local archive_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}}/${source_file_date}/${reporter_call_grid}/${receiver_name}@${grape_id}/${receiver_band}"

    local source_wav_file_name="${source_wav_file_path##*/}"
    local archive_file_name="${source_wav_file_name/.wav/.wv}"
    local archive_file_path="${archive_dir}/${archive_file_name}"
    wd_logger 1 "Archiving ${source_wav_file_path} to ${archive_file_path}"

    mkdir -p ${archive_dir}

    wd_logger 1 "Starting 'wavpack -hh ${source_wav_file_path} -m ${archive_file_path} >& wavpack.log'"
    wavpack -hh ${source_wav_file_path} -m ${archive_file_path} >& wavpack.log
    rc=$? ;  if (( rc )); then
    wd_logger 1 "ERROR: 'wavpack -hh ${source_wav_file_path} -m ${archive_file_path}' => ${rc}, so flush that wav file:\n$(< wavpack.log)"
        wd_rm ${source_wav_file_path}
        return 1
    fi
    return 0
}
