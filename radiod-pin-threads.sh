#!/bin/bash
# radiod-pin-threads.sh <instance> — pin radiod's hot threads to specific CPUs.
#
# Layout is NOT hard-coded: it comes from wd-cpu-plan.sh, which reads the real CPU
# topology.  That matters because SMT siblings are not always adjacent -- on some
# machines CPU0 pairs with CPU8 -- and a hard-coded "cores 2,3" would then straddle
# two different physical cores.
#
# WHY pin at all: fft and proc_rx888 are radiod's two hot threads.  Sharing one
# physical core they contend for its execution units, L1 and L2.  Giving each its own
# physical core measured a 33-point CPU reduction for identical work at KJ6MKI
# (145% -> 112%), and took the fft core's worst-case idle from 4.4% to 29%.
# proc_rx888 drains the RX888 USB stream; if it runs late the front-end ring buffer
# overruns and radiod's Drops counter increments.
#
# DRY_RUN=1 prints what would happen and changes nothing.
set -u
inst="${1:-}"
[ -n "$inst" ] || { echo "usage: $0 <radiod-instance>" >&2; exit 2; }
PLAN_CMD="${WD_CPU_PLAN:-/usr/local/sbin/wd-cpu-plan.sh}"
DRY="${DRY_RUN:-0}"
log(){ echo "radiod-pin[$inst]: $*"; }
run(){ if [ "$DRY" = "1" ]; then echo "    would: $*"; else "$@" >/dev/null 2>&1; fi; }

plan=$("$PLAN_CMD" 2>/dev/null) || { log "cannot run $PLAN_CMD; leaving affinity unmanaged"; exit 0; }
eval "$plan"
if [ "${WD_PLAN_OK:-no}" != "yes" ]; then
    log "no usable plan: ${WD_PLAN_REASON:-unknown}; leaving affinity unmanaged"; exit 0
fi

# find this instance's index in the plan
idx=""
for i in $(seq 0 $(( ${WD_RADIOD_INSTANCES:-0} - 1 ))); do
    eval "n=\${WD_RADIOD${i}_NAME:-}"
    [ "$n" = "$inst" ] && { idx=$i; break; }
done
[ -n "$idx" ] || { log "instance not present in plan (plan has: ${WD_RADIOD_NAMES:-none}); leaving unmanaged"; exit 0; }
eval "FFT_CPU=\$WD_RADIOD${idx}_FFT_CPU; RX_CPU=\$WD_RADIOD${idx}_RX888_CPU; OTHER_CPUS=\$WD_RADIOD${idx}_OTHER_CPUS"
log "plan: fft->CPU$FFT_CPU  proc_rx888->CPU$RX_CPU  others->CPUs $OTHER_CPUS  (${WD_TOPO_SIBLING_STYLE:-?} SMT)"

pid=""
for _ in $(seq 1 30); do
    pid=$(systemctl show "radiod@$inst" -p MainPID --value 2>/dev/null)
    [ -n "$pid" ] && [ "$pid" != "0" ] && [ -d "/proc/$pid/task" ] && break
    [ "$DRY" = "1" ] && break
    sleep 1
done
if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -d "/proc/$pid/task" ]; then
    log "no MainPID; giving up (service unaffected)"; exit 0
fi
pin_pass(){
    local f=0 r=0 o=0 tid nm
    for t in /proc/"$pid"/task/*; do
        [ -d "$t" ] || continue
        tid=$(basename "$t"); nm=$(cat "$t/comm" 2>/dev/null) || continue
        case "$nm" in
            fft)        run taskset -pc "$FFT_CPU"    "$tid" && f=$((f+1)) ;;
            proc_rx888) run taskset -pc "$RX_CPU"     "$tid" && r=$((r+1)) ;;
            *)          run taskset -pc "$OTHER_CPUS" "$tid" && o=$((o+1)) ;;
        esac
    done
    log "pinned fft=$f proc_rx888=$r other=$o"
}
# channel threads appear as channels come up, so make two passes
if [ "$DRY" = "1" ]; then pin_pass; else sleep 8; pin_pass; sleep 20; pin_pass; fi
log "done"
exit 0
