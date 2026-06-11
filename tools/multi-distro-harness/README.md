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

## Future work (M4+)

- M4: same for Alpine (musl baseline).
- M5: cross-distro binary-cache push/pull.
