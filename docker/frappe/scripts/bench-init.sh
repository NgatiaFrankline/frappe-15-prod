#!/bin/bash

initialize_bench() (
  set -euo pipefail
  export HOME=/home/frappe
  source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

  BENCH_DIR="${BENCH_DIR:-/home/frappe/frappe-bench}"
  require_env BENCH_DIR

  run_as_frappe() {
    setpriv --reuid=frappe --regid=0 --init-groups \
      env HOME=/home/frappe USER=frappe LOGNAME=frappe "$@"
  }

#  if [[ -f "${BENCH_DIR}/sites/apps.txt" \
#    && -x "${BENCH_DIR}/env/bin/python" ]]; then
#    log INFO "Bench is already initialized at ${BENCH_DIR}; skipping bench init"
#  else
#    if [[ -e "${BENCH_DIR}" && ! -d "${BENCH_DIR}" ]]; then
#      log ERROR "Bench path exists but is not a directory: ${BENCH_DIR}"
#      exit 1
#    fi
#    if [[ -d "${BENCH_DIR}" ]] \
#      && [[ -n "$(find "${BENCH_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
#      log ERROR "Bench path is non-empty but not initialized; refusing to remove data: ${BENCH_DIR}"
#      exit 1
#    fi
#
#    log INFO "Initializing bench in ${BENCH_DIR}"
#    mkdir -p "${BENCH_DIR}"
#    chown frappe:0 "${BENCH_DIR}"
#    chmod g=u "${BENCH_DIR}"
#    cd "$(dirname "${BENCH_DIR}")"
#    run_as_frappe bench init "${BENCH_DIR}" --ignore-exist --skip-redis-config-generation --verbose
#    log SUCCESS "Bench initialization complete"
#  fi

  cd "${BENCH_DIR}"
  bench_commands="/conf/benchinit_commands.conf"
  if [[ ! -s "${bench_commands}" ]]; then
    echo "Skipping bench configuration: ${bench_commands} is missing or empty"
    return 0
  fi

  echo "Running bench commands from ${bench_commands}"
  run_as_frappe bash -euo pipefail "${bench_commands}"
)

initialize_bench
