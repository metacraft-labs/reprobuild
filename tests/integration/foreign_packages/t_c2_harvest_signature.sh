#!/usr/bin/env bash
# t_c2_harvest_signature.sh — C2 integration gate.
#
# Tamper with the cached Packages index by flipping a single byte.
# The harvester must refuse to proceed with a signature-mismatch
# error (the InRelease's SHA256: line lists the un-tampered digest;
# the harvester re-hashes the fetched bytes before walking).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

workdir="$(c2_make_workdir c2-sig)"
trap 'rm -rf "$workdir"' EXIT

c2_build_fixture "$workdir"
out="$workdir/out"
mkdir -p "$out"

# Sanity: clean fixture harvests successfully.
c2_run_harvester "$workdir" "$out" \
  "apt:git@debian/bookworm:20260601T000000Z" >/dev/null
c2_ok "clean fixture harvest succeeded"

# Now tamper with the Packages index: flip a byte in the middle.
pkg_file="$workdir/cache/snapshot.debian.org/archive/debian/20260601T000000Z/dists/bookworm/main/binary-amd64/Packages"
if [[ ! -f "$pkg_file" ]]; then
  c2_fail "fixture Packages file missing at $pkg_file"
fi
python3 - "$pkg_file" <<'PY'
import sys
path = sys.argv[1]
with open(path, "rb") as f:
    data = bytearray(f.read())
# Flip byte at offset 100 — guaranteed to be inside the first stanza.
data[100] ^= 0x01
with open(path, "wb") as f:
    f.write(data)
print(f"tampered {path}", file=sys.stderr)
PY

# Retry: harvester must exit 2 (signature verification failure).
rm -rf "$out"
mkdir -p "$out"
set +e
"$(c2_harvester_binary)" \
  --source "apt:git@debian/bookworm:20260601T000000Z" \
  --output-dir "$out" \
  --cache-dir "$workdir/cache" \
  --gpg-keys "$workdir/keys" \
  --offline \
  --signature-backend fingerprint-allowlist \
  --rate-ms 0 \
  > "$workdir/stdout.log" 2> "$workdir/stderr.log"
exit_code=$?
set -e

if [[ "$exit_code" -ne 2 ]]; then
  echo "stderr:" >&2
  cat "$workdir/stderr.log" >&2
  c2_fail "expected harvester to exit 2 (signature failure), got $exit_code"
fi
c2_ok "harvester refused tampered Packages index (exit 2)"

# The error message should mention sha256.
if ! grep -qiE "(sha256|signature)" "$workdir/stderr.log"; then
  cat "$workdir/stderr.log" >&2
  c2_fail "expected error message to cite sha256/signature mismatch"
fi
c2_ok "error message cites sha256/signature mismatch"

# Also: no catalog files should have been written.
if [[ -d "$out/apt" ]] && [[ "$(find "$out/apt" -name '*.json' | wc -l)" -gt 0 ]]; then
  c2_fail "harvester wrote catalog files despite refusing the index"
fi
c2_ok "no catalog files emitted on signature failure"

echo "PASS: t_c2_harvest_signature"
