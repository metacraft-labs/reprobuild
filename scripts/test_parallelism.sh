#!/usr/bin/env bash

# Choose a default worker count for graph-owned test builds, as a fraction of
# the host's logical CPUs. The fraction (cores/2) leaves headroom for the C
# compilers each `nim c` forks; the caps below only stop very large hosts from
# oversubscribing memory.
#
# The former ceiling of eight was flat above 24 cores, so a 32- or 64-core
# workstation compiled the ~1200 test binaries eight at a time — the fraction
# was computed and then thrown away. Hosts at or above 32 cores now keep more
# of it.
#
# This default applies only when REPROBUILD_MAX_PARALLELISM is unset, i.e. to
# local runs. CI sets that variable explicitly (see .github/workflows/ci.yml)
# because its runner is a shared box: `nproc` there reports the whole machine
# while a dozen runner instances contend for it, so a host-derived default
# would badly oversubscribe it.
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
  if (( available_cores >= 32 )); then
    max_cap=16
  fi
  if (( cap > max_cap )); then
    cap="${max_cap}"
  fi
  printf '%s\n' "${cap}"
}
