# reproos-iso (R2)

Typed reprobuild recipe that takes a kernel + initramfs and emits a
**deterministic hybrid (BIOS + UEFI) bootable ISO** that the R0
vm-harness boots under Hyper-V Gen-2 UEFI.

## What this is for

R2 proves the recipe + bootloader integration end-to-end **before** R8
(from-source kernel) and R7 (from-source initramfs) land. The vendored
Debian-netinst kernel + initramfs are the test inputs today; R10 swaps
them for the from-source artifacts without changing the recipe.

The same recipe consumes either set of inputs because the recipe layer
is input-graph-agnostic: what counts is that the (inputs, env, tool
versions) tuple is deterministic.

## Files

- `repro.nim` -- typed `package reproosIso` declaration; the
  `buildAction` calls `scripts/build-iso.sh` via the `sh` typed-tool
  wrapper, declaring the vendored kernel + initramfs as `extraInputs`
  and the produced ISO at `build/reproos.iso` as `extraOutputs`.
- `scripts/build-iso.sh` -- the deterministic ISO driver. Wraps
  `grub-mkrescue` with the reproducibility flags + the `mformat` shim
  that pins the embedded ESP image's FAT volume serial. Designed to
  run inside the `repro-debian` WSL distro on Windows or natively on
  Linux.
- `vendor/MANIFEST.md` -- evidence records for the vendored kernel +
  initramfs.
- `vendor/fetch.ps1` -- Windows fetcher. Downloads the upstream Debian
  netinst ISO into `$env:LOCALAPPDATA\repro-boot-harness-cache\`, then
  extracts the kernel + initramfs via `xorriso -osirrox` inside the
  `repro-debian` WSL distro.
- `vendor/SHA256SUMS` -- per-blob sha256 pins (committed).
- `vendor/.gitignore` -- both blobs exceed the 10 MB committable rule
  and are gitignored; fetched on demand via `fetch.ps1`.

## How to run

```powershell
. D:/metacraft/env.ps1
$env:PATH = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User')
cd D:/metacraft/reprobuild

# One-time setup: install xorriso + grub + mtools in the repro-debian
# WSL distro. (apt is content-addressable; re-running is cheap.)
wsl -d repro-debian -u root -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y xorriso grub-pc-bin grub-efi-amd64-bin mtools squashfs-tools && apt-get clean"

# Fetch the vendored kernel + initramfs (idempotent).
pwsh recipes/reproos-iso/vendor/fetch.ps1

# Build the ISO (manually invoking the script for now -- the
# `repro build reproosIso` path lands when the path-mode resolver
# learns the `sh` typed-tool provisioning for the WSL distro).
wsl -d repro-debian -- bash -c "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC bash /mnt/d/metacraft/reprobuild/recipes/reproos-iso/scripts/build-iso.sh /mnt/d/metacraft/reprobuild/recipes/reproos-iso/vendor/vmlinuz-debian-netinst /mnt/d/metacraft/reprobuild/recipes/reproos-iso/vendor/initrd.img-debian-netinst /mnt/d/metacraft/reprobuild/recipes/reproos-iso/build/reproos.iso"

# Verify reproducibility (3 back-to-back rebuilds with sha256 equality).
bash tests/reproducibility/t_r2_iso_reproducibility.sh

