# Some typical problems

## Consider usb loading issues.  
- is the RX888 plugged into a USB3 superspeed socket?
- has radiod successfully loading the firmware to the RX888?

## Consider system service issues
- systemctl service enabled? 
- configured to always restart on boot?
- does your computer or OS support what you want the RX888 or wsprdaemon to do?
- for Beelink, set the fan to 'auto' with the fan turning on at 40C and getting to max speed at 60C with at ramp of '8' 
- have you configured the computer to resume function after loss/restoration of power?

## Consider avahi address translation issues
- avahi installed (see pre-requisite libraries)

## Consider ethernet hubs/architecture

- ttl = 0 by default (assuming a stand-alone setup) so as not to flood the LAN or WLAN with multicast packets
- if using multicast between computers, ttl = 1 required on sending computer and on the right NIC
- multicast will require an IGMP-capable switch with snooping ON to isolate the computers using radiod multicast from the rest of your LAN or WLAN, particularly if your LAN uses WiFi. 
- have you defined and enabled a device in radiod@rx888-XXX.conf?

## Brute force recovery

One method of recovery involves, in effect, starting from (almost) scratch.

The important "almost" refers to preserving your configuration.  DON'T FORGET THIS!

First, critically, copy your ~/wsprdaemon/wsprdaemon.conf file to somewhere safe, e.g., the home directory:
```
cp ~/wsprdaemon/wsprdaemon.conf ~
```
Then delete the wsprdaemon subdirectory:
```
rm -rf ~/wsprdaemon/
```

Clean out /shm/wsprdaemon:
```
rm -rf /shm/wsprdaemon/*
```

Clone the WD repository (while in /home/wsprdaemon/):
```
git clone https://github.com/rrobinett/wsprdaemon.git
```

Copy the wsprdaemon.conf back into the new ~/wsprdaemon:
```
cp ~/wsprdaemon.conf ~/wsrdaemon
```

Run wd to get everything built and installed:
```
wd
```

Restart WD:
```
wda
```

Check the usual places (see above) to ensure things are functioning as expected.