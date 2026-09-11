##########################################################################################################################################################
########## Section which reports (and optionally applies) the radiod CPU / cache / IRQ layout  ############################################################
##########################################################################################################################################################
###
### radiod competes with the WSPR decoders for CPU, L3 cache and USB interrupt service.  When it
### loses, it drops blocks of the RX888 input stream -- see /var/log/wsprdaemon/drops.log.
### wd-cpu-plan.sh works out a layout from THIS host's real topology; the helper scripts apply it.
###
### This reports on every WD start no matter what, so a site can see whether its layout is sane
### without having to understand any of it.  Since 2026-09-03 it also APPLIES the layout by
### default (WD_CPU_TUNING defaults to "yes"): the planner refuses hosts it can't lay out sanely
### (WD_PLAN_OK=no), and wd-cpu-apply.sh rolls back rather than half-apply, so the remaining risk
### is judged smaller than radiod sitting on core 0 with the decoders, which is where every
### untuned host ends up.  A site that wants to manage CPU affinity itself sets
### WD_CPU_TUNING="no" in wsprdaemon.conf and gets the report only.
###
### Reporting needs no privileges and runs the planner straight out of the WD directory.
### Applying installs the helpers to /usr/local/sbin, because the systemd units reference them there.

declare WD_CPU_TUNING_LOG=${WD_CPU_TUNING_LOG-/var/log/wsprdaemon/cpu-tuning.log}
declare WD_CPU_TUNING=${WD_CPU_TUNING-yes}                    ### "yes" (the default) => apply.  Anything else => report only.
declare WD_CPU_TUNING_SBIN=${WD_CPU_TUNING_SBIN-/usr/local/sbin}
declare WD_CPU_TUNING_SCRIPTS="wd-cpu-plan.sh radiod-pin-threads.sh wd-resctrl-setup.sh wd-irq-affinity.sh wd-cpu-freq.sh wd-cpu-apply.sh"

### ---- the site's own clock ceiling ------------------------------------------------------
### Before the planner, a site capped its CPU clocks with CPU_CORE_KHZ in wsprdaemon.conf.  The
### planner took the clock policy over and gives radiod's cores the HARDWARE MAXIMUM -- 4.55 GHz
### on a Ryzen 7 5825U -- while wd_cpu_tuning_retire_manual_cores() commented CPU_CORE_KHZ out.
### That left the operator with no knob at all: FREQ_RADIOD_KHZ / FREQ_OTHER_KHZ existed only in
### /etc/wd-cpu-plan.conf, which nothing writes and no site owner has ever been told about.
### ON5KQ (2026-09-09), on a box he had deliberately run at 2.6 GHz for years: "The cpu is at its
### limit and the blower runs at full speed ... I tried to limit the clock rate again, but it
### doesn't seem to work anymore."  He was right, and a receiver whose fan is unbearable gets
### switched off.  radiod needs clock only in proportion to the RX888 sample rate (fft is
### 0.54 Gcycle/s at 64.8 Msps, 2.75 at 129.6), so on a slow-sampling site most of that 4.55 GHz
### is heat for nothing.  These four settings, in MHz, are the knob; they are propagated to
### /etc/wd-cpu-plan.conf so the boot-time wd-cpu-freq.service applies the same policy.
declare WD_CPU_FREQ_MAX_MHZ=${WD_CPU_FREQ_MAX_MHZ-}          ### ceiling for EVERY core; the simple knob
declare WD_CPU_FREQ_RADIOD_MHZ=${WD_CPU_FREQ_RADIOD_MHZ-}    ### ceiling for radiod's cores; unset => hardware max
declare WD_CPU_FREQ_OTHER_MHZ=${WD_CPU_FREQ_OTHER_MHZ-}      ### ceiling for the decoder/OS cores; unset => 1400
declare WD_CPU_FREQ_FAST_MODE=${WD_CPU_FREQ_FAST_MODE-}      ### "radiod" (every radiod cpu fast) or "fft-pair"
declare WD_CPU_PLAN_CONF=${WD_CPU_PLAN_CONF-/etc/wd-cpu-plan.conf}

