# Personal Space Weather Station Data Repository Access

Revised instructions to activate the uploading of GRAPE data to the PSWS site. All prior instructions should be ignored since the PSWS site has moved to a new server, ssh access has been turned off and the site requires the use of SFTP, a public key and the newest WSPRDaemon code to support the upload. These instructions are specific to WSPRDaemon users that have RX888 receivers to record WWV for the GRAPE project.

## PSWS Account

To begin, you must have a Personal Space Weather Station account. Visit this link to see how to get started. Follow the link to register your station. 

https://pswsnetwork.eng.ua.edu/about/
 
There's an excellent document written by Bill Engelke, AB4EJ located at this link that is a good primer to read for the uninitiated. It shows how to set up the account.  It does not include WSPRDaemon configuration instructions, FYI. 
 
https://hamsci.org/sites/default/files/Grape/Getting%20Started%20with%20Data%20Reporting%20Using%20A%20Personal%20Space%20Weather%20Station_V7.2.pdf

Once your PSWS account is set up and you add a device, you must make note of your Station ID and your device ID. The station ID can be found at the PSWS home page and clicking the "Stations" along the top bar and then clicking "View My Stations". The station ID is under the column labeled ID. The ID is a link and when you click it, you'll see more detail. 
 
Your station ID will be at the very top under Details of this station:
 
ID: S000XXX where the XXX's will be your number. 
 
The Device ID is located at the bottom of the page inside the outlined box. It is also labeled ID and will be a three digit number. You need both to enter into your wsprdaemon.conf file.

## Integrating with wsprdaemon

If you haven't updated your WSPDaemon code in a while, that should be your next step. At your linux command prompt, type cdw and press enter, which brings you to the wsprdaemon directory. Type wdz to stop wsprdaemon and other active programs like KA9Q radio. Type "git pull" and download new files to the system. Type wda to restart wsprdaemon. Type wds to check system status. 
 
Now, on the latest version, edit your wsprdaemon.conf file to include your two PSWS ID's. See example below:
 
PSWS_STATION_ID="S000XXX"

PSWS_DEVICE_ID="1XX"

Be sure to remove any leading #'s. If you have an older version of WSPRDaemon, your .conf file may have this entry, "GRAPE_PSWS_ID", which has been deprecated and is no longer used. Remove it from your config file. 
 
## Setting up automatic login to upload data
Uploading to the PSWS site requires a public key generated on your computer which needs to be sent to Bill Engelke. His email is wdengelke@retiree.ua.edu
 
The best way to access that key is to run this command at the command prompt.  wd-sftp-psws
 
Running this will test connectivity to the PSWS server. If your key has not been installed on the server yet, you will see a failure message, However, you will also see the key that needs to be emailed to Bill to be entered into the server, allowing your system to upload data. Copy that key and email it to Bill. It's a very long string that looks like this...
 
ssh-ed25519 AAAAC3XxXxXxXXxxxxxxxxxxxx+m2injVxdYXJFFF99mhp5E3qkYngFsCITj wsprdaemon@XXXXX

When Bill confirms this has been entered into the PSWS account, you can run wd-sftp-psws again and it should return a message that looks like this.
 
The GRAPE_PSWS_ID=S000XXX_XXX is being derived from PSWS_STATION_ID=S000XXX and PSWS_DEVICE_ID=1XX
Testing Internnet connectivity to the PSWS server by running 'nc -vz -w 2 pswsnetwork.eng.ua.edu 22'
After  0 seconds, Successfully ran 'nc -vz pswsnetwork.eng.ua.edu 22'
Testing sftp autologin with 'sftp -o ConnectTimeout=20  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -b /dev/null S000XXX@pswsnetwork.eng.ua.edu'
After  1 seconds, Successfully ran 'sftp -o ConnectTimeout=20  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -b /dev/null S000XXX@pswsnetwork.eng.ua.edu'
 
 
The steps above should get your wsprdaemon connected and able to upload to the PSWS site. 
 
## Configuring WWV/CHU Channels in wsprdaemon.conf

