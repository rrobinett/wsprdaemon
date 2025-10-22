
if [[ -f ~/wsprdaemon/bash-aliases ]]; then
    source ~/wsprdaemon/bash-aliases
fi

function add-rsync-client() {
    local client="$1"
    local pubkey="$2"
    local base="/srv/wd-uploads"

    if [[ -z "$client" || -z "$pubkey" ]]; then
        echo "Usage: add_rsync_client <client_name> <ssh_pubkey_file>"
        return 1
    fi

    # Create client system user (no shell, no password)
    sudo useradd -m -d "$base/$client" -s /usr/sbin/nologin "$client"

    # Create upload directory
    sudo mkdir -p "$base/$client"
    sudo chown "$client:$client" "$base/$client"
    sudo chmod 750 "$base/$client"

    # Setup SSH directory for the client
    sudo -u "$client" mkdir -p "$base/$client/.ssh"
    sudo chmod 700 "$base/$client/.ssh"

    # Install client public key with rsync-only restriction
    sudo bash -c "echo 'command=\"/usr/bin/rsync --server --sender -logDtprze.iLsfxC .\" $(cat "$pubkey")' >> $base/$client/.ssh/authorized_keys"

    sudo chmod 600 "$base/$client/.ssh/authorized_keys"
    sudo chown -R "$client:$client" "$base/$client/.ssh"

    echo "✅ Client '$client' added."
    echo "Upload path: rsync -avz file.tar $client@$(hostname -f):$base/$client/"
}

### ================= Setup a RAC client to upload WD spot and noise files =======================

declare SSR_CONF_FILE=~/.ssr.conf             ### Default to load the WD conf file
declare SSR_CONF_LOCAL_FILE=~/.ssr.conf.local   ### If present contains additional logins

###  Returns 0 if arg is an unsigned integer, else 1
function is_int()  { if [[ "$1" =~ ^-?[0-9]+$ ]]; then return 0; else return 1; fi }
function is_uint() { if [[ "$1" =~   ^[0-9]+$ ]]; then return 0; else return 1; fi }

