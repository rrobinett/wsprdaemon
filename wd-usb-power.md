# Power cycling a hung RX888 from software (uhubctl)

An RX888 that hangs, or that is stuck in the Cypress FX3 bootloader because its
firmware load keeps failing, used to be recoverable only by someone at the site
pulling its USB plug.  radiod exits at once ("no device with serial ..."), WD
reports the radio as NOT on the USB bus, and the station is silent until a person
visits.  KX4AZ-T sat like that on 2026-09-06.

If the RX888 is plugged into a hub that really switches VBUS per port, WD can
pull that plug itself with [uhubctl](https://github.com/mvp/uhubctl).

## What WD does

* Every `wd` command and every watchdog pass records where each programmed RX888
  serial sits (hub location and port, the `-l` / `-p` uhubctl wants) in
  `/var/log/wsprdaemon/rx888-ports.map`.  So when a radio vanishes WD still knows
  which port to cycle.
* At a WD start, before giving up on a `radiod@X` whose configured RX888 serial is
  not on the bus, WD power cycles the port that radio sits on (or was last seen
  on), waits for it to re-enumerate and load firmware, and starts radiod if it
  came back.
* When a device sits in the bootloader (`04b4:00f3`) and neither the udev rule
  nor a direct `rx888_boot` gets its firmware in, WD cycles that device's port.
* The watchdog cycles the port of any *enabled* `radiod@` instance that is not
  running because its RX888 is missing, and restarts that radiod when the radio
  comes back.  Never more than once per port per `WD_USB_POWER_CYCLE_MIN_MINUTES`
  (default 10), so a dead radio is not hammered.
* A radio on a 480 Mb/s USB 2 port is never cycled: it can not work there, and
  WD says so.  Move it to a USB 3 (SuperSpeed) port.
* `wd -a` installs the `uhubctl` package on hosts that have an RX888.

Only ERROR/WARNING lines reach the terminal; everything else goes to
`/var/log/wsprdaemon/usb-power.log`.

## Commands

    wd -u          (wd-usb, wdu)   RX888s on the bus, their hub/port, whether WD can
                                   switch that port, which radiod uses each, radiods
                                   whose radio is missing and where it was last seen,
                                   and the tail of usb-power.log
    wd -U SERIAL   (wd-usb-cycle)  power cycle the port that RX888 sits on / was last on
    wd -U HUB:PORT                 power cycle that port, e.g. wd -U 2-1:3
    wd -U all                      cycle every RX888 WD has seen

`sudo uhubctl` with no arguments lists the hubs on the host that can switch power,
with the `-l` location of each.  If it lists nothing, no hub here qualifies.

## wsprdaemon.conf

    WD_USB_POWER_CYCLE="yes"            "no" disables the cycling; the bookkeeping and 'wd -u' still work
    WD_USB_POWER_CYCLE_MIN_MINUTES=10   never cycle the same port more often than this
    WD_USB_POWER_OFF_SECS=5             how long the port stays off
    WD_USB_POWER_REENUM_SECS=25         how long to wait for the radio to come back

## Which hub

Almost every hub advertises "per-port power switching" in its USB descriptors, and
almost none actually cut power to the port: the LED goes out and the device stays
powered.  Only hubs on uhubctl's tested list
(https://github.com/mvp/uhubctl#compatible-usb-hubs) work.

Recommended: the RSHTECH (sold as Rosonway on the uhubctl list) 10 port powered
USB 3 hub, 60 W supply, 3 × 10 Gb/s + 7 × 5 Gb/s ports with a switch per port,
https://www.amazon.com/dp/B0DX6KR79L .  Its siblings RSH-A10 and RSH-ST10C-6 are
on the tested list.  Whatever hub you buy, confirm it with `sudo uhubctl` after
plugging it in: it must appear in the list, and `wd -u` must show `switchable yes`
on the RX888's line.

Rules for the RX888 behind a hub:

* The hub must be USB 3 and plugged into a USB 3 port on the computer, and the
  RX888 must be on one of the hub's USB 3 ports.  Check with `lsusb -t`: the
  RX888's line must say 5000M or 10000M, never 480M.
* Use the hub's own power supply.  An RX888 draws too much for bus power, and a
  hub without its own supply can not switch anything.
* One RX888 per hub port, and note which port (`wd -u` shows it).
* Some root hubs (ports directly on the computer) can also be switched; `sudo
  uhubctl` lists them too if so.  Most can not.

## Without a switching hub

`wd-usbreset <bus-port>` (in bash-aliases) unbinds and rebinds the USB device,
which is a software reset only: it does not cut power and does not get a radio out
of the bootloader loop.  Otherwise it is a site visit.
