#!/bin/bash
set -e

# This script is called by systemd with a config file path as the first argument
# Usage: wsprdaemon_server.sh /etc/wsprdaemon/wsprdaemon.conf

CONFIG_FILE="$1"

if [[ -z "${CONFIG_FILE}" ]]; then
    echo "ERROR: No configuration file specified" >&2
    echo "Usage: $0 /etc/wsprdaemon/config.conf" >&2
    exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Configuration file not found: ${CONFIG_FILE}" >&2
    exit 1
fi

# Parse the configuration file by sourcing it
# This reads all the variable definitions from the config file
echo "Loading configuration from: ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Default verbosity if not set in config
VERBOSITY="${VERBOSITY:-0}"

# Validate required variables are now set
REQUIRED_VARS=(
    "CLICKHOUSE_DEFAULT_PASSWORD"
    "CLICKHOUSE_ADMIN_USER"
    "CLICKHOUSE_ADMIN_PASSWORD"
    "CLICKHOUSE_READONLY_USER"
    "CLICKHOUSE_READONLY_PASSWORD"
    "LOG_FILE"
    "VENV_PYTHON"
    "SCRAPER_SCRIPT"
    "LOOP_INTERVAL"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        MISSING_VARS+=("${var}")
    fi
done

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    echo "ERROR: Missing required configuration variables in ${CONFIG_FILE}:" >&2
    printf '  %s\n' "${MISSING_VARS[@]}" >&2
    exit 1
fi

# Validate files exist
if [[ ! -x "${VENV_PYTHON}" ]]; then
    echo "ERROR: Python executable not found or not executable: ${VENV_PYTHON}" >&2
    exit 1
fi

if [[ ! -f "${SCRAPER_SCRIPT}" ]]; then
    echo "ERROR: Scraper script not found: ${SCRAPER_SCRIPT}" >&2
    exit 1
fi

# Create directories if needed
mkdir -p "$(dirname "${LOG_FILE}")"

# Build and execute the command with variables parsed from config
echo "Starting WSPRDAEMON server with config: ${CONFIG_FILE}"
echo "Python: ${VENV_PYTHON}"
echo "Script: ${SCRAPER_SCRIPT}"
echo "Log: ${LOG_FILE}"
echo "Loop interval: ${LOOP_INTERVAL} seconds"

exec "${VENV_PYTHON}" "${SCRAPER_SCRIPT}" \
    --clickhouse-user "${CLICKHOUSE_ADMIN_USER}" \
    --clickhouse-password "${CLICKHOUSE_ADMIN_PASSWORD}" \
    --setup-default-password "${CLICKHOUSE_DEFAULT_PASSWORD}" \
    --setup-readonly-user "${CLICKHOUSE_READONLY_USER}" \
    --setup-readonly-password "${CLICKHOUSE_READONLY_PASSWORD}" \
    --log-file "${LOG_FILE}" \
    --log-max-mb "${LOG_MAX_MB:-10}" \
    --verbose "${VERBOSITY}" \
    --loop "${LOOP_INTERVAL}"
