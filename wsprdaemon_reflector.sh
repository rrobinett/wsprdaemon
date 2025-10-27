#!/bin/bash
set -e

# This script is called by systemd with a config file path as the first argument
# Usage: wsprdaemon_reflector.sh /etc/wsprdaemon/reflector.conf

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
echo "Loading configuration from: ${CONFIG_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Validate required variables are now set
REQUIRED_VARS=(
    "STATE_FILE"
    "QUEUE_BASE_DIR"
    "LOG_FILE"
    "VENV_PYTHON"
    "REFLECTOR_SCRIPT"
    "REFLECTOR_CONFIG"
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

if [[ ! -f "${REFLECTOR_SCRIPT}" ]]; then
    echo "ERROR: Reflector script not found: ${REFLECTOR_SCRIPT}" >&2
    exit 1
fi

if [[ ! -f "${REFLECTOR_CONFIG}" ]]; then
    echo "ERROR: Reflector destinations config not found: ${REFLECTOR_CONFIG}" >&2
    exit 1
fi

# Create directories if needed
mkdir -p "$(dirname "${STATE_FILE}")"
mkdir -p "$(dirname "${LOG_FILE}")"
mkdir -p "${QUEUE_BASE_DIR}"

# Build and execute the command with variables parsed from config
echo "Starting WSPRDAEMON Reflector with config: ${CONFIG_FILE}"
echo "Python: ${VENV_PYTHON}"
echo "Script: ${REFLECTOR_SCRIPT}"
echo "Destinations config: ${REFLECTOR_CONFIG}"
echo "Log: ${LOG_FILE}"
echo "Verbosity: ${VERBOSITY:-1}"

exec "${VENV_PYTHON}" "${REFLECTOR_SCRIPT}" \
    --config "${REFLECTOR_CONFIG}" \
    --log-file "${LOG_FILE}" \
    --log-max-mb "${LOG_MAX_MB:-10}" \
    --verbose "${VERBOSITY:-1}"
