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

# ---- 2. which radiod instances? (names SORTED so index assignment is stable) ----
if [ -z "$RADIOD_NAMES" ]; then
    RADIOD_NAMES=$(systemctl list-units 'radiod@*.service' --all --no-legend 2>/dev/null \
                   | grep -oE 'radiod@[^ .]+' | sed 's/radiod@//' | sort -u | tr '\n' ' ')
fi
RADIOD_NAMES=$(echo $RADIOD_NAMES)
read -r -a _names <<< "$RADIOD_NAMES"
if [ -z "$RADIOD_INSTANCES" ]; then
    RADIOD_INSTANCES=${#_names[@]}
    [ "$RADIOD_INSTANCES" -eq 0 ] && { RADIOD_INSTANCES=1; _names=("unknown"); RADIOD_NAMES="unknown"; }
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
    for wd_conf in "${WSPRDAEMON_CONFIG_FILE:-}" "$HOME/wsprdaemon/wsprdaemon.conf" /home/wsprdaemon/wsprdaemon/wsprdaemon.conf ; do
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
if [ -n "$CBM" ]; then
    WAYS=$(( $(echo "obase=2; ibase=16; ${CBM^^}" | bc | tr -cd '1' | wc -c) ))
else
    WAYS=$(cat /sys/devices/system/cpu/cpu0/cache/index3/ways_of_associativity 2>/dev/null || echo 0)
fi
if [ "$WAYS" -gt 0 ]; then
    rw=$(awk -v w="$WAYS" -v f="$RADIOD_L3_FRACTION" 'BEGIN{printf "%d", int(w*f+0.5)}')
    [ $(( WAYS - rw )) -lt "$MIN_DECODER_WAYS" ] && rw=$(( WAYS - MIN_DECODER_WAYS ))
    [ "$rw" -lt 1 ] && rw=1
    RADIOD_MASK=$(printf '%x' $(( (1 << rw) - 1 )))
    OTHER_MASK=$(printf '%x' $(( ((1 << WAYS) - 1) ^ ((1 << rw) - 1) )))
    KB_PER_WAY=$(( ${L3_KB:-0} / WAYS ))
else
    RADIOD_MASK=""; OTHER_MASK=""; rw=0; KB_PER_WAY=0
fi

# ---- 5. emit ----
cat <<EOF
WD_PLAN_OK=yes
# --- detected ---
WD_TOPO_CPUS=$NCPUS
WD_TOPO_CORES=$NCORES
WD_TOPO_SMT=$SMT
WD_TOPO_SIBLING_STYLE="$( if [ "$SMT" -gt 1 ]; then a=$(cpus_of 0); b=${a%%,*}; c=${a##*,}; if [ $(( c - b )) -eq 1 ]; then echo adjacent; else echo "sparse (stride $(( (c - b) / (SMT - 1) )))"; fi; else echo "no SMT"; fi )"
WD_TOPO_CORE_MAP="$(for k in "${CORE_ORDER[@]}"; do printf '%s=[%s] ' "$k" "${CORE_CPUS[$k]}"; done)"
WD_L3_KB=${L3_KB:-unknown}
WD_L3_WAYS=$WAYS
WD_L3_KB_PER_WAY=$KB_PER_WAY
# --- plan ---
WD_OS_CPUS="$os_list"
WD_RADIOD_INSTANCES=$RADIOD_INSTANCES
WD_RADIOD_NAMES="$RADIOD_NAMES"
WD_CORES_PER_RADIOD=$CORES_PER_RADIOD
WD_DEGRADED="$DEGRADED"
WD_RECEIVER_COUNT=$WD_RECEIVER_COUNT
WD_MIN_DECODER_CORES=$MIN_DECODER_CORES
WD_DECODER_FLOOR_APPLIED="$DECODER_FLOOR_APPLIED"
EOF
for i in $(seq 0 $((RADIOD_INSTANCES-1))); do
    echo "WD_RADIOD${i}_NAME=\"${_names[$i]:-}\""
    echo "WD_RADIOD${i}_CPUS=\"${RADIOD_LISTS[$i]}\""
    echo "WD_RADIOD${i}_FFT_CPU=\"${RADIOD_FFT[$i]}\""
    echo "WD_RADIOD${i}_RX888_CPU=\"${RADIOD_RX[$i]}\""
    echo "WD_RADIOD${i}_OTHER_CPUS=\"${RADIOD_OTHER[$i]}\""
done
echo "WD_DECODER_CPUS=\"$dec_list\""
echo "WD_L3_RADIOD_MASK=\"$RADIOD_MASK\"   # $rw ways = $(( rw * KB_PER_WAY / 1024 )) MB"
echo "WD_L3_OTHER_MASK=\"$OTHER_MASK\"   # $(( WAYS - rw )) ways = $(( (WAYS-rw) * KB_PER_WAY / 1024 )) MB"
