#!/bin/bash
# wd-cpu-apply.sh — write every systemd CPU-affinity setting from the plan in wd-cpu-plan.sh.
#
# ORDER MATTERS, and it is the whole point of this script's structure:
#   1. write the radiod drop-ins
#   2. VERIFY systemd actually resolved them to the planned CPUs
#   3. only then restrict the decoders
#
# If step 2 fails, everything written is rolled back and the decoders are left alone.
#
# Why: at ON5KQ-BL a site had its own override.conf in radiod@*.service.d/.  systemd applies
# drop-ins ALPHABETICALLY, so override.conf sorted after cpu-affinity.conf and won -- radiod never
# moved to its planned cores.  The decoder restriction had nothing competing with it and applied
# cleanly, so 161 wsprd processes were confined to the 3 cores the plan had freed on the assumption
# radiod had vacated them.  Result: three cores pinned at 0% idle, load average 85, and six CPUs
# completely idle.  Half-applying was far worse than not applying at all.
#
# Writes DROP-INS, never unit files, so WD regenerating wsprdaemon.service does not discard them.
# systemd merges CPUAffinity= ADDITIVELY, so each drop-in resets with an empty CPUAffinity= first.
# Restarts nothing: it reports which units need it.  DRY_RUN=1 changes nothing.
set -u
PLAN_CMD="${WD_CPU_PLAN:-/usr/local/sbin/wd-cpu-plan.sh}"
PIN_SCRIPT="${WD_PIN_SCRIPT:-/usr/local/sbin/radiod-pin-threads.sh}"
DRY="${DRY_RUN:-0}"
DROPIN_NAME="cpu-affinity.conf"
declare -a NEEDS_RESTART=() WROTE=()

