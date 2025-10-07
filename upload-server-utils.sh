#!/bin/bash

if [[  ${HOSTNAME:0:2} == "WD" ]]; then
    if [[ ${HOSTNAME} == "WD0" ]]; then
        declare UPLOAD_FTP_PATH="/home/noisegraphs/ftp/upload"                          ### Where the FTP server puts the uploaded tar.tbz files from WD clients
        if ! [[ -d ${UPLOAD_FTP_PATH} ]]; then
            wd_logger 1 "ERROR: can't find the expected incoming .tbz files directory '${UPLOAD_FTP_PATH}' on server WD0"
            echo ${force_abort}
        fi
    else
        ### As of 9/28/2025 WD1 and WD2 look for .tbz files in directories under /var/spool/wsprdaemon/..
        declare INCOMING_TBZS_DIR_ROOT_PATH="/var/spool/wsprdaemon"
        sudo mkdir -p ${INCOMING_TBZS_DIR_ROOT_PATH}
        sudo mkdir -p ${INCOMING_TBZS_DIR_ROOT_PATH}/from-wd0
        sudo mkdir -p ${INCOMING_TBZS_DIR_ROOT_PATH}/from-wd00
        sudo chown -R wsprdaemon:wsprdaemon ${INCOMING_TBZS_DIR_ROOT_PATH}

        ### Make sure the Clickhouse database is installed 
   fi
fi
declare TS_NOISE_AWK_SCRIPT=${WSPRDAEMON_ROOT_DIR}/ts_noise.awk

### The extended spot lines created by WD 2.x have these 32 fields:
### spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin       <=== Taken directly from the ALL_WSPR.TXT spot lines
###                         spot_for_wsprnet spot_rms_noise spot_c2_noise                                                                                                                                             <=== Added by the decode_daemon()
###                         band my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon                                                                                                          <=== Added by add_azi() python code

###  WD 3.0 adds two additional fields at the end of each extended spot line for a total of 34 fields:
###                         overload_counts  pkt_mode

declare MAX_SPOT_LINES=5000  ### Record no more than this many spot lines at a time to TS and CH 
declare MAX_RM_ARGS=5000     ### Limit of the number of files in the 'rm ...' cmd line
declare TBZ_SERVER_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/uploads
declare TBZ_PROCESSED_ARCHIVE_FILE="${TBZ_SERVER_ROOT_DIR}/tbz_processed_list.txt"
declare MAX_SIZE_TBZ_PROCESSED_ARCHIVE_FILE=1000000            ### limit its size

declare TBZ_SPOTS_TMP_FILE_SYSTEM_SIZE=$(df ${UPLOADS_TMP_ROOT_DIR} | awk '/^tmpfs/{print $2}')
declare TBZ_SPOTS_TMP_FILE_SYSTEM_MAX_USAGE=$(( (TBZ_SPOTS_TMP_FILE_SYSTEM_SIZE * 2) / 3 ))           ### Use no more than 2/3 of the /tmp/wsprdaemon file system

### Use the database and table names from wsprdaemon.conf
declare CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE="${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}.${CLICKHOUSE_WSPRDAEMON_DATABASE_SPOTS_TABLE_NAME}"
declare CLICKHOUSE_WSPRDAEMON_NOISE_TABLE="${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}.${CLICKHOUSE_WSPRDAEMON_DATABASE_NOISE_TABLE_NAME}"
declare CLICKHOUSE_WSPRDAEMON_BANDS_TABLE="${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}.bands"

function setup_clickhouse_wsprdaemon_tables() 
{
    local rc

    # Use admin user for all database/table creation and modification operations
    clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="SELECT 1 FROM system.databases WHERE name = '${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}'" | grep -q 1
    rc=$? ; if (( rc == 0 )); then
        wd_logger 1 "The '${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}' database already exists"
    else
        wd_logger 1 "Creating the '${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}' database"
        clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="CREATE DATABASE ${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}"
        rc=$? ; if (( rc )); then
            wd_logger 1 "Failed to create missing '${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}' database"
            echo ${force_abort}
        fi
        wd_logger 1 "Created the missing '${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}' database"
    fi

    ### If necessary create wsprdaemon.bands table which translates bands to tuning frequency
    if (( $(clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="EXISTS TABLE ${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}") )); then
        wd_logger 1 "Table ${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE} already exists"
    else
        wd_logger 1 "Creating missing ${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}"
        clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="
CREATE TABLE ${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE} (
    band            Int16,
    frequency       UInt64,
    display         LowCardinality(String),
    is_beacon_band  UInt8
)
ENGINE = MergeTree
ORDER BY band;
"
        rc=$? ; if (( rc )); then
            wd_logger 1 "Failed to create missing '${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}' table"
            echo ${force_abort}
         else
             wd_logger 1 "Created the missing '${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}' table"
        fi
    fi

    if (( $(clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="select count(*) from ${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}")  )); then
         wd_logger 1 "'${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}' table has been initialized"
     else
         wd_logger 1 "Initializing an empty '${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}' table"
         clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query "
         INSERT INTO  ${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE} (band, frequency, display, is_beacon_band) VALUES
(-1,     136000,      'LF',     0),
(0,      474200,      'MF',     0),
(1,     1836600,      '160m',   0),
(3,     3568600,      '80m',    1),
(5,     5287200,      '60m',    0),
(7,     7038600,      '40m',    1),
(10,   10138700,      '30m',    1),
(13,   13553900,      '22m',    0),
(14,   14095600,      '20m',    1),
(18,   18104600,      '17m',    1),
(21,   21094600,      '15m',    1),
(24,   24924600,      '12m',    1),
(28,   28124600,      '10m',    1),
(40,   40680000,      '8m',     0),
(50,   50293000,      '6m',     0),
(70,   70091000,      '4m',     0),
(144, 144489000,      '2m',     0),
(432, 432300000,      '70cm',   0),
(1296,1296500000,     '23m',    0);
"
        rc=$? ; if (( rc )); then
            wd_logger 1 "Failed to initialize '${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}' table"
            echo ${force_abort}
        else
            wd_logger 1 "Initialized '${CLICKHOUSE_WSPRDAEMON_BANDS_TABLE}' table"
        fi
    fi

    ### If needed, create the wsprdaemon_spots table
    if (( $(clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="EXISTS TABLE ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE}") )); then
        wd_logger 1 "Table ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE} already exists"
    else
        wd_logger 1 "Creating ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE}"
        ### The fields in this wsprdaemon.spots table are in their order in the csv file
        ###     and that order comes from the spot lines uploaded by the clients
        ###     and that order derives from their order in ALL_WSPR.TXT
        clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="
CREATE TABLE ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE} (
    time           DateTime                CODEC(ZSTD(1)),
    band           Int16                   CODEC(ZSTD(1)),
    rx_grid        LowCardinality(String)  CODEC(LZ4),
    rx_id          LowCardinality(String)  CODEC(LZ4),
    tx_call        LowCardinality(String)  CODEC(LZ4),
    tx_grid        LowCardinality(String)  CODEC(LZ4),
    SNR            Float32                 CODEC(Delta(4), ZSTD(3)),
    c2_noise       Float32                 CODEC(Delta(4), ZSTD(3)), -- Mapped from fft_noise
    drift          Float32                 CODEC(Delta(4), ZSTD(3)),
    freq           Float32                 CODEC(Delta(4), ZSTD(3)),
    km             Int32                   CODEC(T64, ZSTD(1)),      -- Mapped from distance
    rx_az          Float32                 CODEC(Delta(4), ZSTD(3)), -- Mapped from rx_azimuth
    rx_lat         Float32                 CODEC(Delta(4), ZSTD(3)),
    rx_lon         Float32                 CODEC(Delta(4), ZSTD(3)),
    tx_az          Float32                 CODEC(Delta(4), ZSTD(3)), -- Mapped from azimuth
    tx_dBm         UInt8                   CODEC(T64, ZSTD(1)),      -- Mapped from power
    tx_lat         Float32                 CODEC(Delta(4), ZSTD(3)),
    tx_lon         Float32                 CODEC(Delta(4), ZSTD(3)),
    v_lat          Float32                 CODEC(Delta(4), ZSTD(3)),
    v_lon          Float32                 CODEC(Delta(4), ZSTD(3)),
    sync_quality   UInt16                  CODEC(ZSTD(1)),
    dt             Float32                 CODEC(Delta(4), ZSTD(3)),
    decode_cycles  UInt32                  CODEC(T64, ZSTD(1)),
    jitter         Int16                   CODEC(T64, ZSTD(1)),
    rms_noise      Float32                 CODEC(Delta(4), ZSTD(3)),
    blocksize      UInt16                  CODEC(T64, ZSTD(1)),
    metric         Int16                   CODEC(T64, ZSTD(1)),
    osd_decode     UInt8                   CODEC(T64, ZSTD(1)),
    receiver       LowCardinality(String)  CODEC(LZ4),
    nhardmin       UInt16                  CODEC(T64, ZSTD(1)),
    ipass          UInt8                   CODEC(T64, ZSTD(1)),
    proxy_upload   UInt8                   CODEC(T64, ZSTD(1)),
    mode           Int16                   CODEC(ZSTD(1)),
    ov_count       UInt32                  CODEC(T64, ZSTD(1)),
    rx_status      LowCardinality(String)  DEFAULT 'No Info' CODEC(LZ4)
) 
ENGINE = MergeTree
PARTITION BY toYYYYMM(time)
ORDER BY (time)
SETTINGS index_granularity = 8192;
"
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: clickhouse ... CREATE ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE} => ${rc}"
            echo ${force_abort}
        else
            wd_logger 1 "Created ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE}"
        fi
    fi

    ### If needed, create the wsprdaemon_noise table
    if (( $(clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="EXISTS TABLE ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE}") )); then
        wd_logger 1 "Table ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE} already exists"
    else
        wd_logger 1 "Creating ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE}"
        ### The fields in this wsprdaemon.noise table are in their order in the csv file
        ###     and that order comes from the noise lines uploaded by the clients
        clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="
