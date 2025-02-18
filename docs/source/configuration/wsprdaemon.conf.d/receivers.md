
# Receiver definitions

## KiwiSDR

## KA9Q

```
##############################################################
### The RECEIVER_LIST() array defines the physical (KIWI_xxx or KA9Q...) and logical (MERG...) receive devices available on this server
### Each element of RECEIVER_LIST is a string with 5 space-separated fields:
###   " ID(no spaces)             IP:PORT or RTL:n    MyCall       MyGrid  KiwPassword    Optional SIGNAL_LEVEL_ADJUSTMENTS
###                                                                                       [[DEFAULT:ADJUST,]BAND_0:ADJUST[,BAND_N:ADJUST_N]...]
###                                                                                       A comma-separated list of BAND:ADJUST pairs
###                                                                                       BAND is one of 2200..10, while ADJUST is in dBs TO BE ADDED to the raw data
###                                                                                       So If you have a +10 dB LNA, ADJUST '-10' will LOWER the reported level so that your reports reflect the level at the input of the LNA
###                                                                                       DEFAULT defaults to zero and is applied to all bands not specified with a BAND:ADJUST

declare RECEIVER_LIST=(
        "KA9Q_0                     wspr-pcm.local     OE3GBB/Q        JN87aq    NULL"      ### A receiver name which starts with 'KA9Q_...' will decode wav files supplied by the KA9Q-radio multicast RTP streams
                                                                                          ### In WD 3.1.0 WD assumes all WSPR audio streams come from a local instance of KA9Q
                                                                                          ### which by default outputs all the WSPR audio stream on the multicast DNS address wspr-pcm.local
        "KA9Q_1                    wspr1-pcm.local     AI6VN         CM88mc    NULL"      ### Multicast streams from remote KA9Q receivers can be sources, and not just RX-888s
        "KA9Q_0_WSPR_IQ              wspr-iq.local     AI6VN         CM88mc    NULL"      ### Multicast IQ streams from the local RX888 + KA9Q receiver
        "KA9Q_0_WWV_IQ                wwv-iq.local     AI6VN         CM88mc    NULL"      ### Those streams are not enabled by default in the radiod.conf file. So if you configue an IQ rx job,
                                                                                          ###    you will need to set 'disabled = no' for one or both in radiod@rx888-wsprdaemon.conf and then restart radiod

        "KIWI_0                  10.11.12.100:8073     AI6VN         CM88mc    NULL"
        "KIWI_1                  10.11.12.101:8073     AI6VN         CM88mc  foobar       DEFAULT:-10,80:-12,30:-8,20:2,15:6"     ### You can optionally adjust noise levels for the antenna factor
        "KIWI_2                  10.11.12.102:8073     AI6VN         CM88mc  foobar"

        "MERG_K01_Q01  KIWI_0,KIWI_1,KA9Q_0,KA9Q_1     AI6VN         CM88mc  foobar"      ### For a  receiver with a  name starting with "MERG", the IP field is a list of two or more 'real' receivers a defined above. For a logical MERG receiver
)

```
