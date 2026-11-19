#!/bin/bash
set -euo pipefail

source /scripts/prefix-logs.sh
prefix_logs queue-short

source /scripts/wait-for-backend.sh "${BACKEND_URL}" queue-short
exec bench worker --queue short,default
