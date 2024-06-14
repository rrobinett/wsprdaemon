#!/bin/bash

declare WD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare FRPC_CMD=${WD_BIN_DIR}/frpc
declare WD_FRPS_URL=${WD_FRPS_URL-wd0.wsprdaemon.org}
declare WD_FRPS_PORT=35735
declare FRP_REQUIRED_VERSION=${FRP_REQUIRED_VERSION-0.36.2}    ### Default to use FRP version 0.36.2
declare FRPC_INI_FILE=${FRPC_CMD}_wd.ini
declare WD_REMOTE_ACCESS_SERVICE_NAME="wd_remote_access"
declare RAC_ID_MAX=1000
declare RAC_IP_PORT_BASE=35800
declare RAC_IP_PORT_MAX=$(( ${RAC_IP_PORT_BASE} + ${RAC_ID_MAX} ))

function execute_sysctl_command()
{
    local command=$1
    local service=$2
    local rc

    sudo systemctl ${command} ${service} >& /tmp/wd_sysctl_out.txt
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
        wd_logger 2 "OK: 'sudo systemctl ${command} ${service}' => '$(</tmp/wd_sysctl_out.txt)'"
        return 0
    fi
    wd_logger 2 "ERROR: 'sudo systemctl ${command} ${service}' => rc=${rc} =>'$(</tmp/wd_sysctl_out.txt)'"
    return ${rc}
}

function remote_access_connection_stop_and_disable() {
    if execute_sysctl_command is-enabled ${WD_REMOTE_ACCESS_SERVICE_NAME}; then
        wd_logger 1 "Disabling previously enabled ${WD_REMOTE_ACCESS_SERVICE_NAME}"
        execute_sysctl_command disable ${WD_REMOTE_ACCESS_SERVICE_NAME}
    fi
    if execute_sysctl_command is-active ${WD_REMOTE_ACCESS_SERVICE_NAME} ; then
        wd_logger 1 "Stopping running previously enabled and active ${WD_REMOTE_ACCESS_SERVICE_NAME}"
        execute_sysctl_command stop ${WD_REMOTE_ACCESS_SERVICE_NAME}
    fi
    wd_logger 2 "The Remote Access Service is stopped and disnabled"
    return 0
}

