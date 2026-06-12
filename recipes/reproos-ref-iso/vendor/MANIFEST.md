# R1 Vendored Upstream Binaries

This directory holds the vendored upstream binaries that R1 boots through the
R0 harness to validate the end-to-end pipeline (ISO/rootfs -> harness backend
-> systemd userspace -> serial assertions) **before** R4-R10 invest months in
the from-source bootstrap chain.

Every record below is `evidence_type: vendored-upstream-binary`. R10 swaps
each entry for the reprobuild from-source artifact.

The blobs themselves are **not committed** (gitignored via `*.tar.xz`,
`*.qcow2`, `*.vhdx`). Use `fetch.ps1` to materialise them locally on first
run; the boot test refuses to proceed if any expected sha256 is missing.

## Inventory

### debian-12-nocloud-amd64.tar.xz (Path A — WSL2 backend)

A "no-cloud-init" variant of the Debian 12 (bookworm) cloud rootfs. It
contains the full bookworm userspace including `/sbin/init` (systemd) and the
upstream-built kernel/initrd (the kernel is unused under WSL2 but harmless to
import).

- **URL**: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-nocloud-amd64.tar.xz
- **Mirror**: https://saimei.ftp.acc.umu.se/images/cloud/bookworm/latest/debian-12-nocloud-amd64.tar.xz
- **Size**: 263131960 bytes (~251 MiB)
- **SHA512 (upstream)**: `7d54678ddc3a3de1d61036e57b4d5f908e81744caca154a0834dbaaf6ad1f1094497c6f6abd46f0db113da072cdb1bc74b68209b5bf3d97f271e102d7ef71fea`
- **SHA256 (computed locally by `fetch.ps1` first run; recorded in `SHA256SUMS`)**: see `SHA256SUMS`.
- **Upstream maintainer**: Debian Cloud Team (https://salsa.debian.org/cloud-team/debian-cloud-images)
- **License**: per-component upstream (mostly GPL/MIT/BSD); see
  `/usr/share/doc/*/copyright` inside the rootfs after import.

### debian-12-genericcloud-amd64.qcow2 (Path B — Hyper-V backend)

Standard Debian 12 cloud image with cloud-init enabled. Used by the
Hyper-V Gen-2 UEFI path. The boot test:

1. Converts the qcow2 to a dynamic VHDX via `qemu-img convert -O vhdx`.
2. Generates a NoCloud cloud-init seed.iso (label `cidata`) with
   `user-data` setting a root password + enabling serial console, and
   `meta-data` carrying the instance-id.
3. Attaches the VHDX as primary disk + the seed.iso as DVD on a Gen-2
   UEFI VM with Secure Boot disabled.
4. Captures the serial pipe and asserts on `systemd[1]:` + `login:`.

- **URL**: https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
- **Size (latest snapshot 2026-06-01 build of bookworm 12.10)**: ~334 MiB
- **SHA512 pin**: `ff1c5b86c680bf29fb65a485296f45da744c9f636cb3c3ecc573b7c51ff88797ef207119e40f07ae9428b9bb539d57b490cdb2beecdfbac25dc95163e1418936`
  (sourced from https://cloud.debian.org/images/cloud/bookworm/latest/SHA512SUMS;
  verified by `fetch.ps1` before write; SHA256 also recorded in
  `SHA256SUMS` for downstream tooling that prefers SHA256).
- **Conversion**: `qemu-img convert -O vhdx -o subformat=dynamic` (qemu 11.0.0
  on PATH; see `convert-cloud-image.ps1`). Resulting VHDX is also gitignored.
- **Upstream maintainer**: Debian Cloud Team (https://salsa.debian.org/cloud-team/debian-cloud-images).
- **License**: per-component upstream (mostly GPL/MIT/BSD); see
  `/usr/share/doc/*/copyright` inside the guest after first boot.
