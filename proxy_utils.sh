declare -r WSPRDAEMON_PROXY_PID_FILE=${WSPRDAEMON_ROOT_DIR}/proxy.pid
declare WD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare FRPC_CMD=${WD_BIN_DIR}/frpc
declare WD_FRPS_URL=${WD_FRPS_URL-wd0.wsprdaemon.org}
declare WD_FRPS_PORT=35735
declare FRP_REQUIRED_VERSION=${FRP_REQUIRED_VERSION-0.36.2}    ### Default to use FRP version 0.36.2
declare FRPC_LOG_FILE=${FRPC_CMD}.log
declare FRPC_INI_FILE=${FRPC_CMD}_wd.ini

### Echos 0 if no client is running, else echos the pid of the running proxy
function proxy_connection_pid() {
    local proxy_pid=0
    if [[ -f ${WSPRDAEMON_PROXY_PID_FILE} ]]; then
        proxy_pid=$(cat ${WSPRDAEMON_PROXY_PID_FILE})
        if ps ${proxy_pid} > /dev/null; then
            wd_logger 2 "FRPC is running with pid ${proxy_pid}"
        else
            wd_logger 2 "FRPC pid file contains zombie pid ${proxy_pid}"
            rm ${WSPRDAEMON_PROXY_PID_FILE}
            proxy_pid=0
        fi
    else
        wd_logger 2 "No ${WSPRDAEMON_PROXY_PID_FILE} file, so no proxy client daemon is running"
    fi
    echo ${proxy_pid}
}

function proxy_connection_status() {
    local proxy_pid=$(proxy_connection_pid)
    if [[ ${proxy_pid} -eq 0 ]]; then
        wd_logger 2 "No proxy client connection daemon is active"
    else
        wd_logger 2 "Proxy client connection daemon is active with pid ${proxy_pid}"
    fi
    return 0
}