CREATE TABLE ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE}
(
    time       DateTime                     CODEC(Delta(4), ZSTD(1)),
    site       LowCardinality(String),
    receiver   LowCardinality(String),
    rx_loc     LowCardinality(String),
    band       LowCardinality(String),
    rms_level  Float32                      CODEC(ZSTD(1)),
    c2_level   Float32                      CODEC(ZSTD(1)),
    ov         Nullable(Int32),
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(time)
ORDER BY (time, site, receiver)
SETTINGS index_granularity = 8192;
"
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: clickhouse ... CREATE ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE} => ${rc}"
            echo ${force_abort}
        else
            wd_logger 1 "Created ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE}"
        fi
    fi
    wd_logger 1 "Database setup is complete"
    return ${rc}
}

### This daemon runs on wd{1,2}.wsprdaemon.org and processes tbz files which have been rsync'd to it by wd[0,00}.wsprdaemon.org
### It optionally queues a copy of each tgz for FTP transfer to WD1
function tbz_service_daemon() 
{
    local tbz_service_daemon_root_dir=$1  ### The tbz files are found in permanent storage under ~/wsprdaemon/uploads.d/..., but this daemon does all its work in a /tmp/wsprdaemon/... directory
    local rc

    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    wd_logger 1 "Starting in $PWD.  Searching ${INCOMING_TBZS_DIR_ROOT_PATH} for new tbz files. Untaring them in ${UPLOADS_TMP_ROOT_DIR}"

    if [[ ${HOSTNAME} =~ WD0 ]]; then
        wd_logger 1 "Don't set up Clickhouse on ${HOSTNAME}"
    else
        wd_logger 1 "Set up Clickhouse on ${HOSTNAME}"
        setup_clickhouse_wsprdaemon_tables
        rc=$? ; if (( rc )); then
            wd_logger 1 "'setup_clickhouse_wsprdaemon_tables' => ${rc}"
            echo ${force_abort}
        fi
    fi

    while true; do
        wd_logger 1 "Looking for *.tbz files in ${INCOMING_TBZS_DIR_ROOT_PATH}"
        local tbz_file_list=()
        while tbz_file_list=( $( find ${INCOMING_TBZS_DIR_ROOT_PATH} -maxdepth 1 -type f -name '*.tbz' ) ) && [[ ${#tbz_file_list[@]} -eq 0 ]]; do
            wd_logger 2 "Found no tbz files in '${INCOMING_TBZS_DIR_ROOT_PATH}', so sleep and try again"
            sleep 2
        done
        wd_logger 1 "Found ${#tbz_file_list[@]} tbz files in '${INCOMING_TBZS_DIR_ROOT_PATH}'"

       [[ -d ${UPLOADS_TMP_ROOT_DIR} ]] && rm -rf ${UPLOADS_TMP_ROOT_DIR}
        mkdir -p ${UPLOADS_TMP_ROOT_DIR}
 
        local valid_tbz_list=()
        local tbz_file
        for tbz_file in ${tbz_file_list[@]} ; do
            local tbz_file_base_name="${tbz_file##*/}"
            [[ ! -f ${TBZ_PROCESSED_ARCHIVE_FILE} ]] && touch ${TBZ_PROCESSED_ARCHIVE_FILE}
            if grep -q ${tbz_file_base_name} ${TBZ_PROCESSED_ARCHIVE_FILE} ; then
                wd_logger 1 "Flushing tar file '${tbz_file}' which has been previously processed"
                wd_rm ${tbz_file}
            else
                wd_logger 2 "Extracting spot and noise files to '${UPLOADS_TMP_ROOT_DIR}' by running 'tar xf ${tbz_file} -C ${UPLOADS_TMP_ROOT_DIR}'"
                tar xf ${tbz_file} -C ${UPLOADS_TMP_ROOT_DIR} &> /dev/null
                rc=$? ; if (( rc )); then
                    wd_logger 1 "ERROR: 'tar xf ${tbz_file} -C ${UPLOADS_TMP_ROOT_DIR}' => ${rc}, so just flush it"
                    wd_rm  ${tbz_file}
                else
                    wd_logger 2 "Extracted spot and noise files from '${tbz_file}'"
                    echo "${tbz_file_base_name}" >> ${TBZ_PROCESSED_ARCHIVE_FILE}
                    valid_tbz_list+=( ${tbz_file} )
                fi
            fi
            local file_system_usage=$(df ${UPLOADS_TMP_ROOT_DIR} | awk '/^tmpfs/{print $3}')
            if (( file_system_usage >  TBZ_SPOTS_TMP_FILE_SYSTEM_MAX_USAGE )); then
                wd_logger 1 "The ${UPLOADS_TMP_ROOT_DIR} file system has been filled after extracting from ${#valid_tbz_list[@]} tbz files, so proceed to processing the spot and noise files which were extracted"
                break
            fi
        done
        truncate_file ${TBZ_PROCESSED_ARCHIVE_FILE} ${MAX_SIZE_TBZ_PROCESSED_ARCHIVE_FILE}
        wd_logger 1 "We have created a list of ${#valid_tbz_list[@]} .tbz files and extracted their contents into ${UPLOADS_TMP_ROOT_DIR}"

        record_wsprdaemon_spot_files       ${UPLOADS_TMP_ROOT_DIR}
        record_wsprdaemon_noise_files      ${UPLOADS_TMP_ROOT_DIR}

        ### On WD1 and WD2 we just delete the tbz files once they are recorded to the Clickhouse database
        wd_rm  ${valid_tbz_list[@]}
        
        wd_logger 1 "Done processing a batch of  ${#valid_tbz_list[@]} .tbz files"
        sleep 2
    done
}

function tbz_service_daemon_status()
{
    get_status_of_daemon tbz_service_daemon ${TBZ_SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 2 "The tbz_service_daemon is running in '${TBZ_SERVER_ROOT_DIR}'"
    else
        wd_logger 2 "The tbz_service_daemon is not running in '${TBZ_SERVER_ROOT_DIR}'"
    fi
}

function tbz_service_daemon_stop()
{
    kill_daemon tbz_service_daemon ${TBZ_SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "Killed the tbz_service_daemon running in '${TBZ_SERVER_ROOT_DIR}'"
    else
        wd_logger 1 "Failed to kill the tbz_service_daemon in '${TBZ_SERVER_ROOT_DIR}'"
    fi
}

### Given the file path to the root of a directory tree populated with spot files uploaded by WD clients,
### flush all the zero sized spot files which clients genrate when no spots were found in a band+cycle
function flush_empty_spot_files()
{
    local spot_flles_root_path=$1
    local ret_code

    local spot_file_list=()
    while [[ -d ${spot_flles_root_path} ]] && spot_file_list=( $(find ${spot_flles_root_path} -name '*_spots.txt' -size 0 ) ) && [[ ${#spot_file_list[@]} -gt 0 ]]; do     ### Remove in batches of 10000 files.
        wd_logger 1 "Flushing ${#spot_file_list[@]} empty spot files"
        if [[ ${#spot_file_list[@]} -gt ${MAX_RM_ARGS} ]]; then
            wd_logger 1 "${#spot_file_list[@]} empty spot files are too many to 'rm ..' in one call, so 'rm' the first ${MAX_RM_ARGS} spot files"
            spot_file_list=(${spot_file_list[@]:0:${MAX_RM_ARGS}})
        fi
        wd_rm ${spot_file_list[@]}
        ret_code=$? ; if (( ret_code )); then
            wd_logger 1 "ERROR: while flushing zero length files, 'rm ...' => ${ret_code}"
        fi
    done
}

### Give the file path to the root of a directory tree populated with spot files uploaded by WD clients,
### format a single CSV file with those spot files and call the python program which recrods those lines in the Clickhouse (CH) database
#
declare SPOTS_CSV_FILE_PATH="${UPLOADS_TMP_ROOT_DIR}/ts_spots.csv"    ### Take spots in wsprdaemon extended spot lines and format them into this file which can be recorded to CH
function record_wsprdaemon_spot_files()
{
    local spot_flles_root_path=$1
    local ret_code

    wd_logger 2 "Flushing empty spot files found under ${spot_flles_root_path}"
    flush_empty_spot_files ${spot_flles_root_path}

    ### Process non-empty spot files
    local spot_file_list=()
    while [[ -d ${spot_flles_root_path} ]] && spot_file_list=( $(find ${spot_flles_root_path} -name '*_spots.txt')  ) && (( ${#spot_file_list[@]} > 0 )); do
        wd_logger 1 "Found ${#spot_file_list[@]} spot files"
        if (( ${#spot_file_list[@]} > MAX_RM_ARGS )); then
            wd_logger 1 "${#spot_file_list[@]} spot files are too many to process in one pass, so processing the first ${MAX_RM_ARGS} spot files"
            spot_file_list=(${spot_file_list[@]:0:${MAX_RM_ARGS}})
        fi
        format_spot_lines ${SPOTS_CSV_FILE_PATH} ${spot_file_list[@]}
        local spot_lines_count=$( wc -l <  ${SPOTS_CSV_FILE_PATH} )
        if (( spot_lines_count == 0 )); then
            wd_logger 1 "Found zero valid spot lines in the ${#spot_file_list[@]} spot files"
        else
            wd_logger 2 "Found ${spot_lines_count} spots in the ${#spot_file_list[@]} spot files"
            declare TS_MAX_INPUT_LINES=${PYTHON_MAX_INPUT_LINES-5000}
            declare SPLIT_CSV_PREFIX="${UPLOADS_TMP_ROOT_DIR}/split_spots_"
            rm -f ${SPLIT_CSV_PREFIX}*
            split --lines=${TS_MAX_INPUT_LINES} --numeric-suffixes --additional-suffix=.csv ${SPOTS_CSV_FILE_PATH} ${SPLIT_CSV_PREFIX}
            ret_code=$? ; if (( ret_code )); then
                wd_logger 1 "ERROR: couldn't split ${SPOTS_CSV_FILE_PATH}.  'split --lines=${TS_MAX_INPUT_LINES} --numeric-suffixes --additional-suffix=.csv ${SPOTS_CSV_FILE_PATH} ${SPLIT_CSV_PREFIX}' => ${ret_code}"
                echo ${force_abort}
            fi
            local split_file_list=( ${SPLIT_CSV_PREFIX}* )
            wd_logger 2 "Split ${SPOTS_CSV_FILE_PATH} into ${#split_file_list[@]} splitXXX.csv files"
            local split_csv_file
            for split_csv_file in ${split_file_list[@]} ; do
                wd_logger 1 "Recording spots assembled in $(realpath ${split_csv_file})"
                # Use admin user for INSERT operations
                clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="INSERT INTO ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE} FORMAT CSV" < ${split_csv_file}
                ret_code=$? ; if (( ret_code )); then
                    wd_logger 1 "ERROR: 'clickhouse-client ... --query='INSERT INTO ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE} FORMAT CSV' => ${ret_code} when recording the $( wc -l < ${split_csv_file} ) spots in ${split_csv_file} to the wsprdaemon.spots table"
                else
                    wd_logger 2 "Recorded $( wc -l < ${split_csv_file} ) spots in ${split_csv_file} to the ${CLICKHOUSE_WSPRDAEMON_SPOTS_TABLE} table from ${#spot_file_list[*]} spot files which were extracted from ${#split_file_list[*]} tar files, so flush ${split_csv_file}"
                fi
            done
            wd_logger 2 "Finished recording the ${#split_file_list[@]} splitXXX.csv files"
        fi
        wd_logger 2 "Finished recording ${SPOTS_CSV_FILE_PATH}, so flushing it and all the ${#spot_file_list[@]} spot files which created it"
        wd_rm ${spot_file_list[@]}
        ret_code=$? ; if (( ret_code )); then
            wd_logger 1 "ERROR: while flushing ${SPOTS_CSV_FILE_PATH} and the ${#spot_file_list[*]} non-zero length spot files already recorded to TS, 'rm ...' => ${ret_code}"
        fi
    done
    wd_logger 2 "Done"
}

###  Format of the extended spot line delivered by WD clients:
###   spot_date spot_time spot_sync_quality spot_snr spot_dt spot_freq spot_call spot_grid spot_pwr spot_drift spot_decode_cycles spot_jitter spot_blocksize spot_metric spot_osd_decode spot_ipass spot_nhardmin \
###                                                                       spot_rms_noise spot_c2_noise spot_for_wsprnet band \
###                                                                                        my_grid my_call_sign km rx_az rx_lat rx_lon tx_az tx_lat tx_lon v_lat v_lon (WD 3.x: wspr_packet_mode) (appended by awk: site_receiver_name)
###  Those lines are converted into a .csv file which will be recorded in TS and CH by this awk program:
###  awk 'NF == 32' ${spot_file_list[@]:0:20000}  => filters out corrupt spot lines.  Only lines with 32 fields are fed to TS.  The bash cmd line can process no more than about 23,500 arguments, so pass at most 20,000 txt file names to awk.  If there are more, they will get processed in the next loop iteration
###          
###  sed -r 's/\S+\s+//18; s/ /,/g; s/,/:/; s/./&"/11; s/./&:/9; s/./&-/4; s/./&-/2; s/^/"20/;'"s/\"/'/g"
###          s/\S+\s+//18;  => deletes the 18th field, the 'proxy upload this spot to wsprnet.org'
###                        s/ /,/g; => replace all spaces with ','s
###                                   s/,/:/; => change the first two fields from DATE,TIME to DATE:TIME
###                                          s/./&"/11; => add '"' to get DATE:TIME"
###                                                      s/./&:/9; => insert ':' to get YYMMDD:HH:MM"
###                                                                s/./&-/4; s/./&-/2;   => insert ':' to get YY-MM-DD:HH:MM"
###                                                                                   s/^/"20/;  => insert '"20' to get "20YY-MM-DD:HH:MM"
###                                                                                             s/",0\./",/; => WSJT-x V2.2+ outputs a floating point sync value.  this chops off the leading '0.' to make it a decimal number for TS 
###                                                                                                          "s/\"/'/g" => replace those two '"'s with ''' to get '20YY-MM-DD:HH:MM'.  Since this expression includes a ', it has to be within "s

declare WSPRDAEMON_SPOTS_TO_CLICKHOUSE_AWK_PROGRAM=${WSPRDAEMON_ROOT_DIR}/wsprdaemon-spots-to-clickhouse-csv.awk
function format_spot_lines()
{
    local spots_csv_file_path=$1
    local spot_files_list=( ${@:2} )

    if [[ ! -f ${WSPRDAEMON_SPOTS_TO_CLICKHOUSE_AWK_PROGRAM} ]]; then
        wd_logger 1 "ERROR: can't find awk program file '${WSPRDAEMON_SPOTS_TO_CLICKHOUSE_AWK_PROGRAM}'"
        echo ${force_abort}
    fi
    if (( ${#spot_files_list[@]} == 0 )); then
        wd_logger 1 "ERROR: no spot files were passed"
        echo ${force_abort}
    fi
    cat  ${spot_file_list[@]} > ${spots_csv_file_path}.raw     ### DIAGS_CODE
    local temp_spot_lines_file_path="${spots_csv_file_path}.tmp"
    awk -f ${WSPRDAEMON_SPOTS_TO_CLICKHOUSE_AWK_PROGRAM} ${spot_file_list[@]} > ${temp_spot_lines_file_path}
    ret_code=$? ; if (( ret_code )); then
        wd_logger 1 "ERROR: 'awk -f ${WSPRDAEMON_SPOTS_TO_CLICKHOUSE_AWK_PROGRAM} ...' => ${ret_code}"
        return 1
    fi
    grep -v "ERROR" ${temp_spot_lines_file_path} > ${spots_csv_file_path}
    if [[ ! -s  ${spots_csv_file_path} ]]; then
        wd_logger 1 "Found no spot lines in ${temp_spot_lines_file_path}"
    fi
    local error_lines_file_path="${spots_csv_file_path}.errors"
    grep "ERROR" ${temp_spot_lines_file_path} > ${error_lines_file_path} 
    if [[ -s ${error_lines_file_path} ]] ; then
        wd_logger 1 "ERROR: stored $( wd -l < ${error_lines_file_path}) invalid spots in ${error_lines_file_path}:\n$(< ${error_lines_file_path})"
    fi

    wd_logger 1 "Formatted $(wc -l <  ${spots_csv_file_path}) WD spots into ${spots_csv_file_path} (here are the first four lines):\n$(head -n 4 ${spots_csv_file_path})"
    return 0
}

function record_wsprdaemon_noise_files()
{
    ### Record the noise files
    local noise_csv_file=${UPLOADS_TMP_ROOT_DIR}/ts_noise.csv
    local noise_file_list=()
    local max_noise_files=${MAX_RM_ARGS}
    local ret_code

    local noise_search_root_dir_path=" ${UPLOADS_TMP_ROOT_DIR}"   ### new commit WD clients will have stored noise files in '.../wsprdaemon/noise/..' while clients running older commits will have stored them in '.../wsprdaemon.d/noise.d/.."
    while [[ -d ${UPLOADS_TMP_ROOT_DIR} ]] \
           && noise_file_list=( $(find ${noise_search_root_dir_path}/ -name '*_noise.txt') ) \
           && (( ${#noise_file_list[@]} )); do
        if (( ${#noise_file_list[@]} > max_noise_files )); then
            wd_logger 1 "${#noise_file_list[@]} noise files are too many to process in one pass, so process the first ${max_noise_files} noise files"
            noise_file_list=( ${noise_file_list[@]:0:${max_noise_files}} )
        else
            wd_logger 1 "Found ${#noise_file_list[@]} noise files to be processed"
        fi
        awk -f ${TS_NOISE_AWK_SCRIPT} ${noise_file_list[@]} > ${noise_csv_file}
        ret_code=$? ; if (( ret_code )); then
            wd_logger 1 "ERROR: 'awk -f ${TS_NOISE_AWK_SCRIPT} .. of ${#noise_file_list[@]} noise files' => ${ret_code}, so just dump those noise files"
        else
            # Use admin user for INSERT operations
            clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query="INSERT INTO ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE} FORMAT CSV" < ${noise_csv_file}
            ret_code=$? ; if (( ret_code )); then
                wd_logger 1 "ERROR: ' clickhouse-client -u ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} --password ${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD} --host ${CLICKHOUSE_HOST:-localhost} --query='INSERT INTO ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE} FORMAT CSV' < ${noise_csv_file}' => ${ret_code}"
                echo ${force_abort}
            else
                wd_logger 1 "Recorded $( wc -l < ${noise_csv_file} ) noise lines in ${noise_csv_file} to the ${CLICKHOUSE_WSPRDAEMON_NOISE_TABLE} table from ${#noise_file_list[*]} noise files so flush all those noise files"
            fi
        fi
        wd_rm ${noise_file_list[@]}
        ret_code=$? ; if (( ret_code )); then
            wd_logger 1 "ERROR: while flushing noise files already recorded to wsprdaemon_spots table. 'wd_rm ${spot_file_list[@]}' => ${ret_code}"
        fi
    done
    wd_logger 1 "Processed all the noise files"
}


################################## Mirror Service Section #########################################################################################
### This daemon runs on WD (logs.wsprdaemon.org), the cloud server where all WD clients deliver their tgz files

declare MIRROR_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}/mirror   ### Where tgz files are put to be uploaded
### ID,URL[:port],FTP_USER,FTP_USER_PASSWORD              ### This is the primary target of client uploads. Mirror at WD spot/noise files to WD1
if [[ ${MIRROR_DESTINATIONS_LIST[0]-x} == "x" ]] ; then
    ### This array was not declared in the conf file, so declare it here
    declare -a MIRROR_DESTINATIONS_LIST=()
fi
declare UPLOAD_TO_MIRROR_SERVER_SECS=10     ### How often to attempt to upload tar files to log1.wsprdaemon.org
declare UPLOAD_MAX_FILE_COUNT=1000          ### curl will upload only a ?? number of files, so limit the number of files given to curl

function get_upload_spec_from_id()
{
    local _return_url_spec_variable=$1
    local target_spec_id=$2
    local mirror_spec
    
    for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]}; do
        local mirror_spec_list=( ${mirror_spec//,/ } )
        if [[ "${mirror_spec_list[0]}" == "${target_spec_id}" ]]; then
            wd_logger 1 "Found target_spec_id=${target_spec_id} in '${mirror_spec}"
            eval ${_return_url_spec_variable}="${mirror_spec}"
            return 0
        fi
    done
    wd_logger 1 "ERROR:  couldn't find target_spec_id=${target_spec_id} in MIRROR_DESTINATIONS_LIST[]"
    return 1
}

### One instance of this daemon is spawned for each mirror target defined in MIRROR_DESTINATIONS_LIST
### This daemon polls for files under its mirror source directory
function upload_to_mirror_site_daemon() {
    local my_pwd=$1            ### spawn_daemon passes us the directory we are to run in
    mkdir -p ${my_pwd}
    cd ${my_pwd}
      
    local my_upload_id=${my_pwd##*/}    ### Get the upload_id from the path to this daemon's home dir
    local url_spec
    get_upload_spec_from_id   url_spec ${my_upload_id}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: passed my home path '${my_upload_id}' which specifies an upload_id '${my_upload_id}' which can't be found in \$MIRROR_DESTINATIONS_LIST[]"
        exit ${ret_code}
    fi
     wd_logger 1 "Got url_spec=${url_spec}' for my_upload_id=${my_upload_id}"

    local url_spec_list=( ${url_spec//,/ } )
    local url_id=${url_spec_list[0]}
    local url_addr=${url_spec_list[1]}
    local url_login_name=${url_spec_list[2]}
    local url_login_password=${url_spec_list[3]}
    local upload_to_mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${url_id}   ### Where to find tbz files
    local upload_to_mirror_daemon_queue_dir=${upload_to_mirror_daemon_root_dir}/queue.d

    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    mkdir -p ${upload_to_mirror_daemon_queue_dir}
    wd_logger 1 "Looking for files in ${upload_to_mirror_daemon_queue_dir}"
    while true; do
        local files_queued_for_upload_list=( $(find ${upload_to_mirror_daemon_queue_dir} -type f) )
        if [[ ${#files_queued_for_upload_list[@]} -eq 0 ]]; then
            wd_logger 1 "Found no files to upload to url_addr=${url_addr}, url_login_name=${url_login_name}, url_login_password=${url_login_password}"
        else
            wd_logger 1 "Found ${#files_queued_for_upload_list[@]} files to upload to url_addr=${url_addr}, url_login_name=${url_login_name}, url_login_password=${url_login_password}"

            local curl_upload_file_list=(${files_queued_for_upload_list[@]::${UPLOAD_MAX_FILE_COUNT}})  ### curl limits the number of files to upload, so curl only the first UPLOAD_MAX_FILE_COUNT files 

            local curl_upload_file_string=${curl_upload_file_list[@]}
            curl_upload_file_string=${curl_upload_file_string// /,}     ### curl wants a comma-separated list of files

            wd_logger 2 "Starting curl of ${#curl_upload_file_list[@]} files using: 'curl -sS -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${url_login_name}:${url_login_password} ftp://${url_addr}/'"
            ### curl -sS == don't print progress, but print errors
            curl -sS --limit-rate ${UPLOAD_TO_MIRROR_SERVER_MAX_BYTES_PER_SECOND-20000} -m ${UPLOAD_TO_MIRROR_SERVER_SECS} -T "{${curl_upload_file_string}}" --user ${url_login_name}:${url_login_password} ftp://${url_addr}/ > curl.log 2>&1 
            local ret_code=$?
            local curl_output=$(< curl.log)
            if [[ ${ret_code} -ne 0 ]]; then
                wd_logger 1 "Curl xfer failed: '${curl_output} ...'  => ${ret_code}, so leave files alone and try again"
            else
                wd_logger 1 "Curl xfer was successful, so delete the ${#curl_upload_file_list[@]} local files"
                wd_rm ${curl_upload_file_list[@]}
                local ret_code=$?
                if [[ ${ret_code} -ne 0 ]]; then
                    wd_logger 1 "ERROR: 'wd_rm ${curl_upload_file_list[*]}' => ${ret_code}, but there is nothing we can do to recover"
                fi
            fi
        fi
        wd_logger 2 "Sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        wd_sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function kill_upload_to_mirror_site_daemons()
{
    wd_logger 2 "Start"

    if [[ ${#MIRROR_DESTINATIONS_LIST[@]} -eq 0 ]]; then
        wd_logger 2 "There are no mirror destinations declared in \${MIRROR_DESTINATIONS_LIST[@]}, so there are no mirror daemons running"
        return 0
    fi
 
    local mirror_spec
    for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
        local mirror_spec_list=(${mirror_spec[@]//,/ })
        local mirror_daemon_id=${mirror_spec_list[0]}
        local mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${mirror_daemon_id}

        wd_logger 2 "Killing mirror daemon with: 'kill_daemon upload_to_mirror_site_daemon ${mirror_daemon_root_dir}'"
        kill_daemon  upload_to_mirror_site_daemon ${mirror_daemon_root_dir}
        local ret_code=$?
        ### Normally upload_to_mirror_site_daemon() will print out its actions, so there is no reason to print out its return code
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 1 "Killed a upload_to_mirror_site_daemon running in '${mirror_daemon_root_dir}'"
        else
            wd_logger 1 "The 'upload_to_mirror_site_daemon' was not running in '${mirror_daemon_root_dir}'"
        fi
    done
    wd_logger 2 "Done"
}

function mirror_daemon_kill_handler()
{
    wd_logger 1 "Got SIGTERM"
    kill_upload_to_mirror_site_daemons
    wd_logger 1 "Done killing"
    exit 0
}

function mirror_watchdog_daemon() {
    setup_verbosity_traps
    ## trap mirror_daemon_kill_handler SIGTERM

    while true; do
        local mirror_spec
        for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
            local mirror_spec_list=(${mirror_spec[@]//,/ })
            local mirror_daemon_id=${mirror_spec_list[0]}
            local mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${mirror_daemon_id}
            
            wd_logger 2 "Spawning mirror daemon for '${mirror_spec}'"
            mkdir -p ${mirror_daemon_root_dir}
            spawn_daemon  upload_to_mirror_site_daemon ${mirror_daemon_root_dir} 
            wd_logger 2 "Spawned upload_to_mirror_site_daemon with pid = $( < ${mirror_daemon_root_dir}/upload_to_mirror_site_daemon.pid)"
        done
        wd_logger 1 "Sleeping for ${UPLOAD_TO_MIRROR_SERVER_SECS} seconds"
        wd_sleep ${UPLOAD_TO_MIRROR_SERVER_SECS}
    done
}

function kill_mirror_watchdog_daemon()
{
    local mirror_watchdog_daemon_home_dir=$1
    wd_logger 2 "Killing mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}" 
    kill_daemon    mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "Killed the mirror_watchdog_daemon running in '${mirror_watchdog_daemon_home_dir}'"
    else
        wd_logger 1 "The 'mirror_watchdog_daemon' was not running in '${mirror_watchdog_daemon_home_dir}'"
    fi

    ### If the mirror_watchdog_daemon() is running, then its SIG_TERM handler will have killed the individual mirror_daemons.
    ### But in the unlikely case that mirror_watchdog_daemon isn't running, make sure they are killed
    wd_logger 2 "Killing kill_upload_to_mirror_site_daemons ${mirror_watchdog_daemon_home_dir}"
    kill_upload_to_mirror_site_daemons ${mirror_watchdog_daemon_home_dir}
}

function get_status_mirror_watchdog_daemon()
{
    local mirror_watchdog_daemon_home_dir=$1
    
    wd_logger 2 "Get status for 'mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}'"
    get_status_of_daemon    mirror_watchdog_daemon ${mirror_watchdog_daemon_home_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "The mirror_watchdog_daemon is running in '${mirror_watchdog_daemon_home_dir}'"
    else
        wd_logger 1 "The mirror_watchdog_daemon is not running in '${mirror_watchdog_daemon_home_dir}'"
    fi

    if [[ ${#MIRROR_DESTINATIONS_LIST[@]} -eq 0 ]]; then
        wd_logger 2 "There are no mirror destinations declared in \${MIRROR_DESTINATIONS_LIST[@]}, so there are no mirror daemons running"
        return 0
    fi
    local mirror_spec
    for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
        local mirror_spec_list=(${mirror_spec[@]//,/ })
        local mirror_daemon_id=${mirror_spec_list[0]}
        local mirror_daemon_root_dir=${MIRROR_ROOT_DIR}/${mirror_daemon_id}

        wd_logger 2 "Get status for '${mirror_spec}'"
        get_status_of_daemon  upload_to_mirror_site_daemon ${mirror_daemon_root_dir}
        local ret_code=$?
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 1 "The upload_to_mirror_site_daemon to site '${mirror_daemon_id}' is running in ${mirror_daemon_root_dir}"
        else
            wd_logger 1 "The upload_to_mirror_site_daemon to site '${mirror_daemon_id}' is not running in ${mirror_daemon_root_dir}"
        fi
    done
}

function queue_files_for_mirroring()
{
    local files="$@"
    local files_path_list=(${files})

    if [[ ${#MIRROR_DESTINATIONS_LIST[@]} -eq 0 ]]; then
        wd_logger 2 "There are no mirror destinations declared in \${MIRROR_DESTINATIONS_LIST[@]}, so don't queue the ${#files_path_list[@]} we were passed"
    else
        local mirror_spec
        for mirror_spec in ${MIRROR_DESTINATIONS_LIST[@]} ; do
            local mirror_spec_list=(${mirror_spec[@]//,/ })
            local mirror_id=${mirror_spec_list[0]}
            local mirror_root_dir=${MIRROR_ROOT_DIR}/${mirror_id}
            local mirror_queue_dir=${mirror_root_dir}/queue.d

            mkdir -p ${mirror_queue_dir}
            wd_logger 1 "Queuing ${#files_path_list[@]} files to ${mirror_queue_dir}: '${files_path_list[*]::5}...'"
            local src_file_path
            for src_file_path in ${files_path_list[@]}; do
                local src_file_name=${src_file_path##*/}
                local dst_file_path=${mirror_queue_dir}/${src_file_name}
                if [[ -f ${dst_file_path} ]]; then
                    wd_logger 1 "WARNING: source file '${src_file_path}' already exists in '${mirror_queue_dir}', so skipping"
                else
                    ln ${src_file_path} ${dst_file_path}
                    local ret_code=$?
                    if [[ ${ret_code} -ne 0 ]]; then
                        wd_logger 1 "ERROR: 'ln ${src_file_path} ${dst_file_path}' => ${ret_code}"
                    else
                        wd_logger 2 "Queued ${src_file_name} using 'ln ${src_file_path} ${dst_file_path}'"
                    fi
                fi
            done
            wd_logger 1 "Done queuing to mirror '${mirror_spec}'"
        done
        wd_logger 1 "Done queuing to mirror targets: '${MIRROR_DESTINATIONS_LIST[*]}'"
    fi
    wd_logger 2 "Done with all mirroring"
}

######################## Upload services spawned by the upload watchdog server ######################
function get_status_upload_service() 
{
    local daemon_function_name=$1

    local daemon_status_function_name=""
    local daemon_home_dir
    local entry_info
    for entry_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local entry_info_list=( ${entry_info} )
        local entry_function_name=${entry_info_list[0]}
        local entry_status_function_name=${entry_info_list[2]-get_status_of_daemon}
        local entry_home_dir=${entry_info_list[3]}

        if [[ ${daemon_function_name} == ${entry_function_name} ]]; then
            daemon_status_function_name=${entry_status_function_name}
            daemon_home_dir=${entry_home_dir}
            break
        fi
    done
    if [[ -z "${daemon_status_function_name}" ]]; then
        wd_logger 1 "ERROR:  can't find daemon_function_name='${daemon_function_name}' in '\${UPLOAD_DAEMON_LIST[@]}'"
        return 1
    fi

    wd_logger 1 "Get status of: '${daemon_function_name}' with home dir '${daemon_home_dir}' by executing '${daemon_status_function_name}'"
    ${daemon_status_function_name} ${daemon_home_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 2 "${daemon_status_function_name}() '${daemon_home_dir}' => OK"
    else
        wd_logger 1 "${daemon_status_function_name}() '${daemon_home_dir}' => ${ret_code}"
    fi
}

function get_status_upload_watchdog_services()
{
    local daemon_status_function_name=""
    local daemon_home_dir
    local entry_info
    for entry_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local entry_info_list=( ${entry_info} )
        local entry_function_name=${entry_info_list[0]}
        get_status_upload_service ${entry_function_name}
    done
    return 0
}

################################## Upload Server Top Level Daemon Watchdog Section #########################################################################################
declare -r UPLOAD_SERVERS_POLL_RATE=10       ### Seconds for the daemons to wait between polling for files

function upload_services_watchdog_daemon() 
{
    local ret_code=$?
    setup_verbosity_traps          ### So we can increment and decrement verbosity without restarting WD

    wd_logger 1 "Starting"
    while true; do
        wd_logger 1 "Starting to check all daemons"
        local daemon_info
        for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
            local daemon_info_list=( ${daemon_info} )
            local daemon_function_name=${daemon_info_list[0]}
            local daemon_home_dir=${daemon_info_list[3]}
            
            wd_logger 1 "Check, and if needed, spawn: '${daemon_function_name} ${daemon_home_dir}'"
            spawn_daemon ${daemon_function_name} ${daemon_home_dir}
            ret_code=$?; if (( ret_code )); then
                wd_logger 1 "ERROR: '${daemon_function_name} ${daemon_home_dir}' => ${ret_code}"
            else
                wd_logger 1 "Spawned '${daemon_function_name} ${daemon_home_dir}'"
            fi
        done
        wd_sleep 600 # ${UPLOAD_SERVERS_POLL_RATE}
    done
}

### Called by 'wd -u a'
function spawn_upload_services_watchdog_daemon() 
{
    wd_logger 1 "Start"
    spawn_daemon            upload_services_watchdog_daemon ${SERVER_ROOT_DIR}
    wd_logger 1 "Done"
}

function kill_upload_services_watchdog_daemon()
{
    wd_logger 2 "Kill the upload_services_watchdog_daemon by executing: 'kill_daemon upload_services_watchdog_daemon ${SERVER_ROOT_DIR}'"
    ### Kill the watchdog
    kill_daemon  upload_services_watchdog_daemon ${SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "Killed the daemon 'upload_services_watchdog_daemon' running in '${SERVER_ROOT_DIR}'"
    else
        wd_logger 1 "The 'upload_services_watchdog_daemon' was not running in '${SERVER_ROOT_DIR}'"
    fi

    ### Kill the services it spawned
    for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local daemon_info_list=( ${daemon_info} )
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_kill_function_name=${daemon_info_list[1]}
        local daemon_home_dir=${daemon_info_list[3]}

        wd_logger 2 "Kill the '${daemon_function_name} by executing: '${daemon_kill_function_name} ${daemon_home_dir}'"
        ${daemon_kill_function_name} ${daemon_home_dir}
        local ret_code=$?
        ### Normally the kill function will print out its actions, so don't print here
        if [[ ${ret_code} -eq 0 ]]; then
            wd_logger 2 "'${daemon_kill_function_name} ${daemon_home_dir}' reports success"
        else
            wd_logger 2 "ERROR: '${daemon_kill_function_name} ${daemon_home_dir}' returned ${ret_code}"
        fi
    done
    wd_logger 2 "Done"
}

### Watchdog daemons which spawn service daemons have their own status report functions
function get_status_upload_services()
{
    wd_logger 2 "Get the status of the topmost daemon 'upload_services_watchdog_daemon' by executing: 'get_status_of_daemon   upload_services_watchdog_daemon ${SERVER_ROOT_DIR}'"
    get_status_of_daemon   upload_services_watchdog_daemon ${SERVER_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 2 "The upload_services_watchdog_daemon is running in '${SERVER_ROOT_DIR}'"
    else
        wd_logger 2 "The upload_services_watchdog_daemon is not running in '${SERVER_ROOT_DIR}'"
    fi

    for daemon_info in "${UPLOAD_DAEMON_LIST[@]}"; do
        local daemon_info_list=( ${daemon_info} )
        local daemon_function_name=${daemon_info_list[0]}
        local daemon_status_function_name=${daemon_info_list[2]}
        local daemon_home_dir=${daemon_info_list[3]}

        wd_logger 2 "Getting status for '${daemon_function_name}' spawned by 'upload_services_watchdog_daemon' by calling: ${daemon_status_function_name} ${daemon_home_dir}'"
        ${daemon_status_function_name}  ${daemon_home_dir}
    done
    return 0
}

declare SERVER_ROOT_DIR=${WSPRDAEMON_ROOT_DIR}
declare SCRAPER_ROOT_DIR=${SERVER_ROOT_DIR}/scraper
declare NOISE_GRAPHS_SERVER_ROOT_DIR=${SERVER_ROOT_DIR}/noise_graphs

################# These functions run only on WD0 and WD00 ################################################
declare MIRROR_SERVER_ROOT_DIR=${SERVER_ROOT_DIR}/mirror
#declare MIRROR_SERVER_LIST=( WD1 WD2 )
declare MIRROR_SERVER_LIST=( WD2 )
##
## The relay and mirror daemons look and log to directories under ~/wsprdaemon:
## MIRROR_SERVER_ROOT_DIR= ~/wsprdaemon
#    has the pid and log file for  tbz_relay_daemon() which looks for files in /home/*/uploads/* and hard links them to 'mirror' in the directories ~/wsprdaemon/mirrors/WD{1,2,...}/
#    There is a single tbz_relay_daemon() which logs to  ~/wsprdaemon/mirrors/tbz_relay_daemon.{log,pid}
#    There is a mirror directory for each of the mirror destination servers (currently WD1 and WD2) e.g.  ~/wsprdaemon/mirrors/WD1
#    In those directories you will find the .pid and .log files for that instance of tbz_mirror_deamon as well as the .tbz files waiting to be rssync'd to the associated WD[12] server

### This daemon runs on WD0 and WD000 and polls for the extended spot and noise files sftp uploaded by clients to their /home/<CLIENT_NAME>/uploads/ directory 
### and queues those files to be rsync'd to WD! and WD2
function tbz_relay_daemon() 
{
    while true; do
        local tbz_file_path_list=( $(find /home/*/uploads/ -type f -name '*.tbz') )
        if (( ${#tbz_file_path_list[@]} == 0 )); then
            wd_logger 2 "Found no tbz files to relay, so sleep 10 before polling again"
            sleep 10
            continue
        fi
        wd_logger 2 "Found ${#tbz_file_path_list[@]} to be relayed"

        ### Create the dir outside of the inner loop
        local mirror_server
        for mirror_server in ${MIRROR_SERVER_LIST[@]} ; do
            mkdir -p ${SERVER_ROOT_DIR}/mirror/${mirror_server}
        done

        ### Avoid overflowing bash's argument count limit by hard linking batchs
        local batch_size=10000
        local total_files=${#tbz_file_path_list[@]}
        local i
        for mirror_server in ${MIRROR_SERVER_LIST[@]}; do
            local mirror_dir="${MIRROR_SERVER_ROOT_DIR}/${mirror_server}"
            wd_logger 2 "Queuing ${total_files} files to ${mirror_dir}"
            for ((i=0; i<total_files; i+= batch_size)); do
                local batch_list=( ${tbz_file_path_list[@]:i:${batch_size}} )
                wd_logger 1 "Queuing ${#batch_list[@]} .tbz files to ${mirror_dir}"
                local file
                for file in ${batch_list[@]}; do
                    sudo ln ${file} ${mirror_dir}/     ### Since we don't own the source file, we have to 'sudo ln ...'
                    local rc=$? ; if (( rc )); then
                        wd_logger 1 "ERROR: ' ln ${file} ${mirror_dir}/' => ${rc}"
                        exit 1
                    fi
                done
            done
        done
        ## Remove the queued files in batchs
        wd_logger 1 "Flushing the source files now that they have been queued"
        for ((i=0; i<total_files; i+= batch_size)); do
            sudo rm ${tbz_file_path_list[@]:i:batch_size} ### Since we don't own the source file, we have to 'sudo rm ...'
        done
    done
}

declare TBZ_RELAY_DAEMON_PID_FILE_PATH="${MIRROR_SERVER_ROOT_DIR}/tbz_relay_daemon.pid"
declare TBZ_RELAY_DAEMON_LOG_FILE_PATH="${TBZ_RELAY_DAEMON_PID_FILE_PATH/.pid/.log}"

function tbz_relay_daemon_start()
{
    wd_logger 1 "PID file is ${TBZ_RELAY_DAEMON_PID_FILE_PATH}, LOG file is ${TBZ_RELAY_DAEMON_PID_FILE_PATH}"
    local relay_pid
    if [[ -f ${TBZ_RELAY_DAEMON_PID_FILE_PATH} ]]; then
        relay_pid=$(< ${TBZ_RELAY_DAEMON_PID_FILE_PATH})
        if ps ${relay_pid} > /dev/null ; then
            wd_logger 1 "The tbz_relay_daemon() is running with pid=${relay_pid}"
            return 0
        fi
        wd_logger 1 "The ${TBZ_RELAY_DAEMON_PID_FILE_PATH} contains inactive pid ${relay_pid}, so restart that daemon"
        wd_rm ${TBZ_RELAY_DAEMON_PID_FILE_PATH}
    fi
    WD_LOGFILE="${TBZ_RELAY_DAEMON_LOG_FILE_PATH}" tbz_relay_daemon &
    rc=$? ; if (( rc )) ; then
        wd_logger 1 "Failed to spawn tbz_relay_daemon() => ${rc}"
        return 1
    fi
    relay_pid=$!
    echo ${relay_pid} > ${TBZ_RELAY_DAEMON_PID_FILE_PATH}
    wd_logger 1 "Spawned tbz_relay_daemon() which has PID=${relay_pid}"
    return 0
}

function tbz_relay_daemon_status()
{
    wd_logger 2 "PID file is ${TBZ_RELAY_DAEMON_PID_FILE_PATH}, LOG file is ${TBZ_RELAY_DAEMON_LOG_FILE_PATH}"
    if ! [[ -f ${TBZ_RELAY_DAEMON_PID_FILE_PATH} ]]; then
        wd_logger 1 "${TBZ_RELAY_DAEMON_PID_FILE_PATH} doesn't exist, so the tbz_relay_daemon() isn't running"
        return 1
    fi
    local relay_pid=$(< ${TBZ_RELAY_DAEMON_PID_FILE_PATH})
    if ! ps ${relay_pid} > /dev/null ; then
        wd_logger 1 "The ${TBZ_RELAY_DAEMON_PID_FILE_PATH} contains inactive pid ${relay_pid}, so delete that PID file"
        wd_rm ${TBZ_RELAY_DAEMON_PID_FILE_PATH}
        return 2
    fi
    wd_logger 1 "The tbz_relay_daemon() is running with pid=${relay_pid}"
    return 0
}

function tbz_relay_daemon_stop()
{
    local rc
    wd_logger 2 "PID file is ${TBZ_RELAY_DAEMON_PID_FILE_PATH}, LOG file is ${TBZ_RELAY_DAEMON_PID_FILE_PATH}"
    if ! tbz_relay_daemon_status; then
        wd_logger 1 " tbz_relay_daemon() is already dead.  So nothing to do"
        return 0
    fi
    if [[ ! -f ${TBZ_RELAY_DAEMON_PID_FILE_PATH} ]]; then
        wd_logger 1 "PID file ${TBZ_RELAY_DAEMON_PID_FILE_PATH} doesn't exist, so nothing to kill"
        return 0
    fi
    local relay_pid=$(< ${TBZ_RELAY_DAEMON_PID_FILE_PATH})
    if ! ps ${relay_pid} > /dev/null; then
        wd_logger 1 "WARNING: pid in pid file is not active"
        rm ${TBZ_RELAY_DAEMON_PID_FILE_PATH}
        return 0
    fi
    kill ${relay_pid}        ## Kills the parent
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: 'kill ${relay_pid}' => ${rc}"
        return ${rc}
    fi
    pkill -P ${relay_pid}        ## Kills processes it may have spowned
    rc=$? ; if (( rc )); then
        ### But it may have not spawned any processes, so it is likely there were none to kill
        wd_logger 2 "WARNING: 'pkill -P ${relay_pid}' => ${rc}"
        return ${rc}
    fi
 
    wd_logger 1 "Killed tbz_relay_daemon()"
    return 0
}


#############################################
### On WED0 and WD00 there is one of these daemons for each of WD1 and WD2
### It polls the dir where tbz files have been queued by the tbz_mirror_daemon(), and rsyncs those files to the 'server_name' 
function tbz_mirror_daemon() 
{
    local server_file_dir="${1}"
    local server_name="${server_file_dir##*/}"

    local dst_url="wsprdaemon@${server_name}:/var/spool/wsprdaemon/from-wd00/"
    local file_list_file_path="/tmp/rsync-file-list.txt" ##$(mktemp)

    while true; do
        local tbz_file_list=( $(find ${server_file_dir} -type f -name '*.tbz' ) )
        if (( ${#tbz_file_list[@]} == 0 )); then
            wd_logger 2 "No files are in ${server_file_dir}, so sleep 2"
            sleep 2
            continue
        fi
        wd_logger 1 "Found ${#tbz_file_list[@]} files queued in ${server_file_dir}, so rsync them to ${dst_url}"
        printf '%s\n' "${tbz_file_list[@]##*/}" > "${file_list_file_path}"
        rsync -a --remove-source-files --files-from="${file_list_file_path}" "${server_file_dir}" "${dst_url}"
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: 'rsync -a --remove-source-files --files-from='${file_list_file_path}' / '${dst_url}'' => ${rc}"
            exit
        else
            wd_logger 1 "files were transferred by 'rsync -a --remove-source-files --files-from='${file_list_file_path}' / '${dst_url}''"
        fi
    done
}

declare TBZ_RELAY_DAEMON_PID_FILE_PATH="${MIRROR_SERVER_ROOT_DIR}/tbz_relay_daemon.pid"
declare TBZ_RELAY_DAEMON_LOG_FILE_PATH="${TBZ_RELAY_DAEMON_PID_FILE_PATH/.pid/.log}"

function tbz_mirror_daemon_status()
{
    local pid_file_path="${1}"

    wd_logger 2 "Checking the status of the daemon whose PID file is ${pid_file_path}"
    if ! [[ -f ${pid_file_path} ]]; then
        wd_logger 2 "${pid_file_path} doesn't exist, so the daemon isn't running"
        return 1
    fi
    local testing_pid=$(< ${pid_file_path})
        if ! ps ${testing_pid} > /dev/null; then
        wd_logger 1 "The ${pid_file_path} contains inactive pid ${testing_pid}, so delete that PID file"
        wd_rm ${pid_file_path}
        return 2
    fi
    wd_logger 2 "The daemon() whose PID=${testing_pid} is running"
    return 0
}

function tbz_mirror_daemons_status()
{
    local dest_wd_server
    for dest_wd_server in ${MIRROR_SERVER_LIST[@]}; do
        local dest_server_file_dir="${MIRROR_SERVER_ROOT_DIR}/${dest_wd_server}"
        local dest_server_pid_file_path="${dest_server_file_dir}/tbz_mirror_daemon.pid"

        wd_logger 2 "The ${dest_wd_server} tbz_mirror_daemon() PID file is ${dest_server_pid_file_path}"
        if tbz_mirror_daemon_status ${dest_server_pid_file_path}; then
            wd_logger 1 "The ${dest_wd_server} tbz_mirror_daemon() in ${dest_server_file_dir} is running"
        else
             wd_logger 1 "The ${dest_wd_server} tbz_mirror_daemon() in ${dest_server_file_dir} is not running"
        fi
    done
    return 0
}


function tbz_mirror_daemons_start()
{
    local dest_wd_server
    for dest_wd_server in ${MIRROR_SERVER_LIST[@]}; do
        local dest_server_file_dir="${MIRROR_SERVER_ROOT_DIR}/${dest_wd_server}"
        mkdir -p ${dest_server_file_dir}
        local dest_server_pid_file_path="${dest_server_file_dir}/tbz_mirror_daemon.pid"

        wd_logger 2 "The ${dest_wd_server} tbz_mirror_daemon() PID file is ${dest_server_pid_file_path}"
        if tbz_mirror_daemon_status ${dest_server_pid_file_path}; then
            wd_logger 1 "The ${dest_wd_server} tbz_mirror_daemon() in ${dest_server_file_dir} is already running"
            continue
        fi
        local dest_server_log_file_path="${dest_server_pid_file_path/.pid/.log}"
        wd_logger 1 "Spawning a new ${dest_wd_server} tbz_mirror_daemon() which will log to ${dest_server_log_file_path}"
        WD_LOGFILE="${dest_server_log_file_path}" tbz_mirror_daemon "${dest_server_file_dir}" &
        local rc=$? ; if (( rc )) ; then
            wd_logger 1 "Failed to spawn tbz_mirror_daemon() => ${rc}"
            exit 1
        fi
        local mirror_pid=$!
        echo ${mirror_pid} > ${dest_server_pid_file_path}
        wd_logger 1 "Spawned tbz_mirror_daemon() which has PID=${mirror_pid} and saved it in ${dest_server_pid_file_path}"
    done

    return 0
}

function tbz_mirror_daemons_stop()
{
    local rc
    local dest_wd_server
    for dest_wd_server in ${MIRROR_SERVER_LIST[@]}; do
        local dest_server_file_dir="${MIRROR_SERVER_ROOT_DIR}/${dest_wd_server}"
        local dest_server_pid_file_path="${dest_server_file_dir}/tbz_mirror_daemon.pid"

        wd_logger 1 "The ${dest_wd_server} tbz_mirror_daemon() PID file is ${dest_server_pid_file_path}"
        if ! tbz_mirror_daemon_status ${dest_server_pid_file_path}; then
            wd_logger 1 "The ${dest_wd_server} tbz_mirror_daemon() in ${dest_server_file_dir} is already stopped"
            continue
        fi
        ### There is a daemon running, so kill it 
        local mirror_pid=$(< ${dest_server_pid_file_path})
        wd_logger 1 "There is a runing tbz_mirror_daemon() which has PID=${mirror_pid}, so kill it"
        kill ${mirror_pid}
        rc=$? ; if (( rc )); then
            wd_logger 1 "ERROR: for PID from ${dest_server_pid_file_path}, 'kill ${mirror_pid}' => ${rc}"
            return ${rc}
        fi
        pkill -P ${mirror_pid}
        rc=$? ; if (( rc )); then
            ### It may not have spawned and child processes, so this is not neessarily an error
            wd_logger 2 "WARNING: for PID from ${dest_server_pid_file_path}, 'pkill -P ${mirror_pid}' => ${rc}"
        fi
        wd_logger 1 "Killed tbz_mirror_daemon() for server ${dest_wd_server}"
    done
    return 0
}

if ! [[  ${HOSTNAME} =~ ^WD[0-9] ]]; then
    wd_logger 2 "This is not one of the Wsprdaemon servers, so don't setup server daemons"
else
   if [[ ${HOSTNAME} =~ ^WD0 ]]; then
        wd_logger 2 "WD0 and WD00 are Digital Ocean droplets which only are destinations for client .tbz file uploads.  They rsync those files to WD1 and WD2"
        declare  UPLOAD_DAEMON_LIST=(
            "tbz_relay_daemon_start               tbz_relay_daemon_stop                tbz_relay_daemon_status                   ${MIRROR_SERVER_ROOT_DIR} "           ### Queue tbz files uploaded to WD0/WD00
            "tbz_mirror_daemons_start             tbz_mirror_daemons_stop              tbz_mirror_daemons_status                 ${MIRROR_SERVER_ROOT_DIR} "           ### Each daemon rynds those files to a WD1/2 server
        )
    else
        wd_logger 2 "Setting up all server services on this ${HOSTNAME}"
        declare  UPLOAD_DAEMON_LIST=(
            "tbz_service_daemon              tbz_service_daemon_stop              tbz_service_daemon_status                 ${TBZ_SERVER_ROOT_DIR} "           ### Process extended_spot/noise files from WD clients
#            "wsprnet_scrape_daemon           kill_wsprnet_scrape_daemon           get_status_wsprnet_scrape_daemon              ${SCRAPER_ROOT_DIR}"               ### Scrapes wspornet.org into a local DB
#            "wsprnet_gap_daemon              kill_wsprnet_gap_daemon              get_status_wsprnet_gap_daemon                 ${SCRAPER_ROOT_DIR}"               ### Attempts to fill gaps reported by the wsprnet_scrape_daemon()
#            "mirror_watchdog_daemon          kill_mirror_watchdog_daemon          get_status_mirror_watchdog_daemon             ${MIRROR_SERVER_ROOT_DIR}"         ### Forwards those files to WD1/WD2/...
#            "noise_graphs_publishing_daemon  kill_noise_graphs_publishing_daemon  get_status_noise_graphs_publishing_daemon     ${NOISE_GRAPHS_SERVER_ROOT_DIR}"  ### Publish noise graph .png file
        )
    fi
fi

### function which handles 'wd -u ...'
function upload_server_cmd() {
    local action=$1
    
    wd_logger 1 "Process cmd '${action}'"
    case ${action} in
        a)
            spawn_upload_services_watchdog_daemon
            ;;
        z)
            kill_upload_services_watchdog_daemon
            ;;
        s)
            get_status_upload_services
            return 0         ### Ignore error codes
            ;;
       *)
            wd_logger 1 "argument action '${action}' is invalid"
            exit 1
            ;;
    esac
}
