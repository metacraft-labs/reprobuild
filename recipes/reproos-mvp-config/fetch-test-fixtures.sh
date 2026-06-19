#!/usr/bin/env bash
# Provision the jammy .deb fixtures the NDE0-A apt-jammy adapter test
# (libs/repro_dsl_stdlib/tests/t_nde0a_apt_jammy.nim) reads from
# recipes/reproos-mvp-config/vendored-archives/linux/.
#
# The test pins each fixture's SHA-256 and fails loudly when a fixture
# is missing (it does NOT silently skip). These are real Ubuntu jammy
# packages downloaded from the official archive — small, pure-data /
# leaf packages chosen by the test for the extract / store-path /
# determinism / systemd-unit cases. We download rather than vendor the
# binaries into git.
#
# Idempotent: a file already present with the expected SHA-256 is left
# alone; a download whose hash does not match is deleted so the test
# fails loudly on a missing fixture rather than consuming corrupt bytes.
#
# Best-effort: a failed download (e.g. no network) is warned about and
# skipped so this step never aborts the wider test run — the test
# itself remains the gate.
#
# Linux-only: the fixtures and the asserted layout are Debian/Ubuntu
# specific, matching the test's platform guard.

set -uo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/vendored-archives/linux"
MIRROR="${UBUNTU_ARCHIVE_MIRROR:-http://archive.ubuntu.com/ubuntu}"

mkdir -p "$OUT_DIR"

log() { echo "[nde0a-fixtures] $*" >&2; }

# Each entry: <relative-pool-path> <expected-sha256>
# The filename is the basename of the pool path.
FIXTURES=(
  "pool/main/libd/libdrm/libdrm-common_2.4.113-2~ubuntu0.22.04.1_all.deb 35a306712d8b15b30c42ecd73ec087813eb01c0b3125dc8f7ca2b5134e133522"
  "pool/universe/f/foot/foot-terminfo_1.11.0-2_all.deb f96344f31bc8f02aea4c3e82e451bca8ea2c723954dd5cbe5725f1eb2c0feffd"
  "pool/main/a/accountsservice/accountsservice_22.07.5-2ubuntu1.5_amd64.deb 95ef667f9ada1acb2629bb98d3aa004dcf49a694430ac46b72d9add43adc569d"
)

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

for entry in "${FIXTURES[@]}"; do
  rel="${entry%% *}"
  want="${entry##* }"
  name="$(basename "$rel")"
  dest="$OUT_DIR/$name"

  if [ -f "$dest" ] && [ "$(sha_of "$dest")" = "$want" ]; then
    continue
  fi

  log "fetching $name"
  if ! curl -fsSL -o "$dest.tmp" "$MIRROR/$rel"; then
    log "WARN: download failed for $name ($MIRROR/$rel); the test will report it missing"
    rm -f "$dest.tmp"
    continue
  fi

  got="$(sha_of "$dest.tmp")"
  if [ "$got" != "$want" ]; then
    log "WARN: SHA-256 mismatch for $name (got $got, want $want); discarding"
    rm -f "$dest.tmp"
    continue
  fi
  mv -f "$dest.tmp" "$dest"
done

exit 0
