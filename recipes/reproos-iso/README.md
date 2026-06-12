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

The d-i kernel reads the `console=` cmdline option and writes its
text-mode installer banner to ttyS0. Under Hyper-V Gen-2 UEFI with
COM1 wired to a named pipe, the R0 vm-harness `bootFromMedia` boot
gate tails the pipe and asserts on the installer banner.

R2 does NOT drive the installer (we just verify the kernel reaches
userspace). R10's recipe will boot the from-source kernel + initramfs
through the same mechanism and the boot-gate assertion targets will
shift to systemd's startup banner.
