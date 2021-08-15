# wsprdaemon (WD) Latest version is v2.10k
2.10k Add WD's version number to spots uploaded to wsprnet.org

2.10j Upload WSJT-x 2.3.0 binaries

2.10i Fix installation of python-numpy on Ubuntu 20.04.1 LTE 

2.10h Fix a bug which on fast CPUs caused loss of connection to Kiwis.  There is no need to upgrade to 2.10h unless your installation is failing to connect to your Kiwis.

2.10g Fix uninitialized variable bug which was causing recording jobs to abort

2.10f Add FSTW4-120 decoding on all bands if JT9_DECODE_ENABLED="yes" is in wd.conf file.  Disabled by default, but even when enabled DOES NOT UPOLOAD FSTW4 SPOTS!!!!

2.10e  At the sugguestionof Joe Taylor, I have added the GNU GPL license.

2.10d Check and loads if missing the libgfortran5 library used by the new version of wsprd

2.10b Attempts to get installation working on Ubuntu 20.04 servers.
Also, installs the new 'wsprd' decoder from WSJT-x V2.3.0. I have been told this new wsprd supports a newly introduced modulation mode being heavily used on 2200 and 630

2.10a Support for installation on Ubuntu 20.04.  This required changes to the installation of the 'wsprd' decoding binary we take from WSJT-x.  Instead of installing the whole WSHT-x, we extract only the '/usr/bin/wsprd' program from the WSJT-x package file.  This greatly reduces the number of libraries and packages installed during installation.  However, I cannot easily test this new installation proceedure on other Linux distros, so I have incremented the minor version number to alert users to this change in installation operations.  So please contact me if you have problems running this new code.

2.9j WD Server fixes:  to get correct format of rx/tx GRIDs and add rx name to spot records

2.9i Add supplort for offset frequency assicated with VHF/UHF downconvertors

2.9h Fixes a number of installation and error handling problems.  Unless you are having problems with your installation, I don't think exisiting installatons need to upgrade to this build

2.9g Installs WSJT-x 2.2.2 which includes an enhanced wsprd decoding utility capable of extracting up to 6% more spots from your receiver

2.9f Fixes parsing of the config file so that WD supports multiple call/grid definitions

2.9e Adds a small fix to code which runs only on the upload server at wsprdaemon.org.

2.9d Adds enhanced spots logging to wsprnet.org and a number of error resiliency enhancements.

It is a very low risk upgrade, so I encourage all users to 'git pull' it

A Debian/Raspberry Pi [WSPR](https://en.wikipedia.org/wiki/WSPR_(amateur_radio_software)) decoding and noise level graphing service

This is a large bash script which utilizes [kiwirecorder.py](https://github.com/jks-prv/kiwiclient) and other library and utility commands to record WSPR spots from one or more [Kiwis](http://kiwisdr.com), audio adapters and (for VHF/UHF) [RTL-SDRs](https://www.rtl-sdr.com/about-rtl-sdr/) and *reliably* post them to [wsprnet.org](http://wsprnet.org).

Schedules can be configured to switch between bands at different hours of the day, or at sunrise/sunset-relative times.

Signals obtained from multiple receievers on the same band ( e.g a 40M vertical and 500' Beverage ) can be merged together with only the best SNR posted to [wsprnet.org](http://wsprnet.org).

In addition WD can be configured to, at the same time, create graphs of the background noise level for display on the computer running WD and/or at [graphs.wsprnet.org](http://graphs.wsprnet.org).

WD can run on almost any Debian Linux system and is tested on Stretch and Buster for Raspberry Pi 3 and 4, and Ubuntu 18.04LTS on x86. A Pi 3b can decode 14+ bands; a Pi 4 can decoder 30+ bands.

## Greenfield Installation

On a Raspberry Pi, install as user 'pi'.

On other Debian/Ubuntu servers, create a `wsprdaemon` user to install and run WD on your system.  That user will need `sudo` access for installation, and and auto sudo permissions is needed if WD is configured to display graphics on the server's own web page. 

To configure user 'wsprdaemon' to sudo:
```bash
su -
adduser wsprdaemon sudo
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

This first run of WD will install many, many utilities and libraries, and for some you will be prompted to agree to the insallation. Some/all of them will require `sudo` permission.  I configure `wsprdaemon` as a member of the `sudoers` group and thus are never prompted for a password, but your experience may vary.

At then end of a sucessful installation, WD creates a prototype configuration file at `~/wsprdaemon/wsprdaemon.conf`.  You will need to edit that file to reflect your desired configuration running ./wsprdaemon.sh -V until WD just prints out its's version number.  Once confgured, run './wsprdaemon.sh -a' to start the daemon.  It will automatically start after a reboot or power cycle.

## To upgrade from 2.6*:

1) cd ~/wsprdaemon
2) stop WD with '~/wsprdaemon/wsprdaemon.sh -z'
3) execute 'git pull'
4) free disk space with 'rm -rf /tmp/wsprdaemon/*'
5) clean out legacy noise data with 'rm -rf /home/pi/wsprdaemon/signal_levels/*'
6) start WD with '~/wsprdaemon/wsprdaemon.sh -a'

## Installation on a system running wsprdaemon that was not installed using 'git clone'

Stop WD with:  
```bash
'./wsprdaemon.sh -z'
````
Save away (i.e.rename) your exisiting ~/wsprdaemon directory, including its wsprdaemon.conf file:
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

After installtion and configuration is completed, run:

| Command | Description |
| ------- | ----------- |
| `~/wsprdaemon/wsprdaemon.sh -a` | Starts WD running as a background linux service which will automatically start after any reboot or power cycle of your server |
| `~/wsprdaemon/wsprdaemon.sh -z` | Stop any running WD, but it will start again after a reboot/power cycle |
| `~/wsprdaemon/wsprdaemon.sh -s` | Display the status of the WD service |
| `~/wsprdaemon/wsprdaemon.sh -h` | Help menu |

Since I have no QA department,  installations, especially on non-Pi systems, may encounter problems which I have not seen. However WD has been running for months at many top spotting sites and I hope you find it useful, not frustrating.
