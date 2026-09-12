##########################################################################################################################################################
########## Section which reports when a band's decodes fall permanently behind, and when a cycle is lost  ################################################
##########################################################################################################################################################
###
### A single decode taking longer than its 2 minute cycle is NOT a problem, and WD is built so that it
### isn't.  A decode job starts when the wav files it needs are all on disk -- get_wav_file_list() hands
### back the oldest WSPR packet that has not been decoded yet and returns immediately whenever the files
### are there.  Nothing waits for a wall clock boundary (sleep_until_raw_file_is_full() is dead code), so
### after a slow cycle the daemon runs the next decode back to back and the band catches up on its own at
### (120 / decode_seconds) - 1 cycles per cycle.  The :00 and :30 boundaries, where F5 + F15 + F30 all
### come due at once, are exactly the case this handles: two or three late cycles, then back to normal.
###
### What IS a problem is falling behind and staying there.  Then the wav files pile up in /dev/shm until
### they reach MAX_WAV_FILE_AGE_MIN and purge_stale_recordings() deletes them undecoded, which is where
### cycles are actually lost -- and until now that happened in silence.  So this file reports:
###
###   BEHIND    a band has been at least WD_DECODE_LATE_SECS (120 s, one cycle) behind for
###             WD_DECODE_SUSTAIN_CYCLES (5) decodes in a row AND has made no net progress over that
###             run.  That is a band which will not recover without more CPU or fewer bands.  Logged as
###             an ERROR once per episode, with a reminder every WD_DECODE_SUSTAIN_CYCLES after that.
###             A burst which is draining -- lateness falling cycle over cycle -- never trips this, no
###             matter how late it started, because the band is already fixing itself.
###   CAUGHT_UP the band came back under the threshold.  Says how long the episode lasted and how far
###             behind it got, so a transient leaves a record without ever raising an error.
###   KILLED    wsprd/jt9 was killed by its 'timeout' before it finished, so that cycle reported no
###             spots.  A definite lost cycle, always an ERROR.
###   DROPPED   purge_stale_recordings() deleted a wav file nothing had decoded.  Also a definite lost
###             cycle, always an ERROR.
###   LATE      one decode started a cycle or more after its audio was complete.  Recorded, never
###             alarmed on its own: this is the raw material the BEHIND rule is computed from.
###
### 'late' -- the seconds between the end of a packet's audio and the start of its decode -- is the
### backlog measured in seconds, per band.  It is the one number that separates a spike from a slide.
###
### Every event is appended to /var/log/wsprdaemon/decode-health.log, so the history survives a restart.
### 'wsprdaemon.sh -b' ('wdb') prints the summary.  The streak state lives in the decoding daemon's own
### shell variables: there is one decoding daemon process per receiver+band, so it needs no state file
### and a daemon restart correctly forgets the old streak.
###
### wsprdaemon.conf:
###   WD_DECODE_HEALTH_ENABLED="no"     stop recording these events (default "yes")
###   WD_DECODE_LATE_SECS=120           a decode starting at least this late counts toward a streak
###   WD_DECODE_SUSTAIN_CYCLES=5        consecutive late decodes, with no net progress, before BEHIND
###   WD_DECODE_HEALTH_MAX_BYTES        cap on the event log (default 1 MB, trimmed to the newest half)

declare WD_DECODE_HEALTH_ENABLED=${WD_DECODE_HEALTH_ENABLED-yes}
declare WD_DECODE_HEALTH_LOG_DIR=${WD_DECODE_HEALTH_LOG_DIR-/var/log/wsprdaemon}
declare WD_DECODE_HEALTH_LOG=${WD_DECODE_HEALTH_LOG-${WD_DECODE_HEALTH_LOG_DIR}/decode-health.log}
declare WD_DECODE_LATE_SECS=${WD_DECODE_LATE_SECS-120}            ### Starting a whole cycle late counts as late
declare WD_DECODE_SUSTAIN_CYCLES=${WD_DECODE_SUSTAIN_CYCLES-5}    ### ...but only a run of them with no progress is a fault
declare WD_DECODE_HEALTH_MAX_BYTES=${WD_DECODE_HEALTH_MAX_BYTES-1000000}
declare WD_DECODE_OK_HEARTBEAT_SECS=${WD_DECODE_OK_HEARTBEAT_SECS-3600}   ### Log one healthy decode per band per hour, so 'wdb' can show a good band as good
declare WD_DECODE_OK_SETTLE_SECS=${WD_DECODE_OK_SETTLE_SECS-300}          ### ...but not the first decodes after a restart, which are always catching up

