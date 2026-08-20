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
set -u
PLAN_CMD="${WD_CPU_PLAN:-/usr/local/sbin/wd-cpu-plan.sh}"
MATCH="${MATCH:-xhci_hcd}"
DRY="${DRY_RUN:-0}"
OS_CPUS="${OS_CPUS:-}"
if [ -z "$OS_CPUS" ]; then
    plan=$("$PLAN_CMD" 2>/dev/null) && eval "$plan"
    OS_CPUS="${WD_OS_CPUS:-}"
fi
[ -n "$OS_CPUS" ] || { echo "wd-irq-affinity: no OS cpu list available; leaving IRQs unmanaged"; exit 0; }

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
exit 0
