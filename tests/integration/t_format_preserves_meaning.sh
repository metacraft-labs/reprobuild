#!/usr/bin/env bash
# Integration boundary: real fork formatter/parser and real files. The wrapper
# below injects formatter corruption only; verification always calls the real
# compiler-backed AST checker. This proves the script protects dirty sources
# independently of the layouter repair and its own final check. Its `drift`
# kind keeps the meaning but is not a fixed point (the real formatter is one
# now, so no real input can show that the script refuses such output).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
real="$(command -v nimpretty)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/tree/"{scripts,apps,libs,tests} "$scratch/bin"
cp "$repo/scripts/format_sources.sh" "$scratch/tree/scripts/"
printf '{}\n' >"$scratch/tree/flake.nix"
cp "$repo/libs/repro_cli_support/src/repro_cli_support.nim" "$scratch/real.nim"
# The CLI-support monolith is the largest source in the tree and the one the
# formatter has refused before with "invalid indentation": the layouter
# rendered a rejoined line break as a blank line with its continuation in
# column 0, and laid a `proc` body passed inside a call out at the level of
# the enclosing field. The formatter must accept it, keep its
# parsed meaning, and be at a fixed point on its own output, or `just format`
# followed by `just format --check` reports the file again.
if ! "$real" --out:"$scratch/formatted.nim" "$scratch/real.nim"; then
  echo "FAIL: formatter refused the CLI-support module" >&2; exit 1
fi
if grep -q orstderrPolicy "$scratch/formatted.nim"; then
  echo "FAIL: formatter joined word operator and operand" >&2; exit 1
fi
"$real" --checkEquivalent:"$scratch/real.nim" "$scratch/formatted.nim"
if ! "$real" --out:"$scratch/reformatted.nim" "$scratch/formatted.nim"; then
  echo "FAIL: formatter refused its own output for the CLI-support module" >&2
  exit 1
fi
if ! cmp "$scratch/formatted.nim" "$scratch/reformatted.nim"; then
  echo "FAIL: formatting the CLI-support module is not idempotent" >&2; exit 1
