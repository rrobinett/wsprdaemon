# Operating Sytems

I currently do most of my installation and run-time testing on the recently released Ubuntu 24.04 LTS server OS. Desktop Ubuntu includes a lot of software auto-upgrade features which can disrupt the operation of WD and other applications, so I suggest you avoid using the desktop version. If you do use it, then at least follow [Clint KA7OEI's "de-snap" instructions](http://www.sdrutah.org/info/websdr_Ubuntu_2204_install_notes.html#snapd)

[Download Ubuntu server](https://ubuntu.com/download/server) and run the 'Raspberry Pi Imager' program on your PC to copy the Ubuntu.iso file to a 8 GB or larger USB thumb drive.

In Imager select:

Rasperry Pi Device => "NO FILTERING" Operating System => Use custom => browse to the Ubuntu image file you have downloaded to your PC Storage => the thumb drive

You will then insert the USB thumb drive into your host and boot from that drive. Frequently you will need to press the DEL key or a function key (e.g. F7) immediately after power-up in order to instruct the BIOS of the server to boot from the thumb drive.

I suggest that you create a user 'wsprdaemon' with sudo privileges after installation is complete.

While WD can run on many different x86 and ARM CPU's, the RX888 is best run on a i5-6500T-class or newer x86 server.

For new installations I have found the Beelink brand SER 5 Ryzen 5800U offers excellent price, performance and low power consumption for a WD system. Today Sept 9, 2024 Amazon offers it for $270 (after $18 discount) at [Amazon](https://www.amazon.com/Beelink-SER5-Computer-Graphics-Support/dp/B0D6G965BC), but the same Beelink may be offered at several different prices on Amazon, so search for price including 'discount coupons'. The Beelink Ser 5 5560U is another excellent choice which until today I was able to purchase for $219.  Also consider the Ryzen 5800 series chips, (5800U, 5800H, 5825H) but avoid the 5700 series as these have a divided L3 cache which may introduce gaps in the USB stream as processing switches from one set of cores to another.

Whatever server you choose, WD runs a little better on 16 GB of ram.

The Beelink comes with Windows installed but WD runs on Linux, so I usually first install Windows and associate the Beelink with my Microsoft account to be sure the server hardware and software are functional, and in case I want to restore Windows on that server.

Maximizing CPU performance on the Beelink requires that the 'always slow' default fan setting be changed in the BIOS to 'fan on a 40C, fan max at 60C, speed ramp 8'. The 'btop' program which I run to monitor the CPU usage displays CPU temperature among many other things. If it shows the CPU at much more than 60C during the 100% busy periods which start every even 2 minutes, then your fan is not running fast enough.

I also find the 'power always on' setting deeply buried in the ACH sub menu.
