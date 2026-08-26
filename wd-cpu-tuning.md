# radiod CPU / cache tuning

Eliminates radiod FFT block-drops by isolating radiod from the WSPR decoders on CPU
cores and on L3 cache. Validated at two sites running RX888s at 129.6 Msps: **zero
front-end drops over 13 h** (KX4AZ-T, 8C/16T + 16 MB L3, two RX888s) and **8 h 45 m**
(KJ6MKI, 6C/12T + 8 MB L3, one RX888) — both at **stock `ND=4`**.

## The scripts

| script | when it runs | what it does |
|---|---|---|
| `wd-cpu-plan.sh` | on demand | Reads the real CPU topology and cache geometry, prints a sourceable plan. Single source of truth. |
| `radiod-pin-threads.sh <instance>` | `ExecStartPost=` of `radiod@<instance>` | Pins `fft` and `proc_rx888` to separate physical cores. |
| `wd-resctrl-setup.sh` | boot (oneshot unit) | Applies the L3 CAT partition. |
| `wd-irq-affinity.sh` | boot (oneshot unit) | Pins USB (xhci) IRQs to the OS core. |

The last three take their CPU lists from `wd-cpu-plan.sh`. Nothing is hard-coded to a host.

## Why each piece matters

- **radiod off core 0.** Core 0 carries the kernel's IRQ/housekeeping load. Moving radiod
  off it was the single most effective change.
- **Two physical cores per radiod, `fft` and `proc_rx888` on separate ones.** These are the
  two hot threads. Sharing one physical core they contend for its execution units, L1 and
  L2. Separating them cut CPU for *identical* work by 33 points at KJ6MKI (145% → 112%) and
  took the fft core's worst-case idle from 4.4% to 29%.
- **Decoders excluded from radiod's cores**, via the WD cgroup cpuset and `WD_CPU_CORES`.
- **L3 CAT partition**, so decoders cannot evict radiod's FFT working set.
- **USB IRQs pinned.** The RX888 arrives over USB. Left alone the xhci IRQ was found parked
  on a decoder core at both sites — and at one site with an *unrestricted* affinity mask,
  meaning it could land directly on a radiod core after any reboot.

`ND` (the FFT ring-buffer depth in `filter.h`) is **not** part of the fix. Both sites run
stock `ND=4`. Enlarging it only masks the symptom.

## Topology is detected, not assumed

SMT siblings are **not** always adjacent. Some machines pair CPU0 with CPU8. A hard-coded
"cores 2,3" would then straddle two different physical cores and quietly defeat the whole
point. `wd-cpu-plan.sh` groups logical CPUs by their real core id from `lscpu -p=CPU,CORE,SOCKET`
and emits sparse lists (e.g. `0,8`) where appropriate. It also handles no-SMT hosts, and on a
host too small to isolate anything it reports `WD_PLAN_OK=no` and recommends leaving affinity
unmanaged rather than applying a bad pinning.

## Per-site overrides

Optional `/etc/wd-cpu-plan.conf`, sourced by `wd-cpu-plan.sh`:

```sh
RADIOD_L3_FRACTION=0.8125   # fraction of L3 ways given to radiod (default 0.62)
MIN_DECODER_WAYS=3          # floor on the decoders' ways (default 4)
RADIOD_INSTANCES=2          # override auto-detection
RADIOD_NAMES="dipole ns-bev"
```

Do not starve the decoders. A component squeezed into a tiny partition generates L3-miss
traffic that saturates the DRAM bus and hurts everything, radiod included — observed at
KX4AZ-T when a stale hard-coded `cpus_list` left one radiod inside the decoders' 3 MB
partition: identical work, 86.9% CPU vs 75.0% for its twin.

## Checking it

`DRY_RUN=1` on any of the three consumers prints what would change and touches nothing.
Drop counts come from `control <status-stream>`; the front-end **Drops** count is the metric
that matters, not FFT %CPU. Note radiod's Uptime string switches from `MM:SS` to `H:MM:SS`
at one hour, so do not detect restarts by parsing it — use
`systemctl show radiod@<inst> -p NRestarts,ActiveEnterTimestamp`.

## Where to see the drop counts

`watchdog_daemon()` samples every radiod on this host and appends to
**`/var/log/wsprdaemon/drops.log`** (see `wd-drops.sh`), capped by
`/etc/logrotate.d/drops.rotate` at 1 MB x 5. No separate service is involved.

```
# utc_time              status_stream           block_drops
2026-08-20T13:14:00Z    dipole-status.local     0
```

