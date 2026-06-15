#!/usr/bin/env bash
# R9 Phase 5: build an initramfs containing our from-source systemd + minimal userspace.
# Path A pragmatic: borrow libc + bash + coreutils + util-linux from the host Ubuntu.
set -euo pipefail
: "${SOURCE_DATE_EPOCH:=1735689600}"
: "${LC_ALL:=C}"
: "${TZ:=UTC}"
export SOURCE_DATE_EPOCH LC_ALL TZ

WORK=/root/r9-work/rootfs
INSTALL=/root/r9-work/systemd-install
OUT=/root/r9-work/initramfs-systemd.cpio.gz

rm -rf "$WORK"
mkdir -p "$WORK"

# Base FHS layout
for d in bin sbin etc proc sys dev run tmp var var/log var/run var/log/journal \
         root home usr usr/bin usr/sbin usr/lib usr/lib/x86_64-linux-gnu \
         usr/lib/x86_64-linux-gnu/systemd usr/lib/x86_64-linux-gnu/security \
         usr/lib/systemd usr/lib/systemd/system usr/lib/systemd/system-generators \
         lib lib64 lib/x86_64-linux-gnu \
         etc/systemd etc/systemd/system etc/pam.d \
         dev/pts dev/shm; do
  mkdir -p "$WORK/$d"
done

