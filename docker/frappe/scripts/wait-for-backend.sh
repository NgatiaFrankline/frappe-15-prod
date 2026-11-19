#!/bin/bash

wait_for_backend() (
  set -euo pipefail

  backend_url="${1:-}"
  _SERVICE_NAME="${2:-Unknown}"
  if [[ -z "${backend_url}" ]]; then
    echo "Usage: source wait-for-backend.sh <backend-url> <service-name>" >&2
    return 2
  fi

  startup_timeout="${BACKEND_STARTUP_TIMEOUT:-300}"
  if [[ ! "${startup_timeout}" =~ ^[1-9][0-9]*$ ]]; then
    echo "BACKEND_STARTUP_TIMEOUT must be a positive integer" >&2
    return 2
  fi

  # Readiness means gunicorn answers HTTP. The site may not exist yet (the
  # ping returns 404 for an unknown site), so any non-5xx response counts.
  backend_ready() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 1 \
      "${backend_url%/}/api/method/ping" || true)"
    [[ "${code}" =~ ^[234][0-9][0-9]$ ]]
  }

  deadline=$((SECONDS + startup_timeout))
  while ! backend_ready; do
    echo "Waiting for backend to become ready..."
    if ((SECONDS >= deadline)); then
      echo "Backend did not become ready within ${startup_timeout} seconds for ${_SERVICE_NAME} to use it. Exiting..." >&2
      return 1
    fi
    sleep 1
  done

  echo "Backend is ready"
)

wait_for_backend "$@"
