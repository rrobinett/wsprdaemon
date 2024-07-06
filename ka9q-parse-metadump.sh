#!/bin/bash 
#
shopt -s -o nounset

verbosity=${verbosity-1}

declare KA9Q_METADUMP_LOG_FILE="${KA9Q_METADUMP_LOG_FILE-/dev/shm/wsprdaemon/ka9q_metadump.log}"

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

function ka9q_get_status() {
     metadump -c 2 -s 14095600 hf.local > ${KA9Q_METADUMP_LOG_FILE}
 }

function ka9q_metadump_parse() {
    local metadump_log_file=${1-}

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

    local parsed_status_line="${last_stat_line_data}"
    while [[ -n "${parsed_status_line}" ]]; do
        local leading_status_field="${parsed_status_line%% \[*}"
        wd_logger 1 "Got leading_status_field=${leading_status_field}"

    set +x
        local no_left_parens="${parsed_status_line#\[}"
        if ! [[ ${no_left_parens} =~ \[ ]]; then
            wd_logger 2 "No '[' left after stripping the first one.  So we are done parsing"
           break
        fi
        parsed_status_line="[${parsed_status_line#* \[}"
        #read -p "Next => "
    done

}

function ka9q_status_service_test() {
    if [[ ! -f  ${KA9Q_METADUMP_LOG_FILE} ]]; then
        ka9q_get_status
    fi
    ka9q_metadump_parse  ${KA9Q_METADUMP_LOG_FILE}
 }
 ka9q_status_service_test
