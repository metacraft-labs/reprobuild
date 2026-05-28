#!/usr/bin/env bash
# ==============================================================================
# M29 Part C — Nix catalog attribute verification gate.
#
# Walks every ``libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages/*.nim``
# entry, parses its ``nixPackage "nixpkgs#<attr>"`` selector + ``nixpkgsRev``,
# and asks ``nix eval --refresh`` whether the attribute actually resolves on
# the pinned nixpkgs revision.
#
# Why this exists
# ---------------
# Catalog entries are written ahead of being dispatched (M7, M29 Part B);
# the only thing that promises a given selector + pin combination still
# resolves is the catalog file's own pin string. Nixpkgs renames /
# removes packages periodically (e.g. ``python3Packages.pyproject-hooks``
# vs ``python3Packages.pyproject_hooks``, ``nodejs-slim`` vs ``nodejs``).
# This gate catches such drift before it ships as a runtime
# ``error: attribute '<attr>' missing`` from a user repro build.
#
# Failure modes
# -------------
# Per-entry result is one of:
#   OK         : ``nix eval`` returned 0 and produced a derivation path.
#   MISSING    : ``nix eval`` reported the attribute is unknown.
#   ERROR      : ``nix eval`` exited non-zero for some other reason
#                (network failure, evaluation error in nixpkgs).
#
# The script exits non-zero if any entry reports MISSING; ERROR is
# reported but doesn't fail the gate by default (we don't want a
# transient nixpkgs-side network blip to break unrelated CI). Pass
# ``--strict`` to also fail on ERROR.
#
# Invocation
# ----------
#   ./scripts/verify-nix-catalog-attrs.sh             # Linux/macOS native
#   nix develop -c ./scripts/verify-nix-catalog-attrs.sh
#   nix develop -c ./scripts/verify-nix-catalog-attrs.sh --strict
#
# The script requires ``nix`` with flakes enabled (the existing
# ``flake.nix`` dev shell guarantees this on Linux/macOS hosts; on
# Windows the gate skips with exit 0 since native ``nix`` isn't
# typically installed there).
# ==============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packages_dir="${repo_root}/libs/repro_dsl_stdlib/src/repro_dsl_stdlib/packages"

strict=0
case "${1:-}" in
  --strict) strict=1 ;;
  --help|-h)
    head -42 "$0" | sed -n '1,42p' >&2
    exit 0
    ;;
  '') ;;
  *)
    echo "verify-nix-catalog-attrs.sh: unknown argument: $1" >&2
    exit 2
    ;;
esac

case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux|Darwin) ;;
  *)
    echo "verify-nix-catalog-attrs.sh: skipping — only supported on Linux/macOS hosts" >&2
    exit 0
    ;;
esac

if ! command -v nix >/dev/null 2>&1; then
  echo "verify-nix-catalog-attrs.sh: skipping — 'nix' not on PATH" >&2
  exit 0
fi

if [ ! -d "${packages_dir}" ]; then
  echo "FAIL: packages directory not found: ${packages_dir}" >&2
  exit 1
fi

total=0
ok=0
missing=0
errored=0
declare -a missing_attrs=()
declare -a errored_attrs=()

# parse_field <file> <field>
#   Echoes the value of ``<field> = "<value>"`` from the catalog file's
#   ``provisioning:`` block, or empty if not found.
parse_field() {
  local file="$1"
  local field="$2"
  awk -v field="${field}" '
    $0 ~ field"[[:space:]]*=" {
      n = match($0, /"[^"]*"/)
      if (n > 0) {
        s = substr($0, RSTART + 1, RLENGTH - 2)
        print s
        exit
      }
    }
  ' "${file}"
}

# parse_nix_selector <file>
#   Echoes the bare attribute path (without the leading ``nixpkgs#``).
parse_nix_selector() {
  local file="$1"
  awk '
    /nixPackage[[:space:]]*"nixpkgs#/ {
      n = match($0, /"nixpkgs#[^"]+"/)
      if (n > 0) {
        s = substr($0, RSTART + 1, RLENGTH - 2)
        sub(/^nixpkgs#/, "", s)
        print s
        exit
      }
    }
  ' "${file}"
}

for file in "${packages_dir}"/*.nim; do
  [ -f "${file}" ] || continue
  basename_no_ext="$(basename "${file}" .nim)"
  selector="$(parse_nix_selector "${file}" || true)"
  rev="$(parse_field "${file}" "nixpkgsRev" || true)"
  if [ -z "${selector}" ] || [ -z "${rev}" ]; then
    echo "SKIP ${basename_no_ext}: no nixpkgs# selector or rev (likely tarball/scoop)"
    continue
  fi
  total=$((total + 1))
  flakeref="github:NixOS/nixpkgs/${rev}#${selector}"
  printf 'CHECK %-32s -> %s\n' "${basename_no_ext}" "${flakeref}"
  # We probe the .name attribute — it's cheap to evaluate, present on
  # every derivation, and avoids realising the package (which would
  # download arbitrary closures).
  if out=$(nix eval --refresh --raw "${flakeref}.name" 2>&1); then
    ok=$((ok + 1))
    printf '  OK      %s\n' "${out}"
  else
    # Distinguish "attribute missing" from "evaluation error / network".
    if echo "${out}" | grep -Eq "attribute .* missing|does not provide attribute"; then
      missing=$((missing + 1))
      missing_attrs+=("${basename_no_ext}: ${selector}")
      printf '  MISSING (attribute not in nixpkgs/%s)\n' "${rev:0:12}"
    else
      errored=$((errored + 1))
      errored_attrs+=("${basename_no_ext}: ${selector}")
      printf '  ERROR   (nix eval failed; first line: %s)\n' \
        "$(echo "${out}" | head -1)"
    fi
  fi
done

echo
echo "==== Summary ===================================================="
echo "Total checked : ${total}"
echo "OK            : ${ok}"
echo "MISSING       : ${missing}"
echo "ERROR         : ${errored}"

if [ "${missing}" -gt 0 ]; then
  echo
  echo "Missing attributes (FAIL):"
  for entry in "${missing_attrs[@]}"; do
    echo "  - ${entry}"
  done
fi
if [ "${errored}" -gt 0 ]; then
  echo
  echo "Errored attributes (informational):"
  for entry in "${errored_attrs[@]}"; do
    echo "  - ${entry}"
  done
fi

if [ "${missing}" -gt 0 ]; then
  exit 1
fi
if [ "${strict}" -eq 1 ] && [ "${errored}" -gt 0 ]; then
  exit 1
fi
exit 0