# Boot the produced ISO via vm-harness (Hyper-V Gen-2 UEFI).
# Requires an elevated PowerShell session.
nim c -r --threads:on --hints:off --warnings:off tests/integration/t_r2_iso_boot.nim
```

## Reproducibility details

The recipe pins six sources of non-determinism that would otherwise
drift across rebuilds:

1. **`SOURCE_DATE_EPOCH = 1735689600`** (2025-01-01T00:00:00Z) -- the
   single epoch every downstream timestamp inherits.
2. **`LC_ALL=C`** + **`TZ=UTC`** -- locale + timezone for ASCII
   timestamps in the PVD / SVD.
3. **`--gpt_disk_guid 52455052-4f53-4953-4f52-322d62756c61`** -- pins
   the GPT disk GUID xorriso/libisofs would otherwise generate from
   `gettimeofday()`.
4. **`--modification-date=2025010100000000`** -- pins the PVD
   modification timestamp (the `cc` hundredth-seconds field is the
   only PVD field that `SOURCE_DATE_EPOCH` doesn't cover).
5. **`--set_all_file_dates 1735689600`** -- pins the per-file
   recording timestamps in every ISO9660 directory record.
6. **`mformat` shim with pinned `-N 0xb007ed02`** -- Debian 12's
   mtools 4.0.32 seeds `random()` from `time(0)` before generating the
   FAT volume serial; `SOURCE_DATE_EPOCH` doesn't cover this path. The
   shim drops a wrapper script into a private dir, prepended on
   `$PATH`, that hands `-N <hex>` to mformat for every grub-mkrescue
   call.

With all six pins, three back-to-back rebuilds produce byte-identical
ISOs (sha256 stable). The
`tests/reproducibility/t_r2_iso_reproducibility.sh` gate enforces
this.

## What boots

The grub.cfg launches the vendored Debian netinst kernel with:

```
console=tty1 console=ttyS0,115200n8 quiet
```

### Historical R2 boot path (REPRO_LIVE_INIT=0, default)

The vendored d-i initramfs runs busybox + the Debian Installer
framework. Reads the `console=` cmdline option and writes its
text-mode installer banner to ttyS0. Under Hyper-V Gen-2 UEFI with
COM1 wired to a named pipe, the R0 vm-harness `bootFromMedia` boot
gate tails the pipe and asserts on the installer banner.

R2 does NOT drive the installer (we just verify the kernel reaches
userspace).

### M9.R.17c live-init boot path (REPRO_LIVE_INIT=1)

The historical R2 d-i initramfs ignores `/live/filesystem.squashfs`
and just runs the installer. M9.R.17c replaces it with a custom
live-init capable initramfs (see `scripts/build-initramfs.sh` +
`initramfs/init`) that:

1. Probes block devices for the ISO.
2. Mounts `/live/filesystem.squashfs` via the loop driver.
3. Overlays it with a tmpfs upper via overlayfs.
4. `switch_root`s into the overlay where /sbin/init = systemd.

The squashfs payload is assembled by `scripts/stage-de-rootfs.sh`
which:

1. Pulls a base userspace (systemd, libc, Qt6, GL stack, sddm)
   from `debian:trixie-slim` via Docker apt-install
   (`scripts/build-base-rootfs.sh`).
2. Overlays the from-source DE binaries (sway, mutter, kwin, sddm,
   plasma-workspace, gdm) from the sibling source recipes'
   `.repro/output/install/usr/` trees.
3. Stages `/usr/share/wayland-sessions/{sway,plasma,gnome}.desktop`
   so SDDM enumerates all three at the login screen.
4. Symlinks `/etc/systemd/system/display-manager.service ->
   /usr/lib/systemd/system/sddm.service` and `default.target ->
   graphical.target` so systemd starts SDDM on graphical.target.

QEMU smoke (verified 2026-06-23): boots into SDDM with `Session:`
dropdown showing Sway/Plasma/GNOME, the live user avatar, and a
password input field (password = `reproos`).

The recipe's `repro.nim` sets `REPRO_LIVE_INIT=1` so the recipe
invocation builds the live-boot path; the reproducibility test
(`tests/reproducibility/t_r2_iso_reproducibility.sh`) leaves
REPRO_LIVE_INIT defaulted to 0 so the historical R2 reproducibility
contract continues to be enforced against the vendored d-i path.

### M9.R.19 ReproOS Installer wizard chain

M9.R.19 closed the engine integration for the ReproOS Installer
(see `apps/reproos-installer/`). The full boot chain the live ISO
exercises:

```
GRUB (multi-de variant)
  -> kernel (vendored vmlinuz-debian-netinst, until R8)
  -> initrd (custom live-init initramfs, M9.R.17c.1)
  -> live-init: probe block devices, mount /live/filesystem.squashfs,
                overlay with tmpfs upper, switch_root to overlay
  -> systemd (graphical.target via the staged default.target symlink)
  -> sddm (display-manager.service, autologin per M9.R.18.1)
  -> autologin Session=reproos-installer (default since M9.R.19.4)
  -> /usr/bin/reproos-installer-launcher (kiosk wrapper)
  -> sway -c $SWAY_CFG (minimal compositor in kiosk mode)
  -> /usr/bin/reproos-installer (Qt6/QML wizard, 9 screens)
```

The installer binary is **mandatory** in the ISO since M9.R.19.3 —
`stage-de-rootfs.sh` enforces it via exit code 66 if the engine-built
artifact at `apps/reproos-installer/.repro/output/install/usr/bin/
reproos-installer` is missing. The reproos-iso recipe's `extraInputs`
declares the binary path so the engine refingerprints the ISO build
when the wizard changes.

Build the wizard recipe before the ISO:

```bash
repro build apps/reproos-installer --tool-provisioning=from-source
repro build recipes/reproos-iso     --tool-provisioning=from-source
```

The qt6-quickcontrols2 dep on the wizard is satisfied by
`recipes/packages/source/qt6-quickcontrols2/` (M9.R.19.1), which
shares the qtdeclarative tarball with the sibling qt6-declarative
recipe — QtQuickControls2 was merged into qtdeclarative upstream at
Qt 6.2 so no separate qtquickcontrols2-everywhere-src tarball exists.
