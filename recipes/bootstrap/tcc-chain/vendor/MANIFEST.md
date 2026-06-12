# R4 Bootstrap Source Vendor — hex0 → tcc chain

This directory holds the vendored inputs for the ReproOS-MVP R4 milestone
(hex0 → tcc real-build chain). Architecture: **AMD64** (x86_64-linux).

Two artifacts:

1. **`hex0-seed.AMD64.bin`** — the 229-byte pre-compiled hex0 ELF binary
   from `oriansj/bootstrap-seeds`. This is the **only pre-compiled
   binary** in the bootstrap chain; every later step builds from this.
   Small enough to commit in-tree.

2. **`minimal-bootstrap-sources.tar.gz`** — a snapshot of the
   `oriansj/stage0-posix` repository at tag `Release_1.9.1` with all
   submodules recursively initialized (AMD64, x86, mescc-tools,
   M2-Planet, M2-Mesoplanet, M2libc, mescc-tools-extra,
   bootstrap-seeds). Gitignored (1.5 MB exceeds the project's
   <=10 MB committable rule — well below but kept consistent with the
   other vendor dirs); fetched on demand by `fetch.ps1`. Bit-stable
   under `SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC` because we
   strip `.git*` files and tar with `--sort=name`, fixed mtime, and
   numeric 0:0 ownership.

Every record below is `evidence_type: vendored-upstream-binary`
(for the hex0-seed) or `vendored-upstream-source` (for the tarball).

## hex0-seed.AMD64.bin

- **Source URL**:
  `https://raw.githubusercontent.com/oriansj/bootstrap-seeds/cedec6b8066d1db229b6c77d42d120a23c6980ed/POSIX/AMD64/hex0-seed`
- **Upstream repo**: `https://github.com/oriansj/bootstrap-seeds`
- **Upstream commit**: `cedec6b8066d1db229b6c77d42d120a23c6980ed`
- **Snapshot date**: 2026-06-12
- **Size**: 229 bytes
- **sha256 (file)**: `66c95985e668f20f2465c2b876f83fef066fd7c8c2dd3adb51a969f2d7120c8b`
- **NAR-hash (nixpkgs format `sha256-DCzZduYrix9yOeJoem/Jhz/WDzAss7UWwjZbkXJq6Ms=`,
  hex: `0c2cd976e62b8b1f7239e2687a6fc9873fd60f302cb3b516c2365b91726ae8cb`)**:
  matches `pkgs/os-specific/linux/minimal-bootstrap/stage0-posix/hex0.nix`
  AMD64 entry in nixpkgs commit `06a4933d0`.
- **ELF header verified**: x86_64 ELF (`e_machine = 0x3e`).
- **License**: GPL-3.0+ (same as stage0-posix, which the seed is the
  binary form of).
- **Provenance trust anchor**: the seed is committed to the
  bootstrap-seeds repo as the canonical "untrusted byte floor" for
  the bootstrappable-builds chain; Stagex, nixpkgs, live-bootstrap,
  and guix all pin the same bytes. Diverse Double Compilation through
  multiple independent rebuilders is the long-term mitigation.

**Note on spec discrepancy**: the R4 spec brief said "181 bytes" but
that was the i386 (x86) hex0-seed size. The AMD64 seed is 229 bytes;
nixpkgs's hex0.nix selects per-arch from the same upstream commit.

## minimal-bootstrap-sources.tar.gz

- **Upstream repo**: `https://github.com/oriansj/stage0-posix`
- **Upstream tag**: `Release_1.9.1`
- **Upstream commit**: `45d90f5955b6907dc6cdea9ebafce558359edcd3`
- **Snapshot date**: 2026-06-12
- **Size**: 1508930 bytes (~1.4 MiB)
- **sha256**: `91df538e63abd103a2f5ace56638eb20c07f577afd57e1fa398a638fd955589c`
- **Snapshot method**:
  ```
  git clone --depth 1 --branch Release_1.9.1 <repo>
  git submodule update --init --depth 1 --recursive
  rm -rf .git .gitmodules .gitignore (recursively)
  SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC \
    tar --sort=name --mtime="@1735689600" \
        --owner=0 --group=0 --numeric-owner -czf <out>.tar.gz stage0-posix
  ```
