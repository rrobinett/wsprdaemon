##########################################################################################################################################################
########## Section which finds a ka9q-web stuck spinning on an abandoned browser session, records why, and restarts it ##################################
##########################################################################################################################################################
###
### ka9q-web serves each browser's spectrum over a websocket, through libonion.  When a viewer goes away, the thread that served
### it can keep running flat out: at KX4AZ-T on 2026-10-27 ka9q-web@dipole had two of its 13 threads at 100% of a CPU each with no
### client connected at all, after a browser at 100.112.3.23 opened the page at 15:54 UTC.  gdb put both in libonion's
### onion_websocket_call() -> poll(fds, 1, -1), in state R: poll() returning at once on the dead socket, in a loop that never ends.
### One thread per abandoned session, each taking a CPU from the WSPR/FT decoders that ka9q-web shares CPUs with.  Nothing fails,
### so nothing reports it.
###
### wd_ka9q_web_guard_check(), from the watchdog every WD_KA9Q_WEB_CHECK_MINUTES:
###  - samples every ka9q-web thread's CPU time; a thread at WD_KA9Q_WEB_SPIN_PCT or more of a CPU on WD_KA9Q_WEB_SPIN_PASSES
###    checks in a row is stuck.  Real work never pins one thread: a viewer spreads a little load over several.
###  - with no client on the instance's port it acts at once; with one connected it allows one more check first.
###  - saves 'gdb thread apply all bt' to WD_KA9Q_WEB_GUARD_LOG_DIR (the newest 10 are kept), for the upstream bug report.
###  - restarts a ka9q-web@ unit, or kills a ka9q-web WD started itself (ka9q_web_service_daemon() starts it again in 5 s).
###  - logs each restart, with how many there have been in 24 hours, in WD_KA9Q_WEB_GUARD_LOG_FILE.
### wd_ka9q_web_quota_setup() also caps ka9q-web@ units at WD_KA9Q_WEB_CPU_QUOTA with a systemd drop-in, so a stuck instance costs
### the decoders at most that much even before it is caught.  The unit file itself is the site's and is left alone.

declare WD_KA9Q_WEB_GUARD=${WD_KA9Q_WEB_GUARD-yes}
declare WD_KA9Q_WEB_CHECK_MINUTES=${WD_KA9Q_WEB_CHECK_MINUTES-2}
declare WD_KA9Q_WEB_SPIN_PCT=${WD_KA9Q_WEB_SPIN_PCT-80}             ### one thread at this % of a CPU ...
declare WD_KA9Q_WEB_SPIN_PASSES=${WD_KA9Q_WEB_SPIN_PASSES-2}        ### ... on this many checks in a row is stuck
declare WD_KA9Q_WEB_CPU_QUOTA=${WD_KA9Q_WEB_CPU_QUOTA-50%}          ### CPUQuota= for ka9q-web@ units; "" leaves them uncapped
declare WD_KA9Q_WEB_GUARD_LOG_DIR=${WD_KA9Q_WEB_GUARD_LOG_DIR-/var/log/wsprdaemon}
declare WD_KA9Q_WEB_GUARD_LOG_FILE=${WD_KA9Q_WEB_GUARD_LOG_FILE-${WD_KA9Q_WEB_GUARD_LOG_DIR}/ka9q-web-guard.log}
declare WD_KA9Q_WEB_GUARD_LAST_CHECK_EPOCH=0
declare WD_KA9Q_WEB_QUOTA_DONE="no"
declare -A WD_KA9Q_WEB_PREV=()       ### "PID:TID" -> "TICKS EPOCH" from the previous check
declare -A WD_KA9Q_WEB_STRIKES=()    ### "PID:TID" -> how many checks in a row this thread has been pinned

### Install (or update) the CPUQuota drop-in for the ka9q-web@ template unit.  Returns 0; logs what it did.
function wd_ka9q_web_quota_setup()
{
    [[ ${KA9Q_WEB_SYSTEMD-no} == "yes" && -n ${WD_KA9Q_WEB_CPU_QUOTA} ]] || return 0
    systemctl cat ka9q-web@.service > /dev/null 2>&1 || return 0
    local dir=/etc/systemd/system/ka9q-web@.service.d file want
    file=${dir}/wd-cpu-quota.conf
    want="### Written by WD (wd-ka9q-web-guard.sh): a ka9q-web stuck on an abandoned websocket must not take whole CPUs from the decoders
[Service]
CPUQuota=${WD_KA9Q_WEB_CPU_QUOTA}"
    [[ -f ${file} && "$(< ${file})" == "${want}" ]] && return 0
    sudo mkdir -p ${dir} && echo "${want}" | sudo tee ${file} > /dev/null && sudo systemctl daemon-reload \
        && wd_logger 1 "Capped every ka9q-web@ unit at CPUQuota=${WD_KA9Q_WEB_CPU_QUOTA} (${file})" \
        || wd_logger 1 "ERROR: could not write ${file}"
    return 0
}

### Echoes the ka9q-web@ unit that pid $1 runs in, or nothing for a ka9q-web started by WD itself
function wd_ka9q_web_unit_of_pid()
{
    sed -n 's|.*/\(ka9q-web@[^/]*\.service\).*|\1|p' /proc/$1/cgroup 2>/dev/null | head -1
}

