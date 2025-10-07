#!/bin/bash

function wait_for_clickhouse_ready() {
    local max_retries=${1:-30}
    local retry=0
    
    wd_logger 1 "Waiting for ClickHouse to be ready..."
    
    while (( retry < max_retries )); do
        # Check if service is active
        if ! sudo systemctl is-active --quiet clickhouse-server; then
            wd_logger 1 "Service not active yet (attempt $((retry+1))/$max_retries)"
        else
            # Service is active, try to connect (first without password, then with)
            if clickhouse-client --query "SELECT 1" &>/dev/null || \
               clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "SELECT 1" &>/dev/null; then
                wd_logger 1 "ClickHouse is ready and responding to queries"
                return 0
            fi
            wd_logger 1 "Service active but not responding to queries yet (attempt $((retry+1))/$max_retries)"
        fi
        
        sleep 2
        ((retry++))
    done
    
    wd_logger 1 "ClickHouse did not become ready after $max_retries attempts"
    sudo systemctl status clickhouse-server --no-pager
    return 1
}

function install_clickhouse_service() {
    wd_logger 1 "Updating package lists..."
    sudo apt update

    wd_logger 1 "Installing prerequisites..."
    sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

    wd_logger 1 "Adding ClickHouse GPG key..."
    curl -fsSL 'https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key' | \
        sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg

    wd_logger 1 "Adding ClickHouse repository to apt sources.list..."
    echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | \
        sudo tee /etc/apt/sources.list.d/clickhouse.list

    wd_logger 1 "Updating package lists with ClickHouse repository..."
    sudo apt update

    # Install ClickHouse
    wd_logger 1 "Installing ClickHouse packages..."
    local ch_version=${CH_VERSION-25.8.8.26}   ### This is the latest LTS version as of 10/3/25
    sudo DEBIAN_FRONTEND=noninteractive apt install -y clickhouse-server=${ch_version} clickhouse-client=${ch_version} clickhouse-common-static=${ch_version}
    local install_rc=$?
    if (( install_rc )); then
        wd_logger 1 "ERROR: ClickHouse installation failed with exit code ${install_rc}"
        return ${install_rc}
    fi

    # Configure data directory before first start
    wd_logger 1 "Configuring data directory to /src/wd_data/clickhouse..."
    sudo mkdir -p /src/wd_data/clickhouse
    sudo chown -R clickhouse:clickhouse /src/wd_data/clickhouse
    sudo chmod 700 /src/wd_data/clickhouse

    # Create config override for data path
    sudo tee /etc/clickhouse-server/config.d/data-path.xml > /dev/null <<'EOF'
<clickhouse>
    <path>/src/wd_data/clickhouse/</path>
</clickhouse>
EOF
    sudo chown clickhouse:clickhouse /etc/clickhouse-server/config.d/data-path.xml
    sudo chmod 640 /etc/clickhouse-server/config.d/data-path.xml

    # Start and enable service
    wd_logger 1 "Starting ClickHouse service..."
    sudo systemctl start clickhouse-server
    sudo systemctl enable clickhouse-server

    # Wait for service to be ready
    wait_for_clickhouse_ready 30
    local rc=$?
    if (( rc )); then
        wd_logger 1 "ERROR: ClickHouse did not become ready"
        return ${rc}
    fi

    # Set the password for the default user by creating a password file
    wd_logger 1 "Setting password for default user..."
    local password_sha256=$(echo -n "${CLICKHOUSE_DEFAULT_USER_PASSWORD}" | sha256sum | awk '{print $1}')
    sudo tee /etc/clickhouse-server/users.d/default-password.xml > /dev/null <<EOF
<clickhouse>
    <users>
        <default>
            <password remove="1"/>
            <password_sha256_hex>${password_sha256}</password_sha256_hex>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
        </default>
    </users>
</clickhouse>
EOF

    # Set correct ownership and permissions
    sudo chown clickhouse:clickhouse /etc/clickhouse-server/users.d/default-password.xml
    sudo chmod 640 /etc/clickhouse-server/users.d/default-password.xml

    # Restart ClickHouse to apply the password
    wd_logger 1 "Restarting ClickHouse to apply password..."
    sudo systemctl restart clickhouse-server

    # Wait for it to be ready again
    wait_for_clickhouse_ready 30
    rc=$?
    if (( rc )); then
        wd_logger 1 "ERROR: ClickHouse did not become ready after password configuration"
        return ${rc}
    fi

    wd_logger 1 "Password set successfully"

    # Create databases
    wd_logger 1 "Creating databases..."
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_WSPRNET_DATABASE_NAME}"
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "CREATE DATABASE IF NOT EXISTS ${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}"

    # Create application users with passwords
    wd_logger 1 "Creating application users..."
    
    # wsprnet-admin (read/write, localhost only)
    local wsprnet_admin_sha256=$(echo -n "${CLICKHOUSE_WSPRNET_ADMIN_PASSWORD}" | sha256sum | awk '{print $1}')
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "CREATE USER IF NOT EXISTS '${CLICKHOUSE_WSPRNET_ADMIN_USR}' IDENTIFIED WITH sha256_hash BY '${wsprnet_admin_sha256}' HOST IP '127.0.0.1', '::1'"
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "GRANT ALL ON ${CLICKHOUSE_WSPRNET_DATABASE_NAME}.* TO '${CLICKHOUSE_WSPRNET_ADMIN_USR}'"
    
    # wsprnet (read-only)
    local wsprnet_ro_sha256=$(echo -n "${CLICKHOUSE_WSPRNET_USER_PASSWORD}" | sha256sum | awk '{print $1}')
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "CREATE USER IF NOT EXISTS '${CLICKHOUSE_WSPRNET_USER}' IDENTIFIED WITH sha256_hash BY '${wsprnet_ro_sha256}'"
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "GRANT SELECT ON ${CLICKHOUSE_WSPRNET_DATABASE_NAME}.* TO '${CLICKHOUSE_WSPRNET_USER}'"
    
    # wsprdaemon-admin (read/write, localhost only)
    local wsprdaemon_admin_sha256=$(echo -n "${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD}" | sha256sum | awk '{print $1}')
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "CREATE USER IF NOT EXISTS '${CLICKHOUSE_WSPRDAEMON_ADMIN_USER}' IDENTIFIED WITH sha256_hash BY '${wsprdaemon_admin_sha256}' HOST IP '127.0.0.1', '::1'"
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "GRANT ALL ON ${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}.* TO '${CLICKHOUSE_WSPRDAEMON_ADMIN_USER}'"
    
    # wsprdaemon (read-only)
    local wsprdaemon_ro_sha256=$(echo -n "${CLICKHOUSE_WSPRDAEMON_USER_PASSWORD}" | sha256sum | awk '{print $1}')
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "CREATE USER IF NOT EXISTS '${CLICKHOUSE_WSPRDAEMON_USER}' IDENTIFIED WITH sha256_hash BY '${wsprdaemon_ro_sha256}'"
    clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "GRANT SELECT ON ${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME}.* TO '${CLICKHOUSE_WSPRDAEMON_USER}'"

    wd_logger 1 "Databases and users created successfully"

    # Log the installed version
    local version=$(clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "SELECT version()" 2>/dev/null)
    wd_logger 1 "ClickHouse ${version} installed and verified successfully"
    wd_logger 1 ""
    wd_logger 1 "Data directory: /src/wd_data/clickhouse"
    wd_logger 1 ""
    wd_logger 1 "Databases created:"
    wd_logger 1 "  - ${CLICKHOUSE_WSPRNET_DATABASE_NAME} (users: ${CLICKHOUSE_WSPRNET_ADMIN_USR} [rw, localhost], ${CLICKHOUSE_WSPRNET_USER} [ro])"
    wd_logger 1 "  - ${CLICKHOUSE_WSPRDAEMON_DATABASE_NAME} (users: ${CLICKHOUSE_WSPRDAEMON_ADMIN_USER} [rw, localhost], ${CLICKHOUSE_WSPRDAEMON_USER} [ro])"
    wd_logger 1 ""
    wd_logger 1 "Default user (localhost only):"
    wd_logger 1 "  clickhouse-client --password '${CLICKHOUSE_DEFAULT_USER_PASSWORD}'"
    wd_logger 1 ""
    wd_logger 1 "Web interface (localhost only):"
    wd_logger 1 "  http://localhost:8123/play"

    return 0
}

