# R1 — ReproOS reference-ISO boot-harness gate

This directory is the **R1 milestone** of the ReproOS-MVP track: a boot
test that runs a real systemd userspace through the R0 boot-harness and
asserts on serial-console / shell output.

R1 is **scaffolding, not a deliverable**. The vendored Debian rootfs is
labelled `evidence_type: vendored-upstream-binary` in
[`vendor/MANIFEST.md`](vendor/MANIFEST.md); R4-R10 swap the vendored
blobs for reprobuild-built artefacts. The point of R1 is to prove the
R0 harness + the eventual ISO recipe + a real systemd userspace
actually talk to each other end-to-end **before** the project commits
months to from-source bootstrap.

## What R1 is and isn't

| | R1 (this dir) | R2 (next) | R10 (eventually) |
|-|-|-|-|
| ISO recipe | stub `repro.nim` | typed-action chain | typed-action chain |
| Boot driver | Python `boot-test.py` consuming `expected.json` directly | same script; `expected.json` generated from `repro.nim` `boot-gate:` block | same script; same generation |
| Kernel + initrd | vendored (WSL2 kernel for Path A; vendored cloud image for Path B) | vendored | reprobuild-built |
| Systemd userspace | vendored from `deb.debian.org` (apt-installed on top of bookworm-slim rootfs) | vendored from same source | reprobuild-built from source |
| Boot gate | runs, observes `systemctl --version` + `systemctl is-system-running`, asserts | identical gate, but driven by the typed recipe | identical gate against from-source build |

## Which path is exercised here

**Path A: WSL2 + Debian bookworm-slim rootfs (this session — PASS)**

1. `vendor/fetch.ps1` pulls the upstream Debian rootfs.tar.gz from the
   Docker Hub registry (the `library/debian:bookworm-slim` amd64
   variant — the canonical debuerreotype-built rootfs) and pins it to
   the layer's sha256 digest, recording it in `vendor/SHA256SUMS`.
2. `boot-test.py` invokes `wsl --import` to create a transient distro
   under the safety-mandated `repro-test-boot-` prefix.
3. The script then runs `apt-get install -y --no-install-recommends
   systemd dbus systemd-sysv` inside the distro and writes
   `/etc/wsl.conf` with `[boot]\nsystemd=true`.
4. `wsl --terminate` forces the distro to pick up the new wsl.conf.
5. A fresh `wsl -d <distro> -- /bin/sh` shell is spawned; under WSL2's
   systemd mode this boots systemd as PID 1 before yielding the shell.
6. The R0 LineBuffer/assertion DSL drives the assertions in
   `expected.json` against the shell's stdout, capturing every byte
   into `$env:TEMP\repro-boot-harness\<distro>.log` (the "serial log"
   in R0 vocabulary).
7. `finally:` unregisters the distro and removes the work directory.

**Path B: Hyper-V + Debian cloud qcow2 (not exercised this session)**

