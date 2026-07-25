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
###        - Purge is governed by how FULL the volume is, NOT by age.  The raw *.wv files are a
###          research cache (remote users may later request them re-uploaded), so they are kept as
###          long as there is room.  Only once the volume reaches ${ARCHIVE_FILL_PERCENT}% full are the
###          OLDEST *delivered* reporter trees (those holding the PSWS '${PSWS_UPLOAD_MARKER}' marker)
###          purged, oldest-first, just enough to drop back under the threshold.
###        - Delivered trees are purged first.  As a LAST RESORT, if purging every delivered tree still
###          leaves the volume over threshold (a site that can never reach PSWS), the OLDEST UNDELIVERED
###          trees are purged too so recent recordings still have room - this loses un-uploaded data and
###          is logged as a WARNING to stdout + syslog.  The current UTC day is ALWAYS protected.
###        - A DEADLOCK ALERT (stdout + syslog) fires when even purging every non-current tree cannot
###          free one day's space (WD_ARCHIVE_MIN_FREE_GB, 0 => auto from the largest date tree).
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

### Archive purge is fill-driven; these two knobs (resolved below from env > wsprdaemon.conf > default)
### match the interactive 'wdgpu' (wd-grape-purge-uploaded) alias so one setting governs both.
declare PSWS_UPLOAD_MARKER="pswsnetwork_upload_completed"       ### present in a <DATE>/<REPORTER>_<GRID> dir once its 10 Hz wavs have been accepted by PSWS
declare WD_CONF_FILE="${WD_CLEANUP_CONF_FILE:-${WD_ROOT_DIR}/wsprdaemon.conf}"   ### per-site overrides for WD_ARCHIVE_FILL_PERCENT / WD_ARCHIVE_MIN_FREE_GB

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

