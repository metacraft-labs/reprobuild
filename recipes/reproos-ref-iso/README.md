# R1 — ReproOS reference-ISO boot-harness gate

This directory is the **R1 milestone** of the ReproOS-MVP track: a boot
test that runs a real systemd userspace under the vm-harness primitives
and asserts on serial-console / shell output.

R1 is **scaffolding, not a deliverable**. The vendored Debian rootfs is
labelled `evidence_type: vendored-upstream-binary` in
[`vendor/MANIFEST.md`](vendor/MANIFEST.md); R4-R10 swap the vendored
blobs for reprobuild-built artefacts. The point of R1 is to prove the
boot path + the eventual ISO recipe + a real systemd userspace actually
talk to each other end-to-end **before** the project commits months to
from-source bootstrap.

## R0/R1 — lifted into vm-harness

The standalone Python `tools/boot-harness/` (R0) and the Python R1
drivers (`boot-test.py` + `boot-test-hyperv.py` + `expected.json`) have
been **superseded** by Nim primitives in the canonical vm-harness
library at `D:/metacraft/vm-harness/`. The architectural insight is
that boot-from-media + serial-stream capture are generic VM-orchestration
primitives that belong alongside vm-harness's existing baseline +
exec-in-guest contract, not in a duplicate Python harness in reprobuild.

The new vm-harness primitives:

- `BootMediaSpec` + `bootFromMedia` — spin up a transient VM directly
  around a VHDX / ISO / rootfs tar, distinct from
  `provisionBaseline` + `revertToBaseline` (which targets a long-lived
  known-good guest for test-in-guest workflows).
- `SerialStream` + `captureSerial` + `expectLine` + `serialSend` +
  `closeSerial` — read serial bytes during boot before the guest is
  "ready" enough for `execInGuest`, match Perl-flavoured regex
  patterns with a per-assertion timeout, send keystrokes back through
  the same channel.
- `writeNoCloudIso` — pure-Nim ISO9660 + cloud-init NoCloud seed
  builder (port of the Python ISO9660 generator).

The R1 scenarios live as e2e tests in vm-harness:

- **Path A** (WSL2 + Debian bookworm-slim rootfs): vm-harness/`tests/e2e/t_vm_harness_wsl_systemd_boot.nim`
- **Path B** (Hyper-V Gen-2 UEFI + Debian cloud VHDX): vm-harness/`tests/e2e/t_vm_harness_hyperv_systemd_boot.nim`

Both tests SKIP-with-reason when the host or vendored artefacts are
missing (NEVER silently pass).

## What stays here (in reprobuild)

- `vendor/MANIFEST.md`, `vendor/SHA256SUMS`, `vendor/fetch.ps1`,
  `vendor/convert-cloud-image.ps1` — the vendored-artefact provenance
  + fetch + qcow2-to-VHDX conversion scripts. These are reused as-is
  by the vm-harness e2e tests.
- `run-evidence/*.json` — historical PASS records from the Python
  driver runs (kept for traceability).
- `repro.nim` — R2 typed-recipe handoff stub.
- This README.

## What R1 is and isn't

| | R1 (this dir) | R2 (next) | R10 (eventually) |
|-|-|-|-|
| ISO recipe | stub `repro.nim` | typed-action chain | typed-action chain |
| Boot driver | vm-harness e2e tests | typed `boot-gate:` block | typed `boot-gate:` block |
| Kernel + initrd | vendored (WSL2 kernel for Path A; vendored cloud image for Path B) | vendored | reprobuild-built |
| Systemd userspace | vendored from `deb.debian.org` (apt-installed on top of bookworm-slim rootfs) | vendored from same source | reprobuild-built from source |
| Boot gate | runs, observes `systemctl --version` + `systemctl is-system-running` (Path A) or `systemd[1]:` + cloud-init final + login prompt (Path B), asserts | identical gate, but driven by the typed recipe | identical gate against from-source build |

## How to reproduce

### One-time: fetch + convert vendored artefacts

```powershell
. D:/metacraft/env.ps1
cd D:/metacraft/reprobuild

# Path A only needs the rootfs tarball (~28 MiB).
# Path B also needs the cloud qcow2 + a qcow2->VHDX conversion (~1.2 GiB).
pwsh recipes/reproos-ref-iso/vendor/fetch.ps1
pwsh recipes/reproos-ref-iso/vendor/convert-cloud-image.ps1
```

### Path A — WSL2 + Debian bookworm-slim rootfs

```powershell
cd D:/metacraft/vm-harness
nim r --threads:on --path:src tests/e2e/t_vm_harness_wsl_systemd_boot.nim
```

The test auto-detects the vendored rootfs at
`D:/metacraft/reprobuild/recipes/reproos-ref-iso/vendor/debian-bookworm-slim-amd64-rootfs.tar.gz`
(or set `VMH_DEBIAN_ROOTFS_TAR` to point at a custom location). Wall-
clock ~15-25 s on a warm WSL2 host. No elevation required.

### Path B — Hyper-V Gen-2 UEFI + Debian cloud VHDX

**Requires admin elevation.** The Hyper-V cmdlets need elevation; the
test SKIPs-with-reason (Get-VMHost fails) when invoked unprivileged.

```powershell
# In an elevated pwsh shell:
. D:/metacraft/env.ps1
cd D:/metacraft/vm-harness
nim r --threads:on --path:src tests/e2e/t_vm_harness_hyperv_systemd_boot.nim
```

The test auto-detects the vendored VHDX at
`D:/metacraft/reprobuild/recipes/reproos-ref-iso/vendor/debian-12-genericcloud-amd64.vhdx`
(or set `VMH_DEBIAN_CLOUD_VHDX`). Wall-clock ~130 s end-to-end
(kernel boot + cloud-init + login).

## Evidence from the latest Python-driver runs (2026-06-12, pre-lift)

These outcome JSONs were produced by the now-removed Python drivers.
They document the GREEN-on-2026-06-12 state of both paths before the
lift into vm-harness. The vm-harness e2e tests reproduce the same
assertions.

- Path A: [`run-evidence/20260612T083440Z.json`](run-evidence/20260612T083440Z.json)
- Path B: [`run-evidence/hyperv-20260612T090800Z.json`](run-evidence/hyperv-20260612T090800Z.json)

## Cleanup verification

```powershell
PS> wsl -l -q | Select-String 'repro-test-boot-'  # empty
PS> Get-VM -Name 'repro-test-boot-*' -ErrorAction SilentlyContinue  # empty
```

vm-harness's `BootMediaSpec.name` defaults to `repro-test-boot-<hex>`,
so a sweep is trivial. The vm-harness orchestrator's try/finally also
guarantees `stopAndCleanup` runs on every exception path.

## Path forward to R2

R2 replaces this stub `repro.nim` with a typed-action reprobuild ISO
recipe that materialises the boot-gate's expectations + bootable
artefact at `repro build .` time. The boot path itself stays in
vm-harness — R2 only adds a thin reprobuild adapter that consumes the
materialised expected.json and dispatches the right vm-harness backend
based on the boot medium kind:

| boot medium kind | vm-harness backend |
|-|-|
| `rootfs-tar` | `WslBackend` (Windows host) / future libvirt user-namespace path (Linux host) |
| `vhdx` | `HyperVBackend` (Windows host) / `libvirt` (Linux host, qcow2 conversion) |
| `iso`  | `HyperVBackend` (Windows host) / `libvirt` (Linux host) / `tart` (macOS-arm host) |

R1 deliberately does NOT block on R2's typed recipe — the point of R1
is exactly to prove the gate works before the typed work starts.
