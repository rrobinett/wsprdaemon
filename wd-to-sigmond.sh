#!/bin/bash
# wd-to-sigmond.sh — move an RX888 WsprDaemon station to a bare-metal Sigmond install, and back.
#
# Generalized from the hand-made kit that converted KJ6MKI (RAC 84) on 2026-10-27/28
# (bundle.sh, handover.sh, pre-sigmond.sh, restore.sh), plus every problem that station's
# first `smd align`, first reboot and first week turned up (2026-11-11/12).
#
# Run ON THE STATION as the WsprDaemon user (passwordless sudo).  Never under sudo:
# smd refuses that.  Each phase refuses to run until the one before it has left its marker.
#
#   wd-to-sigmond.sh check                 read-only: is this station a candidate, and what will not carry over
#   wd-to-sigmond.sh bundle                capture the revert bundle (read-only for the running stack)
#   wd-to-sigmond.sh handover              stop + disable the WsprDaemon stack; the RX888 is then free
#   wd-to-sigmond.sh prep                  remove WD's host tuning so it cannot fight sigmond
#   wd-to-sigmond.sh install [opts]        clone + install sigmond, then `smd bringup` (no sigmond-rac)
#   wd-to-sigmond.sh post                  the fixes KJ6MKI needed after bring-up; stages kernel isolation,
#                                          applies sigmond's CPU clock policy, WD-only uploads, PSWS ids + key check
#   wd-to-sigmond.sh reboot                reboot to activate isolcpus/nohz_full/rcu_nocbs
#   wd-to-sigmond.sh verify                after the reboot: isolation, IRQs, CPU clocks, services, spots,
#                                          grape-daily.timer and a login-only PSWS test of the GRAPE upload key
#   wd-to-sigmond.sh restore [--check]     put the station back on WsprDaemon from the bundle
#
# install options:
#   --profile NAME     sigmond bring-up profile (default wd: radiod, ka9q-web, wspr-recorder, psk-recorder;
#                      hf-timestd is added only where wsprdaemon.conf recorded WWV)
#   --reporter ID      default: REPORTER_ID from wsprdaemon.conf
#   --grid LOCATOR     default: REPORTER_GRID from wsprdaemon.conf
#   --callsign CALL    default: the reporter id up to the first '/' or '-'
#   --yes              no prompts
#
# Global options:  --bundle DIR (default: newest ~/wd-to-sigmond/bundle-*)   --dry-run   --yes
#
# It never touches wd-remote-access@* (the RAC tunnel you arrive over), the WsprDaemon git
# tree, PostgreSQL or the desktop session.  sigmond-rac is never activated (SIGMOND_NO_RAC=1):
# installing it beside wd-remote-access could cut the only path in.
#
# Full description: WD-TO-SIGMOND.md beside this script.

set -uo pipefail
shopt -s nullglob

declare -r WD_HOME=${WD_HOME:-$HOME/wsprdaemon}
declare -r WORK_ROOT=${WD_TO_SIGMOND_ROOT:-$HOME/wd-to-sigmond}
declare -r SIGMOND_BASE=/opt/git/sigmond
declare -r SMD=/usr/local/bin/smd
declare -r KEEP_RE='^wd-remote-access(@.*)?\.service$'
declare -r WD_MANAGER_AFFINITY=/etc/systemd/system.conf.d/radiod-cpu-affinity.conf     ### written by wd-cpu-apply.sh
declare -r SIGMOND_MANAGER_AFFINITY=/etc/systemd/system.conf.d/sigmond-cpu-affinity.conf
declare -r GRUB_ISOLATION=/etc/default/grub.d/sigmond-cpu-isolation.cfg

DRY_RUN=no
YES=no
BUNDLE=""
PROFILE=wd
REPORTER="" GRID="" CALLSIGN=""
RC=0

### ---------------------------------------------------------------- helpers
log()  { echo "[$(date -u +%H:%M:%SZ)] $*" | tee -a "${LOG:-/dev/null}"; }
ok()   { log "  OK    $*"; }
warn() { log "  WARN  $*"; }
bad()  { log "  FAIL  $*"; RC=1; }
die()  { log "FATAL: $*"; exit 3; }
run()  {
    log "+ $*"
    [[ ${DRY_RUN} == yes ]] && return 0
    "$@" 2>&1 | tee -a "${LOG:-/dev/null}"
    return "${PIPESTATUS[0]}"
}
confirm() {
    [[ ${YES} == yes || ${DRY_RUN} == yes ]] && return 0
    local reply
    read -r -p "$* [y/N] " reply
    [[ ${reply} == [yY]* ]]
}
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

newest_bundle() { ls -d "${WORK_ROOT}"/bundle-* 2>/dev/null | sort | tail -1; }

need_bundle() {
    [[ -n ${BUNDLE} ]] || BUNDLE=$(newest_bundle)
    [[ -d ${BUNDLE} ]] || die "no bundle dir (run: $0 bundle)"
    ( cd "${BUNDLE}" && sudo -n sha256sum -c --quiet SHA256SUMS ) || die "bundle checksum mismatch in ${BUNDLE}"
}
need_marker() {   ### $1 = marker prefix that the previous phase leaves in the bundle
    ls "${BUNDLE}/$1"-* >/dev/null 2>&1 || die "no $1 marker in ${BUNDLE}: run the earlier phase first"
}
mark() { [[ ${DRY_RUN} == yes ]] || touch "${BUNDLE}/$1-$(date -u +%Y%m%dT%H%M%SZ)"; }

ncpus() { nproc --all; }
all_cpus() { echo "0-$(( $(ncpus) - 1 ))"; }

