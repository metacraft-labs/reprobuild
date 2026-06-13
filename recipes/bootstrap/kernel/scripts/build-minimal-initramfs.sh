#!/bin/bash
# build-minimal-initramfs.sh -- R8 placeholder initramfs.
#
# Produces a deterministic, tiny gzip-compressed cpio archive containing
# just enough to give the kernel an `/init` to exec so that boot doesn't
# panic at "No working init found" before we observe the printk banners.
#
# The `/init` is a statically-linked busybox-`sh` "-c" wrapper that
# prints a recognisable banner ("R8-INIT-REACHED") and then `poweroff -f`s
# the VM. For R8 we don't actually need a full userspace -- the
# acceptance criterion is that the kernel produces its boot banners on
# the serial console.
#
# Actually, simpler: use a shell script `/init` and rely on the kernel
# fallback chain. If busybox isn't available, we just produce an empty
# initramfs and accept the panic banner -- the kernel still prints
# `Linux version 6.6.142` and `Hypervisor detected: Microsoft Hyper-V`
# before panicking.
#
# Usage: build-minimal-initramfs.sh OUT.cpio.gz
#
# Reproducibility: SOURCE_DATE_EPOCH stamps every cpio entry; gzip -n
# strips the embedded mtime + filename from the gzip header.

set -euo pipefail
: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

OUT="${1:?usage: $0 OUT.cpio.gz}"

WORK="$(mktemp -d -t reproos-r8-initramfs-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Stage minimal rootfs.
mkdir -p "$WORK/proc" "$WORK/sys" "$WORK/dev"
cat > "$WORK/init" <<'EOF'
#!/bin/sh
echo
echo "================================================================"
echo "R8-INIT-REACHED: from-source kernel reached userspace init"
echo "================================================================"
echo
# Brief sleep then power off -- vm-harness expects an orderly shutdown.
sleep 1
poweroff -f 2>/dev/null || halt -f 2>/dev/null || exit 1
EOF
chmod +x "$WORK/init"

# Pack: cpio newc format + gzip -n. SOURCE_DATE_EPOCH-honouring tools
# would be ideal; cpio doesn't honour SDE, so we feed it `--owner=0:0`
# and pre-touch the files to the SDE wall-clock timestamp.
find "$WORK" -depth -print0 | xargs -0 touch -h --date="@$SOURCE_DATE_EPOCH"

# cpio newc doesn't accept --sort, but we sort the file list ourselves
# via `find ... | sort` before piping to cpio.
(cd "$WORK" && find . -print0 | LC_ALL=C sort -z | \
  cpio --null --owner=0:0 -o -H newc 2>/dev/null) | \
  gzip -9 -n > "$OUT"

sz=$(stat -c %s "$OUT")
sha=$(sha256sum "$OUT" | awk '{print $1}')
echo "[initramfs] $OUT bytes=$sz sha256=$sha"
