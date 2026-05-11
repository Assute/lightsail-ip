#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_FILE="${LIGHTSAIL_MONITOR_CONFIG:-${SCRIPT_DIR}/config.json}"
NODE_BIN="node"

if ! command -v "$NODE_BIN" >/dev/null 2>&1; then
  NODE_BIN="nodejs"
fi

if [ "$#" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
  exec bash "$SCRIPT_DIR/lightsail-monitor.sh"
fi

if [ "$#" -ge 1 ]; then
  exec "$NODE_BIN" "$SCRIPT_DIR/lightsail_monitor.js" --config "$CONFIG_FILE" run --server "$1"
fi

exec "$NODE_BIN" "$SCRIPT_DIR/lightsail_monitor.js" --config "$CONFIG_FILE" run
