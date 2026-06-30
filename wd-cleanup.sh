#!/bin/bash

### wd-cleanup.sh - periodic housekeeping for the wsprdaemon file trees.
###
### Two trees are cleaned:
###   1) The temp tree  ${SHM_TREE} (tmpfs / RAM disk):
###        - *.log files larger than ${LOG_MAX_SIZE} are rotated by logrotate using
###          'copytruncate'.  This is REQUIRED because most of these logs are the
###          redirected stdout of long-running daemons which hold the file open: a
###          plain 'tail >tmp; mv tmp log' would swap the inode and the daemon would
###          keep writing to the now-unlinked file.  copytruncate copies the content
###          then truncates the original in place, preserving the inode/fd.
###        - *.wav files older than ${WAV_AGE_MINUTES} minutes are deleted (closed files).
###   2) The archive tree ${ARCHIVE_TREE}:
###        - *.wav/*.wv/*.flac files older than ${ARCHIVE_AGE_DAYS} days are deleted, EXCEPT a
###          10 Hz wav (${TEN_HZ_WAV_NAME}) is preserved until its <DATE>/<REPORTER>_<GRID>
###          directory holds the PSWS '${PSWS_UPLOAD_MARKER}' marker, so wavs queued for a
###          PSWS upload survive long Internet outages until they are successfully uploaded.
###        - directories left empty (including trees of only empty subdirs) are pruned.
###
### By default this runs in DRY-RUN mode: it only reports what WOULD change and how
### much space would be freed.  Pass -r to actually apply the changes.

declare WD_ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

declare SHM_TREE="${WD_CLEANUP_SHM_TREE:-/dev/shm/wsprdaemon}"
declare ARCHIVE_TREE="${WD_CLEANUP_ARCHIVE_TREE:-${WD_ROOT_DIR}/wav-archive}"

declare LOG_MAX_SIZE="${WD_CLEANUP_LOG_MAX_SIZE:-1M}"            ### logrotate 'size' threshold for *.log files
declare -i LOG_ROTATE_KEEP=${WD_CLEANUP_LOG_ROTATE_KEEP:-1}     ### number of old (compressed) copies logrotate keeps in the tree
declare -i WAV_AGE_MINUTES=${WD_CLEANUP_WAV_AGE_MINUTES:-60}    ### delete *.wav in the temp tree older than this
declare -i ARCHIVE_AGE_DAYS=${WD_CLEANUP_ARCHIVE_AGE_DAYS:-7}   ### delete archive files older than this

### Only these audio file types are purged from the archive tree (leaves logs/markers/metadata alone).
declare TEN_HZ_WAV_NAME="24_hour_10sps_iq.wav"                  ### the 24-hour, 10 sample/sec IQ wav uploaded to the PSWS network
declare PSWS_UPLOAD_MARKER="pswsnetwork_upload_completed"       ### present in a <DATE>/<REPORTER>_<GRID> dir once its 10 Hz wavs have been accepted by PSWS

declare LOGROTATE_STATE_FILE="${WD_CLEANUP_LOGROTATE_STATE:-${WD_ROOT_DIR}/.wd-logrotate.state}"
declare GET_FILE_SIZE_CMD="stat --format=%s"

declare dry_run="yes"

function usage() {
    cat <<EOF
Usage: $(basename "$0") [-r] [-h]

  (default)  DRY RUN: report what would change and how much space would be freed.
  -r         REAL RUN: rotate logs (copytruncate) and delete old files/empty dirs.
  -h         Show this help.

Trees cleaned:
  temp:    ${SHM_TREE}
  archive: ${ARCHIVE_TREE}
EOF
}

### Print a byte count in human-readable form, falling back to raw bytes if numfmt is missing.
function hr() {
    local bytes=$1
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec --suffix=B "${bytes}"
    else
        echo "${bytes} bytes"
    fi
}

