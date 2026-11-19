#!/bin/bash
set -euo pipefail

wait_for_websocket() (
  set -euo pipefail

  local service_name="${1:-Unknown}"
  local startup_timeout="${WEBSOCKET_STARTUP_TIMEOUT:-180}"
  local deadline response

  if [[ ! "${startup_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    echo "WEBSOCKET_STARTUP_TIMEOUT must be a positive integer" >&2
    return 2
  fi

  deadline=$((SECONDS + startup_timeout))
  while true; do
    echo "Waiting for Socket.IO to become ready..."
    if response=$(curl -fsS --connect-timeout 1 --max-time 1 \
      'http://127.0.0.1:9000/socket.io/?EIO=4&transport=polling' 2>/dev/null) \
      && [[ "${response}" == 0\{* ]]; then
      echo "Socket.IO is ready for ${service_name} to use it."
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "Socket.IO did not become ready within ${startup_timeout} seconds for ${service_name} to use it. Exiting..." >&2
      return 1
    fi
    sleep 1
  done
)

wait_for_websocket "$@"
