#!/bin/bash
set -euo pipefail

# Run manually after custom app changes have been pushed; this script does not
# install missing apps or run as part of container startup.
if ((EUID == 0)); then
  exec runuser --user frappe -- "$0" "$@"
fi

if [[ "$(id -un)" != "frappe" ]]; then
  echo "Run refresh-codebase.sh as the frappe user" >&2
  exit 1
fi

bench_dir="${BENCH_DIR:-/home/frappe/frappe-bench}"
site_name="${SITE_NAME:?SITE_NAME must be set}"
refresh_apps="${REFRESH_CODEBASE_APPS:-}"

if [[ -z "${refresh_apps//[[:space:],]/}" ]]; then
  echo "REFRESH_CODEBASE_APPS must contain at least one comma-separated app name" >&2
  exit 1
fi
if [[ ! "${site_name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Invalid SITE_NAME '${site_name}'" >&2
  exit 2
fi
if [[ ! -x "${bench_dir}/env/bin/python" ]]; then
  echo "Frappe bench is not initialized at ${bench_dir}" >&2
  exit 1
fi

# Prevent concurrent updates to the same shared bench.
exec 9>/tmp/refresh-codebase.lock
if ! flock -n 9; then
  echo "Another codebase refresh is already running" >&2
  exit 1
fi

cd "${bench_dir}"
IFS=, read -r -a configured_apps <<< "${refresh_apps}"
declare -a app_names=()
declare -a app_remotes=()
declare -a app_branches=()
declare -A seen_apps=()

for app in "${configured_apps[@]}"; do
  app="${app#"${app%%[![:space:]]*}"}"
  app="${app%"${app##*[![:space:]]}"}"
  if [[ ! "${app}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    echo "Invalid app name '${app}' in REFRESH_CODEBASE_APPS" >&2
    exit 2
  fi
  if [[ -n "${seen_apps[${app}]:-}" ]]; then
    echo "Duplicate app '${app}' in REFRESH_CODEBASE_APPS" >&2
    exit 2
  fi
  seen_apps["${app}"]=1

  app_dir="${bench_dir}/apps/${app}"
  if [[ ! -d "${app_dir}" ]] || ! git -C "${app_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "App ${app} is not a Git checkout in the bench; install it first" >&2
    exit 1
  fi

  upstream="$(git -C "${app_dir}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')" || {
    echo "App ${app} has no configured upstream branch; configure one before refreshing" >&2
    exit 1
  }
  remote="${upstream%%/*}"
  branch="${upstream#*/}"
  if [[ "${upstream}" != */* || -z "${remote}" || -z "${branch}" ]]; then
    echo "Could not determine the upstream remote and branch for ${app}: ${upstream}" >&2
    exit 1
  fi
  if [[ -n "$(git -C "${app_dir}" status --porcelain)" ]]; then
    echo "App ${app} has local changes; commit or stash them before refreshing" >&2
    exit 1
  fi

  app_names+=("${app}")
  app_remotes+=("${remote}")
  app_branches+=("${branch}")
done

installed_apps="$(bench --site "${site_name}" list-apps | awk '{print $1}')"
for app in "${app_names[@]}"; do
  if ! grep -Fxq -- "${app}" <<< "${installed_apps}"; then
    echo "App ${app} is not installed on ${site_name}; install it first" >&2
    exit 1
  fi
done

# Refresh in the exact order listed by REFRESH_CODEBASE_APPS. Refuse dirty
# trees rather than discarding local work with reset or a forced checkout.
apps_updated=false
for index in "${!app_names[@]}"; do
  app="${app_names[index]}"
  app_dir="${bench_dir}/apps/${app}"
  remote="${app_remotes[index]}"
  branch="${app_branches[index]}"
  before="$(git -C "${app_dir}" rev-parse HEAD)"

  echo "Updating ${app} from ${remote}/${branch}"
  git -C "${app_dir}" pull --ff-only "${remote}" "${branch}"
  after="$(git -C "${app_dir}" rev-parse HEAD)"
  if [[ "${before}" == "${after}" ]]; then
    echo "${app} is already up to date; skipping package installation"
    continue
  fi

  apps_updated=true
  metadata_changes="$(git -C "${app_dir}" diff --name-only "${before}" "${after}" -- \
    pyproject.toml setup.py setup.cfg requirements.txt requirements)"
  if [[ -n "${metadata_changes}" ]]; then
    echo "Python package metadata changed for ${app}; updating its environment"
    "${bench_dir}/env/bin/pip" install -e "apps/${app}"
  else
    echo "Python package metadata unchanged for ${app}; skipping package installation"
  fi

  echo "${app}: ${before:0:7} -> ${after:0:7}"
done

if [[ "${apps_updated}" != true ]]; then
  echo "All selected apps are already up to date; skipping migrations and service reload"
  exit 0
fi

# Apply app patches and refresh Frappe's cached site metadata. Assets are not
# rebuilt here; the runtime image expects each app to provide runtime assets.
bench --site "${site_name}" migrate
bench --site "${site_name}" clear-cache
bench --site "${site_name}" clear-website-cache
bench --site "${site_name}" build

echo
echo "Restarting supervisor and nginx"
supervisorctl -c /etc/supervisor/erp.supervisord.conf restart all && pkill nginx
echo "Done!"

# Restart nginx (the supervisor "frappe:frontend" program) so it serves the refreshed code.
if ! supervisorctl -c /etc/supervisor/supervisord.conf restart all; then
  echo "Could not restart nginx; restart the frappe service manually" >&2
fi

echo "Done!"
echo "Adios gringo"