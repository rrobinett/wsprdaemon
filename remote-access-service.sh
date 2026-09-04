#!/bin/bash

### This WD module implements WD's Remote Access Channel service which allows WD admins with access to ports on the wd0.wsprdaemon.org server to ssh to 
### WD devices running the Linux wsprdaemon_remote_access.service
###
### WD sites enable access by adding two lines to their wsprdaemon.conf file:
#
### REMOTE_ACCESS_CHANNEL=1           ### Defaults to "".  When it is an integer in the range 0-1000, allow the wsprdemon.org administrator ssh access to this WD server if you also provide a user/password on this server
### REMOTE_ACCESS_ID="KPH-Beelink-1"
#
# Hosts with names which start with "WSPRSONDE-" are gateways connected to Wsprsonde8 beacons, and those hosts are automatically set up to log on to this RAC service

declare WD_BIN_DIR=${WSPRDAEMON_ROOT_DIR}/bin
declare FRPC_CMD=${WD_BIN_DIR}/frpc
declare WD_FRPS_URL=${WD_FRPS_URL-remote.wsprdaemon.org}
declare HAMSCI_FRPS_URL=${HAMSCI_FRPS_URL-vpn.hamsci.org}
declare HAMSCI_RAC_MIN=200
declare HAMSCI_RAC_MAX=299
declare WD_FRPS_PORT=35735
declare FRP_REQUIRED_VERSION=${FRP_REQUIRED_VERSION-0.64.0}    ### Default to use FRP version 0.64.0 which is the current version running on WD0 on 8/21/25
declare FRPC_INI_FILE=${FRPC_CMD}.ini
declare WD_REMOTE_ACCESS_SERVICE_NAME="wd-remote-access"

### Since WD 3.4.6 the RAC is provided by the wd-rac-client package (https://github.com/rrobinett/wd-rac-client):
### one frpc tunnel to EACH WD gateway (gw2 primary, gw1 standby), on the authenticated frps-secure tier, with the
### station registered under its own node key.  WD still owns the decision through RAC= / REMOTE_ACCESS_CHANNEL=
### in wsprdaemon.conf: when it is set WD installs (or updates) that package and lets its installer (re)configure
### the tunnels -- idempotent, and add-before-remove when it replaces the legacy single tunnel below -- and when it
### is unset WD stops the tunnels.  The legacy frpc built into this file is kept only for the HamSCI RAC range
### (200-299, a different frps) and for channels outside what the WD registrar accepts (0-199, 300-999).
declare WD_RAC_CLIENT_REPO_URL=${WD_RAC_CLIENT_REPO_URL-https://github.com/rrobinett/wd-rac-client}
declare WD_RAC_CLIENT_DIR=${WD_RAC_CLIENT_DIR-${WSPRDAEMON_ROOT_DIR}/wd-rac-client}
declare WD_RAC_CLIENT_LOG=${WSPRDAEMON_ROOT_DIR}/wd-rac-client-install.log
declare WD_RAC_CLIENT_CONF_DIR=/etc/wd-remote-access
declare WD_RAC_CLIENT_INSTALL_UNIT=wd-rac-client-install
declare WD_RAC_CLIENT_INSTALL_TIMEOUT=${WD_RAC_CLIENT_INSTALL_TIMEOUT-180}    ### Seconds to wait for the installer before leaving it to finish in the background

### Remove all vestiges of the legacy name and implementation of the RAC client service
sudo systemctl stop wd_remote_access.service 2>/dev/null       || true
sudo systemctl disable wd_remote_access.service 2>/dev/null    || true
sudo rm -f /etc/systemd/system/wd_remote_access.service
sudo systemctl daemon-reload
sudo systemctl reset-failed wd_remote_access.service 2>/dev/null  || true
### Restart the new RAC client service if it was blocked by the legacy service we just killed
if systemctl is-enabled ${WD_REMOTE_ACCESS_SERVICE_NAME}.service &>/dev/null && ! systemctl is-active ${WD_REMOTE_ACCESS_SERVICE_NAME}.service &>/dev/null; then
    sudo systemctl restart ${WD_REMOTE_ACCESS_SERVICE_NAME}.service
fi

declare RAC_IP_PORT_BASE=35800    ### Don't change this!  As of 7/9/24 many WD servers have IDs which start here
declare RAC_GRAPE_PORT_OFFSET=5000    ### The registrar's vm_grape band: the GRAPE strip-chart web page of RAC n is at gateway port 40800+n (WD 3.4.6+)
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
    wd_rac_client_stop_and_disable
    wd_logger 2 "The Remote Access Connection (RAC) service has been stopped and disabled"
    return 0
}

