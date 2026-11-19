#!/bin/bash
set -euo pipefail

source /scripts/prefix-logs.sh
prefix_logs scheduler

source /scripts/wait-for-backend.sh "${BACKEND_URL}" scheduler
exec bench schedule
