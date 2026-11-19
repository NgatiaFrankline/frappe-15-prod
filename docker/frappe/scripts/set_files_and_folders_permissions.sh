#!/bin/bash

set_files_and_folders_permissions() {
  local bench_dir="${BENCH_DIR:-/home/frappe/frappe-bench}"
  local home_dir="/home/frappe"
  local archive_dir="/archive"

  if [[ ! -d "${bench_dir}" ]]; then
    echo "Frappe bench directory does not exist: ${bench_dir}" >&2
    return 1
  fi

  # The frappe service starts as root to prepare home and shared-volume
  # permissions before Supervisor starts. queue-long runs as frappe.
  if ((EUID != 0)); then
    echo "Skipping runtime ownership repair as non-root user $(id -un)"
    return 0
  fi

  if [[ ! -d "${home_dir}" ]]; then
    echo "Frappe home directory does not exist: ${home_dir}" >&2
    return 1
  fi

  echo "Setting writable home permissions on ${home_dir}"
  chown frappe:0 "${home_dir}"
  chmod 2770 "${home_dir}"

  echo "Setting ownership and group permissions on ${bench_dir}"
  chown -R frappe:0 "${bench_dir}"
  chmod -R g=u "${bench_dir}"

  # /archive may be a fresh bind mount, which hides the image directory's
  # ownership and otherwise leaves it unwritable by the frappe user.
  mkdir -p "${archive_dir}"
  chown frappe:0 "${archive_dir}"
  chmod 2770 "${archive_dir}"
}

set_files_and_folders_permissions
