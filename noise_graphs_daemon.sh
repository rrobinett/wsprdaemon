#!/bin/bash

declare NOISE_GRAPHS_USER_HOME_DIR="/home/noisegraphs"
declare UPLOAD_DAEMON_FTP_DIR=${NOISE_GRAPHS_USER_HOME_DIR}/ftp/upload/    ### WD users can choose to have WD FTP their noise png graphs to the /home/noisegraphs/ftp/uploads drectory where their tbz files are also sent

declare NOISE_GRAPHS_WWW_ROOT_DIR=/var/www/html/graphs      ### Root of individual reporter noisegraph pages

declare NOISE_GRAPHS_ROOT_INDEX_FILE=${NOISE_GRAPHS_WWW_ROOT_DIR}/index.html
declare NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE=${WSPRDAEMON_ROOT_DIR}/noise_graphs_root_index_template.html    ### This is put into each reporter's www/html/graphs/REPORTER directory

declare NOISE_GRAPHS_POLLING_INTERVAL_SECS=5
declare MAX_PNG_FILES_TO_POST=1000 
function publish_latest_noisegraph_pngs()
{
    if [[ ! -d ${UPLOAD_DAEMON_FTP_DIR} ]]; then
	wd_logger 1 "No '${UPLOAD_DAEMON_FTP_DIR}' on this server, so the user 'noisegraphs' needs to be created"
	return 1
    fi
    local png_files_list=( $( find ${UPLOAD_DAEMON_FTP_DIR} -type f -name '*.png') )

    wd_logger 2 "Found ${#png_files_list[@]} png files: ${png_files_list[*]}"
    if [[ ${#png_files_list[@]} -eq 0 ]] ; then
        wd_logger 2 "There are no .png files in '${UPLOAD_DAEMON_FTP_DIR}'"
        return 0
    elif [[ ${#png_files_list[@]} -gt ${MAX_PNG_FILES_TO_POST} ]]; then
        wd_logger 1 "There are '${#png_files_list[@]}' files to publish, too many to do at once. So publish only the first ${MAX_PNG_FILES_TO_POST} files"
        png_files_list=( ${png_files_list[@]::{MAX_PNG_FILES_TO_POST}} )
    else
        wd_logger 2 "Publishing the '${#png_files_list[@]}' png files found in '${UPLOAD_DAEMON_FTP_DIR}'"
    fi
    local png_path
    for png_path in ${png_files_list[@]}; do
        local png_file=${png_path##*/}
        local site_id=${png_file%%-*}
        local file_root=${png_file##*-}
        local file_upload_datetime=${png_file#*-}
        file_upload_datetime=${file_upload_datetime%-*}

        local publish_dir=${NOISE_GRAPHS_WWW_ROOT_DIR}/${site_id}
        wd_logger 2 "Found file '${png_file}' from site '${site_id}' and moving it to '${publish_dir}'"
        sudo mkdir -p ${publish_dir}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'sudo mkdir -p ${publish_dir}' => ${ret_code}"
            exit 1
        fi
        sudo rm -f ${publish_dir}/*
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'sudo mkdir -p ${publish_dir}' => ${ret_code}"
            exit 1
        fi
        sudo cp -p ${NOISE_GRAPHS_REPORTER_INDEX_TEMPLATE_FILE} ${publish_dir}/index.html
        sudo mv ${png_path} ${publish_dir}/${file_root}
        sudo chmod a+r ${publish_dir}/*
        sudo chown -R noisegraphs:noisegraphs ${publish_dir}
        wd_logger 1 "Published '${png_file}' from site '${site_id}' by moving it to '${publish_dir}'"
    done
}

function setup_noisegraph_daemon_files()
{
    sudo mkdir -p ${NOISE_GRAPHS_WWW_ROOT_DIR}
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "ERROR: 'sudo mkdir -p ${NOISE_GRAPHS_WWW_ROOT_DIR}' failed with => ${ret_code}"
       exit 1
    fi
    wd_logger 1 "Checking for needed files"
    if [[ ! -f ${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE} ]]; then
        wd_logger 1 "ERROR: missing the expected file '${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE}'"
        exit 1
    fi
     if [[ ! -f ${NOISE_GRAPHS_REPORTER_INDEX_TEMPLATE_FILE} ]]; then
        wd_logger 1 "ERROR: missing the expected file '${NOISE_GRAPHS_REPORTER_INDEX_TEMPLATE_FILE}'"
        exit 1
    fi
    local update_index_file="no"
    if [[ ! -f ${NOISE_GRAPHS_ROOT_INDEX_FILE} ]]; then
        wd_logger 1 "Missing '${NOISE_GRAPHS_ROOT_INDEX_FILE} so sudo cp -p ${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE} ${NOISE_GRAPHS_ROOT_INDEX_FILE}"
        update_index_file="yes"
    elif [[ ${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE} -nt ${NOISE_GRAPHS_ROOT_INDEX_FILE} ]]; then
        wd_logger 1 "The template file '${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE}' is newer than ${NOISE_GRAPHS_ROOT_INDEX_FILE}, so sudo cp -p ${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE} ${NOISE_GRAPHS_ROOT_INDEX_FILE}"
        update_index_file="yes"
    fi
    if [[ ${update_index_file} == "yes" ]]; then
        sudo cp -p ${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE} ${NOISE_GRAPHS_ROOT_INDEX_FILE}
        local ret_code=$?
        if [[ ${ret_code} -ne 0 ]]; then
            wd_logger 1 "ERROR: 'sudo cp -p ${NOISE_GRAPHS_ROOT_INDEX_TEMPLATE_FILE} ${NOISE_GRAPHS_ROOT_INDEX_FILE}' failed with => ${ret_code}"
            exit 1
        fi
    fi
}

function noise_graphs_publishing_daemon() 
{
    local noise_graphs_publishing_root_dir=$1

    mkdir -p ${noise_graphs_publishing_root_dir}
    cd ${noise_graphs_publishing_root_dir}

    setup_verbosity_traps
    setup_noisegraph_daemon_files

    wd_logger 1 "Starting in ${noise_graphs_publishing_root_dir}"

    while true; do
        wd_logger 2 "Awake"

        publish_latest_noisegraph_pngs

        wd_logger 2 "Finished publishing. Sleeping for ${NOISE_GRAPHS_POLLING_INTERVAL_SECS} seconds"
        wd_sleep ${NOISE_GRAPHS_POLLING_INTERVAL_SECS}
    done
}

function kill_noise_graphs_publishing_daemon()
{
    local noise_graphs_publishing_root_dir=$1
    local noise_graphs_publishing_daemon_function_name="noise_graphs_publishing_daemon"

    wd_logger 2 "Kill with: 'kill_daemon ${noise_graphs_publishing_daemon_function_name}  ${noise_graphs_publishing_root_dir}'"
    kill_daemon         ${noise_graphs_publishing_daemon_function_name}  ${noise_graphs_publishing_root_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "Killed the ${noise_graphs_publishing_daemon_function_name} running in '${noise_graphs_publishing_root_dir}'"
    else
        wd_logger 1 "The '${noise_graphs_publishing_daemon_function_name}' was not running in '${noise_graphs_publishing_root_dir}'"
    fi

}

function get_status_noise_graphs_publishing_daemon() 
{
    local noise_graphs_publishing_root_dir=$1
    local noise_graphs_publishing_daemon_function_name="noise_graphs_publishing_daemon"

    wd_logger 2 "Get status with: 'get_status_of_daemon ${noise_graphs_publishing_daemon_function_name}  ${noise_graphs_publishing_root_dir}'"
    get_status_of_daemon  ${noise_graphs_publishing_daemon_function_name}  ${noise_graphs_publishing_root_dir}
    local ret_code=$?
    if [[ ${ret_code} -eq 0 ]]; then
        wd_logger 1 "The ${noise_graphs_publishing_daemon_function_name} is running in '${noise_graphs_publishing_root_dir}'"
    else
        wd_logger 1 "The ${noise_graphs_publishing_daemon_function_name} is not running in '${noise_graphs_publishing_root_dir}'"
    fi
    return ${ret_code}

}

