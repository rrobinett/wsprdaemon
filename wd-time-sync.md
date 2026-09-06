# Clock discipline (chrony)

WSPR and FST4W decoding need the system clock within about a second of UTC, and every
wav file WD records is stamped with it.  Sites have lost that in two ways: no time daemon
running at all, and (N8UR, 2026-09-06) systemd-timesyncd polling only a DHCP-advertised LAN
server that never answered.  timesyncd does not fall back to its pool servers while a DHCP
server is configured, so that clock drifted 7 s slow while WD logged one WARNING nobody saw.

Since 2026-09-06 WD enforces **chrony**, which polls every configured source and ignores the
ones that do not answer.  `wd-time-sync.sh` runs at every WD start, after wsprdaemon.conf is read:

1. installs chrony (apt removes systemd-timesyncd / ntp / ntpsec, which conflict with it) and
   stops + masks any of those still present;
2. adds well-known public pools as **extra** sources in `/etc/chrony/sources.d/wsprdaemon.sources`
   (or, on chrony < 4 without `sourcedir`, in a marked block in `/etc/chrony/chrony.conf`).
   Servers from the distro's chrony.conf and from DHCP are still used and win when they answer:
   a GPS-disciplined LAN server is stratum 1, the pools are stratum 2;
3. appends `makestep 1 -1` in a marked block at the end of chrony.conf so any offset over 1 s is
   stepped at any time, not only during chrony's first three updates (the distro default);
4. on `wda` / service start waits up to `WD_TIME_SYNC_WAIT_SECS` (30) for chrony to report a
   synchronised clock.  If it can't, an ERROR with every source and what it answered goes to the
   terminal, the WD log, stderr (so `wdj` / `journalctl -u wsprdaemon` shows it) and
   `/var/log/wsprdaemon/time-sync.log`;
5. the watchdog re-checks every `WD_TIME_SYNC_CHECK_MINUTES` (10) and logs an ERROR line for as
   long as the clock is unsynchronised, and one line when it recovers.

## wsprdaemon.conf

| variable | default | meaning |
|---|---|---|
| `WD_TIME_SYNC` | `chrony` | `no` = this site manages its own time daemon; WD changes nothing and only checks and complains |
| `WD_NTP_SERVERS` | `pool.ntp.org time.google.com time.cloudflare.com time.nist.gov` | extra sources, each written as `pool <name> iburst` |
| `WD_TIME_SYNC_WAIT_SECS` | `30` | how long a WD start waits for sync before complaining |
| `WD_TIME_SYNC_CHECK_MINUTES` | `10` | watchdog re-check interval |
| `WD_TIME_SYNC_MAX_OFFSET_SECS` | `1` | "synchronised" also requires the offset to be below this |

## Looking at it

`wdt` (`wd -t`) prints `chronyc tracking`, `chronyc sources -v` and the tail of time-sync.log.
In `chronyc sources`, `^*` marks the source in use and `^?` one that has never answered; a
site whose every source is `^?` cannot reach UDP port 123 (firewall), or has no route out.
