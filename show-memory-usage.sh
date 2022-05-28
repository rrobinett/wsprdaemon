declare pid_file_list=()
declare pid_last_values_file="show-memory-usage.last"
declare pid_new_values_file="show-memory-usage.new"

touch ${pid_last_values_file}

function get_daemon_pid_list()
{
    pid_file_list=($(find ~/wsprdaemon /tmp/wsprdaemon -name '*.pid') )
}

function get_mem_usage()
{
    local mem_total=0
    > ${pid_new_values_file}
    get_daemon_pid_list
    for pid_file in ${pid_file_list[@]} ; do
        local pid_val=$(< ${pid_file} )
        if ps ${pid_val} > /dev/null ; then
            local pid_rss_val=$(awk -v pid_file=${pid_file} '/VmRSS/{printf "%s\n", $2}' /proc/${pid_val}/status)
            # printf "PID %6s  VmRSS %6s from pid file %s\n" ${pid_val} ${pid_rss_val}  ${pid_file}
            local old_rss_val=$( grep "${pid_file}" ${pid_last_values_file} | awk '{print $1}')
            if [[ "${pid_rss_val}" -ne "${old_rss_val}" ]]; then
                printf "For PID %8s old=%8s new=%8s from file %s\n" "${pid_val}" "${old_rss_val}" "${pid_rss_val}" "${pid_file}"
            fi
            printf "%8d %s\n"  ${pid_rss_val} ${pid_file} >> ${pid_new_values_file}
            mem_total=$(( mem_total + pid_rss_val))
        else
            echo "pid file ${pid_file} contains pid # ${pid_val} which isn't active"
            rm  ${pid_file}
        fi
    done
    local output_str="$(date): Found ${#pid_file_list[@]} pid files with a VmRSS total of ${mem_total}"
    echo "${output_str}" >> show-memory-usage.txt
    echo "${output_str}"
}
while true; do
    get_mem_usage
    sleep 10
done