### Is this channel served by the WD registrar and wd-rac-client (rather than one of the legacy paths)?
function wd_rac_client_channel_ok() {
    local channel=$1
    if (( channel >= HAMSCI_RAC_MIN && channel <= HAMSCI_RAC_MAX )); then
        return 1        ### HamSCI stations tunnel to vpn.hamsci.org with the legacy frpc
    fi
    if (( channel > 999 || ( channel > 199 && channel < 300 ) )); then
        return 1        ### e.g. the WSPRSONDE-GW-nnn channels >= 2200: the registrar does not know them
    fi
    return 0
}

### Stop the per-gateway tunnel instances (RAC= has been removed from the conf file)
function wd_rac_client_stop_and_disable() {
    local unit
    for unit in $(systemctl list-units --all --plain --no-legend 'wd-remote-access@*' 2>/dev/null | awk '{print $1}'); do
        wd_logger 1 "Disabling ${unit}"
        execute_sysctl_command "disable --now" ${unit}
    done
    return 0
}

### True when this GRAPE site should publish its carrier strip-chart page (grape-utils.sh) through the RAC
function wd_rac_grape_charts_wanted() {
    [[ -n "${GRAPE_PSWS_ID-}" && "${GRAPE_CHARTS_ENABLED-yes}" == "yes" ]]
}

### True when the installed wd-rac-client already serves this channel on every gateway: then there is nothing
### to do and no registrar round trip is made on this WD start
function wd_rac_client_is_current() {
    local channel=$1
    local ssh_port=$(( RAC_IP_PORT_BASE + channel ))
    local grape_port=$(( RAC_IP_PORT_BASE + RAC_GRAPE_PORT_OFFSET + channel ))
    local conf
    local found=0

    [[ -s ${WD_RAC_CLIENT_CONF_DIR}/VERSION ]] || return 1
    for conf in ${WD_RAC_CLIENT_CONF_DIR}/gateways/*.toml; do
        [[ -f ${conf} ]] || continue
        sudo grep -q "^remotePort = ${ssh_port}$" ${conf} || return 1      ### the RAC number changed in the conf file
        if wd_rac_grape_charts_wanted && ! sudo grep -q "^remotePort = ${grape_port}$" ${conf} ; then
            wd_logger 1 "${conf} has no tunnel for the GRAPE charts page (gateway port ${grape_port}), so the wd-rac-client installer will be re-run to add it"
            return 1
        fi
        local gw=${conf##*/}
        gw=${gw%.toml}
        systemctl is-active --quiet wd-remote-access@${gw}.service || return 1
        found=1
    done
    (( found ))
}

### Fetch the wd-rac-client package, or update a git checkout of it
function wd_rac_client_fetch() {
    if [[ -d ${WD_RAC_CLIENT_DIR}/.git ]]; then
        wd_logger 2 "Updating ${WD_RAC_CLIENT_DIR}"
        if ! timeout 60 git -C ${WD_RAC_CLIENT_DIR} pull -q --ff-only >& /tmp/wd-rac-client-git.txt; then
            wd_logger 1 "WARNING: 'git pull' in ${WD_RAC_CLIENT_DIR} failed, so using the copy already there: $(< /tmp/wd-rac-client-git.txt)"
        fi
        return 0
    fi
    if [[ -x ${WD_RAC_CLIENT_DIR}/install.sh ]]; then
        wd_logger 2 "${WD_RAC_CLIENT_DIR} is a tarball install, so it is not updated automatically"
        return 0
    fi
    wd_logger 1 "Installing the wd-rac-client package into ${WD_RAC_CLIENT_DIR}"
    if command -v git >& /dev/null; then
        if timeout 120 git clone -q ${WD_RAC_CLIENT_REPO_URL}.git ${WD_RAC_CLIENT_DIR} >& /tmp/wd-rac-client-git.txt; then
            return 0
        fi
        wd_logger 1 "WARNING: 'git clone' failed, so trying the tarball: $(< /tmp/wd-rac-client-git.txt)"
    fi
    local tmp_dir=$(mktemp -d)
    if ( cd ${tmp_dir} && timeout 120 curl -fsSL ${WD_RAC_CLIENT_REPO_URL}/archive/main.tar.gz | tar xz ) && [[ -d ${tmp_dir}/wd-rac-client-main ]]; then
        mv ${tmp_dir}/wd-rac-client-main ${WD_RAC_CLIENT_DIR}
        rm -rf ${tmp_dir}
        return 0
    fi
    rm -rf ${tmp_dir}
    wd_logger 1 "ERROR: could not download ${WD_RAC_CLIENT_REPO_URL}"
    return 1
}

