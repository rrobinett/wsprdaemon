# Example of a working wsprdaemon.conf
```
        # 1. Computer-related parameters:
        # RAC setup
        REMOTE_ACCESS_CHANNEL=27
        REMOTE_ACCESS_ID="AC0G-BEE1"

        # CPU/CORE TUNING if neccessary
        # the following will restrict wd processes to particular cores if necessary (e.g., Ryzen 7 - 5700 series)
        WD_CPU_CORES="8-15"
        RADIOD_CPU_CORES="0-7"

        # 2. ka9q-radio/web parameters
        KA9Q_RADIO_COMMIT="main"
        KA9Q_RUNS_ONLY_REMOTELY="no" 
        KA9Q_CONF_NAME="ac0g-bee1-rx888"
        KA9Q_WEB_COMMIT_CHECK="main"
        KA9Q_WEB_TITLE="AC0G_@EM38ww_Longwire_Antenna"

        # 3. Reporting parameters
        GRAPE_PSWS_ID="S000171_172"
        SIGNAL_LEVEL_UPLOAD="noise"  
        SIGNAL_LEVEL_UPLOAD_ID="AC0G_BEE1"
        SIGNAL_LEVEL_UPLOAD_GRAPHS="yes"  

        # 4. Receiver definitions
        # two radiod receivers -- one for wspr and one for wwv
        declare RECEIVER_LIST=(
                "KA9Q_0                     wspr-pcm.local     AI6VN         CM88mc    NULL"    
                "KA9Q_0_WWV_IQ                wwv-iq.local     AI6VN         CM88mc    NULL"     
        )

        # 5. Schedule definitions
        # SCHEDULE
        declare receiver="KA9Q_0"
        declare WSPR_SCHEDULE=(
            "00:00  ${receiver},2200,W2:F2:F5:F15:F30      ${receiver},630,W2:F2:F5      ${receiver},160,W2:F2:F5
                    ${receiver},80,W2:F2:F5                ${receiver},80eu,W2:F2:F5     ${receiver},60,W2:F2:F5
                    ${receiver},60eu,W2:F2:F5              ${receiver},40,W2:F2:F5       ${receiver},30,W2:F2:F5
                    ${receiver},22,W2                      ${receiver},20,W2:F2:F5       ${receiver},17,W2:F2:F5
                    ${receiver},15,W2:F2:F5                ${receiver},12,W2:F2:F5       ${receiver},10,W2:F2:F5

                    ${receiver}_WWV,WWV_2_5,I1             ${receiver}_WWV,WWV_5,I1      ${receiver}_WWV,WWV_10,I1
                    ${receiver}_WWV,WWV_15,I1              ${receiver}_WWV,WWV_20,I1     ${receiver}_WWV,WWV_25,I1
                    ${receiver}_WWV,CHU_3,I1               ${receiver}_WWV,CHU_7,I1      ${receiver}_WWV,CHU_14,I1"
        )
```