#!/bin/bash

### This WD module implemewnts WD's Remote Access Channel service which allows WD admins with access to ports on the wd0.wsprdaemon.org server to ssh to 
### WD devices running the Linux wsprdaemon_remote_access.serice
###
### ED sites enable access by adding two lines to their wsprdaemon.conf file:
#
### REMOTE_ACCESS_CHANNEL=1           ### Defaults to "".  When it is an integer in the range 0-1000, allow the wsprdemon.org administrator ssh access to this WD server if you also provide a user/password on this server
### REMOTE_ACCESS_ID="KPH-Beelink-1"
#
# Hosts with names which start with "WSPRSONDE-" are gateways connected to Wsprsonde8 beacons, and those hosts are automatically set up to log on to this RAC service

declare WD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare FRPC_CMD=${WD_BIN_DIR}/frpc
declare WD_FRPS_URL=${WD_FRPS_URL-wd0.wsprdaemon.org}
declare WD_FRPS_PORT=35735
declare FRP_REQUIRED_VERSION=${FRP_REQUIRED_VERSION-0.36.2}    ### Default to use FRP version 0.36.2
declare FRPC_INI_FILE=${FRPC_CMD}_wd.ini
declare WD_REMOTE_ACCESS_SERVICE_NAME="wd_remote_access"

declare RAC_IP_PORT_BASE=35800    ### Don't change this!  As of 7/9/24 many WD servers have IDs which start here
declare RAC_IP_PORT_MAX=39999
declare WSPRSONDE_IP_PORT_BASE=$(( ${RAC_IP_PORT_BASE} - (  ${RAC_IP_PORT_BASE} % 1000 )  + 3000 ))    ## The WS gateways RAC_IDs start at 3000

declare WSPRSONDE_ID_BASE=$(( ${WSPRSONDE_IP_PORT_BASE} - ${RAC_IP_PORT_BASE} ))
declare RAC_ID_MAX=$(( ${WSPRSONDE_ID_BASE} - 1 ))                                    ### Max RAC_ID is 2199, which should be plenty
declare WSPRSONDE_ID_MAX=$(( ${RAC_IP_PORT_MAX} - ${WSPRSONDE_IP_PORT_BASE} ))        ### Max WPSRSONDE_ID in 1999, which should be plenty

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
    wd_logger 2 "Stop and disable ' ${WD_REMOTE_ACCESS_SERVICE_NAME}'"

    if execute_sysctl_command is-enabled ${WD_REMOTE_ACCESS_SERVICE_NAME}; then
        wd_logger 1 "Disabling previously enabled ${WD_REMOTE_ACCESS_SERVICE_NAME}"
        execute_sysctl_command disable ${WD_REMOTE_ACCESS_SERVICE_NAME}
    fi
    if execute_sysctl_command is-active ${WD_REMOTE_ACCESS_SERVICE_NAME} ; then
        wd_logger 1 "Stopping running previously enabled and active ${WD_REMOTE_ACCESS_SERVICE_NAME}"
        execute_sysctl_command stop ${WD_REMOTE_ACCESS_SERVICE_NAME}
    fi
    wd_logger 2 "The Remote Access Connection (RAC) service has been stopped and disabled"
    return 0
}