### Install, upgrade or migrate to wd-rac-client for this channel.  The package's installer is run DETACHED from
### this shell: when WD itself is being started over the legacy tunnel, retiring that tunnel would kill a
### foreground installer half way (its rollback timer would recover the node, but only ten minutes later).
function wd_rac_client_manager() {
    local channel=$1
    local rac_id=$2
    local rc

    if wd_rac_client_is_current ${channel}; then
        wd_logger 2 "wd-rac-client $(< ${WD_RAC_CLIENT_CONF_DIR}/VERSION) already serves RAC ${channel} on every gateway"
        return 0
    fi
    wd_rac_client_fetch
    rc=$? ; if (( rc )); then
        return ${rc}
    fi

    ### The registrar wants site names of A-Z 0-9 _ - (3-32 chars), so 'KFS/OMNI' becomes 'KFS-OMNI'
    local site=$( echo "${rac_id}" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9_-]/-/g' )
    local ssh_port=22
    local sshd_config_port=$( awk '/^Port /{print $2}' /etc/ssh/sshd_config 2>/dev/null )
    if [[ -n "${sshd_config_port}" ]]; then
        ssh_port=${sshd_config_port}
    fi
    local proxies="vm_ssh=${ssh_port} vm_web=${KA9Q_WEB_SERVICE_PORT-8081}"    ### the same two tunnels the legacy .ini published
    if wd_rac_grape_charts_wanted; then
        proxies+=" vm_grape=${GRAPE_CHARTS_PORT-8088}"                          ### WD 3.4.6+: the GRAPE carrier strip-chart page, at gateway port 40800+RAC
    fi

    wd_logger 1 "Configuring wd-rac-client for RAC ${channel}, site '${site}', tunnels '${proxies}' (installer log: ${WD_RAC_CLIENT_LOG})"
    sudo systemctl stop ${WD_RAC_CLIENT_INSTALL_UNIT}.service 2>/dev/null || true
    sudo systemd-run --quiet --collect --unit=${WD_RAC_CLIENT_INSTALL_UNIT} \
        --property=WorkingDirectory=${WD_RAC_CLIENT_DIR} \
        --setenv=WD_RAC_SITE="${site}" --setenv=WD_RAC_NUMBER=${channel} \
        --setenv=WD_RAC_PROXIES="${proxies}" --setenv=WD_RAC_RETIRE_LEGACY=managed \
        /bin/bash -c "./install.sh > ${WD_RAC_CLIENT_LOG} 2>&1"
    rc=$? ; if (( rc )); then
        wd_logger 1 "ERROR: could not start the wd-rac-client installer: 'systemd-run' => ${rc}"
        return ${rc}
    fi
    local waited=0
    while systemctl is-active --quiet ${WD_RAC_CLIENT_INSTALL_UNIT}.service; do
        if (( waited >= WD_RAC_CLIENT_INSTALL_TIMEOUT )); then
            wd_logger 1 "The wd-rac-client installer is still running after ${waited} seconds, so leaving it to finish in the background (see ${WD_RAC_CLIENT_LOG})"
            return 0
        fi
        sleep 5
        waited=$(( waited + 5 ))
    done
    if grep -q '^SUCCESS' ${WD_RAC_CLIENT_LOG} 2>/dev/null; then
        wd_logger 1 "wd-rac-client is running: $( grep -E '^Tunnels|^    gw' ${WD_RAC_CLIENT_LOG} | tr '\n' ' ' )"
        wd_logger 1 "So authorized WD developers can ssh to this server at IP port $(( RAC_IP_PORT_BASE + channel )) and open its KA9Q-web UI at port $(( RAC_IP_PORT_BASE + channel + 10000 )) on either gateway"
        if wd_rac_grape_charts_wanted; then
            wd_logger 1 "The GRAPE carrier strip charts of this server are at gateway port $(( RAC_IP_PORT_BASE + RAC_GRAPE_PORT_OFFSET + channel ))"
        fi
        return 0
    fi
    wd_logger 1 "ERROR: the wd-rac-client installer did not report success.  Last lines of ${WD_RAC_CLIENT_LOG}: $( tail -n 5 ${WD_RAC_CLIENT_LOG} 2>/dev/null | tr '\n' '|' )"
    return 1
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
            wd_logger 1 "ERROR: The RAC or REMOTE_ACCESS_CHANNEL defined in ${WSPRDAEMON_CONFIG_FILE} is not an INTEGER, so we have ensured it isn't running"
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
    if [[ "$wd_conf_rac_id" =~ [[:space:]] ]]; then
        wd_logger 1 "ERROR:  RAC '${wd_conf_rac_id}' cannot contain 'space' characters"
        exit 1
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

    local wd0_rac_ssh_ip_port=$(( 35800 + wd_conf_rac_channel ))
    local wd0_rac_web_ip_port=$(( wd0_rac_ssh_ip_port + 10000 ))
    local frpc_ini_section_list=( "${wd_conf_rac_id},local_port:22,remote_port:${wd0_rac_ssh_ip_port}"
                                  "${wd_conf_rac_id}-WEB,local_port:${KA9Q_WEB_SERVICE_PORT-8081},remote_port:${wd0_rac_web_ip_port}")

    local frpc_ini_section
    for frpc_ini_section in ${frpc_ini_section_list[@]}; do
        local expected_section_info_list=( ${frpc_ini_section//,/ } )
        if (( ${#expected_section_info_list[@]} < 3  )); then
            wd_logger 1 "INTERNAL ERROR: expected at least 3 fields, but found only ${#expected_section_info_list[@]} fields"
            exit 1
        fi
        local section_name=${expected_section_info_list[0]}
        local section_string="$( sed -n "/\[${section_name//\//[/]}\]/,/^\[/p" ${FRPC_INI_FILE} )"        ### A lot of sed regex work so sections can have very common RAC names with '/' like 'KFS/OMNI'
        if [[ -z "${section_string}" ]]; then
            wd_logger 1 "Can't find [${section_name}] in ${FRPC_INI_FILE} "
            return 1
        fi
        wd_logger 2 "Checking section ${section_name} for one or more expected <VARIABLE> = <VALUE> lines"
        wd_logger 3 "${section_string}"

        local search_info_list=( ${expected_section_info_list[@]:1} )
        local search_info
        for search_info in ${search_info_list[@]}; do
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
    wd_logger 1 "So authorized WD developers can ssh to this server at IP port ${wd0_rac_ssh_ip_port} and also open the KA9Q-web UI on this server (if there is a RX888 attached to it) at ${wd0_rac_web_ip_port=}"
    return 0
}

### If REVERSE_PROXY == "" (the default), disables and stops the ${WD_REMOTE_ACCESS_SERVICE_NAME}
### Else, if the ${WD_REMOTE_ACCESS_SERVICE_NAME} is not already running,  configure, enable and start it
function wd_remote_access_service_manager() {
    local rc

    wd_logger 2 "Starting"

    if [[ -z "${REMOTE_ACCESS_CHANNEL-}" && ${HOSTNAME} =~ ^WSPRSONDE-GW- ]]; then
        ### Hostnames which start with "WSPSRSONDE-GW-nnn" are (typically) a Raspberry Pi 3b connected to the USB port of a Wspsrsonde-8
        ### Those Pi 3bs provide a remote access gateway for monitoring and control of the WS-8 and only the wd_remote_access_service is automatically run on them, WD isn't running
        local ws_gw_number=${HOSTNAME#WSPRSONDE-GW-}
        local rac_channel=$(( ${WSPRSONDE_ID_BASE} + ${ws_gw_number} ))
        REMOTE_ACCESS_CHANNEL=${rac_channel}
        REMOTE_ACCESS_ID="${HOSTNAME}"
        wd_logger 1 "Automatically configuring WD's RAC on channel #${REMOTE_ACCESS_CHANNEL} => IP Port $(( ${RAC_IP_PORT_BASE} + ${REMOTE_ACCESS_CHANNEL} )) on a host named ${REMOTE_ACCESS_ID}"
    fi

    local remote_access_channel
    local remote_access_id

    remote_access_connection_status "remote_access_channel" "remote_access_id"
    rc=$?

    ### Channels the WD registrar serves get the wd-rac-client package (dual-gateway tunnels); this also migrates
    ### a station off the legacy single tunnel below, even when that one is configured and running normally
    if [[ -n "${remote_access_channel-}" ]] && wd_rac_client_channel_ok ${remote_access_channel}; then
        wd_rac_client_manager ${remote_access_channel} "${remote_access_id}"
        return $?
    fi

    if (( rc == 0 )); then
        wd_logger 2 "Remote Access Connection service is not enabled, or it is enabled and running normally"
        return 0
    fi
    wd_logger 1 "Setting up the legacy Remote Access Connection service with REMOTE_ACCESS_CHANNEL=${remote_access_channel}, REMOTE_ACCESS_ID='${remote_access_id}'"

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
    local rac_url="${WD_FRPS_URL}"
    if (( (remote_access_channel >= HAMSCI_RAC_MIN) &&  (remote_access_channel <= HAMSCI_RAC_MAX) )); then
        rac_url="${HAMSCI_FRPS_URL}"
    fi

    wd_logger 1 "Creating ${FRPC_INI_FILE}"
    cat > ${FRPC_INI_FILE} <<EOF
[common]
admin_addr = 127.0.0.1
admin_port = 7500
server_addr = ${rac_url}
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
    wd_logger 1 "Created ${FRPC_INI_FILE} which specifies connecting to ${WD_FRPS_URL}:${WD_FRPS_PORT} and sharing this client's remote_access_id=${remote_access_id} and ssh port on port ${frpc_remote_port} of that server"
 
    local rc
    setup_wd_remote_access_systemctl_daemon
}

### Configure systemctl so this watchdog daemon runs at startup of the Pi
declare -r WD_REMOTE_ACCESS_DAEMON_CMD="${WSPRDAEMON_ROOT_DIR}/wd-remote-access-daemon.sh"
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
Description=Wsprdaemon Remote Access Channel daemon
After=network.target

[Service]
Type=simple
User=${USER}
Group=$(id -gn)
WorkingDirectory=${HOME}/wsprdaemon/bin
ExecStart=${HOME}/wsprdaemon/wd-remote-access-daemon.sh
Restart=always
RestartSec=10s
TimeoutStartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

   wd_logger 2 "Installing the ${WD_REMOTE_ACCESS_SERVICE_NAME} service"
   sudo mv ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_FILE} ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_PATH}    ### 'sudo cat > ${WD_REMOTE_ACCESS_SYSTEMCTL_UNIT_PATH} gave me permission errors
   execute_sysctl_command daemon-reload  ""
   rc=$? ; if (( rc )); then
       wd_logger 1 "ERROR: 'execute_sysctl_command daemon-reload' => ${rc}"
       return ${rc}
   fi
   execute_sysctl_command enable ${WD_REMOTE_ACCESS_SERVICE_NAME}
   rc=$? ; if (( rc )); then
       wd_logger 1 "ERROR: 'execute_sysctl_command enable ${WD_REMOTE_ACCESS_SERVICE_NAME}' => ${rc}"
       return ${rc}
   fi
   execute_sysctl_command start  ${WD_REMOTE_ACCESS_SERVICE_NAME}
   rc=$? ; if (( rc )); then
       wd_logger 1 "ERROR: 'execute_sysctl_command start ${WD_REMOTE_ACCESS_SERVICE_NAME}' => ${rc}"
       return ${rc}
   fi
   wd_logger 1 "The Remote Access Connection service has been installed and started"
   return 0
}