### If REVERSE_PROXY == "no" (the default), kills any running proxy client
### Else verify proxy is running and spawn a proxy client session if no proxy is running
function proxy_connection_manager() {
    local proxy_pid=$(proxy_connection_pid)     ### Returns 0 if there is no pid file or the pid is dead

    local conf_file
    if [[ -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
        conf_file=${WSPRDAEMON_CONFIG_FILE}
    elif [[ -f ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ]]; then
        wd_logger 1 "wdpraemon.conf has not yet been configured. Edit it and run this again"
        cp -p ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE}
        exit 1
    else
        wd_logger 1 "ERROR: can't find either ${WSPRDAEMON_CONFIG_FILE} or ${WSPRDAEMON_CONFIG_TEMPLATE_FILE}"
        exit 1
    fi
    local remote_access_channel=$(sed 's/ //g; s/#.*//; s/"//g' ${WSPRDAEMON_CONFIG_FILE} | awk -F = '/^ *REMOTE_ACCESS_CHANNEL/{print $2}')

    if [[ -z "${remote_access_channel-}" ]] || ! is_uint "${remote_access_channel-}"; then
        ### A remote access channel is not defined or defined as "no"
        if [[ -z "${remote_access_channel-}" ]]; then
            ### If remote_access_channel is not defined in the conf file, normally there is no need for a printout
            wd_logger 2 "Proxy service is not enabled"
        elif [[ "${remote_access_channel-}" != "no" ]]; then
            ### Only print if it isn't a number and it isn't "no".  No need to printout if it is "no"
            wd_logger 0 "ERROR: Proxy service channel is defined as ${remote_access_channel}, but that is not an integer number"
            exit 1
        fi

        if [[ ${proxy_pid} -ne 0 ]]; then
            wd_logger 0 "Proxy disabled, but found running proxy client job ${proxy_pid}. Kill it"
            kill ${proxy_pid}
            wd_rm ${WSPRDAEMON_PROXY_PID_FILE}
        else
            wd_logger 2 "Proxy disabled and found no pid file as expected"
        fi
        return
    fi
    local signal_level_upload_id=$( sed 's/ //g; s/#.*//; s/"//g' ${WSPRDAEMON_CONFIG_FILE} | awk -F = '/^ *SIGNAL_LEVEL_UPLOAD_ID/{print $2}')
    if [[ -z "${signal_level_upload_id}" ]]; then
        wd_logger 1 "ERROR: wsprdaemon.conf REMOTE_ACCESS_CHANNEL=${remote_access_channel}, but SIGNAL_LEVEL_UPLOAD_ID is not defined"
        exit 2
    fi
    if [[ "${signal_level_upload_id}" == "AI6VN" ]]; then
        wd_logger 1 "ERROR: wsprdaemon.conf REMOTE_ACCESS_CHANNEL=${remote_access_channel}, but SIGNAL_LEVEL_UPLOAD_ID='AI6VN', so change it to your own ID"
        exit 3
    fi
    wd_logger 2 "Proxy connection REMOTE_ACCESS_CHANNEL=${remote_access_channel}, SIGNAL_LEVEL_UPLOAD_ID='${signal_level_upload_id}' is enabled"

    mkdir -p ${WD_BIN_DIR}
    if [[ ! -x ${FRPC_CMD} ]]; then
        wd_logger 0 "Installing ${FRPC_CMD}"
        local cpu_arch=$(uname -m)
        local frp_tar_file=""
        case ${cpu_arch} in
            x86_64)
                frp_tar_file=frp_${FRP_REQUIRED_VERSION}_linux_amd64.tar.gz
                ;;
            armv7l)
                frp_tar_file=frp_${FRP_REQUIRED_VERSION}_linux_arm.tar.gz
                ;;
            aarch64)
                frp_tar_file=frp_${FRP_REQUIRED_VERSION}_linux_arm64.tar.gz
                ;;
            *)
                wd_logger 0 "ERROR: CPU architecture '${cpu_arch}' is not supported by this program"
                exit 1
                ;;
        esac
        ### Download WSJT-x and extract its files and copy wsprd to /usr/bin/
        cd ${WD_BIN_DIR}
        local frp_tar_url=https://github.com/fatedier/frp/releases/download/v${FRP_REQUIRED_VERSION}/${frp_tar_file}
        wget ${frp_tar_url} > /dev/null 2>&1
        if [[ ! -f ${frp_tar_file} ]] ; then
            wd_logger 0 "ERROR: failed to download wget http://physics.princeton.edu/pulsar/K1JT/${frp_tar_file}"
            exit 1
        fi
        wd_logger 0 "Got FRP tar file"
        tar xf ${frp_tar_file}
        wd_rm ${frp_tar_file}         ### We are done with the tar file, so flush it

        local frp_dir=${frp_tar_file%.tar.gz}
        cp -p ${frp_dir}/frpc ${FRPC_CMD}
        rm -r ${frp_dir}              ### We have extracted the 'frpc' command, so flush the directory tree
        cd -
        wd_logger 0 "Installed ${FRPC_CMD}"
    fi
    if ! sudo systemctl status ssh >& /dev/null; then
        wd_logger 0 "Installing openssh-server"
        if ! sudo apt install openssh-server ; then
            wd_logger 0 "ERROR: failed to Install openssh-server"
            return 1
        fi
        sudo systemctl enable ssh
        sudo systemctl start  ssh
        wd_logger 0 "Installed openssh_server"
    fi

    local frpc_remote_port=$(( ${WD_FRPS_PORT} + 100 - (${WD_FRPS_PORT} % 100 ) + ${remote_access_channel} ))
    if [[ -f ${FRPC_INI_FILE} ]]; then
        wd_logger 2 "Validating ${FRPC_INI_FILE}"
        local fprc_ini_file_port=$( awk '/remote_port/{print $3}' ${FRPC_INI_FILE} )
        local fprc_ini_file_channel=$(( ${fprc_ini_file_port} - (${WD_FRPS_PORT} + 100 - (${WD_FRPS_PORT} % 100) ) ))
        if [[ -z "${fprc_ini_file_port}" || ${fprc_ini_file_port} -ne ${frpc_remote_port} ]]; then
            if [[ -z "${fprc_ini_file_port}" ]]; then
                wd_logger 0 "Found no remote_access_channel specified in ${FRPC_INI_FILE}"
            else
                wd_logger 0 "Remote access channel ${remote_access_channel} specified in .conf file does not match access channel ${fprc_ini_file_channel} specified the in ${FRPC_INI_FILE}.  So kill the currently running session and restart it"
            fi
            if [[ ${proxy_pid} -ne 0 ]]; then
                wd_logger 0 "Kill running proxy client with pid ${proxy_pid}"
                kill ${proxy_pid}
                proxy_pid=0
            fi
            wd_rm ${WSPRDAEMON_PROXY_PID_FILE}
            wd_rm ${FRPC_INI_FILE}
        fi
    fi
 
    if [[ ${proxy_pid} -ne 0 ]]; then
        eval $(sed -n 's/^/local\t/;/=/s/ //gp' ${FRPC_INI_FILE})
        wd_logger 0 "ALERT: There is an active proxy connection to ${server_addr} where its port ${remote_port} is open to this server"
        return 0
    fi

    if [[ ! -f ${FRPC_INI_FILE} ]]; then
        local local_ssh_server_port=22        ### By default the ssh server listens on port 22
        declare SSHD_CONFIG_FILE=/etc/ssh/sshd_config
        if [[ -f ${SSHD_CONFIG_FILE} ]]; then
            local sshd_config_port=$(awk '/^Port /{print $2}' ${SSHD_CONFIG_FILE})
            if [[ -n "${sshd_config_port}" ]]; then
                wd_logger 1 "Ssh service on this server is configured to the non-standard port ${sshd_config_port}, not the ssh default port ${local_ssh_server_port}"
                local_ssh_server_port=${sshd_config_port}
            fi
        fi

        wd_logger 0 "Creating ${FRPC_INI_FILE}"
        cat > ${FRPC_INI_FILE} <<EOF
