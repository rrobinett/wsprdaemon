##########################################################################################################################################################
########## Section which reports (and optionally applies) the radiod CPU / cache / IRQ layout  ############################################################
##########################################################################################################################################################
###
### radiod competes with the WSPR decoders for CPU, L3 cache and USB interrupt service.  When it
### loses, it drops blocks of the RX888 input stream -- see /var/log/wsprdaemon/drops.log.
### wd-cpu-plan.sh works out a layout from THIS host's real topology; the helper scripts apply it.
###
### This reports on every WD start no matter what, so a site can see whether its layout is sane
### without having to understand any of it.  It only CHANGES the machine when the operator sets
### WD_CPU_TUNING="yes" in wsprdaemon.conf, because the layout touches CPU affinity, L3 cache
### partitioning and IRQ routing, and a bad assignment can take a receiver off the air.
###
### Reporting needs no privileges and runs the planner straight out of the WD directory.
### Applying installs the helpers to /usr/local/sbin, because the systemd units reference them there.

declare WD_CPU_TUNING_LOG=${WD_CPU_TUNING_LOG-/var/log/wsprdaemon/cpu-tuning.log}
declare WD_CPU_TUNING=${WD_CPU_TUNING-no}                     ### "yes" => apply.  Anything else => report only.
declare WD_CPU_TUNING_SBIN=${WD_CPU_TUNING_SBIN-/usr/local/sbin}
declare WD_CPU_TUNING_SCRIPTS="wd-cpu-plan.sh radiod-pin-threads.sh wd-resctrl-setup.sh wd-irq-affinity.sh wd-cpu-freq.sh wd-cpu-apply.sh"

### Log a line to BOTH the normal WD log and ${WD_CPU_TUNING_LOG}.
### This report runs while ka9q-utils.sh is being sourced, and at that point WD_LOGFILE is not yet
### set -- wd_logger() returns without writing anything when that is true, and there is no terminal
### to echo to either.  So the report would be silently discarded.  Write it to a file the operator
### can simply read instead.  Truncated at the start of each run: this is current status, not history.
function wd_cpu_tuning_log()
{
    local log_level=$1 log_line=$2
    wd_logger ${log_level} "${log_line}"
    ### %b so embedded \n render as newlines, matching what wd_logger does with 'echo -e'
    printf '%s %b\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${log_line}" >> ${WD_CPU_TUNING_LOG} 2>/dev/null
}

