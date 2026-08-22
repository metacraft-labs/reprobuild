#!/usr/bin/env bash
# Source formatter for reprobuild — `just format`.
#
#   format_sources.sh [--check]
#
#   (default)  rewrite files in place.
#   --check    rewrite nothing; report which files WOULD change and exit 1 if
#              any would. Use this to size a reformat before taking it, and as
#              a CI gate once the tree is clean.
#
# THE NIM ARM USED TO BE A SILENT NO-OP. It was guarded by
# `command -v nimpretty`, and no nimpretty was reachable: the dev shell's Nim
# is the 2.3.1 fork built by nix/nim-fork.nix, whose `bin/` shipped `nim`,
# `nim-gdb` and `nim-gdb.bat` and nothing else. So `just format` — a command
# CLAUDE.md documents — formatted `flake.nix`, exited 0, and touched ZERO Nim
# files. A formatter that reports success without running is worse than no
# formatter, because the next reader concludes the tree is formatted.
#
# The fix was NOT to reach for nixpkgs' nim wrapper, which does bundle a
# nimpretty but a 2.2.4 one, against a tree compiled by a 2.3.1 fork: a
# formatter whose parser is a different program from the compiler's will
# eventually rewrite something the compiler accepts into something it does not.
# nim-fork.nix now builds nimpretty from the FORK's own sources, so formatter
# and compiler share a lexer, parser and layouter by construction.
#
# Consequently a missing nimpretty is now an ERROR, not a skip. It means the
# toolchain is wrong, and the only thing worse than finding that out here is
# not finding it out at all.
set -euo pipefail

MODE="write"
for arg in "$@"; do
  case "$arg" in
    --check) MODE=check ;;
    *)
      echo "format_sources.sh: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v nimpretty >/dev/null 2>&1; then
  echo "format_sources.sh: nimpretty not found on PATH." >&2
  echo "  It is part of reprobuild's Nim toolchain (nix/nim-fork.nix builds it" >&2
  echo "  from the fork so the formatter and the compiler share a parser)." >&2
  echo "  Enter the dev shell:  nix develop . -c just format" >&2
  exit 1
fi

mapfile -d '' -t nim_files < <(find apps libs tests -type f -name '*.nim' -print0 | sort -z)
if [ "${#nim_files[@]}" -eq 0 ]; then
  echo "format_sources.sh: no .nim files under apps/ libs/ tests/ — refusing to report success" >&2
  exit 1
fi

# nimpretty REFUSES some files, and that is a feature: it re-parses its own
# output and, if the result does not parse, reports `nimpretty_bug.nim(L,C)
# Error: ...`, exits 1 and leaves the input BYTE-IDENTICAL. Measured over this
# tree (2026-08-22): 7 of 2144 files, all left untouched. Those refusals must
# not be swallowed — that is how this script got into trouble in the first
# place — so they are collected and NAMED. They do not fail the run: the
# formatting the caller asked for did happen, on every file nimpretty could
# handle, and a `just format` that exits nonzero forever until seven files
# (two of them vendored upstream trees) are hand-fixed would just be routed
# around. A MISSING nimpretty is the hard error; a nimpretty that declines a
# file, loudly, having changed nothing, is information.
refused=()
would_change=()
jobs_n="$(nproc 2>/dev/null || echo 4)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

# One nimpretty process per file so a refusal can be attributed to a file
# (batching several paths into one invocation loses that), fanned out with
# `xargs -P` so 2000+ files still take seconds. Workers append their verdicts
# to two files; single short lines opened O_APPEND do not interleave.
if [ "$MODE" = check ]; then
  # shellcheck disable=SC2016  # the worker body is expanded by the spawned bash, not here
  printf '%s\0' "${nim_files[@]}" |
    xargs -0 -P "$jobs_n" -I{} bash -c '
      f=$1; scratch=$2
      out="$scratch/out.$$.nim"
      if nimpretty --out:"$out" "$f" >/dev/null 2>&1; then
        cmp -s "$f" "$out" || printf "%s\n" "$f" >>"$scratch/would_change"
      else
        printf "%s\n" "$f" >>"$scratch/refused"
      fi
      rm -f "$out"
    ' _ {} "$scratch"
  if [ -f "$scratch/would_change" ]; then
    mapfile -t would_change < <(sort "$scratch/would_change")
  fi
else
  # shellcheck disable=SC2016  # the worker body is expanded by the spawned bash, not here
  printf '%s\0' "${nim_files[@]}" |
    xargs -0 -P "$jobs_n" -I{} bash -c '
      f=$1; scratch=$2
      nimpretty "$f" >/dev/null 2>&1 || printf "%s\n" "$f" >>"$scratch/refused"
    ' _ {} "$scratch"
fi
if [ -f "$scratch/refused" ]; then
  mapfile -t refused < <(sort "$scratch/refused")
fi

if [ "${#refused[@]}" -gt 0 ]; then
  echo "format_sources.sh: nimpretty DECLINED ${#refused[@]} file(s) (left unmodified;" >&2
  echo "  its output failed its own re-parse check). Run nimpretty on one to see why:" >&2
  printf '  %s\n' "${refused[@]}" >&2
fi

if [ "$MODE" = check ]; then
  if [ "${#would_change[@]}" -gt 0 ]; then
    printf '%s\n' "${would_change[@]}"
    echo "format_sources.sh: ${#would_change[@]} of ${#nim_files[@]} Nim file(s) are not nimpretty-clean." >&2
    exit 1
  fi
  echo "format_sources.sh: all ${#nim_files[@]} Nim file(s) are nimpretty-clean."
else
  echo "format_sources.sh: nimpretty ran over $(( ${#nim_files[@]} - ${#refused[@]} )) of ${#nim_files[@]} Nim file(s)."
fi

if command -v nixfmt >/dev/null 2>&1; then
  if [ "$MODE" = check ]; then
    nixfmt --check flake.nix
  else
    nixfmt flake.nix
  fi
elif command -v nixfmt-rfc-style >/dev/null 2>&1; then
  if [ "$MODE" = check ]; then
    nixfmt-rfc-style --check flake.nix
  else
    nixfmt-rfc-style flake.nix
  fi
else
  echo "format_sources.sh: no nixfmt on PATH; flake.nix not formatted." >&2
  exit 1
fi
