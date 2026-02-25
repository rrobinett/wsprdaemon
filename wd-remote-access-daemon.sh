#!/bin/bash

FRPC_CONF="./frpc.ini"
FRPC_BIN="./frpc"
ERROR_PATTERN="start error: proxy .* already exists"
MAX_ERRORS=3
RESTART_DELAY=10
ERROR_FILE=$(mktemp)

while true; do
    echo 0 > "$ERROR_FILE"
    "$FRPC_BIN" -c "$FRPC_CONF" 2>&1 | while IFS= read -r line; do
        echo "$line"
        if echo "$line" | grep -qE "$ERROR_PATTERN"; then
            count=$(( $(cat "$ERROR_FILE") + 1 ))
            echo "$count" > "$ERROR_FILE"
            echo "$(date): proxy-already-exists error #${count}" >&2
            if (( count >= MAX_ERRORS )); then
                echo "$(date): restarting frpc to clear stale proxy" >&2
                pkill -f "$FRPC_BIN"
            fi
        fi
    done
    echo "$(date): frpc exited, restarting in ${RESTART_DELAY}s..." >&2
    sleep "$RESTART_DELAY"
    echo 0 > "$ERROR_FILE"
done

