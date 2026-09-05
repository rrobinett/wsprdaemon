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
  took the fft core's worst-case idle from 4.4% to 29%. Measured again at KX4AZ-T in Sept 2026
  the penalty was far smaller (see *One physical core per radiod* below): what matters is that
  the two hot threads are **pinned to separate SMT siblings**, not that they have separate cores.
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
# utc_time              status_stream           block_drops   ssrc
2026-08-20T13:14:00Z    dipole-status.local     0             14096
```

A **decrease** means radiod restarted and the counter reset. Tunables (set in
`wsprdaemon.conf`): `WD_DROPS_ENABLED`, `WD_DROPS_LOG_MINUTES` (default 10),
`WD_DROPS_SSRC`, `WD_DROPS_TIMEOUT`.

`WD_DROPS_SSRC` is unset by default: WD listens to the first static channel group of each
radiod (e.g. `wspr-pcm.local`), takes the lowest ssrc it hears, and keeps polling that one
(remembered in `/var/log/wsprdaemon/drops.ssrc.<stream>`), so successive samples are
comparable. Do not set it to an ssrc radiod does not have: radiod answers a poll for an unknown
ssrc by *creating* a dynamic channel for it, which is how the old fixed default of 14080 left
WSPR-only sites growing a junk 0 Hz channel every ten minutes.

## How it is enabled

WD reports the planned layout on every start, and whether the running system matches it, and
since 2026-09-03 it applies the layout by default. To keep managing CPU affinity yourself and
get the report only, opt out:

```sh
WD_CPU_TUNING="no"      # in wsprdaemon.conf; default is "yes"
```

The planner declines hosts it cannot lay out sanely (`WD_PLAN_OK=no`, e.g. too few cores), and
`wd-cpu-apply.sh` rolls back rather than half-apply, so on such hosts the default changes nothing.

When `WD_CPU_TUNING="yes"`, **`WD_CPU_CORES` and `RADIOD_CPU_CORES` in `wsprdaemon.conf` are
ignored** -- the plan owns the layout and WD stops writing `CPUAffinity` into the unit files from
them. That is deliberate: two writers meant the unit file and the drop-in could disagree, and
`systemctl cat` would show two contradictory values. Those variables still work normally at sites
that set `WD_CPU_TUNING="no"`; with the default they are commented out of `wsprdaemon.conf` (with
a note and a backup) the first time the tuning runs, so the file does not contradict the system.

`/var/log/wsprdaemon/drops.log` tells you whether it is doing anything for you: if the counts
were already 0 the host was keeping up and the tuning is insurance.

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

## One physical core per radiod (KX4AZ-T, Sept 2026)

`CORES_PER_RADIOD_MAX=1` in `/etc/wd-cpu-plan.conf` gives each radiod one physical core:
`fft` on the first SMT sibling, `proc_rx888` and the channel threads on the second. Tested
live at KX4AZ-T (Ryzen 7 5825U, 8c/16t, two RX888s at 129.6 Msps, 45 channels each) by
re-pinning one running radiod with `taskset` while the other stayed on the 2-core plan as a
control, then made permanent. All numbers are the thread's own CPU time from
`/proc/PID/task/TID/stat` (note: `/proc/TID/stat` returns the *whole process*, not the thread).

```
layout                                        fft     proc_rx888   drops (4 min, 2 decode bursts)
2 cores: fft@2, proc_rx888@4, channels@3,5    79.9%     24.2%      0
1 core:  fft@2, proc_rx888+channels@3         81.0%     28.3%      0
1 core:  everything floating on 2,3           81.2%     28.6%      16 within seconds of the re-pin
```

- The one-core penalty is 1-4 points per hot thread, not the 33 points seen at KJ6MKI. The
  busy sibling (proc_rx888 plus 45 channel threads) sits at ~38%, peaks ~52%.
- **Never let the hot threads float over both siblings.** Both are `SCHED_FIFO`; when the
  scheduler puts them on the same sibling the front end drops blocks immediately.
  `radiod-pin-threads.sh` already pins them apart, so the planner's 1-core layout is safe.
- The two freed cores go to the decoders (or to a third RX888: the planner puts a third
  instance on the next core automatically).

**How much L3 does a radiod really need?** Shrinking the radiod CAT partition live with both
radiods running (fft is the only thread on its sibling, so that CPU's busy% is fft's own):

```
radiod partition        fft dipole   fft ns-bev   radiod DRAM BW   drops (2 min each)
10 ways = 5 MB each        62%          68%         10.4 GB/s       0
 7 ways = 3.5 MB each      66%          73%         11.1 GB/s       0
 5 ways = 2.5 MB each      73%          79%         11.6 GB/s       0
 3 ways = 1.5 MB each      85%          89%         12.4 GB/s       0
```

So three radiods sharing the default 10-way partition (3.3 MB each) cost each fft only 4-6
points; L3 is not what limits a third RX888 on this class of host. USB is: two RX888s at
129.6 Msps already occupy both SuperSpeed ports of one xHCI controller, so the third must go
on the second controller.

**64.8 Msps when the antenna feed has a 30 MHz low-pass filter.** At KX4AZ-T the 40.68 MHz and
50.3 MHz channels showed only the ADC floor (N0 -153 to -155 dB/Hz against -141 at 28 MHz),
so both RX888s were moved to 64.8 Msps and those channels removed. fft fell from 60-80% to
20-24% of its CPU, package power from 17-20 W to 8 W, drops stayed 0, and the noise floor at
14 MHz was unchanged. `wd-cpu-freq.sh` already notes that fft cost rises much faster than
linearly with sample rate; this is that effect in the other direction.

**The decoder clock cap.** On the 5825U with `amd-pstate` in active (EPP) mode every
`scaling_max_freq` at or below ~3.19 GHz produces the same 3.19 GHz (the CPPC nominal clock)
on a fully busy core: 1.4, 2.0, 2.5 and 3.0 GHz caps, `boost=0`, `EPP=power` and the
`performance` governor all measured 3.19 GHz with `turbostat`; only caps above nominal bite
(uncapped: 4.06 GHz). This confirms the 5560U observation in `wd-cpu-freq.sh`: the "1.4 GHz"
decoder cap really means "no boost". The decoders there run 40-54% busy per 10-minute average
at 3.19 GHz, so a true 1.4 GHz would not finish a cycle anyway.
