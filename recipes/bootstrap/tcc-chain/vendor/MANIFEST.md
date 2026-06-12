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

## Refresh

Run `pwsh fetch.ps1` to re-materialise `minimal-bootstrap-sources.tar.gz`
from upstream. The script clones the pinned tag + submodules in a WSL
distro and re-tars deterministically. The hex0-seed is committed and
needs no refresh. The mes + nyacc tarballs are direct upstream
downloads; refresh via:

```
pwsh -c 'iwr https://ftpmirror.gnu.org/gnu/mes/mes-0.27.1.tar.gz -OutFile mes-0.27.1.tar.gz'
pwsh -c 'iwr https://download.savannah.nongnu.org/releases/nyacc/nyacc-1.09.1.tar.gz -OutFile nyacc-1.09.1.tar.gz'
```
