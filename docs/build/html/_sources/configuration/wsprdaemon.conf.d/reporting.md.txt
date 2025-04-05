
# Reporting

## WSPR Reporting

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

## HamSCI -- Grape Reporting

WD includes configurable support for the [HamSCI GRAPE WWV Doppler shift project](https://hamsci.org/grape).  From local or remote RX888 receivers, WD can record a continuous series of one minute long 16000 sps flac-compressed IQ wav files.  Soon after 00:00 UTC, WD creates a single 3.8 MB 24hour-10hz-iq.wav file which is uploaded to WD's WD1 server at grape.wsprdaemon.org.  WD software on WD1 then converts the one or more time station band recordings into [Digital RF (DRF)](https://github.com/MITHaystack/digital_rf) file format and uploads those DRF files to the HamSCI server.

You must create an account at https://pswsnetwork.caps.ua.edu/.  This account enables you to manage your site(s) and instrument(s).  

After establishing your account, you create a "site" having a SITE_ID and a TOKEN for each WD instance contributing to the GRAPE project.  The SITE_ID takes the form "S000NNN".  You typically name the site with your callsign and a useful discriminator if you have more than one site, for instance, "AC0G_B1", "AC0G_B2".  For each site, you add an "instrument" of particular type, for instance, "magnetometer" or "rx888", with an INSTRUMENT_ID.  You can create multiple sites but each site has only one instrument.  The SITE_ID and TOKEN function as username and password for uploading data.  The SITE_ID and INSTRUMENT_ID function to identify the data in DRF.

On your WD server, you then 
- [configure KA9Q-radio](../radiod@.conf/channels.md) to output WWV-IQ channels. 
- [configure WD receivers](./receivers.md) listen to those channels. 
- [configure a WD schedule](./schedule.md) for listening on each channel.  
- [configure WD reporting](./reporting.md) with GRAPE_PSWS_ID="<SITE_ID>_<INSTRUMENT_ID>" 

Finally, enable automatic uploads of HamSCI data.  For example, with SITE_ID="S000987" run: 
```
ssh-copy-id S000987@pswsnetwork.caps.ua.edu
``` 
The site will respond by asking for a password.  Enter the TOKEN for that site and you should get a message of success.  The most common cause of failure at this point is errant copy and paste with a character missing or an added space at the beginning or end of the token string.

You can check if auto login works by executing the 'wdssp' alias.

Source : https://groups.io/g/wsprdaemon/message/3319 Rob Robinett Source : https://github.com/rrobinett/wsprdaemon/blob/master/wd_template.conf Source : https://groups.io/g/wsprdaemon/message/3301 Rob Robinett

## PSKReporter

