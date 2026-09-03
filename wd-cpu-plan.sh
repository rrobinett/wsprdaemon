#!/bin/bash
# wd-cpu-plan.sh — derive a radiod/decoder CPU + L3 plan from the ACTUAL topology.
#
# Emits sourceable shell variables.  Makes NO assumption that SMT siblings are
# adjacent: it groups logical CPUs by their real physical core id, so a machine
# pairing CPU0 with CPU8 (first-half/second-half enumeration, common on Intel and
# on some AMD configs) is handled correctly and produces SPARSE cpu lists like "0,8".
#
# Topology source: `lscpu -p=CPU,CORE,SOCKET` (machine-readable, and the CORE column
# is the authoritative pairing -- do NOT infer pairing from cpu numbering).
#
# Allocation policy (from the KX4AZ-T / KJ6MKI results):
#   core[0]            -> OS + all USB/xhci IRQ handling  (radiod must NOT be here)
#   next cores         -> radiod: 2 PHYSICAL cores per instance, so that the two hot
#                         threads (fft, proc_rx888) get a physical core each and do
#                         not share execution units / L1 / L2.  Falls back to 1 core
#                         per instance if there are not enough cores.
#   remaining cores    -> WD decoders
# L3/CAT: radiod gets ceil(ways * RADIOD_L3_FRACTION), the rest goes to decoders+OS.
#   Do NOT starve the decoders: a component squeezed into a tiny partition generates
#   L3-miss traffic that saturates the DRAM bus and hurts everything (observed at
#   KX4AZ-T when a radiod accidentally ran in the decoders' 3 MB partition).
set -u
# Optional per-site overrides (RADIOD_L3_FRACTION, MIN_DECODER_WAYS, RADIOD_INSTANCES,
# RADIOD_NAMES, CORES_PER_RADIOD_MAX, MIN_DECODER_CORES).  Lets a site tune without editing code.
[ -r /etc/wd-cpu-plan.conf ] && . /etc/wd-cpu-plan.conf
RADIOD_INSTANCES="${RADIOD_INSTANCES:-}"        # override; else auto-detect
RADIOD_NAMES="${RADIOD_NAMES:-}"                # override; else auto-detect (sorted)
RADIOD_L3_FRACTION="${RADIOD_L3_FRACTION:-0.62}" # ~5/8; tune per site
MIN_DECODER_WAYS="${MIN_DECODER_WAYS:-4}"
### Clock cap for every cpu that is NOT radiod's.  1.4 GHz is the efficient point on the
### Zen3 mobile parts most WD sites run.
FREQ_OTHER_KHZ="${FREQ_OTHER_KHZ:-1400000}"
### radiod's cores default to the hardware maximum.  Override it on a thermally constrained
### host: at KX4AZ-T, taking the two fft cores to 4.44 GHz cut the busiest fft from 86% to 52%
### of a core but pushed the package from 78 C to 84.8 C against a 94.8 C limit, on a chassis
### whose fan cannot be controlled from Linux at all.  Trading a little of that clock back
### keeps most of the margin for meaningfully less heat.
FREQ_RADIOD_KHZ="${FREQ_RADIOD_KHZ:-}"

# ---- 1. group logical CPUs by physical core (socket-aware) ----
declare -A CORE_CPUS
CORE_ORDER=()
NCPUS=0
while IFS=, read -r cpu core sock; do
    [ -z "${cpu:-}" ] && continue
    NCPUS=$((NCPUS+1))
    key="${sock}/${core}"
    if [ -z "${CORE_CPUS[$key]:-}" ]; then CORE_ORDER+=("$key"); CORE_CPUS[$key]="$cpu"
    else CORE_CPUS[$key]="${CORE_CPUS[$key]},$cpu"; fi
done < <(lscpu -p=CPU,CORE,SOCKET 2>/dev/null | grep -v '^#')

