#!/bin/bash
# Helper to materialize tinycc-mes archive from a local clone.
set -e
REV=cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341
SHORTREV="${REV:0:7}"
CLONE=/tmp/tinycc-clone
OUT=/tmp/tinycc-mes-build

mkdir -p "$OUT"
cd "$OUT"
rm -rf "tinycc-${SHORTREV}"

# Use git archive into stdout, untar
git --git-dir="$CLONE/.git" archive --prefix="tinycc-${SHORTREV}/" "$REV" | tar -x

echo "ls of extract:"
ls "tinycc-${SHORTREV}" | head -10
echo "size: $(du -sh tinycc-${SHORTREV})"
echo "file count: $(find tinycc-${SHORTREV} -type f | wc -l)"
