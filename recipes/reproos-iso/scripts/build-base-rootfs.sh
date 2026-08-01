#!/usr/bin/env bash
# Build the deterministic, package-free filesystem seed used by ReproOS.
#
# Executables, libraries, units, firmware, and desktop data are supplied by
# source recipe install mirrors in stage-de-rootfs.sh. This script owns only
# FHS directories and machine-independent configuration that no package build
# should own.
#
# Input:
#   $1 = absolute output path for the rootfs tar.xz
#
# Required environment:
#   SOURCE_DATE_EPOCH
#
# Required host tools:
#   bash, chmod, ln, mkdir, mktemp, mv, rm, sha256sum, stat, tar, xz

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-tarball.tar.xz>" >&2
  exit 64
fi
OUT_TAR="$1"

: "${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must be set}"

for tool in chmod ln mkdir mktemp mv rm sha256sum stat tar xz; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "build-base-rootfs.sh: required tool missing: $tool" >&2
    exit 66
  fi
done

WORK_DIR="$(mktemp -d -t reproos-base-rootfs-XXXXXX)"
ROOTFS_DIR="$WORK_DIR/rootfs"
TMP_TAR="$WORK_DIR/rootfs.tar"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

umask 022
mkdir -p "$ROOTFS_DIR"
mkdir -p \
  "$ROOTFS_DIR/boot" \
  "$ROOTFS_DIR/dev/pts" \
  "$ROOTFS_DIR/dev/shm" \
  "$ROOTFS_DIR/etc/default" \
  "$ROOTFS_DIR/etc/ld.so.conf.d" \
  "$ROOTFS_DIR/etc/pam.d" \
  "$ROOTFS_DIR/etc/profile.d" \
  "$ROOTFS_DIR/etc/security" \
  "$ROOTFS_DIR/etc/skel" \
  "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d" \
  "$ROOTFS_DIR/etc/systemd/system/serial-getty@ttyS0.service.d" \
  "$ROOTFS_DIR/home/live" \
  "$ROOTFS_DIR/media" \
  "$ROOTFS_DIR/mnt" \
  "$ROOTFS_DIR/opt" \
  "$ROOTFS_DIR/proc" \
  "$ROOTFS_DIR/root" \
  "$ROOTFS_DIR/run/lock" \
  "$ROOTFS_DIR/srv" \
  "$ROOTFS_DIR/sys" \
  "$ROOTFS_DIR/tmp" \
  "$ROOTFS_DIR/usr/bin" \
  "$ROOTFS_DIR/usr/lib" \
  "$ROOTFS_DIR/usr/lib64" \
  "$ROOTFS_DIR/usr/libexec" \
  "$ROOTFS_DIR/usr/local/bin" \
  "$ROOTFS_DIR/usr/local/lib" \
  "$ROOTFS_DIR/usr/local/sbin" \
  "$ROOTFS_DIR/usr/sbin" \
  "$ROOTFS_DIR/usr/share" \
  "$ROOTFS_DIR/var/backups" \
  "$ROOTFS_DIR/var/cache" \
  "$ROOTFS_DIR/var/lib/dbus" \
  "$ROOTFS_DIR/var/local" \
  "$ROOTFS_DIR/var/log" \
  "$ROOTFS_DIR/var/mail" \
  "$ROOTFS_DIR/var/opt" \
  "$ROOTFS_DIR/var/spool" \
  "$ROOTFS_DIR/var/tmp"

chmod 0700 "$ROOTFS_DIR/root" "$ROOTFS_DIR/home/live"
chmod 1777 "$ROOTFS_DIR/tmp" "$ROOTFS_DIR/var/tmp"

# ReproOS uses a merged-/usr layout. The source bridge populates the targets
# after this skeleton is extracted.
ln -s usr/bin "$ROOTFS_DIR/bin"
ln -s usr/sbin "$ROOTFS_DIR/sbin"
ln -s usr/lib "$ROOTFS_DIR/lib"
ln -s usr/lib64 "$ROOTFS_DIR/lib64"
ln -s bash "$ROOTFS_DIR/usr/bin/sh"
ln -s bash "$ROOTFS_DIR/usr/bin/rbash"
ln -s /proc/mounts "$ROOTFS_DIR/etc/mtab"
ln -s /run "$ROOTFS_DIR/var/run"
ln -s /run/lock "$ROOTFS_DIR/var/lock"
ln -s /etc/machine-id "$ROOTFS_DIR/var/lib/dbus/machine-id"
ln -s /usr/share/zoneinfo/UTC "$ROOTFS_DIR/etc/localtime"
ln -s ../../etc/os-release "$ROOTFS_DIR/usr/lib/os-release"

