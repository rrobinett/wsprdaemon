# wsprdaemon  (WD)
A Debian/Raspberry Pi WSPR decoding and noise level graphing service 

This is a large bash script which utilizes kiwrecorder.py and other library and utility commands to record WSPR spots 
from one or more Kiwis, audio adapters and (for VHF/UHF) RTL-SDRs and *reliably* post them to wsprnet.org

Schedules can be configured to switch between bands at different hours of the day, or at sunrise/sunset-relative times.

Signals obtained from multiple receievers on the same band ( e.g a 40M vertical and 500' Beverage ) can be merged together with only
the best SNR posted to wsprnet.org

In addition WD can be configured to, at the same time, create graphs of the background noise level for display on the computer running WD
and/or at http://graphs.wsprdaemon.org/

WD can run on almost any Debian Linux system and is tested on Stretch and Buster for Raspberry Pi 3 and 4, and Ubuntu 18.04LTS on x86
A Pi 3b can decode 14+ bands, but 14 bands of noise level graphing requires a Pi 4 or x86 server.


Installation

I recommend that you create a 'wsprdaemon' user to install and run WD on your system.  That user will need sudo access for installation,
and and auto sudo is needed if WDE is confiured to display graphic on the server's own web page.

Logged on as that user:

Dowload wsprdaemon.sh from this site

chmod +x wsprdaemon.sh
mkdir ~/wsprdaemon
mv wsprdaemon.sh ~/wsprdaemon/
cd ~/wsprdaemon/
./wsprdaemon.sh

This first run of WD will install many, many utilities and libraries, and for some you will be prompted to agree to the insallation
Some/all of them will requier sudo permission.  I configure 'wsprdaemon' as a member of the 'sudoers' group and thus are never prompted 
for a password, but you experience may vary.

At then end of a sucessful installation, WD creates a prototype configuration file '~/wsprdaemon/wsprdaemon.conf'.  You will
need to edit that file to reflect your desired configuration.

After installtion and configuration is completed, run:

~/wsprdaemon/wsprdaemon.sh -a          => Starts WD running as a background linux service which will 
                                           automatically start after any reboot or power cycle of your server
~/wsprdaemon/wsprdaemon.sh -z          => Stop any running WD, but it will start again after a reboot/power cycle
~/wsprdaemon/wsprdaemon.sh -s          => Display the status of the WD service

~/wsprdaemon/wsprdaemon.sh -h          => Help menu

Since I have no QA department,  installations, especially on non-Pi systems, may encounter problems which I have not seen.
However WD has been running for months at many top spotting sites and I hope you find it useful, not frustrating