`qemu-img` (needed to convert the upstream `debian-12-genericcloud-amd64.qcow2`
to VHDX for Hyper-V's Gen-2 backend) is not installed on this host's
PATH. Installing QEMU on Windows from `winget` requires elevated UAC,
which the harness invocation context does not have. The
`vendor/MANIFEST.md` records the upstream URL for Path B so R2 can
pick it up once the host gets `qemu-img`.

**Path C: Arch Linux ISO direct** — not pursued because Path A is
sufficient to prove the gate, and Path C has the same Hyper-V-needs-
elevation blocker as Path B without the cloud-init advantage.

## How to reproduce

```powershell
. D:/metacraft/env.ps1
cd D:/metacraft/reprobuild

# One-time: pull the upstream Debian rootfs from Docker Hub registry.
# Verifies sha256 against the layer digest; refuses to proceed on
# mismatch. The blob lives at
#   recipes/reproos-ref-iso/vendor/debian-bookworm-slim-amd64-rootfs.tar.gz
# (gitignored — pulled fresh on first run, ~28 MB).
pwsh recipes/reproos-ref-iso/vendor/fetch.ps1

# Run the boot test. Expect:
#   - PASS in ~15-25s on a warm Windows host with WSL2 already
#     installed,
#   - the outcome JSON written under
#     recipes/reproos-ref-iso/run-evidence/<utc-stamp>.json,
#   - no surviving repro-test-boot-* WSL distros after exit (verify
#     with `wsl -l -q`).
python recipes/reproos-ref-iso/boot-test.py
```

## Evidence from the latest run (2026-06-12 08:34 UTC)

Outcome JSON: [`run-evidence/20260612T083440Z.json`](run-evidence/20260612T083440Z.json)

```
[r1-boot-test] blob OK: debian-bookworm-slim-amd64-rootfs.tar.gz
               sha256=b9136609bef0128191aa157637b98dd7b98e52154ca60c18258d65957a01c6d0
[r1-boot-test] distro=repro-test-boot-r1-a129c1
[r1-boot-test] import: debian-bookworm-slim-amd64-rootfs.tar.gz -> repro-test-boot-r1-a129c1
[r1-boot-test] bootstrap: apt-get update && apt-get install -y --no-install-recommends systemd dbus system...
[r1-boot-test] terminating distro to apply wsl.conf changes
[r1-boot-test] PASS expect_line('systemd 2\d\d') matched 'systemd 252' at 8.81s
[r1-boot-test] PASS expect_line('^(running|degraded|starting|initializing)$') matched 'degraded' at 0.11s
[r1-boot-test] cleanup: unregister repro-test-boot-r1-a129c1
[r1-boot-test] wall-clock: 17.69s
[r1-boot-test] === PASS ===
```

Serial-log tail (the actual bytes the WSL2 systemd-mode shell emitted —
the R0 backend buffers this into the LineBuffer the assertion DSL
scans):

```
wsl: Failed to start the systemd user session for 'root'. See journalctl for more details.
systemd 252 (252.39-1~deb12u2)
degraded
```

(The `systemd user session for 'root'` warning is expected: WSL2's
systemd integration doesn't run a per-user systemd instance for root,
because the root account doesn't get a normal login session. PID-1
systemd is up and reachable, which is what the gate asserts.)

`systemctl is-system-running` returns `degraded` rather than `running`
because the imported rootfs has not had `apt-get install
systemd-resolved` (one of the services systemd-sysv wants on bookworm).
The R1 gate explicitly accepts `degraded` as a pass because the goal
is "PID-1 systemd is up and answering systemctl" — not "every unit
came up green". R2's typed recipe will tighten this once the from-
source service set is known.

### Wall-clock breakdown (warm second run after `apt-get update` cache exists)

| Phase | Time |
|-|-|
| `wsl --import` | ~2.5 s |
| `cat /etc/os-release` | ~0.5 s |
| `apt-get update && apt-get install -y systemd dbus systemd-sysv` | ~3.5 s (cached) |
| `wsl --terminate` | ~0.5 s |
| WSL2 systemd boot + first assertion | ~8.8 s |
| Second assertion (already in shell) | ~0.1 s |
| Cleanup (`wsl --unregister` + rmtree) | ~2 s |
| **Total** | **~17.7 s** |

(Cold first-ever run also fits inside ~25 s because `apt-get install`
is fetching ~8 MB of packages.)

## Cleanup verification

```powershell
PS> wsl -l -q | Select-String 'repro-test-boot-'  # empty
PS> Get-VM -Name 'repro-test-boot-*' -ErrorAction SilentlyContinue  # empty
```

The R0 WSL2 backend's safety prefix (`repro-test-boot-`) means
`wsl --unregister` is guaranteed to refuse anything else, and the
`finally:` block reliably tears the distro down even on Ctrl-C.

## Path forward to R2

R2 replaces this directory's hand-rolled `boot-test.py` with the
typed-action reprobuild ISO recipe:

1. `repro.nim` declares the boot medium (`iso` for Hyper-V/QEMU paths,
   `rootfs.tar.gz` for WSL2 path), the vendored kernel + initrd +
   bootloader (R1) or the reprobuild-built ones (R10), and the
   systemd userspace tree.
2. A `boot-gate:` block in `repro.nim` declares the assertions in the
   same shape as today's `expected.json`. The typed recipe materialises
   them at `repro build .` time into `.repro/build/reproos-ref-iso/expected.json`.
3. `boot-test.py` then consumes the generated `expected.json` from the
   build tree, removing the duplication this stub has between the
   recipe and the test driver.
4. The harness backend is selected per the boot medium kind: `iso` ->
   Hyper-V/QEMU, `rootfs.tar.gz` -> WSL2. Each backend reuses the same
   assertion DSL; only the I/O side differs (serial pipe for Hyper-V,
   `-serial stdio` for QEMU, subprocess stdin/stdout for WSL2).

R1 deliberately does NOT block on R2's typed recipe — the point of R1
is exactly to prove the gate works before the typed work starts.

## Estimated effort to lift R1 into R2

| Item | Effort (Eng-days) |
|-|-|
| `boot-gate:` block in repro_project_dsl + materialisation | 1.5 |
| Path B (Hyper-V Gen-2 UEFI + Debian cloud qcow2 -> VHDX) | 1.0 (gated on `qemu-img` install) |
| `boot-test.py` -> driver consuming materialised expected.json | 0.5 |
| Path A boot test wired to the new recipe | 0.5 |
| **Total** | **~3.5 Eng-days** |

Path B is the proper UEFI/ISO gate; Path A alone is enough to validate
the WSL2-userspace inner loop but does NOT exercise a kernel or boot-
loader. R2 should land Path B alongside the typed recipe so R3 (live-
USB) inherits a working ISO gate from day one.
