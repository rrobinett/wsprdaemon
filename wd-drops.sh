##########################################################################################################################################################
########## Section which logs radiod FFT block-drop counts  ##############################################################################################
##########################################################################################################################################################
###
### radiod reports a per-channel output-filter block-drop counter.  It is the number
### that matters when diagnosing a receiver that is losing audio: NOT the FFT %CPU.
### It increments when radiod cannot keep up with the RX888 input stream, which in
### practice means CPU or memory-bandwidth contention with the WSPR decoders.
### See wd-cpu-tuning.md for the CPU/cache isolation that drives it to zero.
###
### Sampled by watchdog_daemon() on its odd-minute pass, so there is no extra systemd
### service to run.  One sample costs about 1 second per radio.
###
### The counter read here is chan->filter.out.block_drops for one channel, i.e.
### exactly what `control` displays as "Drops" (control.c) and what `metadump` prints
### as "block drops" (dump.c).  Poll the SAME ssrc every time or the numbers are not
### comparable between samples.
###
### WHICH ssrc: by default one that radiod actually has.  The old fixed default of 14080
### (the 14.080 MHz FT4 channel) only exists at sites that decode FT4 there, and polling
### radiod for an ssrc it does NOT have is worse than a failed read: radiod creates a new
### dynamic channel (RF 0 Hz, on the [global] data stream) for every unknown ssrc it is
### polled about, so a WSPR-only site grew a junk channel every WD_DROPS_LOG_MINUTES.
### So unless WD_DROPS_SSRC is set in wsprdaemon.conf, listen passively on the first
### static channel group of each radiod (e.g. wspr-pcm.local), take the lowest ssrc heard,
### and remember it in ${WD_DROPS_LOG_DIR} so every later sample polls that same channel.
### The ssrc is logged in a 4th column so the samples can be told apart.
###
### NOTE metadump waits passively unless given -s <ssrc>, and -c 1 returns only the
### poll packet -- the STAT reply needs a couple of records.  Hence '-s N -c 3'.

declare WD_DROPS_ENABLED=${WD_DROPS_ENABLED-yes}
declare WD_DROPS_LOG_DIR=${WD_DROPS_LOG_DIR-/var/log/wsprdaemon}
declare WD_DROPS_LOG_FILE=${WD_DROPS_LOG_FILE-${WD_DROPS_LOG_DIR}/drops.log}
declare WD_DROPS_LOG_MINUTES=${WD_DROPS_LOG_MINUTES-10}
declare WD_DROPS_SSRC=${WD_DROPS_SSRC-}                 ### Empty => discover one from radiod's own channel list (see above)
declare WD_DROPS_TIMEOUT=${WD_DROPS_TIMEOUT-10}
declare WD_DROPS_DISCOVER_COUNT=${WD_DROPS_DISCOVER_COUNT-40}   ### status packets to listen for when discovering an ssrc

