
##########################################################################################################################################################
########## Section which implements the help menu ########################################################################################################
##########################################################################################################################################################
function usage() {
    echo "
###    Copyright (C) 2020-2022  Robert S. Robinett
###
###    This program is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    This program is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###    GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with this program.  If not, see <https://www.gnu.org/licenses/>.

###   wsprdaemon depends heavily upon the 'wsprd' program and other technologies developed by Joe Taylor K1JT and others, to whom we are grateful.
###   Goto https://physics.princeton.edu/pulsar/K1JT/wsjtx.html to learn more about WSJT-x

This is VERSION = ${VERSION}

     This program reads the configuration file wsprdaemon.conf which defines a schedule to capture and post WSPR signals from one or more KiwiSDRs 
     and/or AUDIO inputs and/or RTL-SDRs.
     Each KiwiSDR can be configured to run 8 separate bands, so 2 Kiwis can spot every 2 minute cycle from all 14 LF/MF/HF bands.
     In addition, the operator can configure 'MERG_..' receivers which posts decodes from 2 or more 'real' receivers 
     but selects only the best SNR for each received callsign (i.e no double-posting).

     Each 2 minute WSPR cycle this script creates a separate .wav recording file on this host from the audio output of each configured [receiver,band].
     At the end of each cycle, each of those files is processed by the 'wsprd' WSPR decode application included in the WSJT-x application
     which must be installed on this server. The decodes output by 'wsprd' are then spotted to the WSPRnet.org database. 
     The script allows individual [receiver,band] control as well as automatic scheduled band control via a watchdog process 
     which is automatically started during the server's bootup process.

usage:
    ${WSPRDAEMON_ROOT_PATH} -[asz] Start,Show Status, or Stop the watchdog daemon
    -a                            => stArt watchdog daemon which will start all scheduled jobs ( -w a )
    -A                            => install wsprdaemon as a service started at linux boot/reboot/powerup time and then stArt it
    -z                            => stop watchdog daemon and all jobs it is currently running (-w z )   (i.e.zzzz => go to sleep)
    -Z                            => stop any running WD and also remove it from being run by Linux at boot/reboot/powerup time
    -s                            => show Status of watchdog and jobs it is currently running  (-w s ; -j s )
    -l     [e,n,d]                => show log files lines using 'tail -F'.  'e' = new ERROR lines from all logs files.  'n' = wsprnet.org uploading. 'd' = wsprdaemon.org uploading 
    -h                            => print this help message (execute '-vh' to get a description of the architecture of this program)

    These flags are mostly intended for advanced configuration:

    -i                            => list audio and RTL-SDR devices attached to this computer
    -v                            => Increase verbosity of diagnotic printouts 
    -d                            => Signal all running processes as found in the *.pid files in the current directory to increment the logging verbosity
                                     This permits changes to logging verbosity without restarting WD
    -D                            => Signal all to decrement verbosity

    Examples:
     ${0##*/} -a                      => stArt the watchdog daemon which will in turn run '-j a,all' starting WSPR jobs defined in '${WSPRDAEMON_CONFIG_FILE}'
     ${0##*/} -z                      => Stop the watchdog daemon but WSPR jobs will continue to run 
     ${0##*/} -s                      => Show the status of the watchdog and all of the currently running jobs it has created

    Valid RECEIVER_NAMEs which have been defined in '${WSPRDAEMON_CONFIG_FILE}':
    $(list_known_receivers)

    WSPR_BAND  => {2200|630|160|80|80eu|60|60eu|40|30|22|20|17|15|12|10|6|2|1|0} 

    See the file wd_template.conf for more details about configuration options

    Author Rob Robinett AI6VN rob@robinett.us   with help from John Seamons, the author of the KiwiSDR, Gwyn Griffths G3ZIL, and a large group of beta testers.
    I would appreciate reports which compare the number of reports and the SNR values reported by wsprdaemon.sh 
        against values reported by the same Kiwi's autowspr and/or that same Kiwi fed to WSJT-x 
    In my testing wsprdaemon.sh always reports the same or more signals and the same SNR for those detected by autowspr,
        but I cannot yet guarantee that wsprdaemon.sh is always better than those other reporting methods.
    "
    [[ ${verbosity} -ge 2 ]] && echo "
    An overview of the SW architecture of wsprdaemon.sh:

    This program creates a error-resilient stand-alone WSPR receiving appliance which should run 24/7/365 without user attention and will recover from 
    loss of power and/or Internet connectivity. 
    It has been  primarily developed and deployed on Raspberry Pi 3Bs which can support 20 or more WSPR decoding bands when KiwiSDRs are used as the demodulated signal sources. 
    However it is running on other Debian 16.4 servers like the Odroid and x86 servers (I think) without and modifications.  Even Windows runs bash today, so perhaps
    it could be ported to run there too.  It has run on Max OSX, but I haven't checked its operation there in many months.
    It is almost entirely a bash script which excutes the 'wsprd' binary supplied in the WSJT-x distribution.  To use a KiwiSDR as the signal source it
    uses a Python script supplied by the KiwiSDR author 
    "
    return 0
}

