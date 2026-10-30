#!/usr/bin/env bash
# Strip FOREIGN dynamic-loader preloads from the suite's environment.
#
# The monitor shim (`librepro_monitor_shim`) is preloaded into every monitored
# child, and the capture it reports is what grades an edge's evidence
# (Failure-Semantics.md, the monitor-loss ladder). A library that ANOTHER tool
# preloaded into our process -- an agent harness tracing commands, a
# profiler, a TLS interceptor -- is inherited by every child too, so every
# monitored edge then runs with a second interposer beside the shim and the
# capture is graded a monitor loss. The engine then, correctly, publishes
# nothing (`cache-skip-monitor-loss`, "this edge will re-run on every build
# until the cause is removed"), and every test that expects a record, a hit
# or a publication fails with no line that names the cause.
#
# Measured 2026-10-30 on nixos-ci-bare-003 under an agent-harbor session
# (`LD_PRELOAD=.../libah_command_trace_shim.so`): the daemon peer-cache gate
# and the whole-graph shortcut test red, both green the moment the variable
# was unset for the run. So the suite removes what is not its own shim, says
# so, and runs. Only the suite's environment changes: the caller's shell is
# untouched, and reprobuild's own shim entries are kept in place.
#
# Removing the variable in THIS shell is not enough. The interposer is already
# loaded into the shell that runs the suite, and such a library re-inserts
# itself into every child's environment at exec time (measured with the
# agent-harbor shim: after `unset LD_PRELOAD` a child's /proc/self/maps still
# listed it, while `env -u LD_PRELOAD bash -c ...` from the same shell gave a
# clean child). So `foreign_preload_guard` re-executes the suite once through
# `env -u <var>`, which starts a shell the library was never loaded into, and
# refuses to run when the variable is back after that: the suite would be a
# silent red, and the operator must start it from a shell without the
# interposer (or turn its propagation off).
#
# Shared by scripts/run_tests.sh (`foreign_preload_guard "$@"`) and its
# falsifier (tests/integration/t_run_tests_strips_foreign_preload.nim), which
# sources this file and drives both functions directly.

foreign_preload_variable() {
  # The loader's preload variable for this platform. Pure bash on purpose:
  # every external this file ran would itself start under the preload it is
  # about to judge (and, when that names an absent file, print the loader's
  # complaint into the suite's stderr).
  case "${OSTYPE:-}" in
    darwin*) printf 'DYLD_INSERT_LIBRARIES' ;;
    *) printf 'LD_PRELOAD' ;;
  esac
}

foreign_preload_is_own_shim() {
  # Reprobuild's own monitor shim, under any of its build names. A basename
  # match is a convenience classifier for what to keep, not a trust decision:
  # a library that merely carries the name is not thereby monitored or
  # trusted, and the engine's evidence grading judges every preload by what
  # it does.
  case "${1##*/}" in
    librepro_monitor_shim*) return 0 ;;
    *) return 1 ;;
  esac
}

strip_foreign_preload() {
  # Remove every preload entry that is not reprobuild's monitor shim from the
  # platform's preload variable, in this shell's environment, and name each
  # removed entry on stderr. Entries are separated by colons or spaces (the
  # glibc loader accepts both). Returns 0 whether or not anything was removed.
  local var value entry
  var="$(foreign_preload_variable)"
  value="${!var:-}"
  [[ -n "${value}" ]] || return 0
  local -a entries kept=() dropped=()
  IFS=': ' read -r -a entries <<< "${value}"
  for entry in "${entries[@]}"; do
    [[ -n "${entry}" ]] || continue
    if foreign_preload_is_own_shim "${entry}"; then
      kept+=("${entry}")
    else
      dropped+=("${entry}")
    fi
  done
  (( ${#dropped[@]} > 0 )) || return 0
  printf 'run_tests.sh: %s named %d foreign preload(s); removed for this run:\n' \
    "${var}" "${#dropped[@]}" >&2
  for entry in "${dropped[@]}"; do
    printf '  %s\n' "${entry}" >&2
  done
  printf '  A library preloaded beside the monitor shim is a monitor loss on every\n' >&2
  printf '  monitored edge: nothing publishes, every cache test fails, and no test\n' >&2
  printf '  names the cause (scripts/lib/foreign_preload.sh).\n' >&2
  if (( ${#kept[@]} > 0 )); then
    local joined
    joined="$(IFS=:; printf '%s' "${kept[*]}")"
    export "${var}=${joined}"
  else
    unset "${var}"
  fi
}

foreign_preload_guard() {
  # Called with the suite's own arguments ("$@"). Strips foreign preloads; when
  # any was present, re-executes this script once in a shell started without
  # the variable, and refuses (exit 1) if the variable is back after that.
  local var value
  var="$(foreign_preload_variable)"
  value="${!var:-}"
  strip_foreign_preload
  if [[ "${value}" == "${!var:-}" ]]; then
    return 0  # nothing foreign was present
  fi
  if [[ -n "${REPRO_FOREIGN_PRELOAD_REEXEC:-}" ]]; then
    printf 'run_tests.sh: REFUSED: %s named a foreign preload again after the suite\n' \
      "${var}" >&2
    printf '  was re-executed without it, so the interposer re-inserts itself at exec\n' >&2
    printf '  time and every monitored edge would be a monitor loss. Start the suite\n' >&2
    printf '  from a shell the library is not loaded into, or turn its propagation off.\n' >&2
    return 1
  fi
  export REPRO_FOREIGN_PRELOAD_REEXEC=1
  local kept
  kept="${!var:-}"
  if [[ -n "${kept}" ]]; then
    # Our own shim stays preloaded: the new shell starts with exactly the
    # kept entries, so the foreign library is gone and the shim is not.
    printf '  Re-executing the suite in a shell started with %s=%s.\n' \
      "${var}" "${kept}" >&2
    exec env "${var}=${kept}" "${BASH}" "$0" "$@"
  fi
  printf '  Re-executing the suite in a shell started without %s.\n' "${var}" >&2
  exec env -u "${var}" "${BASH}" "$0" "$@"
}
