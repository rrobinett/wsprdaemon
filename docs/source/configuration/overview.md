# Overview of Configuration 

Having prepared and cloned the wsprdaemon software, now you can run it:

```
wd
```
This sets the stage and tells you to edit wsprdaemon.conf.

## wsprdaemon.conf

The template for a wsprdaemon.conf file, located in /home/wsprdaemon/wsprdaemon/, includes tons of stuff and looks dauntingly complicated. 
However, it boils down to setting up the following:
- [computer-related parameters](./wd_conf/computer.md)
- [receiver definitions](./wd_conf/receivers.md)
- [ka9q-radio parameters](./wd_conf/ka9q-radio.md)
- [reporting parameters](./wd_conf/reporting.md)
- [a schedule](./wd_conf/schedule.md)

### [example wsprdaemon.conf](./wd_conf/wsprdaemon.conf.md)

## radiod@.conf

Likewise, the radiod@<something>.conf, located in /etc/radio/, has lots of options.
However, it boils down to setting up the following:
- [global settings](./radiod_conf/global.md)
- [hardware settings](./radiod_conf/hardware.md)
- [channel settings](./radiod_conf/channels.md)

### [example radiod@rx888-wsprdaemon.conf](./radiod_conf/radiod@rx888-wsprdaemon.conf.md)


