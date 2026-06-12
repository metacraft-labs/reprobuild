#!/bin/bash
set -eu
RMNT=/mnt/repro-debian-rescue
ROOTFS=/mnt/repro-debian-rescue/tmp/r7-rootfs
mkdir -p $RMNT
if ! mountpoint -q $RMNT; then mount /dev/sde $RMNT; fi

# Source paths inside the rescue mount
GLIBC=$RMNT/tmp/r6-build/glibc
NCURSES=$RMNT/tmp/r7-build/ncurses
BASH=$RMNT/tmp/r7-build/bash
COREUTILS=$RMNT/tmp/r7-build/coreutils
UTILLINUX=$RMNT/tmp/r7-build/util-linux
PAM=$RMNT/tmp/r7-build/pam
SHADOW=$RMNT/tmp/r7-build/shadow-DESTDIR/tmp/r7-build/shadow
LIBXCRYPT=$RMNT/tmp/r7-build/libxcrypt

# Build a FRESH rootfs in the rescue tmp
rm -rf $ROOTFS
mkdir -p $ROOTFS/{bin,sbin,etc,lib,lib64,usr,proc,sys,dev,tmp,var/log,root,home,run}
mkdir -p $ROOTFS/usr/{bin,sbin,lib,lib64,libexec,share}
mkdir -p $ROOTFS/etc/{pam.d,security,default}
mkdir -p $ROOTFS/lib/security
mkdir -p $ROOTFS/var/log

# Dynamic linker
cp -P $GLIBC/lib/ld-linux-x86-64.so.2 $ROOTFS/lib64/

