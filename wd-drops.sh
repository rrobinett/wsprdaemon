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
###  - radiod's own count of the samples it has received ("in samples" in its status, beside "in samprate"): over a whole check
###    interval it must grow by elapsed time x sample rate.  It misses nothing between checks and needs neither sudo nor the journal
###    (KX4AZ-T, 2026-10-24: ns-bev's count matched 11 hours of 64.8 Msps to the second; ew-bev's was 102 billion, 4.1%, short).
###    A radiod restart resets the count, so a check that sees a new radiod PID, or a smaller count, only takes a new baseline.
###    A radiod whose count does not move at all, or that answers no status after logging "No rx888 data", is a zombie: alive to
###    systemd but getting nothing from its RX888.  It is restarted (once per check) and counted in the RX888 recovery history.
###  - WD's own recordings: each finished one-minute YYYYMMDDTHHMMSSZ_FREQ_usb.wav must hold 60 s at the byte rate in its own header.
###    This also covers receivers fed by a radiod on another host, but it sees only the few minutes of files present when it looks.
###    One short minute is what any radiod restart produces, so a receiver is reported only for two or more.
declare WD_SAMPLE_LOSS_ENABLED=${WD_SAMPLE_LOSS_ENABLED-yes}
declare WD_SAMPLE_LOSS_MINUTES=${WD_SAMPLE_LOSS_MINUTES-10}           ### how often to check: the interval radiod's sample count is judged over
declare WD_SAMPLE_LOSS_PCT=${WD_SAMPLE_LOSS_PCT-2}                    ### a sample count or a WAV this many percent short is a loss
declare WD_SAMPLE_LOSS_ERROR_PCT=${WD_SAMPLE_LOSS_ERROR_PCT-10}       ### a radiod this many percent short over one interval is an ERROR, not a WARNING
declare WD_SAMPLE_LOSS_ERROR_MINUTES=${WD_SAMPLE_LOSS_ERROR_MINUTES-3}   ### this many short WAV minutes in one check make it an ERROR, not a WARNING
declare WD_SAMPLE_LOSS_LOG_FILE=${WD_SAMPLE_LOSS_LOG_FILE-${WD_DROPS_LOG_DIR}/sample-loss.log}
declare WD_SAMPLE_LOSS_LAST_CHECK_EPOCH=0

