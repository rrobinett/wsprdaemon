#!/bin/bash 

##########################################################################################################################################################
########## Section which creates and uploads the noise level graphs ######################################################################################
##########################################################################################################################################################
declare -r NOISE_PLOT_CMD=${WSPRDAEMON_ROOT_DIR}/noise_plot.py
declare    NOISE_GRAPHS_UPLOAD_ENABLED="${NOISE_GRAPHS_UPLOAD_ENABLED-no}"
declare    NOISE_GRAPHS_LOCAL_ENABLED="${NOISE_GRAPHS_LOCAL_ENABLED-no}"
declare -r NOISE_GRAPH_FILENAME=noise_graph.png
declare -r NOISE_GRAPH_TMP_FILE=${WSPRDAEMON_TMP_DIR}/wd_tmp.png
declare -r NOISE_GRAPH_LOCAL_WWW_DIR=/var/www/html
declare -r NOISE_GRAPHS_WWW_INDEX_FILE=${NOISE_GRAPH_LOCAL_WWW_DIR}/index.html
declare -r NOISE_GRAPH_FILE=${WSPRDAEMON_TMP_DIR}/${NOISE_GRAPH_FILENAME}          ## If configured, this is the png graph copied to the graphs.wsprdaemon.org site and displayed by the local Apache server
declare -r NOISE_GRAPH_WWW_FILE=${NOISE_GRAPH_LOCAL_WWW_DIR}/${NOISE_GRAPH_FILENAME}   ## If we have the Apache serivce running to locally display noise graphs, then this will be a symbolic link to ${NOISE_GRAPH_FILE}
declare -r NOISE_GRAPHS_TMP_CSV_FILE=${WSPRDAEMON_TMP_DIR}/wd_log.csv
declare -r NOISE_GRAPHS_INDEX_LINES="
<html>
<header><title>This is title</title></header>
<body>
<img src=\"${NOISE_GRAPH_FILENAME}\" alt=\"Noise Graphics\" >
</body>
</html>"
 
declare    NOISE_GRAPHS_UPLOAD_FTP_PASSWORD="${NOISE_GRAPHS_UPLOAD_FTP_PASSWORD-xahFie6g}"  ## Hopefully this never needs to change 

function setup_noise_graphs() 
{
    if [[ -n "${SIGNAL_LEVEL_LOCAL_GRAPHS-}" ]]; then
        NOISE_GRAPHS_LOCAL_ENABLED=${SIGNAL_LEVEL_LOCAL_GRAPHS}
        wd_logger 2 "Whether to display noise graphs locally has been set by SIGNAL_LEVEL_LOCAL_GRAPHS=${SIGNAL_LEVEL_LOCAL_GRAPHS} in WD.conf file"
    fi
    if [[ -n "${SIGNAL_LEVEL_UPLOAD_GRAPHS-}" ]]; then
        NOISE_GRAPHS_UPLOAD_ENABLED=${SIGNAL_LEVEL_UPLOAD_GRAPHS}
        wd_logger 2 "Whether to upload noise graphs has been set by SIGNAL_LEVEL_UPLOAD_GRAPHS=${SIGNAL_LEVEL_UPLOAD_GRAPHS} in WD.conf file"
    fi
    if [[ ${NOISE_GRAPHS_LOCAL_ENABLED-no} == "no" && ${NOISE_GRAPHS_UPLOAD_ENABLED-no} == "no" ]] ; then
        wd_logger 2 "Noise graphing is disabled, so skip installation of libraries needed for it"
        return 0
    fi

    ### Get the Python packages needed to create the graphs.png
    local package
    for package in psycopg2 matplotlib scipy ; do
        install_python_package ${package}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: failed to install Python package ${package}"
            return ${ret_code}
        fi
    done

    if [[ ${NOISE_GRAPHS_LOCAL_ENABLED-no} == "yes" ]] ; then
        ## Ensure that Apache is installed and running
        if ! install_debian_package  apache2 ; then
            wd_logger 1 "ERROR: 'install_debian_package  apache2' => $?"
            exit 1
        fi
       if ! diff ${index_tmp_file} ${NOISE_GRAPHS_WWW_INDEX_FILE} > /dev/null; then
            sudo cp -p  ${NOISE_GRAPHS_WWW_INDEX_FILE} ${NOISE_GRAPHS_WWW_INDEX_FILE}.orig
            sudo mv     ${index_tmp_file}               ${NOISE_GRAPHS_WWW_INDEX_FILE}
        fi
        if [[ ! -f ${NOISE_GRAPH_WWW_FILE} ]]; then
            ## /var/html/www/noise_grapsh.png doesn't exist. It can't be a symnlink ;=(
            touch        ${NOISE_GRAPH_FILE}
            sudo  cp -p  ${NOISE_GRAPH_FILE}  ${NOISE_GRAPH_WWW_FILE}
        fi
    fi
}

