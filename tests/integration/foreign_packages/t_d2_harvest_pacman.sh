#!/usr/bin/env bash
# t_d2_harvest_pacman.sh — D2 P2 integration gate for the pacman harvester.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

d2_pacman_harvester_binary() {
  if [[ -n "${D2_PACMAN_HARVESTER_BIN:-}" ]]; then
    echo "$D2_PACMAN_HARVESTER_BIN"
    return
  fi
  for c in \
      "$REPO_ROOT/apps/repro-harvest-pacman/repro_harvest_pacman.exe" \
      "$REPO_ROOT/apps/repro-harvest-pacman/repro_harvest_pacman"; do
    if [[ -x "$c" ]]; then echo "$c"; return; fi
  done
  echo "ERROR: cannot locate repro_harvest_pacman binary" >&2
  echo "  build via: nim c -d:ssl --path:apps/repro-harvest-pacman/src --path:apps/repro-harvest-apt/src apps/repro-harvest-pacman/repro_harvest_pacman.nim" >&2
  exit 1
}

d2_pacman_fixture_builder() {
  for c in \
      "$REPO_ROOT/tests/integration/foreign_packages/lib/pacman_fixture_build.exe" \
      "$REPO_ROOT/tests/integration/foreign_packages/lib/pacman_fixture_build"; do
    if [[ -x "$c" ]]; then echo "$c"; return; fi
  done
  echo "ERROR: cannot locate pacman_fixture_build helper" >&2
  exit 1
}

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

if command -v mktemp >/dev/null 2>&1; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/d2-pacman.XXXXXX")"
else
  workdir="${TMPDIR:-/tmp}/d2-pacman.$$"
  mkdir -p "$workdir"
fi
trap 'rm -rf "$workdir"' EXIT

"$(d2_pacman_fixture_builder)" "$workdir" >/dev/null

out="$workdir/out"
mkdir -p "$out"

"$(d2_pacman_harvester_binary)" \
  --source "pacman:htop@archlinux/rolling:20260601" \
  --output-dir "$out" \
  --cache-dir "$workdir/cache" \
  --gpg-keys "$workdir/keys" \
  --offline \
  --signature-backend fingerprint-allowlist \
  --rate-ms 0 >/dev/null

# Expected closure for htop: htop + ncurses + glibc + gcc-libs (ncurses
# carries gcc-libs as a dep). 4 catalog files.
count=$(find "$out/pacman" -maxdepth 1 -name '*.json' | wc -l)
if [[ "$count" -ne 4 ]]; then
  fail "expected 4 catalog files, got $count under $out/pacman"
fi
ok "harvested 4 catalog files"

# htop.json dep closure: gcc-libs + glibc + ncurses.
expected="gcc-libs glibc ncurses"
got=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
names = sorted(d["name"] for d in j["dependency_closure"])
print(" ".join(names))
' "$out/pacman/htop.json")
if [[ "$got" != "$expected" ]]; then
  fail "htop dep closure mismatch
  expected: $expected
  got:      $got"
fi
ok "htop.json dep closure matches"

# Each .pkg.tar.zst URL points at archive.archlinux.org repos path.
for j in "$out"/pacman/*.json; do
  url=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
print(j["provisioning_methods"][0]["url"])
' "$j")
  if [[ "$url" != https://archive.archlinux.org/repos/2026/06/01/core/os/x86_64/* ]]; then
    fail "catalog $j has malformed URL: $url"
  fi
done
ok "all .pkg URLs point at archive.archlinux.org/repos path"

echo "PASS: t_d2_harvest_pacman"
