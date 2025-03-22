# Preparing for installation

You will clone from github.com and then run the wsprdaemon software in a "wsrdaemon" sub-directory of a regular linux user account, e.g., /home/username/wsprdaemon.  
Typically, you will create a separate "wsprdaemon" user, e.g., /home/wsprdaemon but you can run it under your own (or another's) account. 

N.B.  In either case, the account running wsprdaemon needs sudo privileges as several component installations and process management require it.

## Prerequisites

### Computer requirements

One has lots of options for a computer and network architecture that supports ka9q-radio and wsprdaemon.  However, in order to run it all on one computer, it needs sufficient CPU and memory power and superspeed USB 3 (the RX888 samples at 64.8 or 129.6 MHz!).  CPU and memory (RAM and cache) structures vary widely and some, even nominally "powerful" new computers may not, in their default configuration, manage the core and cache optimally.  Computers using the Ryzen 5800 chipsets and above work without adjustment. 

One can run ka9q-radio (radiod) on a "slower" computer, as long as it has USB 3.  It will multicast its output via RTP streams to another computer for processing.  This setup will usually require an IGMP-aware ethernet switch to shield your LAN (especially if it relies on WiFi).  The prodigious multicast output from radiod can bring a WiFi LAN to a clogged halt.  

### Operating system

The current version of wsprdaemon runs on [Ubuntu 24.04 LTS](https://ubuntu.com/download/server).  Ubuntu seems determined to push "snap" software which has sometimes broken wsprdaemon through automatic updates that changed critical dependencies.  Clint Turner has developed a [method to "de-snap"](http://www.sdrutah.org/info/websdr_Ubuntu_2204_install_notes.html#snapd) a system to avoid this problem.  Alternatively, you can install an Ubuntu-derivative -- [Mint](https://www.linuxmint.com/download.php) -- which does not use snaps or their progenitor [Debian](https://www.debian.org/distrib/).  

### sudo access 

Installation and proper function of wsprdaemon requires root access, best done using `sudo`.

To avoid entering the su password all the time:
```
sudo visudo
``` 
Edit the line starting with "%sudo" to allow members of group sudo to execute any command:
```
%sudo   ALL=(ALL:ALL) NOPASSWD: ALL
```

### Determine the wsprdaemon user

If you choose to run wsprdaemon as the user "wsprdaemon", create a wsprdaemon user:
```
sudo adduser wsprdaemon
```

Subsequent installation and management of wd will then happen as user "wsprdaemon".  You should then login to the machine as "wsprdaemon." 

If you login with another username, you can make it easier to change to the wsprdaemon user, by creating an alias: 
```
echo  "alias wd='sudo su - wsprdaemon'" >> ~/.bashrc
```
Executing `wd` then enables you to operate as the wsprdaemon user.

Add wsprdaemon (or your username) to groups sudo, plugdev:
```
sudo usermod -a -G sudo wsprdaemon
sudo usermod -a -G plugdev wsprdaemon
```

wsprdaemon includes and installs the ka9q-radio package which creates a "radio" group.  So, once the wsprdaemon script has finished compiling and installing the ka9q-radio package, check that user wsprdaemon (or your username) has been added to the radio group in /etc/group.  If not, then:

```
sudo usermod -a -G radio wsprdaemon
```

If dedicating this computer to exclusive wsprdaemon use, you may also want the hostname of your computer to reflect this.  To do so:
```
sudo hostnamectl set-hostname W3USR-B1-1
```

After changing the hostname, check or update the /etc/hosts file to reflect the change. 

### Remote Access Setup

If installing wsprdaemon on a computer you intend to manage remotely, you can make it much easier to login to the other computer via ssh.

First, make sure you have a public key :
```
ssh-keygen
```
then use the ssh-copy-id utility to copy this to the remote computer.
```
ssh-copy-id  wsprdaemon@\<new computer name\>
```

If you want to suppress the several notices that greet you on every login, 
```
touch .hushlogin
```

A useful shell command to find your external ip address:
```
dig +short myip.opendns.com @resolver1.opendns.com
```

### System Pre-requisites and Useful Utilities:

This includes what will prove needed or useful for wsprdaemon and ka9q-radio.  As of wsprdaemon v3.3.1, many but not all of these will get installed automatically. You can safely run the following either way.

```
sudo apt install btop nmap git tmux vim net-tools iputils-ping avahi-daemon libnss-mdns mdns-scan avahi-utils avahi-discover build-essential make cmake gcc libairspy-dev libairspyhf-dev libavahi-client-dev libbsd-dev libfftw3-dev libhackrf-dev libiniparser-dev libncurses5-dev libopus-dev librtlsdr-dev libusb-1.0-0-dev libusb-dev portaudio19-dev libasound2-dev uuid-dev rsync sox libsox-fmt-all opus-tools flac tcpdump wireshark libhdf5-dev libsamplerate-dev
```

For ethernet transport, radiod will use your default network interface (NIC).  You can enable a specific NIC device in /etc/radio/radiod@.conf and in /etc/avahi/avahi-daemon.conf.  This primarily pertains to systems that have more than one NIC and setups that will use multicast between computers, not just on a stand-alone system.  

The program "tmux" usefully enables multiple text windows, preserves a session between different logins, and enables two or more users to concurrently join a session.

To enable tmux mouse control, edit .tmux.conf (logged in as wsprdaemon) with
```
set -g mouse on
```

When accessing the system with a Mac using iTerm, you can enable mouse "cut and paste".  Goto iTerm2 > Preferences > “General” tab, and in the “Selection” section, check “Applications in terminal may access clipboard”.

--- 

You can now proceed to [clone wsprdaemon from GitHub](./git.md).