### Expand "0-1,4-6" / "0 1 4" into a canonical sorted "0,1,4,5,6" so the two formats compare.
function wd_cpu_list_normalise()
{
    local spec="${1//[[:space:]]/,}" part lo hi i
    local -a out=() parts
    IFS=',' read -r -a parts <<< "${spec}"
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        if [[ "${part}" == *-* ]]; then
            lo=${part%%-*}; hi=${part##*-}
            for (( i=lo; i<=hi; i++ )); do out+=("$i"); done
        else
            out+=("${part}")
        fi
    done
    (( ${#out[@]} == 0 )) && return 0
    printf '%s\n' "${out[@]}" | sort -n -u | paste -sd, -
}

### Copy the helper scripts to ${WD_CPU_TUNING_SBIN} when they are missing or out of date.
function wd_cpu_tuning_install_scripts()
{
    local script rc=0
    for script in ${WD_CPU_TUNING_SCRIPTS}; do
        local src="${WSPRDAEMON_ROOT_DIR}/${script}"
        local dst="${WD_CPU_TUNING_SBIN}/${script}"
        [[ -f ${src} ]] || { wd_logger 1 "ERROR: ${src} is missing from the WD directory"; rc=1; continue; }
        if [[ -f ${dst} ]] && cmp -s "${src}" "${dst}" ; then
            continue
        fi
        if sudo install -m 755 "${src}" "${dst}" ; then
            wd_logger 1 "Installed ${dst}"
        else
            wd_logger 1 "ERROR: could not install ${dst}"; rc=1
        fi
    done
    return ${rc}
}

### Report the planned layout and whether the running system matches it.
function wd_cpu_tuning_report()
{
    local planner="${WSPRDAEMON_ROOT_DIR}/wd-cpu-plan.sh"
    [[ -x ${planner} ]] || { wd_cpu_tuning_log 1 "CPU tuning: ${planner} not found, skipping report"; return 0; }

    local plan
    plan=$( ${planner} 2>/dev/null ) || { wd_cpu_tuning_log 1 "CPU tuning: could not read the CPU topology, skipping"; return 0; }
    eval "${plan}"

    if [[ "${WD_PLAN_OK:-no}" != "yes" ]]; then
        wd_cpu_tuning_log 1 "CPU tuning: no usable layout for this host: ${WD_PLAN_REASON:-unknown}.  ${WD_ADVICE:-Leaving CPU affinity unmanaged.}"
        return 0
    fi

    wd_cpu_tuning_log 1 "CPU tuning: ${WD_TOPO_CORES} physical cores, ${WD_TOPO_CPUS} CPUs, ${WD_TOPO_SIBLING_STYLE}, ${WD_L3_KB} KB L3, CAT ${WD_L3_CAT:-unknown}"
    wd_cpu_tuning_log 1 "CPU tuning: planned layout => OS ${WD_OS_CPUS} | radiod ${WD_CORES_PER_RADIOD} core(s) each | decoders ${WD_DECODER_CPUS}"
    ### Say so when the instance list did not come from systemctl, so a recovered run is not
    ### silently indistinguishable from a normal one.
    if [[ -n "${WD_RADIOD_DISCOVERY:-}" && "${WD_RADIOD_DISCOVERY}" != "systemctl" ]]; then
        wd_cpu_tuning_log 1 "CPU tuning: radiod instance(s) identified from ${WD_RADIOD_DISCOVERY}"
    fi
    if [[ "${WD_FREQ_AVAILABLE:-no}" == "yes" ]]; then
        wd_cpu_tuning_log 1 "CPU tuning: planned clocks => radiod $(( ${WD_FREQ_RADIOD_KHZ:-0} / 1000 )) MHz (hardware max), other cores $(( ${WD_FREQ_OTHER_KHZ:-0} / 1000 )) MHz"
    else
        wd_cpu_tuning_log 1 "CPU tuning: no cpufreq driver on this host, so the clock cannot be managed (BIOS EIST/SpeedStep disabled?)"
    fi

    ### Compare the plan against what is actually in effect
    local -i mismatches=0
    local i name cpus actual
    for (( i=0; i < ${WD_RADIOD_INSTANCES:-0}; ++i )); do
        eval "name=\${WD_RADIOD${i}_NAME}; cpus=\${WD_RADIOD${i}_CPUS}; unit=\${WD_RADIOD${i}_UNIT:-}"
        [[ -n "${name}" ]] || continue
        ### The plan carries the FULL unit name because radiod is not always 'radiod@NAME':
        ### ka9q-radio's udev autostart runs it as 'ka9q-radio@VVVV-PPPP-SERIAL'.  An older
        ### installed plan that predates WD_RADIODn_UNIT emits no unit, so fall back.
        [[ -z "${unit}" && "${name}" != "unknown" ]] && unit="radiod@${name}.service"
        if [[ -z "${unit}" ]]; then
            wd_cpu_tuning_log 1 "CPU tuning: found no radiod@ or ka9q-radio@ systemd unit; plan wants radiod on ${cpus} but there is no unit to pin"
            (( ++mismatches ))
            continue
        fi
        actual=$(systemctl show "${unit}" -p CPUAffinity --value 2>/dev/null)
        ### Compare the VALUES, not just "is it set".  The previous version only counted a mismatch
        ### when CPUAffinity was empty, so a host running radiod on entirely the wrong cores -- core 0
        ### included -- was reported as "matches the plan".  The report lied on exactly the machines
        ### that needed it.  Normalise first: systemd reports "2-5" where the plan says "2,3,4,5".
        if [[ -z "${actual}" ]]; then
            wd_cpu_tuning_log 1 "CPU tuning: ${unit} has NO CPUAffinity set; plan wants ${cpus} (fft on CPU$(eval echo \${WD_RADIOD${i}_FFT_CPU}), proc_rx888 on CPU$(eval echo \${WD_RADIOD${i}_RX888_CPU}))"
            (( ++mismatches ))
        elif [[ "$(wd_cpu_list_normalise "${actual}")" != "$(wd_cpu_list_normalise "${cpus}")" ]]; then
            wd_cpu_tuning_log 1 "CPU tuning: ${unit} is on CPUs ${actual} but the plan wants ${cpus}"
            (( ++mismatches ))
        else
            wd_cpu_tuning_log 2 "CPU tuning: ${unit} CPUAffinity=${actual} matches the plan"
        fi
    done
    if [[ -r /sys/fs/resctrl/radiod/cpus_list ]]; then
        wd_cpu_tuning_log 2 "CPU tuning: L3 partition radiod=$(cat /sys/fs/resctrl/radiod/cpus_list) decoders=$(cat /sys/fs/resctrl/decoders/cpus_list 2>/dev/null)"
    else
        wd_cpu_tuning_log 1 "CPU tuning: no L3 cache partition configured; the decoders can evict radiod's FFT working set"
        (( ++mismatches ))
    fi

    ### The decoders matter as much as radiod: confining them to too few cores is how a host ends up
    ### with idle CPUs and a load average in the 80s.
    if systemctl cat wsprdaemon.service >/dev/null 2>&1 ; then
        local dec_actual
        dec_actual=$(systemctl show wsprdaemon.service -p CPUAffinity --value 2>/dev/null)
        if [[ -n "${dec_actual}" ]] && [[ "$(wd_cpu_list_normalise "${dec_actual}")" != "$(wd_cpu_list_normalise "${WD_DECODER_CPUS}")" ]]; then
            wd_cpu_tuning_log 1 "CPU tuning: the decoders are confined to ${dec_actual} but the plan wants ${WD_DECODER_CPUS}"
            (( ++mismatches ))
        fi
    fi
    [[ "${WD_DECODER_FLOOR_APPLIED:-no}" == "yes" ]] && \
        wd_cpu_tuning_log 1 "CPU tuning: cores per radiod reduced to keep ${WD_MIN_DECODER_CORES} core(s) for the decoders"

    if (( mismatches == 0 )); then
        wd_cpu_tuning_log 1 "CPU tuning: the running layout matches the plan"
    elif [[ "${WD_CPU_TUNING}" != "yes" ]]; then
        wd_cpu_tuning_log 1 "CPU tuning: ${mismatches} item(s) differ from the plan.  This host is NOT tuned."
        wd_cpu_tuning_log 1 "CPU tuning: to apply it, set WD_CPU_TUNING=\"yes\" in ${WSPRDAEMON_CONFIG_FILE} and restart WD.  See wd-cpu-tuning.md."
        wd_cpu_tuning_log 1 "CPU tuning: check /var/log/wsprdaemon/drops.log first -- if the counts stay 0, this host does not need tuning."
    fi
    return 0
}

### Install and enable the boot-time units.  Running the helper scripts once is NOT enough:
### resctrl groups and IRQ affinity are both lost across a reboot, so without these units a tuned
### host silently reverts on the next power cycle.  On a site that has never been tuned the unit
### files do not exist at all.
function wd_cpu_tuning_install_units()
{
    local unit desc script path content
    local -i changed=0
    for unit in wd-resctrl wd-irq-affinity wd-cpu-freq ; do
        case ${unit} in
            wd-resctrl)      desc="L3 CAT partition for radiod vs the WD decoders" ; script="wd-resctrl-setup.sh" ;;
            wd-irq-affinity) desc="Pin USB (xhci) IRQs off the radiod and decoder cores" ; script="wd-irq-affinity.sh" ;;
            wd-cpu-freq)     desc="CPU clock policy: radiod at hardware max, other cores capped" ; script="wd-cpu-freq.sh" ;;
        esac
        path="/etc/systemd/system/${unit}.service"
        content="[Unit]
Description=${desc}
Documentation=man:wsprdaemon
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${WD_CPU_TUNING_SBIN}/${script}

[Install]
WantedBy=multi-user.target"
        if [[ ! -f ${path} ]] || [[ "$(cat ${path} 2>/dev/null)" != "${content}" ]]; then
            echo "${content}" | sudo tee "${path}" >/dev/null && changed=1
            wd_cpu_tuning_log 1 "CPU tuning: wrote ${path}"
        fi
    done
    (( changed )) && sudo systemctl daemon-reload
    sudo systemctl enable wd-resctrl wd-irq-affinity wd-cpu-freq >/dev/null 2>&1
    wd_cpu_tuning_log 1 "CPU tuning: boot-time units enabled: wd-resctrl=$(systemctl is-enabled wd-resctrl 2>/dev/null) wd-irq-affinity=$(systemctl is-enabled wd-irq-affinity 2>/dev/null)"
    return 0
}

### Apply the layout.  Only ever called when WD_CPU_TUNING="yes".
### When WD_CPU_TUNING="yes", wd-cpu-plan.sh owns CPU placement and ka9q-utils.sh deliberately
### ignores RADIOD_CPU_CORES / WD_CPU_CORES, and wd-cpu-freq.sh supersedes CPU_CORE_KHZ
### (whose hand-written core:khz list was written for a layout we no longer use, so it is
### always wrong once the planner moves the cores).  Left uncommented they read
### as operative: HPi7 carried RADIOD_CPU_CORES="5,11" in its conf while radiod actually ran on
### cpus 1,2,7,8, and the file was the first place its operator (and we) looked.  A config that
### contradicts the running system is worse than no config, so comment them out and say why.
### Idempotent -- already-commented lines do not match -- and the original is backed up first.
function wd_cpu_tuning_retire_manual_cores()
{
    local conf=${WSPRDAEMON_CONFIG_FILE}
    [[ -f ${conf} ]] || return 0

    local -a found=()
    local var
    for var in RADIOD_CPU_CORES WD_CPU_CORES CPU_CORE_KHZ ; do
        grep -qE "^[[:space:]]*${var}=" "${conf}" && found+=("${var}")
    done
    (( ${#found[@]} )) || return 0        ### nothing active: the usual case after the first run

    if [[ ! -w ${conf} ]]; then
        wd_cpu_tuning_log 1 "CPU tuning: ${found[*]} in ${conf} are ignored while WD_CPU_TUNING=yes, but the file is not writable, so they are left as they are"
        return 0
    fi

    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    if ! cp -a "${conf}" "${conf}.bak-cpu-tuning-${stamp}" ; then
        wd_cpu_tuning_log 1 "ERROR: CPU tuning: could not back up ${conf}, so it was left unedited"
        return 1
    fi

    local note="### Commented out by WD CPU tuning ${stamp}: WD_CPU_TUNING=\"yes\" means wd-cpu-plan.sh decides"
    local note2="### the CPU layout AND the clock policy, so this setting is IGNORED.  Restore it only if you set WD_CPU_TUNING=\"no\"."
    for var in "${found[@]}" ; do
        sed -i -E "s|^([[:space:]]*)(${var}=.*)$|\1${note}\n\1${note2}\n\1#\2|" "${conf}"
    done
    wd_cpu_tuning_log 1 "CPU tuning: commented out ${found[*]} in ${conf} -- the planner owns placement now (backup: ${conf}.bak-cpu-tuning-${stamp})"
    return 0
}

function wd_cpu_tuning_apply()
{
    wd_cpu_tuning_log 1 "CPU tuning: WD_CPU_TUNING=yes, so applying the planned layout"
    wd_cpu_tuning_install_scripts || { wd_cpu_tuning_log 1 "ERROR: CPU tuning helpers could not be installed; not applying"; return 1; }
    wd_cpu_tuning_install_units

    local out
    ### Write the drop-ins first: this does its own daemon-reload, which would otherwise reset the
    ### oneshot units' RemainAfterExit state and leave them reporting "inactive" after we start them.
    out=$( sudo ${WD_CPU_TUNING_SBIN}/wd-cpu-apply.sh 2>&1 )
    wd_cpu_tuning_log 1 "CPU tuning: systemd affinity:\n${out}"

    ### Only now that the planner's layout is actually written: retire any hand-set core
    ### assignments still sitting active in wsprdaemon.conf, so the file cannot claim otherwise.
    wd_cpu_tuning_retire_manual_cores

    ### Drive the L3 partition and IRQ pinning through their UNITS rather than by running the scripts
    ### directly.  Same code path systemd uses at boot, and it leaves the units genuinely active
    ### instead of enabled-but-inactive, which reads as broken in 'systemctl is-active'.
    local unit
    for unit in wd-resctrl wd-irq-affinity wd-cpu-freq ; do
        if sudo systemctl restart "${unit}" 2>/dev/null ; then
            wd_cpu_tuning_log 1 "CPU tuning: ${unit} => $(systemctl is-active ${unit} 2>/dev/null)/$(systemctl is-enabled ${unit} 2>/dev/null)"
        else
            wd_cpu_tuning_log 1 "ERROR: CPU tuning: ${unit} failed to start:\n$(sudo systemctl status ${unit} --no-pager 2>&1 | tail -5)"
        fi
    done

    ### Log the resulting state, which is what actually matters, rather than the scripts' stdout
    wd_cpu_tuning_log 1 "CPU tuning: L3 partition now radiod=$(cat /sys/fs/resctrl/radiod/cpus_list 2>/dev/null || echo none) decoders=$(cat /sys/fs/resctrl/decoders/cpus_list 2>/dev/null || echo none)"
    local irq_state=""
    local irq
    for irq in $(grep -E "xhci" /proc/interrupts 2>/dev/null | awk -F: '{gsub(/ /,"",$1); print $1}'); do
        irq_state+="IRQ${irq}=$(cat /proc/irq/${irq}/smp_affinity_list 2>/dev/null) "
    done
    wd_cpu_tuning_log 1 "CPU tuning: USB IRQ affinity now ${irq_state:-none found}"
    wd_cpu_tuning_log 1 "CPU tuning: applied.  radiod picks up new CPU affinity on its next restart."
    return 0
}

### Entry point, called once per WD start.
function wd_cpu_tuning()
{
    ### Make sure the log directory exists and is writable by us, then start a fresh report
    local log_dir=${WD_CPU_TUNING_LOG%/*}
    [[ -d ${log_dir} ]] || sudo mkdir -p "${log_dir}" 2>/dev/null
    [[ -w ${log_dir} ]] || sudo chown "$(id -un)" "${log_dir}" 2>/dev/null
    if [[ ! -w ${log_dir} ]]; then
        WD_CPU_TUNING_LOG="${WSPRDAEMON_ROOT_DIR:-.}/cpu-tuning.log"     ### fall back if /var/log is not writable
    fi
    ### Append rather than truncate: wd_cpu_tuning() runs more than once per WD start, and
    ### truncating meant the run that actually did the work was overwritten by a later run that
    ### found nothing to do.  Cap the size instead so it still needs no rotation.
    if [[ -f ${WD_CPU_TUNING_LOG} ]] && (( $(stat -c %s "${WD_CPU_TUNING_LOG}" 2>/dev/null || echo 0) > 200000 )); then
        tail -n 500 "${WD_CPU_TUNING_LOG}" > "${WD_CPU_TUNING_LOG}.tmp" 2>/dev/null && mv "${WD_CPU_TUNING_LOG}.tmp" "${WD_CPU_TUNING_LOG}" 2>/dev/null
    fi
    printf '%s ---- wd_cpu_tuning run ----\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ${WD_CPU_TUNING_LOG} 2>/dev/null

    wd_cpu_tuning_report
    if [[ "${WD_CPU_TUNING}" == "yes" ]]; then
        wd_cpu_tuning_apply
    fi
    return 0
}
