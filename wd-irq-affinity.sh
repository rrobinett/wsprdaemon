#!/bin/bash
# wd-irq-affinity.sh — pin USB (xhci) interrupts to the OS core, deterministically.
#
# The OS core comes from wd-cpu-plan.sh, so this follows the real topology (it may be a
# SPARSE cpu list such as "0,8" on machines whose SMT siblings are not adjacent).
#
# WHY: the RX888 arrives over USB.  Left alone the kernel parks the xhci IRQ on an
# arbitrary CPU -- found on a WD decoder core at BOTH sites, and at KX4AZ-T with an
# UNRESTRICTED 0-15 affinity, meaning it could land directly on a radiod core after any
# reboot.  Hard-IRQ entry preempts user space, but the USB bottom half (softirq/ksoftirqd)
# is normally scheduled and can be delayed by a busy core -- and proc_rx888 depends on
# that completion path.
#
# IRQ NUMBERS ARE NOT STABLE ACROSS REBOOTS, so match by DEVICE NAME.  Affinity does not
# persist across reboots either, hence the accompanying systemd unit.
# Pair with irqbalance disabled, or it will migrate these right back.
#
# ALL_IRQS=1 (settable in /etc/wd-cpu-plan.conf) additionally herds EVERY movable IRQ onto the
# OS cpus and points /proc/irq/default_smp_affinity there, so IRQs registered later also land
# on the OS cpus.  Found necessary at KX4AZ: pinning only xhci still left other device IRQs
# free to fire on the radiod cores.  Kernel-managed (per-queue NVMe/NIC) IRQs refuse the write
# and are left alone -- the kernel spreads those deliberately.
set -u
[ -r /etc/wd-cpu-plan.conf ] && . /etc/wd-cpu-plan.conf
PLAN_CMD="${WD_CPU_PLAN:-/usr/local/sbin/wd-cpu-plan.sh}"
MATCH="${MATCH:-xhci_hcd}"
ALL_IRQS="${ALL_IRQS:-0}"
DRY="${DRY_RUN:-0}"
OS_CPUS="${OS_CPUS:-}"
if [ -z "$OS_CPUS" ]; then
    plan=$("$PLAN_CMD" 2>/dev/null) && eval "$plan"
    OS_CPUS="${WD_OS_CPUS:-}"
fi
[ -n "$OS_CPUS" ] || { echo "wd-irq-affinity: no OS cpu list available; leaving IRQs unmanaged"; exit 1; }

found=0
while read -r irq; do
    [ -n "$irq" ] || continue
    found=1
    f=/proc/irq/$irq/smp_affinity_list
    cur=$(cat "$f" 2>/dev/null)
    if [ "$DRY" = "1" ]; then
        echo "    would: IRQ $irq ($MATCH) $cur -> $OS_CPUS"
    elif echo "$OS_CPUS" > "$f" 2>/dev/null; then
        echo "wd-irq-affinity: IRQ $irq ($MATCH) $cur -> $(cat "$f" 2>/dev/null)"
    else
        # kernel-managed IRQs (IRQD_AFFINITY_MANAGED) reject writes with EIO; not fatal
        echo "wd-irq-affinity: IRQ $irq ($MATCH) is kernel-managed, left at $cur"
    fi
done < <(grep -E "$MATCH" /proc/interrupts | awk -F: '{gsub(/ /,"",$1); print $1}')
[ "$found" = "1" ] || echo "wd-irq-affinity: no IRQs matching '$MATCH'"

if [ "$ALL_IRQS" = "1" ]; then
    # cpu list -> hex mask ("0-1,4" -> 13).  Good to 62 cpus; beyond that the /proc mask
    # format needs comma-grouped words, so emit nothing rather than corrupt the file.
    cpulist_to_hex(){
        local mask=0 part lo hi c
        for part in $(echo "$1" | tr ',' ' '); do
            lo=${part%%-*}; hi=${part##*-}
            for (( c=lo; c<=hi; c++ )); do
                [ "$c" -ge 63 ] && { printf ''; return; }
                mask=$(( mask | (1 << c) ))
            done
        done
        [ "$mask" != "0" ] && printf '%x' "$mask"
    }
    hexmask=$(cpulist_to_hex "$OS_CPUS")
    if [ -n "$hexmask" ]; then
        if [ "$DRY" = "1" ]; then echo "    would: default_smp_affinity -> $hexmask"
        else echo "$hexmask" > /proc/irq/default_smp_affinity 2>/dev/null \
             && echo "wd-irq-affinity: default_smp_affinity -> $hexmask (cpus $OS_CPUS)"
        fi
    fi
    moved=0 kept=0
    for d in /proc/irq/[0-9]*; do
        irq=$(basename "$d")
        [ -f "$d/smp_affinity_list" ] || continue
        if [ "$DRY" = "1" ]; then moved=$((moved+1))
        elif echo "$OS_CPUS" > "$d/smp_affinity_list" 2>/dev/null; then moved=$((moved+1))
        else kept=$((kept+1))    # kernel-managed or immovable (IRQ0); left alone
        fi
    done
    echo "wd-irq-affinity: ALL_IRQS=1: $moved IRQs -> cpus $OS_CPUS, $kept kernel-managed/immovable left alone"

    # Unbound kernel workqueues honor a cpumask of their own: point it at every cpu EXCEPT
    # radiod's, or async kernel work (writeback, crypto, fs) still lands on the radio cores
    # and walks radiod's L3 partition.  Per-cpu kworkers cannot and should not move.
    if [ -n "${WD_DECODER_CPUS:-}" ] && [ -w /sys/devices/virtual/workqueue/cpumask ]; then
        wq_hex=$(cpulist_to_hex "$OS_CPUS,$WD_DECODER_CPUS")
        if [ -n "$wq_hex" ]; then
            if [ "$DRY" = "1" ]; then echo "    would: workqueue cpumask -> $wq_hex"
            else echo "$wq_hex" > /sys/devices/virtual/workqueue/cpumask 2>/dev/null \
                 && echo "wd-irq-affinity: unbound workqueue cpumask -> $wq_hex (cpus $OS_CPUS,$WD_DECODER_CPUS)"
            fi
        fi
    fi
fi
exit 0
