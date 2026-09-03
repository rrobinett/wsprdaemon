##########################################################################################################################################################
########## Section which logs decode BACKLOG for FT8, FT4 and WSPR  #######################################################################################
##########################################################################################################################################################
###
### A decoder consumes wav files and deletes each one once decoded.  When a decoder cannot keep
### up -- e.g. the 1.4 GHz decoder frequency cap starving a weak CPU's single-threaded
### decode_ft8 (K6FOD, 2026-09-02: a 42 GB / 3600-file FT8 pile-up) -- files accumulate.  This
### samples each decode type and warns when it is falling behind.
###
### FT8 (15 s cycle) and FT4 (7.5 s) delete each wav immediately, so almost none are ever
###   "overdue" (older than WD_BACKLOG_FT_AGE_MIN).  Overdue count is thus a clean backlog gauge.
### WSPR is different: FST4W-1800 legitimately keeps 1-minute wavs for ~30 min (up to the
###   MAX_WAV_FILE_AGE_MIN=35 purge), so file AGE cannot tell accumulation from backlog.  Instead
###   we watch the TOTAL wav count for sustained GROWTH -- stable in steady state, unbounded when
###   decoding falls behind.
### A dash ("-") means that decode type is not present on this host.
###
### Sampled by watchdog_daemon() alongside log_radiod_drops; self-throttling, so cheap to call.

declare WD_BACKLOG_ENABLED=${WD_BACKLOG_ENABLED-yes}
declare WD_BACKLOG_LOG_DIR=${WD_BACKLOG_LOG_DIR-/var/log/wsprdaemon}
declare WD_BACKLOG_LOG_FILE=${WD_BACKLOG_LOG_FILE-${WD_BACKLOG_LOG_DIR}/decode-backlog.log}
declare WD_BACKLOG_STATE_FILE=${WD_BACKLOG_STATE_FILE-${WD_BACKLOG_LOG_DIR}/.decode-backlog.state}
declare WD_BACKLOG_LOG_MINUTES=${WD_BACKLOG_LOG_MINUTES-10}
declare WD_BACKLOG_FT_AGE_MIN=${WD_BACKLOG_FT_AGE_MIN-1}       ### FT wav older than this = overdue
declare WD_BACKLOG_FT_WARN=${WD_BACKLOG_FT_WARN-10}            ### warn when this many FT wavs are overdue
declare WD_BACKLOG_WSPR_FLOOR=${WD_BACKLOG_WSPR_FLOOR-200}     ### ignore WSPR totals below this (small sites)
declare WD_BACKLOG_WSPR_GROW_PCT=${WD_BACKLOG_WSPR_GROW_PCT-50} ### warn when WSPR total grows >= this % between samples
declare WD_BACKLOG_FT_ROOT=${KA9Q_FT_TMP_ROOT-/var/lib/ka9q-radio}

### Count *.wav files under $1.  $2 = min age filter ("" = all ages).  $3 = "deep" recurses.
### Echoes an integer, or "-" when the directory is absent (that decode type not run here).
function wd_backlog_count()
{
    local dir=$1 age=${2:-} depth="-maxdepth 1"
    [ "${3:-}" = "deep" ] && depth=""
    [ -d "$dir" ] || { echo "-"; return 0; }
    if [ -n "$age" ]; then
        find "$dir" ${depth} -name '*.wav' -mmin +${age} 2>/dev/null | wc -l
    else
        find "$dir" ${depth} -name '*.wav' 2>/dev/null | wc -l
    fi
}

### Sample the backlog, append one line to the log, warn if a decoder is falling behind.
### Self-throttling: does nothing until WD_BACKLOG_LOG_MINUTES have passed since the last write.
function log_decode_backlog()
{
    [[ "${WD_BACKLOG_ENABLED}" != "yes" ]] && return 0
    command -v find >/dev/null 2>&1 || return 0

    local now=${EPOCHSECONDS} last_epoch=0 p_ft8="-" p_ft4="-" p_wspr="-"
    [[ -f ${WD_BACKLOG_STATE_FILE} ]] && read -r last_epoch p_ft8 p_ft4 p_wspr < "${WD_BACKLOG_STATE_FILE}" 2>/dev/null
    (( now - ${last_epoch:-0} < WD_BACKLOG_LOG_MINUTES * 60 )) && return 0

    local ft8 ft4 wspr
    ft8=$(  wd_backlog_count "${WD_BACKLOG_FT_ROOT}/ft8" ${WD_BACKLOG_FT_AGE_MIN} )     ### overdue
    ft4=$(  wd_backlog_count "${WD_BACKLOG_FT_ROOT}/ft4" ${WD_BACKLOG_FT_AGE_MIN} )     ### overdue
    wspr=$( wd_backlog_count "${WSPRDAEMON_TMP_DIR:-/dev/shm/wsprdaemon}/recording.d" "" deep )  ### total

    local warn="" t c pnm p
    ### FT8 / FT4: overdue count -- warn if high, or growing above half the warn floor.
    for t in ft8 ft4; do
        c=${!t}; pnm="p_${t}"; p=${!pnm}
        [[ "$c" =~ ^[0-9]+$ ]] || continue
        if   (( c >= WD_BACKLOG_FT_WARN )); then warn+=" ${t^^} backlog=${c} overdue"
        elif [[ "$p" =~ ^[0-9]+$ ]] && (( c > p && c > WD_BACKLOG_FT_WARN / 2 )); then warn+=" ${t^^} backlog growing ${p}->${c}"
        fi
    done
    ### WSPR: total count -- warn only on sustained growth (tolerates FST4W steady-state).
    if [[ "$wspr" =~ ^[0-9]+$ && "$p_wspr" =~ ^[0-9]+$ ]] \
        && (( wspr >= WD_BACKLOG_WSPR_FLOOR )) && (( wspr * 100 >= p_wspr * (100 + WD_BACKLOG_WSPR_GROW_PCT) )); then
        warn+=" WSPR total growing ${p_wspr}->${wspr}"
    fi

    mkdir -p "${WD_BACKLOG_LOG_DIR}" 2>/dev/null || sudo mkdir -p "${WD_BACKLOG_LOG_DIR}" 2>/dev/null
    printf '%s\tft8_overdue=%s\tft4_overdue=%s\twspr_total=%s%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ft8" "$ft4" "$wspr" \
        "${warn:+	WARNING:${warn}}" >> "${WD_BACKLOG_LOG_FILE}" 2>/dev/null
    printf '%s %s %s %s\n' "$now" "$ft8" "$ft4" "$wspr" > "${WD_BACKLOG_STATE_FILE}" 2>/dev/null

    [[ -n "$warn" ]] && wd_logger 1 "WARNING: decode backlog:${warn} -- a decoder is falling behind (CPU cap too low / too few cores?).  See ${WD_BACKLOG_LOG_FILE}"

    if [[ -f ${WD_BACKLOG_LOG_FILE} ]] && (( $(stat -c %s "${WD_BACKLOG_LOG_FILE}" 2>/dev/null || echo 0) > 200000 )); then
        tail -n 500 "${WD_BACKLOG_LOG_FILE}" > "${WD_BACKLOG_LOG_FILE}.tmp" 2>/dev/null && mv "${WD_BACKLOG_LOG_FILE}.tmp" "${WD_BACKLOG_LOG_FILE}" 2>/dev/null
    fi
    return 0
}
