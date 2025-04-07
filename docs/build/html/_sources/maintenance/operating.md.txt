# Operating WD

## Start and Stop

After installation, there are two different ways to run WD. Each of these is invoked from the command line.

The first method is the usual one where WD is run as a 'systemctl' service. In this mode it automatically starts when Linux boots or reboots after a power cycle. The command line (aliased) commands associated with this mode are 'wd -a' and 'wd -z'. 'wd -a' starts this mode while 'wd -z' terminates it. However, this method does not post system errors back to the command line. For this reason, when first verifying at startup or for verifying operation after wsprdaemon.conf has been modified, it can be useful to temporarily use the second mode.

This second mode is invoked with 'wd -A' and terminated with 'wd -Z'. Note the capitalization differences. 'wd -A' invokes WD from the command line rather than automatically from the systemctl environment. This means that it does post errors back to the command line where they can be viewed. This mode is exited by typing 'wd -Z'.

Once an installation and wsprdaemon.conf changes are verified, 'wd -Z' followed by 'wd -a' will make operation automatic. Any future changes should be made by first stopping this automatic operation and then temporarily using 'wd -A' to re-verify them followed by 'wd -Z' and 'wd -a' once they are acceptable.