function get_frpc_ini_values() {
    local rac_id="none"
    local rac_channel=-1

     if [[ ! -f ${FRPC_INI_FILE} ]]; then
         echo "${rac_channel} ${rac_id}"
         return 1
     fi
     local rac_id_line_list=( $(grep "^\["  ${FRPC_INI_FILE}) )
     [[ ${verbosity} -gt 1 ]] && echo "Found ${#rac_id_line_list[@]}  '[...]' lines in  ${FRPC_INI_FILE}: ${rac_id_line_list[*]}" 1>&2
     if [[ ${#rac_id_line_list[@]} -eq 0 ]]; then
         [[ ${verbosity} -gt 0  ]] && echo "ERROR: Found no '[...]' lines in  ${FRPC_INI_FILE}" 1>&2
         echo ""
         return 1
     fi
     if [[ ${#rac_id_line_list[@]} -eq 1 ]]; then
         [[ ${verbosity} -gt 0  ]] && echo "ERROR: Found only one '[...]'' line in  ${FRPC_INI_FILE}: ${rac_id_line_list[0]}" 1>&2
         echo ""
         return 2
     fi

     local frpc_ini_id="$(echo ${rac_id_line_list[1]} | sed 's/\[//;s/\]//')"
     [[ ${verbosity} -gt 1  ]] && echo "Found frpc_ini's RAC_ID = '${frpc_ini_id}'" 1>&2

      local rac_port_line_list=( $(grep "^remote_port"  ${FRPC_INI_FILE}) )
      if [[ ${#rac_port_line_list[@]} -ne 3 ]]; then 
          [[ ${verbosity} -gt 0  ]] && echo "ERROR: can't find valid 'remote_port' line" 1>&2
          echo ""
          return 3
      fi
      local remote_port=${rac_port_line_list[2]}

      if [[ ${remote_port} -lt ${RAC_IP_PORT_BASE} || ${remote_port} -ge ${RAC_IP_PORT_MAX} ]]; then
          [[ ${verbosity} -gt 0  ]] && echo "ERROR: remote_port ${remote_port} found in ${FRPC_INI_FILE} is invalid" 1>&2
          echo ""
          return 4
      fi
      local frpc_ini_channel=$(( ${remote_port} - ${RAC_IP_PORT_BASE} )) 
      [[ ${verbosity} -gt 1  ]] && echo "The RAC ini file ${FRPC_INI_FILE} is configured to forward RAC '${frpc_ini_id}' from remote_port ${remote_port} to loal port 22" 1>&2
      echo "${frpc_ini_channel} ${frpc_ini_id}"
      return 0
 }

function remote_access_connection_status() {
    local rc

    wd_logger 2 "Starting"
    if [[ -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
        conf_file=${WSPRDAEMON_CONFIG_FILE}
    elif [[ -f ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ]]; then
        wd_logger 1 "wsprdaemon.conf has not yet been configured. Edit it and run this again"
        cp -p ${WSPRDAEMON_CONFIG_TEMPLATE_FILE} ${WSPRDAEMON_CONFIG_FILE}
        exit 1
    else
        wd_logger 1 "ERROR: found neither ${WSPRDAEMON_CONFIG_FILE} nor ${WSPRDAEMON_CONFIG_TEMPLATE_FILE}"
        exit 1
    fi

    source ${WSPRDAEMON_CONFIG_FILE} > /dev/null
    local rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "ERROR: there is a format error in ${WSPRDAEMON_CONFIG_FILE}"
        exit 1
    fi

    ### If REMOTE_ACCESS_CHANNEL is not defined in WD.conf, shut down the RAC
    local wd_conf_rac_channel="${REMOTE_ACCESS_CHANNEL-}"
          wd_conf_rac_channel="${wd_conf_rac_channel-${RAC-}}"    ### accept RAC=...
    if [[ -z "${wd_conf_rac_channel-}" ]] || ! is_uint "${wd_conf_rac_channel-}"; then
        remote_access_connection_stop_and_disable
        wd_logger 1 "REMOTE_ACCESS_CHANNEL is not defined in ${WSPRDAEMON_CONFIG_FILE}, so we have ensured it isn't running"
        return 0
    fi
     local wd_conf_rac_id="${REMOTE_ACCESS_ID-}"
           wd_conf_rac_id="${wd_conf_rac_id-${RACi_ID-}}"    ### accept RAC=...
    if [[ -z "${wd_conf_rac_id-}" ]]; then
        remote_access_connection_stop_and_disable
        wd_logger 1 "REMOTE_ACCESS_CHANNEL '${wd_conf_rac_channel}' is defined in ${WSPRDAEMON_CONFIG_FILE} but {REMOTE_ACCESS_ID is not defined, so we have ensured it isn't running"
        return 0
    fi

    ### The RAC is enabled and configured in the WD.conf file. Check to see if it and the ID match the frpc_wd.ini
    ### Get the last REMOTE_ACCESS_ID or SIGNAL_LEVEL_UPLOAD_ID in the conf file and strip out any '"' characters in it
    local frpc_ini_info_list=( $(get_frpc_ini_values) )
    if [[ ${#frpc_ini_info_list[@]} -ne 2 ]]; then
         wd_logger 1 "The RAC is enabled in the WD.conf file, but here is no session id and/or channel defined in the frpc_wd_file"
         return 1
    fi

    local frpc_ini_channel="${frpc_ini_info_list[0]}"
    if [[ "${frpc_ini_channel}" != "${wd_conf_rac_channel}" ]]; then
        remote_access_connection_stop_and_disable
        wd_logger 1 "RAC_CH '${wd_conf_rac_channel}}' is defined in the WD.conf file, but the RAC ${frpc_ini_channel} in the frpd_wd.ini file doesn't match it.  So stop frpc, recreated the frpc_wd.ini, and restart it"
        return 2
    fi
    local frpc_ini_id="${frpc_ini_info_list[1]}"
    if [[ "${frpc_ini_id}" != "${wd_conf_rac_id}" ]]; then
        remote_access_connection_stop_and_disable
        wd_logger 1 "RAC_ID '${wd_conf_rac_id}}' is defined in the WD.conf file, but the RAC ${frpc_ini_id} in the frpd_wd.ini file doesn't match it.  So stop frpc, recreated the frpc_wd.ini, and restart it"
        return 3
    fi

    execute_sysctl_command is-active ${WD_REMOTE_ACCESS_SERVICE_NAME}
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "The Remote Access Connection service is configured but not active"
        return 4
    fi
    wd_logger 2 "The ${WD_REMOTE_ACCESS_SERVICE_NAME} service is configured and active.  Checking the status of its connection"
    execute_sysctl_command status ${WD_REMOTE_ACCESS_SERVICE_NAME}  
    rc=$?
    if [[ ${rc} -ne 0 ]]; then
        wd_logger 1 "The ${WD_REMOTE_ACCESS_SERVICE_NAME} is configured but returns status ${rc}"
        return 5
    fi
    wd_logger 1 "The Remote Access Connection (RAC) service connected through RAC channel #${REMOTE_ACCESS_CHANNEL} is enabled and running"
    return 0
}

### If REVERSE_PROXY == "" (the default), disables and stops the ${WD_REMOTE_ACCESS_SERVICE_NAME}
### Else, if the ${WD_REMOTE_ACCESS_SERVICE_NAME} is not already running,  configure, enqble and start it
function wd_remote_access_service_manager() {
    local rc

    remote_access_connection_status
    rc=$?
    if [[ ${rc} -eq 0 ]]; then
        wd_logger 2 "Remote Access Connection service is not enabled, or it is enabled and running normally"
        return 0
    fi

    source ${WSPRDAEMON_CONFIG_FILE} > /dev/null
    local remote_access_channel=${REMOTE_ACCESS_CHANNEL}
    local remote_access_id=${REMOTE_ACCESS_ID-${SIGNAL_LEVEL_UPLOAD_ID}}

    wd_logger 1 "Setting up the Remote Access Connection service with REMOTE_ACCESS_CHANNEL=${remote_access_channel}, REMOTE_ACCESS_ID='${remote_access_id}'"

    ### If it isn't already installed, download and install the FRP service from github
    mkdir -p ${WD_BIN_DIR}
    if [[ ! -x ${FRPC_CMD} ]]; then
        wd_logger 1 "Installing ${FRPC_CMD}"
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
                wd_logger 1 "ERROR: CPU architecture '${cpu_arch}' is not supported by this program"
                exit 1
                ;;
        esac
        ### Download  FRPC
        cd ${WD_BIN_DIR}
        local frp_tar_url=https://github.com/fatedier/frp/releases/download/v${FRP_REQUIRED_VERSION}/${frp_tar_file}
        wget ${frp_tar_url} > /dev/null 2>&1
        if [[ ! -f ${frp_tar_file} ]] ; then
            wd_logger 1 "ERROR: failed to download wget http://physics.princeton.edu/pulsar/K1JT/${frp_tar_file}"
            cd - > /dev/null
            exit 1
        fi
        wd_logger 1 "Got FRP tar file"
        tar xf ${frp_tar_file}
        wd_rm ${frp_tar_file}         ### We are done with the tar file, so flush it

        local frp_dir=${frp_tar_file%.tar.gz}
        cp -p ${frp_dir}/frpc ${FRPC_CMD}
        rm -r ${frp_dir}              ### We have extracted the 'frpc' command, so flush the directory tree
        cd - > /dev/null
        wd_logger 1 "Installed ${FRPC_CMD}"
    fi

    ### Some Linux distros don't install the ssh service by default
    if ! execute_sysctl_command status ssh >& /dev/null; then
        wd_logger 1 "Installing openssh-server"
        if ! sudo apt install openssh-server ; then
            wd_logger 1 "ERROR: failed to Install openssh-server"
            return 1
        fi
        execute_sysctl_command enable ssh
        execute_sysctl_command start  ssh
        wd_logger 1 "Installed openssh_server"
    fi

    local frpc_remote_port=$(( ${WD_FRPS_PORT} + 100 - (${WD_FRPS_PORT} % 100 ) + ${remote_access_channel} ))
    local local_ssh_server_port=22        ### By default the ssh server listens on port 22
    declare SSHD_CONFIG_FILE=/etc/ssh/sshd_config
    if [[ -f ${SSHD_CONFIG_FILE} ]]; then
        local sshd_config_port=$(awk '/^Port /{print $2}' ${SSHD_CONFIG_FILE})
        if [[ -n "${sshd_config_port}" ]]; then
            wd_logger 1 "Ssh service on this server is configured to the non-standard port ${sshd_config_port}, not the ssh default port ${local_ssh_server_port}"
            local_ssh_server_port=${sshd_config_port}
        fi
    fi

    wd_logger 2 "Creating ${FRPC_INI_FILE}"
    cat > ${FRPC_INI_FILE} <<EOF
[common]
admin_addr = 127.0.0.1
admin_port = 7500
server_addr = ${WD_FRPS_URL}
server_port = ${WD_FRPS_PORT}

[${remote_access_id}]
type = tcp
local_ip = 127.0.0.1
local_port = ${local_ssh_server_port}
remote_port = ${frpc_remote_port}
EOF
    wd_logger 2 "Created frpc.ini which specifies connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this client's remote_access_id=${remote_access_id} and ssh port on port ${frpc_remote_port} of that server"
 
    local rc
    setup_wd_remote_access_systemctl_daemon
}

### Configure systemctl so this watchdog daemon runs at startup of the Pi
declare -r WD_REMOTE_ACCESS_DAEMON_CMD="${WSPRDAEMON_ROOT_DIR}/wd_remote_access_daemon.sh"
declare -r WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_FILE="${WD_REMOTE_ACCESS_SERVICE_NAME}.service"                       ### Create it in WD's home dirctory
declare -r WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_PATH="/etc/systemd/system/${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_FILE}"    ### Install it where systemctl will find it

function setup_wd_remote_access_systemctl_daemon() {
    local start_args=${1--A}         ### Defaults to client start/stop args, but '-u a' (run as upload server) will configure with '-u a/z'
    local stop_args=${2--Z} 
    local systemctl_dir=${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_PATH%/*}
    if [[ ! -d ${systemctl_dir} ]]; then
        wd_logger 1 "ERROR: This server appears to not be configured to use 'systemctl' which runs ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_FILE}"
        return 1
    fi
    local my_id=$(id -u -n)
    local my_group=$(id -g -n)
    cat > ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_FILE} <<EOF
[Unit]
Description= The Wsprdaemon Remote Access Channel daemon
After=multi-user.target

[Service]
User=${my_id}
Group=${my_group}
WorkingDirectory=${WSPRDAEMON_ROOT_DIR}/bin
ExecStart=${WD_REMOTE_ACCESS_DAEMON_CMD} ${start_args}
ExecStop=${WD_REMOTE_ACCESS_DAEMON_CMD}  ${stop_args}
Type=forking
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF

   wd_logger 2 "Installing the ${WD_REMOTE_ACCESS_SERVICE_NAME} service"
   sudo mv ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_FILE} ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_PATH}    ### 'sudo cat > ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_PATH} gave me permission errors
   execute_sysctl_command daemon-reload  ""
   rc=$?
   if [[ ${rc} -ne 0 ]]; then
       wd_logger 1 "ERROR: 'execute_sysctl_command daemon-reload' => ${rc}"
       return ${rc}
   fi
   execute_sysctl_command enable ${WD_REMOTE_ACCESS_SERVICE_NAME}
   rc=$?
   if [[ ${rc} -ne 0 ]]; then
       wd_logger 1 "ERROR: 'execute_sysctl_command enable ${WD_REMOTE_ACCESS_SERVICE_NAME}' => ${rc}"
       return ${rc}
   fi
   execute_sysctl_command start  ${WD_REMOTE_ACCESS_SERVICE_NAME}
   rc=$?
   if [[ ${rc} -ne 0 ]]; then
       wd_logger 1 "ERROR: 'execute_sysctl_command start ${WD_REMOTE_ACCESS_SERVICE_NAME}' => ${rc}"
       return ${rc}
   fi
   wd_logger 1 "The Remote Access Connection service has been installed and started"
   return 0
}