### Emit a logrotate config for the temp-tree *.log files to stdout.
### logrotate's glob is non-recursive, so list each depth explicitly (logs nest 0-4 levels deep).
function emit_logrotate_config() {
    local tree_user tree_group
    tree_user=$( stat -c '%U' "${SHM_TREE}" )
    tree_group=$( stat -c '%G' "${SHM_TREE}" )
    cat <<EOF
${SHM_TREE}/*.log
${SHM_TREE}/*/*.log
${SHM_TREE}/*/*/*.log
${SHM_TREE}/*/*/*/*.log
${SHM_TREE}/*/*/*/*/*.log
{
    su ${tree_user} ${tree_group}
    size ${LOG_MAX_SIZE}
    rotate ${LOG_ROTATE_KEEP}
    missingok
    notifempty
    copytruncate
    compress
    nodateext
}
EOF
}

#######################################################################
### 1) Temp tree: rotate oversized *.log files via logrotate (copytruncate)
function clean_temp_logs() {
    [[ ! -d ${SHM_TREE} ]] && { echo "  (temp tree '${SHM_TREE}' not found, skipping logs)"; return; }

    ### Report how many logs currently exceed the threshold and by how much.
    local -i max_bytes
    max_bytes=$( numfmt --from=iec "${LOG_MAX_SIZE/M/MB}" 2>/dev/null || echo 1000000 )
    local -i count=0 over_bytes=0
    local log_file file_size
    while IFS= read -r -d '' log_file; do
        file_size=$( ${GET_FILE_SIZE_CMD} "${log_file}" )
        (( file_size <= max_bytes )) && continue
        (( count++ ))
        (( over_bytes += file_size - max_bytes ))
    done < <(find "${SHM_TREE}" -type f -name '*.log' -print0)

    local config_file
    config_file=$( mktemp /tmp/wd-cleanup-logrotate.XXXXXX )
    emit_logrotate_config > "${config_file}"

    if [[ ${dry_run} == "no" ]]; then
        if ! logrotate -s "${LOGROTATE_STATE_FILE}" "${config_file}"; then
            echo "  ERROR: logrotate returned non-zero"
        fi
    fi
    rm -f "${config_file}"

    echo "  *.log over ${LOG_MAX_SIZE}: ${count} file(s) (~$(hr ${over_bytes}) over threshold) rotated in place via logrotate copytruncate"
}

#######################################################################
### 2) Temp tree: delete old *.wav files
function clean_temp_wavs() {
    [[ ! -d ${SHM_TREE} ]] && { echo "  (temp tree '${SHM_TREE}' not found, skipping wavs)"; return; }

    local -i count=0 bytes=0 file_size
    local wav_file
    while IFS= read -r -d '' wav_file; do
        (( count++ ))
        file_size=$( ${GET_FILE_SIZE_CMD} "${wav_file}" )
        (( bytes += file_size ))
        [[ ${dry_run} == "no" ]] && rm -f "${wav_file}"
    done < <(find "${SHM_TREE}" -type f -name '*.wav' -mmin +${WAV_AGE_MINUTES} -print0)

    echo "  *.wav older than ${WAV_AGE_MINUTES} min: ${count} file(s), $(hr ${bytes})"
}