function wd_ka9q_web_guard_check()
{
    [[ ${WD_KA9Q_WEB_GUARD} == "yes" ]] || return 0
    local now; now=$(printf "%(%s)T")
    (( now - WD_KA9Q_WEB_GUARD_LAST_CHECK_EPOCH < WD_KA9Q_WEB_CHECK_MINUTES * 60 )) && return 0
    WD_KA9Q_WEB_GUARD_LAST_CHECK_EPOCH=${now}
    [[ ${WD_KA9Q_WEB_QUOTA_DONE} == "yes" ]] || { wd_ka9q_web_quota_setup; WD_KA9Q_WEB_QUOTA_DONE="yes"; }

    local hz pid tid task ticks key prev_ticks prev_epoch pct
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    local -A seen=() stuck=() worst=()
    for pid in $(pgrep -x ka9q-web); do
        for task in /proc/${pid}/task/*; do
            [[ -r ${task}/stat ]] || continue
            tid=${task##*/}; key="${pid}:${tid}"; seen[${key}]=1
            ticks=$( awk '{ sub(/^.*\) /, ""); print $12 + $13 }' ${task}/stat 2>/dev/null ) || continue
            if [[ -n ${WD_KA9Q_WEB_PREV[${key}]-} ]]; then
                read -r prev_ticks prev_epoch <<< "${WD_KA9Q_WEB_PREV[${key}]}"
                if (( now > prev_epoch )); then
                    pct=$(( (ticks - prev_ticks) * 100 / (hz * (now - prev_epoch)) ))
                    if (( pct >= WD_KA9Q_WEB_SPIN_PCT )); then
                        WD_KA9Q_WEB_STRIKES[${key}]=$(( ${WD_KA9Q_WEB_STRIKES[${key}]-0} + 1 ))
                        (( WD_KA9Q_WEB_STRIKES[${key}] >= WD_KA9Q_WEB_SPIN_PASSES )) && stuck[${pid}]+="${tid}(${pct}%) "
                        (( WD_KA9Q_WEB_STRIKES[${key}] > ${worst[${pid}]-0} )) && worst[${pid}]=${WD_KA9Q_WEB_STRIKES[${key}]}
                    else
                        unset "WD_KA9Q_WEB_STRIKES[${key}]"
                    fi
                fi
            fi
            WD_KA9Q_WEB_PREV[${key}]="${ticks} ${now}"
        done
    done
    for key in "${!WD_KA9Q_WEB_PREV[@]}"; do                 ### forget threads and processes that are gone
        [[ -n ${seen[${key}]-} ]] || { unset "WD_KA9Q_WEB_PREV[${key}]"; unset "WD_KA9Q_WEB_STRIKES[${key}]"; }
    done

    local port clients unit utc bt day
    for pid in "${!stuck[@]}"; do
        port=$( tr '\0' ' ' < /proc/${pid}/cmdline 2>/dev/null | grep -oE -- '-p [0-9]+' | grep -oE '[0-9]+' )
        clients=$( ss -tnH state established "( sport = :${port:-0} )" 2>/dev/null | wc -l )
        unit=$( wd_ka9q_web_unit_of_pid ${pid} )
        if (( clients > 0 && worst[${pid}] <= WD_KA9Q_WEB_SPIN_PASSES )); then
            wd_logger 1 "WARNING: ka9q-web ${unit:-pid ${pid}} on port ${port} has thread(s) ${stuck[${pid}]}pinned, but ${clients} viewer(s) are connected, so it gets one more check before it is restarted"
            continue
        fi
        utc=$(date -u +%Y%m%dT%H%M%SZ)
        bt="${WD_KA9Q_WEB_GUARD_LOG_DIR}/ka9q-web-spin-${port:-x}-${utc}.bt"
        if command -v gdb > /dev/null; then
            sudo timeout 30 gdb -p ${pid} -batch -ex "thread apply all bt 12" > ${bt} 2>&1 || true
            ls -t ${WD_KA9Q_WEB_GUARD_LOG_DIR}/ka9q-web-spin-*.bt 2>/dev/null | tail -n +11 | xargs -r rm -f
        else
            bt="(no gdb installed, so no backtrace)"
        fi
        if [[ -n ${unit} ]]; then
            sudo systemctl restart "${unit}"
        else
            kill ${pid}                                        ### ka9q_web_service_daemon() starts it again in 5 s
        fi
        printf "%s\t%s\tport %s\tthreads %s\tclients %s\t%s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${unit:-pid ${pid}}" "${port}" "${stuck[${pid}]% }" "${clients}" "${bt}" >> ${WD_KA9Q_WEB_GUARD_LOG_FILE} 2>/dev/null
        day=$( awk -F'\t' -v d="$(date -u -d '-1 day' +%Y-%m-%dT%H:%M:%SZ)" '$1 >= d' ${WD_KA9Q_WEB_GUARD_LOG_FILE} 2>/dev/null | wc -l )
        wd_logger 1 "WARNING: restarted ka9q-web ${unit:-pid ${pid}} on port ${port}: thread(s) ${stuck[${pid}]}had been pinned for ${worst[${pid}]} checks with ${clients} viewer(s) connected, a websocket session left spinning in libonion (${day} such restarts in 24 h).  Backtrace: ${bt}"
        for key in "${!WD_KA9Q_WEB_PREV[@]}"; do [[ ${key} == ${pid}:* ]] && { unset "WD_KA9Q_WEB_PREV[${key}]"; unset "WD_KA9Q_WEB_STRIKES[${key}]"; }; done
    done
    return 0
}
