#!/bin/bash

###  grape_utils.sh:  wakes up at every UTC 00:05, creates and uploads Digial RF files of the last 24 hours of WWV IQ recordings

###    Copyright (C) 2024  Robert S. Robinett
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

declare    GRAPE_ARCHIVE_PRESERVE_DATES_LIST=( ${GRAPE_ARCHIVE_PRESERVE_DATES_LIST[@]-20240407 20240408 20240409} )    ### Preserve the .wv files for the April 8th 2024 total eclipse +- 1 day
declare -r GRAPE_TMP_DIR="/run/wsprdaemon/grape_drf_cache"                                                          ### While creating a 24 hour 10 Hz IQ wav file, decompress the 1440 one minute wav files into this tmpfs file system
declare -r GRAPE_WAV_ARCHIVE_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/wav-archive"                                          ### Cache all 1440 one minute long, wavpack-compressed, 16000 IQ wav files in this dir tree
declare -r WD_SILENT_WV_FILE_PATH="${WSPRDAEMON_ROOT_DIR}/one-minute-silent-float.wv"                                  ### A wavpack-compressed wav file of one minute of silence.  When a minute file is missing  soft link to this file
declare -r MINUTES_PER_DAY=$(( 60 * 24 ))
declare -r HOURS_LIST=( $(seq -f "%02g" 0 23) )
declare -r MINUTES_LIST=( $(seq -f "%02g" 0 59) )
declare -r GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME="24_hour_10sps_iq.wav"
declare -r GRAPE_24_HOUR_10_HZ_WAV_STATS_FILE_NAME="24_hour_10sps_iq.stats"
declare -r PSWS_URL="pswsnetwork.caps.ua.edu"
declare -r PSWS_NEW_URL="pswsnetwork.eng.ua.edu"

### Return codes can only be in the range 0-255.  So we reserve a few of those codes for the following routines to commmunicate errors back to grape calling functions
declare -r          GRAPE_ERROR_RETURN_BASE=240
declare -r        GRAPE_ERROR_RETURN_NO_WVS=$(( ${GRAPE_ERROR_RETURN_BASE} + 0 ))
declare -r          GRAPE_ERROR_RETURN_BAND=$(( ${GRAPE_ERROR_RETURN_BASE} + 1 ))
declare -r        GRAPE_ERROR_REPAIR_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 2 ))
declare -r            GRAPE_ERROR_WV_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 3 ))
declare -r           GRAPE_ERROR_SOX_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 4 ))
declare -r GRAPE_ERROR_RETURN_REPAIR_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 5 ))
declare -r           GRAPE_ERROR_RETURN_MAX=$(( ${GRAPE_ERROR_RETURN_BASE} + 10 ))

function grape_return_code_is_error() {
    if [[ $1 -ge  ${GRAPE_ERROR_RETURN_BASE} && $1 -le  ${GRAPE_ERROR_RETURN_MAX} ]]; then
        return 0
    fi
    return 1
}

######### The functions which implement this service daemon follow this line ###############

# upload_24hour_wavs_to_grape_drf_server() is derived from Franco's grape.sh
# go from wav files to Grape:
# - convert from wav to Digital RF dataset
# - upload Digital RF dataset directory to PSWS network
#
# Franco Venturi - K4VZ - Mon 22 Jan 2024 01:20:14 PM UTC
# Rob Robinett - AI6VN - Mon Jan 30 2024 modified to be part of a Wsprdaemon client

#set -euo pipefail

declare -r PSWS_SERVER_URL='pswsnetwork.caps.ua.edu'
declare -r PSWS_SERVER_NEW_URL='pswsnetwork.eng.ua.edu'
declare -r UPLOAD_TO_PSWS_SERVER_COMPLETED_FILE_NAME='pswsnetwork_upload_completed'
declare -r WAV2GRAPE_PYTHON_CMD="${WSPRDAEMON_ROOT_DIR}/wav2grape.py"

### '-u ' sub menu
function grape_upload_all_local_wavs() {
   wd_logger 2 "Upload wav files not yet uploaded to the GRAPE server"

    local date_dir_list=( $( find -L ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -name '20??????' | sort ) )   ## Follow symbolic link to /mnt/wd-archive/...
    local date_dir
    for date_dir in ${date_dir_list[@]} ; do
        wd_logger 2 "Checking date_dir ${date_dir}"
        local site_dir_list=( $( find -L ${date_dir} -mindepth 1 -maxdepth 1 -type d  | sort) )
        local site_dir
        local search_txt="NOT_DEFINED"
        for site_dir in ${site_dir_list[@]} ; do
            wd_logger 1 "Checking site_dir ${site_dir} for NOT DEFINED"
            if [[ "$site_dir" == "*$search_txt*" ]]; then
                wd_logger 1 "Skipping ${site_dir} with NOT_DEFINED"
                new_dir=${site_dir/NOT_DEFINED/${GRAPE_PSWS_ID}}
                ### what we need to do:
                # test for new_dir existing.  If not, rename site_dir to new_dir
                # OTHERWISE, for each folder in site_dir, copy its contents to the same dir in new_dir
                wd_logger 1 "would create ${new_dir}"
            else
                wd_logger 2 "Checking site_dir ${site_dir}"
                upload_24hour_wavs_to_grape_drf_server ${site_dir}
            fi
        done
    done
    wd_logger 2 "Completed"
}

