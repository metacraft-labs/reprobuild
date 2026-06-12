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
    smoke_hello.sh                  # POSIX-sh hello-world test (Recipe-Val M0)
    sandbox_check_bubblewrap.sh     # bwrap + user-ns probe (Sandbox-MVP M0)
    sandbox_transparency_probe.sh   # bwrap passthrough transparency probe (Sandbox-MVP M0)
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

## M2 — Debian + Ubuntu self-bootstrap

`bootstrap-debian.sh` and `bootstrap-ubuntu.sh` mirror M1's shape inside
`repro-debian` (Debian 12 / bookworm) and `repro-ubuntu` (Ubuntu 22.04
LTS / jammy). Same flow: apt prereqs + upstream-built clingo + upstream-
built BLAKE3 + `nim c -d:release` of `apps/repro` + `apps/repro-standard-
provider` from `/mnt/d/metacraft/reprobuild`, no `nix develop`. Both
scripts use M0's choosenim-installed Nim 2.2.10 at `/root/.nimble/bin/nim`
(neither distro's apt repo ships a usable Nim).

The two scripts are clone-and-tweak rather than refactored into a shared
helper; consolidation is its own concern (a future cleanup milestone),
not part of M2's deliverable.

Apt prereqs (Step 1, identical on both):

```
build-essential git curl ca-certificates xz-utils
pkg-config libssl-dev libsqlite3-dev libxxhash-dev
cmake bison re2c unzip
```

Upstream sources built from tarballs (Steps 2-3, identical to M1):

| Component | Version | Source                                                                   | Why                                                                          |
| --------- | ------- | ------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| clingo    | 5.8.0   | <https://github.com/potassco/clingo/archive/refs/tags/v5.8.0.tar.gz>     | Not in Debian bookworm or Ubuntu jammy apt repos as of 2026-06.              |
| BLAKE3    | 1.5.0   | <https://github.com/BLAKE3-team/BLAKE3/archive/refs/tags/1.5.0.tar.gz>   | Not in bookworm or jammy apt repos. (Ubuntu 24.04 noble DOES ship libblake3-dev.) |

Per-distro divergences from M1 (Arch):

- **No re2c-4.3 compat patch.** Both Debian bookworm and Ubuntu jammy
  ship re2c 3.0, which still accepts clingo 5.8.0's vendored grammar
  files. The AUR patch M1 applies (targeting Arch's re2c 4.5+) is
  NOT applied on either apt-based distro.
- **xxhash multiarch symlink.** `libxxhash-dev` installs into
  `/usr/lib/x86_64-linux-gnu/` but reprobuild's `config.nims`
  `firstExistingPrefix` only probes `<prefix>/lib/<dylib>`. Both
  bootstrap scripts symlink the apt-shipped `.so` + headers into
  `/usr/local/lib` + `/usr/local/include` (alongside BLAKE3) and
  export `XXHASH_PREFIX=/usr/local`.
- **Nim source.** Arch's pacman ships nim 2.2.10 on `/usr/sbin/nim`
  (on PATH). Debian's apt nim is 1.6.10 (too old); Ubuntu jammy has
  no `nim` apt package at all. Both bootstrap scripts use M0's
  choosenim install at `/root/.nimble/bin/nim` (Nim 2.2.10) and
  inject that directory into PATH for downstream `repro build`
  invocations (the test script adds it ahead of `repro build`).

Bootstrap timing (WSL2 / Ryzen-class host):

| Distro | Run  | Wall time   | Notes                                                       |
| ------ | ---- | ----------- | ----------------------------------------------------------- |
| Debian | Cold | 11 min 02 s | clingo + BLAKE3 cmake builds dominate (~7 min combined).    |
| Debian | Warm | 3 min 14 s  | clingo + BLAKE3 short-circuit; only Nim recompiles.         |
| Ubuntu | Cold | 4 min 08 s  | clingo + BLAKE3 cmake builds + first Nim build.             |
| Ubuntu | Warm | 3 min 20 s  | clingo + BLAKE3 short-circuit; only Nim recompiles.         |

(The Debian cold timing is higher than Ubuntu's despite identical
script logic — both ran on the same host. Likely sources of the gap:
WSL2 9P I/O cold-cache effects on the very first `apt-get install` run
that warmed Ubuntu by the time Debian's was measured, and Debian's
slightly larger clingo + BLAKE3 install footprint into the freshly-
wiped `/usr/local`. The warm timings, which exclude cmake/install, are
within 6 s of each other.)

### Running M2 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m2_self_bootstrap debian ubuntu
```

The test script (`tools/multi-distro-harness/tests/m2_self_bootstrap.sh`)
is a single file that dispatches on `/etc/os-release` `ID`:

1. Detects distro (must be `debian` or `ubuntu`).
2. Runs the matching `bootstrap-{debian,ubuntu}.sh`.
3. Copies `examples/hello-world-c/` (the same M1 recipe, unchanged) to
   `/tmp/reprobuild-bootstrap-<distro>/m2-recipe/hello-world-c/`.
4. Invokes `repro build . --tool-provisioning=path --no-runquota`.
5. Asserts the binary outputs `hello from reprobuild M1` (recipe is
   unchanged from M1).
6. Wipes the per-project `.repro/build/` tree + global
   `~/.cache/repro/action-cache/`, rebuilds, asserts intra-distro
   sha256 bit-identity.

The test refuses to run on non-Debian / non-Ubuntu hosts.

### Content-addressability sha256 (intra-distro)

| Distro | sha256 of `hello-world-c` (build #1 == build #2)                        |
| ------ | ----------------------------------------------------------------------- |
| Debian | `9057905d822360d4c14c2c8460cd157dedabdd90e770cc7aabc3b3ada332a378`      |
| Ubuntu | `1ed6a9525cdb9af8766c8a5a6cff1a329f5d91ba62359bb0d5f5a56b54e763db`      |

Cross-distro sha256 differ from each other and from M1's Arch
(`f602a18b...`); each distro pins a different gcc (Debian gcc-12,
Ubuntu gcc-11, Arch gcc-15.x) + glibc + binutils combination, so the
linked binaries don't match across distros. Cross-distro bit-identity
via the peer cache (build on Arch, pull on Debian) is M5's scope.

## M3 — Fedora self-bootstrap

`bootstrap-fedora.sh` mirrors M1+M2's shape inside `repro-fedora`
(Fedora 44). Same flow: dnf prereqs + `nim c -d:release` of
`apps/repro` + `apps/repro-standard-provider` from
`/mnt/d/metacraft/reprobuild`, no `nix develop`. Like M2's bootstraps,
it uses M0's choosenim-installed Nim 2.2.10 at `/root/.nimble/bin/nim`
(Fedora 44's main repo ships no `nim` at all).

The headline divergence from M1+M2: **Fedora 44 ships clingo, BLAKE3,
and xxhash in its main repo**, so neither the M1 AUR-style upstream
clingo build nor the M2 upstream BLAKE3 build is needed. The script
skips Steps 2 and 3 entirely; everything that M2 fetched as a tarball
comes from `dnf install`.

Dnf prereqs (Step 1):

```
gcc make git curl ca-certificates xz
pkgconf-pkg-config openssl-devel sqlite-devel
cmake bison re2c unzip
clingo-devel blake3-devel xxhash-devel
```

Pkg sources (dnf vs upstream):

| Component  | Fedora 44 dnf            | Source chosen | Reason                                                       |
| ---------- | ------------------------ | ------------- | ------------------------------------------------------------ |
| nim 2.2+   | not in repos             | choosenim     | No `nim` rpm in main+updates as of 2026-06.                  |
| libclingo  | `clingo-devel` 5.8.0     | dnf           | Same upstream version M1+M2 built from tarball; ships ready. |
| libblake3  | `blake3-devel` 1.8.3     | dnf           | Newer than M1+M2's 1.5.0 tarball; ships ready.               |
| xxhash     | `xxhash-devel` 0.8.3     | dnf           | Same version M2 got from apt; ships ready.                   |

Divergences from M1 (Arch) + M2 (Debian/Ubuntu):

- **No upstream clingo build.** M1's AUR re2c-4.3 compat patch +
  upstream-tarball clingo build, and M2's identical upstream-tarball
  clingo build, are both dropped on Fedora. `dnf install clingo-devel`
  lands `libclingo.so` at `/usr/lib64/libclingo.so` and the system
  loader finds it via the default `ldconfig` cache (`/usr/lib64` is on
  the default search path on Fedora).
- **No upstream BLAKE3 build.** Same removal — `dnf install
  blake3-devel` lands `libblake3.so` at `/usr/lib64/libblake3.so` +
  the header at `/usr/include/blake3.h`. The dnf-shipped 1.8.3 is
  newer than M1+M2's upstream 1.5.0 but the C API is back-compatible.
- **`/usr/lib64` symlink workaround.** Fedora installs shared libs to
  `/usr/lib64/` (32-bit libs go to `/usr/lib/`). Reprobuild's
  `config.nims` `firstExistingPrefix` only probes `<prefix>/lib/<dylib>`
  — NOT `lib64`. So setting `BLAKE3_PREFIX=/usr` would fail (the
  resolver finds `/usr/include/blake3.h` but no `/usr/lib/libblake3.so`).
  Mirror M2's apt-multiarch workaround: symlink `/usr/lib64/libblake3.so`
  and `/usr/lib64/libxxhash.so` (plus their `.so.0` aliases + headers)
  into `/usr/local/lib` + `/usr/local/include`, then export
  `BLAKE3_PREFIX=/usr/local` + `XXHASH_PREFIX=/usr/local`. A cleaner
  fix would be a `config.nims` patch teaching the helper about
  `/usr/lib64`; that is a source change and out of M3's bootstrap-only
  scope.
- **Package-name nits.** Fedora uses `pkgconf-pkg-config` (not
  `pkg-config` or `pkgconfig`), `openssl-devel` (not `libssl-dev`),
  `sqlite-devel` (not `libsqlite3-dev`), `xz` (not `xz-utils`). No
  meta-pkg like `base-devel`/`build-essential` — list `gcc` + `make`
  explicitly. (Fedora's `@development-tools` group exists but pulls
  in ~40 packages incl. autoconf/automake we don't need; the explicit
  list is leaner.)

Bootstrap timing (WSL2 / Ryzen-class host):

| Distro | Run  | Wall time   | Notes                                                                  |
| ------ | ---- | ----------- | ---------------------------------------------------------------------- |
| Fedora | Cold | 3 min 14 s  | dnf install (clingo+blake3+xxhash+toolchain) + 2x `nim c -d:release`.  |
| Fedora | Warm | 2 min 32 s  | dnf already-installed short-circuits; only Nim recompiles.             |

Fedora's cold time is FASTER than M2's Debian cold (11:02) and matches
M2's Ubuntu cold (4:08) within noise — the difference is the absence
of the upstream clingo + BLAKE3 cmake builds (~7 min on Debian, ~2 min
on Ubuntu). Fedora's warm is faster than M1's Arch warm (3:14) and
M2's Debian/Ubuntu warm (3:14 / 3:20), again because Fedora skips the
"is upstream clingo/blake3 still installed?" filesystem checks the
M1/M2 scripts make on every warm run.

### Running M3 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m3_self_bootstrap fedora
```

The test script (`tools/multi-distro-harness/tests/m3_self_bootstrap.sh`):

1. Detects distro (must be `fedora`).
2. Runs `bootstrap-fedora.sh`.
3. Copies `examples/hello-world-c/` (the same M1+M2 recipe, unchanged)
   to `/tmp/reprobuild-bootstrap-fedora/m3-recipe/hello-world-c/`.
4. Invokes `repro build . --tool-provisioning=path --no-runquota`.
5. Asserts the binary outputs `hello from reprobuild M1` (recipe is
   unchanged from M1).
6. Wipes the per-project `.repro/build/` tree + global
   `~/.cache/repro/action-cache/`, rebuilds, asserts intra-distro
   sha256 bit-identity.

The test refuses to run on non-Fedora hosts.

### Content-addressability sha256 (intra-distro)

| Distro | sha256 of `hello-world-c` (build #1 == build #2 across full cache wipe) |
| ------ | ----------------------------------------------------------------------- |
| Fedora | `c26c2cd986f789e9970b564dea245f0f3b17812340a4a88151c2a12055530b33`      |

Cross-distro sha256 differs from M1's Arch (`f602a18b...`), M2's
Debian (`9057905d...`) and M2's Ubuntu (`1ed6a952...`) — Fedora 44's
gcc 16.1.1 + glibc differs from every M1/M2 baseline (Arch gcc 15.x,
Debian gcc 12, Ubuntu gcc 11). Cross-distro bit-identity is M5's
scope (peer-cache pull).

## M4 — Alpine self-bootstrap (musl baseline)

`bootstrap-alpine.sh` mirrors M1+M2+M3's shape inside `repro-alpine`
(Alpine Linux 3.19, musl 1.2.4). Same flow: apk prereqs +
`nim c -d:release` of `apps/repro` + `apps/repro-standard-provider`
from `/mnt/d/metacraft/reprobuild`, no `nix develop`. Two new wrinkles
relative to M1-M3:

1. **Nim 2.2.10 is built from source** (~2 min) because Alpine
   edge/community's apk nim is at 2.2.0, which has a codegen bug that
   mis-generates the eqdestroy hook signature for sequence types
   (`apps/repro` fails to compile at `codec_u551` in
   `repro_dev_env_artifacts/codec.nim`). The fix landed in Nim 2.2.2+;
   we use 2.2.10 to match M1-M3 exactly. choosenim is NOT a fallback:
   its pre-built nim binaries are glibc-linked and refuse to execute
   on musl. The source build path is:

   ```sh
   curl -fsSL -o nim-2.2.10.tar.xz https://nim-lang.org/download/nim-2.2.10.tar.xz
   tar xJf nim-2.2.10.tar.xz && cd nim-2.2.10
   sh ./build.sh                   # csources -> v1 nim via gcc
   ./bin/nim c koch                # compile koch
   ./koch boot -d:release          # self-host up to 2.2.10
   ```

   No pre-existing Nim is required — Nim's release tarball includes a
   frozen `c_code/` csources subtree that `build.sh` compiles via plain
   gcc.

2. **Apk's edge repos** are enabled for the three hash/solver
   dev packages (`blake3-dev`, `xxhash-dev`, `clingo-dev`). Alpine 3.19
   main has clingo 5.6.2 + xxhash-dev 0.8.2 but **no blake3 at all**;
   the edge repos carry blake3-dev 1.8.5 + clingo-dev 5.8.0 +
   xxhash-dev 0.8.3 — all matching the versions M3 (Fedora) consumes
   from dnf. Like M3 and unlike M1+M2, no upstream tarball builds of
   clingo or blake3 are needed.

Apk prereqs (Step 1):

```
build-base git curl ca-certificates xz
pkgconf openssl-dev sqlite-dev
cmake bison re2c unzip
blake3-dev xxhash-dev clingo-dev   (from edge/community + edge/main)
```

Pkg sources (apk vs upstream):

| Component  | Alpine 3.19 main    | Alpine edge             | Source chosen | Reason                                              |
| ---------- | ------------------- | ----------------------- | ------------- | --------------------------------------------------- |
| nim 2.2.2+ | nim 1.6.16 (too old)| nim 2.2.0 (codegen bug) | source build  | apk 2.2.0 mis-generates eqdestroy hooks; choosenim is glibc-only on musl. |
| libclingo  | clingo-dev 5.6.2    | clingo-dev 5.8.0        | apk/edge      | Edge matches the upstream version M1+M2 built from tarball. |
| libblake3  | (not present)       | blake3-dev 1.8.5        | apk/edge      | Same back-compat C API as M1+M2's upstream 1.5.0.   |
| xxhash     | xxhash-dev 0.8.2    | xxhash-dev 0.8.3        | apk/edge      | Edge for version consistency with the other edge deps. |

Divergences from M1 (Arch) + M2 (Debian/Ubuntu) + M3 (Fedora):

- **Nim from source.** The most distinctive M4 trait; no other
  milestone needs to build the Nim compiler. Adds ~2 min to the cold
  bootstrap and ~120 MB to the work tree.
- **Flat /usr/lib + /usr/include — no /usr/local symlink.** Unlike
  M2's Debian multiarch (`/usr/lib/x86_64-linux-gnu/`) and M3's Fedora
  `/usr/lib64/`, Alpine installs all shared libraries to `/usr/lib/`.
  That's exactly what reprobuild's `config.nims` `firstExistingPrefix`
  probes natively (`<prefix>/lib/<dylib>`), so `BLAKE3_PREFIX=/usr` +
  `XXHASH_PREFIX=/usr` resolve directly. The M2/M3 `/usr/local`
  symlink workaround is NOT needed on Alpine.
- **POSIX-sh strictness.** Alpine's `/bin/sh` is busybox ash, not bash.
  The bootstrap script is strictly POSIX sh — no `[[ ]]`, no
  `$'...'`, no arrays. (M1-M3's scripts are already POSIX-clean; M4
  maintains the contract.)
- **Nim PATH injection requires the source-built bin dir.**
  Like M2+M3 and unlike M1 (where pacman's nim is on `/usr/bin`),
  Alpine's source-built nim lives under
  `${WORK_ROOT}/nim-2.2.10/bin/`. The test script injects that
  directory ahead of `repro build` so the recipe-build leg (which
  forks `nim` to compile the recipe's `repro.nim`) finds the right
  Nim — not apk's broken 2.2.0 (or no nim at all if apk's nim was
  never installed).
- **Package-name nits.** Alpine uses `build-base` (not `base-devel` /
  `build-essential` / `gcc make`), `pkgconf` (not `pkg-config` /
  `pkgconf-pkg-config`), `openssl-dev` (no `lib` prefix),
  `sqlite-dev` (no `lib` prefix), `xz` (no `-utils`). musl-dev is
  pulled in by build-base and replaces glibc-headers.

Bootstrap timing (WSL2 / Ryzen-class host):

| Distro | Run        | Wall time   | Notes                                                                  |
| ------ | ---------- | ----------- | ---------------------------------------------------------------------- |
| Alpine | Cold       | 4 min 41 s  | apk (~30s) + Nim source build (~2 min) + reprobuild Nim build (~2 min). |
| Alpine | Warm       | ~25 s       | apk no-op, Nim binary reused, only reprobuild Nim recompiles.          |
| Alpine | Test runner cold | 5 min 34 s  | Full m4_self_bootstrap including recipe build + cache wipe + rebuild. |
| Alpine | Test runner warm | 2 min 27 s  | Bootstrap short-circuits; only recipe build + wipe + rebuild.        |

Alpine's cold bootstrap is the slowest of the four because of the
~2 min Nim source build; the rest (apk install + reprobuild Nim
builds) is comparable to M3 (Fedora) cold's 3:14. Warm Alpine is the
fastest of M1-M4 (apk no-op + Nim binary already built; only the
reprobuild Nim re-link runs).

### Running M4 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m4_self_bootstrap alpine
```

The test script (`tools/multi-distro-harness/tests/m4_self_bootstrap.sh`):

1. Detects distro (must be `alpine`).
2. Runs `bootstrap-alpine.sh`.
3. Copies `examples/hello-world-c/` (the same M1+M2+M3 recipe,
   unchanged) to `/tmp/reprobuild-bootstrap-alpine/m4-recipe/hello-world-c/`.
4. Invokes `repro build . --tool-provisioning=path --no-runquota`.
5. Asserts the binary outputs `hello from reprobuild M1` (recipe is
   unchanged from M1).
6. Wipes the per-project `.repro/build/` tree + global
   `~/.cache/repro/action-cache/`, rebuilds, asserts intra-distro
   sha256 bit-identity.

The test refuses to run on non-Alpine hosts.

### Content-addressability sha256 (intra-distro)

| Distro | sha256 of `hello-world-c` (build #1 == build #2 across full cache wipe) |
| ------ | ----------------------------------------------------------------------- |
| Alpine | `6752c496a26fd6f60c8b6724ba9d173eb916f346333a17c6343684ff682dce5b`      |

Cross-distro sha256 differs from M1's Arch (`f602a18b...`), M2's
Debian (`9057905d...`), M2's Ubuntu (`1ed6a952...`), and M3's Fedora
(`c26c2cd9...`). The musl-vs-glibc gap is the headline source of
divergence on Alpine, layered on top of Alpine 3.19's gcc 13.x +
binutils + linker versions. **This is the most architecturally
distinct sha256 of the campaign so far** and the most important data
point for the ReproOS-MVP cross-distro story — when M5 wires the
peer-cache pull path, the input recipe + action-cache keys MUST hash
the same on Alpine as on Arch/Debian/Ubuntu/Fedora (the content-address
gate); the OUTPUT shas legitimately differ because the toolchains are
different.

### ReproOS-MVP relevance

M4 closes the only musl-libc data point in the Linux-Distro-Recipe-
Validation campaign. The ReproOS-MVP Phase 1 chain (hex0 -> tcc ->
gcc -> musl) bootstraps a musl-only userland; M4's findings
(Nim 2.2.0 codegen bug, source-build path, flat /usr/lib layout)
all feed directly into that work.

## M6 — `repro home apply` on non-NixOS Linux

`tools/multi-distro-harness/tests/m6_home_apply.sh` exercises the
M68/M83 home-scope apply pipeline against the same `repro` binary
M1-M4 build, on every non-NixOS distro the campaign covers (arch /
debian / ubuntu / fedora / alpine). The Dotfiles-Migration-Completion
campaign already validated the apply path on NixOS (`eli-wsl`),
where it had to dodge home-manager; M6 confirms the path works on
distros without a hostile declarative neighbour.

The fixture profile lives at
`tools/multi-distro-harness/tests/fixtures/m6_home_profile.nim`. It
exercises the four headless home-scope primitives:

| Primitive             | What the profile declares                                            |
| --------------------- | -------------------------------------------------------------------- |
| `fs.userFile`         | `~/.config/m6-test/marker.txt` + `~/.config/m6-test/hello.sh` (0755). |
| `env.userVariable`    | `REPRO_M6_HOME_APPLY=1` (rendered into the POSIX rc managed block).  |
| `env.userPath`        | `/opt/repro-m6-test/bin` contribution (driver test-seam `REPRO_HOME_POSIX_PATH_RC`). |
| `shell.integration`   | A managed block in `~/.config/m6-test/shell-hook.sh`.                |

GUI / Wayland / X primitives (`linux.dconfKey`, `linux.kdeConfigKey`,
`vscode.extension`, `systemd.userUnit` with a real GUI target) are
deliberately excluded — the `repro-*` WSL instances are headless.

The test driver:

1. Re-runs the matching `bootstrap-<distro>.sh` (warm-build short-circuit).
2. Stages the fixture as `home.nim` under `${WORK_ROOT}/m6-home/profile/`.
3. Exports `REPRO_HOME_STATE_DIR`, `REPRO_HOME_STORE_ROOT`,
   `REPRO_HOME_POSIX_PATH_RC`, and `REPRO_HOST=m6-test-host` so the
   apply lands in isolated test paths and the host-table lookup
   resolves to the fixture's `default` activity deterministically
   (without depending on the WSL kernel hostname which differs per
   distro: `archlinux` / `debian` / `ubuntu` / `fedora` / `alpine`).
4. Runs `repro home apply --plan` and asserts the rendered plan
   names every expected resource address (`marker`, `hello`,
   `m6Var`, `m6Path`, `m6Hook`).
5. Runs `repro home apply` for real (the WSL instance IS the
   disposable sandbox per the M6 brief).
6. Verifies on-disk materialization: marker file, hello.sh
   executable + output, PATH contribution managed block, shell-
   integration managed block (with `repro-managed:` sentinels).
7. Re-runs `repro home apply --plan` and asserts the plan reports
   `plan status: no-op (matches the active generation)` + `0 drift`.

The `EXIT` trap removes the per-run state-dir + `~/.config/m6-test/`
so a re-run starts clean even after a failure.

### Per-distro op count + status

All five distros produce the same plan shape (one operation per
declared resource, none cross-distro divergence at the planner
level):

| Distro | Initial plan ops | Drift plan status | Notes                                              |
| ------ | ---------------- | ----------------- | -------------------------------------------------- |
| Arch   | 5                | no-op             | Uses pacman's nim 2.2.10 directly.                 |
| Debian | 5                | no-op             | Uses M2's choosenim nim at `/root/.nimble/bin`.    |
| Ubuntu | 5                | no-op             | Uses M2's choosenim nim at `/root/.nimble/bin`.    |
| Fedora | 5                | no-op             | Uses M3's choosenim nim at `/root/.nimble/bin`.    |
| Alpine | 5                | no-op             | Uses M4's source-built nim at `${WORK_ROOT}/nim-2.2.10/bin`. |

The Op count is identical across all 5 distros because the home-scope
primitives are uniform on Linux — there is no per-distro path
divergence at the home scope (cross-distro divergence is concentrated
in the SYSTEM scope, which is M7's territory: Debian's
`/usr/share/bash-completion/` vs Fedora's `/etc/bash_completion.d/`
etc.).

### Closed finding: `env.userVariable` POSIX arm landed

Pre-fix: `applyUserVariableCreate` / `applyUserVariableUpdate` /
`applyUserVariableDestroy` in
`libs/repro_home_resources/src/repro_home_resources/drivers/env_user.nim`
were gated `when defined(windows):` and were no-ops on POSIX. The
M6 step 6d soft-warned on the gap so it surfaced in the logs.

The POSIX arm now writes `export <name>='<value>'` into a per-variable
managed block (`repro-home-env-<name>`) in the same shell rc file the
`env.userPath` driver owns
(`defaultUserPathHostFile()`-resolved, overridable via
`REPRO_HOME_POSIX_PATH_RC` for tests). The destroy direction removes
the per-variable managed block, leaving the user's surrounding rc
content intact. The post-apply digest matches the re-observed
managed-block bytes so the lifecycle algorithm reports no-op on
re-apply.

Regression coverage:
`libs/repro_home_resources/tests/t_smoke_home_resources.nim` →
`Recipe-Val side-finding: POSIX env.userVariable arm` (6 tests:
render, escape, block-id stability, create round-trip, destroy
round-trip, two-var coexistence).

All 5 home-scope primitives (`fs.userFile` x2, `env.userPath`,
`shell.integration`, `env.userVariable`) now materialize correctly
on all 5 non-NixOS distros. M6 step 6d can be promoted from
soft-warn to hard-assert at the next harness pass.

### Running M6 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m6_home_apply --all       # 5/5 expected
bash scripts/run_multi_distro_tests.sh m6_home_apply arch        # 1/1
```

opensuse is OUT of M6 scope (`opensuse-tumbleweed` is in the M0
smoke-probe sweep but the M1-M9 milestones explicitly scope to
arch/debian/ubuntu/fedora/alpine). The harness will report
`opensuse` as FAIL with the message `unrecognized ID` when invoked
via `--all`; this is by design.

## M7 — `repro infra plan` on non-NixOS Linux

`tools/multi-distro-harness/tests/m7_infra_plan.sh` exercises the
M69+M83 system-scope plan pipeline against the same `repro` binary
M1-M4 build, on every non-NixOS distro the campaign covers (arch /
debian / ubuntu / fedora / alpine). Where M6 covered the home scope
(uniformly five operations on every distro), M7 covers the system
scope using the generic-Linux primitives that don't require the
NixOS-only `linux.nixosSystemModule` escape-hatch driver.

The fixture profile lives at
`tools/multi-distro-harness/tests/fixtures/m7_system_profile.nim`. It
exercises three plan-time-safe system-scope primitives:

| Primitive            | What the profile declares                                                      |
| -------------------- | ------------------------------------------------------------------------------ |
| `systemd.systemUnit` | A minimal `m7-hello.service` oneshot unit (`enabled: false`).                  |
| `fs.systemFile`      | `/etc/m7-test/marker` at mode 0644.                                            |
| `os.timezone`        | `Etc/UTC` (the IANA value every fresh WSL instance defaults to or near).       |

Skipped per the brief:

- `passwd.user` — plan-time observation reads `/etc/passwd`; for any
  unknown user the planner emits `create`, which is correct, but the
  apply path requires elevation (M82 broker) and is outside M7 scope.
- `linux.firewallRule` — some distros' plan-time observation probes
  the live iptables/nftables chain, which can fault on WSL kernels
  without netfilter modules.

Both are deferred to a future system-scope-apply milestone.

The test driver:

1. Re-runs the matching `bootstrap-<distro>.sh` (warm-build
   short-circuits when the repro binary is already present).
2. Stages the fixture as `system.nim` under `${WORK_ROOT}/m7-infra/profile/`.
3. Runs `repro infra plan --profile=<...>/system.nim --state-dir=<...>`
   and captures the rendered plan.
4. Asserts the plan exit code is zero, every declared resource address
   (`m7HelloUnit`, `m7Marker`, `m7Timezone`) appears in the plan output,
   and the plan ends with either the `would change the system` or
   `no-op` header.
5. Captures the per-distro operation count for the table below.
6. **Does NOT** run `repro infra apply`. The brief is explicit: plan
   only, no elevation, no mutation of the WSL instance's real
   `/etc/`. Generation switch + rollback is M9's gate.
7. The `EXIT` trap removes the per-run state-dir; no on-disk
   artifacts under `/etc/m7-test/` exist because apply never ran.

### Per-distro plan op counts + observation divergence

All five distros parse the fixture, compile through the M83 Phase A
typed-DSL adapter, and emit a three-operation plan. The per-resource
ACTION differs on the timezone resource because the plan-time
observation reads the live system tz:

| Distro | Initial plan ops | systemd.systemUnit | fs.systemFile | os.timezone | Notes                                                                  |
| ------ | ---------------- | ------------------ | ------------- | ----------- | ---------------------------------------------------------------------- |
| Arch   | 3                | create             | create        | **update**  | Pre-existing `/etc/localtime` doesn't byte-match the desired digest.   |
| Debian | 3                | create             | create        | **update**  | Same as Arch — apt-shipped tzdata + the WSL rootfs default differ.     |
| Ubuntu | 3                | create             | create        | update      | Same shape as Debian (cloud-images.ubuntu.com WSL tarball).            |
| Fedora | 3                | create             | create        | **update**  | dnf-shipped tzdata; `/etc/localtime` is a symlink into `/usr/share/zoneinfo/UTC`. |
| Alpine | 3                | create             | create        | **create**  | NO `/etc/localtime` on a fresh musl rootfs (tzdata is opt-in apk).      |

The op COUNT is identical (3) on every distro — the planner is
platform-pure. The per-resource ACTION divergence on the timezone
row is the most informative output of the gate: it reports the
live system state the planner observed, which IS the per-distro
divergence the M7 brief asks for.

### Per-distro path / systemd convention findings

- **Arch**: pacman ships systemd as the real init. `/etc/systemd/system/`
  is the canonical drop-in dir; the plan-time observation only reads
  the path (no `systemctl daemon-reload` runs at plan time).
- **Debian / Ubuntu**: apt-managed systemd; WSL defaults to
  Microsoft's init unless `/etc/wsl.conf` opts in to systemd. The M7
  plan observation is filesystem-only so the gate does not depend on
  systemd being live.
- **Fedora**: dnf-managed systemd. `/etc/systemd/system/` overrides
  `/usr/lib/systemd/system/` (the distro-shipped unit dir). Same
  filesystem-only observation as the other systemd distros.
- **Alpine**: NO systemd — openrc is the real init. The plan reports
  a legal `create` for the unit file (the filesystem write would
  succeed; the unit just would never start because nothing reads
  `/etc/systemd/system/` on a musl/openrc host). **Apply-time
  carve-out (Recipe-Validation follow-up): landed.**
  `applySystemdSystemUnit` + `applySystemdSystemTimer` now fail
  closed with an `EProtocol` directive on any host whose
  `/etc/os-release` declares `ID=alpine` / `ID=void` / `ID=gentoo`,
  pointing the operator at the OpenRC-equivalent
  `openrc.service` (Phase-D) resource or the `fs.systemFile`
  alternative for stage-only intent. The closed-set predicate
  `usesSystemdFromOsRelease` lives in
  `libs/repro_elevation/src/repro_elevation/posix_system_parse.nim`
  (pure parser, cross-platform tests); the host probe with the
  `REPRO_OS_RELEASE_PATH` test seam lives in
  `posix_system_driver.nim`. M7's brief is plan-only so the read-only
  observation surface is unchanged.
- **Timezone driver — Etc/UTC fast-path (CLOSED follow-up)**: every
  glibc distro under WSL has `/etc/localtime` pre-set to UTC (the
  same IANA value the fixture declares); pre-fix the plan reported
  `update` not `no-op` because `UTC` (the symlink-target basename)
  and `Etc/UTC` (the declared IANA name) hashed differently in the
  drift digest. Recipe-Validation follow-up: `canonicalIanaTimezone`
  (in `os_system_parse.nim`) now collapses the IANA-tzdb-link
  aliases — `UTC` / `Etc/UTC` / `Etc/Zulu` / `Universal` all
  canonicalise to `UTC`; the `GMT` family collapses to `Etc/GMT`.
  The drift digest is computed on the canonicalised string so an
  observed `UTC` and a declared `Etc/UTC` no longer produce a
  spurious `update` action. Regression: `Recipe-Val side-findings:
  os.timezone canonicalization` (4 tests in `t_smoke_repro_elevation.nim`).

### Running M7 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m7_infra_plan --all       # 5/5 expected
bash scripts/run_multi_distro_tests.sh m7_infra_plan arch        # 1/1
```

opensuse is OUT of M7 scope (consistent with M6 — M1-M9 explicitly
covers arch/debian/ubuntu/fedora/alpine). The harness reports
`opensuse` as FAIL with `unrecognized ID` when invoked via `--all`;
this is by design.

## M9 — Generation switch + rollback demo

`tools/multi-distro-harness/tests/m9_rollback.sh` exercises the M83
generation registry + M10 home-gc engine + M56 content-addressed
store end-to-end on a non-NixOS distro. The fixture pair
(`tests/fixtures/m9_profile_a.nim` + `m9_profile_b.nim`) declares
the SAME resource address (`rollbackFile`) with DIFFERENT
`fs.userFile` content so the test driver can byte-compare the live
file's contents after each transition.

The test driver:

1. Re-runs `bootstrap-debian.sh` (warm-build short-circuit).
2. Stages profile A as `home.nim` under `${WORK_ROOT}/m9-rollback/profile/`.
3. Resets per-run `STATE_DIR` + `STORE_ROOT` + `${HOME}/.config/m9-test/`.
4. Runs `repro home apply` for profile A; captures `ID_A` from the
   `applied generation <hex>` log line; asserts the live file's
   bytes match `m9-profile-A\n`.
5. Swaps the staged profile to B; re-applies; captures `ID_B`;
   asserts `ID_A != ID_B` + the live file is now `m9-profile-B\n`.
6. Runs `repro home history`; asserts both generation short ids
   (12-char hex) appear AND B's row carries the `[active]` marker.
7. Runs `repro home rollback ${ID_A}`; asserts the log contains
   `rolled back from ${ID_B} to ${ID_A}`; re-reads the live file
   and asserts the bytes are back to `m9-profile-A\n`; re-runs
   `repro home history` and asserts the `[active]` marker is now
   on A's row (NOT on B's).
8. Runs `repro home gc --dry-run --keep-generations 1`; asserts the
   log contains `no orphaned prefixes` (the M9 profile is
   package-free, so the M10 gc engine has nothing to reclaim —
   the assertion confirms the engine ran against the right
   state-dir + store-root + correctly computed the empty
   live-prefix set).
9. Runs `repro store gc`; asserts the `reclaimed: <N>` line is
   present and `repro store roots` still lists `${ID_A}` (the
   active generation MUST stay registered).

The `EXIT` trap removes `${WORK_ROOT}/m9-rollback/` + `~/.config/m9-test/`
so a re-run starts clean even after a failure.

### Debian-only by design

M9 runs on `repro-debian` only. The M83 generation registry, the
M10 home-gc engine, and the M56 store gc are all platform-pure —
per-distro divergences (gcc version, glibc vs musl, multiarch dir
layout, systemd vs openrc) sit BELOW this layer in the build
pipeline. M6 already proves the home apply pipeline materializes
uniformly across all five non-NixOS distros (5/5 op count, no-op
drift); re-running M9 on arch/ubuntu/fedora/alpine would re-prove
the M6 gate without adding signal. The script refuses to run on
non-debian distros with a clear error message.

### Two env-var notes

- **`REPRO_STORE_ROOT`, not `REPRO_HOME_STORE_ROOT`.** The home
  apply pipeline reads `REPRO_STORE_ROOT` (the canonical M56
  store-root env var, surfaced by
  `libs/repro_local_store/src/repro_local_store/store.nim` as
  `StoreRootEnvVar`). `REPRO_HOME_STORE_ROOT` (which M6's test
  driver sets) is unused — verified via grep + a side-by-side
  store-root comparison run. M9 deliberately uses the right env
  var so the gc step asserts against the same store the apply
  pipeline wrote to. The M6 pin is benign for the M6 gate (M6
  never reads the store) but would silently leak realization into
  the user's real `~/.cache/repro/store` if M6 ever started
  asserting on store contents. Flagging for a future M6 cleanup.

- **Package-free profile + `no orphaned prefixes` assertion.** The
  M9 fixtures declare a single `fs.userFile` resource with no
  package realization. The M10 home-gc engine reclaims orphaned
  content-addressed prefixes (i.e. realized packages); the
  `fs.userFile` primitive is rolled back/forward via the
  in-process file manager, not via store prefixes. So
  `repro home gc --keep-generations 1` deterministically reports
  `no orphaned prefixes — store is clean` on this profile shape.
  Asserting that exact outcome IS the M9 gate for a package-free
  profile — it confirms the engine runs against the right
  state-dir + store-root + that it correctly computes the empty
  live-prefix set across the kept generations. Package-realization
  gc IS exercised by the Nim e2e suite (`t_home_gc.nim`,
  `t_integration_local_store_gc.nim`,
  `t_e2e_repro_home_rollback_round_trip.nim`); that surface uses
  `REPRO_TEST_PACKAGE_SOURCE` to install fake packages without a
  real adapter, which is a test-only seam that does not belong in
  a cross-distro shell-test gate.

### Running M9 acceptance

```bash
bash scripts/run_multi_distro_tests.sh m9_rollback debian       # 1/1 expected
```

Sample green run:

```
==== debian (repro-debian) : m9_rollback ====
  store-root:   /tmp/reprobuild-bootstrap-debian/m9-rollback/store
  ID_A:         bb590b4edb91eee1056e53f55b4b39a2
  ID_B:         fc958f2d0bb3143a012e365f3415ba70
  transitions:  apply A -> apply B -> rollback to A (live file restored)
  gc:           home gc clean; store gc clean; active root preserved
[PASS] debian: m9_rollback (rc=0)

repro multi-distro: 1/1 distros passed
```

## Sandbox-MVP (Linux-Third-Party-Sandbox-MVP M0)

A second campaign reuses this harness for the Tier-3 FHS-view wrapper.
See
[`Linux-Third-Party-Sandbox-MVP.milestones.org`](../../../reprobuild-specs/Linux-Third-Party-Sandbox-MVP.milestones.org)
for the full spec. The M0 deliverable is two probes, both POSIX-sh,
sitting alongside the Recipe-Validation tests:

| Test                          | Purpose                                                                  |
| ----------------------------- | ------------------------------------------------------------------------ |
| `sandbox_check_bubblewrap`    | Read-only: probe `bwrap` presence + version + unprivileged user-ns state. |
| `sandbox_transparency_probe`  | Install `bwrap` on demand, then verify a no-isolation bwrap invocation behaves identically to a native exec (echo determinism, host /etc visibility, host PID visibility, identity-mapped UID). |

Running:

```bash
bash scripts/run_multi_distro_tests.sh sandbox_check_bubblewrap --all
bash scripts/run_multi_distro_tests.sh sandbox_transparency_probe --all
```

The probes use the same per-distro provisioned `repro-<distro>` WSL
instances; nothing else is required.

### M0 results (2026-06-11)

| Distro             | bwrap version (post-install) | unprivileged user-ns | transparency 4/4 |
| ------------------ | ---------------------------- | -------------------- | ---------------- |
| arch               | bubblewrap 0.11.2            | enabled              | PASS             |
| debian             | bubblewrap 0.8.0             | enabled              | PASS             |
| ubuntu             | bubblewrap 0.6.1             | enabled              | PASS             |
| fedora             | bubblewrap 0.11.0            | enabled              | PASS             |
| opensuse-tumbleweed| bubblewrap 0.11.2            | enabled              | PASS             |
| alpine             | bubblewrap 0.11.2            | enabled              | PASS             |

All six distros: `unshare --user true` exits 0, confirming
unprivileged-user-namespace creation works out of the box on the WSL
kernel for every provisioned instance. No `sysctl
kernel.unprivileged_userns_clone=1` admin step is needed on any of them.

The transparency probe's bwrap shape is the M0-spec minimum-policy
invocation:

```sh
bwrap --dev-bind / / --proc /proc -- <argv...>
```

with NO `--unshare-pid`, NO `--unshare-net`, NO `--unshare-ipc`, NO
`--unshare-uts`, NO `--unshare-cgroup`, NO `--cap-drop`, NO
`--seccomp`. The four assertions inside the probe:

1. `bwrap ... -- echo 'hello from bwrap'` -> exact match, rc=0.
2. `bwrap ... -- ls /etc` lists at least one entry (host etc visible).
3. `bwrap ... -- ps aux | wc -l` >= 5 lines (host PID table visible).
4. `bwrap ... -- id -u` == host `id -u` (UID identity-mapped).

### Notes for M1 (driver scaffold)

- bwrap is shipped by every target distro's package manager; the M1
  driver can install it via the same closed-set switch the probes use.
- ubuntu jammy's `bwrap 0.6.1` is the oldest version we have to
  support. It DOES support `--dev-bind` and `--proc`; M1 should
  validate any newer bwrap flags it wants against this version.
- No distro in this campaign needs the user-ns sysctl drop-in. If a
  future distro DOES, `sandbox_check_bubblewrap` will FAIL with a
  clear remediation line.

### Sandbox-MVP M5 — Closure dedup + cold/warm profile

`tools/sandbox-harness/m5_dedup_profile.sh` is the Sandbox-MVP M5
deliverable: a POSIX-sh measurement runner that profiles the M2 / M3 /
M4 orchestrators' cold + warm + cross-package realize timings on the
applicable per-distro fetcher, asserts per-fetcher dedup, and documents
the cross-fetcher namespace divergence + the peer-cache cross-campaign
blocker. Honest scope: M5 is largely measurement + documentation, NOT
new orchestration code. The dedup behaviour itself is already-working
by virtue of the M2/M3/M4 content-addressed prefix layout
(`sha256-<upstream-bytes-sha>-<pkg>/data/`) — the existing M2/M3/M4
integration tests' warm-run gates already assert "cache hit" lines.

Running:

```bash
# Inside any of repro-debian / repro-ubuntu / repro-fedora / repro-arch.
bash tools/sandbox-harness/m5_dedup_profile.sh
```

The script detects distro via `/etc/os-release` and dispatches to the
matching fetcher block (`debian|ubuntu` -> apt; `fedora` -> dnf;
`arch` -> pacman). Each block:

1. **Cold realize root #1** (`--no-exec` — isolates the realize pipeline
   from the bwrap launch round-trip). Wall time captured via
   `/usr/bin/time -p`.
2. **Warm realize root #1** (same `$REPRO_STORE_ROOT`). Wall time +
   "cache hit" count + `cold/warm` speedup ratio. Asserts:
   - cache-hit line count >= per-fetcher floor (3 for apt, 3 for dnf,
     5 for pacman; covers per-prefix + composed-tree + index hits).
   - `cold/warm` speedup >= 10x (the M5 spec verification clause).
3. **Cross-package realize of root #2**. Root #2's first-level
   dependencies overlap root #1's closure on the shared libc dependency:

   | fetcher | root #1 | root #2    | shared dep         |
   | ------- | ------- | ---------- | ------------------ |
   | apt     | hello   | sed        | libc6              |
   | dnf     | hello   | which      | glibc              |
   | pacman  | bash    | coreutils  | glibc              |

   Asserts the shared lib's prefix is a cache hit (cross-package dedup).
4. **Summary block** with per-fetcher CSV table + the dedup verdict
   (per-fetcher: verified; cross-fetcher: not possible by design;
   peer-cache: blocked).

**Per-fetcher dedup verdict (verified):**

- Per-fetcher dedup works as designed. The orchestrators' "if data
  dir already exists" cache-hit branches (apt_mvp.sh L391, dnf_mvp.sh
  L586, pacman_mvp.sh L563) short-circuit the second realize of the
  same upstream sha256.
- The composed FHS tree is ALSO cached by closure digest, and the
  per-fetcher index file (`Packages.gz` / `primary.xml.gz` / `desc`
  dir) is cached by its own upstream sha256.

**Cross-fetcher dedup verdict (not possible by design):**

apt's `libc6_2.36-9+deb12u13_amd64.deb`, dnf's
`glibc-2.38-7.fc39.x86_64.rpm`, and pacman's
`glibc-2.40+r16+gaa533d58ff-2-x86_64.pkg.tar.zst` have THREE different
upstream sha256 values — they are three different binary container
formats over conceptually the same upstream glibc but with different
vendor patches, build flags, and binary layouts. The store is
content-addressed by upstream BYTES, so the three realize into three
distinct `sha256-<...>-libc6` / `sha256-<...>-glibc` prefixes. This is
correct behaviour and matches Nix (a glibc derivation built via apt is
a different store path from one built via dnf even when both are
"logically glibc 2.36"). Cross-distro shared store paths are the
[`Linux-Distro-Recipe-Validation.milestones.org`](../../../reprobuild-specs/Linux-Distro-Recipe-Validation.milestones.org)
M5 problem space and require either Realize-Closure-style toolchain
pinning or per-toolchain-tier keying — both out-of-scope for the
Tier 3 sandbox consumption story.

**Peer-cache integration verdict (blocked):**

Same blocker as Linux-Distro-Recipe-Validation M5:
`apps/repro/repro.nim` -> `runBuildCommand` in
`libs/repro_cli_support/src/repro_cli_support.nim` does not yet consult
`PeerCacheActionCacheReader`
(`libs/repro_peer_cache/src/repro_peer_cache/engine_seam.nim`). The
peer-cache daemon + the reader work in isolation (60+ unit tests pass),
but no consumer in `repro_build_engine`, `repro_local_store`,
`repro_cli_support`, or any worker path instantiates it. Until a
"wire `PeerCacheActionCacheReader` into `runBuildCommand`" task lands
in the Peer-Cache campaign, neither Recipe-Validation nor Sandbox-MVP
can demonstrate cross-host pull of a realized prefix at the harness
surface.

The Sandbox-MVP M5 spec section mirrors Recipe-Validation M5a:
document the gap, mark M5 `in_review` for the measurement +
documentation deliverable, proceed to M6 (steam-run use-case
validation) which doesn't depend on cross-host cache.

### Cold/warm timing envelopes

The script reports VERBATIM what it measures; numbers below are the
per-orchestrator header comments' honest scope estimates, NOT pinned
fixtures. The script's PASS / FAIL lines surface whatever the actual
host measures.

| Fetcher | Cold (est.) | Warm (est.) | Speedup (est.) | Source                          |
| ------- | ----------- | ----------- | -------------- | ------------------------------- |
| apt     | 10-30 s     | <2 s        | >=10x          | apt_mvp.sh header               |
| dnf     | 30-90 s     | <5 s        | >=10x          | dnf_mvp.sh header               |
| pacman  | 30-90 s     | <5 s        | >=10x          | pacman_mvp.sh header            |

## Cross-campaign blocked milestones

- M5 peer-cache push/pull arm: cross-distro binary-cache push/pull
  (blocked on Peer-Cache campaign wiring
  `PeerCacheActionCacheReader` into `runBuildCommand`). The
  per-fetcher dedup + cold/warm profile arms ARE delivered; only the
  cross-host pull demo is blocked.
- M8: multi-output package realize (blocked on a cross-campaign
  Reprobuild-Development milestone — DSL, build graph, and
  content-addressed store do not yet partition a package's
  outputs into independently-realized prefixes; see the
  `Linux-Distro-Recipe-Validation.milestones.org` M8 "Blocker
  Investigation" + "Cross-Campaign Dependency" sections for the
  layer-by-layer gap analysis).
