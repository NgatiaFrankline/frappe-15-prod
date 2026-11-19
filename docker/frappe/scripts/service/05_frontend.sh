#!/bin/bash
set -euo pipefail

source /scripts/prefix-logs.sh
prefix_logs frontend

source /scripts/wait-for-backend.sh "${BACKEND_URL}" frontend
source /scripts/wait-for-websocket.sh frontend
exec /usr/local/bin/nginx-entrypoint.sh
