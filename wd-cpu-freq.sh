#!/bin/bash
# wd-cpu-freq.sh — set the CPU clock policy from wd-cpu-plan.sh: radiod fast, everything else capped.
#
# WHY THE TWO HALVES DIFFER, measured 2026-08-31 with hardware cycle counters:
#   fft rises FASTER than linearly with the RX888 sample rate -- 0.54 Gcycle/s at 64.8 Msps but
#   2.75 Gcycle/s at 129.6 Msps on the same Ryzen 7 5825U silicon, which is 86% of a 3.19 GHz
#   core.  Cap that core to 1.4 GHz and fft would need more than a whole core: the receiver
#   breaks.  So radiod's cores get the hardware maximum, not a guess.
#   proc_rx888 is ~0.24 Gcycle/s of fixed USB/buffer work plus ~3.6 cycles per sample, so it
#   also wants clock but is far cheaper.
#   The DECODERS are the opposite case: WSPR decoding is throughput work, and a decode burst
#   measured finishing ~35 s into every 120 s cycle -- ~85 s of slack.  Slowing those cores
#   spends slack we have to buy less DRAM and L3 contention against fft while it runs, plus
#   lower power draw and lower peak temperatures.
#
# Before this, clocks came from CPU_CORE_KHZ in wsprdaemon.conf (wd-setup.sh): a hand-written
# core:khz list that knew nothing about which cores run radiod, and whose UNSET DEFAULT capped
# every core at 3.2 GHz -- hiding 0.86 GHz of headroom on a 5825U at every site that never set it.
#
# HOW WELL THE CAP ACTUALLY BITES, measured on a Ryzen 5560U (amd-pstate, 2026-08-31):
#   setting scaling_max_freq is ADVISORY on amd-pstate, not a hard ceiling.  A fixed workload
#   timed on an idle core took 1.11 s capped at 1.4 GHz versus 0.85 s uncapped -- a 1.3x
#   slowdown, not the 2.9x a real 1.4 GHz ceiling would give.  In practice the cap takes the
#   core off boost down to roughly its nominal clock and no further, and amd_pstate=passive
#   behaves the same.  Do not trust scaling_cur_freq to check this: it kept reporting 3.2 GHz
#   regardless of the setting.  Time a fixed workload instead.
#   The radiod half of the policy is unambiguous and does work: performance governor plus the
#   hardware maximum moved those cores from 3.14 to 4.02 GHz, measured.
#
# Frequency does not persist across reboots, hence the accompanying systemd unit.
set -u
[ -r /etc/wd-cpu-plan.conf ] && . /etc/wd-cpu-plan.conf
PLAN_CMD="${WD_CPU_PLAN:-/usr/local/sbin/wd-cpu-plan.sh}"
DRY="${DRY_RUN:-0}"

plan=$("$PLAN_CMD" 2>/dev/null) || { echo "wd-cpu-freq: cannot run $PLAN_CMD"; exit 1; }
eval "$plan"
[ "${WD_PLAN_OK:-no}" = "yes" ] || { echo "wd-cpu-freq: no usable plan: ${WD_PLAN_REASON:-unknown}"; exit 0; }
if [ "${WD_FREQ_AVAILABLE:-no}" != "yes" ]; then
    echo "wd-cpu-freq: no cpufreq driver on this host, so the clock is not software controlled; nothing to do"
    exit 0
fi

RADIOD_KHZ=${WD_FREQ_RADIOD_KHZ:-0}
OTHER_KHZ=${WD_FREQ_OTHER_KHZ:-0}
[ "$RADIOD_KHZ" -gt 0 ] && [ "$OTHER_KHZ" -gt 0 ] || { echo "wd-cpu-freq: plan carries no frequencies; nothing to do"; exit 0; }

### Expand "0-1,4" into "0 1 4"
expand(){
    local part lo hi i out=""
    for part in $(echo "${1:-}" | tr ',' ' '); do
        case "$part" in
            *-*) lo=${part%%-*}; hi=${part##*-}; for (( i=lo; i<=hi; i++ )); do out+="$i " ; done ;;
            "")  ;;
            *)   out+="$part " ;;
        esac
    done
    echo "$out"
}

### Every cpu radiod owns, across all instances
radiod_cpus=""
for i in $(seq 0 $(( ${WD_RADIOD_INSTANCES:-0} - 1 ))); do
    eval "c=\${WD_RADIOD${i}_CPUS:-}"
    radiod_cpus+="$(expand "$c") "
done

is_radiod(){ case " $radiod_cpus " in *" $1 "*) return 0;; *) return 1;; esac; }

w(){ if [ "$DRY" = "1" ]; then echo "    would: echo '$1' > $2"; else echo "$1" > "$2" 2>/dev/null; fi; }

n_fast=0 n_capped=0 n_skipped=0
for d in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -d "$d" ] || continue
    cpu=$(basename "$(dirname "$d")"); cpu=${cpu#cpu}
    maxf="$d/scaling_max_freq"
    gov="$d/scaling_governor"
    if [ ! -w "$maxf" ] && [ "$DRY" != "1" ]; then n_skipped=$((n_skipped+1)); continue; fi
    if is_radiod "$cpu"; then
        w "$RADIOD_KHZ" "$maxf"
        ### performance keeps fft off the low P-states between decode cycles; it is the thread
        ### whose latency the whole receiver depends on, and it is never idle for long anyway.
        ### a dry run must preview this even when it is not running as root
        if grep -q performance "$d/scaling_available_governors" 2>/dev/null && \
           { [ "$DRY" = "1" ] || [ -w "$gov" ]; }; then
            w "performance" "$gov"
        fi
        n_fast=$((n_fast+1))
    else
        w "$OTHER_KHZ" "$maxf"
        n_capped=$((n_capped+1))
    fi
done

printf 'wd-cpu-freq: radiod cpus %s -> %d kHz (hardware max), %d other cpu(s) -> %d kHz'"\n" \
       "$(echo $radiod_cpus | tr ' ' ',')" "$RADIOD_KHZ" "$n_capped" "$OTHER_KHZ"
[ "$n_skipped" -gt 0 ] && echo "wd-cpu-freq: $n_skipped cpu(s) had no writable scaling_max_freq and were left alone"
exit 0