### Expand "0-1,4-6" / "0 1 4" into a canonical sorted "0,1,4,5,6" so formats can be compared.
cpu_list_normalise(){
    local spec="${1//[[:space:]]/,}" part lo hi i
    local -a out=()
    local -a parts
    IFS=',' read -r -a parts <<< "${spec}"
    for part in "${parts[@]}"; do
        [ -z "${part}" ] && continue
        if [ "${part}" != "${part#*-}" ] && [ "${part#*-}" != "${part}" ]; then
            lo=${part%%-*}; hi=${part##*-}
            for (( i=lo; i<=hi; i++ )); do out+=("$i"); done
        else
            out+=("${part}")
        fi
    done
    [ ${#out[@]} -eq 0 ] && return 0
    printf '%s\n' "${out[@]}" | sort -n -u | paste -sd, -
}

effective(){ grep -vE '^[[:space:]]*(#|$)' 2>/dev/null || true ; }

write_dropin(){
    local path=$1 content=$2 unit=$3
    if [ -f "$path" ] && [ "$(effective < "$path")" = "$(printf '%s\n' "$content" | effective)" ]; then
        echo "  unchanged: $path"; return 0
    fi
    if [ "$DRY" = "1" ]; then
        echo "  WOULD WRITE $path:"; echo "$content" | sed 's/^/      /'
    else
        sudo mkdir -p "$(dirname "$path")"
        echo "$content" | sudo tee "$path" >/dev/null
        echo "  wrote: $path"
        WROTE+=("$path")
    fi
    [ -n "$unit" ] && NEEDS_RESTART+=("$unit")
    return 0
}

rollback(){
    local f
    echo "  ROLLING BACK -- removing everything this run wrote:"
    for f in "${WROTE[@]}"; do sudo rm -f "$f" && echo "    removed $f"; done
    sudo systemctl daemon-reload
}

plan=$("$PLAN_CMD" 2>/dev/null) || { echo "wd-cpu-apply: cannot run $PLAN_CMD"; exit 1; }
eval "$plan"
[ "${WD_PLAN_OK:-no}" = "yes" ] || { echo "wd-cpu-apply: no usable plan: ${WD_PLAN_REASON:-unknown}"; exit 0; }

### radiod is 'radiod@NAME.service' under direct systemd management but
### 'ka9q-radio@VVVV-PPPP-SERIAL.service' under ka9q-radio's udev autostart; the plan carries
### the full unit name.  Fall back to radiod@NAME for an older installed plan without it.
resolve_unit(){   # $1 = plan index -> echoes the systemd unit, empty when there is none
    local n u
    eval "n=\${WD_RADIOD$1_NAME:-}; u=\${WD_RADIOD$1_UNIT:-}"
    [ -z "$u" ] && [ -n "$n" ] && [ "$n" != "unknown" ] && u="radiod@${n}.service"
    printf '%s' "$u"
}

### Refuse up front when the plan has no real unit to pin.  The 'unknown' placeholder used to
### sail through: 'systemctl show radiod@unknown' renders the TEMPLATE plus our fresh drop-in,
### so the verify step passed while no running radiod was pinned at all -- and the decoders were
### then restricted anyway.  That is the ON5KQ half-apply, reached down a different road.
for (( i=0; i < ${WD_RADIOD_INSTANCES:-0}; ++i )); do
    if [ -z "$(resolve_unit $i)" ]; then
        echo "wd-cpu-apply: REFUSING to apply -- the plan found no radiod@ or ka9q-radio@ unit to pin."
        echo "  Restricting the decoders while radiod floats free is worse than doing nothing."
        exit 1
    fi
done

### The drop-ins are written from the plan THIS script ran, but radiod-pin-threads.sh reads the
### INSTALLED plan at ExecStartPost time.  If those two copies disagree, the unit's CPUAffinity and
### the thread pinning come from different layouts.  That happened at ON5KQ-BL: apply wrote
### CPUAffinity=2-3 from an updated plan while the pin script read an older installed plan and pinned
### proc_rx888 to CPU4 -- outside the unit's own allowed set, which taskset permits when run as root.
CANON_PLAN=/usr/local/sbin/wd-cpu-plan.sh
if [ "$(readlink -f "$PLAN_CMD" 2>/dev/null)" != "$(readlink -f "$CANON_PLAN" 2>/dev/null)" ]; then
    if [ ! -f "$CANON_PLAN" ]; then
        echo "wd-cpu-apply: WARNING -- $CANON_PLAN is not installed, so radiod-pin-threads.sh cannot plan"
    elif ! cmp -s "$PLAN_CMD" "$CANON_PLAN" ; then
        echo "wd-cpu-apply: REFUSING to apply -- planning from $PLAN_CMD, but radiod-pin-threads.sh"
        echo "  will read $CANON_PLAN and the two DIFFER.  The drop-ins and the thread pinning would"
        echo "  come from different layouts.  Install the same plan to $CANON_PLAN first."
        exit 1
    fi
fi

echo "wd-cpu-apply: ${WD_TOPO_CORES} cores, ${WD_TOPO_SIBLING_STYLE} SMT, ${WD_CORES_PER_RADIOD} core(s)/radiod"
[ "${WD_DECODER_FLOOR_APPLIED:-no}" = "yes" ] && \
    echo "  note: cores per radiod reduced to keep ${WD_MIN_DECODER_CORES} core(s) for the decoders"

### ---- step 0: refuse if a foreign drop-in would win the alphabetical ordering ----
conflict=0
for (( i=0; i < ${WD_RADIOD_INSTANCES:-0}; ++i )); do
    unit=$(resolve_unit $i)
    [ -n "${unit}" ] || continue
    for f in "/etc/systemd/system/${unit}.d/"*.conf ; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        [ "$b" = "$DROPIN_NAME" ] && continue
        if [ "$b" \> "$DROPIN_NAME" ] && grep -qi '^[[:space:]]*CPUAffinity=[0-9]' "$f" ; then
            ### Only a DIFFERENT value is a conflict.  A later drop-in that already agrees with the
            ### plan is harmless, and refusing on it would block sites that keep their layout in
            ### their own file.
            eval "want=\$WD_RADIOD${i}_CPUS"
            other=$(grep -i '^[[:space:]]*CPUAffinity=[0-9]' "$f" | tail -1 | cut -d= -f2)
            if [ "$(cpu_list_normalise "$other")" != "$(cpu_list_normalise "$want")" ]; then
                echo "  CONFLICT: $f sets CPUAffinity=${other} and sorts after ${DROPIN_NAME}; plan wants ${want}"
                conflict=1
            else
                echo "  note: $f also sets CPUAffinity=${other}, which agrees with the plan"
            fi
        fi
    done
done
if (( conflict )); then
    echo "wd-cpu-apply: REFUSING to apply -- another drop-in would override the radiod affinity."
    echo "  Applying anyway would restrict the decoders while radiod stayed put, which is worse than"
    echo "  doing nothing.  Remove or rename that drop-in, or set its CPUAffinity to match the plan."
    exit 1
fi

### ---- step 1: radiod drop-ins ----
for (( i=0; i < ${WD_RADIOD_INSTANCES:-0}; ++i )); do
    eval "cpus=\$WD_RADIOD${i}_CPUS"
    unit=$(resolve_unit $i)
    [ -n "${unit}" ] || continue
    write_dropin "/etc/systemd/system/${unit}.d/${DROPIN_NAME}" \
"[Service]
# Generated by wd-cpu-apply.sh from wd-cpu-plan.sh -- do not hand-edit.
# The empty CPUAffinity= reset is REQUIRED; systemd merges this directive additively.
CPUAffinity=
CPUAffinity=$(echo "$cpus" | tr ',' ' ')
# AllowedCPUs (cpuset) is the HARD boundary.  radiod re-affinitizes its own threads to all
# online CPUs, which overrides the inherited CPUAffinity (sched_setaffinity) but NOT a cpuset
# restriction -- without this, proc_rx888 and fft drift onto the decoder cores after a
# reconfiguration event (observed on K6FOD's split-L3 5500U, 2026-09-02).
AllowedCPUs=
AllowedCPUs=${cpus}
ExecStartPost=+${PIN_SCRIPT} %i" \
        "${unit}"
done

### ---- step 2: VERIFY systemd resolved them to the planned CPUs ----
if [ "$DRY" != "1" ]; then
    sudo systemctl daemon-reload
    for (( i=0; i < ${WD_RADIOD_INSTANCES:-0}; ++i )); do
        eval "cpus=\$WD_RADIOD${i}_CPUS"
        unit=$(resolve_unit $i)
        [ -n "${unit}" ] || continue
        got=$(systemctl show "${unit}" -p CPUAffinity --value 2>/dev/null)
        if [ "$(cpu_list_normalise "$got")" != "$(cpu_list_normalise "$cpus")" ]; then
            echo "  VERIFY FAILED: ${unit} resolves to '${got}', plan wants '${cpus}'"
            rollback
            echo "wd-cpu-apply: NOT restricting the decoders -- radiod did not take its planned cores."
            exit 1
        fi
        echo "  verified: ${unit} => ${got}"
    done
fi

### ---- step 3: only now is it safe to confine the decoders ----
if systemctl cat wsprdaemon.service >/dev/null 2>&1 ; then
    write_dropin "/etc/systemd/system/wsprdaemon.service.d/${DROPIN_NAME}" \
"[Service]
# Generated by wd-cpu-apply.sh from wd-cpu-plan.sh -- do not hand-edit.
CPUAffinity=
CPUAffinity=$(echo "${WD_DECODER_CPUS}" | tr ',' ' ')" \
        "wsprdaemon.service"
else
    echo "  wsprdaemon.service not present; skipping (WD is not a systemd service here)"
fi

write_dropin "/etc/systemd/system.conf.d/radiod-cpu-affinity.conf" \
"[Manager]
# Generated by wd-cpu-apply.sh -- keeps OS and system services off the radiod cores.
CPUAffinity=$(cpu_list_normalise "${WD_OS_CPUS},${WD_DECODER_CPUS}" | tr ',' ' ')" \
    ""

if [ "$DRY" = "1" ]; then
    echo "  (dry run - nothing written, no daemon-reload)"
else
    sudo systemctl daemon-reload
fi
if [ ${#NEEDS_RESTART[@]} -eq 0 ]; then
    echo "wd-cpu-apply: no changes; nothing needs restarting"
else
    printf 'wd-cpu-apply: RESTART REQUIRED for: %s\n' "${NEEDS_RESTART[*]}"
    echo "  (not done automatically -- restarting radiod resets its drop counter)"
fi
exit 0