cat > "$ROOTFS_DIR/etc/os-release" <<'EOF'
NAME="ReproOS"
PRETTY_NAME="ReproOS"
ID=reproos
ID_LIKE=linux
VERSION_ID="0"
VERSION="source"
HOME_URL="https://metacraft-labs.com/"
EOF

cat > "$ROOTFS_DIR/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
live:x:1000:1002:ReproOS Live User:/home/live:/bin/bash
EOF

cat > "$ROOTFS_DIR/etc/group" <<'EOF'
root:x:0:
daemon:x:1:
bin:x:2:
sys:x:3:
adm:x:4:live
tty:x:5:
disk:x:6:
sudo:x:27:live
audio:x:29:live
video:x:44:live
plugdev:x:46:live
users:x:100:
input:x:104:live
netdev:x:105:live
live:x:1002:
nogroup:x:65534:
EOF

cat > "$ROOTFS_DIR/etc/shadow" <<'EOF'
root:$6$reproo123$KJGP/pyxIdKyCZBeNLmdzO1b0H3n5klR49gRuog3Qel19.safRMX6YDVU9U2O098qGJMp6pp.NDp.7YcKXFnz/:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
bin:*:19000:0:99999:7:::
sys:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
live:$6$reproo123$KJGP/pyxIdKyCZBeNLmdzO1b0H3n5klR49gRuog3Qel19.safRMX6YDVU9U2O098qGJMp6pp.NDp.7YcKXFnz/:19000:0:99999:7:::
EOF

cat > "$ROOTFS_DIR/etc/gshadow" <<'EOF'
root:*::
daemon:*::
bin:*::
sys:*::
adm:*::live
tty:*::
disk:*::
sudo:*::live
audio:*::live
video:*::live
plugdev:*::live
users:*::
input:*::live
netdev:*::live
live:!::
nogroup:*::
EOF
chmod 0640 "$ROOTFS_DIR/etc/shadow" "$ROOTFS_DIR/etc/gshadow"

cat > "$ROOTFS_DIR/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
gshadow: files
hosts: files dns
networks: files
protocols: files
services: files
ethers: files
rpc: files
EOF

cat > "$ROOTFS_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 reproos
::1 localhost ip6-localhost ip6-loopback
EOF
: > "$ROOTFS_DIR/etc/resolv.conf"
printf '%s\n' 'reproos' > "$ROOTFS_DIR/etc/hostname"
printf '%s\n' 'UTC' > "$ROOTFS_DIR/etc/timezone"
printf '%s\n' 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/default/locale"
printf '%s\n' 'LANG=C.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
: > "$ROOTFS_DIR/etc/machine-id"
: > "$ROOTFS_DIR/etc/environment"