### these could be modified from these default values by declaring them in the .conf file.
declare    SIGNAL_LEVEL_PRE_TX_SEC=${SIGNAL_LEVEL_PRE_TX_SEC-.25}
declare    SIGNAL_LEVEL_PRE_TX_LEN=${SIGNAL_LEVEL_PRE_TX_LEN-.5}
declare    SIGNAL_LEVEL_TX_SEC=${SIGNAL_LEVEL_TX_SEC-1}
declare    SIGNAL_LEVEL_TX_LEN=${SIGNAL_LEVEL_TX_LEN-109}
declare    SIGNAL_LEVEL_POST_TX_SEC=${SIGNAL_LEVEL_POST_TX_LEN-113}
declare    SIGNAL_LEVEL_POST_TX_LEN=${SIGNAL_LEVEL_POST_TX_LEN-5}
declare    SIGNAL_LEVEL_LOG_FILE_NAME="signal_levels.txt"
declare    SIGNAL_LEVEL_CSV_FILE_NAME="signal_levels.csv"

function setup_signal_levels_log_file() {
    local return_signal_levels_log_file_variable_name=$1   ### Return the full path to the log file which will be added to during each wspr packet decode 
    local receiver_name=$2
    local receiver_band=$3

    if [[ ${receiver_name} =~ / ]]; then
        wd_logger 1 "Replacing all the '/' in ${receiver_name} with '='"
        receiver_name=${receiver_name//\//=}
    fi
    local signal_level_logs_dir=${WSPRDAEMON_ROOT_DIR}/signal_levels/${receiver_name}/${receiver_band}
    mkdir -p ${signal_level_logs_dir}

    local local_signal_levels_log_file=${signal_level_logs_dir}/${SIGNAL_LEVEL_LOG_FILE_NAME}
    eval ${return_signal_levels_log_file_variable_name}=${local_signal_levels_log_file}

    if [[ -f ${local_signal_levels_log_file} ]]; then
        wd_logger 2 "Signal Level log file '${local_signal_levels_log_file}' exists, so leave it alone"
        return 0
    fi
    local  pre_tx_header="Pre Tx (${SIGNAL_LEVEL_PRE_TX_SEC}-${SIGNAL_LEVEL_PRE_TX_LEN})"
    local  tx_header="Tx (${SIGNAL_LEVEL_TX_SEC}-${SIGNAL_LEVEL_TX_LEN})"
    local  post_tx_header="Post Tx (${SIGNAL_LEVEL_POST_TX_SEC}-${SIGNAL_LEVEL_POST_TX_LEN})"
    local  field_descriptions="    'Pk lev dB' 'RMS lev dB' 'RMS Pk dB' 'RMS Tr dB'    "
    local  date_str=$(date)

    printf "${date_str}: %20s %-55s %-55s %-55s FFT\n" "" "${pre_tx_header}" "${tx_header}" "${post_tx_header}"   >  ${local_signal_levels_log_file}
    printf "${date_str}: %s %s %s\n" "${field_descriptions}" "${field_descriptions}" "${field_descriptions}"      >> ${local_signal_levels_log_file}

    wd_logger 1 "Setup header line in a new Signal Level log file '${local_signal_levels_log_file}'"
    return 0
}

### This is a hack, but use the maidenhead value of the first receiver as the global locator for signal_level graphs and logging
function get_my_maidenhead() {
    local first_rx_line=(${RECEIVER_LIST[0]})
    local first_rx_maidenhead=${first_rx_line[3]}
    echo ${first_rx_maidenhead}
}

function plot_noise() {
    local my_maidenhead=$(get_my_maidenhead)
    local signal_levels_root_dir=${WSPRDAEMON_ROOT_DIR}/signal_levels
    local noise_plot_dir=${WSPRDAEMON_ROOT_DIR}/noise_plot
    mkdir -p ${noise_plot_dir}
    local noise_calibration_file=${noise_plot_dir}/noise_ca_vals.csv

    if [[ -f ${NOISE_GRAPH_FILE} ]] ; then
        local now_secs=$(date +%s)
        local graph_secs=$(date -r ${NOISE_GRAPH_FILE} +%s)
        local graph_age_secs=$(( ${now_secs} - ${graph_secs} ))

        if [[ ${graph_age_secs} -lt ${GRAPH_UPDATE_RATE-480} ]]; then
            ### The python script which creates the graph file is very CPU intensive and causes the KPH Pis to fall behind
            ### So create a new graph file only every 480 seconds (== 8 minutes), i.e. every fourth WSPR 2 minute cycle
            wd_logger 1 "Found the noise graph file is only ${graph_age_secs} seconds old, so don't update it"
            return
        fi
    fi

    if [[ ! -f ${noise_calibration_file} ]]; then
        mkdir -p ${noise_calibration_file%/*}   ### creates the directory for the file

        echo "# Cal file for use with 'wsprdaemon.sh -p'" >${noise_calibration_file}
        echo "# Values are: Nominal bandwidth, noise equiv bandwidth, RMS offset, freq offset, FFT_band, Threshold, see notes for details" >>${noise_calibration_file}
        ## read -p 'Enter nominal kiwirecorder.py bandwidth (500 or 320Hz):' nom_bw
        ## echo "Using defaults -50.4dB for RMS offset, -41.0dB for FFT offset, and +13.1dB for FFT %coefficients correction"
        ### echo "Using equivalent RMS and FFT noise bandwidths based on your nominal bandwidth"
        local nom_bw=320     ## wsprdaemon.sh always uses 320 hz BW
        if [ $nom_bw == 500 ]; then
            local enb_rms=427
            local fft_band=-12.7
        else
            local enb_rms=246
            local fft_band=-13.9
        fi
        echo $nom_bw","$enb_rms",-50.4,-41.0,"$fft_band",13.1" >> ${noise_calibration_file}
        wd_logger 1 "Found there was no '${noise_calibration_file}', so created it"
    fi
    # noise records are all 2 min apart so 30 per hour so rows = hours *30. The max number of rows we need in the csv file is (24 *30), so to speed processing only take that number of rows from the log file
    local -i rows_per_day=$((24*30))

    ### convert wsprdaemon AI6VN sox stats format files to csv for excel or Python matplotlib etc
    if [[ ! -d ${signal_levels_root_dir} ]]; then
        wd_logger 1 "'${signal_levels_root_dir}' doesn't exist"
        return 0
    fi
    local signal_levels_log_list=()
    signal_levels_log_list=( $(find ${signal_levels_root_dir} -type f -name ${SIGNAL_LEVEL_LOG_FILE_NAME} -print ) ) 
    if [[ ${#signal_levels_log_list[@]} -eq 0 ]]; then
        wd_logger 1 "Found no signal-levels.log files, so nothing to plot"
        return 0
    fi

    for log_file in "${signal_levels_log_list[@]}" ; do
        local csv_file=${log_file%.txt}.csv
        local log_file_data_lines_count=$(( $( wc -l < ${log_file} ) - 2 ))  
        if [[ "${log_file_data_lines_count}" -le 0 ]]; then
            ### The log file has only the two header lines
            wd_logger 2 "Found log file ${log_file} has only the header lines"
            rm -f ${csv_file}
            continue
        fi
            
        local csv_lines=${rows_per_day}
        if [[ ${csv_lines} -gt ${log_file_data_lines_count} ]]; then
            wd_logger 2 "Log file ${log_file} has only ${log_file_data_lines_count} lines in it, which is less than 24 hours of data."
            csv_lines=${log_file_data_lines_count}
        fi
        #  format conversion is by Rob AI6VN - could work directly from log file, but nice to have csv files GG using tail rather than cat
        tail -n ${csv_lines} ${log_file} \
            | sed -nr '/^[12]/s/\s+/,/gp' \
            | sed 's=^\(..\)\(..\)\(..\).\(..\)\(..\):=\3/\2/\1 \4:\5=' \
            | awk -F ',' '{ print $0 }'  > ${NOISE_GRAPHS_TMP_CSV_FILE}
	if [[ -s ${NOISE_GRAPHS_TMP_CSV_FILE} ]]; then
            mv ${NOISE_GRAPHS_TMP_CSV_FILE} ${csv_file}  ### only create .csv if it has at least one line of data
            wd_logger 2 "Created '${csv_file}'"
        else
            wd_logger 1 "ERROR: failed to create '${csv_file}'"
        fi
    done

    local csv_file_list=( $( find ${signal_levels_root_dir} -type f -name ${SIGNAL_LEVEL_CSV_FILE_NAME} -print) )  
    if [[ ${#csv_file_list[0]} -eq 0 ]]; then
        wd_logger 1 "Found no .csv files to plot"
        return 0
    fi
    local sort_field_number=$(( $(awk -F / '{print NF}' <<< "${csv_file_list[0]}") - 1 ))        ### Sort on the .../BAND/... in the path to the .csv file
    local sorted_csv_file_list=( $( local path; for path in ${csv_file_list[@]}; do echo ${path}; done | sort -n -t / -k ${sort_field_number},${sort_field_number} ) )
    if [[ ${#sorted_csv_file_list[@]} -eq 0 ]] ; then 
        wd_logger 1 "ERROR: failed to sort .csv file list"  ### , or ${signal_band_count} -ne ${band_file_lines}.  Don't plot"
        return 0 
    fi

    local plot_csv_file_list_string=$( echo ${sorted_csv_file_list[@]} | tr '\n' ' ')
    python3 ${NOISE_PLOT_CMD} ${SIGNAL_LEVEL_UPLOAD_ID-wsprdaemon.sh}  ${my_maidenhead} ${NOISE_GRAPH_TMP_FILE} ${noise_calibration_file} "${plot_csv_file_list_string}"
    local ret_code=$?
    wd_logger 1 "'python3 ${NOISE_PLOT_CMD} ${SIGNAL_LEVEL_UPLOAD_ID-wsprdaemon.sh}  ${my_maidenhead} ${NOISE_GRAPH_TMP_FILE} ${noise_calibration_file} '${sorted_csv_file_list[*]}' => ${ret_code}"
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'python3 ${NOISE_PLOT_CMD} ${SIGNAL_LEVEL_UPLOAD_ID-wsprdaemon.sh}  ${my_maidenhead} ${NOISE_GRAPH_TMP_FILE} ${noise_calibration_file} ...' => ${ret_code}"
        return ${ret_code}
    fi
    mv ${NOISE_GRAPH_TMP_FILE} ${NOISE_GRAPH_FILE}
    wd_logger 1 "Created new '${NOISE_GRAPH_FILE}'"
    if [[ ${NOISE_GRAPHS_LOCAL_ENABLED-no} == "yes" ]]; then
        wd_logger 1 "Configured for local web page display, so copying ${NOISE_GRAPH_FILE} to ${NOISE_GRAPH_WWW_FILE}"
        sudo  cp -p  ${NOISE_GRAPH_FILE}  ${NOISE_GRAPH_WWW_FILE}
    fi
    if [[ "${NOISE_GRAPHS_UPLOAD_ENABLED-no}" == "yes" ]] && [[ ${SIGNAL_LEVEL_UPLOAD_ID-none} != "none" ]]; then
        local upload_file_name=${SIGNAL_LEVEL_UPLOAD_ID}-$(date -u +"%y-%m-%d-%H-%M")-noise_graph.png
        local upload_url=${SIGNAL_LEVEL_FTP_URL-graphs.wsprdaemon.org/upload}/${upload_file_name}
        local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-noisegraphs}
        local upload_password=${NOISE_GRAPHS_UPLOAD_FTP_PASSWORD}
        local upload_rate_limit=$(( ${SIGNAL_LEVEL_FTP_RATE_LIMIT_BPS-1000000} / 8 ))        ## SIGNAL_LEVEL_FTP_RATE_LIMIT_BPS can be declared in .conf. It is in bits per second.

        wd_logger 1 "Starting ftp upload of ${NOISE_GRAPH_FILE} to ftp://${upload_url}"
        curl -s --limit-rate ${upload_rate_limit} -T ${NOISE_GRAPH_FILE} --user ${upload_user}:${upload_password} ftp://${upload_url}
        wd_logger 1 "Ftp upload is complete"
    fi
    return 0
}
