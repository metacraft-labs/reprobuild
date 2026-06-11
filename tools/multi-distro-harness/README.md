# Multi-distro WSL test harness

A disposable per-distro WSL2 test environment for the
[Linux-Distro-Recipe-Validation](../../reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org)
campaign. Provisions clean Arch / Debian / Ubuntu / Fedora / openSUSE / Alpine
instances under WSL2 from official upstream rootfs tarballs, installs a
minimum build-prereq set (gcc, make, git, curl), installs Nim from upstream
(choosenim) where the apt/dnf/zypper/pacman/apk repos lag, and runs a
hello-world smoke probe.

This is the M0 milestone of the campaign. Subsequent milestones (M1-M4)
build the `repro` binary inside each instance and exercise the recipe model.

## What lives here

```
tools/multi-distro-harness/
  README.md                 # this file
  _common.ps1               # shared helpers (download cache, wsl import, smoke probe)
  provision-arch.ps1        # one provisioner per distro
  provision-debian.ps1
  provision-ubuntu.ps1
  provision-fedora.ps1
  provision-opensuse.ps1
  provision-alpine.ps1
  teardown-all.ps1          # unregister ALL repro-* WSL instances (cache preserved)
  tests/
    smoke_hello.sh          # POSIX-sh hello-world test (runs inside each WSL instance)
scripts/
  run_multi_distro_tests.sh # cross-distro test driver
```

## Provisioning

Each `provision-<distro>.ps1` is independent. Run from any working directory:

```powershell
pwsh tools/multi-distro-harness/provision-alpine.ps1
pwsh tools/multi-distro-harness/provision-debian.ps1
pwsh tools/multi-distro-harness/provision-ubuntu.ps1
pwsh tools/multi-distro-harness/provision-fedora.ps1
pwsh tools/multi-distro-harness/provision-opensuse.ps1
pwsh tools/multi-distro-harness/provision-arch.ps1
```

Each script:

1. Downloads the distro's official rootfs tarball to
   `$env:LOCALAPPDATA\repro-multi-distro-cache\`. Re-running skips the download
   when the cached file's sha256 matches the pinned value.
2. Imports the tarball via `wsl --import repro-<distro> D:\wsl-instances\repro-<distro> ...`.
   If the instance already exists it's terminated + unregistered first for a
   clean import.
3. Installs the prereq packages (gcc, make, git, curl, xz, ca-certificates)
   via the distro's package manager.
4. Best-effort Nim install via `choosenim` (or apk for Alpine where choosenim's
   glibc binaries don't run on musl).
5. Runs the hello-world smoke probe: writes `/tmp/hello.c`, compiles with gcc,
   runs the binary, asserts the output.

The instance is **not** automatically started after the script finishes; use
`wsl -d repro-<distro>` to enter it for follow-up work.

## Rootfs sources

| Distro    | URL                                                                                       | sha256 (truncated) | Size  |
| --------- | ----------------------------------------------------------------------------------------- | ------------------ | ----- |
| Arch      | <https://archive.archlinux.org/iso/2025.12.01/archlinux-bootstrap-2025.12.01-x86_64.tar.zst> | `48277d93...8832bdf` | 139M |
| Debian    | <https://images.linuxcontainers.org/images/debian/bookworm/amd64/default/20260608_05:24/rootfs.tar.xz> | `90c1f6bf...d31ffefa` | 94M |
| Ubuntu    | <https://cloud-images.ubuntu.com/wsl/jammy/current/ubuntu-jammy-wsl-amd64-ubuntu22.04lts.rootfs.tar.gz> | `1483cc5c...d63fb4109` | 325M |
| Fedora    | <https://images.linuxcontainers.org/images/fedora/44/amd64/default/20260602_20:33/rootfs.tar.xz> | `8bb27c7e...ae5c13d9` | 94M |
| openSUSE  | <https://download.opensuse.org/tumbleweed/appliances/opensuse-tumbleweed-image.x86_64-lxc.tar.xz> | `66bbc157...3acfd15` | 33M |
| Alpine    | <https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-minirootfs-3.19.1-x86_64.tar.gz> | `185123ce...7e08fa29e` | 3M |

Full sha256 values live in the corresponding `provision-<distro>.ps1` for
verification. The Arch bootstrap tarball uses zstd and a `root.x86_64/` prefix
that `wsl --import` can't consume directly; `provision-arch.ps1` repackages it
to a flat `.tar.gz` via a transient Alpine helper instance the first time it
runs, caching the result under the same dir.

The Debian and Fedora rootfs are pinned to the snapshot dates above; bump the
snapshot in the provisioning script when refreshing.

## Running tests

```bash
# from the reprobuild repo root, in git-bash or pwsh
bash scripts/run_multi_distro_tests.sh smoke_hello --all
bash scripts/run_multi_distro_tests.sh smoke_hello arch debian fedora
```

The runner looks up the test under `tools/multi-distro-harness/tests/<name>.sh`,
invokes it as `/bin/sh <test>` inside each repro-* WSL instance, captures the
last 20 lines of output on failure, and reports `PASS`/`FAIL` per distro. Exit
code is `0` when every requested distro passes, `1` otherwise. Final line:

```
repro multi-distro: <pass>/<total> distros passed
```

If an instance doesn't exist the runner reports `FAIL` with a pointer to the
provisioning script; it does NOT auto-provision.

## Teardown

```powershell
pwsh tools/multi-distro-harness/teardown-all.ps1            # asks "yes/no"
pwsh tools/multi-distro-harness/teardown-all.ps1 -Force     # no prompt
```

Removes every `repro-*` WSL instance and its on-disk VHDX. **Never** touches
`eli-wsl` or any other instance whose name doesn't start with `repro-`. The
rootfs cache under `$env:LOCALAPPDATA\repro-multi-distro-cache\` is preserved
so a subsequent re-provision is a sha256 cache-hit + `wsl --import`.

Individual instance teardown:

```powershell
wsl --terminate repro-debian
wsl --unregister repro-debian
```

## Disk usage

| Item                                 | Approx. footprint |
| ------------------------------------ | ----------------- |
| Rootfs cache (all 6 distros)         | ~700 MB           |
| Arch flat-rootfs repack cache (.gz)  | ~150 MB           |
| Per-instance VHDX after smoke probe  | 200 MB - 1.5 GB   |
| All 6 instances (smoke-probed only)  | ~4 GB             |

The instance VHDX grows with package installs; running `repro` builds inside
the instance can grow it further. WSL2 VHDX doesn't auto-shrink; use
`wsl --shutdown` then `Optimize-VHD` to reclaim.

## Constraints (campaign-mandated)

1. **No Hyper-V VMs** in M0. The spec explicitly defers VM templates until
   a future milestone surfaces a WSL limitation.
2. **`eli-wsl` is untouchable.** The user's existing NixOS WSL instance is
   the canonical Tier-1-on-NixOS validation target; the M0 harness must
   not disturb it. Every `wsl --unregister` invocation in this directory
   verifies the target name starts with `repro-`.
3. **Smoke probe only.** M0 stops at "hello world compiles + runs"; M1
   begins reprobuild self-bootstrap on each distro.

## M1 — Arch self-bootstrap

The `bootstrap-arch.sh` script (`tools/multi-distro-harness/bootstrap-arch.sh`)
runs inside the provisioned `repro-arch` instance and builds the
`repro` + `repro-standard-provider` binaries from the Windows-mounted
source tree at `/mnt/d/metacraft/reprobuild`. The build path uses
ONLY pacman packages + two upstream sources (clingo + BLAKE3), no
`nix develop` anywhere.

Pacman prereqs (Step 1):

```
base-devel git curl ca-certificates xz nim sqlite openssl
cmake bison re2c
```

Upstream sources built from tarballs (Steps 2-3):

| Component | Version | Source                                                                   | Why                                                            |
| --------- | ------- | ------------------------------------------------------------------------ | -------------------------------------------------------------- |
| clingo    | 5.8.0   | <https://github.com/potassco/clingo/archive/refs/tags/v5.8.0.tar.gz>     | reprobuild_solver dlopens libclingo.so; not in Arch core/extra. |
| BLAKE3    | 1.5.0   | <https://github.com/BLAKE3-team/BLAKE3/archive/refs/tags/1.5.0.tar.gz>   | reprobuild_hash links libblake3; not in Arch core/extra.        |

Clingo needs an inline `re2c >= 4.3` compatibility patch pulled from
the AUR PKGBUILD (current Arch ships re2c 4.5+ which removed the
legacy `condition` block syntax clingo's vendored grammar files used);
the bootstrap script fetches the patch via a depth-1 git clone of
`aur.archlinux.org/clingo.git` and applies it before configuring
clingo's cmake build. Both clingo and BLAKE3 install to `/usr/local`
and the script wires `/etc/ld.so.conf.d/local.conf` so the runtime
loader sees them.

Nim build invocations (Step 4):

```sh
nim c -d:release --out:<work>/bin/repro \
    apps/repro/repro.nim
