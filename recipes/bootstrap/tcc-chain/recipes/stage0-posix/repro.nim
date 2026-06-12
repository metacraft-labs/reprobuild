## R4 Phase 3 (R4b): stage0-posix mescc-tools-boot chain.
##
## Ports nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/stage0-posix/
## mescc-tools-boot.nix (the 11-step chain from hex0 → kaem-unwrapped)
## into a single shell-script driver that the typed reprobuild action
## wraps. The script (`scripts/build-stage0-posix.sh`) runs inside the
## repro-debian WSL distro and produces these binaries under
## `build/stage0-posix/`:
##
##   hex1, hex2-0, catm, M0, cc_arch, M2, blood-elf-0, M1-0, hex2-1,
##   M1, hex2, kaem-unwrapped
##
## Per-binary sha256 lands in `build/stage0-posix/SHA256SUMS`.
##
## The chain uses the AMD64 platform pins from nixpkgs's
## stage0-posix/platforms.nix:
##   stage0Arch    = AMD64
##   m2libcArch    = amd64
##   ENDIAN_FLAG   = --little-endian
##   BLOOD_FLAGS   = --64
##   baseAddress   = 0x00600000
##
## Reproducibility: every step uses SOURCE_DATE_EPOCH=1735689600 LC_ALL=C
## TZ=UTC. Note that hex0/hex2/M0/M1/M2 emit no timestamps in their
## outputs (they're hand-rolled assemblers without metadata sections);
## blood-elf-0 emits ELF debug info but not timestamps. The chain should
## be byte-stable across rebuilds.
##
## Verification (Phase 3 acceptance criterion): re-run produces
## byte-identical SHA256SUMS. Cross-check vs nixpkgs build (if a NixOS
## host is available) is a future M2-real verification step; the
## existing M2-sim chain.json pins i386 stage0-posix binaries from
## Stagex, which won't byte-match these AMD64 outputs.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainStage0Posix:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("cd recipes/bootstrap/tcc-chain && " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-stage0-posix.sh " &
                 "vendor build/stage0-posix"),
      actionId = "tccChainStage0Posix.build_chain",
      extraInputs = @[
        "recipes/bootstrap/tcc-chain/vendor/hex0-seed.AMD64.bin",
        "recipes/bootstrap/tcc-chain/vendor/minimal-bootstrap-sources.tar.gz",
        "recipes/bootstrap/tcc-chain/vendor/SHA256SUMS",
        "recipes/bootstrap/tcc-chain/scripts/build-hex0.sh",
        "recipes/bootstrap/tcc-chain/scripts/build-stage0-posix.sh",
        "recipes/bootstrap/tcc-chain/build/hex0/hex0",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/stage0-posix/hex0",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/hex1",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/hex2-0",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/catm",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/M0",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/cc_arch",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/M2",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/blood-elf-0",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/M1-0",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/hex2-1",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/M1",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/hex2",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/kaem-unwrapped",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/SHA256SUMS",
      ])
