declare -r WSPRDAEMON_PROXY_PID_FILE=${WSPRDAEMON_ROOT_DIR}/proxy.pid
declare WD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare FRPC_CMD=${WD_BIN_DIR}/frpc
declare WD_FRPS_URL=${WD_FRPS_URL-logs.wsprdaemon.org}
declare WD_FRPS_PORT=35735
declare WD_FRPC_REMOTE_PORT=${WD_FRPC_REMOTE_PORT-$(( ${WD_FRPS_PORT} + ${RANDOM} % 50 ))}   ### Unless the remote port is specified in WD.conf, generate a random port number
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
        wd_logger 1 "No proxy client connection daemon is active"
    else
        wd_logger 1 "Proxy client connection daemon is active with pid ${proxy_pid}"
    fi
    return 0
}

### If REVERSE_PROXY == "no" (the default), kills any running proxy client
### Else verify proxy is running and spawn a proxy client session if no proxy is running
function proxy_connection_manager() {
    local proxy_pid=$(proxy_connection_pid)
    if [[ ${REVERSE_PROXY-no} == "no" ]] ; then
        if [[ ${proxy_pid} -ne 0 ]]; then
            wd_logger 1 "Proxy disabled, but found running proxy client job ${proxy_pid}.  Kill it"
            kill ${proxy_pid}
            rm ${WSPRDAEMON_PROXY_PID_FILE}
        else
            wd_logger 2 "Proxy disabled and found no pid file as expected"
        fi
        return
    fi
    wd_logger 2 "Proxy connection is enabled"
    if [[ ${proxy_pid} -ne 0 ]]; then
        eval $(sed -n 's/^/local\t/;/=/s/ //gp' ${FRPC_INI_FILE})
        wd_logger 2 "ALERT: There is an active proxy connection to ${server_addr} port ${remote_port}"
        return 0
    fi

    mkdir -p ${WD_BIN_DIR}
    if [[ ! -x ${FRPC_CMD} ]]; then
        local cpu_arch=$(uname -m)
        local frp_tar_file=""
        case ${cpu_arch} in
            x86_64)
                frp_tar_file=frp_${FRP_REQUIRED_VERSION}_linux_amd64.tar.gz
                ;;
            armv7l)
                frp_tar_file=frp_${FRP_REQUIRED_VERSION}_linux_arm.tar.gz
                ;;
            *)
                wd_logger 1 "ERROR: CPU architecture '${cpu_arch}' is not supported by this program"
                exit 1
                ;;
        esac
        ### Download WSJT-x and extract its files and copy wsprd to /usr/bin/
        cd ${WD_BIN_DIR}
        local frp_tar_url=https://github.com/fatedier/frp/releases/download/v${FRP_REQUIRED_VERSION}/${frp_tar_file}
        wget ${frp_tar_url} > /dev/null 2>&1
        if [[ ! -f ${frp_tar_file} ]] ; then
            wd_logger 1 "ERROR: failed to download wget http://physics.princeton.edu/pulsar/K1JT/${frp_tar_file}"
            exit 1
        fi
        wd_logger 1 "Got FRP tar file"
        tar xf ${frp_tar_file}
        wd_rm ${frp_tar_file}         ### We are done with the tar file, so flush it

        local frp_dir=${frp_tar_file%.tar.gz}
        cp -p ${frp_dir}/frpc ${FRPC_CMD}
        rm -r ${frp_dir}              ### We have extracted the 'frpc' command, so flush the directory tree
        cd -
    fi
    if [[ ! -f ${FRPC_INI_FILE} ]]; then
        cat > ${FRPC_INI_FILE} <<EOF
[common]
server_addr = ${WD_FRPS_URL}
server_port = ${WD_FRPS_PORT}

[${SIGNAL_LEVEL_UPLOAD_ID}]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = ${WD_FRPC_REMOTE_PORT}
EOF
        wd_logger 1 "Created frpc.ini which specifies connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this clients ssh port on port ${WD_FRPC_REMOTE_PORT} of that server"
    fi
    wd_logger 1 "Spawning the frpc daemon connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this clients ssh port on port ${WD_FRPC_REMOTE_PORT} of that server"
    ${FRPC_CMD} -c ${FRPC_INI_FILE} > ${FRPC_LOG_FILE} 2>&1 & #-c ${FRPC_INI_FILE} &
    local ret_code=$?
    if [[ ${ret_code} -ne 0 ]]; then
        wd_logger 1 "Error ${ret_code} when spawning the frpc daemon"
        exit ${ret_code}
    fi
    local frpc_daemon_pid=$!
    # declare  FRPC_STARTUP_SLEEP_SECS=${FRPC_STARTUP_SLEEP_SECS-2}        ### How long to wait for frpc to start before checking its status  
    # sleep ${FRPC_STARTUP_SLEEP_SECS}
    if ! ps ${frpc_daemon_pid} > /dev/null; then
        wd_logger 1 "ERROR: frpc failed to start: '$(cat ${FRPC_LOG_FILE})'"
        exit 1
    fi
    echo ${frpc_daemon_pid} > ${WSPRDAEMON_PROXY_PID_FILE}
    wd_logger 1 "Spawned frpc daemon with pid ${frpc_daemon_pid}"
}
