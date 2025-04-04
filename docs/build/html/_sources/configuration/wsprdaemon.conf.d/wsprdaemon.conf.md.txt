# Example of a working wsprdaemon.conf

Minimalist configuration for a stand-alone machine that listens to wspr and WWV/CHU streams from radiod (ka9q-radio), then processes and uploads the results to wsprnet, wsprdaemon.org, pskreporter, and pswsnetwork.caps.ua.edu.  

You will find further details on these parameters and definitions in 
- [Computer-related parameters](./computer.md)
- [ka9q-radio/web parameters](./ka9q-radio.md)
- [reporting parameters](./reporting.md)
- [receiver definitions](./receivers.md)
- [schedule definitions](./schedule.md)

```
        # 1. Computer-related parameters:
        # RAC setup enables WD supporters to access your machine remotely.  Get a RAC # from Rob Robinett.
        # WD will run without this 
        REMOTE_ACCESS_CHANNEL=27
        REMOTE_ACCESS_ID="AC0G-BEE1"

        # CPU/CORE TUNING if neccessary
        # the following will restrict wd processes to particular cores if necessary (e.g., Ryzen 7 - 5700 series)
        # WD will run without this
        WD_CPU_CORES="2-15"
        RADIOD_CPU_CORES="0-1"

        # 2. ka9q-radio/web parameters
        KA9Q_RADIO_COMMIT="main"
        KA9Q_RUNS_ONLY_REMOTELY="no" 
        KA9Q_CONF_NAME="ac0g-bee1-rx888"
        KA9Q_WEB_COMMIT_CHECK="main"
        # If you don't set the title here, it will default to the description in the radiod@config file
        KA9Q_WEB_TITLE="AC0G_@EM38ww_Longwire"

        # 3. Reporting parameters
        # for contributing to HamSCI monitoring of WWV/CHU
        GRAPE_PSWS_ID="S000171_172"
        # for reporting to wsprdaemon.org
        SIGNAL_LEVEL_UPLOAD="noise"  
        SIGNAL_LEVEL_UPLOAD_ID="AC0G_BEE1"
        SIGNAL_LEVEL_UPLOAD_GRAPHS="yes"  

        # 4. Receiver definitions -- REQUIRED
        # two radiod receivers -- one for wspr and one for wwv
        declare RECEIVER_LIST=(
                "KA9Q_0_WSPR                  wspr-pcm.local     AI6VN         CM88mc    NULL"    
                "KA9Q_0_WWV_IQ                wwv-iq.local       AI6VN         CM88mc    NULL"     
        )

        # 5. Schedule definitions -- REQUIRED
        # SCHEDULE
        declare WSPR_SCHEDULE=(
            "00:00  KA9Q_0_WSPR,2200,W2:F2:F5:F15:F30      KA9Q_0_WSPR,630,W2:F2:F5      KA9Q_0_WSPR,160,W2:F2:F5
                    KA9Q_0_WSPR,80,W2:F2:F5                KA9Q_0_WSPR,80eu,W2:F2:F5     KA9Q_0_WSPR,60,W2:F2:F5
                    KA9Q_0_WSPR,60eu,W2:F2:F5              KA9Q_0_WSPR,40,W2:F2:F5       KA9Q_0_WSPR,30,W2:F2:F5
                    KA9Q_0_WSPR,22,W2                      KA9Q_0_WSPR,20,W2:F2:F5       KA9Q_0_WSPR,17,W2:F2:F5
                    KA9Q_0_WSPR,15,W2:F2:F5                KA9Q_0_WSPR,12,W2:F2:F5       KA9Q_0_WSPR,10,W2:F2:F5

                    KA9Q_0_WWV_IQ,WWV_2_5,I1               KA9Q_0_WWV_IQ,WWV_5,I1        KA9Q_0_WWV_IQ,WWV_10,I1
                    KA9Q_0_WWV_IQ,WWV_15,I1                KA9Q_0_WWV_IQ,WWV_20,I1       KA9Q_0_WWV_IQ,WWV_25,I1
                    KA9Q_0_WWV_IQ,CHU_3,I1                 KA9Q_0_WWV_IQ,CHU_7,I1        KA9Q_0_WWV_IQ,CHU_14,I1"
        )
```