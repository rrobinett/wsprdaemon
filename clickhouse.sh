#!/bin/bash

function install_clickhouse_debian() {
    local configure_password="$1"
    local ch_password="$2"
    
    wd_logger 1 "Installing ClickHouse on Debian/Ubuntu..."
    
    # Update system
    wd_logger 1 "Updating package lists..."
    sudo apt update
    
    # Install required packages
    wd_logger 1 "Installing prerequisites..."
    sudo apt install -y apt-transport-https ca-certificates curl gnupg lsb-release
    
    # Add ClickHouse GPG key (modern method)
    wd_logger 1 "Adding ClickHouse GPG key..."
    curl -fsSL https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key | \
        sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg
    
    # Add repository
    wd_logger 1 "Adding ClickHouse repository..."
    wd_logger 1 "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb stable main" | \
        sudo tee /etc/apt/sources.list.d/clickhouse.list
    
    # Update package list
    sudo apt update
    
    # Handle password configuration
    if [[ "$configure_password" == "true" ]]; then
        if [[ -z "$ch_password" ]]; then
            wd_logger 1 "Enter password for ClickHouse default user (press Enter for no password):"
            read -s ch_password
        fi
        
        if [[ -n "$ch_password" ]]; then
            # Pre-configure password to avoid interactive prompt
            wd_logger 1 "clickhouse-server clickhouse-server/default-password password $ch_password" | \
                sudo debconf-set-selections
            wd_logger 1 "clickhouse-server clickhouse-server/default-password-again password $ch_password" | \
                sudo debconf-set-selections
        fi
    fi
    
    # Install ClickHouse
    wd_logger 1 "Installing ClickHouse packages..."
    if [[ "$configure_password" == "true" ]]; then
        sudo DEBIAN_FRONTEND=noninteractive apt install -y clickhouse-server clickhouse-client
    else
        sudo apt install -y clickhouse-server clickhouse-client
    fi
    
    # Start and enable service
    wd_logger 1 "Starting ClickHouse service..."
    sudo systemctl start clickhouse-server
    sudo systemctl enable clickhouse-server
    
    # Wait a moment for service to start
    sleep 5
    
    # Verify installation
    verify_clickhouse_installation
}

function verify_clickhouse_installation() {
    wd_logger 1 "Verifying ClickHouse installation..."
    
    # Check if service is running
    if systemctl is-active --quiet clickhouse-server; then
        wd_logger 1 "✅ ClickHouse service is running"
    else
        wd_logger 1 "❌ ClickHouse service is not running"
        wd_logger 1 "Service status:"
        sudo systemctl status clickhouse-server --no-pager
        return 1
    fi
    
    # Test connection
    local max_retries=10
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if clickhouse-client --query "SELECT 1" &> /dev/null; then
            wd_logger 1 "✅ ClickHouse is responding to queries"
            wd_logger 1 "✅ Installation completed successfully!"
            wd_logger 1 ""
            wd_logger 1 "You can now connect to ClickHouse using:"
            wd_logger 1 "  clickhouse-client"
            wd_logger 1 ""
            wd_logger 1 "Or access the web interface at:"
            wd_logger 1 "  http://localhost:8123/play"
            return 0
        else
            wd_logger 1 "Waiting for ClickHouse to be ready... (attempt $((retry+1))/$max_retries)"
            sleep 2
            ((retry++))
        fi
    done
    
    wd_logger 1 "❌ ClickHouse is not responding to queries after installation"
    wd_logger 1 "Check logs with: sudo journalctl -u clickhouse-server -f"
    return 1
}

function install_clickhouse() {
    local ch_password=""
    local configure_password=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --password)
                ch_password="$2"
                configure_password=true
                shift 2
                ;;
            --configure-password)
                configure_password=true
                shift
                ;;
            -h|--help)
                wd_logger 1 "Usage: install_clickhouse [--password PASSWORD] [--configure-password]"
                wd_logger 1 "  --password PASSWORD      Set password for default user"
                wd_logger 1 "  --configure-password     Prompt for password if not provided"
                wd_logger 1 "  --help                   Show this help message"
                return 0
                ;;
            *)
                wd_logger 1 "Unknown option: $1"
                return 1
                ;;
        esac
    done

    wd_logger 2 "Checking ClickHouse installation status..."
    
    # Check if ClickHouse is already installed and running
    if command -v clickhouse-server &> /dev/null; then
        wd_logger 2 "ClickHouse server found, checking if it's running..."
        
        if systemctl is-active --quiet clickhouse-server 2>/dev/null; then
            wd_logger 2 "✅ ClickHouse is already installed and running"
            
            # Test connection
            if clickhouse-client --query "SELECT 1" &> /dev/null; then
                wd_logger 2 "✅ ClickHouse is responding to queries"
                return 0
            else
                wd_logger 1 "⚠️  ClickHouse is running but not responding to queries"
                wd_logger 1 "Attempting to restart service..."
                sudo systemctl restart clickhouse-server
                sleep 3
                
                if clickhouse-client --query "SELECT 1" &> /dev/null; then
                    wd_logger 1 "✅ ClickHouse is now responding"
                    return 0
                else
                    wd_logger 1 "❌ ClickHouse still not responding, manual intervention needed"
                    return 1
                fi
            fi
        else
            wd_logger 1 "ClickHouse is installed but not running, starting service..."
            sudo systemctl start clickhouse-server
            sudo systemctl enable clickhouse-server
            sleep 3
            
            if systemctl is-active --quiet clickhouse-server; then
                wd_logger 1 "✅ ClickHouse service started successfully"
                return 0
            else
                wd_logger 1 "❌ Failed to start ClickHouse service"
                return 1
            fi
        fi
    fi

    wd_logger 1 "ClickHouse not found, beginning installation..."
    
    install_clickhouse_debian "$configure_password" "$ch_password"
}

if [[ ${HOSTNAME:0:2} == "WD" ]]; then
    if [[ "$HOSTNAME" == "WD0" ]] || [[ "$HOSTNAME" == "WD00" ]]; then
        wd_logger 2 "Don't install Clickhouse on WD0 or WD00"
    else
        wd_logger 2 "Check for Clickhouse and install it if needed"
        install_clickhouse
    fi
fi