NCORES=${#CORE_ORDER[@]}
[ "$NCORES" -gt 0 ] || { echo "WD_PLAN_OK=no   # could not read topology from lscpu"; exit 1; }
SMT=$(( NCPUS / NCORES ))   # both counts come from the SAME lscpu output

# ---- 1b. Intel hybrid (P-core + E-core) awareness ----
### A chip whose physical cores do NOT all have the same thread count is hybrid: Intel
### Alder/Raptor Lake pair 2-thread P-cores with 1-thread E-cores (e.g. i9-12900HK = 6 P x2 +
### 8 E x1).  SMT=NCPUS/NCORES is meaningless for it -- 20/14 rounds to 1 and reports "no SMT"
### though the P-cores plainly have SMT.  Detect it, keep radiod on the P-cores BY DESIGN
### rather than by relying on the kernel enumerating P before E, and report it honestly.
### On a uniform chip (all cores same thread count) HYBRID stays "no" and nothing below runs,
### so uniform hosts get byte-identical placement, SMT and sibling-style output.
declare -A CORE_THREADS CORE_MAXKHZ
_min_threads=0; _max_threads=0
for _key in "${CORE_ORDER[@]}"; do
    IFS=, read -r -a _tarr <<< "${CORE_CPUS[$_key]}"
    _n=${#_tarr[@]}; CORE_THREADS[$_key]=$_n
    [ "$_min_threads" -eq 0 ] && _min_threads=$_n
    [ "$_n" -lt "$_min_threads" ] && _min_threads=$_n
    [ "$_n" -gt "$_max_threads" ] && _max_threads=$_n
    _cm=0
    for _c in "${_tarr[@]}"; do
        _f=$(cat /sys/devices/system/cpu/cpu${_c}/cpufreq/cpuinfo_max_freq 2>/dev/null || echo 0)
        [ "$_f" -gt "$_cm" ] && _cm=$_f
    done
    CORE_MAXKHZ[$_key]=$_cm
done
HYBRID="no"; NPCORES=0; NECORES=0; PCORE_MAXKHZ=0
if [ "$_min_threads" != "$_max_threads" ]; then
    HYBRID="yes"
    ### Performance cores = those with the most threads (Intel P-cores carry SMT, E-cores do not).
    _P_ORDER=(); _E_ORDER=()
    for _key in "${CORE_ORDER[@]}"; do
        if [ "${CORE_THREADS[$_key]}" = "$_max_threads" ]; then
            _P_ORDER+=("$_key")
            [ "${CORE_MAXKHZ[$_key]}" -gt "$PCORE_MAXKHZ" ] && PCORE_MAXKHZ=${CORE_MAXKHZ[$_key]}
        else
            _E_ORDER+=("$_key")
        fi
    done
    ### Stable partition: every P-core first (in enumeration order), then the E-cores.  The OS
    ### core and radiod are allocated from the front of CORE_ORDER, so this guarantees they land
    ### on P-cores and the decoders inherit the leftover P-cores plus all the E-cores.
    CORE_ORDER=( "${_P_ORDER[@]}" "${_E_ORDER[@]}" )
    NPCORES=${#_P_ORDER[@]}; NECORES=${#_E_ORDER[@]}
    ### The meaningful SMT for radiod placement is the P-cores' thread count, not 20/14.
    SMT=$_max_threads
fi

# ---- 2. which radiod instances? (names SORTED so index assignment is stable) ----
# radiod runs as 'radiod@NAME.service' when systemd manages it directly, but ka9q-radio's
# udev autostart (Phil, Aug 2026) runs the SAME radiod as 'ka9q-radio@VVVV-PPPP-SERIAL.service'
# when the SDR enumerates.  Detect both, and carry the FULL unit name: a drop-in written for
# radiod@X is silently inert on a host whose radiod really runs under ka9q-radio@Y (KFS-NW).
# A RADIOD_NAMES override still means radiod@NAME; RADIOD_UNITS overrides with full unit names.
RADIOD_UNITS="${RADIOD_UNITS:-}"
RADIOD_DISCOVERY='systemctl'        ### how the instances were found; see the stages below
if [ -z "$RADIOD_UNITS" ]; then
    if [ -n "$RADIOD_NAMES" ]; then
        for _n in $RADIOD_NAMES; do RADIOD_UNITS="${RADIOD_UNITS}radiod@${_n}.service "; done
    else
        ### Stage 1 -- ask systemd.  The normal path.
        RADIOD_UNITS=$(systemctl list-units 'radiod@*.service' 'ka9q-radio@*.service' --all --no-legend 2>/dev/null \
                       | grep -oE '(radiod|ka9q-radio)@[^ ]+\.service' | sort -u | tr '\n' ' ')
        ### Stage 2 -- ask the RUNNING radiod which unit owns it.  That systemctl call has twice
        ### returned nothing on a host where radiod was demonstrably up and never restarted
        ### (N2YCH, 2026-08-25 and 2026-09-01).  The plan then fell back to the placeholder name
        ### 'unknown', wd-cpu-apply correctly refused to pin the decoders against a radiod it could
        ### not find, and the operator got an alarming message about a perfectly healthy machine.
        ### /proc/PID/cgroup carries the owning unit and does not depend on systemctl answering,
        ### so consult it before giving up.  Instance names arrive systemd-escaped, hence printf %b.
        if [ -z "$RADIOD_UNITS" ]; then
            for _p in $(pgrep -x radiod 2>/dev/null); do
                _u=$(grep -oE '(radiod|ka9q-radio)@[^/]+\.service' "/proc/${_p}/cgroup" 2>/dev/null | head -1)
                [ -n "$_u" ] && RADIOD_UNITS="${RADIOD_UNITS}$(printf '%b' "$_u") "
            done
            RADIOD_UNITS=$(echo "$RADIOD_UNITS" | tr ' ' '\n' | grep . | sort -u | tr '\n' ' ')
            [ -n "$RADIOD_UNITS" ] && RADIOD_DISCOVERY='running process cgroup (systemctl listed none)'
        fi
        ### There is deliberately NO third stage guessing instances from leftover
        ### radiod@*.service.d directories.  Tried and rejected: on a host that once ran
        ### radiod@kfs-nw and now runs the same receiver under ka9q-radio@<serial>, the stale
        ### directory makes it look like TWO receivers and the plan reserves four cores for one.
        ### When radiod is genuinely stopped there is nothing to pin, and wd-cpu-apply refusing
        ### is the correct, harmless outcome -- the next run picks it up once radiod is back.
    fi
fi
RADIOD_UNITS=$(echo $RADIOD_UNITS)
read -r -a _units <<< "$RADIOD_UNITS"
_names=()
for _u in "${_units[@]}"; do _n="${_u#*@}"; _names+=("${_n%.service}"); done
RADIOD_NAMES="${_names[*]-}"
if [ -z "$RADIOD_INSTANCES" ]; then
    RADIOD_INSTANCES=${#_names[@]}
    [ "$RADIOD_INSTANCES" -eq 0 ] && { RADIOD_INSTANCES=1; _names=("unknown"); _units=(""); RADIOD_NAMES="unknown"; RADIOD_UNITS=""; }
fi

# ---- 3. allocate physical cores ----
OS_CORES=1
### Two physical cores per radiod is the default, so fft and proc_rx888 each get their own and do
### not contend for one core's execution units / L1 / L2.  A site short of cores -- or one that would
### rather give a core back to the decoders -- can set CORES_PER_RADIOD_MAX=1 in /etc/wd-cpu-plan.conf.
### At 1 core the two hot threads share an SMT pair, which measurably raises their CPU cost, and with
### channel threads running SCHED_FIFO it also concentrates RT time on fewer runqueues -- watch for
### "RT throttling activated" in the kernel log.
CORES_PER_RADIOD=${CORES_PER_RADIOD_MAX:-2}

### The decoders must keep a guaranteed share.  At ON5KQ-BL, 2 radiods on an 8-core box took 4 cores
### and left 3 for 161 wsprd processes: those 3 cores pinned at 0% idle, load average 85, while the
### radiod cores sat half idle.  Hardware alone cannot tell that site apart from one running 58
### decoders on identical hardware, so reserve for the decoders by default and let a site that knows
### its decode load raise CORES_PER_RADIOD_MAX deliberately.
### Size the decoder reservation from the number of RECEIVERS, not the number of radiods.
### radiod instance count is a poor proxy for decode load: ON5KQ-BL runs 2 RX888s AND 6 KiwiSDRs,
### so 8 receivers' worth of channels are decoded on a host the planner thought had "2 radiods".
### That site ran ~150 wsprd processes where a 2-radiod site with no Kiwis runs ~58 -- same
### hardware, nearly 3x the decode load, and nothing in the CPU topology reveals it.
### MERG_* entries are merge pseudo-receivers and decode nothing themselves, so they are excluded.
if [ -z "${WD_RECEIVER_COUNT:-}" ]; then
    ### ${HOME:-} not $HOME: systemd does not set HOME for a service, and with set -u an unbound
    ### HOME aborts the whole script -- which is exactly how this failed under wd-resctrl.service
    ### while working perfectly when run by hand from a login shell.
    for wd_conf in "${WSPRDAEMON_CONFIG_FILE:-}" "${HOME:-}/wsprdaemon/wsprdaemon.conf" /home/wsprdaemon/wsprdaemon/wsprdaemon.conf ; do
        [ -n "$wd_conf" ] && [ -r "$wd_conf" ] || continue
        WD_RECEIVER_COUNT=$(awk '/^declare[[:space:]]+RECEIVER_LIST/,/^\)/' "$wd_conf" 2>/dev/null \
            | grep -oE '"[A-Za-z0-9_]+' | tr -d '\042' | grep -vE '^MERG' | sort -u | wc -l)
        break
    done
fi
WD_RECEIVER_COUNT=${WD_RECEIVER_COUNT:-0}
(( WD_RECEIVER_COUNT < RADIOD_INSTANCES )) && WD_RECEIVER_COUNT=$RADIOD_INSTANCES

### Roughly one decoder core per two receivers, bounded by what is actually left after OS + radiod.
MIN_DECODER_CORES=${MIN_DECODER_CORES:-$(( (WD_RECEIVER_COUNT + 1) / 2 ))}
(( MIN_DECODER_CORES < 2 )) && MIN_DECODER_CORES=2
(( MIN_DECODER_CORES > NCORES - OS_CORES - RADIOD_INSTANCES )) && MIN_DECODER_CORES=$(( NCORES - OS_CORES - RADIOD_INSTANCES ))
(( MIN_DECODER_CORES < 1 )) && MIN_DECODER_CORES=1
DECODER_FLOOR_APPLIED="no"
while (( CORES_PER_RADIOD > 1 && OS_CORES + RADIOD_INSTANCES * CORES_PER_RADIOD + MIN_DECODER_CORES > NCORES )); do
    CORES_PER_RADIOD=$(( CORES_PER_RADIOD - 1 ))
    DECODER_FLOOR_APPLIED="yes"
done

need=$(( OS_CORES + RADIOD_INSTANCES * CORES_PER_RADIOD + 1 ))   # +1 => at least one decoder core
if [ "$need" -gt "$NCORES" ]; then
    CORES_PER_RADIOD=1
    need=$(( OS_CORES + RADIOD_INSTANCES + 1 ))
    DEGRADED="yes (only $NCORES cores; wanted ${CORES_PER_RADIOD_MAX:-2} per radiod)"
elif [ -n "${CORES_PER_RADIOD_MAX:-}" ]; then
    DEGRADED="no (CORES_PER_RADIOD_MAX=${CORES_PER_RADIOD_MAX} set in /etc/wd-cpu-plan.conf)"
else
    DEGRADED="no"
fi
if [ "$need" -gt "$NCORES" ]; then
    # Too few cores to isolate anything.  Say so in parseable form and make no
    # recommendation -- a bad pinning is worse than none.
    cat <<EOF
WD_PLAN_OK=no
WD_PLAN_REASON="only $NCORES physical core(s); need >= $need to isolate $RADIOD_INSTANCES radiod instance(s) plus OS and decoders"
WD_TOPO_CORES=$NCORES
WD_TOPO_CPUS=$NCPUS
WD_ADVICE="leave CPU affinity unmanaged on this host; isolation needs at least $need physical cores"
EOF
    exit 0
fi

cpus_of(){ echo "${CORE_CPUS[${CORE_ORDER[$1]}]}"; }
join(){ local IFS=,; echo "$*"; }

### ---- optional: reserve a whole L3 cache DOMAIN for radiod (opt-in per site) ----
### A split-L3 chip (AMD Zen2 mobile: two 4 MiB CCX caches, cpus 0-5 and 6-11) lets radiod own
### an entire L3 domain, so its FFT working set is never evicted by the decoders and NO CAT is
### needed -- the physical cache split IS the partition, and fft/proc land on separate cores of
### that domain.  Opt-in (RADIOD_L3_RESERVE=yes in /etc/wd-cpu-plan.conf) because it trades
### decoder cores for cache isolation.  Single radiod instance only; no-op on unified-L3 chips.
RADIOD_L3_RESERVE="${RADIOD_L3_RESERVE:-no}"
RADIOD_L3_RESERVED="no"
if [ "$RADIOD_L3_RESERVE" = "yes" ] && [ "$RADIOD_INSTANCES" -eq 1 ]; then
    _core_l3(){ local cpu=${1%%,*}; cat /sys/devices/system/cpu/cpu${cpu}/cache/index3/shared_cpu_list 2>/dev/null; }
    _os_dom=$(_core_l3 "$(cpus_of 0)")
    declare -A _seen=(); _ndom=0
    for _k in "${CORE_ORDER[@]}"; do _d=$(_core_l3 "${CORE_CPUS[$_k]}"); [ -n "$_d" ] && [ -z "${_seen[$_d]:-}" ] && { _seen[$_d]=1; _ndom=$((_ndom+1)); }; done
    if [ "${_ndom:-0}" -gt 1 ]; then
        _rad_dom=""
        for _k in "${CORE_ORDER[@]}"; do _d=$(_core_l3 "${CORE_CPUS[$_k]}"); [ -n "$_d" ] && [ "$_d" != "$_os_dom" ] && { _rad_dom=$_d; break; }; done
        _oskey="${CORE_ORDER[0]}"; _radkeys=(); _restkeys=()
        for _k in "${CORE_ORDER[@]}"; do
            [ "$_k" = "$_oskey" ] && continue
            _d=$(_core_l3 "${CORE_CPUS[$_k]}")
            if [ "$_d" = "$_rad_dom" ]; then _radkeys+=("$_k"); else _restkeys+=("$_k"); fi
        done
        if [ "${#_radkeys[@]}" -ge 1 ] && [ "${#_restkeys[@]}" -ge 1 ]; then
            CORE_ORDER=( "$_oskey" "${_radkeys[@]}" "${_restkeys[@]}" )
            CORES_PER_RADIOD=${#_radkeys[@]}
            RADIOD_L3_RESERVED="yes"
        fi
    fi
fi

os_list=$(cpus_of 0)
idx=1
declare -a RADIOD_LISTS RADIOD_FFT RADIOD_RX RADIOD_OTHER
for _ in $(seq 1 "$RADIOD_INSTANCES"); do
    parts=(); first_cpu=""; second_cpu=""; others=()
    for k in $(seq 1 "$CORES_PER_RADIOD"); do
        c=$(cpus_of "$idx"); parts+=("$c")
        # within a core, first listed CPU is the "primary", the rest are SMT siblings
        IFS=, read -r -a arr <<< "$c"
        if [ "$k" = "1" ]; then first_cpu="${arr[0]}"; others+=("${arr[@]:1}")
        else [ -z "$second_cpu" ] && second_cpu="${arr[0]}"; others+=("${arr[@]:1}"); fi
        idx=$((idx+1))
    done
    # with only ONE core, fft and proc_rx888 must share it (degraded)
    [ -z "$second_cpu" ] && second_cpu="${others[0]:-$first_cpu}"
    RADIOD_LISTS+=("$(join "${parts[@]}")")
    RADIOD_FFT+=("$first_cpu"); RADIOD_RX+=("$second_cpu")
    RADIOD_OTHER+=("$( [ ${#others[@]} -gt 0 ] && join "${others[@]}" || echo "$first_cpu" )")
done
dec=(); for i in $(seq "$idx" $((NCORES-1))); do dec+=("$(cpus_of "$i")"); done
### The decoders may also use the OS core.  Reserving a whole physical core for the OS wastes real
### capacity -- it measured 94-99% idle on one host -- and WSPR decoding is throughput work, not
### latency work: a decode that is preempted by kernel or interrupt activity simply finishes a
### moment later.  radiod is the latency-sensitive part and stays off this core.
### Set DECODERS_USE_OS_CORE=no to keep the OS core exclusive.
if [ "${DECODERS_USE_OS_CORE:-yes}" = "yes" ]; then
    dec=( "$os_list" "${dec[@]}" )
fi
dec_list=$(join "${dec[@]}")

# ---- 4. L3 / CAT masks from the real cache geometry ----
L3_KB=$(lscpu -B 2>/dev/null | awk -F: '/L3 cache/{gsub(/ /,"",$2); print int($2/1024)}')
CBM=$(cat /sys/fs/resctrl/info/L3/cbm_mask 2>/dev/null || echo "")
### Having an L3 and being able to PARTITION it are separate facts.  Intel gates RDT/CAT to
### Xeon, so a consumer part reports its ways in sysfs with no way to divide them -- HPi7's
### i7-8700 advertises 16 ways and has no rdt_a/cat_l3 flag and no /sys/fs/resctrl at all.
### Reading ways_of_associativity alone therefore emitted masks for a cache that cannot be
### partitioned, and wd-resctrl only discovered it at the mount, several steps too late.
if [ -n "$CBM" ]; then
    L3_CAT="yes"                    ### resctrl is mounted: the mask IS the usable geometry
    WAYS=$(( $(echo "obase=2; ibase=16; ${CBM^^}" | bc | tr -cd '1' | wc -c) ))
else
    WAYS=$(cat /sys/devices/system/cpu/cpu0/cache/index3/ways_of_associativity 2>/dev/null || echo 0)
    if grep -qE '^flags[[:space:]]*:.*[[:space:]](cat_l3|rdt_a)([[:space:]]|$)' /proc/cpuinfo 2>/dev/null ; then
        L3_CAT="yes"                ### CAT present, resctrl simply not mounted yet
    else
        L3_CAT="no"                 ### no CAT on this CPU: report the geometry, emit no masks
    fi
fi
### radiod owns a whole L3 domain: no CAT -- the physical cache split already isolates it.
if [ "$RADIOD_L3_RESERVED" = "yes" ]; then L3_CAT="reserved-domain"; RADIOD_MASK=""; OTHER_MASK=""; fi
if [ "$L3_CAT" = "yes" ] && [ "$WAYS" -gt 0 ]; then
    rw=$(awk -v w="$WAYS" -v f="$RADIOD_L3_FRACTION" 'BEGIN{printf "%d", int(w*f+0.5)}')
    [ $(( WAYS - rw )) -lt "$MIN_DECODER_WAYS" ] && rw=$(( WAYS - MIN_DECODER_WAYS ))
    [ "$rw" -lt 1 ] && rw=1
    RADIOD_MASK=$(printf '%x' $(( (1 << rw) - 1 )))
    OTHER_MASK=$(printf '%x' $(( ((1 << WAYS) - 1) ^ ((1 << rw) - 1) )))
    KB_PER_WAY=$(( ${L3_KB:-0} / WAYS ))
else
    RADIOD_MASK=""; OTHER_MASK=""; rw=0; KB_PER_WAY=0
fi

# ---- 4b. CPU clock policy ----
### fft rises FASTER than linearly with the RX888 sample rate: measured on one Ryzen 7 5825U
### it needs 0.54 Gcycle/s at 64.8 Msps but 2.75 Gcycle/s at 129.6 Msps, which is 86% of a
### 3.19 GHz core.  A blanket cap would starve it, so radiod's cores get the hardware maximum.
### The decoders finish their burst ~35 s into each 120 s cycle, so capping them spends slack
### we have and buys less DRAM/L3 contention against fft, less power and cooler peaks.
FREQ_DIR=/sys/devices/system/cpu/cpu0/cpufreq
if [ -r "$FREQ_DIR/cpuinfo_max_freq" ]; then
    FREQ_AVAILABLE="yes"
    FREQ_HW_MAX=$(cat "$FREQ_DIR/cpuinfo_max_freq")
    ### On a hybrid chip base radiod's clock on a P-core's maximum, not cpu0's blindly -- radiod
    ### is pinned to P-cores, and if the kernel ever enumerated an E-core as cpu0 the E-core's
    ### lower max would wrongly cap radiod.  Uniform chips are unaffected (PCORE_MAXKHZ=0).
    [ "$HYBRID" = "yes" ] && [ "${PCORE_MAXKHZ:-0}" -gt 0 ] && FREQ_HW_MAX=$PCORE_MAXKHZ
    FREQ_HW_MIN=$(cat "$FREQ_DIR/cpuinfo_min_freq" 2>/dev/null || echo 0)
    if [ -n "${FREQ_RADIOD_KHZ}" ] && [ "${FREQ_RADIOD_KHZ}" -gt 0 ] 2>/dev/null; then
        FREQ_RADIOD=${FREQ_RADIOD_KHZ}
        [ "${FREQ_RADIOD}" -gt "${FREQ_HW_MAX}" ] && FREQ_RADIOD=${FREQ_HW_MAX}
        [ "${FREQ_HW_MIN}" -gt 0 ] && [ "${FREQ_RADIOD}" -lt "${FREQ_HW_MIN}" ] && FREQ_RADIOD=${FREQ_HW_MIN}
    else
        FREQ_RADIOD=${FREQ_HW_MAX}
    fi
    FREQ_OTHER=${FREQ_OTHER_KHZ}
    [ "${FREQ_OTHER}" -gt "${FREQ_HW_MAX}" ] && FREQ_OTHER=${FREQ_HW_MAX}
    [ "${FREQ_HW_MIN}" -gt 0 ] && [ "${FREQ_OTHER}" -lt "${FREQ_HW_MIN}" ] && FREQ_OTHER=${FREQ_HW_MIN}
else
    ### No cpufreq driver at all: BIOS EIST/SpeedStep disabled, or a VM that hides the MSRs.
    FREQ_AVAILABLE="no"; FREQ_HW_MAX=0; FREQ_HW_MIN=0; FREQ_RADIOD=0; FREQ_OTHER=0
fi

# ---- 5. emit ----
cat <<EOF
WD_PLAN_OK=yes
# --- detected ---
WD_TOPO_CPUS=$NCPUS
WD_TOPO_CORES=$NCORES
WD_TOPO_SMT=$SMT
WD_TOPO_SIBLING_STYLE="$( if [ "$HYBRID" = "yes" ]; then echo "hybrid ${NPCORES}P+${NECORES}E"; elif [ "$SMT" -gt 1 ]; then a=$(cpus_of 0); b=${a%%,*}; c=${a##*,}; if [ $(( c - b )) -eq 1 ]; then echo adjacent; else echo "sparse (stride $(( (c - b) / (SMT - 1) )))"; fi; else echo "no SMT"; fi )"
WD_TOPO_HYBRID="$HYBRID"
WD_TOPO_PCORES=$NPCORES
WD_TOPO_ECORES=$NECORES
WD_TOPO_CORE_MAP="$(for k in "${CORE_ORDER[@]}"; do printf '%s=[%s] ' "$k" "${CORE_CPUS[$k]}"; done)"
WD_L3_KB=${L3_KB:-unknown}
WD_L3_WAYS=$WAYS
WD_L3_CAT="$L3_CAT"
WD_RADIOD_L3_RESERVED="$RADIOD_L3_RESERVED"
WD_FREQ_AVAILABLE="$FREQ_AVAILABLE"
WD_FREQ_HW_MAX_KHZ=$FREQ_HW_MAX
WD_FREQ_HW_MIN_KHZ=$FREQ_HW_MIN
WD_FREQ_RADIOD_KHZ=$FREQ_RADIOD
WD_FREQ_OTHER_KHZ=$FREQ_OTHER
WD_L3_KB_PER_WAY=$KB_PER_WAY
# --- plan ---
WD_OS_CPUS="$os_list"
WD_RADIOD_INSTANCES=$RADIOD_INSTANCES
WD_RADIOD_NAMES="$RADIOD_NAMES"
WD_RADIOD_UNITS="$RADIOD_UNITS"
WD_RADIOD_DISCOVERY="$RADIOD_DISCOVERY"
WD_CORES_PER_RADIOD=$CORES_PER_RADIOD
WD_DEGRADED="$DEGRADED"
WD_RECEIVER_COUNT=$WD_RECEIVER_COUNT
WD_MIN_DECODER_CORES=$MIN_DECODER_CORES
WD_DECODER_FLOOR_APPLIED="$DECODER_FLOOR_APPLIED"
EOF
for i in $(seq 0 $((RADIOD_INSTANCES-1))); do
    echo "WD_RADIOD${i}_NAME=\"${_names[$i]:-}\""
    echo "WD_RADIOD${i}_UNIT=\"${_units[$i]:-}\""
    echo "WD_RADIOD${i}_CPUS=\"${RADIOD_LISTS[$i]}\""
    echo "WD_RADIOD${i}_FFT_CPU=\"${RADIOD_FFT[$i]}\""
    echo "WD_RADIOD${i}_RX888_CPU=\"${RADIOD_RX[$i]}\""
    echo "WD_RADIOD${i}_OTHER_CPUS=\"${RADIOD_OTHER[$i]}\""
done
echo "WD_DECODER_CPUS=\"$dec_list\""
if [ "$L3_CAT" = "yes" ] && [ "$WAYS" -gt 0 ]; then
    echo "WD_L3_RADIOD_MASK=\"$RADIOD_MASK\"   # $rw ways = $(( rw * KB_PER_WAY / 1024 )) MB"
    echo "WD_L3_OTHER_MASK=\"$OTHER_MASK\"   # $(( WAYS - rw )) ways = $(( (WAYS-rw) * KB_PER_WAY / 1024 )) MB"
else
    echo "WD_L3_RADIOD_MASK=\"\"   # no CAT on this CPU: the L3 cannot be partitioned"
    echo "WD_L3_OTHER_MASK=\"\"   # no CAT on this CPU: the L3 cannot be partitioned"
fi