- **Submodule pins** (captured 2026-06-12, snapshot-checked):

  | path                        | commit                                   |
  |-----------------------------|------------------------------------------|
  | AArch64                     | 9015b9e048bd969ffc7884399a17952f21d7a039 |
  | AMD64                       | 82efa0d6be1c9bb993a7a62af1cccd8d2cda91f6 |
  | M2-Mesoplanet               | 4b011a85da73a7c97212468d41f17e806ba99547 |
  | M2-Mesoplanet/M2libc        | 68a23cfd05d5a355ba7a30c770d684cbe86fcc4e |
  | M2-Planet                   | bd2fe4b0659fd0ad3f476a5ad0ef801bd134665d |
  | M2-Planet/M2libc            | 68a23cfd05d5a355ba7a30c770d684cbe86fcc4e |
  | M2libc                      | 68a23cfd05d5a355ba7a30c770d684cbe86fcc4e |
  | armv7l                      | 4b1ff94cec0341375c788f73901f25fc1edc3ac3 |
  | bootstrap-seeds             | cedec6b8066d1db229b6c77d42d120a23c6980ed |
  | mescc-tools                 | 5adfbf3364261a77109878a56b100aeeb6ef9ac4 |
  | mescc-tools/M2libc          | 5a7c12a7be39cbce113c5459d77467b829a1ecc5 |
  | mescc-tools-extra           | a151c245e512076971a3c85bb1502cf92cfa83b6 |
  | mescc-tools-extra/M2libc    | 5a7c12a7be39cbce113c5459d77467b829a1ecc5 |
  | riscv32                     | 261c67274cbc396dc211b06c933335c09cc35138 |
  | riscv64                     | 4688bc66bdfd00efd5964350c9d76bdb90a0f72e |
  | x86                         | 3b9c2bb6d4155e4f2e5f642b5e0f59255dfc5934 |

  Note on `M2libc` triplication: stage0-posix vendors three copies
  of M2libc (one each under M2-Mesoplanet/, M2-Planet/, mescc-tools/,
  mescc-tools-extra/, plus the top-level). nixpkgs's
  `make-bootstrap-sources.nix` strips the four nested duplicates
  (`postFetch`). Our snapshot KEEPS all five — the build script
  selects the top-level `M2libc` (which matches nixpkgs's choice)
  and ignores the nested copies. This avoids a `postFetch`-shaped
  divergence from upstream.

- **Comparison with nixpkgs `bootstrap-sources.nix`**: nixpkgs ships a
  NAR-format archive with `outputHash =
  sha256-UNoyb2teqH26VM7YoOcazyqZ0AlDae045aWc31ZHFdw=` (hex:
  `50dba26ed2ab287daa554ced8a0e71acf2999d023679d2b8e5a59c37d56411dd`).
  That hash is over a NAR archive (a Nix-specific format) that
  ALSO strips `bootstrap-seeds/*` and the 4 nested M2libc copies.
  Our tar.gz hash will differ from the NAR hash by construction; the
  source content (top-level commits + submodule SHAs) is the same.

## mes-0.27.1.tar.gz

- **Upstream URL**: `mirror://gnu/mes/mes-0.27.1.tar.gz`
  (e.g. `https://ftpmirror.gnu.org/gnu/mes/mes-0.27.1.tar.gz`).
- **Snapshot date**: 2026-06-12.
- **Size**: 756876 bytes.
- **sha256**: `183a40ea47ea49f8a1e3bd1b9d12e676374d64d63bc79e7bc1ae7d673dfdf25d`.
- **NAR-format pin in nixpkgs**:
  `sha256-GDpA6kfqSfih470bnRLmdjdNZNY7x557wa59Zz398l0=` — byte-equal to
  the raw file sha256 above. Source:
  `pkgs/os-specific/linux/minimal-bootstrap/mes/default.nix`.
- **License**: GPL-3.0+.

## nyacc-1.09.1.tar.gz

- **Upstream URL**: `mirror://savannah/nyacc/nyacc-1.09.1.tar.gz`
  (e.g. `https://download.savannah.nongnu.org/releases/nyacc/nyacc-1.09.1.tar.gz`).
- **Snapshot date**: 2026-06-12.
- **Size**: 1282761 bytes.
- **sha256**: `0ec9ae537e0d951781a50de3c7929ac97a85c1d4b5e85e5d51542e3751022717`.
- **NAR-format pin in nixpkgs**:
  `sha256-DsmuU34NlReBpQ3jx5KayXqFwdS16F5dUVQuN1ECJxc=` — byte-equal to
  the raw file sha256 above. Source:
  `pkgs/os-specific/linux/minimal-bootstrap/mes/nyacc.nix`.
- **License**: LGPL-3.0+.
- **Note**: mes 0.27.1 is incompatible with nyacc >= 1.09.2 (block-comment
  parse bug); 1.09.1 is the explicit upstream pin.

## tinycc-bootstrappable.tar.gz

- **Upstream URL**:
  `https://gitlab.com/janneke/tinycc/-/archive/ea3900f6d5e71776c5cfabcabee317652e3a19ee/tinycc-ea3900f6d5e71776c5cfabcabee317652e3a19ee.tar.gz`.
- **Upstream commit**: `ea3900f6d5e71776c5cfabcabee317652e3a19ee`
  (janneke's bootstrappable fork; nixpkgs "unstable-2024-07-07").
- **Snapshot date**: 2026-06-12.
- **Size**: 772254 bytes.
- **sha256**: `d7a2411890130163fe94fca53a2dfe9688e976fd12479a6acb1395d8f895c740`.
- **NAR-format pin in nixpkgs**:
  `sha256-16JBGJATAWP+lPylOi3+lojpdv0SR5pqyxOV2PiVx0A=` — byte-equal to
  the raw file sha256 above. Source:
  `pkgs/os-specific/linux/minimal-bootstrap/tinycc/bootstrappable.nix`.
- **License**: LGPL-2.1-only.
- **Note**: this is the mes-compatible tinycc fork, not upstream tinycc.
  Required because upstream tinycc has portability issues that mes 0.27
  cannot compile.  Re-vendored to tarball form (not git clone) because
  the GitLab archive is deterministic per commit hash.

## Refresh

Run `pwsh fetch.ps1` to re-materialise `minimal-bootstrap-sources.tar.gz`
from upstream. The script clones the pinned tag + submodules in a WSL
distro and re-tars deterministically. The hex0-seed is committed and
needs no refresh. The mes + nyacc + tinycc-bootstrappable tarballs are
direct upstream downloads; refresh via:

```
pwsh -c 'iwr https://ftpmirror.gnu.org/gnu/mes/mes-0.27.1.tar.gz -OutFile mes-0.27.1.tar.gz'
pwsh -c 'iwr https://download.savannah.nongnu.org/releases/nyacc/nyacc-1.09.1.tar.gz -OutFile nyacc-1.09.1.tar.gz'
pwsh -c 'iwr https://gitlab.com/janneke/tinycc/-/archive/ea3900f6d5e71776c5cfabcabee317652e3a19ee/tinycc-ea3900f6d5e71776c5cfabcabee317652e3a19ee.tar.gz -OutFile tinycc-bootstrappable.tar.gz'
```

# R5 (tcc -> gcc bootstrap loop) vendored sources

Pulled by `vendor/fetch-r5.ps1`.  Each file is sha256-verified against
`SHA256SUMS-r5.txt` after download.  Every pin in this section was
cross-checked against the corresponding nixpkgs derivation under
`pkgs/os-specific/linux/minimal-bootstrap/` at commit `06a4933d0` and
matches byte-for-byte (10 SRI hashes + 5 nix-base32 hashes verified
2026-06-12).

## binutils-2.46.0.tar.xz

- **Upstream URL**: `mirror://gnu/binutils/binutils-2.46.0.tar.xz`.
- **Size**: 28548776 bytes (~27.2 MiB).
- **sha256**: `d75a94f4d73e7a4086f7513e67e439e8fcdcbb726ffe63f4661744e6256b2cf2`.
- **nixpkgs ref**: `binutils/default.nix` (mesboot variant, NOT static).
- **Patches needed** (vendored under `recipes/binutils/patches/`):
  - `deterministic.patch` -- sets `BFD_DETERMINISTIC_OUTPUT` so `ld`
    archives are stable.
  - `fix-tinycc-attribute.patch` -- include/ansidecl.h: skip the
    `__attribute__(x)` no-op define when `__TINYC__` is defined (tcc
    DOES support `__attribute__((aligned(N)))`-style attributes used by
    mmap argv handling in `binutils/bfd/mmap.c`).
- **License**: GPL-3.0+.

## musl-1.2.6.tar.gz + musl-sigsetjmp.patch

- **Upstream URL**: `https://musl.libc.org/releases/musl-1.2.6.tar.gz`.
- **Size**: 1082499 bytes (~1.0 MiB).
- **musl sha256**: `d585fd3b613c66151fc3249e8ed44f77020cb5e6c1e635a616d3f9f82460512a`.
- **musl-sigsetjmp.patch URL**:
  `https://github.com/fosslinux/live-bootstrap/raw/d98f97e21413efc32c770d0356f1feda66025686/sysa/musl-1.1.24/patches/sigsetjmp.patch`.
- **patch sha256**: `c1dd807afd733c95f2deaf77dda8aea79a7520c2b354906ab80ca5de06cae0f5`.
- **nixpkgs ref**: `musl/tcc.nix` (intermediate musl built with tcc).
- **License**: musl is MIT; live-bootstrap patches are CC0.
- **Note**: musl is the libc the chain uses from gcc 4.6.4 onward.
  nixpkgs builds a 2-stage musl: `musl-tcc-intermediate` (with the
  intermediate tcc) -> `musl-tcc` (with `tinycc-musl-intermediate`).
  Both are the same 1.2.6 sources; the staging is about WHICH tcc
  compiles them.

## gcc-core-4.6.4.tar.gz + gcc-g++-4.6.4.tar.gz

- **Upstream URLs**:
  - `mirror://gnu/gcc/gcc-4.6.4/gcc-core-4.6.4.tar.gz`
  - `mirror://gnu/gcc/gcc-4.6.4/gcc-g++-4.6.4.tar.gz`
- **Sizes**: 38438255 bytes + 9178198 bytes (~36.7 MiB + ~8.8 MiB).
- **sha256s**:
  - core: `e534a5cb05ab839d7cf7b2496fd5df42e76352926c1cf0d94de76184c26a739c`
  - g++:  `690a5d4f664180640db28079e3461468192c484c37d6f671dde4b53a7f9918bb`
- **nixpkgs ref**: `gcc/4.6.nix` (C-only, tcc-built) + `gcc/4.6.cxx.nix`
  (C++-also, musl-built; needs musl from the prior step).
- **Patches needed**:
  - `no-system-headers.patch` -- comment out the hardcoded
    `NATIVE_SYSTEM_HEADER_DIR = /usr/include` in `gcc/Makefile.in`.
- **License**: GPL-3.0+.
- **Note**: gcc 4.6.4 is the LAST gcc that can self-build with tcc-mes
  syntax; later gccs require a working C99/C11 compiler that tcc-mes
  doesn't quite provide.

## gmp/mpfr/mpc for gcc 4.6.4 (gmp-4.3.2 / mpfr-2.4.2 / mpc-1.0.3)

- **sha256s**:
  - gmp 4.3.2:  `7be3ad1641b99b17f6a8be6a976f1f954e997c41e919ad7e0c418fe848c13c97`
  - mpfr 2.4.2: `246d7e184048b1fc48d3696dd302c9774e24e921204221540745e5464022b637`
  - mpc 1.0.3:  `617decc6ea09889fb08ede330917a00b16809b8db88c29c31bfbb49cbf88ecc3`
- **nixpkgs ref**: in-tree of `gcc/4.6.nix`.
- **Note**: these are linked into `gcc-4.6.4/{gmp,mpfr,mpc}` so gcc's
  build system bootstraps them statically (`./configure
  --disable-shared` etc).  Hardcoded combinations -- not interchangeable
  with the gcc 10 / 15 versions.

## gcc-10.4.0.tar.xz + deps (gmp 6.2.1 / mpfr 4.2.2 / mpc 1.3.1 / isl 0.24)

- **Sizes**: gcc 10 ~71.5 MiB + ~5.6 MiB of deps.
- **sha256s**:
  - gcc 10.4.0:  `c9297d5bcd7cb43f3dfc2fed5389e948c9312fd962ef6a4ce455cff963ebe4f1`
  - gmp 6.2.1:   `fd4829912cddd12f84181c3451cc752be224643e87fac497b69edddadc49b4f2`
  - mpfr 4.2.2:  `b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01`
  - mpc 1.3.1:   `ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8`
  - isl 0.24:    `fcf78dd9656c10eb8cf9fbd5f59a0b6b01386205fe1934b3b287a0a1898145c0`
- **nixpkgs ref**: `gcc/10.nix`.
- **License**: GPL-3.0+ for gcc; LGPL-3.0+ for gmp/mpfr/mpc; MIT for
  isl.
- **Note**: nixpkgs explicitly avoids gcc 10.5 (per upstream bug
  110716); 10.4.0 is the LAST 10.x that compiles cleanly with gcc 4.6.

## gcc-15.2.0.tar.xz + gmp 6.3.0 (mpfr/mpc/isl reused from gcc 10)

- **Size**: gcc 15 ~96.4 MiB + gmp 6.3.0 ~2.0 MiB.
- **sha256s**:
  - gcc 15.2.0: `438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e`
  - gmp 6.3.0:  `a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898`
- **nixpkgs ref**: `gcc/latest.nix`.
- **Note**: same mpfr 4.2.2, mpc 1.3.1, isl 0.24 as gcc 10 -- no
  separate vendoring required.

## tinycc-mes.tar.gz (R5 Session 2 vendor)

- **Upstream URL**:
  `https://repo.or.cz/tinycc.git/snapshot/cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341.tar.gz`.
- **Upstream commit**: `cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341`
  (repo.or.cz/tinycc.git "mob" history; nixpkgs labels
  "unstable-2025-12-03").
- **Snapshot date**: 2026-06-12.
- **Size**: 992909 bytes.
- **Our sha256 (tarball file)**:
  `012fe809a988528925771b4e3ec6e5914a49d3fed59790e04a36f75f3aca5439`.
- **nixpkgs SRI pin (tarball file)**:
  `sha256-MRuqq3TKcfIahtUWdhAcYhqDiGPkAjS8UTMsDE+/jGU=` (hex
  `311baaab74ca71f21a86d51676101c621a838863e40234bc51332c0c4fbf8c65`).
  Source: `pkgs/os-specific/linux/minimal-bootstrap/tinycc/mes.nix`.
- **Why our hash differs from nixpkgs**: repo.or.cz now gates downloads
  through an Anubis proof-of-work challenge (2026 onward) that
  `Invoke-WebRequest` can't solve.  We re-materialised the tarball
  deterministically via `git archive` from a clone of the public mirror
  (which Github / GitLab forks track):
  ```
  git clone --no-tags https://repo.or.cz/tinycc.git
  git --git-dir=tinycc.git archive --format=tar.gz \
      --prefix=tinycc-cb41cbf/ cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341 \
      -o tinycc-mes.tar.gz
  ```
  The TAR.GZ format / metadata differ from repo.or.cz's snapshot tarball,
  but the EXTRACTED SOURCE CONTENT is byte-identical to the cb41cbfe7
  git tree (which is content-addressable by definition).  Cross-check
  by hashing individual files:
  - `tcc.c`        sha256 `fd46f22e22b9a2b50d1ded68eab593e178e1bd43288a7a4d03531985928c0777`
  - `tccgen.c`     sha256 `fa3370179d632ee88df3c09ef78fd8b2e9222d452ee77a78ec23d80f09464744`
  - `i386-asm.c`   sha256 `ee96b69a8c394190461936691d50d18d4322dc0ec8580f07bc5af18b15cf1647`
  - `libtcc.c`     sha256 `2ca28a612f13028edfbd2751f3a8b6190911a1b2b527db793061d454bf728c8b`
  - `x86_64-gen.c` sha256 `8c2993ffe617872b6bfaaf67aaa1b8219f8af8b4d55e124b4cc1f6b6e5b54c33`
  - `include/tccdefs.h` sha256 `1d7fd24fbf8fbc9c07f54c9803390a37348d4f7b791b43e6166c1597b28ad41b`
- **License**: LGPL-2.1-only.
- **Note**: `tinycc-mes` is the modern tcc (CONFIG_TCC_PREDEFS=1 +
  generated tccdefs_.h) that accepts the C99 features musl 1.2.6 requires
  (`__builtin_va_list`, `[static N]` array params).  It's the missing
  link between `tinycc-bootstrappable` (R4) and musl-tcc (R5 Phase B).

## Refresh (R5)

```
pwsh recipes/bootstrap/tcc-chain/vendor/fetch-r5.ps1
```

Each file is sha256-checked against SHA256SUMS-r5.txt after download.