A **decrease** means radiod restarted and the counter reset. Tunables (set in
`wsprdaemon.conf`): `WD_DROPS_ENABLED`, `WD_DROPS_LOG_MINUTES` (default 10),
`WD_DROPS_SSRC` (default 14080 -- poll the same ssrc every time or samples are not
comparable), `WD_DROPS_TIMEOUT`.

## How it is enabled

WD reports the planned layout on every start, and whether the running system matches it. It does
**not** change the machine unless you opt in:

```sh
WD_CPU_TUNING="yes"     # in wsprdaemon.conf; default is "no"
```

When `WD_CPU_TUNING="yes"`, **`WD_CPU_CORES` and `RADIOD_CPU_CORES` in `wsprdaemon.conf` are
ignored** -- the plan owns the layout and WD stops writing `CPUAffinity` into the unit files from
them. That is deliberate: two writers meant the unit file and the drop-in could disagree, and
`systemctl cat` would show two contradictory values. Those variables still work normally at sites
that leave `WD_CPU_TUNING` at its default of `no`.

**Check `/var/log/wsprdaemon/drops.log` before enabling it.** If the counts stay at 0 this host is
keeping up and does not need tuning. Only turn it on if you are actually losing blocks.

Reporting needs no privileges. Applying installs the helper scripts to `/usr/local/sbin`, writes the
systemd drop-ins, sets the L3 partition and pins the USB IRQs. It is idempotent, it never restarts
radiod for a cosmetic change, and it reports which units need a restart rather than restarting them
itself. radiod picks up new CPU affinity on its next restart.

To undo: set `WD_CPU_TUNING="no"`, remove the generated drop-ins
(`/etc/systemd/system/radiod@*.service.d/cpu-affinity.conf`,
`/etc/systemd/system/wsprdaemon.service.d/cpu-affinity.conf`,
`/etc/systemd/system.conf.d/radiod-cpu-affinity.conf`), `systemctl disable --now wd-resctrl
wd-irq-affinity`, then `systemctl daemon-reload` and restart radiod.

## What a tuned host still shares: a measurement (KFS-NW, Aug 2026)

Even on a fully tuned host, radiod's `fft` thread costs more CPU while the WSPR decoders are
running. On KFS-NW (Ryzen 5 5560U, 6c/12t, 8 MB L3; radiod alone on cpus 2,3; decoders on
0,1,4-11; 5 MB exclusive L3 for radiod; irqbalance absent, all movable IRQs and unbound
workqueues herded to cpus 0,1) `fft` sits at 49% of CPU2 between cycles and rises to 56-59%
during each decode burst. If nothing else may run on its core and nothing may evict its cache,
why does it slow down?

Because the L3 partition protects cache **capacity**, and capacity is not what the burst takes
away. Sampled at 3-second intervals through a decode burst, using the MBM counters that come
free with the resctrl groups (`mon_data/mon_L3_00/mbm_total_bytes`):

```
phase          fft %CPU2   CPU2 clock   radiod mem BW   decoders mem BW
quiet             49%       3137 MHz      5.75 GB/s       0.6-0.9 GB/s
decode burst    56-59%      3125 MHz      5.7  GB/s       5.4-6.9 GB/s
```

Three things fall out of that table:

1. **radiod streams ~5.75 GB/s from DRAM all the time.** Every RX888 sample block is new data;
   it cannot be in any cache the first time `fft` touches it. Those are compulsory misses and no
   amount of L3 prevents them. The partition earns its keep on the *reused* state -- twiddle
   factors, filter overlap, channel buffers -- which is why the burst costs 10 points and not a
   meltdown.
2. **The decoders' burst doubles the load on the shared memory controller.** Their traffic jumps
   from under 1 GB/s to ~7 GB/s (the small 3 MB partition makes them miss more, by design).
   Queue latency at the DRAM controller / data fabric rises for every requester, radiod
   included. Each streaming load stalls longer, and a thread that stalls longer per access needs
   more busy cycles for the same real-time sample flow. Same work, slower memory, more %CPU.
3. **It is not frequency.** CPU2 held ~3.13 GHz flat through the burst, so boost droop --
   the usual suspect on a 15 W mobile part -- contributes nothing here.

The %CPU rise is the *visible price* of memory contention, not a fault. The number that decides
whether it matters is the drop counter, and it stays 0 with ~40% headroom at burst peak.

The one remaining lever would be AMD MBA (the `MB:` line in the resctrl schemata) to cap the
decoders' DRAM bandwidth. Testing at KX4AZ on a similar processor showed MBA to be a weak
control on this silicon: even aggressive settings reduced peak memory bandwidth by at most
~50%. Treat it as the last resort, not the next step -- and remember the decoders finishing
fast also gets them off the memory bus sooner.