### Log a line to BOTH the normal WD log and ${WD_CPU_TUNING_LOG}.
### This report runs while ka9q-utils.sh is being sourced, and at that point WD_LOGFILE is not yet
### set -- wd_logger() returns without writing anything when that is true, and there is no terminal
### to echo to either.  So the report would be silently discarded.  Write it to a file the operator
### can simply read instead.  Truncated at the start of each run: this is current status, not history.
### At the default verbosity only ERROR / WARNING / REFUSING / RESTART REQUIRED / NOT restricting lines reach the
### terminal: a 'wda' should print nothing when all is well.  ${WD_CPU_TUNING_LOG} still gets every line.
function wd_cpu_tuning_log()
{
    local log_level=$1 log_line=$2
    if (( log_level == 1 )) && ! [[ ${log_line} =~ ERROR|WARNING|REFUSING|RESTART\ REQUIRED|NOT\ restricting ]]; then
        log_level=2
    fi
    wd_logger ${log_level} "${log_line}"
    ### %b so embedded \n render as newlines, matching what wd_logger does with 'echo -e'
    [[ -d ${WD_CPU_TUNING_LOG%/*} ]] || sudo install -d -o "$(id -un)" -g "$(id -gn)" "${WD_CPU_TUNING_LOG%/*}" 2>/dev/null
    printf '%s %b\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${log_line}" 2>/dev/null >> ${WD_CPU_TUNING_LOG}
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

### Validate one of the WD_CPU_FREQ_*_MHZ settings and leave it in kHz in ${wd_cpu_freq_khz},
### which is what the cpufreq sysfs files and the planner speak.  Returns 1 when the value is
### unusable, so a typo leaves the default in place rather than pinning the host at some absurd
### clock.  kHz is accepted as well: this replaces CPU_CORE_KHZ, which was in kHz for a decade,
### so "2600000" here is a mistake waiting to happen and is worth reading charitably.
### The answer comes back in a variable rather than on stdout BECAUSE this function logs: called
### as $(wd_cpu_freq_validate ...) its own warning text would be captured as part of the value.
declare wd_cpu_freq_khz=0
function wd_cpu_freq_validate()
{
    local var_name=$1 value="$2"

    wd_cpu_freq_khz=0
    [[ -z ${value} ]] && return 1
    if ! [[ ${value} =~ ^[0-9]+$ ]]; then
        wd_cpu_tuning_log 1 "ERROR: ${var_name}=\"${value}\" is not a whole number of MHz, so it is ignored"
        return 1
    fi
    if (( value >= 100000 )); then
        wd_cpu_tuning_log 1 "WARNING: ${var_name}=\"${value}\" is in kHz, not MHz; reading it as $(( value / 1000 )) MHz"
        value=$(( value / 1000 ))
    fi
    if (( value < 400 || value > 9999 )); then
        wd_cpu_tuning_log 1 "ERROR: ${var_name}=\"${value}\" MHz is outside the sane 400..9999 MHz range, so it is ignored"
        return 1
    fi
    wd_cpu_freq_khz=$(( value * 1000 ))
    return 0
}

### Propagate what only WD knows into ${WD_CPU_PLAN_CONF}, as the variables wd-cpu-plan.sh and
### wd-cpu-freq.sh already understand.  It has to land in that file rather than merely in this
### shell: wd-cpu-freq.service runs at BOOT, long before WD starts, and reads nothing else.
### Only the block between the markers is ours -- a site's hand-written RADIOD_L3_FRACTION and
### friends in the same file are preserved untouched -- and it is written LAST so it wins over
### any FREQ_* the site set there by hand before this knob existed.
###
### Two kinds of fact live here.  The clock ceilings come from wsprdaemon.conf.  RADIOD_INSTANCES=0
### comes from WD having read the receiver list and found no KA9Q receiver: the boot-time scripts
### cannot work that out for themselves -- they re-plan from scratch, discover no radiod, and fall
### back to the placeholder instance -- so without persisting it a Kiwi-only host got its phantom
### radiod cores back at every boot, complete with the performance governor.  Observed on PD0OHW-1.
function wd_cpu_tuning_write_plan_conf()
{
    local radiod_khz="" other_khz="" fast_mode=""

    ### WD_CPU_FREQ_MAX_MHZ is the both-halves shorthand; the specific settings refine it.
    ### Each variable is emitted at most ONCE: a file that assigns FREQ_OTHER_KHZ twice and
    ### relies on the second winning is correct and unreadable, which is how a config file
    ### stops being believed.
    if wd_cpu_freq_validate WD_CPU_FREQ_MAX_MHZ "${WD_CPU_FREQ_MAX_MHZ}" ; then
        radiod_khz=${wd_cpu_freq_khz}
        other_khz=${wd_cpu_freq_khz}
    fi
    wd_cpu_freq_validate WD_CPU_FREQ_RADIOD_MHZ "${WD_CPU_FREQ_RADIOD_MHZ}" && radiod_khz=${wd_cpu_freq_khz}
    wd_cpu_freq_validate WD_CPU_FREQ_OTHER_MHZ  "${WD_CPU_FREQ_OTHER_MHZ}"  && other_khz=${wd_cpu_freq_khz}
    case "${WD_CPU_FREQ_FAST_MODE}" in
        "")                 ;;
        radiod|fft-pair)    fast_mode=${WD_CPU_FREQ_FAST_MODE} ;;
        *)                  wd_cpu_tuning_log 1 "ERROR: WD_CPU_FREQ_FAST_MODE=\"${WD_CPU_FREQ_FAST_MODE}\" is neither 'radiod' nor 'fft-pair', so it is ignored" ;;
    esac

    local -a lines=()
    ### ka9q-utils.sh exports this as 0 when the conf holds no KA9Q receiver.  Anything else --
    ### unset, or a real count -- means "let the planner discover it", which is the normal path.
    [[ "${RADIOD_INSTANCES:-}" == "0" ]] && lines+=( "RADIOD_INSTANCES=0" )
    [[ -n ${radiod_khz} ]] && lines+=( "FREQ_RADIOD_KHZ=${radiod_khz}" )
    [[ -n ${other_khz}  ]] && lines+=( "FREQ_OTHER_KHZ=${other_khz}" )
    [[ -n ${fast_mode}  ]] && lines+=( "FREQ_FAST_MODE=${fast_mode}" )

    local begin_marker="### ---- BEGIN clock policy from wsprdaemon.conf -- written by WD, edit wsprdaemon.conf not this file ----"
    local end_marker="### ---- END clock policy from wsprdaemon.conf ----"

    ### Everything in the file that is NOT our block, in order.  Fixed-string comparison, so a
    ### marker containing '.' and '(' cannot be misread as a regex.
    local rest=""
    if [[ -r ${WD_CPU_PLAN_CONF} ]]; then
        rest=$(awk -v b="${begin_marker}" -v e="${end_marker}" '$0==b{skip=1} skip==0{print} $0==e{skip=0}' "${WD_CPU_PLAN_CONF}")
    fi

    local new_content="${rest}"
    if (( ${#lines[@]} )); then
        [[ -n ${new_content} ]] && new_content+=$'\n'
        new_content+="${begin_marker}"$'\n'"$(printf '%s\n' "${lines[@]}")"$'\n'"${end_marker}"
    fi

    ### $(cat) strips trailing newlines and so does the $(awk) above, so the two sides compare cleanly
    if [[ "$(cat "${WD_CPU_PLAN_CONF}" 2>/dev/null)" == "${new_content}" ]]; then
        (( ${#lines[@]} )) && wd_cpu_tuning_log 2 "CPU tuning: ${WD_CPU_PLAN_CONF} already carries ${lines[*]}"
        return 0
    fi

    if [[ -z ${new_content} ]]; then
        ### Nothing of ours and nothing of theirs left: do not leave an empty file behind
        sudo rm -f "${WD_CPU_PLAN_CONF}"
        wd_cpu_tuning_log 1 "CPU tuning: nothing for WD to pin down in ${WD_CPU_PLAN_CONF} (no WD_CPU_FREQ_* setting, and this host runs radiod), so it was removed and the defaults apply"
        return 0
    fi
    if ! printf '%s\n' "${new_content}" | sudo tee "${WD_CPU_PLAN_CONF}" >/dev/null ; then
        wd_cpu_tuning_log 1 "ERROR: CPU tuning: could not write ${WD_CPU_PLAN_CONF}, so the WD_CPU_FREQ_* settings will not survive a reboot"
        return 1
    fi
    if (( ${#lines[@]} )); then
        wd_cpu_tuning_log 1 "CPU tuning: wrote ${lines[*]} to ${WD_CPU_PLAN_CONF} so the boot-time units see it too"
    else
        wd_cpu_tuning_log 1 "CPU tuning: no WD_CPU_FREQ_* setting in ${WSPRDAEMON_CONFIG_FILE}, so the default clock policy applies"
    fi
    return 0
}

### Carry a legacy CPU_CORE_KHZ="DEFAULT:<khz>[,<core>:<khz>...]" forward into WD_CPU_FREQ_MAX_MHZ.
### Retiring CPU_CORE_KHZ without this is exactly how ON5KQ's box ended up running radiod at
### 4.55 GHz with the fan flat out on hardware its owner had deliberately held to 2.6 GHz: WD
### disabled his setting and offered nothing in its place.  A cap the operator wrote down is a
### decision, not noise, so it survives the migration.
### The per-core fields are dropped, and only DEFAULT is carried: the planner decides which core
### does what now, so a list keyed by core number has no meaning once the layout moves.
function wd_cpu_tuning_migrate_cpu_core_khz()
{
    local conf=${WSPRDAEMON_CONFIG_FILE}

    [[ -f ${conf} ]] || return 0
    ### Already said in the new form, here or in the file: leave it alone
    [[ -n "${WD_CPU_FREQ_MAX_MHZ}${WD_CPU_FREQ_RADIOD_MHZ}${WD_CPU_FREQ_OTHER_MHZ}" ]] && return 0
    grep -qE "^[[:space:]]*WD_CPU_FREQ_(MAX|RADIOD|OTHER)_MHZ=" "${conf}" && return 0

    local legacy
    legacy=$(grep -E "^[[:space:]]*CPU_CORE_KHZ=" "${conf}" | tail -1)
    [[ -n ${legacy} ]] || return 0

    local khz=${legacy#*DEFAULT:}
    khz=${khz%%[^0-9]*}
    if [[ -z ${khz} ]]; then
        wd_cpu_tuning_log 1 "WARNING: CPU tuning: ${conf} has ${legacy} with no usable 'DEFAULT:<khz>', so no clock ceiling was carried forward.  Set WD_CPU_FREQ_MAX_MHZ instead."
        return 0
    fi
    local mhz=$(( khz / 1000 ))
    if (( mhz < 400 || mhz > 9999 )); then
        wd_cpu_tuning_log 1 "WARNING: CPU tuning: ${conf} has ${legacy}, whose ${mhz} MHz is outside the sane 400..9999 MHz range, so no clock ceiling was carried forward"
        return 0
    fi
    if [[ ! -w ${conf} ]]; then
        wd_cpu_tuning_log 1 "WARNING: CPU tuning: ${conf} caps the clocks at ${mhz} MHz with CPU_CORE_KHZ, which the planner ignores, but the file is not writable so WD_CPU_FREQ_MAX_MHZ=\"${mhz}\" could not be added for you"
        return 0
    fi

    local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
    if ! cp -a "${conf}" "${conf}.bak-cpu-tuning-${stamp}" ; then
        wd_cpu_tuning_log 1 "ERROR: CPU tuning: could not back up ${conf}, so CPU_CORE_KHZ was not carried forward"
        return 1
    fi
    cat >> "${conf}" <<EOF

### Carried forward from CPU_CORE_KHZ by WD CPU tuning ${stamp}.  With WD_CPU_TUNING="yes" the
### planner owns the clock policy, and this is the knob that caps it: MHz, applied to every core.
### WD_CPU_FREQ_RADIOD_MHZ and WD_CPU_FREQ_OTHER_MHZ cap radiod's cores and the rest separately;
### unset, radiod runs at the hardware maximum and the other cores at 1400 MHz.  See wd-cpu-tuning.md.
WD_CPU_FREQ_MAX_MHZ="${mhz}"
EOF
    WD_CPU_FREQ_MAX_MHZ=${mhz}      ### take effect on THIS run, not only the next one
    wd_cpu_tuning_log 1 "CPU tuning: carried the ${mhz} MHz ceiling from CPU_CORE_KHZ forward into WD_CPU_FREQ_MAX_MHZ in ${conf} (backup: ${conf}.bak-cpu-tuning-${stamp})"
    return 0
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
            wd_logger 2 "Installed ${dst}"
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
        ### Say which it is.  Reporting a site-set ceiling as "hardware max" is how an operator
        ### who capped his clocks concludes, correctly, that WD ignored him.
        local radiod_why="${WD_FREQ_RADIOD_SOURCE:-hardware max}"
        (( ${WD_FREQ_RADIOD_KHZ:-0} < ${WD_FREQ_HW_MAX_KHZ:-0} )) && \
            radiod_why="${radiod_why}, hardware max $(( ${WD_FREQ_HW_MAX_KHZ:-0} / 1000 )) MHz"
        wd_cpu_tuning_log 1 "CPU tuning: planned clocks => radiod $(( ${WD_FREQ_RADIOD_KHZ:-0} / 1000 )) MHz (${radiod_why}), other cores $(( ${WD_FREQ_OTHER_KHZ:-0} / 1000 )) MHz"
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
    if [[ "${WD_NO_RADIOD:-no}" == "yes" ]]; then
        wd_cpu_tuning_log 1 "CPU tuning: no radiod on this host, so every core is a decoder core and only the clock ceiling is applied"
    elif [[ -r /sys/fs/resctrl/radiod/cpus_list ]]; then
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
        wd_cpu_tuning_log 1 "CPU tuning: WD_CPU_TUNING=\"${WD_CPU_TUNING}\" in ${WSPRDAEMON_CONFIG_FILE}, so it is not being applied.  Remove that line (or set it to \"yes\") and restart WD to apply it.  See wd-cpu-tuning.md."
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
    ### With no radiod there is nothing to isolate: an L3 partition would only fence the decoders
    ### out of a cache no one else is using, and steering the USB IRQs away from them buys nothing
    ### when no RX888 is feeding those interrupts.  The clock ceiling is the whole of the work.
    local units="wd-resctrl wd-irq-affinity wd-cpu-freq"
    [[ "${WD_NO_RADIOD:-no}" == "yes" ]] && units="wd-cpu-freq"
    for unit in ${units} ; do
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
    sudo systemctl enable ${units} >/dev/null 2>&1
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
    ### Never comment a clock setting out without saying what replaced it: the operator came here
    ### to cap his clocks, and a bare "IGNORED" leaves him with a hot box and no knob.
    local note3="### To cap the clocks under the planner use WD_CPU_FREQ_MAX_MHZ (every core), or"
    local note4="### WD_CPU_FREQ_RADIOD_MHZ / WD_CPU_FREQ_OTHER_MHZ separately.  See wd-cpu-tuning.md."
    for var in "${found[@]}" ; do
        local why="${note}\n\1${note2}"
        [[ ${var} == "CPU_CORE_KHZ" ]] && why="${note}\n\1${note2}\n\1${note3}\n\1${note4}"
        sed -i -E "s|^([[:space:]]*)(${var}=.*)$|\1${why}\n\1#\2|" "${conf}"
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
    ### 'sudo env ...' because sudoers env_reset strips exported variables: the boot-time RADIOD_NAMES
    ### hint (ka9q-utils.sh) reached the report's planner but never this one, so at every 'wda' with
    ### radiod stopped, wd-cpu-apply re-planned blind and printed "REFUSING to apply" (N8UR 2026-09-06).
    ### RADIOD_INSTANCES rides along for the same reason RADIOD_NAMES does: without it wd-cpu-apply
    ### re-plans blind, rediscovers nothing on a Kiwi-only host and falls back to the placeholder
    ### instance -- reserving a core for a radiod that does not exist, which is the whole bug.
    out=$( sudo env RADIOD_NAMES="${RADIOD_NAMES:-}" RADIOD_UNITS="${RADIOD_UNITS:-}" RADIOD_INSTANCES="${RADIOD_INSTANCES:-}" ${WD_CPU_TUNING_SBIN}/wd-cpu-apply.sh 2>&1 )
    wd_cpu_tuning_log 1 "CPU tuning: systemd affinity:\n${out}"

    ### Only now that the planner's layout is actually written: retire any hand-set core
    ### assignments still sitting active in wsprdaemon.conf, so the file cannot claim otherwise.
    wd_cpu_tuning_retire_manual_cores

    ### Drive the L3 partition and IRQ pinning through their UNITS rather than by running the scripts
    ### directly.  Same code path systemd uses at boot, and it leaves the units genuinely active
    ### instead of enabled-but-inactive, which reads as broken in 'systemctl is-active'.
    local unit
    local units="wd-resctrl wd-irq-affinity wd-cpu-freq"
    [[ "${WD_NO_RADIOD:-no}" == "yes" ]] && units="wd-cpu-freq"
    for unit in ${units} ; do
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
    printf '%s ---- wd_cpu_tuning run ----\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null >> ${WD_CPU_TUNING_LOG}

    ### Both of these run BEFORE the report, because the report runs the planner and the planner
    ### sources ${WD_CPU_PLAN_CONF}: written afterwards, a site's clock ceiling (and a Kiwi-only
    ### host's RADIOD_INSTANCES=0) would be reported
    ### one WD start late.  Only when we own the policy -- with WD_CPU_TUNING="no" the site drives
    ### the clocks itself through CPU_CORE_KHZ in wd-setup.sh and /etc is none of our business.
    if [[ "${WD_CPU_TUNING}" == "yes" ]]; then
        wd_cpu_tuning_migrate_cpu_core_khz
        wd_cpu_tuning_write_plan_conf
    fi

    wd_cpu_tuning_report
    if [[ "${WD_CPU_TUNING}" == "yes" ]]; then
        if [[ "${WD_PLAN_OK:-no}" == "yes" ]]; then
            wd_cpu_tuning_apply
        else
            ### No layout for this host (e.g. the 2-core N8GA-TC-2): applying used to install and enable the boot
            ### units anyway, and wd-irq-affinity then FAILED at every boot and WD start with "no OS cpu list".
            wd_cpu_tuning_retire_units
        fi
    fi
    return 0
}

### Stop and disable the boot-time units on a host the planner cannot lay out, so nothing fails at boot.
function wd_cpu_tuning_retire_units()
{
    local unit
    for unit in wd-resctrl wd-irq-affinity wd-cpu-freq ; do
        if systemctl is-enabled --quiet "${unit}" 2>/dev/null || systemctl is-active --quiet "${unit}" 2>/dev/null; then
            wd_cpu_tuning_log 1 "CPU tuning: no usable layout here, so disabling ${unit}"
            sudo systemctl disable --now "${unit}" > /dev/null 2>&1
        fi
        sudo systemctl reset-failed "${unit}" > /dev/null 2>&1
    done
}
