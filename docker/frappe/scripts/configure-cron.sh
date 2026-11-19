#!/bin/bash

# Only the main frappe container owns the shared backup schedule.
if [[ "${1:-}" != "/usr/bin/supervisord" ]]; then
  echo "Skipping cron configuration for non-Supervisor command"
  return 0
fi

set -euo pipefail

# The root crontab and cron daemon are managed before Supervisor starts.
if ((EUID != 0)); then
  echo "configure-cron.sh must run as root" >&2
  exit 1
fi

# Check the field count here so malformed schedules fail container startup.
backup_cron="${BACKUP_CRON_SCHEDULE:-0 2 * * *}"
read -r -a cron_fields <<< "${backup_cron}"
if ((${#cron_fields[@]} != 5)); then
  echo "BACKUP_CRON_SCHEDULE must contain exactly five cron fields: minute hour day month weekday" >&2
  exit 2
fi

site_name="${SITE_NAME}"
if [[ ! "${site_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid SITE_NAME '${site_name}'" >&2
  exit 2
fi

backup_dir="${BACKUP_DIR:-/backup}"
if [[ ! "${backup_dir}" =~ ^/[A-Za-z0-9._/-]+$ || "${backup_dir}" == "/" || "${backup_dir}" == *".."* ]]; then
  echo "BACKUP_DIR must be an absolute path without spaces" >&2
  exit 2
fi

site_backup_dir="${backup_dir%/}/${site_name}"
install -d -o frappe -g 0 -m 0750 "${backup_dir}" "${site_backup_dir}"

existing_file="$(mktemp)"
error_file="$(mktemp)"
temporary_file="$(mktemp)"
trap 'rm -f -- "${existing_file}" "${error_file}" "${temporary_file}"' EXIT

# Preserve unrelated root jobs while replacing only this script's managed block.
if crontab -l > "${existing_file}" 2> "${error_file}"; then
  :
elif grep -Fqx 'no crontab for root' "${error_file}"; then
  : > "${existing_file}"
else
  cat "${error_file}" >&2
  exit 1
fi

awk '
  $0 == "# BEGIN managed bench backup" { in_managed_block = 1; next }
  $0 == "# END managed bench backup" { in_managed_block = 0; next }
  !in_managed_block { print }
' "${existing_file}" > "${temporary_file}"

# Pass backup settings to this job only; log the trigger and script output persistently.
{
  printf '# BEGIN managed bench backup\n'
  printf '%s /usr/bin/env SITE_NAME=%s BACKUP_DIR=%s HOME=/home/frappe PATH=/home/frappe/frappe-bench/env/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -c '\''echo "Backup cron triggered at $(date)"; exec runuser --preserve-environment -u frappe -- /scripts/bench-backup.sh'\'' >>/logs/bench-backup-cron.log 2>&1\n' \
    "${backup_cron}" "${site_name}" "${backup_dir}"
  printf '# END managed bench backup\n'
} >> "${temporary_file}"

crontab "${temporary_file}"
rm -f -- "${existing_file}" "${error_file}" "${temporary_file}"
trap - EXIT

# cron daemonizes by default; confirm it started before allowing startup to continue.
if ! pgrep -x cron >/dev/null; then
  /usr/sbin/cron
  for _ in {1..5}; do
    pgrep -x cron >/dev/null && break
    sleep 1
  done
fi

if ! pgrep -x cron >/dev/null; then
  echo "Failed to start cron daemon" >&2
  exit 1
fi

echo "Configured backup schedule '${backup_cron}' for ${site_name}; cron is running"
