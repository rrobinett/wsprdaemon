# Example radiod@rx888-wsprdaemon.conf
## set up for wspr, ft4 and ft8 only.
```
[global]
hardware = rx888 # use built-in rx888 driver, configured in [rx888]
status = hf.local       # DNS name for receiver status and commands
samprate = 12000        # default output sample rate
mode = usb              # default receive mode
ttl = 0                 # 1 if sending RTP streams -- need IGMP switch to protect your LAN
fft-threads = 0

[rx888]
device = "rx888" # required so it won't be seen as a demod section
description = "AC0G @EM38ww dipole" # good to put callsign and antenna description in here
samprate =   64800000     # or 129600000

[WSPR]
encoding=float
disable = no
data = opi5-wspr-pcm.local
agc=0
gain=0
samprate = 12000
mode = usb
low=1300
high=1700
freq = "136k000 474k200 1m836600 3m568600 3m592600 5m287200 5m364700 7m038600 10m138700 13m553900 14m095600 18m104600 21m094600 24m924600 28m124600 50m293000""

[FT8]
disable = no
data = ft8-pcm.local
mode = usb
freq = "1m840000 3m573000 5m357000 7m074000 10m136000 14m074000 18m100000 21m074000 24m915000 28m074000 50m313000"

[FT4]
disable = no
data = ft4-pcm.local
mode = usb
freq = "3m575000 7m047500 10m140000 14m080000 18m10k000 21m140000 24m919000 28m180000 50m318000"
```


