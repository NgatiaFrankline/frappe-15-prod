#!/bin/bash
set -euo pipefail

# Back up a site to /archive before removing its database and site files.
# Run as frappe so Bench uses the bench virtualenv and site files permissions.
if ((EUID == 0)); then
  exec runuser --preserve-environment --user frappe -- "$0" "$@"
fi

if [[ "$(id -un)" != "frappe" ]]; then
  echo "Run site_drop.sh as the frappe user" >&2
  exit 1
fi

site_name="${SITE_NAME:?SITE_NAME is required}"
bench_dir="${BENCH_DIR:-/home/frappe/frappe-bench}"
archive_root="/archive"
force=false
site_config="${bench_dir}/sites/${site_name}/site_config.json"
orphan_database=""

if (( $# > 1 )) || { (( $# == 1 )) && [[ "$1" != "--force" ]]; }; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi
if (( $# == 1 )); then
  force=true
fi

if [[ ! "${site_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid SITE_NAME '${site_name}'" >&2
  exit 2
fi
if [[ ! -x "${bench_dir}/env/bin/python" ]]; then
  echo "Frappe bench is not initialized at ${bench_dir}" >&2
  exit 1
fi
if [[ ! -f "${site_config}" ]]; then
  : "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required to drop the site database}"
  for command_name in mariadb mariadb-dump; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "Required MariaDB command is unavailable: ${command_name}" >&2
      exit 1
    fi
  done

  db_client() {
    MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb \
      --protocol=TCP \
      --host="${DB_HOST:-mariadb-db}" \
      --port="${DB_PORT:-3306}" \
      --user="${DB_ROOT_USER:-root}" \
      "$@"
  }
  db_dump() {
    MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb-dump \
      --protocol=TCP \
      --host="${DB_HOST:-mariadb-db}" \
      --port="${DB_PORT:-3306}" \
      --user="${DB_ROOT_USER:-root}" \
      "$@"
  }

  orphan_database="$(db_client --batch --skip-column-names \
    --execute="SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE BINARY SCHEMA_NAME = BINARY '${site_name}'")"
  if [[ -z "${orphan_database}" ]]; then
    echo "Site ${site_name} and matching database do not exist; nothing to drop"
    exit 0
  fi

  case "${orphan_database,,}" in
    information_schema|mysql|performance_schema|sys)
      echo "Refusing to drop protected MariaDB system database: ${orphan_database}" >&2
      exit 1
      ;;
  esac
fi
if [[ ! -d "${archive_root}" || ! -w "${archive_root}" ]]; then
  echo "Archive directory is missing or not writable: ${archive_root}" >&2
  exit 1
fi
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required to drop the site}"

if [[ "${force}" != true ]]; then
  if [[ ! -t 0 ]]; then
    echo "Refusing to drop non-interactively; rerun with --force to confirm" >&2
    exit 1
  fi
  confirmation=""
  target_description="site ${site_name}"
  if [[ -n "${orphan_database}" ]]; then
    target_description="orphan database ${orphan_database}"
  fi
  read -r -p "Type '${site_name}' to back up and permanently drop ${target_description}: " confirmation || confirmation=""
  if [[ "${confirmation}" != "${site_name}" ]]; then
    echo "Confirmation did not match; keeping ${target_description}"
    exit 1
  fi
fi

if [[ -n "${orphan_database}" ]]; then
  archive_date="$(date '+%Y-%m-%d-%H%M%S')"
  archive_path="${archive_root}/site-dropped-backup-${site_name}-${archive_date}"
  if ! mkdir -m 0770 -- "${archive_path}"; then
    echo "Could not create archive directory: ${archive_path}" >&2
    exit 1
  fi

  database_backup="${archive_path}/${site_name}-database.sql.gz"
  echo "Backing up orphan database ${orphan_database} to ${database_backup}"
  if ! db_dump --single-transaction --routines --events --triggers \
    --databases "${orphan_database}" | gzip -c > "${database_backup}"; then
    echo "Database backup failed; refusing to drop ${orphan_database}. Review ${archive_path}" >&2
    exit 1
  fi
  if [[ ! -s "${database_backup}" ]]; then
    echo "Database backup is empty; refusing to drop ${orphan_database}. Review ${archive_path}" >&2
    exit 1
  fi

  echo "Dropping orphan database ${orphan_database}"
  db_client --execute="DROP DATABASE \`${orphan_database}\`"
  echo "Database ${orphan_database} was dropped. Its backup is in ${archive_path}"
  exit 0
fi

cd "${bench_dir}"
if ! bench --site "${site_name}" list-apps >/dev/null 2>&1; then
  echo "Site ${site_name} is not responding to Bench; refusing to drop it" >&2
  exit 1
fi

archive_date="$(date '+%Y-%m-%d-%H%M%S')"
archive_path="${archive_root}/site-dropped-backup-${site_name}-${archive_date}"
if ! mkdir -m 0770 -- "${archive_path}"; then
  echo "Could not create archive directory: ${archive_path}" >&2
  exit 1
fi

echo "Backing up ${site_name} to ${archive_path}"
bench --site "${site_name}" backup \
  --backup-path "${archive_path}" \
  --with-files \
  --verbose

database_backup="$(find "${archive_path}" -maxdepth 1 -type f -name '*database.sql.gz' -size +0c -print -quit)"
public_files_backup="$(find "${archive_path}" -maxdepth 1 -type f \( -name '*-files.tar' -o -name '*-files.tar.gz' \) ! -name '*-private-files.tar*' -size +0c -print -quit)"
private_files_backup="$(find "${archive_path}" -maxdepth 1 -type f \( -name '*-private-files.tar' -o -name '*-private-files.tar.gz' \) -size +0c -print -quit)"
if [[ -z "${database_backup}" || -z "${public_files_backup}" || -z "${private_files_backup}" ]]; then
  echo "Backup is incomplete; refusing to drop ${site_name}. Review ${archive_path}" >&2
  exit 1
fi

echo "Verified database and public/private file backups:"
find "${archive_path}" -maxdepth 1 -type f -printf '  %f\n' | sort

echo "Dropping site ${site_name}"
bench drop-site "${site_name}" \
  --force \
  --no-backup \
  --root-password "${DB_ROOT_PASSWORD}"

echo "Site ${site_name} was dropped. Its backup is in ${archive_path}"