Next, you must be sure that your wsprdaemon.conf schedule is set to run the WWV recordings. This is detailed in the wd_template.conf and wd_template_full.conf files which are both located in the wsprdaemon directory. To verify they are in fact running, type wds for a status and you should see something that looks like this..
 
 KA9Q_0_WWV,CHU_14,I1:   KA9Q_0_WWV,CHU_14 posting     Pid = 19778
     KA9Q_0_WWV,CHU_14,I1:   KA9Q_0_WWV,CHU_14 decoding    Pid = 20132
     KA9Q_0_WWV,CHU_14,I1:   KA9Q_0_WWV,CHU_14 recording   Pid = 17918
 
      KA9Q_0_WWV,CHU_3,I1:   KA9Q_0_WWV,CHU_3 posting     Pid = 18908
      KA9Q_0_WWV,CHU_3,I1:   KA9Q_0_WWV,CHU_3 decoding    Pid = 19294
      KA9Q_0_WWV,CHU_3,I1:   KA9Q_0_WWV,CHU_3 recording   Pid = 17918
 
      KA9Q_0_WWV,CHU_7,I1:   KA9Q_0_WWV,CHU_7 posting     Pid = 19367
      KA9Q_0_WWV,CHU_7,I1:   KA9Q_0_WWV,CHU_7 decoding    Pid = 19688
      KA9Q_0_WWV,CHU_7,I1:   KA9Q_0_WWV,CHU_7 recording   Pid = 17918
 
     KA9Q_0_WWV,WWV_10,I1:   KA9Q_0_WWV,WWV_10 posting     Pid = 16117
     KA9Q_0_WWV,WWV_10,I1:   KA9Q_0_WWV,WWV_10 decoding    Pid = 16884
     KA9Q_0_WWV,WWV_10,I1:   KA9Q_0_WWV,WWV_10 recording   Pid = 17918
 
     KA9Q_0_WWV,WWV_15,I1:   KA9Q_0_WWV,WWV_15 posting     Pid = 17046
     KA9Q_0_WWV,WWV_15,I1:   KA9Q_0_WWV,WWV_15 decoding    Pid = 17661
     KA9Q_0_WWV,WWV_15,I1:   KA9Q_0_WWV,WWV_15 recording   Pid = 17918
 
     KA9Q_0_WWV,WWV_20,I1:   KA9Q_0_WWV,WWV_20 posting     Pid = 17891
     KA9Q_0_WWV,WWV_20,I1:   KA9Q_0_WWV,WWV_20 decoding    Pid = 18530
     KA9Q_0_WWV,WWV_20,I1:   KA9Q_0_WWV,WWV_20 recording   Pid = 17918
 
     KA9Q_0_WWV,WWV_25,I1:   KA9Q_0_WWV,WWV_25 posting     Pid = 18508
     KA9Q_0_WWV,WWV_25,I1:   KA9Q_0_WWV,WWV_25 decoding    Pid = 18880
     KA9Q_0_WWV,WWV_25,I1:   KA9Q_0_WWV,WWV_25 recording   Pid = 17918
 
    KA9Q_0_WWV,WWV_2_5,I1:   KA9Q_0_WWV,WWV_2_5 posting     Pid = 14208
    KA9Q_0_WWV,WWV_2_5,I1:   KA9Q_0_WWV,WWV_2_5 decoding    Pid = 15066
    KA9Q_0_WWV,WWV_2_5,I1:   KA9Q_0_WWV,WWV_2_5 recording   Pid = 17918
 
      KA9Q_0_WWV,WWV_5,I1:   KA9Q_0_WWV,WWV_5 posting     Pid = 15138
      KA9Q_0_WWV,WWV_5,I1:   KA9Q_0_WWV,WWV_5 decoding    Pid = 16188
      KA9Q_0_WWV,WWV_5,I1:   KA9Q_0_WWV,WWV_5 recording   Pid = 17918
 

## Configuring radiod (from ka9q-radio) to present WWV/CHU RTP streams

In order for these files to be recorded, your radiod@rx888-wsprdaemon.conf configuration should have the [WWV-IQ] "disable" variable set to no. See below. You can find the conf file in the /etc/radio directory. 
 
[WWV-IQ]

encoding=float
disable=no
data = wwv-iq.local
agc=0
gain=0
samprate = 16k
mode = iq
freq = "60k000 2500000 5000000 10000000 15000000 20000000 25000000 3330000 7850000 14670000" ### Added the three CHU frequencies