cat > "$ROOTFS_DIR/etc/ld.so.conf" <<'EOF'
include /etc/ld.so.conf.d/*.conf
EOF
cat > "$ROOTFS_DIR/etc/ld.so.conf.d/reproos.conf" <<'EOF'
/usr/local/lib
/usr/lib
/usr/lib64
EOF

cat > "$ROOTFS_DIR/etc/shells" <<'EOF'
/bin/sh
/usr/bin/sh
/bin/bash
/usr/bin/bash
/bin/rbash
/usr/bin/rbash
EOF

cat > "$ROOTFS_DIR/etc/login.defs" <<'EOF'
MAIL_DIR /var/mail
ENV_SUPATH PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV_PATH PATH=/usr/local/bin:/usr/bin:/bin
HOME_MODE 0700
PASS_MAX_DAYS 99999
PASS_MIN_DAYS 0
PASS_WARN_AGE 7
UID_MIN 1000
UID_MAX 60000
GID_MIN 1000
GID_MAX 60000
ENCRYPT_METHOD SHA512
DEFAULT_HOME yes
USERGROUPS_ENAB yes
EOF

cat > "$ROOTFS_DIR/etc/pam.d/common-auth" <<'EOF'
auth required pam_unix.so nullok
EOF
cat > "$ROOTFS_DIR/etc/pam.d/common-account" <<'EOF'
account required pam_unix.so
EOF
cat > "$ROOTFS_DIR/etc/pam.d/common-password" <<'EOF'
password required pam_unix.so sha512 shadow
EOF
cat > "$ROOTFS_DIR/etc/pam.d/common-session" <<'EOF'
session required pam_unix.so
EOF
cat > "$ROOTFS_DIR/etc/pam.d/common-session-noninteractive" <<'EOF'
session required pam_unix.so
EOF
cat > "$ROOTFS_DIR/etc/pam.d/login" <<'EOF'
auth requisite pam_nologin.so
auth include common-auth
account include common-account
password include common-password
session required pam_loginuid.so
session optional pam_keyinit.so force revoke
session required pam_limits.so
session include common-session
EOF
cat > "$ROOTFS_DIR/etc/pam.d/su" <<'EOF'
auth sufficient pam_rootok.so
auth include common-auth
account include common-account
session include common-session
EOF
cat > "$ROOTFS_DIR/etc/pam.d/passwd" <<'EOF'
password include common-password
EOF
cat > "$ROOTFS_DIR/etc/pam.d/other" <<'EOF'
auth required pam_deny.so
account required pam_deny.so
password required pam_deny.so
session required pam_deny.so
EOF
: > "$ROOTFS_DIR/etc/pam.conf"
: > "$ROOTFS_DIR/etc/security/limits.conf"
: > "$ROOTFS_DIR/etc/security/pam_env.conf"

cat > "$ROOTFS_DIR/etc/profile" <<'EOF'
if [ "$(id -u)" -eq 0 ]; then
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
else
  PATH=/usr/local/bin:/usr/bin:/bin
fi
export PATH

if [ -n "${BASH_VERSION:-}" ] && [ -r /etc/bash.bashrc ]; then
  . /etc/bash.bashrc
fi
for profile_script in /etc/profile.d/*.sh; do
  [ -r "$profile_script" ] && . "$profile_script"
done
unset profile_script
EOF

cat > "$ROOTFS_DIR/etc/bash.bashrc" <<'EOF'
[ -z "${PS1:-}" ] && return
shopt -s checkwinsize
PS1='\u@\h:\w\$ '
EOF

cat > "$ROOTFS_DIR/etc/skel/.profile" <<'EOF'
[ -r /etc/profile ] && . /etc/profile
EOF
cat > "$ROOTFS_DIR/etc/skel/.bashrc" <<'EOF'
[ -r /etc/bash.bashrc ] && . /etc/bash.bashrc
EOF
cat > "$ROOTFS_DIR/root/.profile" <<'EOF'
[ -r /etc/profile ] && . /etc/profile
EOF
cat > "$ROOTFS_DIR/home/live/.profile" <<'EOF'
[ -r /etc/profile ] && . /etc/profile
EOF

cat > "$ROOTFS_DIR/etc/issue" <<'EOF'
ReproOS \n \l
EOF

cat > "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
EOF
cat > "$ROOTFS_DIR/etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I $TERM
EOF

mkdir -p "$(dirname "$OUT_TAR")"
tar \
  --sort=name \
  --format=gnu \
  --mtime="@${SOURCE_DATE_EPOCH}" \
  --clamp-mtime \
  --numeric-owner \
  --owner=0 \
  --group=0 \
  -cf "$TMP_TAR" \
  -C "$ROOTFS_DIR" .
xz --threads=1 --check=crc64 -9e -c "$TMP_TAR" > "$OUT_TAR.tmp"
mv "$OUT_TAR.tmp" "$OUT_TAR"

bytes="$(stat -c %s "$OUT_TAR")"
sha="$(sha256sum "$OUT_TAR")"
sha="${sha%% *}"
echo "[base-rootfs] OK $OUT_TAR bytes=$bytes sha256=$sha"
