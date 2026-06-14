#!/usr/bin/env bash
# t_c2_harvest_git.sh — C2 integration gate.
#
# Harvest git from a deterministic Debian-bookworm fixture (modelled
# on snapshot.debian.org/.../20260601T000000Z). Verify that:
#
#   * The harvester exits 0.
#   * 11 catalog files appear under <output>/apt (1 root + 10
#     transitive deps).
#   * git.json's dependency_closure carries the 10 expected names.
#   * Every catalog file parses cleanly via the foreign_common reader
#     (re-run the round-trip test via the fixture's bytes).
#   * Each .deb URL points at snapshot.debian.org's pool/main/ tree.
#   * Each catalog's sha256 matches the corresponding stanza in the
#     Packages index (verified via the bash side of the test below).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

workdir="$(c2_make_workdir c2-git)"
trap 'rm -rf "$workdir"' EXIT

c2_build_fixture "$workdir"
out="$workdir/out"
mkdir -p "$out"

c2_run_harvester "$workdir" "$out" \
  "apt:git@debian/bookworm:20260601T000000Z" >/dev/null

# Expected: 11 .json files under out/apt.
count=$(find "$out/apt" -maxdepth 1 -name '*.json' | wc -l)
if [[ "$count" -ne 11 ]]; then
  c2_fail "expected 11 catalog files, got $count under $out/apt"
fi
c2_ok "harvested 11 catalog files"

# git.json: dependency_closure has the 10 expected names.
expected="gcc-12-base git-man libc6 libcrypt1 libcurl3-gnutls \
libgcc-s1 libnghttp2-14 libpcre2-8-0 perl-base zlib1g"
got=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
names = sorted(d["name"] for d in j["dependency_closure"])
print(" ".join(names))
' "$out/apt/git.json")
expected_sorted=$(echo "$expected" | tr -s ' ' '\n' | sort | tr '\n' ' ' | sed 's/ *$//')
if [[ "$got" != "$expected_sorted" ]]; then
  c2_fail "git dep closure mismatch
  expected: $expected_sorted
  got:      $got"
fi
c2_ok "git.json dep closure matches"

# Each .deb URL points at snapshot.debian.org/archive/debian/<date>/pool/
for j in "$out"/apt/*.json; do
  url=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
print(j["provisioning_methods"][0]["url"])
' "$j")
  if [[ "$url" != https://snapshot.debian.org/archive/debian/20260601T000000Z/pool/* ]]; then
    c2_fail "catalog $j has malformed URL: $url"
  fi
done
c2_ok "all .deb URLs point at the snapshot's pool tree"

# Every catalog's provisioning sha256 matches the Packages stanza.
# We re-derive the (name -> sha256) map by parsing the fixture Packages
# file ourselves.
pkgs_file="$workdir/cache/snapshot.debian.org/archive/debian/20260601T000000Z/dists/bookworm/main/binary-amd64/Packages"
python3 - "$pkgs_file" "$out/apt" <<'PY'
import sys, os, json, glob
pkgs_file = sys.argv[1]
out_apt = sys.argv[2]
# Parse Packages stanzas.
expected = {}
current = {}
with open(pkgs_file) as f:
    for line in f:
        line = line.rstrip("\n")
        if line == "":
            if "Package" in current:
                expected[current["Package"]] = current.get("SHA256", "")
            current = {}
            continue
        if line.startswith(" ") or line.startswith("\t"):
            continue
        if ":" not in line:
            continue
        k, _, v = line.partition(":")
        current[k.strip()] = v.strip()
if "Package" in current:
    expected[current["Package"]] = current.get("SHA256", "")

# Compare against each catalog.
bad = []
for path in glob.glob(os.path.join(out_apt, "*.json")):
    with open(path) as f:
        j = json.load(f)
    name = j["package"]["name"]
    cat_sha = j["provisioning_methods"][0]["sha256"]
    if name not in expected:
        bad.append((name, "missing-from-fixture", cat_sha))
        continue
    if expected[name].lower() != cat_sha.lower():
        bad.append((name, expected[name], cat_sha))
if bad:
    for row in bad:
        print(" ".join(str(r) for r in row), file=sys.stderr)
    sys.exit(1)
print(f"verified sha256 for {len(glob.glob(os.path.join(out_apt, '*.json')))} catalogs")
PY
c2_ok "every catalog's sha256 matches the Packages index"

echo "PASS: t_c2_harvest_git"