#######################################################################
### Return 0 if the <DATE>/<REPORTER>_<GRID> directory controlling this archive file
### contains the PSWS upload-completed marker (i.e. its 10 Hz wavs have been uploaded).
function reporter_dir_is_uploaded() {
    local file_path=$1
    local rel=${file_path#${ARCHIVE_TREE}/}      ### <DATE>/<REPORTER>_<GRID>/<RX>@.../<BAND>/<file>
    local date_dir=${rel%%/*}
    local rest=${rel#*/}
    local reporter_dir=${rest%%/*}
    [[ -f "${ARCHIVE_TREE}/${date_dir}/${reporter_dir}/${PSWS_UPLOAD_MARKER}" ]]
}

#######################################################################
### 3) Archive tree: delete *.wav/*.wv/*.flac older than ARCHIVE_AGE_DAYS, EXCEPT
###    a 10 Hz wav (${TEN_HZ_WAV_NAME}) is preserved until its <DATE>/<REPORTER>_<GRID>
###    directory holds the PSWS '${PSWS_UPLOAD_MARKER}' marker.  This protects wavs that
###    are still queued for upload when a site has lost its Internet connection for weeks.
function clean_archive_files() {
    [[ ! -d ${ARCHIVE_TREE} ]] && { echo "  (archive tree '${ARCHIVE_TREE}' not found, skipping)"; return; }

    local -i del_count=0 del_bytes=0 kept_count=0 kept_bytes=0 file_size
    local file
    while IFS= read -r -d '' file; do
        file_size=$( ${GET_FILE_SIZE_CMD} "${file}" )
        if [[ "${file##*/}" == "${TEN_HZ_WAV_NAME}" ]] && ! reporter_dir_is_uploaded "${file}"; then
            (( kept_count++ ))
            (( kept_bytes += file_size ))
            continue
        fi
        (( del_count++ ))
        (( del_bytes += file_size ))
        [[ ${dry_run} == "no" ]] && rm -f "${file}"
    done < <(find "${ARCHIVE_TREE}" -type f -mtime +${ARCHIVE_AGE_DAYS} \
                  \( -name '*.wav' -o -name '*.wv' -o -name '*.flac' \) -print0)

    echo "  .wav/.wv/.flac older than ${ARCHIVE_AGE_DAYS} days: ${del_count} file(s) to delete, $(hr ${del_bytes})"
    echo "  preserved (10 Hz wav awaiting PSWS upload): ${kept_count} file(s), $(hr ${kept_bytes})"
}

#######################################################################
### 3b) Archive tree: in already-uploaded reporter dirs, sweep the leftover sox.log
###     files and the PSWS marker so the emptied <DATE>/<REPORTER>_<GRID> dirs can be
###     pruned.  The marker is deleted LAST so 'reporter_dir_is_uploaded' stays valid for
###     the audio and sox.log passes during a real run.
function clean_archive_uploaded_cruft() {
    [[ ! -d ${ARCHIVE_TREE} ]] && return

    local -i log_count=0 marker_count=0 bytes=0 file_size
    local file

    ### sox.log files, but only inside reporter dirs that have already been uploaded
    while IFS= read -r -d '' file; do
        reporter_dir_is_uploaded "${file}" || continue
        (( log_count++ ))
        file_size=$( ${GET_FILE_SIZE_CMD} "${file}" )
        (( bytes += file_size ))
        [[ ${dry_run} == "no" ]] && rm -f "${file}"
    done < <(find "${ARCHIVE_TREE}" -type f -mtime +${ARCHIVE_AGE_DAYS} -name 'sox.log' -print0)

    ### PSWS upload markers (by definition only in uploaded dirs); delete last
    while IFS= read -r -d '' file; do
        (( marker_count++ ))
        file_size=$( ${GET_FILE_SIZE_CMD} "${file}" )
        (( bytes += file_size ))
        [[ ${dry_run} == "no" ]] && rm -f "${file}"
    done < <(find "${ARCHIVE_TREE}" -type f -mtime +${ARCHIVE_AGE_DAYS} -name "${PSWS_UPLOAD_MARKER}" -print0)

    echo "  uploaded-dir cruft: ${log_count} sox.log + ${marker_count} marker file(s) to delete, $(hr ${bytes})"
}

#######################################################################
### 4) Archive tree: prune now-empty directories (bottom-up)
function clean_archive_empty_dirs() {
    [[ ! -d ${ARCHIVE_TREE} ]] && return

    local -i count
    count=$( find "${ARCHIVE_TREE}" -mindepth 1 -type d -empty -print | wc -l )
    if [[ ${dry_run} == "no" ]]; then
        ### Loop because removing a dir may make its parent empty for the next pass.
        while [[ $( find "${ARCHIVE_TREE}" -mindepth 1 -type d -empty -print -quit ) ]]; do
            find "${ARCHIVE_TREE}" -mindepth 1 -type d -empty -delete
        done
    fi
    echo "  empty directories: ${count} (count may grow during a real run as files above are deleted first)"
}

#######################################################################
while getopts "rh" opt; do
    case ${opt} in
        r) dry_run="no" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

if [[ ${dry_run} == "yes" ]]; then
    echo "=== wd-cleanup DRY RUN ($(date)) - nothing will be changed; pass -r to apply ==="
else
    echo "=== wd-cleanup REAL RUN ($(date)) - applying changes ==="
fi

echo "Temp tree: ${SHM_TREE}"
clean_temp_logs
clean_temp_wavs
echo "Archive tree: ${ARCHIVE_TREE}"
clean_archive_files
clean_archive_uploaded_cruft
clean_archive_empty_dirs
echo "=== wd-cleanup done ($(date)) ==="