declare WD_DECODE_HEALTH_LOG_CHECKED=""     ### Set once the log path has been resolved

### Per-band streak state.  These live in the decoding daemon process for one receiver+band.
declare WD_DECODE_LATE_STREAK=0             ### Consecutive decodes at or over WD_DECODE_LATE_SECS
declare WD_DECODE_STREAK_FIRST_LATE=0       ### How late we were when this streak started
declare WD_DECODE_STREAK_MAX_LATE=0         ### The worst lateness in this streak
declare WD_DECODE_STREAK_START_EPOCH=0
declare WD_DECODE_BEHIND_REPORTED="no"      ### Has this streak already been reported as BEHIND?
declare WD_DECODE_LAST_OK_EPOCH=0           ### When this band last wrote a healthy-decode heartbeat

### Resolve a writable path for the event log and leave it in WD_DECODE_HEALTH_LOG.  Runs its checks
### only once per process (never call it in a $( ) subshell, or the caching is lost and every decode
### re-runs the mkdir/sudo probe).  Every decoding daemon is its own process and they all append to
### this one file; each line is far below PIPE_BUF, so O_APPEND keeps them intact.
function wd_decode_health_log_file()
{
    [[ -n "${WD_DECODE_HEALTH_LOG_CHECKED}" ]] && return 0
    local log_dir=${WD_DECODE_HEALTH_LOG%/*}
    if [[ ! -d "${log_dir}" ]]; then
        mkdir -p "${log_dir}" 2>/dev/null || sudo mkdir -p "${log_dir}" 2>/dev/null
        sudo chown "$(id -un)" "${log_dir}" 2>/dev/null
    fi
    if [[ ! -w "${log_dir}" ]]; then
        ### WD does not run as root and /var/log/wsprdaemon could not be created
        WD_DECODE_HEALTH_LOG="${WSPRDAEMON_ROOT_DIR:-${HOME}/wsprdaemon}/decode-health.log"
    fi
    if [[ ! -f "${WD_DECODE_HEALTH_LOG}" ]]; then
        printf "# utc_time\tstatus\treceiver\tband\tmode\tcycle_utc\tlate=SECS_BEHIND\telapsed=DECODE_SECS\trc=DECODER_EXIT_CODE\tnote\n" \
            >> "${WD_DECODE_HEALTH_LOG}" 2>/dev/null
    fi
    WD_DECODE_HEALTH_LOG_CHECKED="${WD_DECODE_HEALTH_LOG}"
    return 0
}

### The wav filenames are UTC, so parse them as UTC rather than in the host's timezone.  (decoding.sh's
### epoch_from_filename() uses local time, which is fine where it only ever subtracts one from another.)
function wd_decode_health_epoch_from_filename()
{
    local file_name=${1##*/}
    TZ=UTC date -d "${file_name:0:8} ${file_name:9:2}:${file_name:11:2}:${file_name:13:2}" +%s 2>/dev/null
}

