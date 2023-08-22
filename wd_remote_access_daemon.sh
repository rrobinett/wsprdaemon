#!/bin/bash
#
### This function is executed by systemctl to start and stop a remote access connection  in the ~/wsprdsaemon/bin directory

declare FRPC_CMD=./frpc
declare FRPC_INI_FILE=${FRPC_CMD}_wd.ini
declare FRPC_ERROR_SLEEP_SECS=10   ### Wait this long after a connection fails before retrying the connection

function wd_remote_access_daemon() {
    echo "Starting with args '$@'"
    if [[ "${1-}" == "-A" ]] ; then
        echo "Starting" 
        local rc
        ${FRPC_CMD} -c ${FRPC_INI_FILE} &
        rc=$?
        if [[ ${rc} -ne 0 ]]; then
            echo "ERROR: '${FRPC_CMD} -c ${FRPC_INI_FILE} &' => ${rc}.  Sleep ${FRPC_ERROR_SLEEP_SECS} and try to connect once again"
        fi
    else
        echo "Stopping"
    fi
    return 0
}

wd_remote_access_daemon $@
