#!/usr/bin/env bash
# R2 reproducibility gate.
#
# Builds the R2 reproos-iso recipe three times back-to-back in clean
# build dirs and asserts that all three produced ISOs have the same
# sha256. If reproducibility breaks, the script saves the three ISOs
# to artifacts/ and prints the byte-diff summary (first 60 differing
# bytes via `cmp -l`).
#
# Designed to run inside the `repro-debian` WSL distro (it requires
# xorriso + grub-mkrescue + mtools + sha256sum; the host doesn't have
# these on Windows). From PowerShell:
#
#   wsl -d repro-debian -- bash tests/reproducibility/t_r2_iso_reproducibility.sh
#
# Honours $REPROOS_ISO_INPUT_KERNEL and $REPROOS_ISO_INPUT_INITRAMFS
# overrides so a future R10 run can point at the from-source artefacts
# without modifying the script. Defaults are the vendored
# kernel/initramfs under recipes/reproos-iso/vendor/.

set -euo pipefail

# Locate the repo root by walking up from the script. This script
# lives at tests/reproducibility/ ; root is two levels up.
script_dir=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$script_dir/../.." && pwd)

kernel=${REPROOS_ISO_INPUT_KERNEL:-"$repo_root/recipes/reproos-iso/vendor/vmlinuz-debian-netinst"}
initramfs=${REPROOS_ISO_INPUT_INITRAMFS:-"$repo_root/recipes/reproos-iso/vendor/initrd.img-debian-netinst"}

if [ ! -f "$kernel" ]; then
  echo "kernel input missing: $kernel" >&2
  echo "run: pwsh recipes/reproos-iso/vendor/fetch.ps1" >&2
  exit 65
fi
if [ ! -f "$initramfs" ]; then
  echo "initramfs input missing: $initramfs" >&2
  echo "run: pwsh recipes/reproos-iso/vendor/fetch.ps1" >&2
  exit 65
fi

for tool in xorriso grub-mkrescue mformat sha256sum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "required tool missing: $tool" >&2
    echo "install: apt-get install -y xorriso grub-pc-bin grub-efi-amd64-bin mtools coreutils" >&2
    exit 66
  fi
done

# Each rebuild gets a fresh build dir so a previous run's stale
# artefacts can't bias the result.
build_root="$repo_root/build/r2-iso-reproducibility"
rm -rf "$build_root"
mkdir -p "$build_root"

sha_a=""
sha_b=""
sha_c=""
size=""

for i in 1 2 3; do
  out_dir="$build_root/rebuild-$i"
  mkdir -p "$out_dir"
  iso="$out_dir/reproos.iso"

  echo "[$(date -u +%H:%M:%S)] rebuild $i ..."
  SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
    bash "$repo_root/recipes/reproos-iso/scripts/build-iso.sh" \
    "$kernel" "$initramfs" "$iso" >/dev/null

  if [ ! -f "$iso" ]; then
    echo "rebuild $i did not produce $iso" >&2
    exit 67
  fi
  sha=$(sha256sum "$iso" | awk '{print $1}')
  bytes=$(stat -c %s "$iso")
  echo "  sha256=$sha bytes=$bytes"

  case $i in
    1) sha_a=$sha; size=$bytes ;;
    2) sha_b=$sha ;;
    3) sha_c=$sha ;;
  esac
done

if [ "$sha_a" = "$sha_b" ] && [ "$sha_b" = "$sha_c" ]; then
  echo
  echo "PASS: all 3 rebuilds produced bit-identical ISOs"
  echo "  sha256=$sha_a"
  echo "  bytes=$size"
  exit 0
fi

echo
echo "FAIL: reproducibility drift detected" >&2
echo "  rebuild 1: $sha_a" >&2
echo "  rebuild 2: $sha_b" >&2
echo "  rebuild 3: $sha_c" >&2

# Diagnostics: dump first 60 differing bytes via cmp -l for each
# differing pair so the reviewer can see WHERE the drift landed.
for pair in "1:2" "1:3" "2:3"; do
  a_idx=${pair%:*}
  b_idx=${pair#*:}
  iso_a="$build_root/rebuild-$a_idx/reproos.iso"
  iso_b="$build_root/rebuild-$b_idx/reproos.iso"
  if cmp "$iso_a" "$iso_b" >/dev/null 2>&1; then
    continue
  fi
  diff_count=$(cmp -l "$iso_a" "$iso_b" | wc -l)
  echo "  diff $a_idx vs $b_idx: $diff_count bytes; first 60:" >&2
  cmp -l "$iso_a" "$iso_b" 2>/dev/null | head -60 >&2 || true
done

exit 1
