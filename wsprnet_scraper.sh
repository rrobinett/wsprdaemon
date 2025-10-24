#!/bin/bash
# WSPRNET Scraper Wrapper Script
# Loads configuration and starts the Python scraper

set -e

# Configuration file paths
WSPRNET_CONF="/etc/wsprdaemon/wsprnet.conf"
CLICKHOUSE_CONF="/etc/wsprdaemon/clickhouse.conf"

# Load configurations
if [[ -f "$WSPRNET_CONF" ]]; then
    echo "Loading configuration from: $WSPRNET_CONF"
    source "$WSPRNET_CONF"
else
    echo "ERROR: Configuration file not found: $WSPRNET_CONF" >&2
    exit 1
fi

if [[ -f "$CLICKHOUSE_CONF" ]]; then
    echo "Loading ClickHouse credentials from: $CLICKHOUSE_CONF"
    source "$CLICKHOUSE_CONF"
else
    echo "ERROR: ClickHouse configuration file not found: $CLICKHOUSE_CONF" >&2
    exit 1
fi

# Validate required variables
REQUIRED_VARS=(
    "WSPRNET_SESSION_FILE"
    "WSPRNET_LOG_FILE"
    "WSPRNET_VENV_PYTHON"
    "WSPRNET_SCRAPER_SCRIPT"
    "WSPRNET_LOOP_INTERVAL"
    "WSPRNET_READONLY_USER"
    "WSPRNET_READONLY_PASSWORD"
    "CLICKHOUSE_HOST"
    "CLICKHOUSE_PORT"
    "CLICKHOUSE_ADMIN_USER"
    "CLICKHOUSE_ADMIN_PASSWORD"
)

MISSING_VARS=()
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        MISSING_VARS+=("  $var")
    fi
done

if [[ ${#MISSING_VARS[@]} -gt 0 ]]; then
    echo "ERROR: Missing required configuration variables:" >&2
    printf '%s\n' "${MISSING_VARS[@]}" >&2
    exit 1
fi

# Build command arguments
CMD_ARGS=(
    "--session-file" "$WSPRNET_SESSION_FILE"
    "--clickhouse-user" "$CLICKHOUSE_ADMIN_USER"
    "--clickhouse-password" "$CLICKHOUSE_ADMIN_PASSWORD"
    "--setup-readonly-user" "$WSPRNET_READONLY_USER"
    "--setup-readonly-password" "$WSPRNET_READONLY_PASSWORD"
    "--log-file" "$WSPRNET_LOG_FILE"
    "--log-max-mb" "${WSPRNET_LOG_MAX_MB:-10}"
    "--loop" "$WSPRNET_LOOP_INTERVAL"
)

# Add optional username/password if provided
if [[ -n "$WSPRNET_USERNAME" ]]; then
    CMD_ARGS+=("--username" "$WSPRNET_USERNAME")
fi

if [[ -n "$WSPRNET_PASSWORD" ]]; then
    CMD_ARGS+=("--password" "$WSPRNET_PASSWORD")
fi

# Execute the Python scraper
echo "Starting WSPRNET scraper..."
exec "$WSPRNET_VENV_PYTHON" "$WSPRNET_SCRAPER_SCRIPT" "${CMD_ARGS[@]}"
