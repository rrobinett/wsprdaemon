# Example of a working wsprdaemon.conf
```
        # RAC setup
        REMOTE_ACCESS_CHANNEL=27
        REMOTE_ACCESS_ID="AC0G-BEE1"

        # CPU/CORE TUNING if neccessary
        # the following will restrict wd processes to particular cores if necessary (e.g., Ryzen 7 - 5700 series)
        WD_CPU_CORES="8-15"
        RADIOD_CPU_CORES="0-7"

        # KA9Q-RADIO/WEB config
        KA9Q_RADIO_COMMIT="main"
        KA9Q_WEB_COMMIT_CHECK="main"
        KA9Q_RUNS_ONLY_REMOTELY="no"         ### If "yes" then WD will not install and configure its own copy of KA9Q-radio and thus assuemes the user has installed and configured it him/her self.
        KA9Q_GIT_PULL_ENABLED="yes"
        KA9Q_CONF_NAME="ac0g-bee1-rx888"
        KA9Q_WEB_TITLE="AC0G_@EM38ww_Longwire_Antenna"

        # REPORTING
        GRAPE_PSWS_ID="S000171_172"
        SIGNAL_LEVEL_UPLOAD="noise"           ### Whether and how to upload extended spots to wsprdaemon.org.  WD always attempts to upload spots to wsprnet.org
        SIGNAL_LEVEL_UPLOAD_ID="AC0G_LW"     ### The name put in upload log records, the title bar of the graph, and the name used to view spots and noise at that server.
        SIGNAL_LEVEL_UPLOAD_GRAPHS="yes"   ### If this variable is defined as "yes" AND SIGNAL_LEVEL_UPLOAD_ID is defined, then FTP graphs of the last 24 hours to http://wsprdaemon.org/graphs/SIGNAL_LEVEL_UPLOAD_ID

        # SCHEDULE
        declare receiver="KA9Q_LONGWIRE"
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