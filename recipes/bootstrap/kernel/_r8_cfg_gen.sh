#!/bin/bash
# Helper: generate the canonical R8 kernel .config inside repro-ubuntu.
# Used once to snapshot configs/x86_64-hyperv.config; not part of the
# normal build path. Re-run if the kernel pin or hyperv-extra.fragment
# changes.
set -e
W=/tmp/r8-cfg
rm -rf "$W"
mkdir -p "$W"
cd "$W"
tar -xf /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/vendor/linux-6.6.142.tar.xz
cd linux-6.6.142
echo '--- base x86_64_defconfig ---'
make ARCH=x86_64 x86_64_defconfig 2>&1 | tail -3
echo '--- merge kvm_guest.config ---'
make ARCH=x86_64 kvm_guest.config 2>&1 | tail -3
echo '--- merge hyperv-extra.fragment ---'
./scripts/kconfig/merge_config.sh -m .config /mnt/d/metacraft/reprobuild/recipes/bootstrap/kernel/configs/hyperv-extra.fragment 2>&1 | tail -10
echo '--- olddefconfig ---'
make ARCH=x86_64 olddefconfig 2>&1 | tail -3
echo '--- summary ---'
grep -E '^(CONFIG_HYPERV|CONFIG_EFI|CONFIG_SERIAL_8250|CONFIG_EXT4|CONFIG_MODULES|CONFIG_BLK_DEV_INITRD|CONFIG_TMPFS|CONFIG_DEVTMPFS|CONFIG_VIRTIO|CONFIG_DRM_HYPERV|CONFIG_FB_HYPERV|CONFIG_PCI_HYPERV)' .config | sort
echo '---size---'
wc -l .config
cp .config /mnt/d/metacraft/reprobuild/recipes/bootstrap/kernel/configs/x86_64-hyperv.config
echo "--- snapshot written ---"