# Copy systemd install tree
cp -a "$INSTALL"/* "$WORK/"

# Copy busybox for early init helpers (will get statically-linked busybox)
if ! command -v busybox >/dev/null; then
  apt-get install -y -qq busybox-static >&2
fi
cp /usr/bin/busybox "$WORK/usr/bin/busybox"
for cmd in sh ash bash ls cat echo cp mv rm mkdir mount umount sleep poweroff halt reboot \
           ln chmod chown id stty login getty switch_root; do
  ln -sf busybox "$WORK/usr/bin/$cmd"
done

# Provide /bin and /sbin shims to /usr/bin
(cd "$WORK/bin" && ln -sf ../usr/bin/sh sh && ln -sf ../usr/bin/bash bash \
    && ln -sf ../usr/bin/cat cat && ln -sf ../usr/bin/ls ls \
    && ln -sf ../usr/bin/login login && ln -sf ../usr/bin/mount mount \
    && ln -sf ../usr/bin/umount umount)
(cd "$WORK/sbin" && ln -sf ../usr/lib/systemd/systemd init \
    && ln -sf ../usr/bin/agetty agetty \
    && ln -sf ../usr/bin/poweroff poweroff \
    && ln -sf ../usr/bin/halt halt \
    && ln -sf ../usr/bin/reboot reboot)

# Copy required shared libs from host (Path A pragmatic).
# Determine the closure of every binary we ship.
copy_libs() {
  local bin="$1"
  ldd "$bin" 2>/dev/null | awk "/=>/ {print \$3} /^\t\// {print \$1}" | while read -r lib; do
    [ -z "$lib" ] && continue
    [ "$lib" = "(0x" ] && continue
    case "$lib" in
      "linux-vdso.so.1"|"") continue ;;
    esac
    if [ -f "$lib" ]; then
      tgt="$WORK${lib}"
      if [ ! -e "$tgt" ]; then
        mkdir -p "$(dirname "$tgt")"
        cp -L "$lib" "$tgt"
      fi
      # Also follow symlinks
      if [ -L "$lib" ]; then
        real=$(readlink -f "$lib")
        rtgt="$WORK${real}"
        if [ ! -e "$rtgt" ]; then
          mkdir -p "$(dirname "$rtgt")"
          cp "$real" "$rtgt"
        fi
      fi
    fi
  done
}

# Collect ld-linux explicitly
cp -L /lib64/ld-linux-x86-64.so.2 "$WORK/lib64/ld-linux-x86-64.so.2"
cp -L /lib/x86_64-linux-gnu/libc.so.6 "$WORK/lib/x86_64-linux-gnu/libc.so.6"

# Process every ELF in systemd-install + busybox
find "$WORK/usr/lib" "$WORK/usr/bin" "$WORK/usr/sbin" -type f -executable 2>/dev/null | while read -r f; do
  if file "$f" 2>/dev/null | grep -q "ELF.*dynamically linked"; then
    copy_libs "$f"
  fi
done
copy_libs /usr/bin/busybox 2>/dev/null || true

# /etc/passwd, /etc/group, /etc/shadow - minimal.
# Root's login shell is `/bin/sh` (busybox's `ash` applet). The
# initramfs busybox doesn't carry a `bash` applet, so attempting to
# exec `/bin/bash` would respawn the getty in a tight loop. The D1
# acceptance test only needs `echo`, `&&`, and the C3 launcher shim
# invocation pipeline, all of which ash supports.
cat > "$WORK/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/:/usr/sbin/nologin
EOF
cat > "$WORK/etc/group" <<EOF
root:x:0:
nogroup:x:65534:
tty:x:5:
EOF
cat > "$WORK/etc/shadow" <<EOF
root::20000:0:99999:7:::
nobody:!:20000:0:99999:7:::
EOF
chmod 640 "$WORK/etc/shadow"
echo "reproos-r9" > "$WORK/etc/hostname"
cat > "$WORK/etc/hosts" <<EOF
127.0.0.1 localhost reproos-r9
::1       localhost
EOF
cat > "$WORK/etc/nsswitch.conf" <<EOF
passwd: files
group: files
shadow: files
hosts: files dns
EOF
cat > "$WORK/etc/os-release" <<EOF
NAME="ReproOS"
VERSION="R9-mvp"
ID=reproos
VERSION_ID=r9
PRETTY_NAME="ReproOS R9 MVP (systemd 257.9 from source)"
EOF

# PAM stub for login (busybox login doesnt use PAM but agetty does on systemd)
cat > "$WORK/etc/pam.d/login" <<EOF
auth    sufficient pam_permit.so
account sufficient pam_permit.so
password sufficient pam_permit.so
session sufficient pam_permit.so
EOF
cat > "$WORK/etc/pam.d/system-auth" <<EOF
auth    sufficient pam_permit.so
account sufficient pam_permit.so
password sufficient pam_permit.so
session sufficient pam_permit.so
EOF

# /etc/profile: ensure the autologin shell picks up /usr/local/bin
# so the C3 sandbox-launcher shims at /usr/local/bin/<name> resolve
# without a full path. Without this, ash defaults to a bare
# /sbin:/usr/sbin:/bin:/usr/bin PATH and the D1 foreign-package
# assertions all fail with "not found" even though the binaries exist.
cat > "$WORK/etc/profile" <<EOF
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=linux
umask 022
EOF

# Ensure default target is multi-user
ln -sf "/usr/lib/systemd/system/multi-user.target" \
   "$WORK/etc/systemd/system/default.target"

# Enable serial-getty@ttyS0.service for the console
mkdir -p "$WORK/etc/systemd/system/getty.target.wants"
ln -sf "/usr/lib/systemd/system/serial-getty@.service" \
   "$WORK/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

# Patch serial-getty to use busybox login + autologin root for MVP
mkdir -p "$WORK/etc/systemd/system/serial-getty@ttyS0.service.d"
cat > "$WORK/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin root --noclear %I 115200 linux
EOF

# Provide a stub udev hwdb that wont fail. Skip.

# /init: kernel runs /init from initramfs. Have it pivot to /sbin/init = systemd.
# Actually, easier: make /init the systemd binary. Some kernels expect a literal /init
# in the initramfs.
ln -sf "/usr/lib/systemd/systemd" "$WORK/init"


# Pre-populate firstboot answers so systemd-firstboot does not block on the console.
# systemd-firstboot checks these files; if all are present it exits silently.
mkdir -p "$WORK/etc"
# machine-id: 32 hex chars; pinned to make boot deterministic.
echo "4242424242424242424242424242424242" | cut -c1-32 > "$WORK/etc/machine-id"
echo "C.UTF-8" > "$WORK/etc/locale.conf"
echo "LANG=C.UTF-8" >> "$WORK/etc/locale.conf"
echo "KEYMAP=us" > "$WORK/etc/vconsole.conf"
ln -sf /usr/share/zoneinfo/UTC "$WORK/etc/localtime" 2>/dev/null || true
mkdir -p "$WORK/usr/share/zoneinfo"
echo "UTC" > "$WORK/etc/timezone"
# Mark firstboot complete so systemd-firstboot.service short-circuits.
touch "$WORK/etc/machine-info"
# Disable systemd-firstboot.service explicitly (mask it).
mkdir -p "$WORK/etc/systemd/system"
ln -sf /dev/null "$WORK/etc/systemd/system/systemd-firstboot.service"
# Also mask vconsole-setup; we do not need it on serial.
ln -sf /dev/null "$WORK/etc/systemd/system/systemd-vconsole-setup.service"


# Real agetty from host util-linux (busybox does NOT have an agetty applet).
cp /usr/sbin/agetty "$WORK/usr/bin/agetty"
chmod +x "$WORK/usr/bin/agetty"

# Mask systemd-logind too — it crashes on our minimal rootfs (no full sysfs)
# and is not needed for serial getty login.
ln -sf /dev/null "$WORK/etc/systemd/system/systemd-logind.service"

# Pack the cpio.gz
find "$WORK" -depth -print0 | xargs -0 touch -h --date="@$SOURCE_DATE_EPOCH" 2>/dev/null || true
(cd "$WORK" && find . -print0 | LC_ALL=C sort -z | \
  cpio --null --owner=0:0 -o -H newc 2>/dev/null) | \
  gzip -9 -n > "$OUT"

sz=$(stat -c %s "$OUT")
sha=$(sha256sum "$OUT" | awk "{print \$1}")
echo "[initramfs] $OUT bytes=$sz sha256=$sha"
