##########################################################################################################################################################
########## Section which makes sure the system clock is disciplined by chrony to servers that actually answer  ###########################################
##########################################################################################################################################################
###
### WSPR and FST4W decoding need the clock within about a second of UTC, and every wav file WD records
### is stamped with it.  Two ways sites have quietly lost that:
###   - no time daemon running at all (several installs over the years), and
###   - 2026-09-06 at N8UR (RAC 175): systemd-timesyncd polled only the DHCP-advertised LAN server, which
###     never answered.  timesyncd does not fall back to its pool servers while a DHCP server is configured,
###     so the clock drifted 7 s slow and WD logged one WARNING line nobody saw.
###
### So WD now enforces chrony, which polls every configured source and simply ignores the ones that
### do not answer:
###   1. installs chrony (apt removes systemd-timesyncd / ntp / ntpsec, which conflict with it) and
###      stops + masks any of those that are still around
###   2. adds well-known public pools as EXTRA sources in /etc/chrony/sources.d/wsprdaemon.sources.
###      Site-configured and DHCP-supplied servers stay in the mix and win when they answer (a
###      GPS-disciplined LAN server is stratum 1; the pools are stratum 2)
###   3. lets chrony step the clock however large the error whenever its sources agree (makestep 1 -1),
###      so a host that boots with a bad RTC or comes back after a long outage is fixed in seconds
###   4. on 'wda' / service start waits up to WD_TIME_SYNC_WAIT_SECS for chrony to report a synchronised
###      clock and, if it can't, says so on the terminal, in the WD log, on stderr (=> journalctl -u
###      wsprdaemon) and in /var/log/wsprdaemon/time-sync.log, together with what each source answered
###   5. re-checks every WD_TIME_SYNC_CHECK_MINUTES from the watchdog daemon and logs an ERROR line
###      for as long as the clock is not synchronised, and one line when it recovers
###
### wsprdaemon.conf:
###   WD_TIME_SYNC="chrony"          (default) do all of the above
###   WD_TIME_SYNC="no"              this site manages its own time (its own chrony/ntpsec/GPS setup):
###                                  WD changes nothing and only checks and complains
###   WD_NTP_SERVERS="a b c"         the extra sources.  Each is written as 'pool <name> iburst'
###   WD_TIME_SYNC_WAIT_SECS=30      how long a WD start waits for sync before complaining
###   WD_TIME_SYNC_CHECK_MINUTES=10  watchdog re-check interval
###
### Diagnose with 'wdt' (chronyc tracking + sources + this log).

declare WD_TIME_SYNC=${WD_TIME_SYNC-chrony}
declare WD_NTP_SERVERS=${WD_NTP_SERVERS-"pool.ntp.org time.google.com time.cloudflare.com time.nist.gov"}
declare WD_TIME_SYNC_WAIT_SECS=${WD_TIME_SYNC_WAIT_SECS-30}
declare WD_TIME_SYNC_CHECK_MINUTES=${WD_TIME_SYNC_CHECK_MINUTES-10}
declare WD_TIME_SYNC_MAX_OFFSET_SECS=${WD_TIME_SYNC_MAX_OFFSET_SECS-1}      ### 'synchronised' also means |offset| is below this
declare WD_TIME_SYNC_LOG=${WD_TIME_SYNC_LOG-/var/log/wsprdaemon/time-sync.log}

declare WD_CHRONY_CONF=/etc/chrony/chrony.conf
declare WD_CHRONY_SOURCES_FILE=/etc/chrony/sources.d/wsprdaemon.sources
declare WD_CHRONY_MARK_BEGIN="### BEGIN wsprdaemon (managed by wd-time-sync.sh -- do not hand-edit this block)"
declare WD_CHRONY_MARK_END="### END wsprdaemon"

### Results of the last wd_time_sync_status call
declare WD_TIME_SYNC_STATE="unknown"      ### synced | unsynced | no-daemon
declare WD_TIME_SYNC_SUMMARY=""           ### one human line
declare WD_TIME_SYNC_LAST_CHECK_EPOCH=0
declare WD_TIME_SYNC_LAST_STATE=""

