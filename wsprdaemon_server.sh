#!/bin/bash
# WSPRDAEMON Server wrapper script

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
fi

# Required variables
required_vars=(
    "CLICKHOUSE_WSPRDAEMON_ADMIN_USER"
    "CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD"
    "VENV_PYTHON"
    "SCRAPER_SCRIPT"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        missing_vars+=("  $var")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "ERROR: Missing required configuration variables in ${CONFIG_FILE}:" >&2
    printf '%s\n' "${missing_vars[@]}" >&2
    exit 1
fi

# Verify files exist
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
mkdir -p "${EXTRACTION_DIR}"

# Build and execute the command
echo "Starting WSPRDAEMON Server with config: ${CONFIG_FILE}"
echo "Python: ${VENV_PYTHON}"
echo "Script: ${SCRAPER_SCRIPT}"
echo "Log: ${LOG_FILE}"
echo "Loop interval: ${LOOP_INTERVAL} seconds"

exec "${VENV_PYTHON}" "${SCRAPER_SCRIPT}" \
    --clickhouse-user "${CLICKHOUSE_WSPRDAEMON_ADMIN_USER}" \
    --clickhouse-password "${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD}" \
    --log-file "${LOG_FILE}" \
    --log-max-mb "${LOG_MAX_MB}" \
    --loop "${LOOP_INTERVAL}" \
    --verbose "${VERBOSITY}"
