# tcc-chain — ReproOS-MVP R4: hex0 → tcc actual binaries

> Real-build companion to the M2-sim attestation chain in
> `D:/metacraft/reprobuild-specs/recipes/bootstrap/tcc-chain/`. Where
> M2-sim vendored binaries from Stagex's OCI image, R4 produces them
> **locally** by running the upstream chain end-to-end in the
> repro-debian WSL distro.

## Layout

```
recipes/bootstrap/tcc-chain/
  vendor/
    hex0-seed.AMD64.bin             — 229-byte trust-anchor binary (committed)
    minimal-bootstrap-sources.tar.gz — stage0-posix Release_1.9.1 + submodules (gitignored)
    MANIFEST.md                      — provenance, pins, sha256s
    SHA256SUMS                       — sha256 pins of both vendor files
    fetch.ps1                        — re-materialise the tarball from upstream
  scripts/
    build-hex0.sh                    — Phase 2: seed → hex0 (~1 s)
    build-stage0-posix.sh            — Phase 3: hex0 → kaem-unwrapped (~25 min)
    [mescc-tools / mes / tcc scripts — phase 4-6, not yet authored]
  recipes/
    hex0/repro.nim                   — typed reprobuild package for Phase 2
    stage0-posix/repro.nim           — typed reprobuild package for Phase 3
    [mescc-tools / mes / tcc recipes — phase 4-6, not yet authored]
  build/                             — output dir (gitignored)
    hex0/hex0                        — 229-byte ELF (Phase 2 output)
    stage0-posix/                    — 12 binaries (Phase 3 output)
      hex0, hex1, hex2-0, catm, M0, cc_arch, M2,
      blood-elf-0, M1-0, hex2-1, M1, hex2, kaem-unwrapped
      SHA256SUMS                     — per-binary sha256 (1 file per line)
```

## Chain shape

Per `nixpkgs/pkgs/os-specific/linux/minimal-bootstrap/` at commit
`06a4933d0` (R3-mined reference):

```
hex0-seed (229 bytes, vendored from oriansj/bootstrap-seeds)
   ↓ assembles hex0_AMD64.hex0 source
hex0 (229 bytes; byte-identical to the seed by self-hosting)
   ↓
[stage0-posix mescc-tools-boot chain, 11 phases]
   ↓ produces hex1, hex2-0, catm, M0, cc_arch, M2,
   ↓          blood-elf-0, M1-0, hex2-1, M1, hex2, kaem-unwrapped
[mescc-tools / mescc-tools-extra]
   ↓
mes 0.27.1 (Maxwell Equations of Software — Scheme + minimal C compiler)
   ↓ M2-Mesoplanet → mes-m2 → mes
mes-libc (compiled with mes)
   ↓
tinycc-bootstrappable (uses mes + mes-libc)
   ↓
tcc (working C compiler — the goal)
```

## How to build (the parts that are landed)

```powershell
. D:/metacraft/env.ps1

# Phase 1: vendor sources (one-time; downloaded blob is gitignored)
pwsh recipes/bootstrap/tcc-chain/vendor/fetch.ps1

# Phase 2 (~1 s): hex0
wsl -d repro-debian -- bash -lc `
  '/mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/scripts/build-hex0.sh `
    /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/vendor `
    /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/build/hex0'

# Phase 3 (~25 min): stage0-posix chain
# NB: hex0 must be present at build/stage0-posix/hex0 before invoking.
$STAGE0=`
  '/mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/build/stage0-posix'
