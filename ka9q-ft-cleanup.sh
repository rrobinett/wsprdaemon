# This script is run by cron ever 10 minutes to cleanup old wav files 
# and truncate ftX.log files which have grown too large

declare -r GET_FILE_SIZE_CMD="stat --format=%s"
declare -r LOG_FILE_MAX_SIZE_BYTES=1000000
function truncate_file() {
    local file_path=$1       ### Must be a text format file
    local file_max_size=$2   ### In bytes
    local file_size=$( ${GET_FILE_SIZE_CMD} ${file_path} )

    [[ $verbosity -ge 3 ]] && echo "$(date): truncate_file() '${file_path}' of size ${file_size} bytes to max size of ${file_max_size} bytes"

    if [[ ${file_size} -gt ${file_max_size} ]]; then
        local file_lines=$( cat ${file_path} | wc -l )
        local truncated_file_lines=$(( ${file_lines} / 2))
        local tmp_file_path="${file_path%.*}.tmp"
        tail -n ${truncated_file_lines} ${file_path} > ${tmp_file_path}
        mv ${tmp_file_path} ${file_path}
        local truncated_file_size=$( ${GET_FILE_SIZE_CMD} ${file_path} )
        [[ $verbosity -ge 1 ]] && echo "$(date): truncate_file() '${file_path}' of original size ${file_size} bytes / ${file_lines} lines now is ${truncated_file_size} bytes"
    fi
}

cd /dev/shm/ka9q-radio

declare old_wav_file_name_list=( $(find . -type f -name '*wav' -mmin +30) )
for old_wav_file_name in ${old_wav_file_name_list[@]}; do
     [[ $verbosity -ge 1 ]] && echo "$(date): deleting old_wav_file_name=${old_wav_file_name}"
     rm -f ${old_wav_file_name}
done

declare log_file_name_list=( $(find -type f -name '*.log') )
for log_file_name in ${log_file_name_list[@]}; do 
    truncate_file ${log_file_name} ${LOG_FILE_MAX_SIZE_BYTES}
done
cd - > /dev/null


