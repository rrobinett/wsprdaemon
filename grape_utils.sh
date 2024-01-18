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

declare -r GRAPE_TMP_DIR="/tmp/wd_grape_wavs"                                  ### While creating a 24 hour 10 Hz IQ wav file, decompress the 1440 one minute wav files into this tmpfs file system
declare -r GRAPE_WAV_ARCHIVE_ROOT_PATH="${WSPRDAEMON_ROOT_DIR}/wav-archive.d"  ### Cache all 1440 one minute long, flac-compressed, 16000 IQ wav files in this dir tree
declare -r WD_SILENT_FLAC_FILE_PATH="${WSPRDAEMON_ROOT_DIR}/silent_iq.flac"    ### A flac-compressed wav file of one minute of silence.  When a minute file is missing , hard link to this file
declare -r MINUTES_PER_DAY=$(( 60 * 24 ))
declare -r HOURS_LIST=( $(seq -f "%02g" 0 23) )
declare -r MINUTES_LIST=( $(seq -f "%02g" 0 59) )
declare -r GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME="24_hour_10sps_iq.wav"
declare -r GRAPE_24_HOUR_10_HZ_WAV_STATS_FILE_NAME="24_hour_10sps_iq.stats"
export     RSYNC_PASSWORD=${RSYNC_PASSWORD-hamsci}

### Return codes can only be in the range 0-255.  So we reserve a few of those codes for the following routines to commmunicate errors back to grape calling functions
declare -r GRAPE_ERROR_RETURN_BASE=240
declare -r GRAPE_ERROR_RETURN_NO_FLACS=$(( ${GRAPE_ERROR_RETURN_BASE} + 0 ))
declare -r GRAPE_ERROR_RETURN_BAND=$(( ${GRAPE_ERROR_RETURN_BASE} + 1 ))
declare -r GRAPE_ERROR_REPAIR_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 2 ))
declare -r GRAPE_ERROR_FLAC_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 3 ))
declare -r GRAPE_ERROR_SOX_FAILED=$(( ${GRAPE_ERROR_RETURN_BASE} + 4 ))
declare -r GRAPE_ERROR_RETURN_MAX=$(( ${GRAPE_ERROR_RETURN_BASE} + 10 ))

function grape_return_code_is_error() {
    if [[ $1 -ge  ${GRAPE_ERROR_RETURN_BASE} && $1 -le  ${GRAPE_ERROR_RETURN_MAX} ]]; then
        return 0
    fi
    return 1
}

