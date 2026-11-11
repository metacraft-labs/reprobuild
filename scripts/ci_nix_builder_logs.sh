#!/usr/bin/env bash
# Keep the BUILDER log of every derivation a CI step's nix reports as failed.
#
# When a derivation's builder exits non-zero, nix prints the derivation's
# name, at most `--log-lines` (default 25) lines of its output, and a
# `nix log <drv>` hint. The tail is often not enough to say why the build
# failed, and the rest of the output exists only in the nix daemon's log
# store on the runner, which is gone when the job ends. A CI step that drives
# nix therefore keeps each failed derivation's full builder log in
# `test-logs/`, the directory the workflow uploads as its record of the run.
# The contract is reprobuild-pm spec/Testing/CI-Bootstrap-Failure-Evidence.md,
# section "Derivation builder logs".
#
# Usage:
#   ci_nix_builder_logs.sh run <out-dir> <name> -- <command> [args...]
#       Run <command>, passing its stdout through untouched (so the form also
#       works inside `$(...)`) and teeing its stderr -- where nix writes its
#       diagnostics -- into a scratch file. When the command fails, collect
#       from that stderr into <out-dir>. Exits with the command's own status.
#       <name> only labels the scratch file.
#
#   ci_nix_builder_logs.sh collect <build-output> <out-dir>
#       For a step that already keeps its output in a file: scan
#       <build-output> and write each failed derivation's builder log to
#       <out-dir>/nix-builder-<drv-name>.log. Always exits 0 once its
#       arguments are valid -- it runs AFTER a failure, and the caller re-raises
#       that failure's own status.
#
# Which derivations: only those whose BUILDER failed. Nix reports each of
# them with one of these (the wording of Nix 2.34 and the earlier one,
# https://github.com/NixOS/nix/tree/master/src/libstore/build):
#
#   error: Cannot build '<drv>'.            followed by  Reason: builder failed ...
#   error: builder for '<drv>' failed with exit code N
#   error: hash mismatch in fixed-output derivation '<drv>':
#          nix log <drv>                    (the "For full logs, run:" hint,
#                                            on a line of its own)
#   For full logs, run 'nix log <drv>'.     (the same hint, earlier wording)
#
# A `Cannot build` whose reason is `N dependency failed` names a dependent: it
# never ran a builder and has no log, so it is not collected. A build output
# also names every `.drv` it builds, fetches or garbage-collects, which is why
# this does not take every store path in the text: run 41201815981 did, sorted
# them, asked `nix log` for an unrelated fetch derivation first, and the
# failure of that one lookup ended the loop before it reached the derivation
# that failed.
#
# Every lookup is independent: a log nix cannot produce is recorded as such in
# the derivation's file and the next one is still tried. `nix log` reads the
# daemon's log store by path, so it answers even after the `.drv` itself has
# been garbage-collected (measured with Nix 2.34.8).

set -uo pipefail

# Bound the work for an output that names an implausible number of failures;
# the first ones are the ones that explain the rest.
readonly MAX_DERIVATIONS=20
# Lines of each builder log echoed into the job log, beside the full file.
readonly TAIL_LINES=80

usage() {
  sed -n '14,27p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

# Print the failed derivations named in the file $1, in first-seen order.
failed_derivations() {
  local line pending="" window=0 drv
  local -A seen=()
  local drv_re="(/nix/store/[a-z0-9]{32}-[^\"' ]+\\.drv)"
  emit() {
    [ -n "${seen[$1]:-}" ] && return
    seen[$1]=1
    printf '%s\n' "$1"
  }
  # Only lines near a failure report matter; grep narrows a long build
  # output to them first (`-A 4` keeps the `Reason:` line that follows a
  # `Cannot build`). Colour escapes would split a store path from its quote,
  # so they are stripped first.
  while IFS= read -r line; do
    if [ -n "$pending" ]; then
      if [[ "$line" == *"Reason: builder failed"* ]]; then
        emit "$pending"
        pending=""
      elif [[ "$line" == *"Reason:"* ]] || [ "$window" -le 0 ]; then
        pending=""
      fi
      window=$((window - 1))
    fi
    if [[ "$line" =~ Cannot\ build\ \'${drv_re}\' ]]; then
      pending="${BASH_REMATCH[1]}"
      window=4
    elif [[ "$line" =~ builder\ for\ \'${drv_re}\'\ failed ]] ||
         [[ "$line" =~ fixed-output\ derivation\ \'${drv_re}\' ]] ||
         [[ "$line" =~ ^[[:space:]]*nix\ log\ ${drv_re}[[:space:]]*$ ]] ||
         [[ "$line" =~ run\ \'nix\ log\ ${drv_re}\' ]]; then
      drv="${BASH_REMATCH[1]}"
      emit "$drv"
    fi
  done < <(sed -E $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' "$1" |
             grep -E -A 4 "Cannot build|builder for|fixed-output derivation|nix log")
}

collect() {
  local output="$1" out_dir="$2" drv name file count=0
  if [ ! -r "$output" ]; then
    echo "ci_nix_builder_logs: no build output at $output; nothing to collect" >&2
    return 0
  fi
  if ! mkdir -p "$out_dir"; then
    echo "ci_nix_builder_logs: cannot create $out_dir; builder logs NOT kept" >&2
    return 0
  fi
  while IFS= read -r drv; do
    count=$((count + 1))
    if [ "$count" -gt "$MAX_DERIVATIONS" ]; then
      echo "ci_nix_builder_logs: more than $MAX_DERIVATIONS failed derivations; kept the first $MAX_DERIVATIONS" >&2
      break
    fi
    name="$(basename "$drv" .drv)"
    file="$out_dir/nix-builder-$name.log"
    echo "::group::nix builder log: $drv -> $file" >&2
    if nix log "$drv" > "$file" 2> "$file.err"; then
      tail -n "$TAIL_LINES" "$file" >&2
    else
      # Keep the reason in the file the reader will open, not only here.
      { echo "nix log $drv failed; its builder log is not available on this runner:"
        cat "$file.err"; } > "$file"
      cat "$file" >&2
    fi
    rm -f "$file.err"
    echo "::endgroup::" >&2
  done < <(failed_derivations "$output")
  if [ "$count" -eq 0 ]; then
    echo "ci_nix_builder_logs: $output names no failed derivation build" >&2
  fi
  return 0
}

run() {
  local out_dir="$1" name="$2" scratch rc
  shift 2
  scratch="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nix-step-$name.XXXXXX")" || {
    echo "ci_nix_builder_logs: cannot create a scratch file; running $1 without capture" >&2
    "$@"
    return
  }
  # stdout goes straight to the caller's stdout through fd 3; only stderr
  # enters the pipe, so `$(... run ...)` still captures exactly the command's
  # stdout. The pipeline is synchronous: tee has finished writing when the
  # status is read.
  { "$@" 2>&1 1>&3 3>&- | tee "$scratch" >&2; } 3>&1
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    collect "$scratch" "$out_dir"
  fi
  rm -f "$scratch"
  return "$rc"
}

main() {
  case "${1:-}" in
    collect)
      [ "$#" -eq 3 ] || usage
      collect "$2" "$3"
      ;;
    run)
      [ "$#" -ge 5 ] && [ "$4" = "--" ] || usage
      local out_dir="$2" name="$3"
      shift 4
      run "$out_dir" "$name" "$@"
      ;;
    *)
      usage
      ;;
  esac
}

main "$@"