### Log to the WD log, the terminal when there is one, and time-sync.log.  ERROR/WARNING lines also go
### to stderr when there is no terminal, so a service start leaves them in 'journalctl -u wsprdaemon'.
### wd_logger() is silent at source time (no WD_LOGFILE yet, no tty under systemd), hence the extra copies.
function wd_time_sync_log()
{
    local log_level=$1 log_line=$2
    wd_logger ${log_level} "${log_line}"
    (( log_level > 1 )) && return 0                   ### time-sync.log keeps what an operator needs to see, not chatter
    if [[ -f ${WD_TIME_SYNC_LOG} ]] && (( $(stat -c %s ${WD_TIME_SYNC_LOG} 2>/dev/null || echo 0) > 200000 )); then
        tail -n 200 ${WD_TIME_SYNC_LOG} > ${WD_TIME_SYNC_LOG}.tmp 2>/dev/null && mv ${WD_TIME_SYNC_LOG}.tmp ${WD_TIME_SYNC_LOG}
    fi
    printf '%s %b\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${log_line}" >> ${WD_TIME_SYNC_LOG} 2>/dev/null
    if [[ ${log_line} =~ ^(ERROR|WARNING) ]] && ! [ -t 2 ]; then
        printf 'wd-time-sync: %b\n' "${log_line}" 1>&2
    fi
}

