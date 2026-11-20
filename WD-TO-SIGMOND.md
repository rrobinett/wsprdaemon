# wd-to-sigmond.sh — moving a WsprDaemon station to bare-metal Sigmond

`wd-to-sigmond.sh` converts an RX888 WsprDaemon station into a bare-metal (repo) Sigmond install,
and can put it back. It is generalized from the hand conversion of KJ6MKI (RAC 84) on
2026-10-27/28, plus everything that station's first align, first reboot and first weeks turned up
(2026-11-11/12).

Run it **on the station, as the WsprDaemon user** (passwordless sudo). Never run it under sudo:
`smd` refuses that. Each phase leaves a marker in the bundle directory, and the next phase refuses
to run until it finds one.

Until the optional `rac` phase, it never touches `wd-remote-access@*` (the RAC tunnel you arrive
over), the WsprDaemon git tree, PostgreSQL or the desktop session. `sigmond-rac` is never
activated, because running it beside `wd-remote-access` could cut the only way in. Once Sigmond's
own tunnel has been set up and works, `rac` retires the WD tunnel (see
[Moving RAC to Sigmond's tunnel](#moving-rac-to-sigmonds-tunnel)).

## Phases

| Phase | What it does |
|---|---|
| `check` | Read-only. Is this station a candidate, and what will not carry over (MERG_ receivers, WWV/GRAPE, missing python3.11-dev), and lists the station's own radiod channels that `post` will carry over. Warns about station scripts that still poll radiod as `hf.local` (see [Station scripts that use hf.local](#station-scripts-that-use-hflocal)). Finds the RAC tunnel in either form, `wd-remote-access@gw*` or the legacy `wd-remote-access.service`. |
| `bundle` | Captures the revert bundle under `~/wd-to-sigmond/bundle-*`. Read-only for the running stack. |
| `handover` | Stops and disables the WsprDaemon stack, which frees the RX888. |
| `prep` | Moves legacy radiod confs out of Sigmond's way, removes WD's host tuning (wd-cpu-freq, wd-resctrl, wd-irq-affinity) and resets the CPU clock limits to the hardware range, handles WD's systemd manager CPUAffinity, and installs python3.11-dev on Ubuntu 22.04. |
| `install` | Clones and installs Sigmond, then `smd bringup wd`. If wsprdaemon.conf recorded WWV, it also installs hamsci-physics and hf-timestd (see [PSWS / GRAPE](#psws--grape)). |
| `post` | The fixes KJ6MKI needed after bring-up (listed below). Stages kernel isolation. Carries the station's own radiod channels into Sigmond's radiod conf. |
| `reboot` | Reboots to activate isolcpus, nohz_full and rcu_nocbs. |
| `verify` | After the reboot: isolation, IRQs, CPU clocks, RX888 at 5 Gbps, services, decoders, spots, GRAPE, the station's own radiod channels and any ignored `conf.d` fragment, hs-uploader's key ownership, the RAC login the gateway dashboard shows (and a warning while two tunnels run), station scripts still naming `hf.local`, the WD gateway SFTP login and the PSWS key. |
| `rac` | Optional, once Sigmond's RAC tunnel is set up. Corrects the ssh login it advertises to the gateway dashboard, then, from a session over that tunnel, stops and disables `wd-remote-access`. |
| `restore [--check]` | Puts the station back on WsprDaemon from the bundle. Re-enables a WD tunnel that `rac` retired before it stops anything, and leaves Sigmond's tunnel running. |

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
8. **The station's own radiod channels.** See [Station radiod channels](#station-radiod-channels).
9. **Upload routing.** See [Uploads](#uploads-wd-servers-only).
10. **PSWS / GRAPE.** See [PSWS / GRAPE](#psws--grape).
11. **hs-uploader's keys.** hs-uploader runs as `hsupload`; any key it names that `hsupload` cannot read is chowned to it (VK5ARG: `id_ed25519` was left `wsprdaemon`-owned, mode 600).
12. **Releases uploads** (`smd sink upload`, no prompt: a migrated station always ends uploading) **once gw1 and gw2 accept the uploader's SFTP login**; if a gateway refuses it, uploads stay held and `verify` releases them after the account is fixed (see [The WD gateway SFTP account](#the-wd-gateway-sftp-account)); then prints `smd status`.

## Station radiod channels

Operators add their own channels to WD's radiod conf: VK5ARG had `[HFAPRS]`, `[SSTV_USB]` and `[SSTV_LSB]` (9 channels) for HF APRS and SSTV decoders. `prep` moves WD's conf to `/etc/radio.legacy-wd/` and Sigmond writes a fresh minimal `radiod@<instance>.conf` with no channels at all, because its own clients (wspr-recorder, psk-recorder, hf-timestd, hfdl-recorder, ka9q-web) create theirs dynamically. Before this step existed, the operator's channels just disappeared.

`post` reads the legacy conf exactly as radiod would have and appends every **enabled** section to the new conf, except:

- `[global]` and hardware sections (any with `device =` or `hardware =`);
- what Sigmond replaces: `[WSPR]`, `[WSPR-IQ]`, `[FT8]`, `[FT4]`, `[ft8-*]`, `[WWV*]`, `[CHU*]`, `[HF MANUAL]`, `[HFDL*]`, and anything whose `data =` group is a WSPR/FT/WWV/CHU/HFDL/hf-pcm/dynamic one.

It keeps a dated backup beside the conf, skips sections already present (so it is safe to re-run), restarts radiod and prints its `[name] N channels started` lines. If WD had several radiod instances and Sigmond's names don't match them, it doesn't guess: it lists the sections to move by hand. The operator's own decoders for those streams have to be restarted on their side.

**Do not put channels in `radiod@<instance>.conf.d/`.** radiod reads `radiod@<instance>.conf` **or** the `.conf.d` directory, never both (ka9q-radio `radio.c` `loadconfig`). While the `.conf` file exists, which it always does under Sigmond, every fragment in the directory is silently ignored. Sigmond's generated header currently says the opposite; that is a Sigmond bug. VK5ARG's operator followed that header and his restart picked up nothing. `verify` FAILs on any `*.conf` file in a `.conf.d` that sits beside a `.conf`, and on any carried-over channel that is missing from the new conf.

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
> the WD-only routing and the station's `id_rsa_wsprdaemon` key, and shows a diff first; since
> 74b62a7 it gives `grape-psws` its own PSWS key. Run `smd admin uploader manifest` (read-only)
> before any `--write`, and read the diff. In scripts, its exit code is 0 when the file is up to
> date and 1 for drift *or* failure: read stdout ("is up to date", "DRIFT —", "would create" mean a
> clean read; a line on stderr starting "uploader:" is a failure).
>
> A hand-placed `/etc/hs-uploader/pipelines.d/<client>.toml` replaces every rendered pipeline of
> that client (the render says so). Remove it when you want the render to own that client again.

## PSWS / GRAPE

This applies only where wsprdaemon.conf recorded WWV (a WWV/WWVB band in a `WSPR_SCHEDULE`
line), in other words to stations that uploaded GRAPE under WsprDaemon.

**`install`**
- Installs `hamsci-physics` first: hf-timestd needs it as a path dependency and fails to install without it.
- Installs `hf-timestd`.
- Runs `smd config init` for both. The GRAPE upload pipeline (`grape-psws`) is only generated once hamsci-physics has its config.
- Since sigmond 6ce1bc5, `smd install` also starts `grape-daily.timer`, which packages each UTC day at about 01:00 UTC. Without it no GRAPE dataset is built and nothing uploads.

**`post`**
1. Copies WD's ids over: `PSWS_STATION_ID` and `PSWS_DEVICE_ID` from wsprdaemon.conf become
   `smd config psws --station <id> --instrument hf-timestd=<device id>`. The station keeps its
   existing PSWS station and instrument; no new account is needed.
2. Runs the PSWS key check below. Here a refused key is only a WARN, because the operator may not have registered it yet.

**Operator step (cannot be automated):** log in at <https://pswsnetwork.eng.ua.edu/>, open the
station and add the public key the script printed. Under Sigmond the uploader uses its own key,
so the key WD used for GRAPE will not do.

### The PSWS key check

A converted station keeps `id_rsa_wsprdaemon` as hs-uploader's main key, because the WD gateways
know it. PSWS knows only the key registered at its portal; on KJ6MKI that is `id_ed25519_host`,
and PSWS refuses `id_rsa_wsprdaemon`. Since sigmond 74b62a7 the render gives `grape-psws` its own
`ssh_key_file = id_ed25519_host`, and `smd psws enroll/status/verify` name that same key. (Before
74b62a7, `smd psws verify` could pass while the generated pipeline would have been refused.)

The script keeps its own check as an independent confirmation, and because a hand-placed
`pipelines.d` drop-in can override the render. It finds the key `grape-psws` really uses (its transport's `ssh_key_file`, else the
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

## The WD gateway SFTP account

hs-uploader's `wspr-wsprdaemon` pipeline sends each cycle's WSPR and FT spots as a tar to
`gw1.wsprdaemon.org` and `gw2.wsprdaemon.org` by SFTP, logging in as its `sender` (the reporter)
with the `[identity]` key Sigmond made at install. That account must exist on **both** gateways,
in the `sftponly` group, with that key, before uploads are released. WsprDaemon 3.3 and older
uploaded by FTP (`noisegraphs`), so such a station may never have had one.

What happens without it (VK5ARG, 2026-11-14/15): every upload is an sshd `Invalid user <sender>`.
The gateways' fail2ban jail `sshd-invalidusers` bans the station's IP after 5 of those in 24 hours,
**for 10 years, on all ports**. That includes frpc's port 35735, so the RAC tunnel goes down along
with the uploads. The station still shows `wd-remote-access` as running, and frps logs a clean
`client exit success`, so it looks like the problem is on the station. It isn't: the spots
queue locally and nothing reaches wsprnet.

`post` and `verify` each test one login per gateway (login only, nothing uploaded; each failed
test costs one fail2ban strike). If a gateway refuses the login:

- `post` does not release uploads, and holds them with `smd sink fill` if they were already
  released. `verify` fails and holds them the same way.
- Both print the account recipe and the public key to install:

  ```bash
  # as root on each gateway that refuses
  useradd -m -s /bin/false -G sftponly <SENDER>
  chown root:root /home/<SENDER>; chmod 755 /home/<SENDER>        # chroot needs a root-owned home
  install -d -o <SENDER> -g <SENDER> -m 700 /home/<SENDER>/.ssh
  install -d -o <SENDER> -g <SENDER> -m 755 /home/<SENDER>/uploads
  echo '<the printed key>' > /home/<SENDER>/.ssh/authorized_keys
  chown <SENDER>:<SENDER> /home/<SENDER>/.ssh/authorized_keys; chmod 600 /home/<SENDER>/.ssh/authorized_keys
  fail2ban-client banned <station public IP>    # then unbanip it in each jail that lists it
  ```

While uploads are held, Sigmond keeps WSPR spots for 24 hours but FT8 spots for only one hour,
so make the account promptly, then run `verify`, which releases the uploads.

`smd remote` cannot restore access on a converted station: there is no `sigmond-rac` there, and
the station's RAC is still WsprDaemon's tunnel, unless `rac` has moved it to Sigmond's.

## Station scripts that use hf.local

WsprDaemon's radiod publishes its status and control stream as `hf.local`. Sigmond's radiod names
it after its instance, `<instance>-status.local` (normally the host name), so after the conversion
nothing answers `hf.local`. `metadump` and `control` retry a name that doesn't resolve forever. A
cron job that polls it therefore never exits, and the runs pile up.

On VK5ARG (2026-11-15), the operator's 2-minute InfluxDB stats job left 520 stuck runs. They filled
12 GB of RAM and 4 GB of swap, and the out-of-memory killer then restarted radiod 60 times and the
recorders about 100 times.

`check` and `verify` search the station's home directories, crontabs and systemd units for
`hf.local`. They skip WsprDaemon's own trees, venvs, logs, backups, docs, C source and comment-only
lines.
- **Warned:** hits in a file that cron or systemd runs, or in the same directory as one (its helper
  or library). A function default that the cron line overrides is harmless, but it is listed so
  you can tell.
- **Listed as INFO:** everything else.

The fix is to repoint the script at the new name and wrap each cron run so a hang can't pile up:

```bash
exec flock -n /tmp/<job>.lock timeout -k 10 60 <command>
```

`timeout` kills the whole process group, `metadump` included, and `flock` skips a run while the
last one is still going.

## Moving RAC to Sigmond's tunnel

The conversion keeps the station's WsprDaemon RAC tunnel. If Sigmond's RAC tunnel
(`sigmond-rac-host@<gw>`) is set up later, both run side by side, on two RAC numbers. VK5ARG ran
RAC 137 (WD) and RAC 532 (Sigmond) that way until 2026-11-15. `rac` finishes the move:

1. **Dashboard login.** The gateway dashboard copies `ssh -p <port> <user>@<gw>` from the user that
   the tunnel's `-vm-ssh` proxy advertises. Sigmond's wizard defaults that user to `hamsci`, the
   account on a Proxmox appliance VM. A bare-metal station has no such account, so the copied
   command fails. If the advertised user is not an account on the station, `rac` sets it to the
   WsprDaemon user, keeps a backup of the frpc config, and restarts the tunnel. If you are logged in
   over that same tunnel, the restart is detached and your session drops: log in again the same way
   and rerun `rac`.
2. **Retire the WD tunnel.** `rac` checks which tunnel carries your ssh session. It refuses while
   you are on the WD tunnel, so it can never cut the session it runs in. Log in over Sigmond's
   tunnel (gateway port `35800 + RAC`, same user as before) and rerun. Once frpc reports the ssh
   proxy running and you are in over it, `rac` asks, then stops and disables `wd-remote-access`.
   It records what it disabled in the bundle (`rac-legacy-disabled.txt`).

`restore` re-enables and starts those units first, before it stops anything. It leaves Sigmond's
tunnel running and prints the command to stop it once you are back in over the WD one.

Since sigmond 5887f1a, the wizard keeps the login already in the station's frpc config, and otherwise picks the station's own user rather than `hamsci`, so a rerun no longer undoes this. Stations set up with an older wizard still need `rac`, and `verify` flags them.

## After the conversion

- Logs and markers are in the bundle: `~/wd-to-sigmond/bundle-*/{post,verify-*}.log`.
- `verify` also works on a station converted before this script existed (it then keeps no log).
- `restore --check` lists what a restore would stop, without stopping anything.