### Append one event line.  $1 status, $2 receiver, $3 band, $4 mode, $5 cycle epoch, $6 late, $7 elapsed, $8 rc, $9.. note
function wd_decode_health_write()
{
    local status=$1 receiver_name=$2 receiver_band=$3 mode=$4 cycle_epoch=$5 late_secs=$6 elapsed_secs=$7 decode_rc=$8
    shift 8
    wd_decode_health_log_file
    printf "%s\t%s\t%s\t%s\t%s\t%s\tlate=%s\telapsed=%s\trc=%s\t%s\n" \
        "$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' -1)" "${status}" "${receiver_name}" "${receiver_band}" "${mode}" \
        "$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' ${cycle_epoch})" "${late_secs}" "${elapsed_secs}" "${decode_rc}" "$*" \
        >> "${WD_DECODE_HEALTH_LOG}" 2>/dev/null

    local log_bytes=$( stat -c %s "${WD_DECODE_HEALTH_LOG}" 2>/dev/null || echo 0 )
    if (( log_bytes > WD_DECODE_HEALTH_MAX_BYTES )); then
        tail -n 5000 "${WD_DECODE_HEALTH_LOG}" > "${WD_DECODE_HEALTH_LOG}.tmp" 2>/dev/null && \
            mv "${WD_DECODE_HEALTH_LOG}.tmp" "${WD_DECODE_HEALTH_LOG}" 2>/dev/null
    fi
}