function verify_clickhouse_installation() {
    wd_logger 1 "Verifying ClickHouse installation..."
    wait_for_clickhouse_ready 10
    return $?
}

function install_clickhouse() 
{
    wd_logger 2 "Checking ClickHouse installation status..."
    
    # Check if ClickHouse is already installed and running
    if command -v clickhouse-server &> /dev/null; then
        wd_logger 2 "ClickHouse server found, checking if it's running..."
    else
        wd_logger 2 "The 'clickhouse-server' command is not present, so install Clickhouse"
        install_clickhouse_service
        local rc=$?; if (( rc )); then
            wd_logger 1 "Failed to install the missing Clickhouser service"
            exit 1
        fi
        wd_logger 1 "Installed the missing Clickhouse service"
    fi
    if systemctl is-active --quiet clickhouse-server 2>/dev/null; then
        wd_logger 2 "ClickHouse is installed and running"
        if clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "SELECT 1" &> /dev/null; then
            ### CH's default user has a password
            wd_logger 2 "ClickHouse is responding to queries by its 'default'(i.e. 'root') user using the password '${CLICKHOUSE_DEFAULT_USER_PASSWORD}' defined in WD.conf"
            return 0
        fi
        if clickhouse-client --query "SELECT 1" &> /dev/null; then
            wd_logger 2 "ClickHouse is responding to queries, but the default user has no password, so set it to '${CLICKHOUSE_DEFAULT_USER_PASSWORD}' "
            # Set password using the same method as install_clickhouse_service
            local password_sha256=$(echo -n "${CLICKHOUSE_DEFAULT_USER_PASSWORD}" | sha256sum | awk '{print $1}')
            sudo tee /etc/clickhouse-server/users.d/default-password.xml > /dev/null <<EOF
<clickhouse>
    <users>
        <default>
            <password remove="1"/>
            <password_sha256_hex>${password_sha256}</password_sha256_hex>
            <networks>
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
        </default>
    </users>
</clickhouse>
EOF
            sudo chown clickhouse:clickhouse /etc/clickhouse-server/users.d/default-password.xml
            sudo chmod 640 /etc/clickhouse-server/users.d/default-password.xml
            sudo systemctl restart clickhouse-server
            sleep 3
            if clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "SELECT 1" &> /dev/null; then
                wd_logger 1 "Set the default user's password to '${CLICKHOUSE_DEFAULT_USER_PASSWORD}'"
                return 0
            fi
            wd_logger 1 "ERROR: Failed to set the default user's password to '${CLICKHOUSE_DEFAULT_USER_PASSWORD}'"
            return 1 
        else
            wd_logger 1 "ClickHouse is running but not responding to queries, so attempting to restart service..."
            sudo systemctl restart clickhouse-server
            sleep 3

            if clickhouse-client --password ${CLICKHOUSE_DEFAULT_USER_PASSWORD} --query "SELECT 1" &> /dev/null; then
                wd_logger 1 "ClickHouse is now responding"
                return 0
            else
                wd_logger 1 "ClickHouse still not responding, manual intervention needed"
                return 1
            fi
        fi
    fi
    wd_logger 1 "ClickHouse is installed but not running, starting service..."
    sudo systemctl start clickhouse-server
    sudo systemctl enable clickhouse-server
    sleep 3

    if systemctl is-active --quiet clickhouse-server; then
        wd_logger 1 "ClickHouse service started successfully"
        return 0
    else
        wd_logger 1 "Failed to start ClickHouse service"
        return 1
    fi
}