### Print the radiod status streams configured on this host, one per line ("hf.local").
### radiod configs come in TWO layouts: a single radiod@NAME.conf file, or a
### radiod@NAME.conf.d/ directory of fragments (ka9q's newer style, used by the udev
### autostart).  Searching only the file form found NO streams on a conf.d host, so
### the drops log sat header-only forever and looked like "no drops" instead of
### "not sampling".  Search both.
function wd_drops_status_streams()
{
    local conf name
    {
        ### radiod@NAME.conf: only when radiod@NAME is running.  A leftover conf for a radio that is not
        ### there (the rx888 conf on the Airspy-only N8GA-TC-2) otherwise logs 'ERR' on every sample.
        for conf in /etc/radio/radiod@*.conf ; do
            [[ -f ${conf} ]] || continue
            name=${conf##*/radiod@}; name=${name%.conf}
            systemctl is-active --quiet "radiod@${name}.service" 2>/dev/null || continue
            grep -sh -oE '^[[:space:]]*status[[:space:]]*=[[:space:]]*[^[:space:]#]+' "${conf}"
        done
        ### conf.d layout (udev autostart runs it as ka9q-radio@<serial>, which the conf name cannot predict)
        grep -sh -oE '^[[:space:]]*status[[:space:]]*=[[:space:]]*[^[:space:]#]+' /etc/radio/radiod@*.conf.d/*.conf
    } | sed -E 's/.*=[[:space:]]*//' | sort -u
}

### Print the multicast group of the first STATIC channel section of the radiod(s) whose
### status stream is $1, e.g. "wspr-pcm.local".  [global]'s own 'data =' is skipped: that
### group carries only dynamic channels, so nothing static ever announces itself there.
function wd_drops_data_stream_for()
{
    local stream=$1
    grep -slE "^[[:space:]]*status[[:space:]]*=[[:space:]]*${stream}([[:space:]#]|$)" \
            /etc/radio/radiod@*.conf /etc/radio/radiod@*.conf.d/*.conf 2>/dev/null \
        | while read -r conf ; do
            ### a conf.d fragment's siblings hold the channel sections, so read the whole directory
            [[ ${conf} == */*.conf.d/* ]] && conf="${conf%/*}/*.conf"
            cat ${conf}
          done \
        | gawk 'match($0, /^[[:space:]]*\[([^]]+)\]/, s)                     { sec = tolower(s[1]); next }
                sec != "" && sec != "global" && match($0, /^[[:space:]]*data[[:space:]]*=[[:space:]]*([^[:space:]#]+)/, d) { print d[1]; exit }'
}

### Print the ssrc to poll on status stream $1: WD_DROPS_SSRC if the site set one, else the
### one discovered earlier and cached in ${WD_DROPS_LOG_DIR}, else discover it now by listening
### to the static channels' own status announcements.  Prints nothing if none can be found.
function wd_drops_pick_ssrc()
{
    local stream=$1
    if [[ -n "${WD_DROPS_SSRC}" ]]; then
        echo "${WD_DROPS_SSRC}"
        return 0
    fi
    local cache_file="${WD_DROPS_LOG_DIR}/drops.ssrc.${stream}"
    if [[ -s "${cache_file}" ]]; then
        cat "${cache_file}"
        return 0
    fi
    local data_stream
    data_stream=$(wd_drops_data_stream_for "${stream}")
    if [[ -z "${data_stream}" ]]; then
        wd_logger 1 "ERROR: found no static channel section in the radiod conf(s) with 'status = ${stream}', so can't pick an ssrc to sample"
        return 1
    fi
    local ssrc
    ssrc=$( timeout ${WD_DROPS_TIMEOUT} metadump -c ${WD_DROPS_DISCOVER_COUNT} "${data_stream}" 2>/dev/null \
            | grep -oE '\[18\] SSRC [0-9,]+' | grep -oE '[0-9,]+$' | tr -d , | sort -n | head -1 )
    if [[ -z "${ssrc}" ]]; then
        wd_logger 1 "ERROR: heard no channel status on ${data_stream} in ${WD_DROPS_TIMEOUT} seconds, so can't pick an ssrc to sample on ${stream}"
        return 1
    fi
    wd_logger 1 "Sampling radiod block drops on ${stream} using ssrc ${ssrc}, the lowest static channel announced on ${data_stream}"
    echo "${ssrc}" > "${cache_file}" 2>/dev/null
    echo "${ssrc}"
}

### Read the drop counter for one status stream.  Echoes "<drops> <ssrc>", or nothing on failure.
function wd_drops_sample_one()
{
    local stream=$1
    local ssrc
    ssrc=$(wd_drops_pick_ssrc "${stream}") || return 1
    local drops
    drops=$( timeout ${WD_DROPS_TIMEOUT} metadump -s ${ssrc} -c 3 "${stream}" 2>/dev/null \
        | grep -oE 'block drops [0-9,]+' | tail -1 | grep -oE '[0-9,]+$' | tr -d , )
    if [[ -z "${drops}" ]]; then
        ### A discovered ssrc which no longer answers (radiod reconfigured?) must not be polled forever:
        ### forget it so the next sample discovers afresh.  A site-configured ssrc is left alone.
        [[ -z "${WD_DROPS_SSRC}" ]] && rm -f "${WD_DROPS_LOG_DIR}/drops.ssrc.${stream}"
        return 1
    fi
    echo "${drops} ${ssrc}"
}

### Append one sample per radio to the drops log.  Self-throttling: does nothing until
### WD_DROPS_LOG_MINUTES have passed since the last write, so it is safe to call from
### the watchdog loop however often that runs.
function log_radiod_drops()
{
    [[ "${WD_DROPS_ENABLED}" != "yes" ]] && return 0
    if ! command -v metadump >/dev/null 2>&1; then
        wd_logger 2 "metadump not installed, so no drop logging"
        return 0
    fi

    ### Fall back to the WD directory if /var/log/wsprdaemon is not writable (WD does not run as root)
    if [[ ! -d "${WD_DROPS_LOG_DIR}" ]]; then
        mkdir -p "${WD_DROPS_LOG_DIR}" 2>/dev/null || sudo mkdir -p "${WD_DROPS_LOG_DIR}" 2>/dev/null
        sudo chown "$(id -un)" "${WD_DROPS_LOG_DIR}" 2>/dev/null
    fi
    if [[ ! -w "${WD_DROPS_LOG_DIR}" ]]; then
        WD_DROPS_LOG_FILE="${WSPRDAEMON_ROOT_DIR:-.}/drops.log"
        wd_logger 2 "${WD_DROPS_LOG_DIR} is not writable, logging drops to ${WD_DROPS_LOG_FILE} instead"
    fi

    ### Throttle using the log file's own mtime, so no extra state file is needed
    if [[ -f "${WD_DROPS_LOG_FILE}" ]]; then
        local age=$(( $(printf "%(%s)T") - $(stat -c %Y "${WD_DROPS_LOG_FILE}" 2>/dev/null || echo 0) ))
        (( age < WD_DROPS_LOG_MINUTES * 60 )) && return 0
    else
        printf "# utc_time\tstatus_stream\tblock_drops\tssrc   (a DECREASE means radiod restarted and the counter reset)\n" >> "${WD_DROPS_LOG_FILE}" 2>/dev/null
    fi

    local stream drops ssrc now
    ### date -u, NOT bash printf %()T -- that formats LOCAL time, so a literal "Z"
    ### in the format string would mislabel local time as UTC.
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for stream in $(wd_drops_status_streams); do
        read -r drops ssrc <<< "$(wd_drops_sample_one "${stream}")"
        printf "%s\t%s\t%s\t%s\n" "${now}" "${stream}" "${drops:-ERR}" "${ssrc:-}" >> "${WD_DROPS_LOG_FILE}"
        if [[ -n "${drops}" ]]; then
            wd_logger 2 "radiod ${stream}: block drops ${drops} (ssrc ${ssrc})"
        else
            wd_logger 1 "ERROR: could not read block drops from ${stream}"
        fi
    done
    return 0
}

##########################################################################################################################################################
########## Section which reports an RX888 that delivers fewer samples than it should  ###################################################################
##########################################################################################################################################################
###
### The block-drop counter above counts samples radiod's own filters could not keep up with.  It does NOT see samples that never
### arrived from the RX888: at KX4AZ-T on 2026-10-23, 22:35-23:22 UTC, radiod@ew-bev's RX888 delivered between 2 and 64 Msps instead
### of 64.8, its WAV files came out 10-30% short, and drops.log read 0 for all three radios the whole time.
###
### Two independent signals, checked every WD_SAMPLE_LOSS_MINUTES from the watchdog:
###  - radiod's own measurement: every minute it logs "RX888 measured sample rate error: R Hz vs nominal N Hz" when R differs from N
###    at all, so its journal covers every minute.  A reading more than WD_SAMPLE_LOSS_PCT below nominal is samples lost.  (Readings
###    within ~2% come and go on a healthy radio: 63.9 and 64.8 Msps were logged with every WAV full size.)
###  - WD's own recordings: each finished one-minute YYYYMMDDTHHMMSSZ_FREQ_usb.wav must hold 60 s at the byte rate in its own header.
###    This also covers receivers fed by a radiod on another host, but it sees only the few minutes of files present when it looks.
###    One short minute is what any radiod restart produces, so a receiver is reported only for two or more.
declare WD_SAMPLE_LOSS_ENABLED=${WD_SAMPLE_LOSS_ENABLED-yes}
declare WD_SAMPLE_LOSS_MINUTES=${WD_SAMPLE_LOSS_MINUTES-10}           ### how often to check, and how far back radiod's journal is read
declare WD_SAMPLE_LOSS_PCT=${WD_SAMPLE_LOSS_PCT-2}                    ### a rate or a WAV this many percent short is a loss
declare WD_SAMPLE_LOSS_ERROR_MINUTES=${WD_SAMPLE_LOSS_ERROR_MINUTES-3}   ### this many lossy minutes in one check make it an ERROR, not a WARNING
declare WD_SAMPLE_LOSS_LOG_FILE=${WD_SAMPLE_LOSS_LOG_FILE-${WD_DROPS_LOG_DIR}/sample-loss.log}
declare WD_SAMPLE_LOSS_LAST_CHECK_EPOCH=0

### Echoes "LOSSY_MINUTES LOWEST_MSPS NOMINAL_MSPS" for radiod@$1 over the last WD_SAMPLE_LOSS_MINUTES, or nothing when it logged no rate line
function wd_sample_loss_radiod_rates()
{
    sudo journalctl -u "radiod@$1" --since "-${WD_SAMPLE_LOSS_MINUTES}min" --no-pager -o cat 2>/dev/null \
        | awk -v pct="${WD_SAMPLE_LOSS_PCT}" '
            /measured sample rate error:/ {
                line = $0; gsub(",", "", line)
                if (match(line, /error: *[0-9.]+ Hz vs nominal [0-9.]+/)) {
                    split(substr(line, RSTART, RLENGTH), f, " ")      # f[2] = measured, f[6] = nominal
                    n++; if (f[2] < f[6] * (100 - pct) / 100) lossy++
                    if (low == "" || f[2] < low) low = f[2]; nominal = f[6]
                }
            }
            END { if (n) printf "%d %.1f %.1f\n", lossy, low / 1e6, nominal / 1e6 }'
}

### Echoes "SHORT_MINUTES TOTAL_FILES WORST_PCT" for the finished one-minute WAVs in recording dir $1 (a receiver's directory)
function wd_sample_loss_wav_check()
{
    local dir=$1 now f name start rate size pct short=0 total=0 worst=100
    local -A short_minutes=()
    now=$(printf "%(%s)T")
    for f in ${dir}/*Z_*_usb.wav ; do
        [[ -f ${f} ]] || continue
        name=${f##*/}
        [[ ${name} =~ ^([0-9]{8})T([0-9]{2})([0-9]{2})00Z_ ]] || continue
        start=$( date -u -d "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}" +%s 2>/dev/null ) || continue
        (( now - start >= 65 )) || continue                                        ### still being written
        ### Only this check's window: files of a band no decoder takes linger ~35 min (KX4AZ-T's 136 kHz and 3.5926 MHz), and
        ### would otherwise put one restart's short minute into several checks
        (( now - start <= WD_SAMPLE_LOSS_MINUTES * 60 )) || continue
        rate=$( od -An -t u4 -j 28 -N 4 "${f}" 2>/dev/null | tr -d ' ' )           ### the header's byte rate
        [[ -n ${rate} ]] && (( rate > 0 )) || continue
        size=$( stat -c %s "${f}" 2>/dev/null ) || continue
        pct=$(( size * 100 / (rate * 60) ))
        (( ++total ))
        (( pct < worst )) && worst=${pct}
        (( pct < 100 - WD_SAMPLE_LOSS_PCT )) && short_minutes[${BASH_REMATCH[2]}${BASH_REMATCH[3]}]=1
    done
    (( total )) && echo "${#short_minutes[@]} ${total} ${worst}"
}

### Self-throttling: does nothing until WD_SAMPLE_LOSS_MINUTES have passed since the last check
function log_radiod_sample_loss()
{
    [[ ${WD_SAMPLE_LOSS_ENABLED} != "yes" ]] && return 0
    local now=$(printf "%(%s)T")
    (( now - WD_SAMPLE_LOSS_LAST_CHECK_EPOCH < WD_SAMPLE_LOSS_MINUTES * 60 )) && return 0
    WD_SAMPLE_LOSS_LAST_CHECK_EPOCH=${now}
    [[ -d ${WD_DROPS_LOG_DIR} && -w ${WD_DROPS_LOG_DIR} ]] || WD_SAMPLE_LOSS_LOG_FILE="${WSPRDAEMON_ROOT_DIR:-.}/sample-loss.log"
    local utc inst lossy low nominal dir rx short total worst level
    utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if declare -F wd_local_radiod_instances > /dev/null ; then
        for inst in $( wd_local_radiod_instances ); do
            systemctl is-active --quiet "radiod@${inst}" || continue
            read -r lossy low nominal <<< "$( wd_sample_loss_radiod_rates "${inst}" )"
            [[ -n ${lossy} ]] && (( lossy > 0 )) || continue
            level=WARNING; (( lossy >= WD_SAMPLE_LOSS_ERROR_MINUTES )) && level=ERROR
            printf "%s\tradiod@%s\t%s lossy minutes, lowest %s of %s Msps\n" "${utc}" "${inst}" "${lossy}" "${low}" "${nominal}" >> "${WD_SAMPLE_LOSS_LOG_FILE}" 2>/dev/null
            wd_logger 1 "${level}: radiod@${inst}'s RX888 delivered more than ${WD_SAMPLE_LOSS_PCT}% fewer samples than its nominal ${nominal} Msps in ${lossy} of the last ${WD_SAMPLE_LOSS_MINUTES} minutes (lowest ${low} Msps), so its recordings have gaps and its spots are lost.  The block-drop counter does not see this.  Suspect the radio's USB cable, port or power.  History: ${WD_SAMPLE_LOSS_LOG_FILE}"
        done
    fi

    for dir in ${WSPRDAEMON_TMP_DIR:-/dev/shm/wsprdaemon}/recording.d/KA9Q_* ; do
        [[ -d ${dir} ]] || continue
        rx=${dir##*/}
        read -r short total worst <<< "$( wd_sample_loss_wav_check "${dir}" )"
        [[ -n ${short} ]] && (( short >= 2 )) || continue
        level=WARNING; (( short >= WD_SAMPLE_LOSS_ERROR_MINUTES )) && level=ERROR
        printf "%s\t%s\t%s short minutes among %s WAVs, worst %s%% of full length\n" "${utc}" "${rx}" "${short}" "${total}" "${worst}" >> "${WD_SAMPLE_LOSS_LOG_FILE}" 2>/dev/null
        wd_logger 1 "${level}: ${rx}'s one-minute WAV files are short in ${short} minutes (worst ${worst}% of a full minute), so its radiod is not delivering every sample.  History: ${WD_SAMPLE_LOSS_LOG_FILE}"
    done
    return 0
}