### Expand "0-3,8,10-11" (or space separated) to one CPU number per line
expand_cpus() {
    local tok
    for tok in ${1//,/ }; do
        if [[ ${tok} == *-* ]]; then seq "${tok%-*}" "${tok#*-}"; else echo "${tok}"; fi
    done
}
### Collapse CPU numbers on stdin to "0-3,8,10-11"
collapse_cpus() {
    sort -n -u | awk 'NR==1{s=p=$1;next} $1==p+1{p=$1;next} {printf "%s%s,", s, (s==p?"":"-"p); s=p=$1} END{if(NR) printf "%s%s\n", s, (s==p?"":"-"p)}'
}

### radiod's CPUs = union of AllowedCPUs over every sigmond radiod drop-in
radiod_cpus() {
    local f c out=""
    for f in /etc/systemd/system/radiod@*.service.d/*.conf; do
        c=$(sed -n 's/^AllowedCPUs=\(.\+\)$/\1/p' "${f}" | tail -1)
        [[ -n ${c} ]] && out+=" ${c// /,}"
    done
    [[ -n ${out} ]] && expand_cpus "${out// /,}" | collapse_cpus
}
other_cpus() {
    local r; r=$(radiod_cpus)
    [[ -n ${r} ]] || return 1
    comm -23 <(seq 0 $(( $(ncpus) - 1 )) | sort) <(expand_cpus "${r}" | sort) | collapse_cpus
}

wd_conf_value() {  ### $1 = variable name in wsprdaemon.conf (simple NAME="value" lines only)
    sed -n "s/^[[:space:]]*$1=[\"']\{0,1\}\([^\"' #]*\).*/\1/p" "${WD_HOME}/wsprdaemon.conf" 2>/dev/null | tail -1
}

wd_recorded_wwv() {   ### an uncommented WWV/WWVB band in any WSPR_SCHEDULE line
    grep -vE '^[[:space:]]*#' "${WD_HOME}/wsprdaemon.conf" 2>/dev/null | grep -qE ',(WWVB|WWV_[0-9_]+),'
}

### PSWS: the key the GRAPE upload pipeline will really use, and a login-only test with exactly that key.
### Rob 2026-11-12: a converted station keeps id_rsa_wsprdaemon as hs-uploader's [identity] key (the WD gateways
### know it), but PSWS knows only the key registered at its portal (KJ6MKI: id_ed25519_host; id_rsa_wsprdaemon
### is REFUSED).  `smd psws verify` tests sigmond's idea of the host key, which can differ from the key the
### grape-psws pipeline inherits, so test the pipeline's own key with IdentitiesOnly (no fallback to another key).
psws_station_id() {
    sudo -n python3.11 -c 'import tomllib,sys; d=tomllib.load(open("/etc/sigmond/site-profile.toml","rb")).get("psws",{}); print(d.get("station_id","") if d.get("enabled") else "")' 2>/dev/null
}
grape_upload_key() {   ### prints the ssh key grape-psws will use, or nothing when no grape-psws pipeline exists
    sudo -n python3.11 - <<'EOF' 2>/dev/null
import glob, tomllib
main = "/etc/hs-uploader/pipelines.toml"
try:
    m = tomllib.load(open(main, "rb"))
except OSError:
    m = {}
ident = m.get("identity", {}).get("ssh_key_file", "/etc/hs-uploader/keys/id_ed25519_host")
for f in [main] + sorted(glob.glob("/etc/hs-uploader/pipelines.d/*.toml")):
    try:
        d = tomllib.load(open(f, "rb"))
    except (OSError, tomllib.TOMLDecodeError):
        continue
    for p in d.get("pipeline", []):
        t = p.get("transport", {})
        if t.get("type") == "psws_dataset":
            print(t.get("ssh_key_file") or ident)
            raise SystemExit
EOF
}
check_psws_key() {   ### $1 = report level for a refused key: bad (verify) or warn (post, before the operator registers it)
    local level=${1:-bad} sid key
    sid=$(psws_station_id)
    [[ -n ${sid} ]] || { log "PSWS not enabled in /etc/sigmond/site-profile.toml: no GRAPE upload to check"; return 0; }
    key=$(grape_upload_key)
    [[ -n ${key} ]] || { ${level} "PSWS ${sid} enabled but hs-uploader has no grape-psws pipeline (pipelines.toml or pipelines.d)"; return 0; }
    sudo -n test -f "${key}" || { ${level} "grape-psws key ${key} does not exist"; return 0; }
    if echo bye | sudo -n -u hsupload sftp -q -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=20 \
            -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
            -i "${key}" "${sid}@pswsnetwork.eng.ua.edu" >/dev/null 2>&1; then
        ok "PSWS login as ${sid} with grape-psws's own key ${key##*/} (login only, nothing uploaded)"
    else
        ${level} "PSWS refuses ${sid} with grape-psws's key ${key}: register this public key at https://pswsnetwork.eng.ua.edu/ (station ${sid}):"
        sudo -n cat "${key}.pub" 2>/dev/null | tee -a "${LOG:-/dev/null}"
    fi
}

### Every WsprDaemon/legacy-ka9q unit present on this host (never wd-remote-access@*)
legacy_units() {
    systemctl list-unit-files --no-legend --no-pager 2>/dev/null | awk '{print $1}' \
      | grep -E '^(wsprdaemon|wd-cpu-freq|wd-resctrl|wd-irq-affinity|wd-fftw-wisdom|wd-radiod-watchdog|wd-disk-monitor|dropmon|ft[248]-(decode|record)|pskreporter|wspr-decoded|ka9q-web|radiod)(@.*)?\.(service|timer)$' \
      | grep -vE "${KEEP_RE}" | grep -v '@\.\(service\|timer\)$'
    ### instantiated template units only appear among loaded units
    systemctl list-units --all --no-legend --no-pager --plain 2>/dev/null | awk '{print $1}' \
      | grep -E '^(radiod|pskreporter|ka9q-web|ft[248]-(decode|record))@.+\.service$'
}

### ================================================================= check
cmd_check() {
    LOG=/dev/null
    log "### wd-to-sigmond check on $(hostname) — read-only"
    . /etc/os-release
    log "os: ${PRETTY_NAME}, kernel $(uname -r), $(ncpus) CPUs: $(lscpu | sed -n 's/^Model name: *//p')"
    case "${ID}:${VERSION_ID}" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ok "OS is one sigmond's bare-metal guide supports" ;;
        *) bad "OS ${PRETTY_NAME} is not in sigmond's bare-metal list (Debian 12/13, Ubuntu 22.04+)" ;;
    esac
    [[ $(uname -m) == x86_64 ]] && ok "x86-64" || bad "arch $(uname -m): sigmond's bare-metal path is x86-64"

    [[ -f ${WD_HOME}/wsprdaemon.conf ]] && ok "wsprdaemon.conf at ${WD_HOME}" || bad "no ${WD_HOME}/wsprdaemon.conf"
    local rid grid
    rid=$(wd_conf_value REPORTER_ID); grid=$(wd_conf_value REPORTER_GRID)
    log "reporter from wsprdaemon.conf: '${rid:-?}' grid '${grid:-?}' (override with install --reporter/--grid)"

    local rx; rx=$(lsusb | grep -cE '04b4:00f[13]')
    [[ ${rx} -ge 1 ]] && ok "${rx} RX888 on USB" || bad "no RX888 on USB: this script converts local-RX888 stations only"
    [[ ${rx} -gt 1 ]] && warn "${rx} RX888s: multi-radiod stations were never converted this way; plan each radiod by hand"
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ $(cat "${d}/idVendor" 2>/dev/null) == 04b4 ]] || continue
        [[ $(cat "${d}/speed") == 5000 ]] && ok "RX888 $(basename "${d}") at 5 Gbps" || warn "RX888 $(basename "${d}") at $(cat "${d}/speed") Mbps"
    done

    ### What the WD conf runs that sigmond will NOT reproduce
    grep -vE '^[[:space:]]*#' "${WD_HOME}/wsprdaemon.conf" 2>/dev/null | grep -qE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:8073|KIWI_' \
        && warn "wsprdaemon.conf lists KiwiSDR receivers: sigmond does not decode from Kiwis; they stop with WD"
    grep -vE '^[[:space:]]*#' "${WD_HOME}/wsprdaemon.conf" 2>/dev/null | grep -qE 'MERGE_' \
        && warn "MERGE_ receivers in use: sigmond has no MERGE; only the RX888's own spots continue"
    grep -vE '^[[:space:]]*#' "${WD_HOME}/wsprdaemon.conf" 2>/dev/null | grep -qE 'WWV(B|_[0-9])|CHU' \
        && log "  INFO  WWV/GRAPE recording in use: install adds hf-timestd to take it over; re-enroll PSWS ids"

    ### Things that bit KJ6MKI
    if [[ ${ID}:${VERSION_ID} == ubuntu:22.04 ]] && ! dpkg -s python3.11-dev >/dev/null 2>&1; then
        warn "python3.11-dev missing: hf-timestd's systemd-python needs Python.h (prep installs it)"
    fi
    [[ -f ${WD_MANAGER_AFFINITY} ]] && warn "WD manager CPUAffinity $(sed -n 's/^CPUAffinity=//p' "${WD_MANAGER_AFFINITY}") in ${WD_MANAGER_AFFINITY}: would let every unpinned process onto sigmond's radiod cores (prep removes it)"
    systemctl is-enabled -q irqbalance 2>/dev/null && warn "irqbalance enabled: it would undo sigmond's IRQ placement (post masks it)"
    local u
    for u in wd-cpu-freq wd-resctrl wd-irq-affinity; do
        systemctl is-enabled -q "${u}" 2>/dev/null && log "  INFO  ${u} enabled (prep disables it and undoes what it applied)"
    done
    ip -4 -o addr show scope global | awk '{print $4}' | grep -vqE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)' \
        && warn "a public IPv4 address is on this host: smd bringup refuses until /etc/sigmond/allow-public-ip exists"
    local free_gb; free_gb=$(df -BG --output=avail /opt | tail -1 | tr -dc 0-9)
    [[ ${free_gb} -ge 20 ]] && ok "${free_gb} GB free under /opt" || bad "${free_gb} GB free under /opt: want 20+"
    local tunnels; tunnels=$(systemctl list-units --no-legend --plain 'wd-remote-access@*' | awk '$4=="running"{print $1}' | tr '\n' ' ')
    [[ -n ${tunnels} ]] && ok "RAC tunnels running (kept throughout): ${tunnels}" || warn "no wd-remote-access tunnel running: you may lose remote access"
    [[ -d ${SIGMOND_BASE}/sigmond ]] && log "  INFO  sigmond already present at ${SIGMOND_BASE}/sigmond"
    log "legacy units found:"; legacy_units | sort -u | sed 's/^/    /'
    [[ ${RC} == 0 ]] && log "CHECK: no blockers" || log "CHECK: blockers above"
    return ${RC}
}

