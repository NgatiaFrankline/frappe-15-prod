#!/bin/bash

prefix_logs() {
  local program_name=$1

  exec 3>&1 4>&2
  exec > >(trap '' TERM INT; while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '[ %s ] %s\n' "${program_name}" "${line}"
  done >&3)
  exec 2> >(trap '' TERM INT; while IFS= read -r line || [[ -n "${line}" ]]; do
    printf '[ %s ] %s\n' "${program_name}" "${line}" >&4
  done)
  exec 3>&- 4>&-
}
