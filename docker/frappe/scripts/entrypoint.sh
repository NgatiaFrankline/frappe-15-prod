#!/bin/bash
set -e

# Container entrypoint shared by all Frappe services.
#  - The supervisord service (frappe) starts as root and prepares the shared
#    bench volume: bootstraps Frappe into it, configures cron and fixes ownership.
#  - Every other service (e.g. queue-long) skips that setup, because the frappe
#    service already did it, and drops from root to the frappe user before
#    running its command, since bench refuses to run well as root.
umask 0002

echo
echo "Entrypoint script..."
echo "User: $(whoami)"

echo
echo "Configuring SSH..."
source /scripts/configure_ssh.sh

echo "Waiting for MariaDB and Redis before bench initialization"
source /scripts/wait-for-backend-dependencies.sh

# One-time shared bench setup, owned by the supervisord (frappe) service.
if [[ "${1:-}" == "/usr/bin/supervisord" ]]; then

  echo
  echo "Sourcing configure cron script..."
  source /scripts/configure-cron.sh

  echo "Sourcing restore frappe bench dir"
  source /scripts/restore-frappe-bench-dir.sh

  echo "Applying bench configuration before starting the backend"
  source /scripts/bench-init.sh

  echo
  echo "Sourcing set files and folders permissions script..."
  source /scripts/set_files_and_folders_permissions.sh

  # Supervisor starts as root; child workers retain its HOME after switching
  # to frappe, so point user-level downloads at frappe's writable home.
  export HOME=/home/frappe
fi

# Run other services as frappe (gid 0 keeps group access to the shared volume).
if ((EUID == 0)) && [[ "${1:-}" != "/usr/bin/supervisord" ]]; then
  echo
  echo "Dropping privileges to user frappe..."
  export HOME=/home/frappe USER=frappe LOGNAME=frappe

  echo "Waiting for backend to be ready..."
  source /scripts/wait-for-backend.sh "${QUEUE_BACKEND_URL}" queue-long

  echo
  echo "Starting..."
  exec setpriv --reuid=frappe --regid=0 --init-groups "$@"
fi

echo
echo "Starting..."
exec "$@"