### Record one decode outcome and update this band's streak.
###   $1 receiver name     $2 band        $3 mode string, e.g. W_120 or F_1800
###   $4 epoch of the FIRST one minute wav file of this packet
###   $5 length of the packet in seconds
###   $6 epoch at which this decode started   $7 how many seconds it ran   $8 its exit code
function wd_decode_health_record()
{
    [[ "${WD_DECODE_HEALTH_ENABLED}" != "yes" ]] && return 0
    local receiver_name=$1 receiver_band=$2 mode=$3 cycle_epoch=$4 period_secs=$5 start_epoch=$6 elapsed_secs=$7 decode_rc=$8

    if ! [[ "${cycle_epoch}" =~ ^[0-9]+$ && "${start_epoch}" =~ ^[0-9]+$ && "${elapsed_secs}" =~ ^[0-9]+$ ]]; then
        return 0            ### A caller could not work out the times; never let health accounting break a decode
    fi
    ### The audio for this packet was complete 'period_secs' after the first minute file started
    local late_secs=$(( start_epoch - ( cycle_epoch + period_secs ) ))
    (( late_secs < 0 )) && late_secs=0
    local cycle_utc
    cycle_utc=$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' ${cycle_epoch})

    ### A decoder killed by its timeout lost that cycle outright, whatever the streak is doing
    if (( decode_rc == 124 )); then
        wd_decode_health_write "KILLED" "${receiver_name}" "${receiver_band}" "${mode}" "${cycle_epoch}" \
            "${late_secs}" "${elapsed_secs}" "${decode_rc}" "killed by its decode timeout"
        wd_logger 1 "ERROR: DECODE KILLED: the ${mode} decode of the ${receiver_band} cycle starting ${cycle_utc} was killed by its timeout after ${elapsed_secs} seconds, so that cycle reported no spots.  See 'wsprdaemon.sh -b'"
        return 0
    fi

    if (( late_secs < WD_DECODE_LATE_SECS )); then
        ### On time.  If we were in a late streak, this band has caught up by itself.
        if (( WD_DECODE_LATE_STREAK > 0 )); then
            local episode_mins=$(( ( EPOCHSECONDS - WD_DECODE_STREAK_START_EPOCH ) / 60 ))
            wd_decode_health_write "CAUGHT_UP" "${receiver_name}" "${receiver_band}" "${mode}" "${cycle_epoch}" \
                "${late_secs}" "${elapsed_secs}" "${decode_rc}" \
                "caught up after ${WD_DECODE_LATE_STREAK} late cycles over ${episode_mins} min, worst ${WD_DECODE_STREAK_MAX_LATE}s behind"
            if [[ "${WD_DECODE_BEHIND_REPORTED}" == "yes" ]]; then
                wd_logger 1 "${receiver_band} has CAUGHT UP: it was behind for ${WD_DECODE_LATE_STREAK} cycles over ${episode_mins} minutes, worst ${WD_DECODE_STREAK_MAX_LATE} seconds behind, and is now ${late_secs} seconds behind"
            else
                wd_logger 2 "${receiver_band} caught up after ${WD_DECODE_LATE_STREAK} late cycles, worst ${WD_DECODE_STREAK_MAX_LATE}s.  No error: a burst which drains is what the design expects"
            fi
            WD_DECODE_LATE_STREAK=0
            WD_DECODE_STREAK_MAX_LATE=0
            WD_DECODE_BEHIND_REPORTED="no"
        else
            ### Healthy.  Write one line an hour, not one every 2 minutes: at 14 bands that would be
            ### 10,000 lines a day and would push the episodes that matter out of the capped log.
            ### One heartbeat per band per hour is enough for 'wsprdaemon.sh -b' to show a good band
            ### as good, and to say when it was last heard from.
            if (( WD_DECODE_LAST_OK_EPOCH == 0 )); then
                ### First healthy decode since this daemon started.  Do NOT log it: a restart leaves
                ### a few minutes of recorded audio waiting, so the first decodes are catching up and
                ### report a lateness the band will not show again for an hour (KJ6MKI 2026-09-12:
                ### every band read "65 s behind" all hour from one restart-transient heartbeat).
                ### Hold the first heartbeat until the band has settled, so 'wdb' shows steady state.
                WD_DECODE_LAST_OK_EPOCH=$(( EPOCHSECONDS - WD_DECODE_OK_HEARTBEAT_SECS + WD_DECODE_OK_SETTLE_SECS ))
            elif (( EPOCHSECONDS - WD_DECODE_LAST_OK_EPOCH >= WD_DECODE_OK_HEARTBEAT_SECS )); then
                WD_DECODE_LAST_OK_EPOCH=${EPOCHSECONDS}
                wd_decode_health_write "OK" "${receiver_name}" "${receiver_band}" "${mode}" "${cycle_epoch}" \
                    "${late_secs}" "${elapsed_secs}" "${decode_rc}" "keeping up"
            fi
            wd_logger 2 "Decode health: ${mode} ${receiver_band} on time: late=${late_secs} elapsed=${elapsed_secs}"
        fi
        return 0
    fi

    ### This decode started at least one cycle late
    if (( WD_DECODE_LATE_STREAK == 0 )); then
        WD_DECODE_STREAK_FIRST_LATE=${late_secs}
        WD_DECODE_STREAK_START_EPOCH=${EPOCHSECONDS}
        WD_DECODE_STREAK_MAX_LATE=0
    fi
    (( ++WD_DECODE_LATE_STREAK ))
    (( late_secs > WD_DECODE_STREAK_MAX_LATE )) && WD_DECODE_STREAK_MAX_LATE=${late_secs}

    ### Is this band draining or sliding?  'late' falling below where the streak started means the
    ### decodes are outrunning the recordings and the band will get back on its own -- no error.
    local making_progress="no"
    (( late_secs < WD_DECODE_STREAK_FIRST_LATE )) && making_progress="yes"

    wd_decode_health_write "LATE" "${receiver_name}" "${receiver_band}" "${mode}" "${cycle_epoch}" \
        "${late_secs}" "${elapsed_secs}" "${decode_rc}" \
        "late cycle ${WD_DECODE_LATE_STREAK} of this run, started at ${WD_DECODE_STREAK_FIRST_LATE}s, draining=${making_progress}"

    if (( WD_DECODE_LATE_STREAK < WD_DECODE_SUSTAIN_CYCLES )) || [[ "${making_progress}" == "yes" ]]; then
        wd_logger 2 "Decode health: ${mode} ${receiver_band} is ${late_secs}s behind (late cycle ${WD_DECODE_LATE_STREAK}, draining=${making_progress}).  Not reporting: only a sustained run with no progress is a fault"
        return 0
    fi

    ### Sustained, and no net progress since the streak began: this band is not going to recover
    if [[ "${WD_DECODE_BEHIND_REPORTED}" == "no" ]] || (( WD_DECODE_LATE_STREAK % WD_DECODE_SUSTAIN_CYCLES == 0 )); then
        local minutes_to_purge=$(( ${MAX_WAV_FILE_AGE_MIN-35} - ( late_secs / 60 ) ))
        wd_decode_health_write "BEHIND" "${receiver_name}" "${receiver_band}" "${mode}" "${cycle_epoch}" \
            "${late_secs}" "${elapsed_secs}" "${decode_rc}" \
            "${WD_DECODE_LATE_STREAK} late cycles with no progress, ${WD_DECODE_STREAK_FIRST_LATE}s -> ${late_secs}s"
        wd_logger 1 "ERROR: ${receiver_band} DECODES ARE FALLING BEHIND: ${WD_DECODE_LATE_STREAK} cycles in a row have started late and the band has made no progress, going from ${WD_DECODE_STREAK_FIRST_LATE} to ${late_secs} seconds behind ($(( late_secs / 120 )) cycles).  It will not catch up on its own.  In about ${minutes_to_purge} more minutes its wav files will reach MAX_WAV_FILE_AGE_MIN=${MAX_WAV_FILE_AGE_MIN-35} and cycles will start to be lost.  See 'wsprdaemon.sh -b' and wd-cpu-tuning.md"
        WD_DECODE_BEHIND_REPORTED="yes"
    fi
    return 0
}

