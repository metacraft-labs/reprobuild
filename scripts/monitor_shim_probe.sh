#!/usr/bin/env bash

# Return success when a reusable monitor shim artifact exists in the requested
# directory. Use only portable shell globbing and a regular-file check because
# optional shell builtins are absent from some supported Bash builds.
repro_monitor_shim_available() {
  local lib_dir="${1:-build/lib}"
  local candidate
  for candidate in "${lib_dir}"/librepro_monitor_shim.*; do
    if [[ -f "${candidate}" ]]; then
      return 0
    fi
  done
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repro_monitor_shim_available "${1:-build/lib}"
fi