### Echo the value assigned to a variable in wsprdaemon.conf (tolerates an optional 'declare ',
### quotes and a trailing comment), or nothing if the file or var is absent.  Avoids sourcing the
### whole conf (which has side effects) just to read a couple of knobs.
function conf_value() {
    local var=$1 line val
    [[ -r ${WD_CONF_FILE} ]] || return 0
    line=$( grep -E "^[[:space:]]*(declare[[:space:]]+(-[a-zA-Z]+[[:space:]]+)?)?${var}=" "${WD_CONF_FILE}" | tail -1 )
    [[ -z ${line} ]] && return 0
    val=${line#*${var}=}
    val=${val%%#*}                 ### strip any trailing comment
    val=${val//[\"\' ]/}           ### strip quotes and spaces
    echo "${val}"
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
### Current used-percentage of the volume holding the archive tree.
function archive_fs_used_percent() {
    df -P "${ARCHIVE_TREE}" | awk 'NR==2{gsub(/%/,"",$5); print $5}'
}

#######################################################################
### 3) Archive tree: fill-driven purge.  Raw *.wv files are kept as a research cache until the
###    volume reaches ARCHIVE_FILL_PERCENT, then the OLDEST *delivered* (marker-present) reporter
###    trees are purged oldest-first, just enough to drop back under the threshold.  Undelivered
###    trees are never touched.  Emits a DEADLOCK ALERT if even purging every delivered tree cannot
###    free one day's space.
function clean_archive_by_fill_threshold() {
    [[ ! -d ${ARCHIVE_TREE} ]] && { echo "  (archive tree '${ARCHIVE_TREE}' not found, skipping)"; return; }

    ### Volume stats (df follows the archive path to its real mountpoint).
    local -a df_fields
    df_fields=( $(df -P -B1 "${ARCHIVE_TREE}" | awk 'NR==2{print $2, $3, $4, $5, $6}') )
    local -i fs_total=${df_fields[0]} fs_used=${df_fields[1]} fs_avail=${df_fields[2]}
    local -i fs_usep=${df_fields[3]%\%}
    local fs_mount=${df_fields[4]}

    ### One day's space requirement for the deadlock check.
    local -i one_day_bytes=0 db
    if (( ARCHIVE_MIN_FREE_GB > 0 )); then
        one_day_bytes=$(( ARCHIVE_MIN_FREE_GB * 1000000000 ))
    else
        local d
        for d in $(find "${ARCHIVE_TREE}" -mindepth 1 -maxdepth 1 -type d); do
            db=$( du -sb "${d}" 2>/dev/null | cut -f1 )
            (( db > one_day_bytes )) && one_day_bytes=${db}
        done
    fi

    ### Build the ordered purge list.  Prefer DELIVERED (marker-present) reporter trees, oldest-first,
    ### since they are already safe on the PSWS server.  As a LAST RESORT - a site that can never upload
    ### would otherwise fill up and stop recording - fall back to the oldest UNDELIVERED trees so recent
    ### recordings still have somewhere to land.  The current UTC day is always protected (recording now).
    local today
    today=$( date -u +%Y%m%d )
    local -a delivered_dirs=() undelivered_dirs=()
    mapfile -t delivered_dirs < <(find "${ARCHIVE_TREE}" -type f -name "${PSWS_UPLOAD_MARKER}" -printf '%h\n' | sort)
    local rdir
    while IFS= read -r rdir; do
        [[ -f "${rdir}/${PSWS_UPLOAD_MARKER}" ]] && continue            ### delivered: already in delivered_dirs
        [[ "${rdir#${ARCHIVE_TREE}/}" == "${today}/"* ]] && continue    ### never purge today's in-progress recording
        undelivered_dirs+=( "${rdir}" )
    done < <(find "${ARCHIVE_TREE}" -mindepth 2 -maxdepth 2 -type d | sort)

    local -i delivered_bytes=0 undelivered_bytes=0
    for rdir in "${delivered_dirs[@]}";   do db=$( du -sb "${rdir}" 2>/dev/null | cut -f1 ); (( delivered_bytes += db )); done
    for rdir in "${undelivered_dirs[@]}"; do db=$( du -sb "${rdir}" 2>/dev/null | cut -f1 ); (( undelivered_bytes += db )); done
    local -i reclaimable_bytes=$(( delivered_bytes + undelivered_bytes ))

    echo "  volume ${fs_mount}: used $(hr ${fs_used}) of $(hr ${fs_total}) (${fs_usep}%), free $(hr ${fs_avail}), fill-threshold ${ARCHIVE_FILL_PERCENT}%"
    echo "  purgeable: ${#delivered_dirs[@]} delivered ($(hr ${delivered_bytes})) + ${#undelivered_dirs[@]} undelivered ($(hr ${undelivered_bytes})); one-day need ~$(hr ${one_day_bytes})"

    ### DEADLOCK ALERT to stdout AND syslog (cron drops stdout).  Now that undelivered trees are purgeable,
    ### this means even emptying everything but today still can't fit a day => the volume is physically too small.
    local -i avail_after_all=$(( fs_avail + reclaimable_bytes ))
    if (( avail_after_all < one_day_bytes )); then
        local alert="DEADLOCK: ${fs_mount} would have only $(hr ${avail_after_all}) free after purging every non-current tree, less than one day (~$(hr ${one_day_bytes})); add disk / reduce bands"
        echo "  *** ${alert} ***"
        command -v logger >/dev/null 2>&1 && logger -t wd-cleanup "${alert}"
    fi

    if (( fs_usep < ARCHIVE_FILL_PERCENT )); then
        echo "  ${fs_usep}% < ${ARCHIVE_FILL_PERCENT}% threshold: keeping all raw wav cache, nothing purged"
        return
    fi

    local -a purge_order=( "${delivered_dirs[@]}" "${undelivered_dirs[@]}" )
    local -i delivered_count=${#delivered_dirs[@]}
    if (( ${#purge_order[@]} == 0 )); then
        echo "  ${fs_usep}% >= ${ARCHIVE_FILL_PERCENT}% threshold but nothing purgeable (only today's recording present)"
        return
    fi

    local -i freed=0 purged=0 undelivered_purged=0 used_now=${fs_used} cur_usep i=0
    local tag
    for rdir in "${purge_order[@]}"; do
        tag="DELIVERED"; (( i >= delivered_count )) && tag="UNDELIVERED"
        db=$( du -sb "${rdir}" 2>/dev/null | cut -f1 )
        echo "  purge [${tag}] $(hr ${db})  ${rdir#${ARCHIVE_TREE}/}"
        [[ ${dry_run} == "no" ]] && rm -rf "${rdir}"
        (( used_now -= db )); (( freed += db )); (( purged++ )); (( i++ ))
        [[ ${tag} == "UNDELIVERED" ]] && (( undelivered_purged++ ))
        ### Re-measure after a real delete; project from the running total during a dry run.
        if [[ ${dry_run} == "no" ]]; then
            cur_usep=$( archive_fs_used_percent )
        else
            cur_usep=$(( fs_total > 0 ? used_now * 100 / fs_total : 0 ))
        fi
        (( cur_usep < ARCHIVE_FILL_PERCENT )) && break
    done

    local verb="would free"; [[ ${dry_run} == "no" ]] && verb="freed"
    echo "  ${verb} $(hr ${freed}) by purging ${purged} tree(s), of which ${undelivered_purged} were undelivered"
    if (( undelivered_purged > 0 )); then
        local warn="purged ${undelivered_purged} UNDELIVERED tree(s) to make room - this site is not keeping up with PSWS uploads (data lost)"
        echo "  *** WARNING: ${warn} ***"
        [[ ${dry_run} == "no" ]] && command -v logger >/dev/null 2>&1 && logger -t wd-cleanup "${warn}"
    fi
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
### Resolve the two archive knobs: environment var > wsprdaemon.conf > built-in default.
declare _cfg
_cfg="${WD_ARCHIVE_FILL_PERCENT:-$(conf_value WD_ARCHIVE_FILL_PERCENT)}"; declare -i ARCHIVE_FILL_PERCENT=${_cfg:-75}
_cfg="${WD_ARCHIVE_MIN_FREE_GB:-$(conf_value WD_ARCHIVE_MIN_FREE_GB)}";   declare -i ARCHIVE_MIN_FREE_GB=${_cfg:-0}

echo "Archive tree: ${ARCHIVE_TREE}"
clean_archive_by_fill_threshold
clean_archive_empty_dirs
echo "=== wd-cleanup done ($(date)) ==="
