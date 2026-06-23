# ReproOS End-to-End Install Demo

M9.R.24 demo walkthrough. This document captures how to build the
ReproOS live ISO, run the installer's `--automated` path against a
fresh QEMU disk, and observe the 6-phase install timeline produced
by `apps/reproos-installer`.

## Prereqs

The demo runs on a Linux host with KVM + Docker. The reference
environment is the eli-wsl distro at `/opt/repro/reprobuild` (a
NixOS userland with `nix-shell` available); the same flow runs on
any host where `nix-shell -p qemu` resolves.

Required nix-shell packages: `qemu socat imagemagick OVMF
binutils squashfsTools xorriso grub2 mtools cpio xz zstd kmod
patchelf glibc qt6.qtdeclarative qt6.qtbase qt6.qtwayland`.

Required apt / system packages: `docker` (for the base-rootfs builder).

## Build the ISO

```bash
cd /opt/repro/reprobuild/recipes/reproos-iso

# Build the wizard binary + repro CLI (only needs to be done once
# per change).
nix-shell -p qt6.qtbase qt6.qtdeclarative qt6.qtwayland cmake ninja \
           gcc14 pkg-config --run \
  'cmake -S ../../apps/reproos-installer -B /tmp/installer-build \
         -G Ninja -DCMAKE_BUILD_TYPE=Release \
         -DCMAKE_POLICY_VERSION_MINIMUM=3.16
   cmake --build /tmp/installer-build
   cp /tmp/installer-build/reproos-installer \
      ../../apps/reproos-installer/.repro/output/install/usr/bin/reproos-installer'

nix-shell -p nim2 gcc --run \
  'nim c --hints:off --nimcache:../../build/nimcache/repro \
         --out:../../build/bin/repro ../../apps/repro/repro.nim'

# Build the ISO. The script's outputs land at build/reproos.iso.
REPRO_LIVE_DEBUG=1 \
REPRO_DE_ROOTFS_DIR=$(pwd)/build/de-rootfs \
SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
REPRO_GRUB_VARIANT=multi-de REPRO_LIVE_INIT=1 \
  nix-shell -p binutils squashfsTools xorriso grub2 mtools cpio xz \
             zstd kmod patchelf glibc qt6.qtdeclarative \
             qt6.qtbase qt6.qtwayland --run \
    'bash scripts/stage-de-rootfs.sh build/de-rootfs
     bash scripts/build-iso.sh vendor/vmlinuz-debian-netinst \
                                vendor/initrd.img-debian-netinst \
                                build/reproos.iso'
```

The resulting ISO is ~595 MB (M9.R.24.4.3 build). See
`recipes/reproos-iso/scripts/` for the staging + build logic.

## Run the installer (BIOS mode)

```bash
# Create a fresh qcow2 target disk.
qemu-img create -f qcow2 /tmp/reproos-target.qcow2 8G

# Boot the ISO with the disk attached. The console autologin (M9.R.24.1c)
# auto-runs the installer in --automated mode against
# /etc/reproos/auto-config.toml (baked at stage time by
# scripts/stage-de-rootfs.sh).
nix-shell -p qemu socat --run \
  'qemu-system-x86_64 -m 4G -enable-kvm \
    -cdrom build/reproos.iso \
    -drive file=/tmp/reproos-target.qcow2,format=qcow2,if=virtio \
    -boot d \
    -serial mon:stdio'
```

## What the demo executes

The autologin shell runs `/etc/profile.d/zz-reproos-installer-autostart.sh`
which fires the wizard binary in `--automated` mode. The wizard
reads `/etc/reproos/auto-config.toml`, gathers the install choices,
and drives the 6-phase sequence in `apps/reproos-installer/src/
installer_state.cpp::install()`:

| Phase | Operation | Underlying tools |
| --- | --- | --- |
| **1: probe** | `repro hardware probe --output ... --regenerate` | Reads `/sys`, `/proc/cpuinfo`, `lsblk`, etc. into a probed-hardware.nim file |
| **2: disk apply** | `repro disk apply disko.json --confirm --device /dev/vda` | Walks the disko spec; runs `wipefs -af` + `sgdisk -o` + `sgdisk -n` (ESP + root) + `partprobe` + `mkfs.vfat` + `mkfs.ext4` |
| **3: mount** | `repro disk mount disko.json --target /mnt --confirm` | Mounts `/dev/vda2 -> /mnt` and `/dev/vda1 -> /mnt/boot` |
| **4: write config** | (in-process) | Writes `/mnt/etc/repro/system.nim` + `/mnt/etc/repro/hardware.nim` |
| **5: system apply** | `repro infra apply --target /mnt` | **STUBBED** for the M9.R.24 demo (the subcommand doesn't yet accept --target). Falls back to `runMinimalBootstrap`: cps live kernel+initrd into `/mnt/boot`, writes `/etc/fstab` + `/etc/hostname`, installs GRUB-EFI to `/dev/vda` via `--target=x86_64-efi --removable`, writes `grub.cfg`. |
| **6: unmount** | `repro disk unmount disko.json --target /mnt` | Reverse-order umount of both mounts. |

Expected output on the QEMU console:

```
=== ReproOS Installer (automated) starting in 3 seconds; Ctrl+C aborts. ===
Config: /etc/reproos/auto-config.toml

Phase 1: probing hardware...
$ /usr/bin/repro hardware probe --output /tmp/.../probed-hardware.nim --regenerate
  repro hardware probe: wrote /tmp/.../probed-hardware.nim
Phase 2: applying disk layout...
wrote /tmp/.../disko.json (578 bytes)
$ /usr/bin/repro disk apply /tmp/.../disko.json --confirm --device /dev/vda
  [apply] umount: umount -lf /dev/vda (exit 32)
  [apply] umount: umount -lf /dev/vda1 (exit 32)
  [apply] umount: umount -lf /dev/vda2 (exit 32)
  [apply] wipefs: wipefs -af /dev/vda (exit 0)
  [apply] sgdisk: sgdisk -o /dev/vda (exit 0)
  [apply] sgdisk: sgdisk -n 1:0:+512M -t 1:EF00 -c 1:esp /dev/vda (exit 0)
  [apply] parted: parted -s /dev/vda set 1 boot on (exit 0)
  [apply] sgdisk: sgdisk -n 2:0:0 -t 2:8300 -c 2:root /dev/vda (exit 0)
  [apply] partprobe: partprobe /dev/vda (exit 0)
  [apply] mkfs.vfat: mkfs.vfat -F 32 /dev/vda1 (exit 0)
  [apply] mkfs.ext4: mkfs.ext4 -F /dev/vda2 (exit 0)
  repro disk apply: OK (11 operations)
Phase 3: mounting target rootfs at /mnt
  EXT4-fs (vda2): mounted filesystem ... r/w with ordered data mode.
  repro disk mount: 2 entries
    /dev/vda2 -> /mnt
    /dev/vda1 -> /mnt/boot
Phase 4: writing /etc/repro/{system,hardware}.nim
  wrote /mnt/etc/repro/system.nim (672 bytes)
  wrote /mnt/etc/repro/hardware.nim (718 bytes)
Phase 5: applying system profile...
$ /usr/bin/repro infra apply --target /mnt
  repro infra apply: unknown flag: --target
system apply (`repro infra apply --target`) is stubbed for the M9.R.24 demo;
proceeding with a minimal bootable-system bootstrap
Phase 5b: copying live kernel + initramfs into /mnt/boot/
Phase 5c: writing /etc/fstab + /etc/hostname
Phase 5d: installing GRUB to /dev/vda
$ grub-install --target=x86_64-efi --efi-directory=/mnt/boot
  --boot-directory=/mnt/boot --no-nvram --removable --recheck /dev/vda
  Installing for x86_64-efi platform.
  Installation finished. No error reported.
Phase 5e: writing GRUB config
  wrote /tmp/.../grub.cfg (152 bytes)
  '/tmp/.../grub.cfg' -> '/mnt/boot/grub/grub.cfg'
minimal bootstrap done
Phase 6: unmounting target...
$ /usr/bin/repro disk unmount /tmp/.../disko.json --target /mnt
  repro disk unmount: 2 entries
install complete

=== Installer exited with rc=0 ===
```

## Configuring the install

The demo config at `/etc/reproos/auto-config.toml` is baked at
ISO-build time by `scripts/stage-de-rootfs.sh`. Override at install
time by passing a different config path, e.g. by booting with a
floppy/CDROM that drops a custom TOML at `/run/reproos/auto-config.toml`.

```toml
hostname = "reproos-vm"
defaultUser = "alice"
password = "reproos"
diskoPreset = "simple"
targetDevice = "/dev/vda"
preferredDE = "plasma"
activities = ["daily-computing", "system-tools"]
```

`diskoPreset` controls Phase 2's layout: `simple` is GPT + ESP +
ext4 root (covered by the M9.R.24.2 JSON path); `encrypted` is
LUKS2 + btrfs subvols (still requires a Nim toolchain in the live
ISO -- pending milestone); `advanced` skips the disko block.

## Reboot into the installed system

```bash
# Boot from disk without the ISO (UEFI/OVMF).
OVMF_CODE=$(find /nix/store -maxdepth 5 -name OVMF_CODE.fd -type f | head -1)
OVMF_VARS=$(find /nix/store -maxdepth 5 -name OVMF_VARS.fd -type f | head -1)
cp "$OVMF_VARS" /tmp/ovmf_vars_install.fd
nix-shell -p qemu OVMF --run \
  'qemu-system-x86_64 -m 4G -enable-kvm \
    -drive if=pflash,format=raw,readonly=on,file='"$OVMF_CODE"' \
    -drive if=pflash,format=raw,file=/tmp/ovmf_vars_install.fd \
    -drive file=/tmp/reproos-target.qcow2,format=qcow2,if=virtio \
    -boot c \
    -serial mon:stdio'
```

## Known M9.R.24 limitations

- **Phase 5 system apply is stubbed.** `repro infra apply --target
  /mnt` doesn't yet accept the --target flag; M9.R.24 falls back to
  the minimal bootable-system bootstrap. A follow-up milestone needs
  to extend `apps/repro/repro.nim`'s infra-apply path to honor a
  target prefix.

- **Phase 5 minimal bootstrap is BIOS+UEFI hybrid.** GRUB installs
  via `--target=x86_64-efi --removable` so the EFI binary lands at
  `EFI/BOOT/BOOTX64.EFI`. Booting from disk requires OVMF firmware.

- **DE session not yet usable in the live ISO.** SDDM + sway crashed
  on initial M9.R.24 attempts (`segfault at 0x91` post-VT-handoff).
  REPRO_LIVE_TARGET=console (default) sidesteps via console autologin.
  REPRO_LIVE_TARGET=graphical retains the SDDM path for later.

- **Encrypted + advanced disko presets need Nim in the ISO.** The
  M9.R.24.2 JSON path only covers the `simple` preset; the other
  presets still call `nim r` and fail with "nim: not found".

- **Installed system's userland is the live ISO's squashfs.** Phase
  5b copies kernel + initrd into /mnt/boot but the rest of /mnt is
  empty (just /etc/{fstab,hostname,repro/}). The follow-up `repro
  infra apply --target` needs to bootstrap a real userland (Debian
  debootstrap or NixOS install path) under /mnt.

## File pointers

- `apps/reproos-installer/src/installer_state.cpp::install()` --
  the 6-phase orchestrator.
- `apps/reproos-installer/src/installer_state.cpp::runMinimalBootstrap()`
  -- the Phase 5 fallback.
- `libs/repro_cli_support/src/repro_cli_support/disk.nim::loadDiskoFromSource()`
  -- the `.json` shortcut path.
- `libs/repro_profile/src/repro_profile/disk_apply.nim::applyDiskLayout()`
  -- the Phase 2 driver.
- `recipes/reproos-iso/scripts/stage-de-rootfs.sh` -- bundles Qt6 +
  libclingo + repro CLI + reproos-installer into the live ISO.
- `recipes/reproos-iso/scripts/build-base-rootfs.sh` -- the Debian
  trixie-slim PKG_LIST.
- `recipes/reproos-iso/initramfs/init` -- the live-init script that
  loads kernel modules + switch_roots into the overlayfs.
