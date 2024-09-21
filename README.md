# WsprDaemon (WD) 3.2.3 is the current master version

Wsprdaemon (WD) is Linux service which decodes WSPR and FST4W spots from one or more [Kiwis](http://kiwisdr.com) and/or RX888 SDRs and *reliably* posts them to [wsprnet.org](http://wsprnet.org).  It includes many features not found in WSJT-x, including multiple band and/or multiple receiver support.  WD also records additional information about spots like doppler shift and background noise level which permit much deeper understanding of propagation conditions.  For systems like the KiwiSDR which have a limited number of receive channels, schedules can be configured to switch between bands at different hours of the day or at sunrise/sunset-relative times. Spots obtained from multiple receivers on the same band ( e.g a 40M vertical and 500' Beverage ) can be merged together with only the best SNR posted to [wsprnet.org](http://wsprnet.org).  WD can be configured to create graphs of the background noise level for display locally and/or at [graphs.wsprdaemon.org](http://graphs.wsprnet.org).

After configuration, WD is designed to run like a home appliance: it recovers on its own from power and Internet outages and caches all spots and other data it gathers until it is confirmed delivered by wsprnet.org and/or wsprdaemon.net.  Most of the 20+ 'top spotting' sites at http://wspr.rocks/topspotters/ are running WD, and in aggregate they report about 33% of the 7+M spots recorded each day at wsprnet.org. 

WD runs on almost any Debian Linux system running Ubuntu 22.04 LTS on x86  Although WD on a Pi 4 can decode 10+ bands, most sites run WD on a x86 CPU.

## Greenfield Installation

On other Debian/Ubuntu servers, create a `wsprdaemon` user to install and run WD on your system.  That user will need `sudo` access for installation, and auto sudo permissions is needed if WD is configured to display graphics on the server's own web page.   On a Raspberry Pi running the Buster OS, install as the default user 'pi'.

To configure user 'wsprdaemon' to sudo:
```bash
su -
sudo adduser wsprdaemon
sudo usermod -aG sudo wsprdaemon
exit
```

While logged on as user 'pi' or 'wsprdaemon':

Download `wsprdaemon.sh` from this site by executing:

```bash
cd ~
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon
./wsprdaemon.sh -V
```

This first run of WD will prompt the user to edit the prototype configuration file '~/wsprdaemon/wsprdaemon.conf' which includes extensive comments about the many configuration options. A basic installation will require that the IP address of at least one Kiwi receiver be defined in the RECEIVER_LIST section, and one listening schedule line be defined in the WSPR_SCHEDULE_simple section.

Once those edits are made, run '~/wsprdaemon/wsprdaemon.sh -a'  which will install many, many utilities and libraries, for some of which you will be prompted to agree to the installation. Some/all of them will require `sudo` permission.  I configure `wsprdaemon` as a member of the `sudoers` group and thus am never prompted for a password, but your experience may vary.

There are a number of commands to more easily control and monitor WD that can be permanently installed by executing:

``` bash
pi@KPH-Pi4b-85:~ $ source ~/wsprdaemon/.wd_bash_aliases
pi@KPH-Pi4b-85:~ $ wd-rci
A reference to '~/wsprdaemon/.wd_bash_aliases' has been added to ' ~/.bash_aliases'
pi@KPH-Pi4b-85:~ $
```
Once installed you can:

wda => start WD

wdz => stop  WD

wds => print the status of WD

wdln => watch the log of WD uploading spots to wsprnet.org

wd-help => list all the added commands

Beware : newer versions, since 3.1.5 will need to use 

```
source ~/wsprdaemon/bash-aliases
```

## Upgrading WD in a cloned directory to the latest master version 

Execute 'git pull'

## Usage

After installation and configuration is completed, run:

| Command | Description |
| ------- | ----------- |
| `~/wsprdaemon/wsprdaemon.sh -A` | Starts WD running as a background linux service which will automatically start after any reboot or power cycle of your server |
| `~/wsprdaemon/wsprdaemon.sh -z` | Stop any running WD, but it will start again after a reboot/power cycle |
| `~/wsprdaemon/wsprdaemon.sh -s` | Display the status of the WD service |
| `~/wsprdaemon/wsprdaemon.sh -h` | Help menu |

Since I have no QA department,  installations, especially on non-Pi systems, may encounter problems which I have not seen. However WD has been running for months at many top spotting sites and I hope you find it useful, not frustrating.