### Sets WD_TIME_SYNC_STATE and WD_TIME_SYNC_SUMMARY.  Returns 0 when synced.
### chronyc's monitoring commands need no privileges.  Without chrony, fall back to what systemd knows.
function wd_time_sync_status()
{
    WD_TIME_SYNC_STATE="no-daemon"
    WD_TIME_SYNC_SUMMARY="no time daemon is running"

    if command -v chronyc > /dev/null && systemctl is-active --quiet chrony 2>/dev/null; then
        local csv
        csv=$( chronyc -c tracking 2>/dev/null )
        if [[ -z "${csv}" ]]; then
            WD_TIME_SYNC_STATE="unsynced"
            WD_TIME_SYNC_SUMMARY="chrony is running but 'chronyc tracking' returned nothing"
            return 1
        fi
        ### refid,refname,stratum,reftime,sysoffset,lastoffset,rmsoffset,freq,residfreq,skew,rootdelay,rootdisp,updateinterval,leap
        local refname stratum offset leap
        IFS=',' read -r _ refname stratum _ offset _ _ _ _ _ _ _ _ leap <<< "${csv}"
        local offset_ms=$( awk -v o="${offset:-0}" 'BEGIN { printf "%d", o * 1000 }' )
        local offset_abs=${offset_ms#-}
        if [[ "${leap}" != "Not synchronised" && ${stratum:-0} -gt 0 && ${offset_abs} -le $(( WD_TIME_SYNC_MAX_OFFSET_SECS * 1000 )) ]]; then
            WD_TIME_SYNC_STATE="synced"
            WD_TIME_SYNC_SUMMARY="chrony is synchronised to ${refname:-?} (stratum ${stratum}), offset ${offset_ms} ms"
            return 0
        fi
        WD_TIME_SYNC_STATE="unsynced"
        WD_TIME_SYNC_SUMMARY="chrony reports '${leap}', stratum ${stratum:-0}, offset ${offset_ms} ms"
        return 1
    fi

    if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
        WD_TIME_SYNC_STATE="synced"
        WD_TIME_SYNC_SUMMARY="chrony is not running but systemd reports the clock is synchronised"
        return 0
    fi
    local active
    active=$( systemctl is-active systemd-timesyncd ntp ntpsec 2>/dev/null | grep -c '^active$' )
    if (( active )); then
        WD_TIME_SYNC_STATE="unsynced"
        WD_TIME_SYNC_SUMMARY="a non-chrony time daemon is running but the clock is not synchronised"
    fi
    return 1
}

### What every source answered, for the error message and for 'wdt'
function wd_time_sync_sources_report()
{
    if command -v chronyc > /dev/null; then
        if ! systemctl is-active --quiet chrony; then
            echo "    chrony is NOT running ($(systemctl is-active chrony)).  'sudo journalctl -u chrony' says:"
            sudo journalctl -u chrony -n 6 --no-pager 2>/dev/null | grep -v '^--' | cut -c1-160 | sed 's/^/    /'
            return 0
        fi
        chronyc -n sources 2>&1 | sed 's/^/    /'
    else
        timedatectl timesync-status 2>&1 | sed 's/^/    /'
    fi
}

### Install chrony and retire the daemons it replaces.  Does NOT start chrony: chrony.conf may still hold
### a block that chronyd refuses (which is exactly how N8UR got stuck on 2026-09-06), so the config is
### written/repaired first by wd_time_sync_configure_chrony() and the start comes after that.
### Returns 0 when chronyd is installed.
function wd_time_sync_install_chrony()
{
    local rc
    if ! command -v chronyd > /dev/null; then
        wd_time_sync_log 1 "Installing chrony (apt will remove systemd-timesyncd / ntp / ntpsec, which conflict with it)"
        install_debian_package chrony
        rc=$? ; if (( rc )); then
            wd_time_sync_log 1 "ERROR: 'install_debian_package chrony' => ${rc}, so the clock stays with whatever daemon this host has"
            return ${rc}
        fi
    fi

    ### Whatever apt left behind must not fight chrony for the clock
    local unit
    for unit in systemd-timesyncd ntp ntpsec ntpd; do
        if systemctl list-unit-files "${unit}.service" 2>/dev/null | grep -q "^${unit}.service"; then
            if systemctl is-active --quiet "${unit}" || systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
                wd_time_sync_log 1 "Stopping and masking ${unit}.service: chrony owns the clock from now on"
                sudo systemctl disable --now "${unit}" > /dev/null 2>&1
            fi
            sudo systemctl mask "${unit}" > /dev/null 2>&1
        fi
    done

    if ! systemctl is-enabled --quiet chrony 2>/dev/null; then
        sudo systemctl enable chrony > /dev/null 2>&1
    fi
    return 0
}

### After the config is in place: make sure chronyd is running.  Returns 0 when it is.
function wd_time_sync_ensure_running()
{
    systemctl is-active --quiet chrony && return 0
    sudo systemctl restart chrony
    local rc=$?
    if (( rc )); then
        wd_time_sync_log 1 "ERROR: 'systemctl restart chrony' => ${rc}"
        return ${rc}
    fi
    return 0
}

### Write a file only if its content changed.  Echoes "changed" when it did.
function wd_time_sync_write_file()
{
    local path=$1 content=$2
    if [[ -f ${path} ]] && [[ "$(< ${path})" == "${content}" ]]; then
        return 0
    fi
    sudo mkdir -p "${path%/*}"
    printf '%s\n' "${content}" | sudo tee "${path}" > /dev/null
    echo "changed"
}

### Add the WD sources and the makestep policy.  Sources go to /etc/chrony/sources.d/ when this chrony
### includes that directory (Debian/Ubuntu chrony >= 4), else into the marked block.  makestep ALWAYS goes
### into a marked block at the END of chrony.conf: chrony's last makestep wins, and the distro's
### 'makestep 1 3' sits after its confdir include, so a conf.d file could not override it.
### Returns 0 when chrony has the config loaded.
function wd_time_sync_configure_chrony()
{
    if [[ ! -f ${WD_CHRONY_CONF} ]]; then
        wd_time_sync_log 1 "ERROR: ${WD_CHRONY_CONF} does not exist, so chrony is not installed the way this code expects"
        return 1
    fi

    local server sources=""
    for server in ${WD_NTP_SERVERS}; do
        sources+="pool ${server} iburst"$'\n'
    done
    sources=${sources%$'\n'}
    ### chrony.conf has NO inline comments (chronyd: "Too many arguments for makestep directive"), so the comment is its own line
    local policy="# step the clock for any offset over 1 s at any time, not only during chrony's first 3 updates
makestep 1 -1"

    local block="${WD_CHRONY_MARK_BEGIN}"$'\n'
    if grep -qE '^[[:space:]]*sourcedir[[:space:]]+/etc/chrony/sources\.d' ${WD_CHRONY_CONF}; then
        if [[ -n "$( wd_time_sync_write_file ${WD_CHRONY_SOURCES_FILE} "# Extra NTP sources added by wsprdaemon (wd-time-sync.sh, WD_NTP_SERVERS in wsprdaemon.conf).
# Servers from chrony.conf and from DHCP are still used; these make sure SOMETHING answers.
${sources}" )" ]]; then
            wd_time_sync_log 1 "Wrote ${WD_CHRONY_SOURCES_FILE}: $(tr '\n' ' ' <<< "${sources}")"
            sudo chronyc reload sources > /dev/null 2>&1
        fi
    else
        block+="${sources}"$'\n'
    fi
    block+="${policy}"$'\n'"${WD_CHRONY_MARK_END}"

    local current
    current=$( awk -v b="${WD_CHRONY_MARK_BEGIN}" -v e="${WD_CHRONY_MARK_END}" '$0 == b { p = 1 } p { print } $0 == e { p = 0 }' ${WD_CHRONY_CONF} )
    if [[ "${current}" == "${block}" ]]; then
        return 0
    fi
    local tmp
    tmp=$( mktemp )
    awk -v b="${WD_CHRONY_MARK_BEGIN}" -v e="${WD_CHRONY_MARK_END}" '$0 == b { skip = 1 } ! skip { print } $0 == e { skip = 0 }' ${WD_CHRONY_CONF} \
        | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && l[n] == "") n--; for (i = 1; i <= n; i++) print l[i] }' > ${tmp}     ### drop trailing blank lines
    printf '\n%s\n' "${block}" >> ${tmp}
    sudo cp -p ${WD_CHRONY_CONF} ${WD_CHRONY_CONF}.wd-bak
    sudo cp ${tmp} ${WD_CHRONY_CONF}
    rm -f ${tmp}
    wd_time_sync_log 1 "Updated the wsprdaemon block at the end of ${WD_CHRONY_CONF} and restarting chrony to load it"
    if ! sudo systemctl restart chrony; then
        ### Never leave the host with no time daemon because of something WD wrote
        sudo cp -p ${WD_CHRONY_CONF}.wd-bak ${WD_CHRONY_CONF}
        sudo systemctl restart chrony
        wd_time_sync_log 1 "ERROR: chrony refused the updated ${WD_CHRONY_CONF}, so it was restored from ${WD_CHRONY_CONF}.wd-bak and chrony restarted (now $(systemctl is-active chrony)).  chronyd said:\n$(sudo journalctl -u chrony -n 5 --no-pager 2>/dev/null | grep -i 'error\|fail\|directive' | sed 's/^/    /')"
        return 1
    fi
    return 0
}

