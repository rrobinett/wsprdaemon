# Preparing the installation

## Prerequisites

If installing on someone's behalf, you need an account on their machine with sudo privileges.  

To avoid entering the su password all the time:
```
sudo visudo
``` 
Edit the %sudo line to allow members of group sudo to execute any command:
```
%sudo   ALL=(ALL:ALL) NOPASSWD: ALL
```

### create a wsprdaemon user

Once on the new machine, create a wsprdaemon user:
```
sudo adduser wsprdaemon
```
Installing and managing wd must happen as wsprdaemon.

To make it easier to change to the wsprdaemon user, create an alias: 
```
echo  "alias wd='sudo su - wsprdaemon'" >> ~/.bashrc
```

Add wsprdaemon to groups sudo, plugdev:
```
sudo usermod -a -G sudo wsprdaemon
sudo usermod -a -G plugdev wsprdaemon
```
ka9q-radio creates a radio group.  Once wsprdaemon has finished compiling and installing, ka9q-radio, check that user wsprdaemon has been added to the radio group in /etc/group.  If not, then:
```
sudo usermod -a -G radio wsprdaemon
```
### remote access setup

From your present computer, make it easier to login to the new (if remote) machine:
make sure you have a public key :
```
ssh-keygen
```
then
```
ssh-copy-id  wsprdaemon@\<new machine name\>
```

To suppress login notices, 
```
touch .hushlogin
```

shell command to find your external ip address:
```
dig +short myip.opendns.com @resolver1.opendns.com
```

### system pre-requisites and useful utilities:

This includes what will prove needed or useful for wsprdaemon and ka9q-radio.

```
sudo apt install btop nmap git tmux vim net-tools iputils-ping avahi-daemon libnss-mdns mdns-scan avahi-utils avahi-discover build-essential make cmake gcc libairspy-dev libairspyhf-dev libavahi-client-dev libbsd-dev libfftw3-dev libhackrf-dev libiniparser-dev libncurses5-dev libopus-dev librtlsdr-dev libusb-1.0-0-dev libusb-dev portaudio19-dev libasound2-dev uuid-dev rsync sox libsox-fmt-all opus-tools flac tcpdump wireshark libhdf5-dev libsamplerate-dev
```

For ethernet transport, make sure to enable the appropriate NIC device in /etc/avahi/avahi-daemon.conf.  This primarily pertains to systems that have more than one NIC and setups that will use multicast between systems, not just on one system.  

To enable tmux mouse control, edit .tmux.conf (logged in as wsprdaemon) with
```
set -g mouse on
```

If using iTerm on macOS, goto iTerm2 > Preferences > “General” tab, and in the “Selection” section, check “Applications in terminal may access clipboard”.