nim c -d:release -d:reproProviderMode \
    --out:<work>/bin/repro-standard-provider \
    apps/repro-standard-provider/repro_standard_provider.nim
```

Required env at build time:

```sh
REPROBUILD_USE_SYSTEM_HASH_LIBS=1   # config.nims: switch off vendored hash path
BLAKE3_PREFIX=/usr/local            # config.nims: where libblake3 lives
XXHASH_PREFIX=/usr                  # config.nims: where libxxhash lives
REPROBUILD_REPO_ROOT=/mnt/d/metacraft/reprobuild
```

Bootstrap timing (Arch on WSL2, Ryzen-class host):

| Run    | Wall time | Notes                                                |
| ------ | --------- | ---------------------------------------------------- |
| Cold   | ~4-7 min  | clingo + BLAKE3 cmake builds dominate (Nim ~80 s).   |
| Warm   | ~30-60 s  | clingo + BLAKE3 short-circuit; only Nim recompiles.  |

### Running M1 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m1_self_bootstrap arch
```

The test script (`tools/multi-distro-harness/tests/m1_self_bootstrap.sh`):

1. Runs `bootstrap-arch.sh` inside `repro-arch`.
2. Copies `examples/hello-world-c/` to `/tmp/reprobuild-bootstrap-arch/
   m1-recipe/hello-world-c/` (avoids the 9P-mounted Windows tree).
3. Invokes `repro build . --tool-provisioning=path --no-runquota`.
4. Asserts the produced binary at
   `.repro/build/hello-world-c/hello-world-c` outputs
   `hello from reprobuild M1`.
5. Wipes BOTH the per-project `.repro/build/` tree AND the global
   `~/.cache/repro/action-cache/`, rebuilds, asserts the new binary's
   sha256 matches the first build (content-addressability gate).

The test is Arch-specific by construction (`pacman -S` + upstream
clingo build) and refuses to run if `/etc/os-release` doesn't say
`ID=arch`. M2/M3/M4 will mirror the script shape for Debian / Fedora /
Alpine, replacing the package manager calls and (where the distro
packages clingo natively) the upstream-clingo-build step.

### Output layout

`repro build` lands per-package outputs under
`<project-root>/.repro/build/<package>/`. The global content-addressable
action cache (where the source-to-output digest mapping lives) is
`~/.cache/repro/action-cache/cas/`. NOTE: this is the production
layout as of 2026-06; it does NOT match the spec wording
`$REPRO_STORE_ROOT/<algo>-<digest>-<name>/` from
`Linux-Distro-Recipe-Validation.milestones.org` M1 verification clause.
The content-addressability guarantee (same input -> same digest) holds
under the actual layout but the surface name + per-output prefix
convention is yet to be implemented.

### Known scope adjustments

- **C/C++ recipes use Mode 3, not Mode 1.** The Mode 1 layout-as-
  manifest path (`libs/repro_cli_support/src/repro_cli_support/
  mode1_loader.nim`) does not yet emit a per-member C source shim, so
  the standard provider's `c_cpp_direct` convention reports "no
  convention matched" when invoked against a Mode-1-synthesised C
  project root. The `examples/hello-world-c/` recipe is Mode 3 (explicit
  `repro.nim` with `executable hello-world-c: discard` + `uses: "gcc"`)
  to sidestep this.
- **Hash libs source.** Arch's official repos ship `xxhash` but NOT
  `blake3`; the bootstrap script builds BLAKE3 from the upstream cmake
  project and installs to `/usr/local`. An alternative would be to wire
  `repro_interface_artifacts.nim`'s `externalHashFlags()` to fall back
  to the in-repo vendored sources under `references/mold/third-party/`
  on Linux (it currently only does so on Windows), eliminating the
  upstream build entirely. That is a source change and out of scope
  for the bootstrap.

## Future work (M2+)

- M2: same for Debian + Ubuntu.
- M3: same for Fedora.
- M4: same for Alpine (musl baseline).
- M5: cross-distro binary-cache push/pull.
