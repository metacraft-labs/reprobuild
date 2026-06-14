#!/usr/bin/env bash
# t_c2_harvest_multipackage.sh — C2 integration gate.
#
# Harvest {git,vim,curl} together from the fixture. Verify:
#
#   * Three catalog "roots" exist (git.json, vim.json, curl.json).
#   * Shared transitive deps (libc6, zlib1g, libnghttp2-14, ...) appear
#     exactly once in the output.
#   * Catalog file count matches the union closure.
#   * Idempotent: a second run produces byte-identical output.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

workdir="$(c2_make_workdir c2-multi)"
trap 'rm -rf "$workdir"' EXIT

c2_build_fixture "$workdir"
out="$workdir/out"
mkdir -p "$out"

c2_run_harvester "$workdir" "$out" \
  "apt:{git,vim,curl}@debian/bookworm:20260601T000000Z" >/dev/null

# Three root catalog files present.
for root in git vim curl; do
  if [[ ! -f "$out/apt/${root}.json" ]]; then
    c2_fail "expected catalog for root '$root' at $out/apt/${root}.json"
  fi
done
c2_ok "three root catalogs (git, vim, curl) all present"

# No duplicates.
count=$(find "$out/apt" -maxdepth 1 -name '*.json' | wc -l)
# Union closure for the fixture:
#   git:   git, git-man, libc6, libcurl3-gnutls, libpcre2-8-0, zlib1g,
#          libgcc-s1, libcrypt1, libnghttp2-14, gcc-12-base, perl-base
#   vim:   vim, libc6 (shared), libtinfo6, perl-base (shared)
#   curl:  curl, libc6 (shared), libcurl4, libnghttp2-14 (shared),
#          zlib1g (shared)
# New deps from vim:   vim + libtinfo6                                2
# New deps from curl:  curl + libcurl4                                2
# Union:               11 + 2 + 2 = 15 distinct names
expected=15
if [[ "$count" -ne "$expected" ]]; then
  echo "catalog files found:" >&2
  ls "$out/apt" >&2
  c2_fail "expected $expected union-closure catalogs, got $count"
fi
c2_ok "union closure has $count distinct catalog files (no duplicates)"

# libc6 appears in every root's dependency_closure.
for root in git vim curl; do
  has_libc=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
for d in j["dependency_closure"]:
    if d["name"] == "libc6":
        print("yes")
        break
else:
    print("no")
' "$out/apt/${root}.json")
  if [[ "$has_libc" != "yes" ]]; then
    c2_fail "expected libc6 in dependency_closure of $root"
  fi
done
c2_ok "shared dep libc6 is reachable from every root"

# Idempotency: a second run produces byte-identical output.
out2="$workdir/out2"
mkdir -p "$out2"
c2_run_harvester "$workdir" "$out2" \
  "apt:{git,vim,curl}@debian/bookworm:20260601T000000Z" >/dev/null
diff -r "$out" "$out2" > "$workdir/diff.log" 2>&1 || true
if [[ -s "$workdir/diff.log" ]]; then
  cat "$workdir/diff.log" >&2
  c2_fail "multi-package run is not idempotent"
fi
c2_ok "multi-package run is byte-identical on re-run"

echo "PASS: t_c2_harvest_multipackage"
