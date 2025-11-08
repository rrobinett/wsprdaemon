#!/bin/bash
#
# wsprdaemon_server.sh - Wrapper script for WSPRDAEMON Server
# Version: 3.0
# Date: 2025-11-04

set -e

# Get config file from command line
CONFIG_FILE="$1"
if [[ -z "${CONFIG_FILE}" ]] || [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    echo "Usage: $0 /path/to/config.conf" >&2
    exit 1
fi

# Load configuration
echo "Loading configuration from: ${CONFIG_FILE}"
source "${CONFIG_FILE}"

# Source ClickHouse configuration
if [[ -f /etc/wsprdaemon/clickhouse.conf ]]; then
    source /etc/wsprdaemon/clickhouse.conf
else
    echo "ERROR: ClickHouse config not found: /etc/wsprdaemon/clickhouse.conf" >&2
    exit 1
fi

# Required variables check
required_vars=(
    "CLICKHOUSE_WSPRDAEMON_ADMIN_USER"
    "CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD"
    "VENV_PYTHON"
    "SCRAPER_SCRIPT"
    "LOG_FILE"
    "LOOP_INTERVAL"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [[ -z "${!var+x}" ]]; then  # Check if variable is set (even if empty)
        missing_vars+=("  $var")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "ERROR: Missing required configuration variables:" >&2
    printf '%s\n' "${missing_vars[@]}" >&2
    exit 1
fi

# Verify Python executable exists
if [[ ! -x "${VENV_PYTHON}" ]]; then
    echo "ERROR: Python executable not found or not executable: ${VENV_PYTHON}" >&2
    exit 1
fi

# Verify script exists
if [[ ! -f "${SCRAPER_SCRIPT}" ]]; then
    echo "ERROR: Server script not found: ${SCRAPER_SCRIPT}" >&2
    exit 1
fi

# Create directories if needed
mkdir -p "$(dirname "${LOG_FILE}")"

# Start the server
echo "Starting WSPRDAEMON Server with config: ${CONFIG_FILE}"
echo "Python: ${VENV_PYTHON}"
echo "Script: ${SCRAPER_SCRIPT}"
echo "Log: ${LOG_FILE}"
echo "Loop interval: ${LOOP_INTERVAL} seconds"

exec "${VENV_PYTHON}" "${SCRAPER_SCRIPT}" \
    --clickhouse-user "${CLICKHOUSE_WSPRDAEMON_ADMIN_USER}" \
    --clickhouse-password "${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD}" \
    --log-file "${LOG_FILE}" \
    --log-max-mb "${LOG_MAX_MB:-10}" \
    --loop "${LOOP_INTERVAL}" \
    --verbose "${VERBOSITY:-1}"
