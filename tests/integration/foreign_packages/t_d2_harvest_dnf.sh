#!/usr/bin/env bash
# t_d2_harvest_dnf.sh — D2 P1 integration gate for the dnf harvester.
#
# Harvest htop from a deterministic Fedora-39 fixture (modelled on
# kojipkgs.fedoraproject.org/compose/39/20260601/...). Verify that:
#
#   * The harvester exits 0.
#   * 3 catalog files appear under <output>/dnf (htop + ncurses-libs +
#     glibc).
#   * htop.json's dependency_closure carries ncurses-libs + glibc.
#   * Each .rpm URL points at the snapshot host's path.
#   * Each catalog's sha256 matches the fixture primary.xml stanza.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

d2_dnf_harvester_binary() {
  if [[ -n "${D2_DNF_HARVESTER_BIN:-}" ]]; then
    echo "$D2_DNF_HARVESTER_BIN"
    return
  fi
  for c in \
      "$REPO_ROOT/apps/repro-harvest-dnf/repro_harvest_dnf.exe" \
      "$REPO_ROOT/apps/repro-harvest-dnf/repro_harvest_dnf"; do
    if [[ -x "$c" ]]; then echo "$c"; return; fi
  done
  echo "ERROR: cannot locate repro_harvest_dnf binary" >&2
  echo "  build via: nim c -d:ssl --path:apps/repro-harvest-dnf/src --path:apps/repro-harvest-apt/src apps/repro-harvest-dnf/repro_harvest_dnf.nim" >&2
  exit 1
}

d2_dnf_fixture_builder() {
  for c in \
      "$REPO_ROOT/tests/integration/foreign_packages/lib/dnf_fixture_build.exe" \
      "$REPO_ROOT/tests/integration/foreign_packages/lib/dnf_fixture_build"; do
    if [[ -x "$c" ]]; then echo "$c"; return; fi
  done
  echo "ERROR: cannot locate dnf_fixture_build helper" >&2
  exit 1
}

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

if command -v mktemp >/dev/null 2>&1; then
  workdir="$(mktemp -d "${TMPDIR:-/tmp}/d2-dnf.XXXXXX")"
else
  workdir="${TMPDIR:-/tmp}/d2-dnf.$$"
  mkdir -p "$workdir"
fi
trap 'rm -rf "$workdir"' EXIT

"$(d2_dnf_fixture_builder)" "$workdir" >/dev/null

out="$workdir/out"
mkdir -p "$out"

"$(d2_dnf_harvester_binary)" \
  --source "dnf:htop@fedora/39:20260601" \
  --output-dir "$out" \
  --cache-dir "$workdir/cache" \
  --gpg-keys "$workdir/keys" \
  --offline \
  --signature-backend fingerprint-allowlist \
  --strict-closure \
  --rate-ms 0 >/dev/null

count=$(find "$out/dnf" -maxdepth 1 -name '*.json' | wc -l)
if [[ "$count" -ne 3 ]]; then
  fail "expected 3 catalog files (htop + ncurses-libs + glibc), got $count under $out/dnf"
fi
ok "harvested 3 catalog files"

# htop.json: dependency_closure has ncurses-libs + glibc.
expected="glibc ncurses-libs"
got=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
names = sorted(d["name"] for d in j["dependency_closure"])
print(" ".join(names))
' "$out/dnf/htop.json")
if [[ "$got" != "$expected" ]]; then
  fail "htop dep closure mismatch
  expected: $expected
  got:      $got"
fi
ok "htop.json dep closure matches"

# Each .rpm URL points at kojipkgs path.
for j in "$out"/dnf/*.json; do
  url=$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    j = json.load(f)
print(j["provisioning_methods"][0]["url"])
' "$j")
  if [[ "$url" != https://kojipkgs.fedoraproject.org/compose/39/20260601/* ]]; then
    fail "catalog $j has malformed URL: $url"
  fi
done
ok "all .rpm URLs point at kojipkgs path"

# Every catalog's provisioning sha256 matches the fixture primary.xml.
python3 - "$workdir" "$out/dnf" <<'PY'
import sys, os, json, glob, xml.etree.ElementTree as ET
workdir = sys.argv[1]
out_dnf = sys.argv[2]
pri_path = os.path.join(workdir, "cache",
  "kojipkgs.fedoraproject.org", "compose", "39", "20260601",
  "compose", "Everything", "x86_64", "os", "repodata", "primary.xml")
tree = ET.parse(pri_path)
root = tree.getroot()
ns = {
  "c": "http://linux.duke.edu/metadata/common",
}
expected = {}
for pkg in root.findall("c:package", ns):
  name = pkg.find("c:name", ns).text.strip()
  chk = pkg.find("c:checksum", ns).text.strip().lower()
  expected[name] = chk

bad = []
for path in glob.glob(os.path.join(out_dnf, "*.json")):
  with open(path) as f:
    j = json.load(f)
  name = j["package"]["name"]
  cat_sha = j["provisioning_methods"][0]["sha256"]
  if name not in expected:
    bad.append((name, "missing-from-fixture", cat_sha))
    continue
  if expected[name] != cat_sha.lower():
    bad.append((name, expected[name], cat_sha))
if bad:
  for row in bad:
    print(" ".join(str(r) for r in row), file=sys.stderr)
  sys.exit(1)
print(f"verified sha256 for {len(glob.glob(os.path.join(out_dnf, '*.json')))} catalogs")
PY
ok "every catalog's sha256 matches the fixture primary.xml"

echo "PASS: t_d2_harvest_dnf"
