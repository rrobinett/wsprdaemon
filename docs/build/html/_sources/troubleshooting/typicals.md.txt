# Some typical problems

## consider usb loading issues.  
- RX888 plugged into a USB3 superspeed socket?
- radiod successfully loading the firmware?

## consider system service issues
- systemctl service enabled?
- configured to always restart on boot?
- does your computer or OS support what you want the RX888 or wsprdaemon to do?
- for Beelink, set the fan to 'auto' with the fan turning on at 40C and getting to max speed at 60C with at ramp of '8' 

## consider avahi address translation issues
- avahi installed (see pre-requisite libraries)

## consider ethernet hubs/architecture

- ttl = 0 by default (assuming a stand-alone setup) so as not to flood the LAN or WLAN with multicast packets
- if using multicast between computers, ttl = 1 required on sending computer and on the right NIC
- multicast will require an IGMP-capable switch with snooping ON to isolate the computers using radiod multicast from the rest of your LAN or WLAN. 
- have you defined and enabled a device in radiod@rx888-XXX.conf?
