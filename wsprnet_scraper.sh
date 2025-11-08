#!/bin/bash
#
# wsprnet_scraper.sh - Wrapper script for WSPRNET Scraper
# Version: 3.0
# Date: 2025-11-04

set -e

# Load wsprnet configuration
if [[ ! -f /etc/wsprdaemon/wsprnet.conf ]]; then
    echo "ERROR: Config file not found: /etc/wsprdaemon/wsprnet.conf" >&2
    exit 1
fi

echo "Loading configuration from: /etc/wsprdaemon/wsprnet.conf"
source /etc/wsprdaemon/wsprnet.conf

# Source ClickHouse configuration
if [[ -f /etc/wsprdaemon/clickhouse.conf ]]; then
    source /etc/wsprdaemon/clickhouse.conf
else
    echo "ERROR: ClickHouse config not found: /etc/wsprdaemon/clickhouse.conf" >&2
    exit 1
fi

# Required variables check
required_vars=(
    "WSPRNET_USERNAME"
    "WSPRNET_PASSWORD"
    "WSPRNET_VENV_PYTHON"
    "WSPRNET_SCRAPER_SCRIPT"
    "WSPRNET_SESSION_FILE"
    "WSPRNET_LOG_FILE"
    "WSPRNET_LOOP_INTERVAL"
    "CLICKHOUSE_WSPRDAEMON_ADMIN_USER"
    "CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD"
)

missing_vars=()
for var in "${required_vars[@]}"; do
    if [[ -z "${!var+x}" ]]; then
        missing_vars+=("  $var")
    fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "ERROR: Missing required configuration variables:" >&2
    printf '%s\n' "${missing_vars[@]}" >&2
    exit 1
fi

# Verify Python executable exists
if [[ ! -x "${WSPRNET_VENV_PYTHON}" ]]; then
    echo "ERROR: Python executable not found or not executable: ${WSPRNET_VENV_PYTHON}" >&2
    exit 1
fi

# Verify script exists
if [[ ! -f "${WSPRNET_SCRAPER_SCRIPT}" ]]; then
    echo "ERROR: Scraper script not found: ${WSPRNET_SCRAPER_SCRIPT}" >&2
    exit 1
fi

# Create directories if needed
mkdir -p "$(dirname "${WSPRNET_LOG_FILE}")"
mkdir -p "$(dirname "${WSPRNET_SESSION_FILE}")"

# Start the scraper
echo "Starting WSPRNET Scraper..."
echo "Python: ${WSPRNET_VENV_PYTHON}"
echo "Script: ${WSPRNET_SCRAPER_SCRIPT}"
echo "Log: ${WSPRNET_LOG_FILE}"
echo "Loop interval: ${WSPRNET_LOOP_INTERVAL} seconds"

exec "${WSPRNET_VENV_PYTHON}" "${WSPRNET_SCRAPER_SCRIPT}" \
    --clickhouse-user "${CLICKHOUSE_WSPRDAEMON_ADMIN_USER}" \
    --clickhouse-password "${CLICKHOUSE_WSPRDAEMON_ADMIN_PASSWORD}" \
    --setup-readonly-user "default" \
    --setup-readonly-password "" \
    --username "${WSPRNET_USERNAME}" \
    --password "${WSPRNET_PASSWORD}" \
    --session-file "${WSPRNET_SESSION_FILE}" \
    --log-file "${WSPRNET_LOG_FILE}" \
    --log-max-mb "${WSPRNET_LOG_MAX_MB:-10}" \
    --loop "${WSPRNET_LOOP_INTERVAL}" \
    --verbose "${WSPRNET_VERBOSITY:-1}"