wsl -d repro-debian -- bash -lc "mkdir -p $STAGE0 && cp /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/build/hex0/hex0 $STAGE0/hex0 && /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/scripts/build-stage0-posix.sh /mnt/d/metacraft/reprobuild/recipes/bootstrap/tcc-chain/vendor $STAGE0"
```

## Typed-engine entry points (Phase 2-3 landed)

```
recipes/bootstrap/tcc-chain/recipes/hex0/repro.nim         — package tccChainHex0
recipes/bootstrap/tcc-chain/recipes/stage0-posix/repro.nim — package tccChainStage0Posix
```

Each is a single `shell(...)` action that wraps the corresponding
`scripts/build-*.sh` driver. The engine fingerprints `extraInputs` (seed
+ source tarball + script) and caches `extraOutputs` (the produced
binaries + per-binary SHA256SUMS). Re-running the engine on the same
inputs should be a cache hit (no rebuild).

## Verification: per-binary sha256 (from a 2026-06-12 build run)

Phase 2:
```
hex0                  229  66c95985e668f20f2465c2b876f83fef066fd7c8c2dd3adb51a969f2d7120c8b
```

Phase 3: see `build/stage0-posix/SHA256SUMS` after a successful build.
The hex0 sha256 byte-matches the input seed sha256 (bootstrap-seeds
self-hosting property); the other 12 binaries are produced by hex0 +
its descendants.

**Cross-check vs nixpkgs**: nixpkgs's hex0.nix pins
`outputHash = sha256-DCzZduYrix9yOeJoem/Jhz/WDzAss7UWwjZbkXJq6Ms=`
which is a NAR hash (hex
`0c2cd976e62b8b1f7239e2687a6fc9873fd60f302cb3b516c2365b91726ae8cb`),
NOT a file sha256. Same bytes, different hashing.

## Status (R4 LANDED, R5 session 1 PARTIAL)

### R4 status (hex0 -> tcc), 2026-06-12

| Phase | Status                  | Wall-clock | Bytes-stable? |
|-------|-------------------------|------------|---------------|
| 1     | COMPLETE (vendor scaffolding + hex0-seed committed; mes + nyacc tarballs vendored) | ~1 min | n/a |
| 2     | COMPLETE (hex0 builds, sha byte-matches input seed)            | ~1 s | yes (re-run verified) |
| 3     | COMPLETE (12 stage0-posix binaries built end-to-end)           | 43 min cold | unverified (no re-run; deterministic by construction) |
| 4     | COMPLETE (11 mescc-tools binaries; reproducibility fix landed for M2-Mesoplanet path-embed)   | 5 s | yes (re-run verified) |
| 5     | COMPLETE (mes + mes-libc + libc-mini.a + libmescc.a + libc+tcc.a + crt1.o) | ~30 min | unverified |
| 6     | COMPLETE (tinycc-bootstrappable: tcc 0.9.28-unstable-2024-07-07; janneke fork ea3900f6d) | ~30 min | unverified |

R4 acceptance gate (`tcc -o hello hello.c; ./hello -> 42`) PASSES.

### R5 status (tcc -> gcc 15.2.0), 2026-06-12 session 1

| Phase | Status                                                                    | Wall-clock        |
|-------|---------------------------------------------------------------------------|-------------------|
| 1     | COMPLETE (R5 vendoring: 15 sources fetched + sha256 cross-checked vs nixpkgs) | ~5 min   |
| 2     | COMPLETE (tcc-shim: stable include + lib paths for R4 tcc)                | <1 min            |
| 3a    | NOT REACHED (tinycc-mes: latest tinycc cb41cbfe7 + CONFIG_TCC_PREDEFS=1)  | est. ~10 min      |
| 3b    | BLOCKED (musl-tcc: tcc cannot parse `[static N]` array params in syscall.h:417; wall hit after crt*.o built) | est. ~30 min      |
| 4     | NOT REACHED (tinycc-musl-intermediate)                                    | est. ~10 min      |
| 5     | NOT REACHED (binutils 2.46.0)                                             | est. ~45 min      |
| 6a    | NOT REACHED (gcc 4.6.4 C-only, tcc-built)                                 | est. 60-90 min    |
| 6b    | NOT REACHED (gcc 4.6.4 cxx, musl-rebuilt)                                 | est. 30-45 min    |
| 7     | NOT REACHED (gcc 10.4.0)                                                  | est. 2-3 hours    |
| 8     | NOT REACHED (gcc 15.2.0 -- the R5 goal)                                   | est. 3-4 hours    |
| 9     | NOT REACHED (DDC self-rebuild gate)                                       | est. 3-4 hours    |

### R5 wall (session 1)

R4's tcc (`tinycc-bootstrappable`, janneke fork ea3900f6d 2024-07-07)
cannot directly compile musl 1.2.6.  Two falsified workarounds during
session 1:

1. **`__builtin_va_list` not recognised as a type** -- musl's
   `include/alltypes.h.in` uses `typedef __builtin_va_list va_list`.
   Sed-replace with `void *` allows crt/Scrt1.o + crt/{crt1,rcrt1}.o +
   crti.o + crtn.o to build.
2. **`[static N]` array parameter not recognised** -- musl's
   `src/internal/syscall.h:417` uses
   `void __procfdname(char __buf[static 15+3*sizeof(int)], unsigned)`.
   No simple sed workaround.

Root cause per nixpkgs `tinycc/mes.nix`: the chain uses an
INTERMEDIATE tinycc (`tinycc-mes`, source cb41cbfe7 2025-12-03) with
`CONFIG_TCC_PREDEFS=1` + a generated `tccdefs_.h` header -- this is
what gives the chain's tcc modern C feature support.  R4 stopped at
`tinycc-bootstrappable` (one step earlier in the chain than nixpkgs's
`tinycc-mes`).

### R5 next-session scope

1. Author `scripts/build-tinycc-mes.sh`: vendor the cb41cbfe7 tinycc
   source, apply the 3 nixpkgs patches (static-link, i386-asm reg-aware,
   ptrdiff_t cast), generate `tccdefs_.h` via R4 tcc, two-pass build
   (boot + main).  Output: `build/tinycc-mes/{bin/tcc, lib/libtcc1.a,
   tccdefs/tccdefs_.h}`.
2. Re-run `scripts/build-musl-tcc.sh` with the new `tinycc-mes` tcc
   replacing the shim.  Expected to succeed because nixpkgs's identical
   musl 1.2.6 + sigsetjmp patch chain works under tinycc-mes.
3. Then proceed phase-by-phase: tinycc-musl-intermediate -> musl-tcc
   -> tinycc-musl -> binutils -> gcc 4.6.4 (Stage A) -> gcc 4.6.4
   (Stage B/cxx) -> gcc 10.4.0 -> gcc 15.2.0.  Each step has a
   self-contained recipe stub at `recipes/<step>/repro.nim` with build
   shape + expected wall-clock + external inputs documented.

### R5 deliverables (session 1)

- `vendor/fetch-r5.ps1` -- downloads 15 R5 source pins from upstream
  and sha256-verifies against `vendor/SHA256SUMS-r5.txt`.
- `vendor/SHA256SUMS-r5.txt` -- all 15 hashes byte-equal to the
  nixpkgs pins (10 SRI base64 hashes + 5 nix-base32 file hashes;
  decoded in PowerShell and cross-checked).
- `vendor/MANIFEST.md` -- per-file provenance, upstream URLs, sizes,
  license, nixpkgs ref.
- `scripts/build-tcc-shim.sh` -- R5 Phase 2 driver.  4 smoke tests all
  pass: ret-only + stdio.h-hello both via wrapper AND via baked-path
  symlink rehydration.
- `scripts/build-musl-tcc.sh` -- R5 Phase 3 driver; partial (crt*.o
  built, src/aio/aio.o blocked on syscall.h:417).
- `recipes/{tcc-shim,tinycc-mes,musl-tcc,binutils,gcc-4.6.4,
  gcc-10.4.0,gcc-15.2.0}/repro.nim` -- typed reprobuild packages for
  R5 Phase 2-8.  tcc-shim is LANDED (live).  The others are
  BLOCKED-stubs with `exit 78` placeholders + detailed build-shape
  documentation in the Nim comments.
- `recipes/{binutils,gcc-4.6.4}/patches/*.patch` -- 3 small patches
  vendored in-tree from nixpkgs (committable; total ~700 bytes).

### Phase 3 + 4 verified sha256 (canonical, x86_64-linux Debian 12 host)

stage0-posix chain (Phase 3):
```
hex0                      229  66c95985e668f20f2465c2b876f83fef066fd7c8c2dd3adb51a969f2d7120c8b
hex1                      622  c264a212d2b0e1f1bcf34217ed7876bb9324bd7e29cd902bb1cad4d9f45f1cf8
hex2-0                   1519  6c69c7e60df220e884de4fc3bdf7137352b7b3c25a1fb7000ef7f7dea82b33bc
catm                      299  911d19bff7be2bc4657b312b19c29ad98cbaad2fed141a016fa0104e07e83ce7
M0                       1684  db97dff12dbbc1f547b5fb58fe70267ac9a99d43d5879d8bbf578f31f1ec2bd1
cc_arch                 17309  b817c888e89685d1ef8984e07a72c0e44dc4f994a3a1db9a01888de6d0e530c3
M2                     194298  b286863129e546d6e702db6d8f08281e8889f43dedb184a168bae96812b8b429
blood-elf-0             23184  3e1e6ac7e2e692c48ef7c763071307bd2c232f150bf1854de3579f713cfecab4
M1-0                    54959  9aed018c6585e68deef59ce2beaf470d16d845161eb6a436f152ebc65e140694
hex2-1                 100049  f782df6d59f7ff930e67f34dde7ea62288b12d6d1a0b036ef465ad06b4a4b97a
M1                     101228  fc68c115384852b827a35b607de382592a475c324e1e11ca7cf5b9e840ce15a9
hex2                   100049  f782df6d59f7ff930e67f34dde7ea62288b12d6d1a0b036ef465ad06b4a4b97a
kaem-unwrapped         114375  6364de59b36f8575fd938779476a9a121878fc0e2d65cc01ae5372aad2d028b5
```
NB: `hex2-1` and `hex2` are byte-identical (`f782df6d59f...`). Phase 10
rebuilds hex2 from C sources via M1+blood-elf-0+M2; the bit-equality
with the Phase 8 hex2-1 is a self-consistency check that the chain is
deterministic.

mescc-tools (Phase 4):
```
M1                     101228  fc68c115384852b827a35b607de382592a475c324e1e11ca7cf5b9e840ce15a9
M2                     194298  b286863129e546d6e702db6d8f08281e8889f43dedb184a168bae96812b8b429
hex2                   100049  f782df6d59f7ff930e67f34dde7ea62288b12d6d1a0b036ef465ad06b4a4b97a
mkdir                   61309  27636130eb38d95c86aa8b3cdacac4aa103fe1d05dafeddcde4f03d759fa0c94
cp                      70003  ce856c0f2688d372331cd2dfcc33dd077e9bacccfbba261081dfdc34e51a0313
chmod                   61587  58f7fc212dc51bf1bd6668e7dfe0cacf13b86024d9e629fa6009f0b8c7668f69
replace                 65367  edd20e5d588902572bc0798f90f9cea7cf69fdfaac5269c8a578bdec141e6df2
M2-Mesoplanet          185240  a151c0228fa5a7bc22565f861f2a636930962c0ca4aba918b10cc2e80d111f0b
blood-elf               76419  6d1c534225ac7a3e74e29cb17579f5dd720547c19e7eea6bfe742326fb4a0bc7
get_machine             57101  379cb35a87bd7a9c190d79d3141af897869aae5e4cb0ac9e03235c78b84e1be7
M2-Planet              458747  7cf19de29a4ae63637898f6093d0526b73108040ab3634f11232030439602fc1
```
M1 + M2 + hex2 are byte-identical to the stage0-posix ones (they're
content-copied via `cp`, not rebuilt). M2-Mesoplanet pins paths to
`/repro/m2libc` + `/repro/bin:` for reproducibility (nixpkgs gets this
for free via content-addressable nix store paths; we have to pin
manually — see `scripts/build-mescc-tools.sh` for the fix).

### Known reproducibility hazard caught + fixed

The initial M2-Mesoplanet build embedded the absolute `$OUT_ABS` path
into the binary via the `cc_spawn.c` PATH replace patch. Two builds
into different output dirs produced 53-byte-different binaries. Fix:
pin paths to `/repro/m2libc` + `/repro/bin:` and document that users
must symlink those locations or pass `--m2libc-path` to M2-Mesoplanet
at runtime. After fix, two consecutive builds emit bit-identical
SHA256SUMS (verified).

## R6 status (gcc -> glibc), 2026-06-13

| Phase | Status                                                                         | Wall-clock        | Bytes-stable? |
|-------|--------------------------------------------------------------------------------|-------------------|---------------|
| 1     | COMPLETE (linux 6.18.7 headers via `make headers_install ARCH=x86_64`)         | ~30 s             | yes (sanitised .h tree, byte-stable under SDE) |
| 2     | COMPLETE (glibc 2.42 vanilla, via R5 gcc 15.2.0 + binutils 2.46.0)             | ~5 min on 32-core | unverified (no re-run; SDE-pinned)             |
| 3     | COMPLETE (smoke-test PASS: hello-world prints + exits 42)                      | <1 s              | n/a                                            |
| 4     | NOT REACHED (rebuild gcc 15.2 with glibc as system libc — deferred to R7)      | n/a               | n/a                                            |

R6 acceptance gate (`gcc 15.2 + glibc -> hello-world links and runs`) PASSES.

### R6 deliverables (session 1)

- `vendor/fetch-r6.ps1` — downloads 2 R6 source pins from upstream and
  sha256-verifies against `vendor/SHA256SUMS-r6.txt`.
- `vendor/SHA256SUMS-r6.txt` — both hashes byte-equal to nixpkgs SRI pins
  (decoded in PowerShell and cross-checked: linux 6.18.7 + glibc 2.42).
- `vendor/MANIFEST.md` — appended R6 section with per-file provenance,
  upstream URLs, sizes, license, nixpkgs ref, patch-skip rationale.
- `scripts/build-linux-headers.sh` — R6 Phase 1 driver. Plain
  `make headers_install ARCH=x86_64` with nixpkgs's cc-version stubs
  + HOST_LFS_CFLAGS. Output: 1028 .h files, 7.0 MiB.
- `scripts/build-glibc.sh` — R6 Phase 2 driver. Out-of-tree build via R5
  gcc 15.2.0 + binutils 2.46.0; `--with-headers=<R6 Phase 1>`,
  `--enable-kernel=3.10.0`, `--disable-multilib`, `--disable-profile`,
  `--disable-nscd`, `--without-gd`, `--without-selinux`. NB:
  `CXX=` (empty) override at `make` time bypasses a libstdc++/hidden-atexit
  conflict in glibc's `support/links-dso-program` test driver — see
  "Known reproducibility hazard caught + fixed" below.
- `scripts/_r6_glibc_shasums.sh` — helper, generates `$OUT/SHA256SUMS`
  with sizes + sha256 for the canonical 17 glibc outputs.
- `scripts/r6-smoke-test.sh` — Phase 3 driver. Builds hello.c, runs it,
  checks `stdout == "Hello from glibc!"` AND `exit code == 42` AND
  the binary's `Requesting program interpreter` is the R6 ld.so AND
  ldd shows libc.so.6 resolved against R6's libc.

### R6 verified sha256 (canonical, 2026-06-13 build run)

Linux headers (Phase 1):
```
include/asm/unistd.h            623  a83776c3b064c9d1f04ea0a8228e20eef166508c6c13cd75afbabd3237acc445
include/asm/unistd_64.h       10372  e491134abeb6c23ea140e967b7b52a27bb5d958c6889d7e7d2d2ce062c973617
include/linux/version.h         216  fddf0fe9c09b1e7fbe9306f2726bb2551003147a42377b24bb63b41984cb2f12
include/linux/types.h          1829  4152b3c5d095f5cf0adf5cc13ee0670e737eb7c4efef5fa08e9d1eb87e68ed78
include/asm-generic/unistd.h  31792  3e926f0eb23613d1293a8cae1db5a58dcdd575304e9ac75e5b492a8bf205c13f
```
Total: 1028 .h files, 7,120,325 bytes across 15 top-level dirs.

glibc 2.42 (Phase 2):
```
lib/libc.so.6               11880752  5b005ba93c1240431a5e69b221bcbf3f3aadddd51d2955226dae7777206dedad
lib/ld-linux-x86-64.so.2     1376816  8f2e3e0795c3c9c7c63d67be83e311bb2a89339ec59ae89e06e8a12dca29646e
lib/libm.so.6                4035272  a9074545934fa483346c27bb38146bca0d293c76786c985c423a6ade42a8e2a4
lib/libpthread.so.0            19856  d727c54f114bfa42e6f58ec28b3e9d91add424614484a0faf01a7e767a4d5b81
lib/librt.so.1                 24144  c057d741ad25bd205391607fd12bdad168dc87bfb33f5081535b4944134753aa
lib/libdl.so.2                 19080  79449fa34e133179b6ac4eda62c0f19b530a3bfeaed921faaeefd062c82f9673
lib/libresolv.so.2            263168  cdb713d9e63fb2381ef6e3c4e734cbdbab1a40d6d5857c29f31fa7c3ce3c24ac
lib/libutil.so.1               18800  94690790de6285813c3518d65c6995fd9d078a509daae40b1eaed611744b14f5
lib/libc_nonshared.a           16978  6643ae19ec75a261ea92bfc6c4e29d042105a7a30792e65ace15a8b5d4d71adb
lib/crt1.o                      8896  09fd86832ca66ba97c5b4b6d5852cebfa9476246fb2536b5b5ccf0efb47535a9
lib/crti.o                      3008  5545e0509b7b5d3c8f54f211d469a05db56eeef7cf5f2bc664e465da659b87aa
lib/crtn.o                      2752  77baaebc89a0b1cf1e555f763910d027b10f2c133978aa9a1cecbcaa987bfb84
bin/ldd                         5463  beea383917107db2fca823133900725d7a8390c4a1b33e34da3ff222e70fec9f
bin/getconf                    53400  842bccd91fa3cf06a5df87c65b5c5fc35b8d944a338dcfee7f5b20440f79e073
bin/getent                     96488  688b05ac84f55cec7f60b1487b4cbb906e9ce75cf751dd741b77716cd76473c8
bin/locale                    154592  98407737e80f2998c18a938e255e91c8f580440a34f6d8bab825849af0ce510a
```

NB: glibc's `libpthread.so.0` is a 19,856-byte stub since glibc 2.34
(pthread merged into libc.so.6). The stub still exists for SONAME
back-compat with binaries that have `NEEDED libpthread.so.0`.

### R6 known reproducibility hazard caught + fixed

`support/links-dso-program` (a glibc-internal test binary) links with
`-lstdc++`. R5's libstdc++ provides a *hidden* `atexit` symbol that
collides with `libc_nonshared.a(atexit.oS)`'s exported `atexit`, breaking
the link with `ld: hidden symbol 'atexit' ... is referenced by DSO`.

Fix: pass `CXX=` (empty) to `make`. glibc's `support/Makefile` falls back
to `links-dso-program-c` (C-only, links against `-lgcc` only) when
`$(CXX)` is empty, which assembles cleanly. The fix is in
`scripts/build-glibc.sh` at Stage 4 ("make -j N CXX=").

This same `links-dso-program` issue is mentioned in glibc's mailing
list archives as a known interaction with non-Debian/non-Fedora
toolchains. Our R5 g++ ships libstdc++.a built against musl, where
the visibility annotations differ from glibc's expectations.

### R6 embedded-path posture

`strings libc.so.6 | grep '^/tmp/'`:
```
/tmp/r6-build/glibc/lib/locale/locale-archive
/tmp/r6-build/glibc/share/locale
/tmp/r6-build/glibc/share/zoneinfo
/tmp/r6-build/glibc/lib/gconv/gconv-modules.cache
```

These are baked in by glibc via the `--prefix=$OUT` configure flag.
ReproOS will install glibc at `/repro/glibc` (or similar) at boot time;
the same configure flag pattern, just with a different prefix. For R6
acceptance the `/tmp/r6-build` prefix is the staging path; the smoke
test verifies the runtime works AT that prefix, which is the only thing
the R6 gate requires.

For R7+ we'll configure with `--prefix=/repro/glibc` and use the
junction-aware install pattern from M2-sim (mount or symlink
`/repro/glibc` at boot).

### R6 deferred to next phase

- Phase 4 (rebuild gcc 15.2.0 with glibc as system libc): not strictly
  needed for the R6 gate ("glibc builds and works"). R5's gcc still has
  `--with-sysroot=$MUSL_GCC46`, but binaries built with the R6
  smoke-test pattern (explicit `--dynamic-linker` + `-isystem $GLIBC/include`
  + `-nostdinc`) link cleanly against glibc. For R7 (userspace) we may
  need to either (a) accept the explicit-flag invocation pattern, (b)
  build a gcc 15.2 wrapper that injects the flags, or (c) rebuild gcc
  15.2 with `--with-sysroot=$GLIBC --with-native-system-header-dir=/include`.
  Option (b) is the standard "cc-wrapper" pattern used by nixpkgs and
  Gentoo's gcc-config; it's cheap and bit-for-bit reproducible.
- Apply the nixpkgs `2.42-master.patch` (254 KB of upstream stable-branch
  backports producing "glibc 2.42-61"). These are bug fixes, not behaviour
  changes; safe to skip for the R6 gate but should be considered before
  any production use.
- Build glibc-locales (separate package per nixpkgs's `locales.nix`).
  Our R6 install includes `bin/localedef` but no locale archive; programs
  needing locale data will get C/POSIX behaviour. Acceptable for R7 dev
  iteration; R8+ needs at least the C.UTF-8 locale.

## References

- Spec: `D:/metacraft/reprobuild-specs/ReproOS-MVP.milestones.org`
  ** R4, R5, R6 headings
- M2-sim chain (the simulation we're replacing): `D:/metacraft/reprobuild-specs/recipes/bootstrap/tcc-chain/chain.json`
- nixpkgs reference: `D:/metacraft/nixpkgs/pkgs/os-specific/linux/minimal-bootstrap/`
  + `pkgs/os-specific/linux/kernel-headers/default.nix`
  + `pkgs/development/libraries/glibc/{default.nix,common.nix}`
- Upstream source: `https://github.com/oriansj/stage0-posix` tag `Release_1.9.1`
- Bootstrap-seeds: `https://github.com/oriansj/bootstrap-seeds` commit
  `cedec6b8066d1db229b6c77d42d120a23c6980ed`
- linux 6.18.7: `https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.7.tar.xz`
- glibc 2.42: `https://ftp.gnu.org/gnu/glibc/glibc-2.42.tar.xz`