function ssr_channel_id_to_rac_list_index() {
    local -n __return_rac_index=$1
    local wanted_rac_channel_id=$2

    local ssr_entry_index
    for (( ssr_entry_index=0; ssr_entry_index < ${#FRPS_REMOTE_ACCESS_LIST[@]}; ++ssr_entry_index )); do
        local rac_entry_list=(${FRPS_REMOTE_ACCESS_LIST[${ssr_entry_index}]//,/ })
        local entry_rac_channel_id=${rac_entry_list[0]}
        if [[ ${entry_rac_channel_id} == ${wanted_rac_channel_id} ]]; then
            (( ${verbosity-0} > 1 )) && echo "Found RAC_ID ${wanted_rac_channel_id} in FRPS_REMOTE_ACCESS_LIST[${ssr_entry_index}]" 1>&2
            __return_rac_index=${ssr_entry_index}
            return 0
        fi
    done
    (( ${verbosity-0} )) && echo "Couldn't find RAC_ID ${wanted_rac_channel_id} in FRPS_REMOTE_ACCESS_LIST[${ssr_entry_index}]" 1>&2
    __return_rac_index=-1
    return 0
 }

 ### Given:   RAC_ID
 ### Returns: that server's WD user and password
function wd-ssr-client-lookup()
{
    local -n __client_user_name=$1
    local -n __client_user_password=$2
    local rac_id="${3-}"
    if ! is_uint ${rac_id}; then
        echo "ERROR: the RAC argument '${rac_id}' is not an unsigned integer"
        return 1
    fi

    if ! [[ ${SSR_CONF_FILE} ]]; then
        echo "ERROR: ' '${SSR_CONF_FILE}' file does not exist on this server"
        return 1
    fi

    (( ${verbosity-0} > 1 )) && echo "Reading '${SSR_CONF_FILE}' file"
    source ${SSR_CONF_FILE}

    if [[ -f ${SSR_CONF_LOCAL_FILE} ]]; then
        (( ${verbosity-0} )) && echo "Reading '${SSR_CONF_FILE}' file"
        source ${SSR_CONF_LOCAL_FILE}
    fi

    local rac_list_index
    ssr_channel_id_to_rac_list_index "rac_list_index" ${rac_id}
    rc=$? ; if (( rc < 0 )); then
        echo "ERROR: can't find RAC ${rac_id}"
    fi
    (( ${verbosity-0} > 1 )) && echo "Found that RAC_ID=${rac_id} is found in FRPS_REMOTE_ACCESS_LIST[${rac_list_index}]: '${FRPS_REMOTE_ACCESS_LIST[${rac_list_index}]}'"

    local user_password_list=( $( echo "${FRPS_REMOTE_ACCESS_LIST[${rac_list_index}]}" | cut -d',' -f5) )
    local rac_client_user_name=${user_password_list[0]}
    local rac_client_user_password=${user_password_list[1]}
    (( ${verbosity-0} > 1 )) && echo "Found that RAC_ID=${rac_id} reports that its WD Linux client's user name is '${rac_client_user_name}' and password is '${rac_client_user_password}'"

    __client_user_name=${rac_client_user_name}
    __client_user_password=${rac_client_user_password}

    return 0
}

WD_RAC_SERVER="wd0"

function wd-client-to-server-setup()
{
    local client_rac=$1
    local client_user=${2-wsprdaemon}
    local client_ip_port=$(( 35800 + client_rac ))
    local rc

    local client_user_password
    wd-ssr-client-lookup "client_user_name" "client_user_password" ${client_rac}
    rc=$? ; if (( rc )); then
        echo "ERROR: can't find user with RAC ${client_rac} in .ssr.conf"
        return 1
    fi

    (( ${verbosity-0} > 1 )) && echo "Testing to see if RAC client has already setup so we can autologin"

    ping -c1 ${WD_RAC_SERVER} >/dev/null 2>&1 
    rc=$? ; if (( rc )); then
        echo "Can't ping the RAC server '${WD_RAC_SERVER}', so can't even test if the client is connected"
        return 1
    fi

    nc -zv wd0 ${client_ip_port} >/dev/null 2>&1
    rc=$? ; if (( rc )); then
        echo "Client with RAC=${client_rac} is not connected to ${WD_RAC_SERVER}:${client_ip_port}, so we can't get its public key"
        return 1
    fi
    (( ${verbosity-0} > 1 )) && echo "Client with RAC=${client_rac} is connected, so we should be able to get its public key"
    
    ssh -o BatchMode=yes -o ConnectTimeout=5 ${client_user}@${WD_RAC_SERVER} -p ${client_ip_port}  true >/dev/null 2>&1
    rc=$? ; if (( rc == 0 )); then
        (( ${verbosity-0} > 1 )) && echo "The RAC is open and we can autologin to '${client_user}@${WD_RAC_SERVER} -p ${client_ip_port}', so get its public key"
    else
        (( ${verbosity-0} > 1 )) && echo "The RAC is open but we can't autologin to '${client_user}@${WD_RAC_SERVER} -p ${client_ip_port}', so try a password login as user ${client_user} with password ${client_user_password}"
        ssh-copy-id -p ${client_ip_port} ${client_user}@${WD_RAC_SERVER}
        rc=$? ; if (( rc )); then
            echo "'ssh-copy-id ${client_user}@${WD_RAC_SERVER} -p ${client_ip_port} failed, so we need to get the correct user/password from client"
            return 1
        fi
        (( ${verbosity-0} > 1 )) && echo "'ssh-copy-id ${client_user}@${WD_RAC_SERVER} -p ${client_ip_port}' succeeded, so get the client's public key"
    fi
    local clients_pub_file_path=$(ssh -p ${client_ip_port} ${client_user}@${WD_RAC_SERVER} "ls ~/.ssh/*.pub | head -n1" )
    if [[ -z "${clients_pub_file_path}" ]]; then
        echo "ERROR: can't find any expecxted pub files on RAC ${client_rac}"
        return 1
    fi
    scp -P ${client_ip_port} ${client_user}@${WD_RAC_SERVER}:"${clients_pub_file_path}" /tmp/rac_${client_rac}_key.pub >/dev/null
    rc=$? ; if (( rc )); then
        echo "'scp -P ${client_ip_port} ${client_user}@${WD_RAC_SERVER}:${clients_pub_file_path}' => ${rc}"
        return 1
    fi
    (( ${verbosity-0} )) && echo "A copy of RAC#${client_rac} pub file has been saved in /tmp/rac_${client_rac}_key.pub"
}
