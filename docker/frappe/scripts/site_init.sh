#!/bin/bash
# Creates the site SITE_NAME when it does not exist yet, or interactively
# offers to replace an already-installed site with a fresh one.
# SITE_NAME is created as the bench default site.
#   SITE_NAME, SITE_DB_NAME, SITE_DB_PASSWORD, DB_HOST, DB_PORT,
#   DB_ROOT_PASSWORD, ADMIN_PASSWORD
set -euo pipefail

# bench must not run as root; re-run as frappe, keeping the environment.
if ((EUID == 0)); then
  exec runuser --preserve-environment --user frappe -- "$0" "$@"
fi

: "${SITE_NAME:?SITE_NAME is required}"
: "${SITE_DB_NAME:?SITE_DB_NAME is required}"
: "${SITE_DB_PASSWORD:?SITE_DB_PASSWORD is required}"

if [[ ! "${SITE_DB_NAME}" =~ ^[A-Za-z0-9_][A-Za-z0-9_]{0,63}$ ]]; then
  echo "Invalid SITE_DB_NAME '${SITE_DB_NAME}'" >&2
  exit 2
fi

case "${SITE_DB_NAME,,}" in
  information_schema|mysql|performance_schema|sys)
    echo "SITE_DB_NAME cannot be a MariaDB system database" >&2
    exit 2
    ;;
esac

bench_dir="/home/frappe/frappe-bench"
cd "${bench_dir}"

if [[ ! "${SITE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid SITE_NAME '${SITE_NAME}'" >&2
  exit 1
fi

backup_existing_site() {
  local archive_path archive_date
  local database_backup public_files_backup private_files_backup

  if [[ ! -d /archive || ! -w /archive ]]; then
    echo "Archive directory is missing or not writable: /archive" >&2
    return 1
  fi

  archive_date="$(date '+%Y-%m-%d-%H%M%S')"
  archive_path="/archive/site-init-backup-${SITE_NAME}-${archive_date}"
  if ! mkdir -m 0770 -- "${archive_path}"; then
    echo "Could not create archive directory: ${archive_path}" >&2
    return 1
  fi

  echo "Backing up ${SITE_NAME} before replacement to ${archive_path}"
  bench --site "${SITE_NAME}" backup \
    --backup-path "${archive_path}" \
    --with-files \
    --verbose

  database_backup="$(find "${archive_path}" -maxdepth 1 -type f -name '*database.sql.gz' -size +0c -print -quit)"
  public_files_backup="$(find "${archive_path}" -maxdepth 1 -type f \( -name '*-files.tar' -o -name '*-files.tar.gz' \) ! -name '*-private-files.tar*' -size +0c -print -quit)"
  private_files_backup="$(find "${archive_path}" -maxdepth 1 -type f \( -name '*-private-files.tar' -o -name '*-private-files.tar.gz' \) -size +0c -print -quit)"
  if [[ -z "${database_backup}" || -z "${public_files_backup}" || -z "${private_files_backup}" ]]; then
    echo "Backup is incomplete; refusing to replace ${SITE_NAME}. Review ${archive_path}" >&2
    return 1
  fi

  echo "Verified database and public/private file backups:"
  find "${archive_path}" -maxdepth 1 -type f -printf '  %f\n' | sort
}

force_args=()
if [[ -f "sites/${SITE_NAME}/site_config.json" ]]; then
  if bench --site "${SITE_NAME}" list-apps >/dev/null 2>&1; then
    if [[ -t 0 ]]; then
      answer=""
      read -r -p "Site ${SITE_NAME} is installed. Reinstall it? This deletes its database and site files [y/N] " answer || answer=""
    else
      echo "Site ${SITE_NAME} already exists; skipping reinstall because no interactive terminal is available"
      answer=""
    fi

    case "${answer,,}" in
      y|yes)
        : "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required to reinstall the site}"
        backup_existing_site
        echo "Dropping site ${SITE_NAME}"
        bench drop-site "${SITE_NAME}" \
          --force \
          --no-backup \
          --root-password "${DB_ROOT_PASSWORD}"
        ;;
      *)
        echo "Keeping existing site ${SITE_NAME}"
        site_ready=true
        ;;
    esac
  else
    echo "Site ${SITE_NAME} is incomplete; recreating it"
    : "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required to recreate the site}"
    backup_existing_site
    force_args=(--force)
  fi
fi

if [[ "${site_ready:-false}" != true ]]; then
  : "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD is required to create the site}"
  : "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required to create the site}"
  echo "Creating site ${SITE_NAME}"
  bench new-site "${SITE_NAME}" \
    --db-name "${SITE_DB_NAME}" \
    --db-password "${SITE_DB_PASSWORD}" \
    --db-host "${DB_HOST:-mariadb-db}" \
    --db-port "${DB_PORT:-3306}" \
    --db-root-username "${DB_ROOT_USER:-root}" \
    --db-root-password "${DB_ROOT_PASSWORD}" \
    --admin-password "${ADMIN_PASSWORD}" \
    --mariadb-user-host-login-scope='%' \
    "${force_args[@]}"
  bench --site "${SITE_NAME}" enable-scheduler
fi

echo
echo "Setting site ${SITE_NAME} as the default site"
bench set-config -g default_site "${SITE_NAME}"
echo "Done!"
echo
echo "Disabling developer mode for site ${SITE_NAME}"
bench --site "${SITE_NAME}" set-config developer_mode 0
echo "Done!"
echo
echo "Enabling scheduler for site ${SITE_NAME}"
bench --site "${SITE_NAME}" enable-scheduler
echo
echo "Running migrations for site ${SITE_NAME}"
bench --site "${SITE_NAME}" migrate
echo "Done!"
