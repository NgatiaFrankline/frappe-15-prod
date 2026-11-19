#!/bin/bash

restore_frappe_bench_dir() {
  local bench_dir="/home/frappe/frappe-bench"
  local bench_seed="/copied-frappe-bench"

  if [[ -f "${bench_dir}/apps/frappe/frappe/__init__.py" \
    && -x "${bench_dir}/env/bin/python" ]]; then
    echo "Frappe is already installed in the shared bench; skipping image seed copy"
    return 0
  fi

  if [[ ! -f "${bench_seed}/apps/frappe/frappe/__init__.py" \
    || ! -x "${bench_seed}/env/bin/python" ]]; then
    echo "Frappe bench seed is missing or incomplete: ${bench_seed}" >&2
    return 1
  fi
  if ((EUID != 0)); then
    echo "Cannot initialize the shared bench as a non-root user; start the frappe service first" >&2
    return 1
  fi

  echo "Initializing the shared bench from ${bench_seed}"
  mkdir -p "${bench_dir}"

  # A stale venv (e.g. symlinks to a Python missing from this image) is never
  # overwritten by cp -n, so move it aside and rebuild it from the seed.
  local env_rebuilt=0
  if [[ -e "${bench_dir}/env" || -L "${bench_dir}/env/bin/python" ]] \
    && [[ ! -x "${bench_dir}/env/bin/python" ]]; then
    local stale_env="${bench_dir}/env.broken.$(date +%Y%m%d%H%M%S)"
    echo "Shared bench env is broken; moving it to ${stale_env} and rebuilding"
    mv "${bench_dir}/env" "${stale_env}"
    env_rebuilt=1
  fi

  cp -an "${bench_seed}/." "${bench_dir}/"

  if ((env_rebuilt)); then
    local app
    for app in "${bench_dir}"/apps/*/; do
      app="${app%/}"
      [[ "${app##*/}" == "frappe" ]] && continue
      [[ -f "${app}/pyproject.toml" || -f "${app}/setup.py" ]] || continue
      echo "Reinstalling ${app##*/} into rebuilt env"
      if command -v uv >/dev/null 2>&1; then
        uv pip install --quiet --python "${bench_dir}/env/bin/python" -e "${app}" \
          || echo "Failed to reinstall ${app##*/}" >&2
      else
        "${bench_dir}/env/bin/python" -m pip install --quiet -e "${app}" \
          || echo "Failed to reinstall ${app##*/}" >&2
      fi
    done
    chown -R frappe:0 "${bench_dir}/env"
    chmod -R g=u "${bench_dir}/env"
  fi
  chown frappe:0 "${bench_dir}"
  chmod g+u "${bench_dir}"

  if [[ ! -f "${bench_dir}/apps/frappe/frappe/__init__.py" \
    || ! -x "${bench_dir}/env/bin/python" ]]; then
    echo "Shared bench initialization failed; Frappe is still missing from ${bench_dir}" >&2
    return 1
  fi
}

restore_frappe_bench_dir
