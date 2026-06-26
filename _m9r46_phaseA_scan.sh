#!/usr/bin/env bash
# M9.R.46 Phase A — characterise the /nix/store leak baseline.
#
# Scans every ELF in /opt (from-source install-mirror) + /usr + /bin + /sbin
# of an extracted live-ISO rootfs and emits the unique set of
# /nix/store/<hash>-pkg/ prefixes referenced by RPATH or PT_INTERP.
#
# Usage:  bash _m9r46_phaseA_scan.sh <rootfs-dir> <out-dir>
#         Outputs to <out-dir>/{leak_prefixes.txt, leak_per_elf.tsv, leak_summary.txt}.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "usage: $0 <rootfs-dir> <out-dir>" >&2
  exit 64
fi
ROOTFS="$1"
OUT="$2"
mkdir -p "$OUT"

LEAK_TSV="$OUT/leak_per_elf.tsv"
PREFIXES="$OUT/leak_prefixes.txt"
SUMMARY="$OUT/leak_summary.txt"

: > "$LEAK_TSV"
: > "$PREFIXES"
: > "$SUMMARY"

scan_dirs=()
for d in opt usr bin sbin lib lib64; do
  [ -d "$ROOTFS/$d" ] && scan_dirs+=("$ROOTFS/$d")
done

if [ "${#scan_dirs[@]}" -eq 0 ]; then
  echo "no scan dirs under $ROOTFS" >&2
  exit 1
fi

echo "[Phase A] scanning ELFs in: ${scan_dirs[*]}" >&2

# Collect all ELF candidate paths first.
candidates="$(mktemp)"
trap 'rm -f "$candidates"' EXIT
find "${scan_dirs[@]}" -type f \
  \( -name '*.so' -o -name '*.so.*' -o -perm -u+x \) 2>/dev/null > "$candidates"
total_cands=$(wc -l < "$candidates")
echo "[Phase A] $total_cands candidate ELFs to inspect" >&2

elfs_inspected=0
elfs_with_leak=0
while IFS= read -r f; do
  # Cheap ELF check.
  magic=$(head -c 4 "$f" 2>/dev/null | od -An -c | tr -d ' \n' || true)
  case "$magic" in
    177ELF*) : ;;
    *) continue ;;
  esac
  elfs_inspected=$((elfs_inspected + 1))
  rp=$(patchelf --print-rpath "$f" 2>/dev/null || true)
  ip=$(patchelf --print-interpreter "$f" 2>/dev/null || true)
  any_leak=0
  # Emit one TSV row per (prefix, elf) pair.
  for ent in $(printf '%s\n%s\n' "$rp" "$ip" | tr ':' '\n' \
               | sed -nE 's|^(/nix/store/[^/]+).*|\1|p' | sort -u); do
    printf '%s\t%s\n' "$ent" "$f" >> "$LEAK_TSV"
    any_leak=1
  done
  [ "$any_leak" = 1 ] && elfs_with_leak=$((elfs_with_leak + 1))
done < "$candidates"

# Unique prefixes.
awk '{print $1}' "$LEAK_TSV" | sort -u > "$PREFIXES"
n_prefixes=$(wc -l < "$PREFIXES")

# Aggregate disk usage for each referenced prefix (only those present
# on the rootfs).
total_bytes=0
while IFS= read -r p; do
  staged="$ROOTFS$p"
  if [ -d "$staged" ]; then
    sz=$(du -sb "$staged" 2>/dev/null | awk '{print $1}')
    [ -n "$sz" ] && total_bytes=$((total_bytes + sz))
  fi
done < "$PREFIXES"

{
  echo "M9.R.46 Phase A leak baseline"
  echo "============================="
  echo "rootfs scanned       : $ROOTFS"
  echo "scan dirs            : ${scan_dirs[*]}"
  echo "ELF candidates       : $total_cands"
  echo "ELFs inspected (true ELF magic): $elfs_inspected"
  echo "ELFs referencing /nix/store    : $elfs_with_leak"
  echo "unique /nix/store/<hash> prefixes: $n_prefixes"
  echo "total bytes on rootfs across them: $total_bytes"
  awk -v b=$total_bytes 'BEGIN{ printf "                                 : %.2f MiB\n", b/1024/1024 }'
  echo ""
  echo "Per-prefix referenced-by-ELF count (sorted):"
  awk -F'\t' '{print $1}' "$LEAK_TSV" | sort | uniq -c | sort -rn
} > "$SUMMARY"

echo "[Phase A] wrote $PREFIXES ($n_prefixes prefixes), $LEAK_TSV, $SUMMARY" >&2
