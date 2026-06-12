#!/bin/bash
set -u
RMNT=/mnt/repro-debian-rescue
ROOTFS=$RMNT/tmp/r7-rootfs
mkdir -p $RMNT
mount /dev/sde $RMNT 2>&1 | head -2 || true

# Make sure no stale binds from a previous run linger
umount $ROOTFS/dev/pts 2>/dev/null || true
umount $ROOTFS/dev/shm 2>/dev/null || true
umount $ROOTFS/dev/mqueue 2>/dev/null || true
umount $ROOTFS/dev/hugepages 2>/dev/null || true
umount $ROOTFS/dev 2>/dev/null || true
umount $ROOTFS/sys 2>/dev/null || true
umount $ROOTFS/proc 2>/dev/null || true

# Wipe everything BUT /proc /sys /dev (which we'd rather not recurse-rm if bind-mounted)
for entry in $ROOTFS/*; do
  case "$entry" in
    */proc|*/sys|*/dev) ;;
    *) rm -rf "$entry" ;;
  esac
done

# Source paths inside the rescue mount
GLIBC=$RMNT/tmp/r6-build/glibc
NCURSES=$RMNT/tmp/r7-build/ncurses
BASH=$RMNT/tmp/r7-build/bash
COREUTILS=$RMNT/tmp/r7-build/coreutils
UTILLINUX=$RMNT/tmp/r7-build/util-linux
PAM=$RMNT/tmp/r7-build/pam
SHADOW=$RMNT/tmp/r7-build/shadow-DESTDIR/tmp/r7-build/shadow
LIBXCRYPT=$RMNT/tmp/r7-build/libxcrypt

mkdir -p $ROOTFS/{bin,sbin,etc,lib,lib64,usr,proc,sys,dev,tmp,var/log,root,home,run}
mkdir -p $ROOTFS/usr/{bin,sbin,lib,lib64,libexec,share}
mkdir -p $ROOTFS/etc/{pam.d,security,default}
mkdir -p $ROOTFS/lib/security
mkdir -p $ROOTFS/tmp/r6-build/glibc/lib
mkdir -p $ROOTFS/tmp/r7-build/ncurses/lib $ROOTFS/tmp/r7-build/libxcrypt/lib $ROOTFS/tmp/r7-build/pam/lib/security

