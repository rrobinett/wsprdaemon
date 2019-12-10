# wsprdaemon (WD)

A Debian/Raspberry Pi [WSPR](https://en.wikipedia.org/wiki/WSPR_(amateur_radio_software)) decoding and noise level graphing service

This is a large bash script which utilizes [kiwirecorder.py](https://github.com/jks-prv/kiwiclient) and other library and utility commands to record WSPR spots from one or more [Kiwis](http://kiwisdr.com), audio adapters and (for VHF/UHF) [RTL-SDRs](https://www.rtl-sdr.com/about-rtl-sdr/) and *reliably* post them to [wsprnet.org](http://wsprnet.org).

Schedules can be configured to switch between bands at different hours of the day, or at sunrise/sunset-relative times.

Signals obtained from multiple receievers on the same band ( e.g a 40M vertical and 500' Beverage ) can be merged together with only the best SNR posted to [wsprnet.org](http://wsprnet.org).

In addition WD can be configured to, at the same time, create graphs of the background noise level for display on the computer running WD and/or at [graphs.wsprnet.org](http://graphs.wsprnet.org).

WD can run on almost any Debian Linux system and is tested on Stretch and Buster for Raspberry Pi 3 and 4, and Ubuntu 18.04LTS on x86. A Pi 3b can decode 14+ bands, but 14 bands of noise level graphing requires a Pi 4 or x86 server.

## Greenfield Installation

I recommend that you create a `wsprdaemon` user to install and run WD on your system.  That user will need `sudo` access for installation, and and auto sudo permissions is needed if WD is configured to display graphics on the server's own web page.

While logged on as that user:

Download `wsprdaemon.sh` from this site

```bash
cd ~
git clone https://github.com/rrobinett/wsprdaemon.git
cd wsprdaemon
./wsprdaemon.sh -V
```

This first run of WD will install many, many utilities and libraries, and for some you will be prompted to agree to the insallation. Some/all of them will require `sudo` permission.  I configure `wsprdaemon` as a member of the `sudoers` group and thus are never prompted for a password, but your experience may vary.

At then end of a sucessful installation, WD creates a prototype configuration file at `~/wsprdaemon/wsprdaemon.conf`.  You will need to edit that file to reflect your desired configuration running ./wsprdaemon.sh -V until WD just prints out its's version number.  Once confgured, run './wsprdaemon.sh -a' to start the daemon.  It will automatically start after a reboot or power cycle.

## Installation on a system with an existing copy of wsprdaemon not installed using 'git clone'

Stop WD with:  
```bash
'./wsprdaemon.sh -z'
````
Save away (i.e.rename) your exisiting wsprdaemon.conf file, e.g 
```bash
mv ~/wsprdaemon/ ~/wsprdaemon.save"
````
Follow the instructions for "Greenfield Installation", but don't start WD with 
```bash
'./wsprdaemon.sh -a'
````
Copy your saved wsprdaemon.conf file into the directory created by the clone, e.g:
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
