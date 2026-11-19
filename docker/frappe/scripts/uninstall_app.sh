#!/bin/bash
set -euo pipefail

# Bench commands must run as frappe; the main service itself starts as root.
if ((EUID == 0)); then
  export HOME=/home/frappe USER=frappe LOGNAME=frappe
  exec runuser --preserve-environment --user frappe -- "$0" "$@"
fi

if [[ "$(id -un)" != "frappe" ]]; then
  echo "Run uninstall_app.sh as the frappe user" >&2
  exit 1
fi
if [[ ! -t 0 ]]; then
  echo "uninstall_app.sh requires an interactive terminal" >&2
  exit 1
fi

bench_dir="${BENCH_DIR:-/home/frappe/frappe-bench}"
if [[ ! -x "${bench_dir}/env/bin/python" ]]; then
  echo "Frappe bench is not initialized at ${bench_dir}" >&2
  exit 1
fi
cd "${bench_dir}"

site_names=()
shopt -s nullglob
site_configs=("${bench_dir}"/sites/*/site_config.json)
shopt -u nullglob
for site_config in "${site_configs[@]}"; do
  site_name="${site_config%/site_config.json}"
  site_name="${site_name##*/}"
  if [[ "${site_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    site_names+=("${site_name}")
  fi
done

if ((${#site_names[@]} == 0)); then
  echo "No sites with site_config.json found in ${bench_dir}/sites"
  exit 0
fi

echo "Available sites:"
PS3="Choose a site number (0 to cancel): "
select selected_site in "${site_names[@]}"; do
  if [[ "${REPLY}" == "0" ]]; then
    echo "Cancelled"
    exit 0
  fi
  if [[ -n "${selected_site:-}" ]]; then
    break
  fi
  echo "Invalid selection"
done

site_apps_for() {
  local site="$1"
  local output app

  if ! output="$(bench --site "${site}" list-apps)"; then
    return 1
  fi

  site_apps=()
  while IFS= read -r app; do
    if [[ "${app}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
      site_apps+=("${app}")
    fi
  done < <(printf '%s\n' "${output}" | awk 'NF {print $1}')
}

if ! site_apps_for "${selected_site}"; then
  echo "Could not list apps installed on ${selected_site}" >&2
  exit 1
fi

uninstallable_apps=()
for app in "${site_apps[@]}"; do
  if [[ "${app}" != "frappe" ]]; then
    uninstallable_apps+=("${app}")
  fi
done

if ((${#uninstallable_apps[@]} == 0)); then
  echo "No uninstallable apps are installed on ${selected_site}"
  exit 0
fi

echo "Apps installed on ${selected_site}:"
PS3="Choose an app number to uninstall (0 to cancel): "
select selected_app in "${uninstallable_apps[@]}"; do
  if [[ "${REPLY}" == "0" ]]; then
    echo "Cancelled"
    exit 0
  fi
  if [[ -n "${selected_app:-}" ]]; then
    break
  fi
  echo "Invalid selection"
done

delete_app_files=false
answer=""
read -r -p "Delete ${selected_app}'s shared bench files after uninstalling? [y/N] " answer || answer=""
case "${answer,,}" in
  y|yes) delete_app_files=true ;;
esac

if [[ "${delete_app_files}" == true ]]; then
  other_sites=()
  for other_site in "${site_names[@]}"; do
    [[ "${other_site}" == "${selected_site}" ]] && continue
    if ! site_apps_for "${other_site}"; then
      echo "Could not check app usage on ${other_site}; shared app files will be kept." >&2
      delete_app_files=false
      break
    fi
    for installed_app in "${site_apps[@]}"; do
      if [[ "${installed_app}" == "${selected_app}" ]]; then
        other_sites+=("${other_site}")
        break
      fi
    done
  done

  if ((${#other_sites[@]} > 0)); then
    printf 'Keeping shared app files; %s is also installed on: %s\n' \
      "${selected_app}" "${other_sites[*]}" >&2
    delete_app_files=false
  fi
fi

answer=""
read -r -p "Uninstall ${selected_app} from ${selected_site}? This removes its site data [y/N] " answer || answer=""
case "${answer,,}" in
  y|yes) ;;
  *)
    echo "Cancelled; no changes made"
    exit 0
    ;;
esac

echo "Uninstalling ${selected_app} from ${selected_site}"
bench --site "${selected_site}" uninstall-app "${selected_app}" --yes

if [[ "${delete_app_files}" == true ]]; then
  echo "Removing ${selected_app} from the bench"
  bench remove-app --no-backup "${selected_app}"
else
  echo "Keeping ${selected_app} files in ${bench_dir}/apps/${selected_app}"
fi

echo "Uninstall complete. Restart frappe services to apply the change."