if [[ ${HOSTNAME:0:2} == "WD" ]]; then
    if [[ "$HOSTNAME" == "WD0" ]] || [[ "$HOSTNAME" == "WD00" ]]; then
        wd_logger 2 "Don't install Clickhouse on WD0 or WD00"
    else
        if [[ -z "${CLICKHOUSE_DEFAULT_USER_PASSWORD-}" ]]; then
            wd_logger 1 "ERROR: The password for the Clickhouse database service needed on this server has not been defined in wsprdaemon.conf.\nTo define it, add to wsprdaemon.conf the line: CLICKHOUSE_DEFAULT_USER_PASSWORD=\"<SOME_OBSCURE_PASSWORD>\""
            exit 1
        fi
        # Check for required application passwords
        if [[ -z "${CLICKHOUSE_WSPRNET_ADMIN_PASSWORD-}" ]] || [[ -z "${CLICKHOUSE_WSPRNET_USER_PASSWORD-}" ]] || \
           [[ -z "${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD-}" ]] || [[ -z "${CLICKHOUSE_WSPRDAEMON_USER_PASSWORD-}" ]]; then
            wd_logger 1 "ERROR: Application user passwords not defined in wsprdaemon.conf."
            wd_logger 1 "Required variables:"
            wd_logger 1 "  CLICKHOUSE_WSPRNET_ADMIN_PASSWORD=\"<password>\""
            wd_logger 1 "  CLICKHOUSE_WSPRNET_USER_PASSWORD=\"<password>\""
            wd_logger 1 "  CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD=\"<password>\""
            wd_logger 1 "  CLICKHOUSE_WSPRDAEMON_USER_PASSWORD=\"<password>\""
            exit 1
        fi
        wd_logger 2 "Check for Clickhouse and install it with the default user's password '${CLICKHOUSE_DEFAULT_USER_PASSWORD}'"
        install_clickhouse
    fi
else
     wd_logger 2 "Running on a client, so don't install Clickhouse"
fi