fi
cat >"$scratch/bin/nimpretty" <<'WRAPPER'
#!/usr/bin/env bash
case "$1" in
  --help|--checkEquivalent:*) exec "$REAL_NIMPRETTY" "$@" ;;
  *)
    # Support both staged output and the unfixed script calling in place.
    target=$1
    case "$target" in --out:*) target=${target#--out:} ;; esac
    if [ "${CORRUPT_KIND:-semantic}" = parse ]; then
      printf 'let = (\n' >"$target"
    elif [ "$CORRUPT_KIND" = drift ]; then
      # Meaning-preserving but never a fixed point: each pass adds a
      # comment, as the fork's layouter once moved comments and changed
      # indentation widths on every pass over its own output.
      src=$2
      if [ "$src" = "$target" ]; then cp "$src" "$target.in"; src=$target.in; fi
      { cat "$src"; printf '# drift\n'; } >"$target"
      rm -f "$target.in"
    else
      printf 'let orvalue = 1\n' >"$target"
    fi
    ;;
esac
WRAPPER
chmod +x "$scratch/bin/nimpretty"
export REAL_NIMPRETTY="$real"
export PATH="$scratch/bin:$PATH"
printf 'let value = 1 # user edits\n' >"$scratch/tree/apps/input.nim"
cp "$scratch/tree/apps/input.nim" "$scratch/original"
for corrupt_kind in semantic parse drift; do
  export CORRUPT_KIND="$corrupt_kind"
  for mode in write check; do
    args=()
    [ "$mode" = write ] || args=(--check)
    if bash "$scratch/tree/scripts/format_sources.sh" "${args[@]}" >"$scratch/log" 2>&1; then
      echo "FAIL: $mode accepted $corrupt_kind corruption" >&2; exit 1
    fi
    grep -q 'apps/input.nim' "$scratch/log"
    # Check mode also exits nonzero for a file that merely would change, so
    # require the fixed-point refusal by name.
    if [ "$corrupt_kind" = drift ]; then
      grep -q 'not a fixed point' "$scratch/log"
    fi
    cmp "$scratch/original" "$scratch/tree/apps/input.nim"
  done
done
unset CORRUPT_KIND

# Exercise both complete publication paths with the actual formatter and nixfmt.
rm "$scratch/bin/nimpretty"
ln -s "$real" "$scratch/bin/nimpretty"
printf '{}\n' >"$scratch/tree/flake.nix"
printf 'let value=1\n' >"$scratch/tree/apps/input.nim"
cp "$scratch/tree/apps/input.nim" "$scratch/original"
if bash "$scratch/tree/scripts/format_sources.sh" --check >"$scratch/log" 2>&1; then
  echo 'FAIL: check accepted unformatted input' >&2; exit 1
fi
grep -q 'not nimpretty-clean' "$scratch/log"
cmp "$scratch/original" "$scratch/tree/apps/input.nim"
bash "$scratch/tree/scripts/format_sources.sh"
if cmp -s "$scratch/original" "$scratch/tree/apps/input.nim"; then
  echo "FAIL: write mode left unformatted input unchanged" >&2; exit 1
fi
"$real" --checkEquivalent:"$scratch/original" "$scratch/tree/apps/input.nim"
cp "$scratch/tree/apps/input.nim" "$scratch/formatted-copy"
bash "$scratch/tree/scripts/format_sources.sh" --check
cmp "$scratch/formatted-copy" "$scratch/tree/apps/input.nim"

# An old formatter may return success for unknown flags; capability detection
# must reject it before touching an input.
rm "$scratch/bin/nimpretty"
printf '#!/usr/bin/env bash\necho "old formatter help"\nexit 0\n' >"$scratch/bin/nimpretty"
chmod +x "$scratch/bin/nimpretty"
if bash "$scratch/tree/scripts/format_sources.sh" >"$scratch/log" 2>&1; then
  echo 'FAIL: accepted formatter without verifier' >&2; exit 1
fi
grep -q 'lacks the required AST verifier' "$scratch/log"
cmp "$scratch/formatted-copy" "$scratch/tree/apps/input.nim"

# A minimal PATH genuinely omits nimpretty rather than returning a fake error.
mkdir "$scratch/missing-bin"
ln -s "$(command -v dirname)" "$scratch/missing-bin/dirname"
if PATH="$scratch/missing-bin" "$(command -v bash)" "$scratch/tree/scripts/format_sources.sh" >"$scratch/log" 2>&1; then
  echo 'FAIL: accepted missing formatter' >&2; exit 1
fi
grep -q 'nimpretty not found' "$scratch/log"
cmp "$scratch/formatted-copy" "$scratch/tree/apps/input.nim"

# Same token spellings but changed indentation must also fail.
printf 'if true:\n  echo 1\n  echo 2\n' >"$scratch/a.nim"
printf 'if true:\n  echo 1\necho 2\n' >"$scratch/b.nim"
if "$real" --checkEquivalent:"$scratch/a.nim" "$scratch/b.nim"; then
  echo 'FAIL: checker accepted indentation change' >&2; exit 1
fi
for pair in '1|2' '0xff|255' '"one"|"two"' '1\x27i32|1\x27i64'; do
  printf "let value = %b\n" "${pair%|*}" >"$scratch/a.nim"
  printf "let value = %b\n" "${pair#*|}" >"$scratch/b.nim"
  if "$real" --checkEquivalent:"$scratch/a.nim" "$scratch/b.nim"; then
    echo 'FAIL: checker accepted literal change' >&2; exit 1
  fi
done
printf 'proc value() {.noSideEffect.} = discard\n' >"$scratch/a.nim"
printf 'proc value() = discard\n' >"$scratch/b.nim"
if "$real" --checkEquivalent:"$scratch/a.nim" "$scratch/b.nim"; then
  echo 'FAIL: checker accepted pragma deletion' >&2; exit 1
fi
echo 'format safety integration passed'
