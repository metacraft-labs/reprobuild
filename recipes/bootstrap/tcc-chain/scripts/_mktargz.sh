#!/bin/bash
# Determinstic tar.gz of tinycc-mes source tree.
# Matches nixpkgs's repo.or.cz snapshot format if possible; if not, we'll
# pin our own sha256 in the vendor MANIFEST.
set -e
REV=cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341
SHORTREV="${REV:0:7}"
OUT=/tmp/tinycc-mes-build
DEST=/mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/vendor/tinycc-mes.tar.gz

export SOURCE_DATE_EPOCH=1735689600
export LC_ALL=C
export TZ=UTC

cd "$OUT"

# Try standard git archive output -- known-format and reproducible
git --git-dir=/tmp/tinycc-clone/.git archive --format=tar.gz \
    --prefix="tinycc-${SHORTREV}/" "$REV" -o "$DEST"

ls -la "$DEST"
echo "sha256: $(sha256sum "$DEST" | awk '{print $1}')"
