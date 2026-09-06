##########################################################################################################################################################
########## Section which makes sure mDNS (avahi) actually works, because every KA9Q stream name WD records from is a .local name ##########################
##########################################################################################################################################################
###
### Seen twice at N8GA on 2026-09-06 (Ubuntu 22.04 and 24.04, avahi 0.8): after avahi-daemon was restarted -- once by an
### unattended-upgrade, once by a WD upgrade's package installs -- its IPv4 interface flapped during start-up and the
### daemon never left the REGISTERING state (D-Bus GetState = 1, no "Server startup complete" in its journal).  In that
### state no locally published record resolves: 'getent hosts wspr-pcm.local' fails, wd-record loops on "Name or service
### not known", and WD records nothing while every log just says "make sure pcmrecord is running".  Both stations sat
### silent for days.  A plain restart of avahi-daemon fixes the daemon, but radiod's 'avahi-publish-address' records do
### not survive an avahi restart (only its --no-fail service records do), so radiod has to be restarted afterwards.
###
### So: at every WD start, and every WD_MDNS_CHECK_MINUTES from the watchdog, check avahi's state and that the stream
### names in RECEIVER_LIST resolve; repair by restarting avahi-daemon and then the running radiod@ unit(s); log an
### ERROR when that does not help.  WD_MDNS_CHECK="no" disables the repairs (the check still logs).

declare WD_MDNS_CHECK=${WD_MDNS_CHECK-yes}
declare WD_MDNS_CHECK_MINUTES=${WD_MDNS_CHECK_MINUTES-10}
declare WD_MDNS_LAST_CHECK_EPOCH=0

### Echoes avahi's server state: 0 invalid, 1 registering, 2 running, 3 collision, 4 failure; empty when unknown
function wd_mdns_avahi_state()
{
    command -v busctl > /dev/null || return 0
    busctl --system call org.freedesktop.Avahi / org.freedesktop.Avahi.Server GetState 2>/dev/null | awk '{print $2}'
}

### Echoes the .local stream names of the KA9Q receivers in RECEIVER_LIST
function wd_mdns_stream_names()
{
    local rx
    for rx in "${RECEIVER_LIST[@]-}"; do
        local f=( ${rx} )
        [[ ${f[0]:-} =~ ^KA9Q && ${f[1]:-} == *.local ]] && echo "${f[1]}"
    done | sort -u
}

### Echoes the names in $@ that do not resolve
function wd_mdns_unresolved()
{
    local name
    for name in "$@"; do
        getent hosts "${name}" > /dev/null 2>&1 || echo "${name}"
    done
}

### Restart avahi, wait for RUNNING, then restart the running radiod(s) so their address records come back
function wd_mdns_repair()
{
    local why=$1
    wd_logger 1 "WARNING: ${why}, so restarting avahi-daemon (and then the running radiod(s), whose mDNS address records do not survive that)"
    sudo systemctl restart avahi-daemon
    local i state
    for (( i = 0; i < 10; ++i )); do
        sleep 1
        state=$( wd_mdns_avahi_state )
        [[ ${state} == 2 ]] && break
    done
    if [[ ${state} != 2 ]]; then
        wd_logger 1 "ERROR: avahi-daemon is still in state '${state:-unknown}' (2 = RUNNING) after a restart, so .local names will not resolve and WD cannot record.  See 'sudo journalctl -u avahi-daemon'"
        return 1
    fi
    local unit
    for unit in $( systemctl list-units 'radiod@*.service' 'ka9q-radio@*.service' --state=active --no-legend --plain 2>/dev/null | awk '{print $1}' ); do
        sudo systemctl restart "${unit}"
    done
    sleep 5
    ### A wd-record that hit "Name or service not known" keeps retrying but never recovers once the name resolves
    ### (N8GA-BL-1: names back, 0 wav files until the recorders were killed).  WD's recording daemons respawn them.
    pkill -x wd-record 2>/dev/null
    return 0
}

### Returns 0 when avahi is RUNNING and every KA9Q stream name resolves.  $1 = "repair" to fix what it can.
function wd_mdns_ensure_running()
{
    local mode=${1:-repair}
    [[ ${WD_MDNS_CHECK} != "yes" ]] && mode="report"
    local -a names=( $( wd_mdns_stream_names ) )
    (( ${#names[@]} == 0 )) && return 0                          ### no KA9Q receivers: nothing to check
    systemctl is-active --quiet avahi-daemon 2>/dev/null || { wd_logger 1 "ERROR: avahi-daemon is not running, so the KA9Q stream names ${names[*]} cannot resolve and WD cannot record"; return 1; }

    local state=$( wd_mdns_avahi_state )
    local -a missing=( $( wd_mdns_unresolved "${names[@]}" ) )
    if [[ -n ${state} && ${state} != 2 ]]; then
        [[ ${mode} == "repair" ]] && wd_mdns_repair "avahi-daemon is stuck in state ${state} (2 = RUNNING) and nothing published on this host resolves" || wd_logger 1 "ERROR: avahi-daemon is stuck in state ${state} (2 = RUNNING), so no .local name resolves (WD_MDNS_CHECK=no, not repairing)"
        missing=( $( wd_mdns_unresolved "${names[@]}" ) )
    elif (( ${#missing[@]} )) && [[ ${mode} == "repair" ]] && pgrep -x radiod > /dev/null; then
        ### avahi says it is fine but radiod's names are gone: its address records were lost to an earlier avahi restart
        wd_mdns_repair "radiod is running but its stream name(s) ${missing[*]} do not resolve"
        missing=( $( wd_mdns_unresolved "${names[@]}" ) )
    fi
    if (( ${#missing[@]} )); then
        wd_logger 1 "ERROR: KA9Q stream name(s) ${missing[*]} do not resolve, so WD cannot record from them.  Check 'avahi-browse -art', 'sudo journalctl -u avahi-daemon' and that radiod is running and publishing them"
        return 1
    fi
    wd_logger 2 "avahi is running and ${names[*]} resolve"
    return 0
}

### Watchdog odd-minute hook, self-throttled
function wd_mdns_check()
{
    local now=$(printf "%(%s)T")
    (( now - WD_MDNS_LAST_CHECK_EPOCH < WD_MDNS_CHECK_MINUTES * 60 )) && return 0
    WD_MDNS_LAST_CHECK_EPOCH=${now}
    wd_mdns_ensure_running repair
    return 0
}
