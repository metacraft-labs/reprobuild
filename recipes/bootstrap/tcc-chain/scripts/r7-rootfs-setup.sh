#!/bin/sh
set -e
ROOTFS=/tmp/r7-rootfs
GLIBC=/tmp/r6-build/glibc
NCURSES=/tmp/r7-build/ncurses
BASH=/tmp/r7-build/bash
COREUTILS=/tmp/r7-build/coreutils
UTILLINUX=/tmp/r7-build/util-linux
PAM=/tmp/r7-build/pam
SHADOW=/tmp/r7-build/shadow
LIBXCRYPT=/tmp/r7-build/libxcrypt

# Wipe and recreate
rm -rf $ROOTFS
mkdir -p $ROOTFS/{bin,sbin,etc,lib,lib64,usr,proc,sys,dev,tmp,var/log,root,home}
mkdir -p $ROOTFS/usr/{bin,sbin,lib,lib64,libexec,share,include}
mkdir -p $ROOTFS/etc/{pam.d,security,default}
mkdir -p $ROOTFS/var/log

# Copy glibc lib (real dylibs only, no static archives)
cp -P $GLIBC/lib/ld-linux-x86-64.so.2 $ROOTFS/lib64/
mkdir -p $ROOTFS/lib/x86_64-linux-gnu
ln -sf /lib64/ld-linux-x86-64.so.2 $ROOTFS/lib/ld-linux-x86-64.so.2
# Copy all .so* (libs + symlinks) — keeps glibc runtime intact
for f in $GLIBC/lib/*.so $GLIBC/lib/*.so.*; do
  if [ -f "$f" ] || [ -L "$f" ]; then
    cp -P "$f" $ROOTFS/lib/
  fi
done
# Locale archive
mkdir -p $ROOTFS/lib/locale
cp $GLIBC/lib/locale/locale-archive $ROOTFS/lib/locale/
# gconv (needed by locale)
cp -r $GLIBC/lib/gconv $ROOTFS/lib/
# Copy libxcrypt
cp -P $LIBXCRYPT/lib/libcrypt.so* $ROOTFS/lib/

# ncurses (libs + terminfo)
cp -P $NCURSES/lib/*.so* $ROOTFS/lib/
mkdir -p $ROOTFS/usr/share/terminfo
cp -r $NCURSES/share/terminfo/* $ROOTFS/usr/share/terminfo/

# bash + /bin/sh
cp $BASH/bin/bash $ROOTFS/bin/bash
ln -sf bash $ROOTFS/bin/sh

# coreutils
for b in ls cat cp mv rm mkdir rmdir chmod chown chgrp echo env pwd id whoami true false test [ tty stty mknod ln; do
  if [ -f $COREUTILS/bin/$b ]; then
    cp $COREUTILS/bin/$b $ROOTFS/bin/
  fi
done

# util-linux
for b in mount umount kill su; do
  if [ -f $UTILLINUX/bin/$b ]; then cp $UTILLINUX/bin/$b $ROOTFS/bin/; fi
done
for b in agetty hwclock nologin; do
  if [ -f $UTILLINUX/sbin/$b ]; then cp $UTILLINUX/sbin/$b $ROOTFS/sbin/; fi
done

# PAM
cp -r $PAM/lib/libpam.so* $PAM/lib/libpam_misc.so* $PAM/lib/libpamc.so* $ROOTFS/lib/ 2>/dev/null || true
mkdir -p $ROOTFS/lib/security
cp -P $PAM/lib/security/*.so $ROOTFS/lib/security/ 2>/dev/null || true
mkdir -p $ROOTFS/etc/pam.d
cp -r $PAM/etc/security $ROOTFS/etc/ 2>/dev/null || true
mkdir -p $ROOTFS/usr/sbin
for s in unix_chkpwd unix_update pam_namespace_helper pam_timestamp_check mkhomedir_helper pwhistory_helper faillock; do
  if [ -f $PAM/sbin/$s ]; then cp $PAM/sbin/$s $ROOTFS/usr/sbin/; fi
done

# Shadow (login/passwd/useradd/...)
for b in login passwd chage chsh chfn gpasswd newgrp sg; do
  if [ -f $SHADOW/bin/$b ]; then cp $SHADOW/bin/$b $ROOTFS/bin/; fi
done
for s in useradd userdel usermod groupadd groupdel groupmod nologin pwck grpck vipw vigr newusers chpasswd; do
  if [ -f $SHADOW/sbin/$s ]; then cp $SHADOW/sbin/$s $ROOTFS/sbin/; fi
done
# Also place login in /usr/sbin (systemd convention)
cp $ROOTFS/bin/login $ROOTFS/usr/sbin/login

# /etc files
cat > $ROOTFS/etc/passwd <<'EOF'
root:x:0:0:root:/root:/bin/bash
EOF

cat > $ROOTFS/etc/group <<'EOF'
root:x:0:
EOF

# password is "reproos" — generated via mkpasswd-style sha512crypt with libxcrypt
# We'll inject the hash after generating it
cat > $ROOTFS/etc/shadow <<'EOF'
root:!:19000:0:99999:7:::
EOF
chmod 640 $ROOTFS/etc/shadow

cat > $ROOTFS/etc/nsswitch.conf <<'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
EOF

cat > $ROOTFS/etc/login.defs <<'EOF'
MAIL_DIR        /var/mail
PASS_MAX_DAYS   99999
PASS_MIN_DAYS   0
PASS_WARN_AGE   7
UID_MIN          1000
UID_MAX         60000
SYS_UID_MIN       100
SYS_UID_MAX       999
GID_MIN          1000
GID_MAX         60000
SYS_GID_MIN       100
SYS_GID_MAX       999
CREATE_HOME     yes
UMASK           022
HOME_MODE       0755
USERGROUPS_ENAB yes
ENCRYPT_METHOD  YESCRYPT
ENV_HZ          HZ=100
ENV_TZ          TZ=UTC
ENV_PATH        PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV_SUPATH      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
FAIL_DELAY      3
LOG_OK_LOGINS   no
LOG_UNKFAIL_ENAB no
SYSLOG_SU_ENAB  yes
SYSLOG_SG_ENAB  yes
SU_NAME         su
USERDEL_CMD     /usr/sbin/userdel_local
TTYTYPE_FILE    /etc/ttytype
TTYGROUP        tty
TTYPERM         0620
EOF

# PAM config — minimal
cat > $ROOTFS/etc/pam.d/login <<'EOF'
#%PAM-1.0
auth       required   pam_unix.so
account    required   pam_unix.so
password   required   pam_unix.so
session    required   pam_unix.so
EOF
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/passwd
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/system-auth
cp $ROOTFS/etc/pam.d/login $ROOTFS/etc/pam.d/common-auth
cat > $ROOTFS/etc/pam.d/other <<'EOF'
#%PAM-1.0
auth       required   pam_deny.so
account    required   pam_deny.so
password   required   pam_deny.so
session    required   pam_deny.so
EOF

# Profile + bashrc
cat > $ROOTFS/etc/profile <<'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LANG=C.UTF-8 LC_ALL=C.UTF-8
export PS1='r7-rootfs# '
echo "ReproOS R7 chroot smoke shell"
EOF
cat > $ROOTFS/root/.bashrc <<'EOF'
[ -f /etc/profile ] && . /etc/profile
EOF

# Inject a known password hash for "reproos"
# Use the from-source libcrypt via a tiny C helper at $LIBXCRYPT/lib/libcrypt.so
cat > /tmp/r7-mkhash.c <<'CEOF'
#include <stdio.h>
#include <crypt.h>
#include <string.h>
int main(int argc, char**argv){
  if(argc<3){fprintf(stderr,"usage: %s password salt\n",argv[0]);return 1;}
  char *h = crypt(argv[1], argv[2]);
  if(!h){perror("crypt");return 1;}
  printf("%s\n", h);
  return 0;
}
CEOF
/tmp/r7-build/wrapper/bin/gcc-glibc -I/tmp/r7-build/libxcrypt/include -L/tmp/r7-build/libxcrypt/lib -Wl,-rpath,/tmp/r7-build/libxcrypt/lib -lcrypt -o /tmp/r7-mkhash /tmp/r7-mkhash.c
HASH=$(/tmp/r7-mkhash "reproos" '$y$j9T$abc123def456ghij78$')
echo "hash=$HASH"
# Use sed to set the hash for root in shadow
sed -i "s|^root:!:|root:$HASH:|" $ROOTFS/etc/shadow
echo "/etc/shadow root hash injected"
cat $ROOTFS/etc/shadow

# Mount-binds
for d in proc sys dev; do
  if ! mountpoint -q $ROOTFS/$d; then mount --bind /$d $ROOTFS/$d || true; fi
done

# fix permissions
chmod 0755 $ROOTFS/bin/* $ROOTFS/sbin/* 2>/dev/null || true
chmod 0640 $ROOTFS/etc/shadow

echo "rootfs ready"
ls $ROOTFS
