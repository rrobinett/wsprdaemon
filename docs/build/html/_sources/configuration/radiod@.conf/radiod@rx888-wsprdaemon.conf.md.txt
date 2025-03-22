# Example radiod@rx888-wsprdaemon.conf

## minimalist setup on a single computer for wspr, wwv, ft4 and ft8.

The following directs radiod to use a RX888 to present simultaneous multicast streams of 16 wspr channels, streams of 7 wwv and 3 chu channels, and streams of 9 ft4 and 11 ft8 channels.

You will find more detailed descriptions of these sections in:
- [global](./global.md)
- [hardware](./hardware.md)
- [channels](./channels.md)

---

```
[global]
hardware = rx888 
status = bee1-hf-status.local 
samprate = 12000  
mode = usb        
ttl = 0           
fft-threads = 0

[rx888]
device = "rx888" 
description = "AC0G @EM38ww dipole" # good to put callsign and antenna description in here
samprate =   64800000     # or 129600000

[WSPR]
encoding = float
disable = no
data = bee1-wspr-pcm.local
agc=0
gain=0
samprate = 12000
mode = usb
low=1300
high=1700
freq = "136k000 474k200 1m836600 3m568600 3m592600 5m287200 5m364700 7m038600 10m138700 13m553900 14m095600 18m104600 21m094600 24m924600 28m124600 50m293000""

[WWV-IQ]
disable = no
encoding=float
data = bee1-wwv-iq.local
agc=0
gain=0
samprate = 16k
mode = iq
freq = "60000 2m500000 5m000000 10m000000 15m000000 20m000000 25m000000 3m330000 7m850000 14m670000"       ### Added the three CHU frequencies

[FT8]
disable = no
data = ft8-pcm.local
mode = usb
freq = "1m840000 3m573000 5m357000 7m074000 10m136000 14m074000 18m100000 21m074000 24m915000 28m074000 50m313000"

[FT4]
disable = no
data = ft4-pcm.local
mode = usb
freq = "3m575000 7m047500 10m140000 14m080000 18m104000 21m140000 24m919000 28m180000 50m318000"
```