######### The functions which implement this service daemon follow this line ###############
function grape_init() {
    if [[ ! -d ${GRAPE_TMP_DIR} ]]; then
        wd_logger 1 "Creating ${GRAPE_TMP_DIR}"
        sudo mkdir ${GRAPE_TMP_DIR}
    fi
    local rc
    mountpoint -q ${GRAPE_TMP_DIR}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        sudo mount -t tmpfs -o size=6G tmpfs ${GRAPE_TMP_DIR}
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            wd_logger 1 "ERROR: ' sudo mount -t tmpfs -o size=6G tmpfs ${GRAPE_TMP_DIR}' => ${rc}"
            return ${rc}
        fi
    fi
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
    local band_dir_list=( $(find ${date_root_dir} -mindepth 3 -type d) )
    wd_logger 1 "Found ${#band_dir_list[@]} bands for UTC date ${date}"
    for band_dir in ${band_dir_list[@]} ; do
        local flac_file_list=( $( find ${band_dir} -type f -name '*.flac') )
        local silent_flac_file_list=( $( find ${band_dir} -links +1 -type f -name '*.flac') )
        printf "In %-90s found ${#flac_file_list[@]} flac files"  ${band_dir}
        if [[ ${#silent_flac_file_list[@]} -gt 0 ]]; then
            printf ", of which ${#silent_flac_file_list[@]} are silence files"
        fi
        printf "\n"
    done
    return ${rc}
}

### '-t' 
function grape_show_all_dates_status(){
    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        grape_get_date_status ${wav_archive_date}
    done
}

### '-p' 
function grape_purge_all_empty_date_trees(){
    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        local date_files_list=( $( find ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date} -type f ) )
        if [[ ${#date_files_list[@]} -eq 0 ]]; then
            wd_logger 1 "Purging empty date  tree ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}"
            rm -r ${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}
        else
            wd_logger 2 "$(printf  "Found %5d files in %s\n" ${#date_files_list[@]} "${GRAPE_WAV_ARCHIVE_ROOT_PATH}/${wav_archive_date}" )"
        fi
    done
}

function grape_repair_band_flacs() {
    local band_dir=$1
    local flac_file_list=( $( find ${band_dir} -type f -name '*.flac') )
    if [[ ${#flac_file_list[@]} -eq ${MINUTES_PER_DAY} ]]; then
        wd_logger 1 "Found the expected ${#flac_file_list[@]} flac files in ${band_dir}"
        return 0
    fi
    local band_date=${flac_file_list[0]##*/}
    band_date=${band_date%%T*}
    local band_freq=${flac_file_list[0]##*/}
    band_freq=${band_freq#*_}
    band_freq=${band_freq/_iq.flac/}
    wd_logger 2 "Found only ${#flac_file_list[@]} flac files in ${band_dir} so it needs repair. band_date=${band_date},  band_freq=${band_freq}"
    local silence_file_list=()
    local hour
    for hour in ${HOURS_LIST[@]} ; do
        local minute 
        for minute in ${MINUTES_LIST[@]} ; do
            local expected_file_name="${band_date}T${hour}${minute}00Z_${band_freq}_iq.flac"
            local expected_file_path=${band_dir}/${expected_file_name}
            # if [[ ! -f ${expected_file_path} ]]; then
            if [[ ! "${flac_file_list[@]}" =~ ${expected_file_path} ]]; then
                wd_logger 2 "Can't find expected IQ file ${expected_file_path}, so link the 1 minute of silence file in its place"
                #read -p "Create silence file ${expected_file_path}? => "
                ln ${WD_SILENT_FLAC_FILE_PATH}  ${expected_file_path}
                silence_file_list+=( ${expected_file_path##*/} )
            else
                 wd_logger 2 "Found expected IQ file ${expected_file_path}"
            fi
        done
    done

    local silence_files_added=${#silence_file_list[@]}
    if [[ ${silence_files_added} -gt 0 ]] ; then
        echo "${silence_file_list[@]}" > silence_file_list.txt
        wd_logger 2 "Created ${silence_files_added} silence files:  $( < silence_file_list.txt)"
        if [[ ${silence_files_added} -ge ${GRAPE_ERROR_RETURN_BASE} ]]; then
            silence_files_added=$(( ${GRAPE_ERROR_RETURN_BASE} - 1 ))
            wd_logger 1 "Added ${#silence_file_list[@]} silence files, more than can be returned from a bash function.  So returning instead ${silence_files_added}"
        fi
    fi
    return ${silence_files_added}
}


### '-R'
function grape_repair_date_flacs() {
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
    local band_dir_list=( $(find ${date_root_dir} -mindepth 3 -type d) )
    wd_logger 1 "Found ${#band_dir_list[@]} bands"
    for band_dir in ${band_dir_list[@]} ; do
        grape_repair_band_flacs ${band_dior}
    done
}

### '-r' 
function grape_repair_all_dates_flacs()
{
    local current_date
    TZ=UTC printf -v current_date "%(%Y%m%d)T"
    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        if [[ ${wav_archive_date} ==  ${current_date} ]] ; then
            wd_logger 1 "Skipping grape_repair_date_flacs for current UTC day ${current_date}"
        else
            grape_repair_date_flacs ${wav_archive_date}
        fi
    done
}

### Give a DATE...BAND directory which should have the requried 1440 minute flac files. create a single w4 hour long 10 Hz BW wav file
### Returns: 0 => if GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME existed, 1 => created new GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME, >  ${GRAPE_ERROR_RETURN_BASE} if there was a error
function grape_create_wav_file()
{
    local flac_file_dir=$1
    local rc

    local output_10sps_wav_file="${flac_file_dir}/${GRAPE_24_HOUR_10_HZ_WAV_FILE_NAME}"
    if [[ -f ${output_10sps_wav_file} ]]; then
        wd_logger 2 "The 10 sps wav file ${output_10sps_wav_file} exists, so there is nothing to do in this directory"
        return 0
    fi

    local flac_file_list=( $(find ${flac_file_dir} -type f -name '*.flac' -printf '%p\n' | sort ) )   ### sort the output of find to ensure the array elements are in time order
    if [[ ${#flac_file_list[@]} -eq 0 ]]; then
        wd_logger 1 "ERROR: found no flac files in ${flac_file_dir}, so delete that directory"
        rm -r ${flac_file_dir}
        return ${GRAPE_ERROR_RETURN_NO_FLACS} 
    fi
    if [[ ${#flac_file_list[@]} -ne ${MINUTES_PER_DAY}  ]]; then
        local files_date=${flac_file_list[0]##*/}       ### The file date of all the flac files should match the date of the root directory, but it is easier to parse th eflac file name to get the date
        files_date=${files_date%%T*}
        local current_date
        TZ=UTC printf -v current_date "%(%Y%m%d)T"
        if [[ ${files_date} == ${current_date} ]] ; then
            wd_logger 1 "Skipping create for current UTC day ${current_date}"
            return 0
        fi
        local missing_flac_file_count=$((  ${MINUTES_PER_DAY} -  ${#flac_file_list[@]} ))
        wd_logger 2 "${missing_flac_file_count} flac files are missing in ${flac_file_dir}, so add silence files to fill the directory"
        grape_repair_band_flacs ${flac_file_dir}
        rc=$?
        if [[ ${rc} -eq 0 ]]; then
            wd_logger 1 "ERROR: grape_repair_band_flacs ${flac_file_dir} =>  ${rc}, but  no repairs were done"
            return ${GRAPE_ERROR_RETURN_REPAIR_FAILED}
        else 
            wd_logger 1 "grape_repair_band_flacs ${flac_file_dir} reported it repaired by adding ${rc} (or more) silence files"
        fi
        wd_logger 2 "Fixed ${missing_flac_file_count} missing flac files"
        flac_file_list=( $(find ${flac_file_dir} -type f -name '*.flac' -printf '%p\n' | sort ) )
    fi
    wd_logger 1 "Creating one 24 hour, 10 hz wav file ${output_10sps_wav_file} from ${#flac_file_list[@]} flac files..."
    rm -f ${GRAPE_TMP_DIR}/*

    local rc
    nice -n 19 flac -s --output-prefix=${GRAPE_TMP_DIR}/ -d ${flac_file_list[@]}
     rc=$?
    rc=0
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'flac ...' => ${rc} "
        rm -f  ${GRAPE_TMP_DIR}/*
        return ${GRAPE_ERROR_FLAC_FAILED}
    fi

    local wav_files_list=( ${flac_file_list[@]##*/} )            ### Chops off the paths
    wav_files_list=( ${wav_files_list[@]/#/${GRAPE_TMP_DIR}/} )  ### Prepends the path to the temp directory
    wav_files_list=( ${wav_files_list[@]/.flac/.wav} )           ### replaces the filename extension .flac with .wav

    local sox_log_file_name="${flac_file_dir}/sox.log"
    ulimit -n 2048    ### sox will open 1440+ files, so up the open file limit
    nice -n 19 sox ${wav_files_list[@]} ${output_10sps_wav_file} rate 10 >& ${sox_log_file_name}
    rc=$?
    rm  ${wav_files_list[@]}
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'sox ...' => ${rc} "
         return ${GRAPE_ERROR_SOX_FAILED}
    fi
    wd_logger 1 "Created ${output_10sps_wav_file}.  sox reported:\n$(< ${sox_log_file_name})"
    return 1
}

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
    local band_dir_list=( $(find ${date_root_dir} -mindepth 3 -type d -printf '%p\n' | sort) )
    wd_logger 2 "found ${#band_dir_list[@]} bands"
    for band_dir in ${band_dir_list[@]} ; do
        # read -p "Create 24 hour wav file in ${band_dir}? => "
        wd_logger 2 "create 24 hour wav file in ${band_dir}"
        local rc
        grape_create_wav_file ${band_dir}
        rc=$?
        if grape_return_code_is_error ${rc} ; then
             wd_logger 1 "ERROR: 'grape_create_wav_file ${band_dir}' => ${rc}"
        elif [[ ${rc} -eq 0 ]]; then
            wd_logger 2 "Found existing 24h.wav file for band ${band_dir}"
        else
            wd_logger 1 "Created a new 24h.wav file for band ${band_dir}"
            (( ++ new_wav_count ))
        fi
        #read -p "Next Band? => "
    done
    
    if [[ ${return_code} -lt 0 ]]; then
         wd_logger 1 "Returning error ${return_code} after one or more errors.  Also created ${new_wav_count} new wav files"
         return ${return_code}
    fi
    if [[ ${new_wav_count} -gt 0 ]]; then
        wd_logger 1 "Returning ${new_wav_count} new wav files"
    fi
     return ${new_wav_count}  
}

### '-c' Searches all the date/... direectories (execpt for today), repairs if necessary by adding silence files, then creates a 24 hour 10 hz wav file.
###  Returns:  number of newly created wav files, or -1 if there was a failure
function grape_create_all_24_hour_wavs(){
    local current_date
    TZ=UTC printf -v current_date "%(%Y%m%d)T"

    local return_code=0
    local new_wav_count=0

    local wav_archive_dates_dir_list=( $(find ${GRAPE_WAV_ARCHIVE_ROOT_PATH} -mindepth 1 -maxdepth 1 -type d -printf '%p\n' | sort)  )
    local wav_archive_date
    for wav_archive_date in ${wav_archive_dates_dir_list[@]##*/} ; do
        #read -p " grape_create_all_24_hour_wavs(): check ${wav_archive_date}? => "
        local rc
        if [[ ${wav_archive_date} ==  ${current_date} ]] ; then
            wd_logger 1 "Skipping grape_create_24_hour_wavs for current UTC day ${current_date}"
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
     wd_logger 1 "Returning ${new_wav_count} new wav files"
     return ${new_wav_count}
}

### '-U'  Runs rsync to upload all the 24_hour_10sps_iq.wav wav files to the grape user account at wsprdaemon.org
function grape_upload_all_10hz_wavs() {
    local rc
    rsync --quiet --archive --partial --exclude=*.flac --include=24_hour_10sps_iq.wav ${GRAPE_WAV_ARCHIVE_ROOT_PATH}  grape@grape.wsprdaemon.org::grape/ 
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "'rsync --quiet --archive --partial --exclude=*.flac --include=24_hour_10sps_iq.wav ${GRAPE_WAV_ARCHIVE_ROOT_PATH}  grape@grape.wsprdaemon.org::grape' => ${rc}"
    else
        wd_logger 1 "All local wav and status files have been uploaded to grape.wspdaemon.org"
    fi
    return ${rc}
}    

### '-a' This function is called every odd 2 minutes by the watchdog daemon.
function grape_uploader() {
    if [[ ${GRAPE_UPLOADS_ENABLED-no} !=  "yes" ]]; then
         wd_logger 1 "GRAPE uploades are not enabled, so do nothing"
         return 0
    fi
    wd_logger 1 "Checking for new 24h.wav files to upload"
    local rc

    grape_create_all_24_hour_wavs
    rc=$?
    if [[ ${rc} -lt 0 ]]; then
        wd_logger 1 "ERROR: grape_create_all_24_hour_wavs => ${rc}"
    elif  [[ ${rc} -lt 0 ]]; then
        wd_logger 1 "There are no new 24h.wav files which need to be uploaded"
    else
        wd_logger 1 "Found ${rc} new 24h.wav files which need to be uploaded"
        grape_upload_all_10hz_wavs
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
             wd_logger 1 "ERROR: grape_upload_all_10hz_wavs => ${rc}"
         else
             wd_logger 1 "Successful upload of  ${rc} new 24h.wav files"
        fi
    fi
    return ${rc}
}

### Calculate the semitones needed by sox to change freqeuncies in a file:  "soc in.wav out.wav pitch PITCH_CHANGE_IN_CENTS"
### Where PITCH_CHANGE_IN_CENTS can be computed by:  'bc -l <<< "l(NEW_FREQ/OLD_FREQ) / l(2) * 12 *100 "'
### But I don't know if soc can change the pitch of 800 to 10 hz.

function grape_print_usage() {
    wd_logger 1 "GRAPE sub-menu commands:
    -C YYYYMMDD      Create 24 hour 10 Hz wav files for all bands 
    -S YYYYMMDD      Show the status of the files in that tree
    -R YYYYMMDD      Repair the directory tree by filling in missing minutes with silent_iq.flac
    -a               Search for 24h.wav files.  If a new 24h.wav is created, then upload it to wsprdaemon.org.  Called by the watchdog_daemon()
    -c               Create 10 sps wav files for each band from flac.tar files for all dates
    -p               Purge all empty date trees
    -r               Repair all date trees
    -t               Show status of all the date trees
    -U               Upload all of the local 24_hour_10sps_iq.wav files to the grape@wsprdaemon.org account
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
            grape_repair_date_flacs ${2-h}
            ;;
        -p)
            grape_purge_all_empty_date_trees
            ;;
        -t)
            grape_show_all_dates_status
            ;; 
        -r) 
            grape_repair_all_dates_flacs
            ;;
        -U)
            grape_upload_all_10hz_wavs
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
}

grape_init
