#!/bin/bash

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "${level}" "$*"
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      log ERROR "Required environment variable ${name} is not set"
      return 1
    fi
  done
}