### Echoes "IN_SAMPLES SAMPRATE" from the status of radiod@$1 (its [global] 'status =' stream), or nothing if it does not answer
function wd_sample_loss_counter()
{
    local stream ssrc out
    stream=$( awk '/^[[:space:]]*status[[:space:]]*=/{v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]#].*$/,"",v); print v; exit}' \
              "${KA9Q_RADIOD_CONF_DIR-/etc/radio}/radiod@$1.conf" 2>/dev/null )
    [[ -n ${stream} ]] || return 1
    ssrc=$( wd_drops_pick_ssrc "${stream}" ) || return 1
    out=$( timeout ${WD_DROPS_TIMEOUT} metadump -s ${ssrc} -c 3 "${stream}" 2>/dev/null )
    awk '/in samples [0-9,]+/ { match($0, /in samples [0-9,]+/);  n = substr($0, RSTART + 11, RLENGTH - 11) }
         /in samprate [0-9,]+/ { match($0, /in samprate [0-9,]+/); r = substr($0, RSTART + 12, RLENGTH - 12) }
         END { gsub(",", "", n); gsub(",", "", r); if (n != "" && r != "") print n, r }' <<< "${out}"
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

### Has the radiod@$1 process now running (pid $2) given up on its RX888?  radiod logs "No rx888 data for 5 seconds, quitting"
### (or "rx888 has aborted") and then stays alive, active to systemd, answering no status and delivering nothing: a zombie.
### KX4AZ-T 2026-10-29/30: radiod@dipole sat like that for 20 hours after a reboot and nothing in WD noticed.
function wd_sample_loss_radiod_gave_up()
{
    sudo journalctl _SYSTEMD_UNIT="radiod@$1.service" _PID="$2" --no-pager -o cat 2>/dev/null | grep -qE "No rx888 data|rx888 has aborted"
}

### Restart zombie radiod@$1 (its RX888 sends nothing), at most once per WD_SAMPLE_LOSS_MINUTES, and count it in the RX888 recovery history
function wd_sample_loss_restart_zombie()
{
    local inst=$1 why=$2 stamp="${WD_DROPS_LOG_DIR}/sample-loss.restart.$1" serial dev
    if [[ -f ${stamp} ]] && (( $(printf "%(%s)T") - $(stat -c %Y ${stamp} 2>/dev/null || echo 0) < WD_SAMPLE_LOSS_MINUTES * 60 - 30 )); then
        return 0
    fi
    touch ${stamp} 2>/dev/null
    printf "%s\tradiod@%s\tZOMBIE: %s; restarting it\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${inst}" "${why}" >> "${WD_SAMPLE_LOSS_LOG_FILE}" 2>/dev/null
    wd_logger 1 "ERROR: radiod@${inst} is running but getting no data from its RX888 (${why}), so restarting it.  If restarts do not bring the data back, an RX888 on a second USB controller may need '[rx888] reqsize=8' and 'queuedepth=8' in radiod@${inst}.conf (KX4AZ-T's bus 4, 2026-10-30); 'wd -u' shows what each RX888 is sending"
    timeout 60 sudo systemctl restart "radiod@${inst}" > /dev/null 2>&1
    rm -f "${WD_DROPS_LOG_DIR}/sample-loss.state.${inst}"
    if declare -F wd_usb_power_record_recovery > /dev/null ; then
        serial=$( wd_usb_power_serial_of_instance "${inst}" 2>/dev/null )
        dev=$( wd_usb_power_dev_of_instance "${inst}" 2>/dev/null || echo "-" )
        wd_usb_power_record_recovery "${inst}" "${dev:--}" "${serial:--}" "get no samples from" \
            "$(systemctl is-active --quiet radiod@${inst} && echo recovered || echo failed)"
    fi
}

### Self-throttling: does nothing until WD_SAMPLE_LOSS_MINUTES have passed since the last check
function log_radiod_sample_loss()
{
    [[ ${WD_SAMPLE_LOSS_ENABLED} != "yes" ]] && return 0
    local now=$(printf "%(%s)T")
    (( now - WD_SAMPLE_LOSS_LAST_CHECK_EPOCH < WD_SAMPLE_LOSS_MINUTES * 60 )) && return 0
    WD_SAMPLE_LOSS_LAST_CHECK_EPOCH=${now}
    [[ -d ${WD_DROPS_LOG_DIR} && -w ${WD_DROPS_LOG_DIR} ]] || WD_SAMPLE_LOSS_LOG_FILE="${WSPRDAEMON_ROOT_DIR:-.}/sample-loss.log"
    local utc inst dir rx short total worst level
    utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if declare -F wd_local_radiod_instances > /dev/null ; then
        for inst in $( wd_local_radiod_instances ); do
            systemctl is-active --quiet "radiod@${inst}" || continue
            local pid samples rate when secs state_file prev_pid prev_samples prev_epoch pct started
            pid=$( systemctl show -p MainPID --value "radiod@${inst}" 2>/dev/null )
            ### Not in its first 2 minutes: a radiod that is still starting answers no status yet
            started=$( date -d "$(systemctl show -p ActiveEnterTimestamp --value radiod@${inst} 2>/dev/null)" +%s 2>/dev/null || echo 0 )
            (( now - started >= 120 )) || continue
            read -r samples rate <<< "$( wd_sample_loss_counter "${inst}" )"
            if [[ -z ${samples} || -z ${rate} ]]; then
                ### A radiod that answers no status is either a zombie (its RX888 gave it no data and it gave up) or just not
                ### reachable by name this minute.  Only the first is certain enough to restart it for.
                if wd_sample_loss_radiod_gave_up "${inst}" "${pid}" ; then
                    wd_sample_loss_restart_zombie "${inst}" "it answers no status and logged 'No rx888 data' since it started"
                else
                    wd_logger 1 "WARNING: radiod@${inst} is running but answered no status request, so its sample count could not be checked"
                fi
                continue
            fi
            when=$(date +%s.%N)          ### this reading's own time: each radiod's status takes ~1 s to read, one after another
            state_file="${WD_DROPS_LOG_DIR}/sample-loss.state.${inst}"
            prev_pid="" prev_samples="" prev_epoch=""
            read -r prev_pid prev_samples prev_epoch 2>/dev/null < "${state_file}"
            echo "${pid} ${samples} ${when}" > "${state_file}" 2>/dev/null
            ### First look, or radiod restarted since the last one: this reading is only the new baseline
            [[ ${prev_pid} == "${pid}" && -n ${prev_samples} ]] && (( samples >= prev_samples )) || continue
            secs=$( awk -v a=${prev_epoch} -v b=${when} 'BEGIN { printf "%d", b - a }' )
            (( secs >= 120 )) || continue    ### a reading's timing is good to ~1 s, so a shorter interval could fake a loss near WD_SAMPLE_LOSS_PCT
            if (( samples == prev_samples )); then
                wd_sample_loss_restart_zombie "${inst}" "its sample count has not moved in ${secs} s"
                continue
            fi
            pct=$( awk -v n=$(( samples - prev_samples )) -v r=${rate} -v a=${prev_epoch} -v b=${when} 'BEGIN { printf "%.1f", 100 * (1 - n / (r * (b - a))) }' )
            awk -v p=${pct} -v l=${WD_SAMPLE_LOSS_PCT} 'BEGIN { exit !(p >= l) }' || continue
            level=WARNING; awk -v p=${pct} -v l=${WD_SAMPLE_LOSS_ERROR_PCT} 'BEGIN { exit !(p >= l) }' && level=ERROR
            printf "%s\tradiod@%s\t%s%% of samples missing over %d s at %s Msps\n" "${utc}" "${inst}" "${pct}" "${secs}" "$( awk -v r=${rate} 'BEGIN { printf "%.1f", r / 1e6 }' )" >> "${WD_SAMPLE_LOSS_LOG_FILE}" 2>/dev/null
            wd_logger 1 "${level}: radiod@${inst} received ${pct}% fewer samples than its ${rate} samples/s in the last $(( (secs + 30) / 60 )) minutes, so its recordings have gaps and spots are lost.  The block-drop counter does not see this.  'wd -u' shows whether the RX888 is not sending (usually the radio itself) or its transfers are failing (cable or USB port).  History: ${WD_SAMPLE_LOSS_LOG_FILE}"
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
