#!/bin/bash
# wd-resctrl-setup.sh — L3 CAT partition (AMD RDT / Intel CAT) for radiod vs WD decoders.
#
# CPU lists and cache masks come from wd-cpu-plan.sh, derived from the real topology and
# the real cache geometry (ways and size) -- nothing here is hard-coded to a host.
#
# *** The CPU lists MUST match the radiod pinning. ***  At KX4AZ-T a stale hard-coded
# cpus_list left one radiod running inside the DECODERS' 3 MB partition instead of
# radiod's 13 MB one after its cores were moved: identical work, a quarter of the cache,
# 86.9% CPU vs 75.0%.  Deriving both from one plan is what prevents that class of bug.
#
# Do NOT starve the decoders: a component squeezed into a tiny partition generates
# L3-miss traffic that saturates the DRAM bus and hurts everything, radiod included.
# Tune via /etc/wd-cpu-plan.conf (RADIOD_L3_FRACTION, MIN_DECODER_WAYS).
#
# Idempotent.  DRY_RUN=1 prints what would happen and changes nothing.
set -u
PLAN_CMD="${WD_CPU_PLAN:-/usr/local/sbin/wd-cpu-plan.sh}"
DRY="${DRY_RUN:-0}"
R=/sys/fs/resctrl
w(){ if [ "$DRY" = "1" ]; then echo "    would: echo '$1' > $2"; else echo "$1" > "$2"; fi; }

plan=$("$PLAN_CMD" 2>/dev/null) || { echo "wd-resctrl: cannot run $PLAN_CMD"; exit 1; }
eval "$plan"
[ "${WD_PLAN_OK:-no}" = "yes" ] || { echo "wd-resctrl: no usable plan: ${WD_PLAN_REASON:-unknown}"; exit 0; }
[ -n "${WD_L3_RADIOD_MASK:-}" ] || { echo "wd-resctrl: no L3 CAT on this CPU; nothing to do"; exit 0; }

if ! mountpoint -q "$R"; then
    if [ "$DRY" = "1" ]; then echo "    would: mount -t resctrl resctrl $R"
    else mount -t resctrl resctrl "$R" 2>/dev/null || { echo "wd-resctrl: cannot mount resctrl; CAT unavailable"; exit 0; }; fi
fi
[ "$DRY" = "1" ] || mkdir -p "$R/radiod" "$R/decoders"

radiod_cpus=""
for i in $(seq 0 $(( ${WD_RADIOD_INSTANCES:-0} - 1 ))); do
    eval "c=\$WD_RADIOD${i}_CPUS"; radiod_cpus="${radiod_cpus:+$radiod_cpus,}$c"
done
other_cpus="${WD_OS_CPUS},${WD_DECODER_CPUS}"

echo "wd-resctrl: radiod cpus=$radiod_cpus mask=$WD_L3_RADIOD_MASK ; others cpus=$other_cpus mask=$WD_L3_OTHER_MASK"
# masks BEFORE cpus, to avoid a transient window where a group has the full mask
w "L3:0=$WD_L3_OTHER_MASK"  "$R/schemata"
w "L3:0=$WD_L3_RADIOD_MASK" "$R/radiod/schemata"
w "L3:0=$WD_L3_OTHER_MASK"  "$R/decoders/schemata"
# shrink decoders FIRST so those CPUs are free to reassign, then claim them for radiod
w "$WD_DECODER_CPUS" "$R/decoders/cpus_list"
w "$radiod_cpus"     "$R/radiod/cpus_list"
exit 0
