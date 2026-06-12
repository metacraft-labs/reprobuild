# R2 Vendored Upstream Binaries (kernel + initramfs)

This directory holds the kernel + initramfs blobs that R2's typed
reprobuild recipe consumes as inputs. R2's purpose is to PROVE that the
typed `package reproosIso` action emits a deterministic hybrid (BIOS +
UEFI) bootable ISO that the vm-harness boot gate validates end-to-end
on Hyper-V Gen-2 UEFI. The vendored kernel/initramfs let us close that
loop today, BEFORE the from-source kernel (R8) and initramfs (R7) land.

R10 will swap these vendored inputs for the from-source artifacts
WITHOUT changing the recipe -- only the dep edges change.

Every record below is `evidence_type: vendored-upstream-binary`.

## Source

Both blobs are extracted (via `xorriso -osirrox`) from the upstream
Debian netinst ISO:

- **Upstream URL**: https://cdimage.debian.org/debian-cd/13.5.0/amd64/iso-cd/debian-13.5.0-amd64-netinst.iso
- **Mirror index**: https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/
- **Upstream sha256**: `95838884f5ea6c82421dfe6baaa5a639dbbe6756c1e380f9fe7a7cb0c1949d2a`
- **Upstream sha256 source**: `SHA256SUMS` published alongside the ISO at
  https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/SHA256SUMS
  (snapshot taken 2026-06-12; "current" resolved to 13.5.0).
- **Upstream maintainer**: Debian Project (https://www.debian.org/CD/)
- **Snapshot date**: 2026-06-12

Choice rationale (vs extracting from R1's vendored cloud VHDX): the
netinst kernel + initrd are designed to boot a text-mode installer over
serial -- minimal userspace, no SSH/cloud-init scaffolding -- which is
the cleanest possible target for "did the kernel + initramfs reach
userspace?" assertion in R0's vm-harness `bootFromMedia` boot gate. The
cloud-image kernel works too but requires more cloud-init plumbing the
recipe doesn't yet need.

## Inventory

### vmlinuz-debian-netinst

The Debian Installer kernel image (gzip-compressed bzImage).

- **Source path inside upstream ISO**: `/install.amd/vmlinuz`
- **Size**: 12117952 bytes (~11.6 MiB)
- **sha256**: `4cc864b8e34c86c281f66b36157a52945a95a1b290762245c608b7c7e3934a11`
- **License**: GPL-2.0 (Linux kernel)
- **Status**: gitignored (exceeds the project's <=10 MB committable rule);
  fetched on demand by `fetch.ps1`; sha256 pinned in `SHA256SUMS`.

### initrd.img-debian-netinst

The Debian Installer initramfs (gzip-compressed cpio). Contains the
busybox userspace + the Debian Installer (d-i) framework.

- **Source path inside upstream ISO**: `/install.amd/initrd.gz`
- **Size**: 24321642 bytes (~23 MiB)
- **sha256**: `aa522af25c1a579b54c123b929b476c425e218efd1d2d84ec471ba07249143fa`
- **License**: per-component upstream (GPL/MIT/BSD mix); see
  `/usr/share/doc/*/copyright` inside the installer rootfs.
- **Status**: gitignored (exceeds the project's <=10 MB committable rule);
  fetched on demand by `fetch.ps1`; sha256 pinned in `SHA256SUMS`.

## Reproducing the vendor

1. Run `pwsh recipes/reproos-iso/vendor/fetch.ps1`.
2. The fetcher caches the upstream ISO at
   `$env:LOCALAPPDATA\repro-boot-harness-cache\debian-13.5.0-amd64-netinst.iso`
   so multiple recipes (R1, R2, future) can share the same blob.
3. The fetcher then drives `xorriso -osirrox on -indev <iso> -extract
   /install.amd/{vmlinuz,initrd.gz}` inside the `repro-debian` WSL
   distro to extract the two blobs into this directory.
4. The kernel + initramfs sha256s are recomputed and verified against
   `SHA256SUMS` (which the recipe + boot gate consume as the integrity
   pin).
