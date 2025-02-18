
# Schedule

## 
```
### The WSPR_SCHEDULE[] array (table) defines a schedule of configurations which will applied by WD's  watchdog daemon when it runs every odd two minutes
### The first field of each entry is the start time for the configuration defined in the following fields
### Start time is in the format HH:MM (e.g 13:15) and by default is in the time zone of the host server '01:30'
### Start times can also be specified by 'sunrise' or 'sunset' followed optionally by "+HH:MM" or "-HH:MM" e.g. "sunrise+01:00"
### Schedules are referenced to the time zone of the host server.  So if your server is set to 'America/New_York', then the entry times are for EST/EDT
### If the time of the first entry is not 00:00, then the latest entry (which may not necessarily be the last ) will be applied at time 00:00

### Following the time are one or more fields of the format 'RECEIVER,BAND[,MODE_1[:MODE_2[:...]]'
### The value of RECEIVER must match one of the receivers defined in RECEIVER_LIST[]

### The value of BAND must match one of:
### WSPR bands:            2200 630 160 80 80eu 60 60eu 40 30 22 20 17 15 12 10 6 4 2 1 0
### Noise only bands:      WWVB WWV_2_5 WWV_5 WWV_10 WWV_15 WWV_20 WWV_25 CHU_3 CHU_7 CHU_14

### The optional 'MODE' arguments specify one or more packet decode modes:
###    I1     => Record and archive a series of one minute long IQ files from a KA9Q stream. KA9Q/radiod must be configured to output those streams
###              The IQ wav file are losslessly compressed by 'flac' and stored in tar files which are by default located in ~/wsprdemon/wav-archive.d/...
###    WO     => for the 'Noise only' bands, which runs the 'wsprd' decoder in its fastest to run mode.  This mode cannot be specified with the other modes
###    W2     => legacy WSPR 2 minute mode (the default if no modes are specified)
###    F2     => FST4W-120  (2 minute)
###    F5     => FST4W-300  (5 minute)
###    F15    => FST4W-900  (15 minue)
###    F30    => FST4W-1800 (30 minute)
###  For example "00:00   KIWI_0,630,W2:F2:F5  AI6VN"   specifies that KIWI_0 should tune to 630M and decode WSPR-2,FST4W-120, and FST4W-300 mode packets
###  Specifying additional modes will add to the CPU burden of the sysem and even more significantly to the peak usage of the /tmp/wsprdaemon tmpfd (ramdisk) file system
###  In 3.0.2.4 and later, WD calculates the peak usages of the /tmp/wsprdaemon file system and warns if that file system may overflow.
###  For FST4W modes spectral width estimation is enabled and is available in the wsprdaemon_spots_s table in database tutorial on wd3.wsprdaemon.org as 'metric'
### So the form of each line is  "HH:MM   RECEIVER,BAND[,MODE_1[:Mode2[...]]...] ".  Here are some examples:
declare WSPR_SCHEDULE_simple=(
    "00:00                       KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
)

declare WSPR_SCHEDULE_complex=(
    "sunrise-01:00               KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12          "
    "sunrise+01:00                          KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "09:00                       KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12          "
    "10:00                                  KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "11:00                                             KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "18:00           KIWI_0,2200 KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15                    "
    "sunset-01:00                           KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
    "sunset+01:00                KIWI_0,630 KIWI_0,160 KIWI_1,80 KIWI_2,80eu KIWI_2,60 KIWI_2,60eu KIWI_1,40 KIWI_1,30 KIWI_1,20 KIWI_1,17 KIWI_1,15 KIWI_1,12 KIWI_1,10"
)

### KA9Q + and RX-888 Mk II can easily decode all the bands as long as you have enough CPU
declare WSPR_SCHEDULE_ka9q=(
    "00:00             KA9Q_0,2200,W2:F2:F5  KA9Q_0,630,W2:F2:F5  KA9Q_0,160,W2:F2:F5  KA9Q_0,80,W2:F2:F5  KA9Q_0,80eu,W2:F2:F5  KA9Q_0,60,W2:F2:F5  KA9Q_0,60eu,W2:F2:F5  KA9Q_0,40,W2:F2:F5
                       KA9Q_0,30,W2:F2:F5    KA9Q_0,20,W2:F2:F5   KA9Q_0,17,W2:F2:F5  KA9Q_0,15,W2:F2:F5    KA9Q_0,12,W2:F2:F5  KA9Q_0,10,W2:F2:F5"
)

declare WSPR_SCHEDULE_merged=(
    "00:00 MERG_K01_Q01,2200,W2:F2:F5 MERG_K01_Q01,630,W2:F2:F5   MERG_K01_Q01,160,W2:F2:F5  MERG_K01_Q01,80,W2:F2:F5  MERG_K01_Q01,80eu,W2:F2:F5
           MERG_K01_Q01,60,W2:F2:F5   MERG_K01_Q01,60eu,W2:F2:F5  MERG_K01_Q01,40,W2:F2:F5   MERG_K01_Q01,30,W2:F2:F5  MERG_K01_Q01,22,W2:F2:F5
           MERG_K01_Q01,20,W2:F2:F5   MERG_K01_Q01,17,W2:F2:F5    MERG_K01_Q01,15,W2:F2:F5   MERG_K01_Q01,12,W2:F2:F5  MERG_K01_Q01,10,W2:F2:F5"
)

### This is how to define IQ recording+archiving jobs.  We are decoding WSPR-2 and FST4W on 20M, recording and archiving a wav file of 20M WSPR,
### And recording and archiving a a wav file of 10 MHz WWV.  The series of 1 minute long wav files are losslessly compressed by 'flac' by about 50% and stored in a series of
### tar files found in ~/wsprdaemon/wav-archive.d/.  A new tar file is created at each odd minute and it contains all of the wav files from the precious 2 minutes.
### 'tar -tf xxxx.tar' will list the wav files in the tar file.
declare WSPR_SCHEDULE_iq=(
     "00:00     KIWI_0,20,W2:F2  KA9Q_0_WSPR_IQ,20,I1  KA9Q_0_WWV_IQ,WWV_10,I1"
)

### This array WSPR_SCHEDULE defines the running configuration.  Here we make the simple configuration defined above the active one:
#declare WSPR_SCHEDULE=( "${WSPR_SCHEDULE_merged[@]}" )
#declare WSPR_SCHEDULE=( "${WSPR_SCHEDULE_simple[@]}" )
```