#!/bin/bash
set -euo pipefail

# Bench backups must run as frappe; avoid creating root-owned lock files.
if ((EUID == 0)); then
  export HOME=/home/frappe USER=frappe LOGNAME=frappe
  exec runuser --preserve-environment --user frappe -- "$0" "$@"
fi

if [[ "$(id -un)" != "frappe" ]]; then
  echo "Run bench-backup.sh as the frappe user" >&2
  exit 1
fi

site_name="${SITE_NAME:?SITE_NAME must be set}"
if [[ ! "${site_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid SITE_NAME '${site_name}'" >&2
  exit 2
fi

bench_dir="${BENCH_DIR:-/home/frappe/frappe-bench}"
export PATH="/home/frappe/.local/bin:${bench_dir}/env/bin:${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
cd "${bench_dir}"

backup_dir="${BACKUP_DIR:-/backup}"
site_backup_dir="${backup_dir%/}/${site_name}"
backup_date="$(date '+%d-%m-%Y')"
backup_path="${site_backup_dir}/${backup_date}"
lock_file="${bench_dir}/sites/.bench-backup-${site_name}.lock"
exec 9>"${lock_file}"
if ! flock -n 9; then
  echo "A backup for ${site_name} is already running; skipping"
  exit 0
fi

mkdir -p -- "${backup_path}"
if [[ ! -w "${backup_path}" ]]; then
  echo "Backup directory is not writable: ${backup_path}" >&2
  exit 1
fi

echo "Starting database and site-file backup for ${site_name} at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Backup directory: ${backup_path}"
bench --site "${site_name}" backup --backup-path "${backup_path}" --with-files --verbose
echo "Backup completed successfully"

prune_backup_sets() {
  local -a backup_dates=()
  local index old_backup_dir

  mapfile -t backup_dates < <(
    find "${site_backup_dir}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
      grep -E '^[0-9]{2}-[0-9]{2}-[0-9]{4}$' |
      sort -t- -k3,3nr -k2,2nr -k1,1nr
  )

  for ((index = 2; index < ${#backup_dates[@]}; index++)); do
    old_backup_dir="${site_backup_dir}/${backup_dates[index]}"
    echo "Removing old backup directory ${old_backup_dir}"
    rm -rf -- "${old_backup_dir}"
  done
}

prune_backup_sets
echo "Backup retention complete; keeping the latest two backup sets"