cp -P $GLIBC/lib/ld-linux-x86-64.so.2 $ROOTFS/lib64/
cp -P $GLIBC/lib/ld-linux-x86-64.so.2 $ROOTFS/tmp/r6-build/glibc/lib/
cd $GLIBC/lib
for f in *.so *.so.*; do [ -e "$f" ] && cp -P "$f" $ROOTFS/lib/ 2>/dev/null && cp -P "$f" $ROOTFS/tmp/r6-build/glibc/lib/ 2>/dev/null; done
mkdir -p $ROOTFS/lib/locale && cp $GLIBC/lib/locale/locale-archive $ROOTFS/lib/locale/
[ -d $GLIBC/lib/gconv ] && cp -r $GLIBC/lib/gconv $ROOTFS/lib/
cp -P $LIBXCRYPT/lib/libcrypt.so* $ROOTFS/lib/ 2>/dev/null
cp -P $LIBXCRYPT/lib/libcrypt.so* $ROOTFS/tmp/r7-build/libxcrypt/lib/ 2>/dev/null
cp -P $NCURSES/lib/*.so* $ROOTFS/lib/ 2>/dev/null
cp -P $NCURSES/lib/*.so* $ROOTFS/tmp/r7-build/ncurses/lib/ 2>/dev/null
mkdir -p $ROOTFS/usr/share/terminfo
cp -r $NCURSES/share/terminfo/* $ROOTFS/usr/share/terminfo/ 2>/dev/null || true

cp $BASH/bin/bash $ROOTFS/bin/bash; ln -sf bash $ROOTFS/bin/sh

for b in ls cat cp mv rm mkdir rmdir chmod chown chgrp echo env pwd id whoami true false test "[" tty ln tee head tail; do
  [ -f $COREUTILS/bin/$b ] && cp $COREUTILS/bin/$b $ROOTFS/bin/
done
for b in mount umount; do [ -f $UTILLINUX/bin/$b ] && cp $UTILLINUX/bin/$b $ROOTFS/bin/; done
for b in agetty nologin; do [ -f $UTILLINUX/sbin/$b ] && cp $UTILLINUX/sbin/$b $ROOTFS/sbin/; done

cp -P $PAM/lib/libpam.so* $PAM/lib/libpam_misc.so* $PAM/lib/libpamc.so* $ROOTFS/lib/ 2>/dev/null
cp -P $PAM/lib/security/*.so $ROOTFS/lib/security/ 2>/dev/null
cp -P $PAM/lib/libpam.so* $PAM/lib/libpam_misc.so* $PAM/lib/libpamc.so* $ROOTFS/tmp/r7-build/pam/lib/ 2>/dev/null
cp -P $PAM/lib/security/*.so $ROOTFS/tmp/r7-build/pam/lib/security/ 2>/dev/null
for s in unix_chkpwd unix_update mkhomedir_helper pwhistory_helper faillock pam_namespace_helper pam_timestamp_check; do
  [ -f $PAM/sbin/$s ] && cp $PAM/sbin/$s $ROOTFS/usr/sbin/
done

for b in login passwd chage chsh chfn gpasswd newgrp sg; do [ -f $SHADOW/bin/$b ] && cp $SHADOW/bin/$b $ROOTFS/bin/; done
for s in useradd userdel usermod groupadd groupdel groupmod nologin pwck grpck vipw vigr newusers chpasswd; do [ -f $SHADOW/sbin/$s ] && cp $SHADOW/sbin/$s $ROOTFS/sbin/; done
cp $ROOTFS/bin/login $ROOTFS/usr/sbin/login 2>/dev/null || true

# /etc files
cat > $ROOTFS/etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF
cat > $ROOTFS/etc/group <<'EOF'
root:x:0:
EOF
cat > $ROOTFS/etc/shadow <<'EOF'
root::19000:0:99999:7:::
EOF
chmod 640 $ROOTFS/etc/shadow
cat > $ROOTFS/etc/nsswitch.conf <<'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files
EOF
cat > $ROOTFS/etc/pam.d/login <<'EOF'
#%PAM-1.0
auth       required   pam_unix.so nullok
account    required   pam_unix.so
password   required   pam_unix.so nullok sha512
session    required   pam_unix.so
EOF
cat > $ROOTFS/etc/pam.d/chpasswd <<'EOF'
#%PAM-1.0
password   required   pam_unix.so nullok sha512
EOF
cat > $ROOTFS/etc/pam.d/passwd <<'EOF'
#%PAM-1.0
password   required   pam_unix.so nullok sha512
EOF
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/system-auth
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-auth
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-account
cat > $ROOTFS/etc/pam.d/common-password <<'EOF'
password   required   pam_unix.so nullok sha512
EOF
cat > $ROOTFS/etc/pam.d/common-session <<'EOF'
session    required   pam_unix.so
EOF
# Pre-create empty backup files so pam_unix can write to them
touch $ROOTFS/etc/passwd- $ROOTFS/etc/shadow- $ROOTFS/etc/group- $ROOTFS/etc/gshadow- $ROOTFS/etc/gshadow
chmod 640 $ROOTFS/etc/shadow- $ROOTFS/etc/gshadow $ROOTFS/etc/gshadow-
cat > $ROOTFS/etc/pam.d/other <<'EOF'
#%PAM-1.0
auth       required   pam_deny.so
account    required   pam_deny.so
password   required   pam_deny.so
session    required   pam_deny.so
EOF
cat > $ROOTFS/etc/login.defs <<'EOF'
PASS_MAX_DAYS  99999
PASS_MIN_DAYS  0
PASS_WARN_AGE  7
UID_MIN        1000
UID_MAX        60000
GID_MIN        1000
GID_MAX        60000
CREATE_HOME    yes
UMASK          022
HOME_MODE      0755
USERGROUPS_ENAB yes
ENCRYPT_METHOD SHA512
ENV_PATH       PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV_SUPATH     PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
FAIL_DELAY     1
LOG_OK_LOGINS  no
LOG_UNKFAIL_ENAB no
SU_NAME        su
TTYGROUP       tty
TTYPERM        0620
EOF
cat > $ROOTFS/etc/profile <<'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8 LC_ALL=C.UTF-8 TERM=linux
EOF

# Now bind /proc /sys /dev only
mount --bind /proc $ROOTFS/proc
mount --bind /sys $ROOTFS/sys
mount --bind /dev $ROOTFS/dev

echo ">>> PHASE 9A: bash chroot <<<"
chroot $ROOTFS /bin/bash --noprofile --norc -c 'echo "[chroot] bash up"; echo "BASH_VERSION=$BASH_VERSION"; /bin/id; exit 91'
echo "9A_exit=$?"

echo ">>> PHASE 9B: useradd + chpasswd <<<"
chroot $ROOTFS /bin/bash --noprofile --norc -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
/sbin/useradd -m -s /bin/bash testuser 2>&1; echo "useradd_rc=$?"
/bin/cat /etc/passwd
echo "--- chpasswd ---"
echo "testuser:testpass" | /sbin/chpasswd 2>&1; echo "chpasswd_rc=$?"
/bin/cat /etc/shadow
exit 92'
echo "9B_exit=$?"

echo ">>> PHASE 9C: unix_chkpwd validation <<<"
chroot $ROOTFS /bin/bash --noprofile --norc -c '
echo -n "testpass" | /usr/sbin/unix_chkpwd testuser nullok 2>&1
echo "good_pw_rc=$?"
echo -n "wrongpass" | /usr/sbin/unix_chkpwd testuser nullok 2>&1
echo "bad_pw_rc=$?"
exit 93'
echo "9C_exit=$?"

echo ">>> PHASE 9D: login -f root (force) <<<"
# Run from a pty via script(1) so login has a tty — fall back to bare if script unavailable
# First check if there's a fresh-enough strace-like setup
# The login binary checks isatty(STDIN); without tty it logs to /var/log and exits
timeout 4 chroot $ROOTFS /usr/sbin/login -f root </dev/null >/tmp/login-9d.out 2>&1
RD=$?
echo "9D[rc=$RD]"
echo "--- /var/log/btmp + /var/log/wtmp probe ---"
ls -la $ROOTFS/var/log 2>&1
echo "9D_exit=$RD (0=success, 124=timeout)"
echo "--- login output (last 15 lines) ---"
tail -15 /tmp/login-9d.out

# Cleanup
umount $ROOTFS/dev 2>/dev/null || true
umount $ROOTFS/sys 2>/dev/null || true
umount $ROOTFS/proc 2>/dev/null || true
umount $RMNT 2>/dev/null || true

echo ""
echo "=== R7 PHASE 9 SUMMARY ==="
echo "9A bash-chroot expected exit 91"
echo "9B useradd+chpasswd expected exit 92"
echo "9C unix_chkpwd expected exit 93"
echo "9D login -f root expected exit 0 or 124"