### ================================================================= bundle
cmd_bundle() {
    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    BUNDLE=${WORK_ROOT}/bundle-${stamp}
    [[ -e ${BUNDLE} ]] && die "${BUNDLE} exists"
    mkdir -p "${BUNDLE}" && cd "${BUNDLE}" || die "cannot create ${BUNDLE}"
    LOG=${BUNDLE}/bundle.log
    log "### bundle: ${BUNDLE}"
    local p paths
    tar_if() {   ### $1 = tar name, rest = paths relative to / ; skips the ones that do not exist
        local name=$1; shift
        paths=(); for p in "$@"; do [[ -e /${p} ]] && paths+=("${p}"); done
        [[ ${#paths[@]} -gt 0 ]] || { log "  (nothing for ${name})"; return 0; }
        sudo -n tar -cpf "${name}" -C / "${paths[@]}" || die "tar ${name} failed"
        log "  ${name}: ${paths[*]}"
    }
    tar_if etc-radio.tar             etc/radio
    tar_if etc-wsprdaemon.tar        etc/wsprdaemon
    tar_if etc-systemd-system.tar    etc/systemd/system etc/systemd/system.conf.d
    tar_if etc-cron.tar              etc/cron.d etc/cron.daily etc/logrotate.d
    tar_if etc-udev.tar              etc/udev/rules.d
    tar_if etc-misc.tar              etc/sysctl.d etc/default/watchdog etc/modprobe.d etc/wd-cpu-plan.conf etc/default/grub etc/default/grub.d
    tar_if etc-fftw.tar              etc/fftw
    tar_if etc-wd-remote-access.tar  etc/wd-remote-access
    [[ -f etc-wd-remote-access.tar ]] && sudo -n chmod 600 etc-wd-remote-access.tar
    tar_if usr-local.tar             usr/local/bin usr/local/sbin usr/local/lib usr/local/share/ka9q-radio usr/local/share/ka9q-web
    tar_if var-lib-ka9q-radio.tar    var/lib/ka9q-radio/wisdom var/lib/ka9q-radio/fft.log var/lib/ka9q-radio/save
    tar -cpf home-config.tar -C "$(dirname "${WD_HOME}")" "$(basename "${WD_HOME}")/wsprdaemon.conf" \
        $(cd "$(dirname "${WD_HOME}")" && ls -d "$(basename "${WD_HOME}")"/wsprdaemon.conf.bak* 2>/dev/null) || die "home-config.tar failed"
    {
        echo "# captured $(date -u +%FT%TZ) on $(hostname), $(uptime -p)"
        echo "## os"; . /etc/os-release; echo "${PRETTY_NAME} $(uname -r)"; cat /proc/cmdline
        echo "## wsprdaemon tree"; git -C "${WD_HOME}" log -1 --format='%H %cd %s' 2>&1; git -C "${WD_HOME}" remote get-url origin 2>&1
        echo "## radiod binary"; ls -la /usr/local/sbin/radiod 2>&1; sha256sum /usr/local/sbin/radiod 2>&1
        echo "## lsusb"; lsusb
        echo "## crontab $(id -un)"; crontab -l 2>&1
        echo "## crontab root"; sudo -n crontab -l 2>&1
        echo "## PID 1 affinity"; grep Cpus_allowed_list /proc/1/status
        echo "## irqbalance"; systemctl is-enabled irqbalance 2>&1
        echo "## resctrl"; for s in /sys/fs/resctrl/schemata /sys/fs/resctrl/*/schemata; do echo "${s}: $(cat "${s}")"; done
    } > state.txt
    systemctl list-unit-files --no-pager --no-legend > unit-files.txt
    systemctl list-units --all --no-pager --no-legend > units-all.txt
    local u
    : > unit-state.txt
    for u in $(legacy_units | sort -u); do
        printf '%-44s enabled=%-10s active=%s\n' "${u}" "$(systemctl is-enabled "${u}" 2>&1)" "$(systemctl is-active "${u}" 2>&1)" >> unit-state.txt
    done
    ### start order for restore: tuning oneshots, radiod, the WD supervisor, then the rest
    { grep -E '^wd-(cpu-freq|resctrl|irq-affinity)' unit-state.txt; grep -E '^radiod@' unit-state.txt
      grep -E '^wsprdaemon\.' unit-state.txt; grep -vE '^(wd-(cpu-freq|resctrl|irq-affinity)|radiod@|wsprdaemon\.)' unit-state.txt; } \
        | awk '{print $1}' > legacy-order.txt
    sudo -n sha256sum ./*.tar state.txt unit-files.txt units-all.txt unit-state.txt legacy-order.txt > SHA256SUMS
    sudo -n chown -R "$(id -un)": "${BUNDLE}"; chmod -R go-rwx "${BUNDLE}"
    log "$(du -sh "${BUNDLE}" | cut -f1) in ${BUNDLE}"; cat unit-state.txt
    mark BUNDLED
    log "BUNDLE OK — next: $0 handover"
}

### ================================================================= handover
cmd_handover() {
    need_bundle; LOG=${BUNDLE}/handover.log
    log "### handover — stop and disable the WsprDaemon stack (bundle ${BUNDLE})"
    confirm "Stop and disable WsprDaemon on $(hostname)? Spots stop until sigmond is up." || die "not confirmed"
    local u
    ### supervisor first (its ExecStop kills its own children), radiod last
    for u in wsprdaemon.service $(awk '{print $1}' "${BUNDLE}/unit-state.txt" | grep -vE '^(wsprdaemon\.service|radiod@)') \
             $(awk '{print $1}' "${BUNDLE}/unit-state.txt" | grep '^radiod@'); do
        [[ ${u} =~ ${KEEP_RE} ]] && continue
        [[ ${u} == wd-cpu-freq.service || ${u} == wd-resctrl.service || ${u} == wd-irq-affinity.service ]] && continue   ### prep handles these
        systemctl is-active -q "${u}" && run timeout 300 sudo -n systemctl stop "${u}"
        systemctl is-enabled -q "${u}" 2>/dev/null && run sudo -n systemctl disable "${u}"
    done
    ### WD's crontab entries restart the stack: comment them out (restore puts the crontab back from state.txt)
    if crontab -l 2>/dev/null | grep -qE '^[^#].*wsprdaemon'; then
        crontab -l > "${BUNDLE}/crontab.$(id -un).txt"
        [[ ${DRY_RUN} == yes ]] || crontab -l | sed -E 's/^([^#].*wsprdaemon.*)$/#wd-to-sigmond# \1/' | crontab -
        log "commented the wsprdaemon lines in $(id -un)'s crontab"
    fi
    sleep 3
    local stray
    stray=$( { pgrep -a -x 'radiod|wd-record|pcmrecord|ka9q-web|wd-jt9|pskreporter-sender'
               pgrep -af 'wsprdaemon\.sh -A|wd-ft-decode|http\.server 8088'; } 2>/dev/null | grep -vE 'pgrep|wd-to-sigmond|bash -c' )
    [[ -z ${stray} ]] || { log "stray processes:"; echo "${stray}" | tee -a "${LOG}"; RC=4; }
    log "RX888 on USB: $(lsusb | grep -c '04b4:00f')   tunnels: $(systemctl list-units --no-legend --plain 'wd-remote-access@*' | awk '{print $1"="$4}' | tr '\n' ' ')"
    [[ ${RC} == 0 ]] || die "handover incomplete (rc=${RC})"
    mark HANDED-OVER
    log "HANDOVER OK — next: $0 prep"
}

### ================================================================= prep
cmd_prep() {
    need_bundle; need_marker HANDED-OVER; LOG=${BUNDLE}/prep.log
    log "### prep — take WsprDaemon's host tuning off"
    pgrep -x radiod >/dev/null && die "a radiod is still running"

    log "## 1. legacy radiod confs out of sigmond's /etc/radio/radiod@*.conf glob"
    local f leg=/etc/radio.legacy-wd
    run sudo -n install -d -m 2775 "${leg}"
    for f in /etc/radio/radiod@*.conf /etc/radio/radiod@*.conf.d; do run sudo -n mv "${f}" "${leg}/"; done
    ### sigmond 1256c4e+ treats a radiod@ instance with no conf as orphaned and never enables or starts it
    local u

    log "## 2. stop + disable the wd-* tuning oneshots, then undo what they applied"
    for u in wd-cpu-freq wd-resctrl wd-irq-affinity; do
        systemctl list-unit-files --no-legend "${u}.service" | grep -q . && run sudo -n systemctl disable --now "${u}.service"
    done
    local d
    for d in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
        [[ ${DRY_RUN} == yes ]] || sudo -n sh -c "cat ${d}/cpuinfo_max_freq > ${d}/scaling_max_freq; cat ${d}/cpuinfo_min_freq > ${d}/scaling_min_freq"
    done
    log "scaling_max_freq now: $(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
    mountpoint -q /sys/fs/resctrl && run sudo -n umount /sys/fs/resctrl

    log "## 3. WD's systemd manager CPUAffinity (it kept WD's radiod cores clear, and lets everything onto sigmond's)"
    if [[ -f ${WD_MANAGER_AFFINITY} ]]; then
        run sudo -n mv "${WD_MANAGER_AFFINITY}" "${BUNDLE}/"
        run sudo -n systemctl daemon-reexec
        ### daemon-reexec does not widen PID 1 (seen on KJ6MKI); do it and its inheritors by hand
        local old; old=$(awk '/^Cpus_allowed_list/{print $2}' /proc/1/status)
        if [[ ${old} != "$(all_cpus)" ]]; then
            local p n=0
            for p in $(ps -eo pid=); do
                [[ $(awk '/^PPid/{print $2}' /proc/"${p}"/status 2>/dev/null) == 2 ]] && continue
                [[ $(awk '/^Cpus_allowed_list/{print $2}' /proc/"${p}"/status 2>/dev/null) == "${old}" ]] || continue
                [[ ${DRY_RUN} == yes ]] || sudo -n taskset -apc "$(all_cpus)" "${p}" >/dev/null 2>&1 && n=$((n+1))
            done
            log "re-affined ${n} processes from ${old} to $(all_cpus)"
        fi
    fi

    log "## 4. packages sigmond's components build against"
    . /etc/os-release
    if [[ ${ID}:${VERSION_ID} == ubuntu:22.04 ]] && ! dpkg -s python3.11-dev >/dev/null 2>&1; then
        run sudo -n apt-get install -y python3.11-dev || warn "python3.11-dev did not install: hf-timestd will fail its build preflight"
    fi
    mark PREPPED
    log "PREP OK — next: $0 install"
}

### ================================================================= install
cmd_install() {
    need_bundle; need_marker PREPPED; LOG=${BUNDLE}/install.log
    REPORTER=${REPORTER:-$(wd_conf_value REPORTER_ID)}
    GRID=${GRID:-$(wd_conf_value REPORTER_GRID)}
    CALLSIGN=${CALLSIGN:-$(echo "${REPORTER}" | sed 's|[/-].*||')}
    [[ -n ${REPORTER} && -n ${GRID} ]] || die "reporter/grid unknown: pass --reporter and --grid"
    log "### install — sigmond for reporter ${REPORTER}, grid ${GRID}, callsign ${CALLSIGN}, profile ${PROFILE}"
    if [[ ! -d ${SIGMOND_BASE}/sigmond/.git ]]; then
        run sudo -n mkdir -p "${SIGMOND_BASE}"
        run sudo -n chown "$(id -un)" "${SIGMOND_BASE}"
        run git clone https://github.com/HamSCI/sigmond "${SIGMOND_BASE}/sigmond"
        ( cd "${SIGMOND_BASE}/sigmond" && run ./install.sh ) || die "sigmond install.sh failed"
    else
        log "sigmond already cloned; leaving it as is"
    fi
    ### bring-up runs in a new group context: install.sh just added us to the sigmond group
    local args=(bringup "${PROFILE}" --reporter "${REPORTER}" --grid "${GRID}" --callsign "${CALLSIGN}" --skip-hardware-check)
    [[ ${YES} == yes ]] && args+=(--non-interactive)
    [[ ${DRY_RUN} == yes ]] && args+=(--dry-run)
    log "+ SIGMOND_NO_RAC=1 smd ${args[*]}   (can take up to an hour: radiod plans its FFTs first)"
    sg sigmond -c "SIGMOND_NO_RAC=1 ${SMD} $(printf '%q ' "${args[@]}")" 2>&1 | tee -a "${LOG}"
    local rc=${PIPESTATUS[0]}
    [[ ${rc} == 0 ]] || die "smd bringup exited ${rc}: read ${LOG}; rerun is safe (bring-up is idempotent)"
    ### never --with-optional for a conversion; add GRAPE timing only where WD recorded WWV
    if wd_recorded_wwv; then
        log "wsprdaemon.conf recorded WWV: adding hf-timestd"
        ### hf-timestd depends on hamsci-physics (editable path dep): install it first (KJ6MKI 2026-11-12)
        run sg sigmond -c "${SMD} install hamsci-physics --yes" || warn "hamsci-physics install failed: read ${LOG}"
        run sg sigmond -c "${SMD} install hf-timestd --yes" || warn "hf-timestd install failed: read ${LOG}"
        run sg sigmond -c "${SMD} config init hf-timestd --non-interactive" || warn "hf-timestd config init failed"
        run sg sigmond -c "${SMD} config init hamsci-physics --non-interactive" || warn "hamsci-physics config init failed (grape-psws stays unrendered without it)"
    fi
    mark INSTALLED
    log "INSTALL OK — next: $0 post"
}

### ================================================================= post
fix_checkout_ownership() {
    log "## checkout ownership (git refuses fetch/pull on mixed ownership; KJ6MKI had root and foreign files in .git)"
    local repo owner n
    for repo in "${SIGMOND_BASE}"/*/; do
        [[ -d ${repo}.git ]] || continue
        owner=$(stat -c %U "${repo}")
        if [[ ${owner} == root ]]; then
            run sudo -n chown -R sigmond:sigmond "${repo}"
            continue
        fi
        n=$(sudo -n find "${repo}.git" ! -user "${owner}" | wc -l)
        [[ ${n} -gt 0 ]] && run sudo -n chown -R --reference="${repo}" "${repo}.git"
    done
}

fix_ft_ssrc_collisions() {
    ### WD's radiod template carries 40.680 MHz in both [FT8] and [FT4].  The same frequency with the same
    ### preset/rate/encoding hashes to ONE ssrc in ka9q-python, which silently keeps one mode (FT4 won on
    ### KJ6MKI, so 8 m FT8 never decoded).  FT8 is the mode on those channels: drop the frequency from FT4.
    log "## FT4/FT8 SSRC collisions in psk-recorder config"
    local dup conf
    for dup in $(${SMD} status 2>&1 | strip_ansi | sed -n 's/.*SSRC collision: FT4 \([0-9]*\) Hz duplicates FT8.*/\1/p' | sort -u); do
        local pretty; pretty=$(printf '%d' "${dup}" | sed -E ':a;s/^([0-9]+)([0-9]{3})/\1_\2/;ta')
        for conf in /etc/psk-recorder/*.toml; do
            [[ ${conf} == *.toml ]] || continue
            grep -q '^\[radiod\.ft4\]' "${conf}" || continue
            run sudo -n cp -a "${conf}" "${conf}.wd-to-sigmond-$(date -u +%Y%m%d)"
            [[ ${DRY_RUN} == yes ]] && continue
            ### inside the [radiod.ft4] table only: delete the number (with or without _ separators) and say why
            sudo -n python3 - "${conf}" "${dup}" "${pretty}" <<'PY'
import re, sys
path, plain, pretty = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split('\n')
out, in_ft4, changed = [], False, False
pat = re.compile(r'(?<![0-9_])(%s|%s)\s*,?' % (re.escape(plain), re.escape(pretty)))
for line in lines:
    if line.startswith('['):
        in_ft4 = line.strip().startswith('[radiod.ft4]')
    if in_ft4 and not line.lstrip().startswith('#') and pat.search(line.split('#')[0]):
        code, _, comment = line.partition('#')
        code = pat.sub('', code, count=1)
        out.append('# wd-to-sigmond: %s removed from FT4 - same ssrc as the FT8 channel' % pretty)
        if code.strip():
            out.append(code.rstrip() + ('  #' + comment if comment else ''))
        changed = True
        continue
    out.append(line)
if changed:
    open(path, 'w').write('\n'.join(out))
print(('fixed ' if changed else 'no change in ') + path)
PY
        done
        local unit
        for unit in $(systemctl list-units --no-legend --plain 'psk-recorder@*' | awk '{print $1}'); do run sudo -n systemctl restart "${unit}"; done
    done
}

fix_manager_affinity() {
    log "## systemd manager CPUAffinity = sigmond's other pool, so nothing unpinned starts on radiod's cores"
    local other; other=$(other_cpus) || { warn "no radiod drop-in yet: cannot compute the other pool"; return; }
    local want="[Manager]
# written by wd-to-sigmond.sh: radiod owns $(radiod_cpus); everything else defaults to ${other}
CPUAffinity=${other//,/ }"
    if [[ $(cat "${SIGMOND_MANAGER_AFFINITY}" 2>/dev/null) != "${want}" ]]; then
        log "+ write ${SIGMOND_MANAGER_AFFINITY}: CPUAffinity=${other}"
        [[ ${DRY_RUN} == yes ]] || { sudo -n install -d /etc/systemd/system.conf.d; echo "${want}" | sudo -n tee "${SIGMOND_MANAGER_AFFINITY}" >/dev/null; }
    fi
    [[ ${DRY_RUN} == yes ]] || sudo -n taskset -pc "${other}" 1 >/dev/null
    log "PID 1 now: $(awk '/^Cpus_allowed_list/{print $2}' /proc/1/status) (the rest follows at the reboot)"
}

fix_kernel_isolation() {
    log "## kernel isolation: isolcpus + nohz_full + rcu_nocbs on radiod's cores (FFT core included)"
    local topo=/etc/sigmond/topology.toml
    if ! sudo -n grep -q '^write_kernel_isolation *= *true' "${topo}"; then
        if sudo -n grep -q '^\[cpu_affinity\]' "${topo}"; then
            run sudo -n sed -i '/^\[cpu_affinity\]/a write_kernel_isolation = true' "${topo}"
        else
            [[ ${DRY_RUN} == yes ]] || printf '\n[cpu_affinity]\nwrite_kernel_isolation = true\n' | sudo -n tee -a "${topo}" >/dev/null
            log "+ appended [cpu_affinity] write_kernel_isolation = true to ${topo}"
        fi
    fi
    run "${SMD}" admin diag cpu-affinity --apply
    if [[ -f ${GRUB_ISOLATION} ]]; then
        ok "$(grep -o 'isolcpus=[^ "]*' "${GRUB_ISOLATION}") staged in ${GRUB_ISOLATION}"
        grep -q "$(grep -o 'isolcpus=[^ "]*' "${GRUB_ISOLATION}")" /boot/grub/grub.cfg 2>/dev/null || run sudo -n update-grub
    else
        bad "no ${GRUB_ISOLATION} after smd admin diag cpu-affinity --apply"
    fi
    log "## IRQs: irqbalance off, sigmond herds every movable IRQ to the first non-radiod core pair"
    systemctl list-unit-files --no-legend irqbalance.service | grep -q . && ! [[ $(systemctl is-enabled irqbalance 2>&1) == masked ]] \
        && run sudo -n systemctl mask --now irqbalance.service
    for u in sigmond-guest-irq-affinity.service; do
        systemctl is-enabled -q "${u}" 2>/dev/null || run sudo -n systemctl enable --now "${u}"
    done
}

fix_cpu_freq() {
    ### replaces the wd-cpu-freq clocks prep removed: radiod's cores pinned min==max, the rest capped (powersave).
    ### On amd-pstate active the cap floors at the nominal clock (KJ6MKI: 1.4 GHz asked, ~2.42 GHz real).
    log "## CPU clocks: smd admin diag cpu-freq --apply (smd-cpu-freq.service re-applies at every boot)"
    run "${SMD}" admin diag cpu-freq --apply
    [[ ${DRY_RUN} == yes ]] && return
    systemctl is-enabled -q smd-cpu-freq.service 2>/dev/null && ok "smd-cpu-freq.service enabled" \
        || bad "smd-cpu-freq.service not enabled: the clock policy will not survive the reboot"
    local c d
    for c in $(expand_cpus "$(radiod_cpus)"); do
        d=/sys/devices/system/cpu/cpu${c}/cpufreq
        log "cpu${c}: $(cat "${d}/scaling_governor") min $(cat "${d}/scaling_min_freq") max $(cat "${d}/scaling_max_freq") kHz"
    done
}

fix_igmp_querier() {
    log "## IGMP querier (130 s root listen; smd elevates itself for --listen)"
    local cls
    cls=$("${SMD}" admin diag net --listen 130 2>&1 | strip_ansi | sed -n 's/^ *Classification: *//p')
    log "network: ${cls:-unknown}"
    if [[ ${cls} == lan-needs-querier* ]]; then
        run "${SMD}" install igmp-querier --yes
        run "${SMD}" admin diag net --listen 130
    fi
}

fix_upload_routing() {
    ### Rob 2026-11-12: a converted station uploads ONLY to the WD servers, as it did under WD.  WD30's
    ### wsprnet-forwarder and the elected pskreporter-forwarder post onward; the station posts nowhere directly.
    log "## uploads go only to the WD servers, which forward to wsprnet.org and pskreporter.info"
    local rid; rid=${REPORTER:-$(wd_conf_value REPORTER_ID)}
    [[ -n ${rid} ]] || { bad "no reporter id: cannot set per-instance upload routing"; return; }
    run "${SMD}" config reporters --wsprnet-proxy on
    run "${SMD}" config upload psk-recorder "${rid}" --on --via server-merge
    systemctl list-units --all --no-legend --plain 'meteor-scatter@*' | grep -q . \
        && run "${SMD}" config upload meteor-scatter "${rid}" --on --via deposit
    local u
    for u in hs-uploader.service $(systemctl list-units --no-legend --plain 'psk-recorder@*' 'meteor-scatter@*' | awk '{print $1}'); do
        run sudo -n systemctl restart "${u}"
    done
    [[ ${DRY_RUN} == yes ]] && return
    sleep 10
    ### a hand-written legacy /etc/hs-uploader/pipelines.toml is not re-rendered (KJ6MKI): catch a direct wsprnet leg
    sudo -n journalctl -u hs-uploader --since -1min --no-pager -o cat | grep -q 'pipeline(s):.*wsprnet' \
        && bad "hs-uploader still runs a direct wsprnet pipeline: /etc/hs-uploader/pipelines.toml is legacy; set forward_to_wsprnet on the tar transport and drop that pipeline"
    sudo -n journalctl -u 'psk-recorder@*' --since -1min --no-pager -o cat | grep -q 'direct PSKReporter uploader disabled' \
        && ok "psk-recorder: server-merge, forward_to_pskreporter=True" || warn "psk-recorder did not confirm server-merge delivery"
}

fix_psws() {
    ### WD's GRAPE ids carry over; the station key must be registered at the PSWS portal by the operator
    systemctl list-unit-files --no-legend timestd-core-recorder.service | grep -q . || return 0
    log "## PSWS / GRAPE: carry over WD's station + instrument ids, then test the GRAPE upload key"
    local sid iid; sid=$(wd_conf_value PSWS_STATION_ID); iid=$(wd_conf_value PSWS_DEVICE_ID)
    if [[ -n ${sid} && -n ${iid} ]]; then
        run sg sigmond -c "${SMD} config psws --station ${sid} --instrument hf-timestd=${iid}"
    elif [[ -z $(psws_station_id) ]]; then
        warn "hf-timestd installed but no PSWS_STATION_ID/PSWS_DEVICE_ID in wsprdaemon.conf: run smd config psws --station Sxxxxxx --instrument hf-timestd=NNN"
        return 0
    fi
    ### hamsci-physics' daily GRAPE packager is linked by install but was left inactive on KJ6MKI (no dataset, no upload)
    systemctl list-unit-files --no-legend grape-daily.timer | grep -q . && ! systemctl is-active -q grape-daily.timer \
        && run sudo -n systemctl enable --now grape-daily.timer
    check_psws_key warn
}

cmd_post() {
    need_bundle; need_marker INSTALLED; LOG=${BUNDLE}/post.log
    log "### post — the fixes KJ6MKI needed after bring-up"
    fix_checkout_ownership
    log "## align every component to the blessed release (installs nothing new; never sigmond-rac)"
    run "${SMD}" align --apply || warn "smd align reported a failure; it names the stale services and the smd restart to run"
    fix_ft_ssrc_collisions
    fix_manager_affinity
    fix_kernel_isolation
    fix_cpu_freq
    fix_igmp_querier

    fix_upload_routing
    fix_psws

    log "## devices sigmond adopted that no client can read"
    if command -v gpsdo-monitor >/dev/null && systemctl is-enabled -q gpsdo-monitor 2>/dev/null; then
        gpsdo-monitor detect 2>&1 | grep -qi 'no leo bodnar\|not supported' && warn "gpsdo-monitor cannot read this GPSDO model; it stays installed (decide per station)"
    fi

    log "## uploads: a repo install holds every upload until released"
    if confirm "Release this station's uploads now (smd sink upload)?"; then run "${SMD}" sink upload; else warn "uploads still held: run 'smd sink upload'"; fi

    log "## status"
    "${SMD}" status 2>&1 | strip_ansi | grep -E '✓|✗|⚠' | tee -a "${LOG}"
    mark POSTED
    log "POST done (rc=${RC}) — next: $0 reboot   (activates the kernel isolation; the RX888 must be on USB 3 after it)"
    return ${RC}
}

### ================================================================= reboot / verify
cmd_reboot() {
    need_bundle; need_marker POSTED; LOG=${BUNDLE}/reboot.log
    confirm "Reboot $(hostname) now?" || die "not confirmed"
    mark REBOOTED
    log "rebooting; after it: $0 verify"
    run sudo -n systemctl reboot
}

cmd_verify() {
    ### verify also works on a station converted before this script existed (no bundle): it just keeps no log
    [[ -n ${BUNDLE} ]] || BUNDLE=$(newest_bundle)
    if [[ -d ${BUNDLE} ]]; then LOG=${BUNDLE}/verify-$(date -u +%Y%m%dT%H%M%SZ).log; else LOG=/dev/null; DRY_RUN=yes; fi
    log "### verify $(hostname), up since $(uptime -s)"
    local rc rcpus other
    rcpus=$(radiod_cpus); other=$(other_cpus)
    log "radiod CPUs: ${rcpus:-?}   other pool: ${other:-?}"
    local isol nohz rcu
    isol=$(cat /sys/devices/system/cpu/isolated); nohz=$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null)
    rcu=$(grep -o 'rcu_nocbs=[^ ]*' /proc/cmdline | cut -d= -f2)
    [[ ${isol} == "${rcpus}" ]] && ok "isolcpus=${isol}" || bad "isolated '${isol}' != radiod CPUs '${rcpus}'"
    [[ ${nohz} == "${rcpus}" ]] && ok "nohz_full=${nohz} (FFT core has no tick)" || bad "nohz_full '${nohz}' != '${rcpus}'"
    [[ ${rcu} == "${rcpus}" ]] && ok "rcu_nocbs=${rcu}" || bad "rcu_nocbs '${rcu}' != '${rcpus}'"
    local pid1; pid1=$(awk '/^Cpus_allowed_list/{print $2}' /proc/1/status)
    [[ ${pid1} == "${other}" ]] && ok "PID 1 on ${pid1}" || bad "PID 1 on ${pid1}, want ${other}"

    ### clocks: smd-cpu-freq pins radiod's cores min==max; a radiod core still floating means the policy is off
    systemctl is-enabled -q smd-cpu-freq.service 2>/dev/null && ok "smd-cpu-freq.service enabled" || bad "smd-cpu-freq.service not enabled"
    local c fmin fmax
    for c in $(expand_cpus "${rcpus}"); do
        fmin=$(cat /sys/devices/system/cpu/cpu${c}/cpufreq/scaling_min_freq 2>/dev/null); fmax=$(cat /sys/devices/system/cpu/cpu${c}/cpufreq/scaling_max_freq 2>/dev/null)
        [[ -n ${fmin} && ${fmin} == "${fmax}" ]] && ok "cpu${c} pinned at ${fmax} kHz" || bad "cpu${c} not pinned: min ${fmin:-?} max ${fmax:-?} kHz"
    done

    ### IRQs: nothing movable on radiod's cores except the kernel-managed per-CPU queues
    systemctl is-active -q irqbalance 2>/dev/null && bad "irqbalance running" || ok "irqbalance not running"
    local d irq eff name on_radiod=""
    for d in /proc/irq/[0-9]*; do
        irq=${d##*/}; eff=$(cat "${d}/effective_affinity_list" 2>/dev/null) || continue
        name=$(awk -v i="${irq}:" '$1==i{print $NF}' /proc/interrupts)
        [[ -n ${name} ]] || continue
        if comm -12 <(expand_cpus "${eff}" | sort) <(expand_cpus "${rcpus}" | sort) | grep -q .; then
            [[ ${name} =~ q[0-9]+$ ]] && continue      ### nvme/nic per-CPU managed queues cannot move (needs isolcpus=managed_irq)
            on_radiod+=" ${irq}:${name}@${eff}"
        fi
    done
    [[ -z ${on_radiod} ]] && ok "no movable IRQ on radiod's cores" || bad "IRQs on radiod's cores:${on_radiod}"

    for d in /sys/bus/usb/devices/*; do
        [[ $(cat "${d}/idVendor" 2>/dev/null) == 04b4 ]] || continue
        [[ $(cat "${d}/idProduct") == 00f1 && $(cat "${d}/speed") == 5000 ]] && ok "RX888 $(basename "${d}") firmware loaded, 5 Gbps" \
            || bad "RX888 $(basename "${d}") product $(cat "${d}/idProduct") at $(cat "${d}/speed") Mbps"
    done
    local u
    for u in $(systemctl list-units --all --no-legend --plain 'radiod@*' | awk '{print $1}'); do
        local inst=${u#radiod@}; inst=${inst%.service}
        if [[ -f /etc/radio/radiod@${inst}.conf ]]; then
            systemctl is-active -q "${u}" && ok "${u} active" || bad "${u} $(systemctl is-active "${u}")"
        else
            systemctl is-active -q "${u}" || systemctl is-enabled -q "${u}" 2>/dev/null && bad "${u} has no /etc/radio conf but is enabled or running"
        fi
    done
    systemctl --failed --no-legend --plain | awk '{print $1}' | while read -r u; do [[ -n ${u} ]] && warn "failed unit: ${u}"; done
    ### decoders: sigmond's default jt9/wsprd are the ubersdr builds (persistent shared-memory jt9 under jt9_decode -T)
    local b
    for b in jt9 wsprd; do
        [[ $(readlink -f /usr/local/bin/${b}) == */decoders/ubersdr/${b} ]] \
            && ok "${b} -> ubersdr ($(awk '{print $2}' /usr/local/libexec/sigmond/decoders/ubersdr/.provenance 2>/dev/null | cut -c1-9))" \
            || bad "/usr/local/bin/${b} -> $(readlink -f /usr/local/bin/${b}), not sigmond's ubersdr build"
    done
    local st; st=$("${SMD}" status 2>&1 | strip_ansi)
    echo "${st}" | grep -E '✗|⚠' | while read -r l; do warn "smd status: ${l}"; done
    echo "${st}" | grep -q 'no contention' && ok "smd: CPU plan applied, no contention" || bad "smd reports CPU contention"
    echo "${st}" | grep -qE 'lan-capable|single-host-safe' && ok "network: $(echo "${st}" | grep -oE 'lan-capable|single-host-safe' | head -1)"
    ### spots: the recorders log a line per cycle; want some within the last 10 minutes
    local ft wspr
    ft=$(sudo -n journalctl -u 'psk-recorder@*' --since -10min --no-pager -o cat | grep -c 'cycle_batcher.*spots')
    wspr=$(sudo -n journalctl -u 'wspr-recorder@*' --since -10min --no-pager -o cat | grep -c 'spot_sink:cycle')
    [[ ${ft} -gt 0 ]] && ok "${ft} FT cycles batched in 10 min" || bad "no FT cycles in 10 min"
    [[ ${wspr} -gt 0 ]] && ok "${wspr} WSPR cycles in 10 min" || warn "no WSPR cycle in 10 min (wait one 2-min cycle after boot)"
    if systemctl list-unit-files --no-legend grape-daily.timer | grep -q .; then
        systemctl is-active -q grape-daily.timer && ok "grape-daily.timer active (packages each UTC day for PSWS)" || bad "grape-daily.timer inactive: no GRAPE dataset will be built or uploaded"
    fi
    check_psws_key bad
    [[ ${RC} == 0 ]] && { log "VERIFY OK"; mark VERIFIED; } || log "VERIFY found problems (above)"
    return ${RC}
}

### ================================================================= restore
cmd_restore() {
    local check=no
    [[ ${1:-} == --check ]] && check=yes
    need_bundle; LOG=${BUNDLE}/restore-$(date -u +%Y%m%dT%H%M%SZ).log
    log "### restore from ${BUNDLE} ($([[ ${check} == yes ]] && echo CHECK only || echo RESTORE))"
    local bundled_sha; bundled_sha=$(awk '/^[0-9a-f]{64} +\/usr\/local\/sbin\/radiod$/{print $1}' "${BUNDLE}/state.txt")
    local live_sha; live_sha=$(sha256sum /usr/local/sbin/radiod 2>/dev/null | awk '{print $1}')
    log "radiod binary: $([[ ${live_sha} == "${bundled_sha}" ]] && echo same as bundle || echo "differs (live ${live_sha:-missing})")"
    local sig
    sig=$(systemctl list-unit-files --no-legend --no-pager | awk '{print $1}' \
          | grep -E '^(sigmond|smd|hf-timestd|timestd|psk-recorder|wspr-recorder|meteor|hs-uploader|mag-recorder|station-web|gpsdo-monitor|igmp-querier|ka9q-web|grape|hamsci)' | grep -v '@\.')
    sig+=$'\n'$(systemctl list-units --all --no-legend --plain 'radiod@*' 'psk-recorder@*' 'wspr-recorder@*' | awk '{print $1}')
    if [[ ${check} == yes ]]; then
        log "sigmond-side units that restore would stop:"; echo "${sig}" | sort -u | grep . | sed 's/^/    /'
        local t
        for t in etc-radio etc-systemd-system usr-local; do
            [[ -f ${BUNDLE}/${t}.tar ]] || continue
            log "## ${t}.tar vs live: $(sudo -n tar --diff -f "${BUNDLE}/${t}.tar" -C / 2>&1 | grep -vcE 'Mod time differs$|Uid differs$|Gid differs$') differences"
        done
        return 0
    fi
    confirm "Stop sigmond and put $(hostname) back on WsprDaemon?" || die "not confirmed"
    local u pre=${BUNDLE}/pre-restore-$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "${pre}"; echo "${sig}" | sort -u > "${pre}/sigmond-units.txt"
    [[ -d /etc/sigmond ]] && sudo -n tar -cpf "${pre}/etc-sigmond.tar" -C / etc/sigmond
    sudo -n tar -cpf "${pre}/etc-radio.tar" -C / etc/radio 2>/dev/null
    while read -r u; do
        [[ -n ${u} && ! ${u} =~ ${KEEP_RE} ]] || continue
        run sudo -n systemctl stop "${u}"; run sudo -n systemctl disable "${u}"
    done < "${pre}/sigmond-units.txt"
    for f in "${SIGMOND_MANAGER_AFFINITY}" "${GRUB_ISOLATION}"; do [[ -f ${f} ]] && run sudo -n mv "${f}" "${pre}/"; done
    pgrep -x radiod >/dev/null && die "a radiod survived; refusing to restore over it"
    [[ -d /etc/radio ]] && run sudo -n mv /etc/radio "${pre}/etc-radio.live"
    local t
    for t in etc-radio usr-local etc-systemd-system etc-cron etc-udev etc-misc etc-fftw var-lib-ka9q-radio etc-wd-remote-access; do
        [[ -f ${BUNDLE}/${t}.tar ]] && run sudo -n tar --unlink-first -xpf "${BUNDLE}/${t}.tar" -C /
    done
    run tar --unlink-first -xpf "${BUNDLE}/home-config.tar" -C "$(dirname "${WD_HOME}")"
    [[ -f ${BUNDLE}/crontab.$(id -un).txt ]] && run crontab "${BUNDLE}/crontab.$(id -un).txt"
    live_sha=$(sha256sum /usr/local/sbin/radiod | awk '{print $1}')
    [[ ${live_sha} == "${bundled_sha}" ]] || die "restored radiod ${live_sha} != bundled ${bundled_sha}"
    run sudo -n systemctl daemon-reload; run sudo -n udevadm control --reload-rules; run sudo -n update-grub
    for u in $(awk '$2=="enabled=enabled"{print $1}' "${BUNDLE}/unit-state.txt"); do run sudo -n systemctl enable "${u}"; done
    for u in $(cat "${BUNDLE}/legacy-order.txt"); do
        grep -q "^${u} .*active=active" "${BUNDLE}/unit-state.txt" || continue
        run timeout 900 sudo -n systemctl start "${u}"
        [[ ${u} == radiod@* ]] && sleep 5
    done
    for u in $(awk '$3=="active=active"{print $1}' "${BUNDLE}/unit-state.txt"); do
        systemctl is-active -q "${u}" && ok "${u}" || bad "${u} $(systemctl is-active "${u}")"
    done
    log "a reboot drops sigmond's isolcpus from the kernel command line; WD's tuning oneshots were re-enabled above"
    [[ ${RC} == 0 ]] && { log "RESTORE OK"; mark RESTORED; } || log "RESTORE INCOMPLETE"
    return ${RC}
}

### ================================================================= main
[[ ${EUID} == 0 ]] && { echo "run as the WsprDaemon user, not root (smd refuses sudo)"; exit 2; }
CMD=${1:-}; shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --bundle)   BUNDLE=$2; shift 2 ;;
        --dry-run)  DRY_RUN=yes; shift ;;
        --yes|-y)   YES=yes; shift ;;
        --profile)  PROFILE=$2; shift 2 ;;
        --reporter) REPORTER=$2; shift 2 ;;
        --grid)     GRID=$2; shift 2 ;;
        --callsign) CALLSIGN=$2; shift 2 ;;
        --check)    RESTORE_CHECK=--check; shift ;;
        *) echo "unknown option $1"; exit 2 ;;
    esac
done
mkdir -p "${WORK_ROOT}"
case ${CMD} in
    check)    cmd_check ;;
    bundle)   cmd_bundle ;;
    handover) cmd_handover ;;
    prep)     cmd_prep ;;
    install)  cmd_install ;;
    post)     cmd_post ;;
    reboot)   cmd_reboot ;;
    verify)   cmd_verify ;;
    restore)  cmd_restore "${RESTORE_CHECK:-}" ;;
    *) sed -n '2,32p' "$0"; exit 2 ;;
esac