[common]
admin_addr = 127.0.0.1
admin_port = 7500
server_addr = ${WD_FRPS_URL}
server_port = ${WD_FRPS_PORT}

[${signal_level_upload_id}]
type = tcp
local_ip = 127.0.0.1
local_port = ${local_ssh_server_port}
remote_port = ${frpc_remote_port}
EOF
        wd_logger 1 "Created frpc.ini which specifies connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this clients ssh port on port ${frpc_remote_port} of that server"
    fi

    wd_logger 0 "Spawning the frpc daemon connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this clients ssh port on port ${frpc_remote_port} of that server"
    ${FRPC_CMD} -c ${FRPC_INI_FILE} > ${FRPC_LOG_FILE} 2>&1 & #-c ${FRPC_INI_FILE} &
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 0 "ERROR: got ${ret_code} when spawning the frpc daemon"
        exit ${ret_code}
    fi
    local frpc_daemon_pid=$!
    if ! ps ${frpc_daemon_pid} > /dev/null; then
        wd_logger 0 "ERROR: frpc failed to start: '$(cat ${FRPC_LOG_FILE})'"
        exit 1
    fi
    echo ${frpc_daemon_pid} > ${WSPRDAEMON_PROXY_PID_FILE}
    wd_logger 0 "Spawned frpc daemon with pid ${frpc_daemon_pid} and recorded its pid ${frpc_daemon_pid} to ${WSPRDAEMON_PROXY_PID_FILE}"
    local frpc_status=$(${FRPC_CMD} -c ${FRPC_INI_FILE} status | awk -v id=${signal_level_upload_id} '$1 == id{print $2}')
    if [[ -z "${frpc_status}" || "${frpc_status}" != "running" ]]; then
        wd_logger 0 "ERROR: the remote access service is running but it failed to connect to wsprdaemon.org and it reports:\n$(${FRPC_CMD} -c ${FRPC_INI_FILE} status)"
    fi

}
