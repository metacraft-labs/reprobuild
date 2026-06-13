#!/bin/bash
# R8 reproducibility-audit helper: extract the compressed vmlinux from
# bzImage and look for embedded host paths / verify the Linux banner
# carries the pinned KBUILD_BUILD_{USER,HOST}.
set -e
W=/tmp/r8-audit
rm -rf "$W"
mkdir -p "$W"
cd "$W"
tar -xf /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/vendor/linux-6.6.142.tar.xz linux-6.6.142/scripts/extract-vmlinux
B=/mnt/d/metacraft/reprobuild/build/r8-build/bzImage
EX=linux-6.6.142/scripts/extract-vmlinux
chmod +x "$EX"
echo '--- Linux banner ---'
"./$EX" "$B" 2>/dev/null | strings | grep -E '^Linux version 6\.6\.142' | head -3 || true
echo
echo '--- /tmp /home leaks in extracted vmlinux ---'
LEAKS=$("./$EX" "$B" 2>/dev/null | strings | grep -E '/tmp/|/home/' | sort -u || true)
if [ -z "$LEAKS" ]; then
  echo '(none)'
else
  echo "$LEAKS"
fi
echo
echo '--- size of extracted vmlinux ---'
"./$EX" "$B" 2>/dev/null | wc -c
