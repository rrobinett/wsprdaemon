#!/bin/bash 
#
shopt -s -o nounset

verbosity=${verbosity-1}

declare KA9Q_METADUMP_LOG_FILE="${KA9Q_METADUMP_LOG_FILE-/dev/shm/wsprdaemon/ka9q_metadump.log}"   ### Put output of metadump here
declare KA9Q_METADUMP_STATUS_FILE="${KA9Q_STATUS_FILE-/dev/shm/wsprdaemon/ka9q.status}"            ### Parse the fields in that file into seperate lines in this file


function wd_logger() {
    local level=$1

    if [[ ${level} -gt ${verbosity} ]]; then
        return 0
    fi
    local log_line="${2}"

    echo "${log_line}"
}
 
### Parses the data fields in the first line with the word 'STAT' in it into the global associative array ka9q_status_list()

declare -A ka9q_status_list=()

function ka9q_get_metadump() {
     metadump -c 2 -s 14095600 hf.local > ${KA9Q_METADUMP_LOG_FILE}
 }

function ka9q_parse_metadump_file_to_status_file() {
    local metadump_log_file=${1}
    local metadump_status_file=${2}

    wd_logger 2 "Parse last STAT line in ${metadump_log_file}"

    local last_stat_line=$(grep "STAT"  ${metadump_log_file} | tail -n 1)
    wd_logger 2  "Last STAT line:  ${last_stat_line}" 

    local last_stat_line_list=(${last_stat_line})

    local last_stat_line_date="${last_stat_line_list[@]:0:6}"
    local last_stat_line_epoch=$(date -d "${last_stat_line_date}" +%s)
    local last_stat_line_host="${last_stat_line_list[6]}"
    local last_stat_line_data="${last_stat_line_list[@]:8}"

    wd_logger 2  "Last STAT date:  ${last_stat_line_date}  === epoch ${last_stat_line_epoch}" 
    wd_logger 2  "Last STAT host:  ${last_stat_line_host}" 
    wd_logger 2  "Last STAT data:  '${last_stat_line_data}'" 

    > ${metadump_status_file}.tmp    ### create or truncate the output file
    local parsed_status_line="${last_stat_line_data}"
    while [[ -n "${parsed_status_line}" ]]; do
        local leading_status_field="${parsed_status_line%% \[*}"
        echo "${leading_status_field}" >> ${metadump_status_file}.tmp
        wd_logger 2 "Got leading_status_field=${leading_status_field}"
        local no_left_parens="${parsed_status_line#\[}"
        if ! [[ ${no_left_parens} =~ \[ ]]; then
            wd_logger 2 "No '[' left after stripping the first one.  So we are done parsing"
           break
        fi
        parsed_status_line="[${parsed_status_line#* \[}"
    done
    sort -t '[' -k2n  ${metadump_status_file}.tmp >  ${metadump_status_file}
    rm -f ${metadump_status_file}.tm
}

function ka9q_get_status_value() {
    local __return_var="$1"
    local search_val="$2"

    ### Parsing metadump's status report lines has proved to be a RE challenge since some lines include a subset of other status report lines
    ### Also each line starts with its enum value '[xxx]' while some lines include a '/'.  This sed expression avoids problems with '/' by delimiting the 's' seach 
    ### and replace command fields with ';' which isn't found in any of the current status lines
    local search_results=$( sed -n -e "s;^\[[0-9]*\] ${search_val};;p"  ${KA9Q_METADUMP_STATUS_FILE} )
    wd_logger 2 "Found search string '${search_val}' in line and returning '${search_results}'"
    eval ${__return_var}=\""${search_results}"\"
}

function ka9q_status_service_test() {
    ka9q_get_metadump
    ka9q_parse_metadump_file_to_status_file  ${KA9Q_METADUMP_LOG_FILE} ${KA9Q_METADUMP_STATUS_FILE}
    local current_sd_overloads_count
    ka9q_get_status_value current_sd_overloads_count "A/D overrange:"
    echo "A/D overrange: ${current_sd_overloads_count}"
    #less ${KA9Q_METADUMP_STATUS_FILE}
 }
 ka9q_status_service_test