### Wait up to $1 seconds for chrony to report sync with |offset| <= WD_TIME_SYNC_MAX_OFFSET_SECS
function wd_time_sync_wait()
{
    local wait_secs=${1:-${WD_TIME_SYNC_WAIT_SECS}}
    wd_time_sync_status && return 0
    if command -v chronyc > /dev/null && systemctl is-active --quiet chrony; then
        wd_time_sync_log 1 "Waiting up to ${wait_secs} seconds for chrony to synchronise the clock"
        ### waitsync <max-tries> <max-correction-secs> <max-skew-ppm (0 = any)> <interval-secs>
        chronyc waitsync $(( (wait_secs + 1) / 2 )) ${WD_TIME_SYNC_MAX_OFFSET_SECS} 0 2 > /dev/null 2>&1
    else
        wd_sleep 5
    fi
    wd_time_sync_status
}

### Tell the operator, loudly, that the clock is bad
function wd_time_sync_complain()
{
    local why=$1
    wd_time_sync_log 1 "ERROR: the system clock is NOT synchronised: ${why}.\n    WSPR decoding needs the clock within a second of UTC, so spots will be missed or mis-timed until this is fixed.\n    Sources and what they answered ('wdt' shows this at any time):\n$(wd_time_sync_sources_report)\n    Fix: if chrony is not running, fix what the journal complains about and 'sudo systemctl restart chrony'; otherwise make sure this host can reach UDP port 123 on the servers above (firewall?), or set WD_NTP_SERVERS in wsprdaemon.conf to servers it can reach.  Then 'wda' again."
}

