
##########################################################################################################################################################
########## Section which creates and uploads the noise level graphs ######################################################################################
##########################################################################################################################################################

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

    if [[ -f ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} ]] ; then
        local now_secs=$(date +%s)
        local graph_secs=$(date -r ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} +%s)
        local graph_age_secs=$(( ${now_secs} - ${graph_secs} ))

        if [[ ${graph_age_secs} -lt ${GRAPH_UPDATE_RATE-480} ]]; then
            ### The python script which creates the graph file is very CPU intensive and causes the KPH Pis to fall behind
            ### So create a new graph file only every 480 seconds (== 8 minutes), i.e. every fourth WSPR 2 minute cycle
            [[ ${verbosity} -gt 2 ]] && echo "plot_noise() found graphic file is only ${graph_age_secs} seconds old, so don't update it"
            return
        fi
    fi

    if [[ ! -f ${noise_calibration_file} ]]; then
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
    fi
    # noise records are all 2 min apart so 30 per hour so rows = hours *30. The max number of rows we need in the csv file is (24 *30), so to speed processing only take that number of rows from the log file
    local -i rows=$((24*30))

    ### convert wsprdaemon AI6VN  sox stats format to csv for excel or Python matplotlib etc

    for log_file in ${signal_levels_root_dir}/*/*/signal-levels.log ; do
        local csv_file=${log_file%.log}.csv
        if [[ ! -f ${log_file} ]]; then
            [[ ${verbosity} -gt 1 ]] && echo "$(date): plot_noise() found no expected log file ${log_file}"
            rm -f ${csv_file}
            continue
        fi
        local log_file_lines=$(( $(cat ${log_file} | wc -l ) - 2 ))  
        if [[ "${log_file_lines}" -le 0 ]]; then
            ### The log file has only the two header lines
            [[ ${verbosity} -gt 1 ]] && echo "$(date): plot_noise() found log file ${log_file} has only the header lines"
            rm -f ${csv_file}
            continue
        fi
            
        local csv_lines=${rows}
        if [[ ${csv_lines} -gt ${log_file_lines} ]]; then
            [[ ${verbosity} -gt 1 ]] && echo "$(date): plot_noise() log file ${log_file} has only ${log_file_lines} lines in it, which is less than 24 hours of data."
            csv_lines=${log_file_lines}
        fi
        #  format conversion is by Rob AI6VN - could work directly from log file, but nice to have csv files GG using tail rather than cat
        tail -n ${csv_lines} ${log_file} \
            | sed -nr '/^[12]/s/\s+/,/gp' \
            | sed 's=^\(..\)\(..\)\(..\).\(..\)\(..\):=\3/\2/\1 \4:\5=' \
            | awk -F ',' '{ if (NF == 16) print $0 }'  > ${SIGNAL_LEVELS_TMP_CSV_FILE}
	[[ -s ${SIGNAL_LEVELS_TMP_CSV_FILE} ]] && mv ${SIGNAL_LEVELS_TMP_CSV_FILE} ${log_file%.log}.csv  ### only create .csv if it has at least one line of data
    done
    local band_paths=(${signal_levels_root_dir}/*/*/signal-levels.csv)  
    IFS=$'\n' 
    local sorted_paths=$(sort -t / -rn -k 7,7  <<< "${band_paths[*]}" | tr '\n' ' ' )
    unset IFS
    local signal_band_count=${#band_paths[*]}
    ### local band_file_lines=$(cat ${sorted_paths[@]} | wc -l )
    if [[ ${signal_band_count} -eq 0 ]] ; then ### || [[ ${signal_band_count} -ne ${band_file_lines} ]]; then
        [[ ${verbosity} -ge 1 ]] && echo "$(date): plot_noise() ERROR, no noise log files signal_band_count=${signal_band_count}.  Don't plot"  ### , or ${signal_band_count} -ne ${band_file_lines}.  Don't plot"
    else
        create_noise_graph ${SIGNAL_LEVEL_UPLOAD_ID-wsprdaemon.sh}  ${my_maidenhead} ${SIGNAL_LEVELS_TMP_NOISE_GRAPH_FILE} ${noise_calibration_file} "${sorted_paths[@]}"
        mv ${SIGNAL_LEVELS_TMP_NOISE_GRAPH_FILE} ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}
        if [[ ${SIGNAL_LEVEL_LOCAL_GRAPHS-no} == "yes" ]]; then
            [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() is configured to display local web page graphs"
            sudo  cp -p  ${SIGNAL_LEVELS_NOISE_GRAPH_FILE}  ${SIGNAL_LEVELS_WWW_NOISE_GRAPH_FILE}
        fi
        if [[ "${SIGNAL_LEVEL_UPLOAD_GRAPHS-no}" == "yes" ]] && [[ ${SIGNAL_LEVEL_UPLOAD_ID-none} != "none" ]]; then
            if [[ ${SIGNAL_LEVEL_UPLOAD_GRAPHS_FTP_MODE:-yes} == yes ]]; then
                local upload_file_name=${SIGNAL_LEVEL_UPLOAD_ID}-$(date -u +"%y-%m-%d-%H-%M")-noise_graph.png
                local upload_url=${SIGNAL_LEVEL_FTP_URL-graphs.wsprdaemon.org/upload}/${upload_file_name}
                local upload_user=${SIGNAL_LEVEL_FTP_LOGIN-noisegraphs}
                declare SIGNAL_LEVEL_FTP_PASSWORD_DEFAULT="xahFie6g"  ## Hopefully this never needs to change 
                local upload_password=${SIGNAL_LEVEL_FTP_PASSWORD-${SIGNAL_LEVEL_FTP_PASSWORD_DEFAULT}}
                local upload_rate_limit=$(( ${SIGNAL_LEVEL_FTP_RATE_LIMIT_BPS-1000000} / 8 ))        ## SIGNAL_LEVEL_FTP_RATE_LIMIT_BPS can be declared in .conf. It is in bits per second.

                [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() starting ftp upload of ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} to ftp://${upload_url}"
                curl -s --limit-rate ${upload_rate_limit} -T ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} --user ${upload_user}:${upload_password} ftp://${upload_url}
                [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() ftp upload is complete"
            else
                local graphs_server_address=${GRAPHS_SERVER_ADDRESS:-graphs.wsprdaemon.org}
                local graphs_server_password=${SIGNAL_LEVEL_UPLOAD_GRAPHS_PASSWORD-wsprdaemon-noise}
                sshpass -p ${graphs_server_password} ssh -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -p ${LOG_SERVER_PORT-22} wsprdaemon@${graphs_server_address} "mkdir -p ${SIGNAL_LEVEL_UPLOAD_ID}" 2>/dev/null
                sshpass -p ${graphs_server_password} scp -o "UserKnownHostsFile=/dev/null" -o "StrictHostKeyChecking=no" -P ${LOG_SERVER_PORT-22} ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} \
                    wsprdaemon@${graphs_server_address}:${SIGNAL_LEVEL_UPLOAD_ID}/${SIGNAL_LEVELS_NOISE_GRAPH_FILE##*/} > /dev/null 2>&1
                [[ ${verbosity} -ge 2 ]] && echo "$(date): plot_noise() configured to upload  web page graphs, so 'scp ${SIGNAL_LEVELS_NOISE_GRAPH_FILE} wsprdaemon@${graphs_server_address}:${SIGNAL_LEVEL_UPLOAD_ID}/${SIGNAL_LEVELS_NOISE_GRAPH_FILE##*/}'"
            fi
        fi
    fi
}

declare -r NOISE_PLOT_CMD=${WSPRDAEMON_ROOT_DIR}/noise_plot.py
###
function create_noise_graph() {
    local receiver_name=$1
    local receiver_maidenhead=$2
    local output_pngfile_path=$3
    local calibration_file_path=$4
    local csv_file_list="$5"        ## This is a space-seperated list of the .csv file paths, so "" are required

    python3 ${NOISE_PLOT_CMD} ${receiver_name} ${receiver_maidenhead} ${output_pngfile_path} ${calibration_file_path} "${csv_file_list}"
}


