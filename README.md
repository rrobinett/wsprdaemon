# wsprdaemon (WD) 3.0.9

New WD users should skip down to the "Greenfield" section below for installation instructions.

For exisiting WD users, WD 3.0.8 is now running on almost all top spotting sites.  Since WD 2.x generates spots with corrupt fields and earlier versions of WD 3.0 are not entirely compatible with recent mode fields changes in WSJT-x 2.6.x, I encourage all WD users to upgrade WD using the procedure described below.  It is a major upgrade from 2.10, but is backwards compatible with 2.10 wsprdaemon.conf files.  For more information and help goto:  https://groups.io/g/wsprdaemon

For existing WD 2.10 users:

cd ~/wsprdaemon

./wsprdaemon.sh -z        

git checkout master

git pull

./wsprdaemon.sh -a

Wsprdaemon is a large bash script which utilizes [kiwirecorder.py](https://github.com/jks-prv/kiwiclient) and other library and utility commands to record WSPR spots from one or more [Kiwis](http://kiwisdr.com), audio adapters and (for VHF/UHF) [RTL-SDRs](https://www.rtl-sdr.com/about-rtl-sdr/) and *reliably* post them to [wsprnet.org](http://wsprnet.org).

Schedules can be configured to switch between bands at different hours of the day, or at sunrise/sunset-relative times.

Signals obtained from multiple receivers on the same band ( e.g a 40M vertical and 500' Beverage ) can be merged together with only the best SNR posted to [wsprnet.org](http://wsprnet.org).

In addition WD can be configured to, at the same time, create graphs of the background noise level for display on the computer running WD and/or at [graphs.wsprnet.org](http://graphs.wsprnet.org).

WD can run on almost any Debian Linux system and is tested on the Buster OS for Raspberry Pi 3 and 4, and Ubuntu 22.04 LTS on x86. A Pi 3b can decode 14+ bands; a Pi 4 can decode 30+ bands.

## Greenfield Installation

On a Raspberry Pi running Buster, install as the default user 'pi'.

On other Debian/Ubuntu servers, create a `wsprdaemon` user to install and run WD on your system.  That user will need `sudo` access for installation, and auto sudo permissions is needed if WD is configured to display graphics on the server's own web page. 

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

## Installation on a system running wsprdaemon that was not installed using 'git clone'

Stop WD with:  
```bash
'./wsprdaemon.sh -z'
````
Save away (i.e.rename) your existing ~/wsprdaemon directory, including its wsprdaemon.conf file:
```bash
mv ~/wsprdaemon/ ~/wsprdaemon.save"
````
Follow the instructions for "Greenfield Installation", but don't end by starting WD with 
```bash
'./wsprdaemon.sh -a'
````
Copy your saved wsprdaemon.conf file into the directory created by the clone:
```bash
cp ~/wsprdaemon.save/wsprdaemon.conf ~/wsprdaemon/"
````
Then start WD with 
```bash
./wsprdaemon.sh -a
````
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
