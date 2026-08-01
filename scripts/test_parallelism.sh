#!/usr/bin/env bash

# Choose a conservative default for graph-owned test builds. Small hosts keep
# the four-worker ceiling; hosts with at least 24 logical CPUs can use up to
# eight workers. Callers can still override REPROBUILD_MAX_PARALLELISM.
reprobuild_default_test_build_parallelism() {
  local available_cores="${1:-1}"
  if [[ ! "${available_cores}" =~ ^[0-9]+$ ]] ||
      (( available_cores < 1 )); then
    available_cores=1
  fi

  local cap=$((available_cores / 2))
  if (( cap < 1 )); then
    cap=1
  fi
  local max_cap=4
  if (( available_cores >= 24 )); then
    max_cap=8
  fi
  if (( cap > max_cap )); then
    cap="${max_cap}"
  fi
  printf '%s\n' "${cap}"
}
