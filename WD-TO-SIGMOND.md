# wd-to-sigmond.sh — moving a WsprDaemon station to bare-metal Sigmond

`wd-to-sigmond.sh` converts an RX888 WsprDaemon station into a bare-metal (repo) Sigmond install,
and can put it back. It is generalized from the hand conversion of KJ6MKI (RAC 84) on
2026-10-27/28, plus everything that station's first align, first reboot and first weeks turned up
(2026-11-11/12).

Run it **on the station, as the WsprDaemon user** (passwordless sudo). Never run it under sudo:
`smd` refuses that. Each phase leaves a marker in the bundle directory, and the next phase refuses
to run until it finds one.

It never touches `wd-remote-access@*` (the RAC tunnel you arrive over), the WsprDaemon git tree,
PostgreSQL or the desktop session. `sigmond-rac` is never activated, because running it beside
`wd-remote-access` could cut the only way in.

## Phases

| Phase | What it does |
|---|---|
| `check` | Read-only. Is this station a candidate, and what will not carry over (MERG_ receivers, WWV/GRAPE, missing python3.11-dev). |
| `bundle` | Captures the revert bundle under `~/wd-to-sigmond/bundle-*`. Read-only for the running stack. |
| `handover` | Stops and disables the WsprDaemon stack, which frees the RX888. |
| `prep` | Moves legacy radiod confs out of Sigmond's way, removes WD's host tuning (wd-cpu-freq, wd-resctrl, wd-irq-affinity) and resets the CPU clock limits to the hardware range, handles WD's systemd manager CPUAffinity, and installs python3.11-dev on Ubuntu 22.04. |
| `install` | Clones and installs Sigmond, then `smd bringup wd`. If wsprdaemon.conf recorded WWV, it also installs hamsci-physics and hf-timestd (see [PSWS / GRAPE](#psws--grape)). |
| `post` | The fixes KJ6MKI needed after bring-up (listed below). Stages kernel isolation. |
| `reboot` | Reboots to activate isolcpus, nohz_full and rcu_nocbs. |
| `verify` | After the reboot: isolation, IRQs, CPU clocks, RX888 at 5 Gbps, services, decoders, spots, GRAPE and the PSWS key. |
| `restore [--check]` | Puts the station back on WsprDaemon from the bundle. |

Typical run:

```bash
./wd-to-sigmond.sh check
./wd-to-sigmond.sh bundle
./wd-to-sigmond.sh handover
./wd-to-sigmond.sh prep
./wd-to-sigmond.sh install
./wd-to-sigmond.sh post
./wd-to-sigmond.sh reboot
./wd-to-sigmond.sh verify     # after you are back in
```

`install` options: `--profile NAME` (default `wd`), `--reporter ID`, `--grid LOCATOR`,
`--callsign CALL`, `--yes`. Global options: `--bundle DIR`, `--dry-run`, `--yes`.

## What `post` fixes, in order

1. **Checkout ownership.** git refuses to fetch or pull a checkout with mixed ownership. Root-owned checkouts under `/opt/git/sigmond` go to `sigmond`, and stray files in each `.git` go to the checkout's owner.
2. **`smd align --apply`.** Aligns every component to the blessed release. It installs nothing new and never installs `sigmond-rac`.
3. **FT4/FT8 SSRC collision.** WD's template lists 8 m (40.680 MHz) under both FT8 and FT4, and ka9q-python derives one SSRC for both, so one channel silently drops. `post` removes the duplicate from FT4.
4. **systemd manager affinity.** Replaces WD's `radiod-cpu-affinity.conf` with `sigmond-cpu-affinity.conf` (everything except radiod's cores) and moves PID 1 there with taskset, because `daemon-reexec` does not narrow it.
5. **Kernel isolation.** Sets `write_kernel_isolation = true`, runs `smd admin diag cpu-affinity --apply` (isolcpus, nohz_full and rcu_nocbs on radiod's cores, the FFT core included), masks irqbalance and enables `sigmond-guest-irq-affinity`, which moves every movable IRQ to the first non-radiod core pair.
6. **CPU clocks.** See [CPU clock policy](#cpu-clock-policy).
7. **IGMP querier.** A 130 s root listen. Installs `igmp-querier` if the LAN has no querier.
8. **Upload routing.** See [Uploads](#uploads-wd-servers-only).
9. **PSWS / GRAPE.** See [PSWS / GRAPE](#psws--grape).
10. **Releases uploads** (`smd sink upload`) after a prompt, then prints `smd status`.

## CPU clock policy

`prep` removes WsprDaemon's `wd-cpu-freq` service and resets every core's clock limits, so WD's
caps cannot fight Sigmond's. `post` then applies Sigmond's own policy:

```bash
smd admin diag cpu-freq --apply
```

- **radiod's cores** are pinned at one fixed clock (scaling_min == scaling_max; 3.2 GHz on KJ6MKI's 5560U). A steady clock keeps the FFT's timing predictable. Expect the FFT's CPU percentage to rise a little at a lower fixed clock (KJ6MKI: 44% → 49%). That does not mean more work.
- **The other cores** (decoders, recorders, the rest of the system) run the powersave governor with a lower cap. On AMD's amd-pstate driver in active mode the cap cannot go below the nominal clock, so a 1.4 GHz cap really runs at about 2.4 GHz. If FT8 decodes start running long, look at this cap first.
- `smd-cpu-freq.service` re-applies the policy at every boot.

`verify` fails if `smd-cpu-freq.service` is not enabled, or if any radiod core is not pinned
(min ≠ max).

## Uploads: WD servers only

A converted station uploads **only to the WD servers**, as it did under WsprDaemon. WD30's
forwarders post onward to wsprnet.org and pskreporter.info; the station posts nowhere directly.
`post` sets this with:

```bash
smd config reporters --wsprnet-proxy on
smd config upload psk-recorder <reporter> --on --via server-merge
smd config upload meteor-scatter <reporter> --on --via deposit     # only if meteor-scatter runs
```

It warns if hs-uploader still runs a direct wsprnet pipeline.

> **Caution — `smd sink upload` and `smd admin uploader manifest --write` regenerate
> `/etc/hs-uploader/pipelines.toml`.** Before sigmond 7df8c7d that rewrite added direct
> PSKReporter pipelines and swapped the gateway key (KJ6MKI, 2026-11-12). Since 7df8c7d it keeps
> the WD-only routing and the station's `id_rsa_wsprdaemon` key, and shows a diff first. Run
> `smd admin uploader manifest` (read-only) before any `--write`, and read the diff.

## PSWS / GRAPE

This applies only where wsprdaemon.conf recorded WWV (a WWV/WWVB band in a `WSPR_SCHEDULE`
line), in other words to stations that uploaded GRAPE under WsprDaemon.

**`install`**
- Installs `hamsci-physics` first: hf-timestd needs it as a path dependency and fails to install without it.
- Installs `hf-timestd`.
- Runs `smd config init` for both. The GRAPE upload pipeline (`grape-psws`) is only generated once hamsci-physics has its config.

**`post`**
1. Copies WD's ids over: `PSWS_STATION_ID` and `PSWS_DEVICE_ID` from wsprdaemon.conf become
   `smd config psws --station <id> --instrument hf-timestd=<device id>`. The station keeps its
   existing PSWS station and instrument; no new account is needed.
2. Starts `grape-daily.timer`. It packages each UTC day at about 01:00 UTC; without it no GRAPE dataset is built and nothing uploads. The install links it but has been seen to leave it inactive.
3. Runs the PSWS key check below. Here a refused key is only a WARN, because the operator may not have registered it yet.

**Operator step (cannot be automated):** log in at <https://pswsnetwork.eng.ua.edu/>, open the
station and add the public key the script printed. Under Sigmond the uploader uses its own key,
so the key WD used for GRAPE will not do.

### The PSWS key check

A converted station keeps `id_rsa_wsprdaemon` as hs-uploader's main key, because the WD gateways
know it. PSWS knows only the key registered at its portal; on KJ6MKI that is `id_ed25519_host`,
and PSWS refuses `id_rsa_wsprdaemon`. `smd psws verify` tests Sigmond's idea of "the machine's
PSWS key", which is not always the key the GRAPE pipeline actually uses. It has passed while the
generated pipeline would have been refused.

So the script finds the key `grape-psws` really uses (its transport's `ssh_key_file`, else the
manifest's `[identity]` key, searching `pipelines.toml` and `pipelines.d/*.toml`). It then runs a
**login-only** SFTP test as the hs-uploader user, with `IdentitiesOnly=yes` so ssh cannot fall
back to another key. Nothing is uploaded. If PSWS refuses, the script prints the public key to
register.

`verify` fails if `grape-daily.timer` is inactive or if PSWS refuses the GRAPE key.

To check by hand on any Sigmond station:

```bash
smd psws status      # offline: station id, instrument ids, key path, last verified
smd psws verify      # live login as the station id (no upload)
```

## After the conversion

- Logs and markers are in the bundle: `~/wd-to-sigmond/bundle-*/{post,verify-*}.log`.
- `verify` also works on a station converted before this script existed (it then keeps no log).
- `restore --check` lists what a restore would stop, without stopping anything.