# Replicate the EMBEDDED paths inside the rootfs (binaries' INTERP and RUNPATH point at /tmp/r6-build/glibc/lib + /tmp/r7-build/{ncurses,libxcrypt,pam}/lib)
mkdir -p $ROOTFS/tmp/r6-build/glibc/lib
cp -P $GLIBC/lib/ld-linux-x86-64.so.2 $ROOTFS/tmp/r6-build/glibc/lib/
# Symlink the whole lib dir so all .so are findable at the embedded paths
for f in $GLIBC/lib/*.so $GLIBC/lib/*.so.*; do
  if [ -e "$f" ]; then cp -P "$f" $ROOTFS/tmp/r6-build/glibc/lib/; fi
done
mkdir -p $ROOTFS/tmp/r7-build/ncurses/lib $ROOTFS/tmp/r7-build/libxcrypt/lib $ROOTFS/tmp/r7-build/pam/lib $ROOTFS/tmp/r7-build/pam/lib/security
cp -P $NCURSES/lib/*.so* $ROOTFS/tmp/r7-build/ncurses/lib/ 2>/dev/null
cp -P $LIBXCRYPT/lib/libcrypt.so* $ROOTFS/tmp/r7-build/libxcrypt/lib/ 2>/dev/null
cp -P $PAM/lib/*.so* $ROOTFS/tmp/r7-build/pam/lib/ 2>/dev/null
cp -P $PAM/lib/security/*.so $ROOTFS/tmp/r7-build/pam/lib/security/ 2>/dev/null

# Copy ALL .so + .so.* files (real + symlinks) from glibc lib
cd $GLIBC/lib
for f in *.so *.so.*; do
  if [ -e "$f" ]; then
    cp -P "$f" $ROOTFS/lib/
  fi
done

# Locale archive
mkdir -p $ROOTFS/lib/locale
cp $GLIBC/lib/locale/locale-archive $ROOTFS/lib/locale/

# gconv
if [ -d $GLIBC/lib/gconv ]; then cp -r $GLIBC/lib/gconv $ROOTFS/lib/; fi

# libxcrypt
cp -P $LIBXCRYPT/lib/libcrypt.so* $ROOTFS/lib/ 2>/dev/null

# ncurses
cp -P $NCURSES/lib/*.so* $ROOTFS/lib/
mkdir -p $ROOTFS/usr/share/terminfo
cp -r $NCURSES/share/terminfo/* $ROOTFS/usr/share/terminfo/ 2>/dev/null || true

# bash + /bin/sh
cp $BASH/bin/bash $ROOTFS/bin/bash
ln -sf bash $ROOTFS/bin/sh

# coreutils
for b in ls cat cp mv rm mkdir rmdir chmod chown chgrp echo env pwd id whoami true false test "[" tty stty ln tee yes seq head tail sort uniq wc; do
  if [ -f $COREUTILS/bin/$b ]; then cp $COREUTILS/bin/$b $ROOTFS/bin/; fi
done

# util-linux
for b in mount umount; do
  if [ -f $UTILLINUX/bin/$b ]; then cp $UTILLINUX/bin/$b $ROOTFS/bin/; fi
done
for b in agetty hwclock nologin; do
  if [ -f $UTILLINUX/sbin/$b ]; then cp $UTILLINUX/sbin/$b $ROOTFS/sbin/; fi
done

# PAM libs + modules
cp -P $PAM/lib/libpam.so* $PAM/lib/libpam_misc.so* $PAM/lib/libpamc.so* $ROOTFS/lib/ 2>/dev/null
cp -P $PAM/lib/security/*.so $ROOTFS/lib/security/ 2>/dev/null
for s in unix_chkpwd unix_update pam_namespace_helper pam_timestamp_check mkhomedir_helper pwhistory_helper faillock; do
  if [ -f $PAM/sbin/$s ]; then cp $PAM/sbin/$s $ROOTFS/usr/sbin/; fi
done

# Shadow
for b in login passwd chage chsh chfn gpasswd newgrp sg; do
  if [ -f $SHADOW/bin/$b ]; then cp $SHADOW/bin/$b $ROOTFS/bin/; fi
done
for s in useradd userdel usermod groupadd groupdel groupmod nologin pwck grpck vipw vigr newusers chpasswd; do
  if [ -f $SHADOW/sbin/$s ]; then cp $SHADOW/sbin/$s $ROOTFS/sbin/; fi
done
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

# PAM config — minimal
cat > $ROOTFS/etc/pam.d/login <<'EOF'
#%PAM-1.0
auth       required   pam_unix.so nullok
account    required   pam_unix.so
password   required   pam_unix.so
session    required   pam_unix.so
EOF
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/passwd
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/system-auth
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-auth
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-account
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-password
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-session
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
ENCRYPT_METHOD yescrypt
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

# /dev minimal — just create nodes if /dev/null doesn't exist
# (we'll bind-mount host /dev for the chroot smoke, so leave as a placeholder)

echo "--- rootfs ready ---"
echo "binaries:"
ls $ROOTFS/bin | head -20
echo "..."
ls $ROOTFS/bin | wc -l
echo "sbin:"
ls $ROOTFS/sbin | head -10
echo "lib:"
ls $ROOTFS/lib | head -10
echo "pam modules:"
ls $ROOTFS/lib/security | head -10

# Now run the chroot smoke
mount --bind /proc $ROOTFS/proc 2>/dev/null || true
mount --bind /sys $ROOTFS/sys 2>/dev/null || true
mount --bind /dev $ROOTFS/dev 2>/dev/null || true

echo "============================================"
echo "Phase 9A: bash inside r7-rootfs chroot"
echo "============================================"
chroot $ROOTFS /bin/bash --noprofile --norc -c 'echo "[chroot] bash up"; echo "BASH_VERSION=$BASH_VERSION"; /bin/ls /bin | head -5; echo "---id---"; /bin/id; echo "---env LANG---"; export LANG=C.UTF-8 LC_ALL=C.UTF-8; echo "LANG=$LANG"; exit 91' 2>&1
echo "phase9A exit=$?"

echo "============================================"
echo "Phase 9B: useradd + login via PAM"
echo "============================================"
chroot $ROOTFS /bin/bash --noprofile --norc -c '
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "--- create testuser ---"
/sbin/useradd -m -s /bin/bash testuser 2>&1
echo "useradd exit=$?"
cat /etc/passwd
echo "--- set password (using passwd in batch mode) ---"
# passwd in batch mode (-e expects encrypted, --stdin not available in shadow upstream)
echo "testuser:testpass" | /sbin/chpasswd 2>&1
echo "chpasswd exit=$?"
cat /etc/shadow | head -5
exit 92
' 2>&1
echo "phase9B exit=$?"

echo "============================================"
echo "Phase 9C: login -f root (force, skip password)"
echo "============================================"
# login -f root expects a tty. In a non-tty pipe context, login may error.
# Run with a fake controlling tty if possible
chroot $ROOTFS /usr/sbin/login -f root 2>&1 < /dev/null &
LPID=$!
sleep 3
if kill -0 $LPID 2>/dev/null; then
  echo "login PID alive after 3s - sending exit"
  kill $LPID 2>/dev/null
  wait $LPID 2>/dev/null
  echo "login killed (still PASSED if it got past PAM)"
else
  wait $LPID 2>/dev/null
  echo "login exited rc=$?"
fi

# Cleanup
umount $ROOTFS/dev 2>/dev/null || true
umount $ROOTFS/sys 2>/dev/null || true
umount $ROOTFS/proc 2>/dev/null || true
echo "done"
