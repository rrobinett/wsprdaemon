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
### The counter read here is chan->filter.out.block_drops for ${WD_DROPS_SSRC}, i.e.
### exactly what `control` displays as "Drops" (control.c) and what `metadump` prints
### as "block drops" (dump.c).  Poll the SAME ssrc every time or the numbers are not
### comparable between samples.
###
### NOTE metadump waits passively unless given -s <ssrc>, and -c 1 returns only the
### poll packet -- the STAT reply needs a couple of records.  Hence '-s N -c 3'.

declare WD_DROPS_ENABLED=${WD_DROPS_ENABLED-yes}
declare WD_DROPS_LOG_DIR=${WD_DROPS_LOG_DIR-/var/log/wsprdaemon}
declare WD_DROPS_LOG_FILE=${WD_DROPS_LOG_FILE-${WD_DROPS_LOG_DIR}/drops.log}
declare WD_DROPS_LOG_MINUTES=${WD_DROPS_LOG_MINUTES-10}
declare WD_DROPS_SSRC=${WD_DROPS_SSRC-14080}
declare WD_DROPS_TIMEOUT=${WD_DROPS_TIMEOUT-10}

### Print the radiod status streams configured on this host, one per line ("hf.local").
### radiod configs come in TWO layouts: a single radiod@NAME.conf file, or a
### radiod@NAME.conf.d/ directory of fragments (ka9q's newer style, used by the udev
### autostart).  Searching only the file form found NO streams on a conf.d host, so
### the drops log sat header-only forever and looked like "no drops" instead of
### "not sampling".  Search both.
function wd_drops_status_streams()
{
    grep -sh -oE '^[[:space:]]*status[[:space:]]*=[[:space:]]*[^[:space:]#]+' \
            /etc/radio/radiod@*.conf /etc/radio/radiod@*.conf.d/*.conf \
        | sed -E 's/.*=[[:space:]]*//' | sort -u
}

### Read the drop counter for one status stream.  Echoes an integer, or nothing on failure.
function wd_drops_sample_one()
{
    local stream=$1
    timeout ${WD_DROPS_TIMEOUT} metadump -s ${WD_DROPS_SSRC} -c 3 "${stream}" 2>/dev/null \
        | grep -oE 'block drops [0-9,]+' | tail -1 | grep -oE '[0-9,]+$' | tr -d ,
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
        printf "# utc_time\tstatus_stream\tblock_drops   (a DECREASE means radiod restarted and the counter reset)\n" >> "${WD_DROPS_LOG_FILE}" 2>/dev/null
    fi

    local stream drops now
    ### date -u, NOT bash printf %()T -- that formats LOCAL time, so a literal "Z"
    ### in the format string would mislabel local time as UTC.
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for stream in $(wd_drops_status_streams); do
        drops=$(wd_drops_sample_one "${stream}")
        printf "%s\t%s\t%s\n" "${now}" "${stream}" "${drops:-ERR}" >> "${WD_DROPS_LOG_FILE}"
        if [[ -n "${drops}" ]]; then
            wd_logger 2 "radiod ${stream}: block drops ${drops}"
        else
            wd_logger 1 "ERROR: could not read block drops from ${stream}"
        fi
    done
    return 0
}