### Given: the path to the .../wav-archive/<DATE>/<RPORTER>_<GRID> directory under which there  may be  one or  more receivers with 24 hour wav files which have not 
###  been converted to DRF and uploaded to the GRAPE server
### Returns:  0 on nothing to do or success on uploading

function upload_24hour_wavs_to_grape_drf_server() {
    local reporter_wav_root_dir=$( realpath $1 )
    wd_logger 1 "Upload bands for reporter ${reporter_wav_root_dir##*/}"

    if [[ ! -d ${reporter_wav_root_dir} ]]; then
        wd_logger 1 "ERROR:  reporter_wav_root_dir='${reporter_wav_root_dir}' does not exist"
        return 1
    fi
    local reporter_wav_root_dir_list=( ${reporter_wav_root_dir//\// } )
    local reporter_wav_root_dir_date="${reporter_wav_root_dir_list[-2]}"
    local current_date=$(TZ=UTC printf "%(%Y%m%d)T" -1)
    if [[ "${reporter_wav_root_dir_date}" == "${current_date}" ]]; then
        wd_logger 2 "Skipping work on .wv files for today's date ${current_date}"
        return 0
    fi
    wd_logger 1 "On date '${current_date}' checking for date '${reporter_wav_root_dir_date}' bands which need a wav file to be created and then convert them to DRF and upload to the GRAPE server"

    local reporter_upload_complete_file_name="${reporter_wav_root_dir}/${UPLOAD_TO_PSWS_SERVER_COMPLETED_FILE_NAME}"

    if [[ -f ${reporter_upload_complete_file_name} ]]; then
        wd_logger 1 "File ${reporter_upload_complete_file_name} exists, so upload of wav files has already been successful"
        return 0
    fi
    wd_logger 1 "File ${reporter_upload_complete_file_name} does not exist, so create the wav files and upload the DRF files"

    ### On the WD client the .wv  and 24hour.wav files are cached in the non-volitile  file system which has the format:
    ### ...../wsprdaemon/wav-archive/<DATE>/<WSPR_REPORTER_ID>_<WSPR_REPORTER_GRID>/<WD_RECEIVER_NAME>@<PSWS_SITE_ID>_<PSWS_INSTRUMENT_NUMBER>/<BAND>
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
    local receiver_dir_list=( $( find -L "${reporter_wav_root_dir}" -mindepth 1 -maxdepth 1 -type d -not -name '*mutex.lock'| sort ) )
    if [[ ${#receiver_dir_list[@]} -eq 0 ]]; then
        wd_logger 1  "There are no receiver dirs under ${reporter_wav_root_dir}"
        return 1
    fi
    for receiver_dir in ${receiver_dir_list[@]} ; do
        local receiver_info="${receiver_dir##*/}"
        local receiver_name="${receiver_info%@*}"
        local pswsnetwork_info="${receiver_info#*@}"
        local psws_station_id="${pswsnetwork_info%_*}"
        local psws_instrument_id="${pswsnetwork_info#*_}"

        if [[ ! "${receiver_info}" =~ @ ]] || [[ -z "${psws_station_id}" ]] || [[ -z "${psws_instrument_id}" ]]; then
            wd_logger 1 "ERROR: directory ${receiver_dir} doesn't contain the '@' which is part of a PSWS ID OR the psws_station_id or the psws_instrument_id couldn't be extracted from it, so skip uploading of it"
            continue
        fi

        wd_logger 1  "Checking and cleaning up the band directories for receiver ${receiver_dir}"
        wd_logger 2  "date: ${wav_date}- site: ${reporter_id} - receiver_name: $receiver_name - psws_station_id: $psws_station_id - psws_instrument_id: ${psws_instrument_id}"

        ### Cleanup the .wv files  and create 24hour.wavs in all the bands
        local wav_file_count=0
        local band_dir_list=( $( find -L ${receiver_dir} -maxdepth 1 -type d  -regex '.*/\(WWV\|CHU\|K_BEACON\).*' | awk -F_ '{print $(NF-1), $NF, $0}' | sort -k1,1r -k2,2n  | cut -d' ' -f3) )
        local band_dir
        for band_dir in ${band_dir_list[@]} ; do
            wd_logger 2 "Checking WWV/CHU/K_BEACON band dir ${band_dir}"
            local band_24hour_wav_file="${band_dir}/24_hour_10sps_iq.wav"
            if [[ -f ${band_24hour_wav_file} ]]; then
                 if soxi ${band_24hour_wav_file} | grep -q '864000 samples' ; then
                     wd_logger 2 "Found a good existing ${band_24hour_wav_file}"
                  else
                     wd_logger 1 "ERROR: Found wav file ${band_24hour_wav_file} doesn't have the expected 860,000 samples in a 10Hz 24 hour wav file, so deleting it"
                     wd_rm ${band_24hour_wav_file}
                 fi
            fi
            if !  [[ -f ${band_24hour_wav_file} ]]; then
                wd_logger 1 "Creating ${band_24hour_wav_file}"
                grape_repair_band_bad_compressed_files ${band_dir}
                rc=$? ; if (( rc )); then
                    wd_logger 1 "WARNING: 'grape_repair_band_bad_compressed_files ${band_dir}' => ${rc}"
                fi
                grape_create_wav_file  ${band_dir}
                rc=$? ; if (( rc )); then
                    wd_logger 1 "WARNING: 'grape_create_wav_file ${band_dir}' => ${rc}"
                fi
            fi 
            if [[  -f ${band_24hour_wav_file} ]]; then
                wd_logger 1 "Found wav file ${band_24hour_wav_file}"
                (( ++wav_file_count ))
            else
                 wd_logger 1 "Neither found nor could create  ${band_24hour_wav_file}"
            fi
        done
        if (( ! wav_file_count )); then
            wd_logger 1 "WARNING: no wav files found or created for any bands, so skip DRF creation for this receiver/band"
            continue
        fi

        wd_logger 1  "Creating the DRF file from ${wav_file_count} bands of wav files"

        ### Create the DRF files for all the bands on this receiver
        rm -rf  ${GRAPE_TMP_DIR}/*          ## the -f suppresses an error when there are no files in that dir
        umask 022    ### Ensures that our 'sftp put .' doesn't enable the group access to the PSWS home directory and thus disable ssh autologin
        local wav2grape_stdout_file="${GRAPE_TMP_DIR}/${WAV2GRAPE_PYTHON_CMD##*/}.stdout"
        local wav2grape_stderr_file="${GRAPE_TMP_DIR}/${WAV2GRAPE_PYTHON_CMD##*/}.stderr"
        ${WAV2GRAPE_PYTHON_CMD} -i "${receiver_dir}" -o "${GRAPE_TMP_DIR}" > ${wav2grape_stdout_file}  2> ${wav2grape_stderr_file}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: '${WAV2GRAPE_PYTHON_CMD} -i $receiver_dir -o $GRAPE_TMP_DIR' =${rc}:\n$(<${wav2grape_stderr_file})"
            return ${rc}
        fi
        local receiver_tmp_dir="$(<${wav2grape_stdout_file} )"
        if [[ -z "${receiver_tmp_dir}" ]]; then
            wd_logger 1 "ERROR: wvunpack  decompressed files, but return a zero length name for its  receiver_tmp_dir"
            return 1
        fi

        wd_logger 1  "The DRF files have been created under ${receiver_tmp_dir}.  Now upload them.."

        local psws_trigger_dir_name="c${receiver_tmp_dir##*/}_\#${psws_instrument_id}_\#$(date -u +%Y-%m%dT%H-%M)"       ### The root directory of where our DRF file tree will go on th ePSWS server
        wd_logger 1 "Uploading our DRF directory tree from local dir '${receiver_tmp_dir%/*}' and then creating the trigger dir '${psws_trigger_dir_name}' on our site's home dir on  the PSWS server"

        local sftp_cmds_file="${WSPRDAEMON_TMP_DIR}/sftp.cmds" 
        echo "put -r . 
              mkdir ${psws_trigger_dir_name}" > ${sftp_cmds_file}
        cd "${receiver_tmp_dir%/*}"
        rc=$? ; if (( rc )); then
            cd - > /dev/null
            wd_logger 1 "ERROR: 'cd ${receiver_tmp_dir%/*}' => ${rc}"
            return ${rc}
        fi

        local sftp_stderr_file="${GRAPE_TMP_DIR}/sftp.out"
        sftp -v -l ${SFTP_BW_LIMIT_KBPS-1000} -b ${sftp_cmds_file} "${psws_station_id}@${PSWS_SERVER_URL}" >& ${sftp_stderr_file}
        rc=$?
        cd - > /dev/null
        if (( rc )); then
            wd_logger 1 "ERROR: 'sftp -l ${SFTP_BW_LIMIT_KBPS-1000} -b ${sftp_cmds_file} ${psws_station_id}@${PSWS_SERVER_URL}' -> ${rc}:\n$(<${sftp_stderr_file})"
            return ${rc}
        fi
    done
    touch "${reporter_upload_complete_file_name}"
    wd_logger 1  "Upload was successful, so create '${reporter_upload_complete_file_name}'"
}

function grape_test_auto_login() {
    local station_id=$1
    local rc

    wd_logger 2 "Starting by trying to execute a 'sftp..."
    timeout ${PSWS_SSH_TIMEOUT-5} sftp -b /dev/null ${station_id}@${PSWS_URL} &>/dev/null
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'ssh ...' => $rc  So can't autologin to account '${station_id}'"
    else
        wd_logger 2 "Autologin to account '${station_id}' was successful"
    fi
    return $rc
}

######  '-p'   upload public key to PSWS server
function grape_upload_public_key() {
    local rc

    wd_logger 2 "Starting"

    if [[ -z "${GRAPE_PSWS_ID-}" ]]; then
        wd_logger 1 "ERROR: GRAPE_PSWS_ID has not been defined in wsprdameon.conf"
        return 1
    fi

    local station_id=${GRAPE_PSWS_ID%_*}   ### Chop off the _ID.. to get the PSWS site name
    grape_test_auto_login $station_id
    rc=$? ; if (( rc == 0 )); then
        wd_logger 2 "Autologin for site ${station_id} is already setup"
        return 0
    fi
    wd_logger 1 "Setup autologin to the GRAPE server for this GRAPE SITE_ID='${station_id}' by entering when prompted the value of 'token' in the PSWS user's admim page"

    ssh-copy-id -o ConnectTimeout=5 -f ${station_id}@${PSWS_URL}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: Failed to setup auto login. 'ssh-copy-id  ${station_id}@${PSWS_URL}' => ${rc}"
        return $rc
    fi
    wd_logger 1 "Auto login has been successfully set up"
    return 0
}

###### '-S'
function grape_get_date_status() {
    local date=$1

    if [[ "${date}" == "h" ]]; then
        wd_logger 1 "usage: -S YYYYMMDD"
        return 0
    fi
    local date_root_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}"

    if [[  ! -d ${date_root_dir} ]]; then
        wd_logger 1 "Can't find ${date_root_dir}"
        return 1
    fi
    local rc=0
    local band_dir_list=( $( find -L ${date_root_dir} -mindepth 3 -type d  -regex '.*/\(WWV\|CHU\|K_BEACON\).*' | awk -F_ '{print $(NF-1), $NF, $0}' | sort -k1,1r -k2,2n  | cut -d' ' -f3) )
    wd_logger 1 "Found ${#band_dir_list[@]} bands for UTC date ${date}"
    for band_dir in ${band_dir_list[@]} ; do
        local compressed_wav_file_list=( $( find -L ${band_dir} -name '*.wv' ) )
        local silent_compressed_wav_file_list=( $( find -L ${band_dir} -type l -name '*.wv' ) )
        printf "In %-90s found ${#compressed_wav_file_list[@]} .wv files"  ${band_dir}
        if [[ ${#silent_compressed_wav_file_list[@]} -gt 0 ]]; then
            printf ", of which ${#silent_compressed_wav_file_list[@]} are silence files"
        fi
        printf "\n"
    done
    return ${rc}
}

### '-t' 
function grape_show_all_dates_status(){
    local wav_archive_dates_dir_list=( $( find -L ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        grape_get_date_status ${wav_archive_date}
    done
}

### '-p' 
function grape_purge_all_empty_date_trees(){
    local wav_archive_dates_dir_list=( $( find -L ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        local date_files_list=( $( find -L ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date} -type f ) )
        if [[ ${#date_files_list[@]} -eq 0 ]]; then
            wd_logger 1 "Purging empty date  tree ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}"
            rm -r ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}
        else
            wd_logger 2 "$(printf  "Found %5d files in %s\n" ${#date_files_list[@]} "${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}" )"
        fi
    done
}

declare GRAPE_AUTO_DELETE_BAD_FLACS="${GRAPE_AUTO_DELETE_BAD_FLACS-yes}"

function grape_repair_band_bad_compressed_files() {
    local band_dir=$1

    if [[ ! "${band_dir}" =~ WWV|CHU ]]; then
        wd_logger 1 "Band '${band_dir}' is not a WWV or CHU band, so skip repairing"
        return 0
    fi
    local compressed_wav_file_list=( $( find -L ${band_dir} -name '*.wv' | sort) )
    if [[ ${#compressed_wav_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "There are no .wv files in ${band_dir}, so returning an this as an error"
        return 1
    fi

    wd_logger 1 "Checking all the ${#compressed_wav_file_list[@]} .wv files in band dir ${band_dir} are present and valid and that the wav files they contain are valid"
    local rc
    local bad_wav_file_count=0
    local good_wav_file_count=0
    local compressed_wav_file
    for compressed_wav_file in  ${compressed_wav_file_list[@]} ; do
        wvunpack -v ${compressed_wav_file} 2> /tmp/wvunpack.log
        rc=$? ; if (( ! rc )); then
            (( ++good_wav_file_count ))
            wd_logger 3 " wavunpack reports file ${compressed_wav_file} is good"
        else
            wd_logger 1 "ERROR: wavunpack reports file ${compressed_wav_file} is corrupt, so deleting it"
            (( ++bad_wav_file_count ))
            wd_rm  ${compressed_wav_file}
        fi
    done
    if (( bad_wav_file_count )); then
        wd_logger 1 "Removed ${bad_wav_file_count} bad .wv files"
    fi
    if (( ! good_wav_file_count )); then
        wd_logger 1 "There are no good .wv files in this ${band_dir}"
        return 1
    fi

    local band_date=${compressed_wav_file_list[0]##*/}
    band_date=${band_date%%T*}
    local band_freq=${compressed_wav_file_list[0]##*/}
    band_freq=${band_freq#*_}
    band_freq=${band_freq/_iq.wv/}
    wd_logger 1 "Found ${#compressed_wav_file_list[@]} .wv files in ${band_dir}. Check there is a .wv for each minute for this band_date=${band_date},  band_freq=${band_freq}"

    local silence_file_list=()
    local expected_files_list=()
    local hour
    for hour in ${HOURS_LIST[@]} ; do
        local minute 
        for minute in ${MINUTES_LIST[@]} ; do
            local expected_file_name="${band_date}T${hour}${minute}00Z_${band_freq}_iq.wv"
            local expected_file_path=${band_dir}/${expected_file_name}
            expected_files_list+=( ${expected_file_path} )
            if [[ "${compressed_wav_file_list[@]}" =~ ${expected_file_path} ]]; then
                wd_logger 2 "Found expected IQ file ${expected_file_path}"
            else
                wd_logger 2 "Can't find expected IQ file ${expected_file_path}, so link the 1 minute of silence file in its place"
                ln -s ${WD_SILENT_WV_FILE_PATH}  ${expected_file_path}
                silence_file_list+=( ${expected_file_path##*/} )
            fi
        done
    done

    local silence_files_added=${#silence_file_list[@]}
    if (( ! silence_files_added )); then
        wd_logger 1 "No silence files were added"
    else
        echo "${silence_file_list[@]}" > silence_file_list.txt
        wd_logger 1 "Created ${silence_files_added} silence files"
        if (( silence_files_added >=  GRAPE_ERROR_RETURN_BASE)); then
            silence_files_added=$(( ${GRAPE_ERROR_RETURN_BASE} - 1 ))
            wd_logger 1 "Added ${#silence_file_list[@]} silence files, more than can be returned from a bash function.  So returning instead ${silence_files_added}"
        fi
    fi

    wd_logger 1 "Check for extra .wv files and flush them"
    local extra_files_list=()
    for found_file in "${compressed_wav_file_list[@]}"; do
        if [[ ! " ${expected_files_list[*]} " =~ ${found_file} ]]; then
            wd_logger 1 "Flushing file ${found_file} which is not expected to be in this directory"
            extra_files_list+=( ${found_file} )
            wd_rm ${found_file}
        fi
    done
    if (( ${#extra_files_list[@]} )); then
        wd_logger 1 "Founbd and flushed ${#extra_files_list[@]} extra .wv files"
    else
        wd_logger 1 "Found no extra .wv files"
    fi

    if (( silence_files_added )); then
        wd_logger 1 "Returning count of the ${silence_files_added}"
        return ${silence_files_added}
    else
         wd_logger 1 "Returning zero, since no silence files were added"
         return 0
    fi
}

### 'To execute this ffrom the cmd line execute: 'WD -g "R <YYYYMMDD>"'
function grape_repair_date_wvs() {
    local date=$1

    if [[ "${date}" == "h" ]]; then
        wd_logger 1 "usage: -R YYYYMMDD"
        return 0
    fi
    local date_root_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${date}"
    
    if [[  ! -d ${date_root_dir} ]]; then
        wd_logger 1 "Can't find ${date_root_dir}"
        return 1
    fi

    ### Get a list of bands sorted so the WWV bands are first and in frequency order followed by the CHU bands in frequency order. Thanks to chatgbt:
    local band_dir_list=( $( find -L ${date_root_dir} -mindepth 3 -type d  -regex '.*/\(WWV\|CHU\|K_BEACON\).*' | awk -F_ '{print $(NF-1), $NF, $0}' | sort -k1,1r -k2,2n  | cut -d' ' -f3) )
    wd_logger 1 "Repairing any defective and/or missing .wv files in these ${#band_dir_list[@]} bands: ${band_dir_list[*]##*/}"
    for band_dir in ${band_dir_list[@]} ; do
        wd_logger 1 "Repairing ${band_dir##*/}"
        grape_repair_band_bad_compressed_files ${band_dir}
    done
}

### '-r' 
function grape_repair_all_dates_wvs()
{
    local current_date
    TZ=UTC printf -v current_date "%(%Y%m%d)T"
    local wav_archive_dates_dir_list=( $( find -L ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        if [[ ${wav_archive_date} ==  ${current_date} ]] ; then
            wd_logger 1 "Skipping grape_repair_date_wvs for current UTC day ${current_date}"
        else
            grape_repair_date_wvs ${wav_archive_date}
        fi
    done
}

### Give a DATE...BAND directory which should have the requried 1440 minute .wv files. create a single w4 hour long 10 Hz BW wav file
### Returns: 0 => if GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME existed, 1 => created new GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME, >  ${GRAPE_ERROR_RETURN_BASE} if there was a error
function grape_create_wav_file()
{
    local compressed_wav_file_dir=$1
    local rc

    local output_10sps_wav_file="${compressed_wav_file_dir}/${GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME}"
    wd_logger 2 "Check for the 10 sps wav file ${output_10sps_wav_file} and create it if it doesn't exist"
    if [[ -f ${output_10sps_wav_file} ]]; then
        wd_logger 2 "The 10 sps wav file ${output_10sps_wav_file} exists, so there is nothing to do in this directory"
        return 0
    fi

    local compressed_wav_file_list=()
    compressed_wav_file_list=( $( find -L ${compressed_wav_file_dir} -name '*.wv' -printf '%p\n' | sort ) )   ### sort the output of find to ensure the array elements are in time order
    rc=$?
    if (( rc )); then
        wd_logger 1 "ERROR: 'find -L ${compressed_wav_file_dir}  -name '*.wv' -printf '%p\n' | sort' => ${rc}"
        return ${rc}
    fi
    if (( ${#compressed_wav_file_list[@]} == 0 )); then
        wd_logger 1 "ERROR: found no .wv files in ${compressed_wav_file_dir}, so delete that directory"
        echo rm -r ${compressed_wav_file_dir}
        return ${GRAPE_ERROR_RETURN_NO_WVS} 
    fi
    if (( ${#compressed_wav_file_list[@]} !=  MINUTES_PER_DAY )); then
        local files_date=${compressed_wav_file_list[0]##*/}       ### The file date of all the .wv files should match the date of the root directory, but it is easier to parse the .wv file name to get the date
        files_date=${files_date%%T*}
        local current_date
        TZ=UTC printf -v current_date "%(%Y%m%d)T"
        if false && [[ ${files_date} == ${current_date} ]] ; then
            wd_logger 1 "Skipping create for current UTC day ${current_date}"
            return 0
        fi

        local missing_compressed_wav_file_count=$((  MINUTES_PER_DAY - ${#compressed_wav_file_list[@]} ))
        wd_logger 1 "${missing_compressed_wav_file_count} .wv files are missing in ${compressed_wav_file_dir}, so add silence files to fill the directory"
        grape_repair_band_bad_compressed_files ${compressed_wav_file_dir}
        rc=$?
        if (( ! rc )); then
            wd_logger 1 "ERROR: because there were ${#compressed_wav_file_list[@]} .wv files instead of the expected ${MINUTES_PER_DAY} .wv files in ${compressed_wav_file_dir} we called grape_repair_band_bad_compressed_files(), but no repairs were done or silent files added"
        else
            wd_logger 1 "grape_repair_band_bad_compressed_files() reported it repaired  ${compressed_wav_file_dir} by adding ${rc} (or more) silence files"
        fi
        ### Since the repair reported success we need to recreate the compressed_wav_file_list() 
        compressed_wav_file_list=( $( find -L ${compressed_wav_file_dir} -name '*.wv' -printf '%p\n' | sort ) )
        if [[ ${#compressed_wav_file_list[@]} -ne ${MINUTES_PER_DAY}  ]]; then
            wd_logger 1 "ERROR: grape_repair_band_bad_compressed_files() failed to leave ${compressed_wav_file_dir} with the expected ${MINUTES_PER_DAY} .wv files"
            return  ${GRAPE_ERROR_RETURN_REPAIR_FAILED}
        fi
    fi

    wd_logger 1 "Creating one 24 hour, 10 hz wav file ${output_10sps_wav_file} from ${#compressed_wav_file_list[@]} .wv files..."
    local sox_log_file_name="${compressed_wav_file_dir}/sox.log"
    ulimit -n 2048    ### sox will open 1440+ files, so up the open file limit
    nice -n 19 sox ${compressed_wav_file_list[@]} --encoding float --bits 32 ${output_10sps_wav_file} rate 10 >& ${sox_log_file_name}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'sox ...' => ${rc}:\n$(<${sox_log_file_name})"
         return ${GRAPE_ERROR_SOX_FAILED}
    fi
    if [[ -z  ${sox_log_file_name} ]]; then
        wd_logger 1 "Created ${output_10sps_wav_file}, but sox reported:\n$(< ${sox_log_file_name})"
    else
        wd_logger 1 "Created ${output_10sps_wav_file}"
    fi
    return 1
}

### To execute this from the command line run:  'WD -g "C <YYYYMMDD>"
### Searches all receivers and bands under 'date' for 24h wav files and creates them if needed
### Returns:  0 if date is today UTC or no 24 wav files were created, < 0 if there is an error, > 0 is the count of newly created wav files
function grape_create_24_hour_wavs() {
    local archive_date=$1

    if [[ "${archive_date}" == "h" ]]; then
        wd_logger 1 "usage: -s yyyymmdd"
        return 0
    fi
    local current_date
    TZ=UTC printf -v current_date "%(%Y%m%d)T"
    if [[ ${archive_date} ==  ${current_date} ]] ; then
        wd_logger 1 "Skipping create for current UTC day ${current_date}"
        return -1
    fi

    local date_root_dir="${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${archive_date}"

    if [[  ! -d ${date_root_dir} ]]; then
        wd_logger 1 "ERROR: can't find ${date_root_dir}"
        return -2
    fi
    local new_wav_count=0
    local return_code=0
    local band_dir_list=( $( find -L ${date_root_dir} -mindepth 3 -type d  -regex '.*/\(WWV\|CHU\|K_BEACON\).*' | awk -F_ '{print $(NF-1), $NF, $0}' | sort -k1,1r -k2,2n  | cut -d' ' -f3) )
    wd_logger 1 "found ${#band_dir_list[@]} bands"
    for band_dir in ${band_dir_list[@]} ; do
        wd_logger 1 "create 24 hour wav file in ${band_dir}"
        local rc
        grape_create_wav_file ${band_dir}
        rc=$?
        if grape_return_code_is_error ${rc} ; then
             wd_logger 1 "ERROR: 'grape_create_wav_file ${band_dir}' => ${rc}"
        elif (( ! rc )); then
            wd_logger 2 "Found existing 24h.wav file for band ${band_dir}"
        else
            wd_logger 1 "Created a new 24h.wav file for band ${band_dir}"
            (( ++ new_wav_count ))
        fi
    done
    
    if (( return_code <  0 )); then
         wd_logger 1 "Returning error ${return_code} after one or more errors.  Also created ${new_wav_count} new wav files"
         return ${return_code}
    fi
    if (( new_wav_count )); then
        wd_logger 1 "Returning ${new_wav_count} new wav files"
    fi
     return ${new_wav_count}  
}

### '-c' Searches all the date/... directories (except for today), repairs if necessary by adding silence files, then creates a 24 hour 10 hz wav file.
###  Returns:  number of newly created wav files, or -1 if there was a failure
function grape_create_all_24_hour_wavs(){
    local current_date
    TZ=UTC printf -v current_date "%(%Y%m%d)T"    ### This assigns the output of printf to the bash variable we declared on the line above

    local return_code=0
    local new_wav_count=0

    local wav_archive_dates_dir_list=( $( find -L ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        local rc
        if [[ ${wav_archive_date} ==  ${current_date} ]] ; then
            wd_logger 2 "Skipping grape_create_24_hour_wavs for current UTC day ${current_date}"
            rc=0
        else
            grape_create_24_hour_wavs ${wav_archive_date}
            rc=$?
            if [[ ${rc} -lt 0 ]]; then
                wd_logger 1 "ERROR: 'grape_create_24_hour_wavs ${wav_archive_date}' => ${rc}"
                return_code=${rc}
            elif [[  ${rc} -gt 0 ]]; then
                wd_logger 1 "'grape_create_24_hour_wavs ${wav_archive_date}' encountered no errors and created ${rc} new wav files"
                (( new_wav_count +=  ${rc} ))
            else
                wd_logger 2 "'grape_create_24_hour_wavs ${wav_archive_date}' encountered no errors, nor did it need to create one or more wav files"
            fi
        fi
    done

    if [[ ${return_code} -lt 0 ]]; then
         wd_logger 1 "Returning error ${return_code} after one or more errors.  Also created ${new_wav_count} new wav files"
         return ${return_code}
    fi
     wd_logger 2 "Returning ${new_wav_count} new wav files"
     return ${new_wav_count}
}

declare LAST_HHMM="0"                       ### Check and upload each time WD is started
declare GRAPE_UPLOAD_START_HHMM="0005"      ### Then check and upload each dat at 5 minutes after UTC 00:00

function grape_upload_service() {
    local grape_uploads_enabled="no"
    get_config_file_variable grape_uploads_enabled "GRAPE_UPLOADS_ENABLED"
    if [[ ${grape_uploads_enabled} == "yes" ]]; then
        grape_uploader
    fi
}

### '-a' This function is called every odd 2 minutes by the watchdog daemon.
function grape_uploader() {
    if [[ -z "${GRAPE_PSWS_ID-}"  ]]; then
         wd_logger 2 "GRAPE uploads are not enabled, so do nothing"
         return 0
    fi
    local current_hhmm=$(TZ=UTC printf "%(%H%M)T")
    if [[ ${LAST_HHMM} == "0" || ${current_hhmm} != ${LAST_HHMM} && ${current_hhmm} == ${GRAPE_UPLOAD_START_HHMM} ]]; then
        wd_logger 1 "Skipping upload at current HHMM = ${current_hhmm}, LAST_HHMM = ${LAST_HHMM}"
        LAST_HHMM=${current_hhmm}
        return 0
    fi
    LAST_HHMM=${current_hhmm}
    wd_logger 1 "Checking for new 24h.wav files to upload"
    local rc

    grape_create_all_24_hour_wavs
    rc=$? ; if (( rc )); then
        wd_logger 1 "There were ${rc} new 24h.wav files created"
    else
        wd_logger 1 "There were no new 24h.wav files created"
    fi
    grape_upload_all_local_wavs
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: grape_upload_all_local_wavs => ${rc}"
    else
        wd_logger 2 "Successful upload of  ${rc} new 24h.wav files"
    fi
    return ${rc}
}

### Spawned by watchdog daemon at startup and every odd minute it looks for wav files to compress and archive 
function grape_upload_daemon() {
    local root_dir=$1

    mkdir -p ${root_dir}
    cd ${root_dir}

    wd_logger 1 "Starting in $PWD"

    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD
    while true; do
        wd_logger 1 "Checking for new .wav files to upload"
        grape_uploader
        local sleep_seconds=$(seconds_until_next_odd_minute)
        wd_logger 1 "Sleeping ${sleep_seconds} seconds in order to wake up at the next odd minute"
        wd_sleep  ${sleep_seconds}
    done
}

### Calculate the semitones needed by sox to change freqeuncies in a file:  "soc in.wav out.wav pitch PITCH_CHANGE_IN_CENTS"
### Where PITCH_CHANGE_IN_CENTS can be computed by:  'bc -l <<< "l(NEW_FREQ/OLD_FREQ) / l(2) * 12 *100 "'
### But I don't know if soc can change the pitch of 800 to 10 hz.

function grape_print_usage() {
    wd_logger 1 "GRAPE sub-menu commands:
    -C YYYYMMDD      Create 24 hour 10 Hz wav files for all bands 
    -S YYYYMMDD      Show the status of the files in that tree
    -R YYYYMMDD      Repair the directory tree by filling in missing minutes with soft links to ~/wsprdaemon/one-minute-silent-float.wv
    -a               Search for 24h.wav files.  If a new 24h.wav is created, then upload it to wsprdaemon.org.  Called by the watchdog_daemon()
    -c               Create 10 Hz wav files for each band for all dates from the 1440 compressed .wv files in each band
    -p               Purge all empty date trees
    -r               Repair all date trees
    -t               Show status of all the date trees
    -u               Upload all of the local 24_hour_10sps_iq.wav files to the grape@wsprdaemon.org account
    -d [a|i|z|s]     systemctl commands for daemon (a=start, i=install and enable, z=disable and stop, s=show status"
}

function grape_menu() {
    case ${1--h} in
        -a)
            grape_uploader
            ;;
        -c)
            grape_create_all_24_hour_wavs
            ;;
        -C)
            grape_create_24_hour_wavs ${2-h}
            ;;
        -S)
            grape_get_date_status ${2-h}
            ;;
        -R)
            grape_repair_date_wvs ${2-h}
            ;;
        -p)
            grape_upload_public_key
            ;;
        -P)
            grape_purge_all_empty_date_trees
            ;;
        -t)
            grape_show_all_dates_status
            ;; 
        -r) 
            grape_repair_all_dates_wvs
            ;;
        -u)
            grape_upload_all_local_wavs
            ;;
       -a)
            spawn_daemon ${2-0}
            ;;
        -A)
            ### If this is installed as a Pi daemon by '-d a', the systemctl system will execute '-A'.  
            spawn_daemon ${KIWI_STARTUP_DELAY_SECONDS}
            ;;
        -z)
            kill_daemon
            ;;
        -s)
            get_daemon_status
            ;;
        -d)
            startup_daemon_control ${2-h}
            ;;
        -h)
            grape_print_usage
            ;;
        *)
            wd_logger 1 "ERROR: flag '$1' is not valid"
            ;;
    esac
    return 0
}

### grape_init() is run during wd_setup, so I/O goes to the user terminal so they can be asked for their PSWS token/password
function grape_init() {
    wd_logger 2 "Starting"
    if [[ -z "${GRAPE_PSWS_ID-}" ]]; then
        wd_logger 2 "This WD server is not configured to upload to the HamSCI GRAPE server"
        return 0
    fi

    local rc
    sudo mkdir -p ${GRAPE_TMP_DIR}
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: can't create ${GRAPE_TMP_DIR} "
        return ${rc}
    fi
    sudo chown "${USER}:$(id -gn)" ${GRAPE_TMP_DIR}

    if ! install_debian_package "libhdf5-dev" ; then
        wd_logger 1 "ERROR: 'install_debian_package libhdf5-dev' => $?"
        exit 1
    fi

    local grape_python_package_list=( "digital_rf" "soundfile" )
    local python_package
    for python_package in ${grape_python_package_list[@]}; do
        install_python_package "${python_package}"
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: can't install python package '${python_package}'"
            return ${rc}
        fi
    done

    if ! [[ -d ~/.ssh ]] || ! find -L ~/.ssh -type f -name '*.pub' | grep -q .; then
        wd_logger 1 "This server has no ssh private/public keypair which is needed for the GRAPE upload service to run.  So running 'ssh-keygen' to create them"
        ssh-keygen
        rc=$? ;  if (( rc )); then
            wd_logger 1 "ERROR:  GRAPE_PSWS_ID is configured, but this server has no ssh public key needed for this feature to run"
            return ${rc}
        fi
    fi

    ### Verifies auto login is enabled OR prompts for the user to enter the token/passsword for this <SITE_ID>
    grape_upload_public_key
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: can't setup auto login which is needed for uploads"
    fi
    return $rc
}

grape_init
rc=$?
if (( rc )); then
    wd_logger 1 "ERROR: grape_init => $rc"
fi
return $rc

