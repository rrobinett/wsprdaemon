#!/bin/bash
# go from wav files to Grape:
# - convert from wav to Digital RF dataset
# - upload Digital RF dataset directory to PSWS network
#
# Franco Venturi - K4VZ - Mon 22 Jan 2024 01:20:14 PM UTC
# Rob Robinett - AI6VN - Mon Jan 30 2024 modified to be part of a Wsprdaemon client

set -euo pipefail

WSPRDAEMON_ROOT_DIR=${WSPRDAEMONM_ROOT_DIR-~/wsprdaemon}

declare -r PSWS_SERVER_URL='pswsnetwork.caps.ua.edu'
declare -r UPLOAD_TO_PSWS_SERVER_COMPLETED_FILE_NAME='pswsnetwork_upload_completed'
declare -r GRAPE_TMP_DIR="/run/user/$(id -u)/grape_drf_cache"
declare -r WAV2GRAPE_PYTHON_CMD="${WSPRDAEMON_ROOT_DIR}/wav2grape.py"


### Given: the path to the .../wav-archive.d/<DATE>/<RPORTER>_<GRID> directory under which there  may be  one or  more receivers with 24 hour wav files which have not 
###  been converted to DRF and uploaded to the GRAPE server
### Returns:  0 on nothing to do or success on uploading

declare    WD_TEST_RX_DIR=~/wsprdaemon/wav-archive.d/20240128/KFS=Q_CM87tj/KA9Q_Omni_WWV_IQ@S000199_999

function upload_24hour_wavs_to_grape_drf_server() {
    local reporter_wav_root_dir=$( realpath $1 )
#     reporter_wav_root_dir=${WD_TEST_RX_DIR}

    local reporter_upload_complete_file_name="${reporter_wav_root_dir}/${UPLOAD_TO_PSWS_SERVER_COMPLETED_FILE_NAME}"

    if [[ -f ${reporter_upload_complete_file_name} ]]; then
        echo "File ${reporter_upload_complete_file_name} exists, so upload of wav files has already been successful"
        return 0
    fi
    ### On the WD client the flac and 24hour.wav files are cached in the non-volitile  file system which has the format:
    ### ...../wsprdaemon/wav-archive.d/<DATE>/<WSPR_REPORTER_ID>_<WSPR_REPORTER_GRID>/<WD_RECEIVER_NAME>@<PSWS_SITE_ID>_<PSWS_INSTRUMENT_NUMBER>/<BAND>
    ### WSPR_REPORTER_ID, WSPR_REPORTER_GRID and WD_RECEIVER and WD_RECEIVER_NAME are assigned by the WD client and entered into the wsprdaemon.conf file
    ### Each WD client can support multiple WSPR_REPORTER_IDs, each of which can have the same or a unique WSPR_REPORTER_GRID
    ### Each WSPR_REPORTER_ID+WSPR_REPORTER_GRID is associated with one or more WSPR_RECIEVER_NAMEs, and each of those will support one or more BANDS
    ###
    local dir_path_list=( ${reporter_wav_root_dir//\// } )
    local wav_date=${dir_path_list[-2]}
    local reporter_info=${dir_path_list[-1]}
    local reporter_id=${reporter_info%_*}         ### Chop off the _GRID to get the WSPR reporter id
    local reporter_grid=${reporter_info#*_}       ### Chop off the REPROTER_ID to get the grid

    ### Search each receiver for wav files
    local receiver_dir
    local receiver_dir_list=( $(find "${reporter_wav_root_dir}" -mindepth 1 -maxdepth 1 -type d -not -name '*mutex.lock' | sort ) )
    if [[ ${#receiver_dir_list[@]} -eq 0 ]]; then
        echo "There are no receiver dirs under ${reporter_wav_root_dir}"
        return 1
    fi
    for receiver_dir in ${receiver_dir_list[@]} ; do
        local receiver_info="${receiver_dir##*/}"
        local receiver_name="${receiver_info%@*}"
        local pswsnetwork_info="${receiver_info#*@}"
        local psws_station_id="${pswsnetwork_info%_*}"
        local psws_instrument_id="${pswsnetwork_info#*_}"
        echo "Processing ${receiver_dir}:
               date: ${wav_date}- site: ${reporter_id} - receiver_name: $receiver_name - psws_station_id: $psws_station_id - psws_instrument_id: $psws_instrument_id" 1>&2
        rm -rf  ${GRAPE_TMP_DIR}/*
        umask 022
        local receiver_tmp_dir="$("$WAV2GRAPE_PYTHON_CMD" -i "$receiver_dir" -o "$GRAPE_TMP_DIR")"
        echo "DRF files can be found in ${receiver_tmp_dir}.  Now upload them"
        # upload to PSWS network
        (
            cd "$(dirname "$receiver_tmp_dir")"
            {
                echo "put -r .";
		        echo "mkdir c$(basename "$receiver_tmp_dir")\#$psws_instrument_id\#$(date -u +%Y-%m-%dT%H-%M)";
            } | sftp -b - "$psws_station_id"@"$PSWS_SERVER_URL"
        )
        rm -r "$receiver_tmp_dir"
    done
    echo touch "${reporter_upload_complete_file_name}"
}

upload_24hour_wavs_to_grape_drf_server $1