function get_frpc_ini_values() {
    local __return_variable_name=$1
    local rac_id="none"
    local rac_channel=-1

    wd_logger 2 "Return ini values to variable ${__return_variable_name}"

    if [[ ! -f ${FRPC_INI_FILE} ]]; then
        wd_logger 1 "ERROR: found no ' ${FRPC_INI_FILE}'"
        return 1
    fi
    local rac_id_line_list=( $( sed -n '/^\[/s/\].*//; /^\[/s/\[//p' ${FRPC_INI_FILE}) )   ## get lines which start with '[' and strip '[' and ']' from those lines
    if (( ! ${#rac_id_line_list[@]} )); then
        wd_logger 1 "ERROR: Found no '[...]' lines in ${FRPC_INI_FILE}"
        return 2
    fi
    wd_logger 1 "Found ${#rac_id_line_list[@]} '[...]' lines in  ${FRPC_INI_FILE}: ${rac_id_line_list[*]}"
    if (( ${#rac_id_line_list[@]} == 1 )); then
        wd_logger 1 "ERROR: Found only one '[...]'' line in  ${FRPC_INI_FILE}: ${rac_id_line_list[0]}"
        return 3
    fi

    local frpc_ini_id="$(echo ${rac_id_line_list[1]} | sed 's/\[//;s/\]//')"
    wd_logger 1 "Found frpc_ini's RAC_ID = '${frpc_ini_id}'"

    local rac_port_line_list=( $(grep "^remote_port"  ${FRPC_INI_FILE}) )
    if (( ${#rac_port_line_list[@]} < 3 )); then 
        wd_logger 1 "ERROR: can't find valid 'remote_port' line"
        return 4
    fi
    local remote_port=${rac_port_line_list[2]}

    if (( remote_port < RAC_IP_PORT_BASE  || remote_port >= RAC_IP_PORT_MAX )); then
        wd_logger 1 "ERROR: remote_port ${remote_port} found in ${FRPC_INI_FILE} is invalid"
        return 5
    fi
    local frpc_ini_channel=$(( remote_port - RAC_IP_PORT_BASE )) 
    local return_value="${frpc_ini_channel} ${frpc_ini_id}"

    wd_logger 2 "The RAC ini file ${FRPC_INI_FILE} is configured to forward RAC '${frpc_ini_id}' from remote_port ${remote_port} to local port 22. Returning '${return_value}' to variable '${__return_variable_name}'"
    eval ${__return_variable_name}="\${return_value}"
    return 0
 }

function remote_access_connection_status() {
    local __remote_access_channel_var=$1
    local __remote_access_id_var=$2
    local rc

    wd_logger 2 "Starting"
    if [[ -f ${WSPRDAEMON_CONFIG_FILE} ]]; then
        wd_logger 2 "Reading existing ${WSPRDAEMON_CONFIG_FILE}"
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
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: there is a format error in ${WSPRDAEMON_CONFIG_FILE}"
        exit 1
    fi

    ### If REMOTE_ACCESS_CHANNEL is not defined in WD.conf, shut down the RAC
    local wd_conf_rac_channel

    wd_conf_rac_channel="${REMOTE_ACCESS_CHANNEL-}"
    if [[ -n "${wd_conf_rac_channel}" ]]; then
        wd_logger 2 "Found REMOTE_ACCESS_CHANNEL = '${REMOTE_ACCESS_CHANNEL}' is defined"
    else
        wd_logger 2 "Found no REMOTE_ACCESS_CHANNEL, so see if RAC is defined"
        if [[ -n "${RAC-}" ]]; then
            wd_logger 2 "Found RAC ='${RAC}'"
            wd_conf_rac_channel="${RAC}"
        fi
    fi

    local close_rac="no"
    if [[ -z "${wd_conf_rac_channel-}" ]]; then
        wd_logger 2 "Found that neither REMOTE_ACCESS_CHANNEL nor RAC is defined in ${WSPRDAEMON_CONFIG_FILE}, so we have ensured it isn't running"
        wd_conf_rac_channel=""
        close_rac="yes"
    else
        if  ! is_uint "${wd_conf_rac_channel-}";  then
            wd_logger 1 "ERROR: The RAC or REMOTE_ACCESS_CHANNEL defined in ${WSPRDAEMON_CONFIG_FILE} is not an INREGER, so we have ensured it isn't running"
            close_rac="yes"
        fi
    fi
    if [[  ${close_rac} == "no" ]]; then
        eval ${__remote_access_channel_var}=\${wd_conf_rac_channel}
        wd_logger 2 "Found REMOTE_ACCESS_CHANNEL=${wd_conf_rac_channel}" 

        local wd_conf_rac_id
        if [[ -n "${REMOTE_ACCESS_ID-}" ]]; then
            wd_logger 2 "Found REMOTE_ACCESS_ID='${REMOTE_ACCESS_ID} in conf file"
            wd_conf_rac_id=${REMOTE_ACCESS_ID}
        elif  [[ -n "${RAC_ID-}" ]]; then
            wd_logger 2 "Found RAC_ID='${RAC_ID} in conf file"
            wd_conf_rac_id=${RAC_ID}
        else
            local ka9q_reporter_id
            get_first_receiver_reporter  "ka9q_reporter_id"
            rc=$?
            if [[ ${rc} -ne 0 ]]; then
                wd_logger 1 "ERROR: couldn't find the wspr report ID of the first RECEIVER"
                close_rac="yes"
            else
                wd_logger 2 "Using the wspr report ID of the first RECEIVER '${ka9q_reporter_id}' as the RAC_ID"
                wd_conf_rac_id=${ka9q_reporter_id}
            fi
        fi
    fi
    if [[ ${close_rac} == "yes" ]]; then
        wd_logger 2 "Ensuring that RAC is closed"
        remote_access_connection_stop_and_disable
        return 0
    fi
    eval ${__remote_access_id_var}=\${wd_conf_rac_id}
    wd_logger 2 "Found REMOTE_ACCESS_ID=${wd_conf_rac_id}" 

    ### The RAC is enabled and configured in the WD.conf file. Check to see if it and the ID match the frpc_wd.ini
    ### Get the last REMOTE_ACCESS_ID or SIGNAL_LEVEL_UPLOAD_ID in the conf file and strip out any '"' characters in it
    if [[ ! -f ${FRPC_INI_FILE} ]]; then
        wd_logger 1 "The FRC .ini file ${FRPC_INI_FILE} doesn't exist, so it will need to be created"
        return 1
    fi
    wd_logger 2 "Checking .ini file ${FRPC_INI_FILE}"

    local frpc_ini_section_list=( "${wd_conf_rac_id},local_port:22,remote_port:$(( 35800 + wd_conf_rac_channel))"
                                  "${wd_conf_rac_id}-WEB,local_port:${KA9Q_WEB_SERVICE_PORT-8081},remote_port:$(( 35800 + 10000 + wd_conf_rac_channel))" )

    local frpc_ini_section
    for frpc_ini_section in ${frpc_ini_section_list[@]}; do
        local exepcted_section_info_list=( ${frpc_ini_section//,/ } )
        if (( ${#exepcted_section_info_list[@]} < 3  )); then
            wd_logger 1 "INTERNAL ERROR: expect at least 3 expected fields, but found only ${#exepcted_section_info_list[@]} fields"
            exit 1
        fi
        local section_name=${exepcted_section_info_list[0]}
        local section_string="$( sed -n "/\[${section_name}\]/,/^\[/p" ${FRPC_INI_FILE} )"
        if [[ -z "${section_string}" ]]; then
            wd_logger 1 "Can't find [${section_name}] in ${FRPC_INI_FILE} "
            return 1
        fi
        wd_logger 2 "Checking section ${section_name} for one or more expected <VARIABLE> = <VALUE> lines"
        wd_logger 3 "${section_string}"

        local serach_info_list=( ${exepcted_section_info_list[@]:1} )
        local search_info
        for search_info in ${serach_info_list[@]}; do
            local search_name_expected_value_list=( ${search_info[@]/:/ } )
            if (( ${#search_name_expected_value_list[@]} != 2  )); then
                wd_logger 1 "INTERNAL ERROR: expected 2 fields, but found ${#search_name_expected_value_list[@]} fields"
                exit 1
            fi
            local value_id=${search_name_expected_value_list[0]}
            local expected_value=${search_name_expected_value_list[1]}

            wd_logger 2 "Checking section '${section_name}' for ${value_id} = ${expected_value}"
            local search_name_line_list=( =$(echo "${section_string}" | grep ${value_id}) )
            if (( ${#search_name_line_list[@]} == 0 )); then
                wd_logger 1 "ERROR: can't find expected ${value_id} = <VALUE> line in an existing section ${section_name}"
                return 1
            fi
            if (( ${#search_name_line_list[@]} != 3 )); then
                wd_logger 1 "ERROR: can't find the 3 expected fields ${value_id} = <VALUE> in an existing section ${section_name}"
                return 1
            fi
            if [[ ${search_name_line_list[2]} ==  ${expected_value} ]]; then
                wd_logger 2 "Found in section ${section_name} the expected ${value_id} = ${expected_value}"
            else
                 wd_logger 1 "Found in section ${section_name}: ${value_id} = ${search_name_line_list[2]} instead of = ${expected_value}"
                 return 1
            fi
        done
    done
    wd_logger 2 "${FRPC_INI_FILE} exists and is properly configured.  Make sure the WD RAC service ${WD_REMOTE_ACCESS_SERVICE_NAME} is running"

    execute_sysctl_command is-active ${WD_REMOTE_ACCESS_SERVICE_NAME}
    rc=$? ; if (( rc )); then
        wd_logger 1 "The Remote Access Connection service is configured but not active"
        return 4
    fi
    wd_logger 2 "The ${WD_REMOTE_ACCESS_SERVICE_NAME} service is configured and active.  Checking the status of its connection"
    execute_sysctl_command status ${WD_REMOTE_ACCESS_SERVICE_NAME}  
    rc=$? ; if (( rc )); then
        wd_logger 1 "The ${WD_REMOTE_ACCESS_SERVICE_NAME} is configured but returns status ${rc}"
        return 5
    fi
    wd_logger 1 "The Remote Access Connection (RAC) service connected through RAC channel '${wd_conf_rac_channel}' with ID '${wd_conf_rac_id}' is configured, enabled and running"
    wd_logger 1 "So authorized WD devlopers can ssh to this server and a.so open the KSA9Q-web UI on this server (if there is a RX888 attached to it)"
    return 0
}

### If REVERSE_PROXY == "" (the default), disables and stops the ${WD_REMOTE_ACCESS_SERVICE_NAME}
### Else, if the ${WD_REMOTE_ACCESS_SERVICE_NAME} is not already running,  configure, enqble and start it
function wd_remote_access_service_manager() {
    local rc

    wd_logger 2 "Starting"

    if [[ -z "${REMOTE_ACCESS_CHANNEL-}" && ${HOSTNAME} =~ ^WSPRSONDE-GW- ]]; then
        ### Hostnames which start with "WSPSRSONDE-GW-nnn" are (typically) a Raspberry Pi 3b connected to the USB port of a Wspsrsonde-8
        ### Those Pi 3bs provoide a remote access gateway for mointoring and control of the WS-8 and only the wdremoteaccess service is automatically run on them, WD isn't running
        local ws_gw_number=${HOSTNAME#WSPRSONDE-GW-}
        local rac_channel=$(( ${WSPRSONDE_ID_BASE} + ${ws_gw_number} ))
        REMOTE_ACCESS_CHANNEL=${rac_channel}
        REMOTE_ACCESS_ID="${HOSTNAME}"
        wd_logger 1 "Automatically configuring WD's RAC on channel #${REMOTE_ACCESS_CHANNEL} => IP Port $(( ${RAC_IP_PORT_BASE} + ${REMOTE_ACCESS_CHANNEL} )) on a host named ${REMOTE_ACCESS_ID}"
    fi

    local remote_access_channel
    local remote_access_id
    remote_access_connection_status "remote_access_channel" "remote_access_id"
    rc=$? ; if (( rc == 0 )); then
        wd_logger 2 "Remote Access Connection service is not enabled, or it is enabled and running normally"
        return 0
    fi
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

    wd_logger 1 "Creating ${FRPC_INI_FILE}"
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

[${remote_access_id}-WEB]
type = tcp
local_ip = 127.0.0.1
local_port = ${KA9Q_WEB_SERVICE_PORT-8081}
remote_port = $(( frpc_remote_port + 10000 ))
EOF
    wd_logger 1 "Created frpc.ini which specifies connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this client's remote_access_id=${remote_access_id} and ssh port on port ${frpc_remote_port} of that server"
 
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
