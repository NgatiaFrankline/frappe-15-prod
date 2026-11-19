#!/bin/bash
set -euo pipefail

source /scripts/prefix-logs.sh
prefix_logs socketio

source /scripts/wait-for-backend.sh "${BACKEND_URL}" socketio
exec node /home/frappe/frappe-bench/apps/frappe/socketio.js