### Runs at every WD start (sourced from wd-setup.sh).  Only the real starts ('-a' from wda, '-A' from
### the service) wait for sync; every other wd command just reports the current state so that
### 'wd -s' and friends stay fast.
function wd_time_sync_setup()
{
    local starting="no"
    [[ " $* " =~ " -a " || " $* " =~ " -A " ]] && starting="yes"

    if [[ "${WD_TIME_SYNC}" == "no" ]]; then
        if wd_time_sync_status; then
            wd_time_sync_log 2 "WD_TIME_SYNC=no: ${WD_TIME_SYNC_SUMMARY}"
        else
            wd_time_sync_complain "${WD_TIME_SYNC_SUMMARY} (WD_TIME_SYNC=\"no\", so WD is leaving the time daemon to you)"
        fi
        return 0
    fi

    if ! wd_time_sync_install_chrony; then
        wd_time_sync_status || wd_time_sync_complain "${WD_TIME_SYNC_SUMMARY}, and WD could not install chrony to fix that"
        return 0
    fi
    wd_time_sync_configure_chrony      ### writes/repairs the config and restarts chrony when it changed
    wd_time_sync_ensure_running        ### first start after the install, or a retry after a failed one

    if [[ ${starting} == "yes" ]]; then
        wd_time_sync_wait ${WD_TIME_SYNC_WAIT_SECS}
    else
        wd_time_sync_status
    fi
    if [[ ${WD_TIME_SYNC_STATE} == "synced" ]]; then
        local level=2
        [[ ${starting} == "yes" ]] && level=1        ### one line per start; the other wd commands stay quiet
        wd_time_sync_log ${level} "Time sync: ${WD_TIME_SYNC_SUMMARY}"
    else
        wd_time_sync_complain "${WD_TIME_SYNC_SUMMARY}"
    fi
    return 0
}

### Called from the watchdog's odd-minute pass.  Self-throttling.
function wd_time_sync_check()
{
    local now=$(printf "%(%s)T")
    (( now - WD_TIME_SYNC_LAST_CHECK_EPOCH < WD_TIME_SYNC_CHECK_MINUTES * 60 )) && return 0
    WD_TIME_SYNC_LAST_CHECK_EPOCH=${now}

    wd_time_sync_status
    if [[ ${WD_TIME_SYNC_STATE} != "synced" ]]; then
        wd_time_sync_complain "${WD_TIME_SYNC_SUMMARY}"
    elif [[ ${WD_TIME_SYNC_LAST_STATE} != "synced" && -n ${WD_TIME_SYNC_LAST_STATE} ]]; then
        wd_time_sync_log 1 "Time sync recovered: ${WD_TIME_SYNC_SUMMARY}"
    else
        wd_time_sync_log 2 "Time sync: ${WD_TIME_SYNC_SUMMARY}"
    fi
    WD_TIME_SYNC_LAST_STATE=${WD_TIME_SYNC_STATE}
    return 0
}

### 'wdt': everything an operator needs to see about the clock
function wd_time_sync_show()
{
    echo "Clock: $(date -u '+%Y-%m-%d %H:%M:%S UTC')  ($(timedatectl show -p NTPSynchronized --value 2>/dev/null | sed 's/yes/systemd: synchronised/;s/no/systemd: NOT synchronised/'))"
    if command -v chronyc > /dev/null; then
        echo "--- chronyc tracking"; chronyc tracking 2>&1
        echo "--- chronyc sources (^* = the one in use, ^? = never answered)"; chronyc sources -v 2>&1
    else
        echo "chrony is not installed (WD_TIME_SYNC=${WD_TIME_SYNC})"; timedatectl timesync-status 2>&1
    fi
    if [[ -f ${WD_TIME_SYNC_LOG} ]]; then
        echo "--- last lines of ${WD_TIME_SYNC_LOG}"; tail -n 8 ${WD_TIME_SYNC_LOG}
    fi
}
