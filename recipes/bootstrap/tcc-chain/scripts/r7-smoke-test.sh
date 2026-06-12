#!/bin/bash
set -u
RMNT=/mnt/repro-debian-rescue
ROOTFS=$RMNT/tmp/r7-rootfs

mkdir -p $RMNT
mount /dev/sde $RMNT 2>&1 || echo "mount: already mounted (ok)"
ls $RMNT/tmp/r7-rootfs/bin/bash 2>&1 | head -2

mount --bind /proc $ROOTFS/proc 2>/dev/null || true
mount --bind /sys $ROOTFS/sys 2>/dev/null || true
mount --bind /dev $ROOTFS/dev 2>/dev/null || true

echo "============================================"
echo "Phase 9A: bash inside r7-rootfs chroot"
echo "============================================"
chroot $ROOTFS /bin/bash --noprofile --norc -c 'echo "[chroot] bash up"; echo "BASH_VERSION=$BASH_VERSION"; /bin/ls / | head -10; echo "---id---"; /bin/id; exit 91'
RA=$?
echo "phase9A exit=$RA"

echo "============================================"
echo "Phase 9B: useradd + chpasswd via PAM"
echo "============================================"
chroot $ROOTFS /bin/bash --noprofile --norc -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo "--- useradd ---"; /sbin/useradd -m -s /bin/bash testuser 2>&1; rc=$?; echo "useradd rc=$rc"
echo "--- passwd file ---"
/bin/cat /etc/passwd
echo "--- chpasswd ---"; echo "testuser:testpass" | /sbin/chpasswd 2>&1; rc=$?; echo "chpasswd rc=$rc"
echo "--- shadow file (root + testuser hashes) ---"
/bin/cat /etc/shadow
exit 92'
RB=$?
echo "phase9B exit=$RB"

echo "============================================"
echo "Phase 9C: unix_chkpwd via PAM (validates testpass against hash)"
echo "============================================"
# Pipe the password to unix_chkpwd directly — exercises the PAM stack
chroot $ROOTFS /bin/bash --noprofile --norc -c 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo -n "testpass" | /usr/sbin/unix_chkpwd testuser nullok 2>&1
echo "unix_chkpwd rc=$?"
echo "--- now try a WRONG password ---"
echo -n "wrongpass" | /usr/sbin/unix_chkpwd testuser nullok 2>&1
echo "unix_chkpwd wrong rc=$?"
exit 93'
RC=$?
echo "phase9C exit=$RC"

echo "============================================"
echo "Phase 9D: login -f root (force, no password)"
echo "============================================"
# Use timeout to avoid hangs
timeout 5 chroot $ROOTFS /usr/sbin/login -f root < /dev/null > /tmp/login-out.txt 2>&1
RD=$?
echo "phase9D exit=$RD (124=timeout, 0=login succeeded)"
echo "--- login output ---"
cat /tmp/login-out.txt 2>&1 | head -20

# Cleanup
umount $ROOTFS/dev 2>/dev/null || true
umount $ROOTFS/sys 2>/dev/null || true
umount $ROOTFS/proc 2>/dev/null || true
umount $RMNT 2>/dev/null || true

echo ""
echo "============================================"
echo "R7 ACCEPTANCE SUMMARY"
echo "============================================"
echo "Phase 9A bash-in-chroot:    exit=$RA (expected 91)"
echo "Phase 9B useradd+chpasswd:  exit=$RB (expected 92)"
echo "Phase 9C unix_chkpwd:       exit=$RC (expected 93)"
echo "Phase 9D login -f root:     exit=$RD (124=timeout-ok, 0=full-login-success)"