### Record a cycle whose wav file was deleted before anything decoded it.  $1 is the full path of the
### wav file purge_stale_recordings() is about to remove.
### Returns 0 when the cycle really was lost, 1 when the file had already been decoded.
function wd_decode_health_record_drop()
{
    [[ "${WD_DECODE_HEALTH_ENABLED}" != "yes" ]] && return 1
    local wav_file_path=$1
    local wav_file_name=${wav_file_path##*/}

    ### .../recording.d/RECEIVER/BAND/FILE.wav (Kiwi) or .../recording.d/RECEIVER/FILE.wav (KA9Q: one
    ### recorder writes every band of the stream into the receiver's directory, band is in the filename)
    local rest=${wav_file_path#*/recording.d/}
    local receiver_name=${rest%%/*}
    local receiver_band=${rest#*/}
    receiver_band=${receiver_band%%/*}
    if [[ "${receiver_band}" == "${wav_file_name}" ]]; then
        ### No band directory, so recover the band from the frequency in the filename: YYYYMMDDTHHMMSSZ_<freq_hz>_usb.wav
        local band_freq_hz=${wav_file_name#*_}
        receiver_band="$( get_wspr_band_name_from_freq_hz ${band_freq_hz%%_*} 2>/dev/null )"
        [[ -z "${receiver_band}" ]] && receiver_band="?"
    fi
    local cycle_epoch
    cycle_epoch=$( wd_decode_health_epoch_from_filename "${wav_file_name}" )
    [[ -z "${cycle_epoch}" ]] && return 1
    local age_secs=$(( EPOCHSECONDS - cycle_epoch ))

    ### Being purged does NOT by itself mean the cycle was lost.  A band running F15/F30 holds each long
    ### packet's one minute files until the NEXT long packet is assembled -- up to an hour -- so on those
    ### bands purge_stale_recordings() routinely deletes files whose 2 minute cycle was decoded half an
    ### hour earlier (KJ6MKI 2026-09-12: '2200' and '8' run W2:F2:F5:F15:F30, and every one of their
    ### purged files had been decoded at the time; this used to claim each one as a lost cycle).
    ### get_wav_file_list() touches '<first wav of the packet>.<seconds>-secs' every time it hands a
    ### packet to the decoder, so the newest of those markers says how far the decoder has got on this
    ### band.  A file older than that marker has already been through the decoder.
    local wav_dir=${wav_file_path%/*}
    local freq_field=${wav_file_name#*_}
    freq_field=${freq_field%%_*}
    local newest_marker_epoch=0 marker marker_epoch
    for marker in ${wav_dir}/*_${freq_field}_*.wav.*-secs ; do
        [[ -e "${marker}" ]] || continue            ### nullglob is not set here, so an unmatched glob comes back literally
        marker_epoch=$( wd_decode_health_epoch_from_filename "${marker##*/}" )
        if [[ -n "${marker_epoch}" ]] && (( marker_epoch > newest_marker_epoch )); then
            newest_marker_epoch=${marker_epoch}
        fi
    done
    if (( newest_marker_epoch > cycle_epoch )); then
        wd_logger 2 "Purged ${wav_file_name} after $(( age_secs / 60 )) minutes, but the decoder had already worked past it (its newest packet marker is $(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' ${newest_marker_epoch})), so no cycle was lost"
        return 1
    fi

    wd_decode_health_write "DROPPED" "${receiver_name}" "${receiver_band}" "-" "${cycle_epoch}" \
        "${age_secs}" "-1" "-" "purged at MAX_WAV_FILE_AGE_MIN=${MAX_WAV_FILE_AGE_MIN-35} min before it was decoded"
    wd_logger 1 "ERROR: CYCLE DROPPED: ${receiver_name} ${receiver_band} wav file '${wav_file_name}' recorded $(( age_secs / 60 )) minutes ago was deleted and the decoder never reached it, so that cycle is lost.  See 'wsprdaemon.sh -b'"
    return 0
}

### 'wsprdaemon.sh -b' / 'wdb'.  Everything the operator needs to answer "did I lose any cycles?"
function wd_decode_health_show()
{
    local log_file=${WD_DECODE_HEALTH_LOG}
    local fallback_log="${WSPRDAEMON_ROOT_DIR:-${HOME}/wsprdaemon}/decode-health.log"
    [[ ! -f "${log_file}" && -f "${fallback_log}" ]] && log_file="${fallback_log}"

    echo "WD decode health at $(TZ=UTC date '+%Y-%m-%d %H:%M:%S UTC')"
    echo "    A decode which takes longer than its cycle is fine: the next decode starts as soon as its wav files"
    echo "    are on disk, so a band catches up by itself.  These are the cases where that did not happen:"
    echo "    BEHIND  = at least ${WD_DECODE_SUSTAIN_CYCLES} cycles in a row started >= ${WD_DECODE_LATE_SECS} s late with no net progress: this band will not recover"
    echo "    KILLED  = wsprd/jt9 was killed by its timeout, so that cycle reported no spots"
    echo "    DROPPED = a recorded wav file was purged before anything decoded it: that cycle is lost"
    echo "    LATE    = one decode started a cycle or more late.  Normal after the :00/:30 F5+F15+F30 wave"
    echo "    CAUGHT_UP = a late run ended by itself, which is the design working"
    echo "    OK        = an hourly heartbeat from a band that is keeping up"
    echo ""
    if [[ ! -f "${log_file}" ]]; then
        echo "No decode events have been recorded yet (there is no ${WD_DECODE_HEALTH_LOG})."
        if [[ "${WD_DECODE_HEALTH_ENABLED}" != "yes" ]]; then
            echo "Recording is turned off: WD_DECODE_HEALTH_ENABLED='${WD_DECODE_HEALTH_ENABLED}' in wsprdaemon.conf."
        else
            echo "WD has not finished a decode since this version was installed.  The decoding daemons load"
            echo "decoding.sh when they start, so after a 'git pull' this stays empty until WD is restarted."
        fi
        return 0
    fi
    echo "Event log: ${log_file}"

    local now_epoch=${EPOCHSECONDS}
    local hour_ago day_ago
    hour_ago=$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' $(( now_epoch - 3600 )) )
    day_ago=$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' $(( now_epoch - 86400 )) )
    local events_file=${WSPRDAEMON_TMP_DIR:-/tmp}/decode-health-events.txt
    tail -n 50000 "${log_file}" | grep -v '^#' > ${events_file}

    ### ISO-8601 Zulu timestamps sort as strings, so these time windows are plain string compares
    echo ""
    awk -F'\t' -v hour_ago="${hour_ago}" -v day_ago="${day_ago}" '
        NF >= 8 {
            if ($1 >= day_ago)  day[$2]++
            if ($1 >= hour_ago) hour[$2]++
        }
        END {
            split("BEHIND KILLED DROPPED LATE CAUGHT_UP", order, " ")
            printf "  last hour "
            for (i = 1; i <= 5; i++) printf "   %s %d", order[i], hour[order[i]] + 0
            printf "\n  last 24 h "
            for (i = 1; i <= 5; i++) printf "   %s %d", order[i], day[order[i]] + 0
            printf "\n  (cycles actually lost = KILLED + DROPPED.  A healthy band logs one OK line an hour, not one per decode)\n"
        }' ${events_file}

    local lost_bands
    lost_bands=$( awk -F'\t' -v day_ago="${day_ago}" '
        NF >= 8 && $1 >= day_ago && ($2 == "BEHIND" || $2 == "KILLED" || $2 == "DROPPED") {
            late = $7 ; sub("late=", "", late) ; late += 0
            count[$4 "\t" $2]++ ; bad[$4] = 1
            if (late > worst[$4]) worst[$4] = late
        }
        END {
            for (b in bad)
                printf "    %-8s %8d %8d %8d   %d s (%d cycles)\n", b,
                    count[b "\tBEHIND"] + 0, count[b "\tKILLED"] + 0, count[b "\tDROPPED"] + 0, worst[b] + 0, int(worst[b] / 120)
        }' ${events_file} | sort )
    echo ""
    if [[ -z "${lost_bands}" ]]; then
        echo "  No band fell permanently behind or lost a cycle in the last 24 hours."
    else
        echo "  Bands which fell permanently behind, or lost a cycle, in the last 24 hours:"
        printf "    %-8s %8s %8s %8s   %s\n" "BAND" "BEHIND" "KILLED" "DROPPED" "WORST LATENESS"
        echo "${lost_bands}"
    fi

    echo ""
    echo "  Where each band stood when it last wrote to this log (a healthy band writes once an hour, so"
    echo "  a reading here can be up to an hour old -- the timestamp says how old):"
    awk -F'\t' -v late_warn="${WD_DECODE_LATE_SECS}" '
        NF >= 8 && $2 != "DROPPED" {
            late = $7 ; sub("late=", "", late) ; late += 0
            el = $8 ; sub("elapsed=", "", el) ; el += 0
            key = $3 "\t" $4
            if (el > slowest[key]) slowest[key] = el
            if ($1 > last_utc[key]) { last_utc[key] = $1 ; last_late[key] = late ; last_state[key] = $2 }
        }
        END {
            for (k in last_utc) {
                split(k, f, "\t")
                printf "    %-14s %-6s %6d s behind   slowest decode %4d s   last %s at %s%s\n",
                    f[1], f[2], last_late[k], slowest[k], last_state[k], last_utc[k],
                    (last_state[k] == "BEHIND") ? "   <== NOT RECOVERING" : ""
            }
        }' ${events_file} | sort

    echo ""
    local problem_events
    problem_events=$( grep -E "	(BEHIND|KILLED|DROPPED|CAUGHT_UP)	" ${events_file} | tail -n 12 )
    if [[ -z "${problem_events}" ]]; then
        echo "  Every decode has kept up: no band has been behind for ${WD_DECODE_SUSTAIN_CYCLES} cycles and no cycle has been lost"
        echo "  in the $(wc -l < ${events_file}) events recorded."
    else
        echo "  Last 12 episode events:"
        sed 's/^/    /' <<< "${problem_events}"
    fi
    rm -f ${events_file}

    local backlog_log=${WD_BACKLOG_LOG_FILE-/var/log/wsprdaemon/decode-backlog.log}
    if [[ -f "${backlog_log}" ]]; then
        echo ""
        echo "  Last lines of ${backlog_log} (how many recorded wav files are still waiting to be decoded):"
        tail -n 5 "${backlog_log}" | sed 's/^/    /'
    fi
    echo ""
    echo "  A BEHIND band needs more CPU, fewer bands or a higher decoder clock (see wd-cpu-tuning.md)."
    echo "  LATE runs which end in CAUGHT_UP cost nothing: that is the decoder draining a burst, as designed."
    return 0
}
