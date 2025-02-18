
# Reporting

## WSPR

```
###################  The following variables are used in normally running installations ###################
SIGNAL_LEVEL_UPLOAD="noise"           ### Whether and how to upload extended spots to wsprdaemon.org.  WD always attempts to upload spots to wsprnet.org
                                    ### SIGNAL_LEVEL_UPLOAD="no"         => (Default) Only upload spots directly to wsprnet.org
                                    ### SIGNAL_LEVEL_UPLOAD_MODE="noise" => In addition, upload extended spots and noise data to wsprdaemon.org
                                    ### SIGNAL_LEVEL_UPLOAD_MODE="proxy" => Don't directly upload spots to wsprdaemon.org.  Instead, after uploading extended spots and noise data to wsprdaemon.org have it regenerate and upload those spots to wsp
                                    ###                                     This mode minimizes the use of Internet bandwidth, but makes getting spots to wsprnet.org dependent upon the wsprdameon.org services.

# If SIGNAL_LEVEL_UPLOAD in NOT "no", then you must modify SIGNAL_LEVEL_UPLOAD_ID from "AI6VN" to your call sign.  SIGNAL_LEVEL_UPLOAD_ID cannot include '/
SIGNAL_LEVEL_UPLOAD_ID="OE3GBB_Q"     ### The name put in upload log records, the title bar of the graph, and the name used to view spots and noise at that server.
# SIGNAL_LEVEL_UPLOAD_GRAPHS="yes"   ### If this variable is defined as "yes" AND SIGNAL_LEVEL_UPLOAD_ID is defined, then FTP graphs of the last 24 hours to http://wsprdaemon.org/graphs/SIGNAL_LEVEL_UPLOAD_ID
# SIGNAL_LEVEL_LOCAL_GRAPHS="yes"    ### If this variable is defined as "yes" AND SIGNAL_LEVEL_UPLOAD_ID is defined, then make graphs visible at http://localhost/
#
### Graphs  default to y-axis minimum of -175 dB to maximum of -105 dB.  X pixels default to 40, Y pixels default to 30.  If the graph of your system isn't pleasing, you can change the graph's appearance by
### uncommenting one or more of these variables and changing their values
# NOISE_GRAPHS_Y_MIN=-175
# NOISE_GRAPHS_Y_MAX=-105
# NOISE_GRAPHS_X_PIXEL=40
# NOISE_GRAPHS_Y_PIXEL=30
```

## HamSCI -- Grape

##################### Starting in WD 3.1.4, WD adds configurable support for the HamSCI GRAPE WWV Doppler shift project: https://hamsci.org/grape. To do that:

On servers with local or remote RX888 receivers, WD can be configured to record a continuous series of one minute long 16000 sps flac-compressed IQ wav files.
Soon after 00:00 UDT, WD creates a single 3.8 MB 24hour-10hz-iq.wav file which is uploaded to WD's WD1 server at grape.wsprdaemon.org.
WD software on WD1 then converts the one or more time station band recordings into HamSCI's Digital RF file format and uploads those DRF files to the HamSCI server
Each WD site contributing to the GRAPE project needs to obtain a SITE_ID,INSTRUMENT_ID, and TOKEN from its user account at https://pswsnetwork.caps.ua.edu/
Then uncomment and edit these variables with that information.
This server will also need the KA9Q-radio 'radiod' services to be configured to output WWV-IQ channels
WD must be configured to record those channels by defining one or more receivers defined to listen to the WWV-IQ channels
In addition to configuring /etc/radio/radiod@rx888-wsprdaemon.conf with active WWV-IQ channels, and wsprdaemon.conf with receivers and a schedule to listen to those channels
These two variables need to be defined in order to enable this WD GRAPE service:
#GRAPE_PSWS_ID="<SITE_ID><INSTRUMENT_ID>" ### If this and GRAPE_PSWS_TOKEN are both defined, then each day soon after 00:00 UDT WD will upload the previous day's 24_hour_10sps-iq.wav file ### GRAPE_PSWS_ID has the form <SITE_ID><INSTRUMENT_ID>, where those values are obtained from a PSWS user account which assigns these values for ### this site+receiver. That PSWS site is at https://pswsnetwork.caps.ua.edu/home ### SITE_ID has the form 'S000nnn' while INSTRUMENT has the form 'NNN' #GRAPE_PSWS_TOKEN="0a1b2c3d4e5f6g7h8i9j0k" ### This value is the "token" created for that user account by the PSWS server. It is a very long string with 0-9 and a-z characters in it ### Together GRAPE_PSWS_ID + GRAPE_PSWS_PASSWORD are the user+password used to authenticate rsync access to WD1/grape.wsprdaemon.org

After those variables are defined, the WD user must register this server with the GRAPE server by executing 'wdg p'. This command needs to be run successfully only once after which automatic uploads to the GRAPE server are enabled.
The token is actually the ssh password to your account on the PSWS server. When GRAPE_PSWS_ID=.... is set in your WD.conf file, you will be prompted for a password by ssh-copyid when it tries to load your public key on your account at the PSS server. Copy and past the token as your response to ssh-copyid.

Don't add GRAPE_PSWS_TOKEN="blahblahblah" to your wsprdaemon.conf file. When a GRAPE_PSWS_ID="S000NNN_NNN" is defined WD will attempt an ssh auto login to that account on the PSWS server. If that login fails, WD runs 'ssh-copyid ...' and you should be prompted by ssh-copyid to enter your ssh password of your account on the PSWS server. Is copy/paste the ssh password (a 'token' in its account status page) from your PSWS account to the login session.
If you succeed in executing ssh-copyid, then WD can login and upload GRAPE data from your WD server to the PSWS server.

You can check if auto login is working by executing the 'wdssp' alias.

Source : https://groups.io/g/wsprdaemon/message/3319 Rob Robinett Source : https://github.com/rrobinett/wsprdaemon/blob/master/wd_template.conf Source : https://groups.io/g/wsprdaemon/message/3301 Rob Robinett

## PSKReporter

