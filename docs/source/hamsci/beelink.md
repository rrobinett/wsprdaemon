# HamSCI -- Beelink 

(Thanks to Frank O'Donnell)

## Beelink BIOS preparation

A keyboard and monitor are required for this step.

Start Beelink while repeatedly pressing Delete key to enter BIOS.

In Advanced > Smart Fan Function, edit settings as follows:

Smart CPU_Fan Mode

Fan start temperature limit			45	->	40
Fan Full Speed temperature limit		92	->	60
PWM SLOPE SETTING			2 PWM  ->	8 PWM

Smart Sys_Fan Mode

Fan start temperature limit			45	->	40
Fan Full Speed temperature limit		70	->	60
PWM SLOPE SETTING			2 PWM  ->	8 PWM

Press F4 to save and exit.

## OS installation

### Windows product key retrieval (optional)

If you wish to retrieve the product key for the copy of Windows 11 that ships with the Beelink for possible future use:

A keyboard and monitor are required for this step, a mouse is also convenient.

Allow Beelink to boot into Windows setup. If you don't wish to associate it with a Microsoft account, you can set up as a local account and leave password blank.

When setup is complete and the Windows desktop appears, press Windows Key + X and select Windows Terminal (Admin) or Command Prompt (Admin)

Enter the following command:

wmic path softwarelicensingservice get OA3xOriginalProductKey

This will display the product key, which you can copy-paste to a text file on a USB flash drive, or take a picture of it.


### Debian install

Download software: Visit debian.org to download an .iso file. Pick a mirror site close to your location. Select the top numbered version displayed (for example, 12.11 as of August 2025). For the Beelinks you will want the AMD64 version.

Once you download the .iso file, you need to burn it to a USB flash drive using software such as balenaEtcher for Windows, Mac, or Linux. Rufus is also popular for Windows.

Run installation: With the Beelink powered down, insert the flash drive into a USB port, then power on the Beelink pressing F7 repeatedly in order to enter the boot menu.

Select the entry for the flash drive. If there is also another entry for a second partition on the flash drive, ignore it. Go with the main entry listed for the flash drive.

The Debian install will then begin.

When prompted, select "Install," not "Graphical install."

Choose language, location, and keyboard as desired.

For network, I had an Ethernet cable attached to the Beelink, and chose the wired network option (which will appear as something like "enp1s0 RTL8125 2.5GbE (wired)"). Wifi may also be possible, but since the Wsprdaemon servers generally use hard-wired Ethernet, I left wifi uninstalled.

Choose and enter a hostname. For Wsprdaemon purposes, this will often be the callsign you want to have spots reported under, followed by "-WD" to identify it as a Wsprdaemon server.

You will be asked for domain type. Unless you know another response is more appropriate, accept the default of ".lan".

Under user accounts, you will be asked to create a root password, then create a normal user account. I only created one account on my system, with username wsprdaemon, since the system will not be used for anything other than Wsprdaemon.

Under partitioning, choose “Guided – use entire disk" and “All files in one partition". When this is selected, it will actually create three partitions, which are normal:

- Partition 1: ESP
- Partition 2: ext4
- Partition 3: swap

Confirm and write changes to disk.

Software selection: At this screen, *unselect* everything, except for:

[x] SSH server
[x] standard system utilities


### First Debian boot

Using the attached keyboard and monitor, log in at console as your user.

Enter this command to switch to root:

su -

Install core utilities:

apt update
apt install sudo less vim nano man-db net-tools iputils-ping wget curl unzip

Then add your user to the sudo and plugdev groups (the command lines below assume the username is wsprdaemon):

sudo usermod -a -G sudo wsprdaemon
sudo usermod -a -G plugdev wsprdaemon

Log out (type "exit"), then log in again as your user in order to activate sudo group. Test sudo by using for a simple command such as:

sudo ls -l

You should get a prompt to enter password; after you do so, the command should succeed.

I also chose to install some other utilities, but these may be optional or unnecessary:

sudo apt install btop nmap git tmux vim net-tools iputils-ping avahi-daemon libnss-mdns mdns-scan avahi-utils avahi-discover build-essential make cmake gcc libavahi-client-dev libbsd-dev libfftw3-dev libiniparser-dev libncurses5-dev libopus-dev libusb-1.0-0-dev libusb-dev portaudio19-dev libasound2-dev uuid-dev rsync sox libsox-fmt-all opus-tools flac tcpdump wireshark libhdf5-dev libsamplerate-dev

During wireshark install, you will probably be asked if it’s ok for non-superusers to capture packets. Select Yes. 

Check the Beelink's IP address by entering this command:

ip a

It will return detailed network information. Look through it to find a value like '192.168.1.xxx'.

At this point, you can remove the keyboard and monitor from the Beelink, and use 'ssh' to log in from another system on your local network using the IP address obtained above:

ssh wsprdaemon@192.168.1.xxx

The first time you connect to the new server, your local system may say it's not in your list of accessed systems, do you want to proceed? Answer yes.

To transfer files to or from the server, secure copy ('scp') is convenient:

scp sourcefile user@hostname:/path/to/destination/
scp user@hostname:/path/to/file /local/destination/

