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
# is the 2.3.1 fork built by nix/pkgs/by-name/re/reprobuild/nim-fork.nix,
# whose `bin/` shipped `nim`, `nim-gdb` and `nim-gdb.bat` and nothing
# else. So `just format` — a command
# AGENTS.md documents — formatted `flake.nix`, exited 0, and touched ZERO Nim
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
  echo "  It is part of reprobuild's Nim toolchain" >&2
  echo "  (nix/pkgs/by-name/re/reprobuild/nim-fork.nix builds it from the" >&2
  echo "  fork so the formatter and the compiler share a parser)." >&2
  echo "  Enter the dev shell:  nix develop . -c just format" >&2
  exit 1
fi

mapfile -d '' -t nim_files < <(find apps libs tests -type f -name '*.nim' -print0 | sort -z)
if [ "${#nim_files[@]}" -eq 0 ]; then
  echo "format_sources.sh: no .nim files under apps/ libs/ tests/ — refusing to report success" >&2
  exit 1
fi

# A re-parse alone cannot detect `or name` becoming the valid identifier
# `orname`. Require the fork's AST verifier, stage every output, and publish
# only after equivalent parsed meaning is established. Older nimpretty exits
# successfully on unknown options, so probe its advertised capability first.
if ! nimpretty --help | grep -q -- '--checkEquivalent:file'; then
  echo "format_sources.sh: nimpretty lacks the required AST verifier; update the Nim toolchain." >&2
  exit 1
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
jobs_n="${FORMAT_JOBS:-2}"
# Each worker owns its output; originals are untouched on any refusal, even
# when the formatter itself writes an invalid output before returning failure.
# shellcheck disable=SC2016
printf '%s\0' "${nim_files[@]}" |
  xargs -0 -P "$jobs_n" -I{} bash -c '
    f=$1; scratch=$2; mode=$3
    out="$scratch/out.$$.nim"
    if ! nimpretty --out:"$out" "$f" >"$out.log" 2>&1 ||
        [ ! -f "$out" ] ||
        ! nimpretty --checkEquivalent:"$f" "$out" >>"$out.log" 2>&1; then
      printf "%s\n" "$f" >>"$scratch/failed"
      cat "$out.log" >&2
    elif ! cmp -s "$f" "$out"; then
      if [ "$mode" = check ]; then
        printf "%s\n" "$f" >>"$scratch/would_change"
      else
        # Publish by same-directory rename so a failed write cannot truncate
        # the input source. Preserve its permissions in the replacement.
        staged=$(mktemp "${f}.format.XXXXXX")
        if ! cp -p "$f" "$staged" || ! cat "$out" >"$staged" ||
            ! mv -f "$staged" "$f"; then
          printf "%s\n" "$f" >>"$scratch/failed"
        fi
        rm -f "$staged"
      fi
    fi
    rm -f "$out" "$out.log"
  ' _ {} "$scratch" "$MODE"

if [ -f "$scratch/failed" ]; then
  echo "format_sources.sh: formatting or equivalence verification FAILED; refused files:" >&2
  sort "$scratch/failed" >&2
  exit 1
fi
if [ "$MODE" = check ] && [ -f "$scratch/would_change" ]; then
  sort "$scratch/would_change"
  echo "format_sources.sh: Nim files are not nimpretty-clean." >&2
  exit 1
fi
echo "format_sources.sh: verified ${#nim_files[@]} Nim file(s)."

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
