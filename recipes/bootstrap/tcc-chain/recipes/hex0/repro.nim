## R4 Phase 2 (R4a): hex0 — the seed step.
##
## Builds the canonical AMD64 hex0 binary from the 229-byte hex0-seed +
## the hex0_AMD64.hex0 source script (from minimal-bootstrap-sources).
## hex0 is the assembler used by every later stage0-posix step.
##
## Implementation pattern: mirrors recipes/reproos-iso/repro.nim — wraps
## a single shell-script driver (`scripts/build-hex0.sh`) that runs
## inside the repro-debian WSL distro (Linux build env). The typed
## reprobuild action captures (inputs, env, output) so the engine
## fingerprints + caches deterministically; the script implements the
## bootstrap byte-for-byte per nixpkgs's
## pkgs/os-specific/linux/minimal-bootstrap/stage0-posix/hex0.nix.
##
## Verification: the produced hex0 sha256 must equal the seed's sha256.
## This is the bootstrap-seeds self-hosting property: the seed binary
## IS the hex0 ELF; the hex0_AMD64.hex0 source documents the byte layout
## so the seed can be re-derived from text. Verified locally:
##   seed:           sha256 66c95985e668f20f2465c2b876f83fef066fd7c8c2dd3adb51a969f2d7120c8b
##   built hex0:     sha256 66c95985e668f20f2465c2b876f83fef066fd7c8c2dd3adb51a969f2d7120c8b
##
## NB: nixpkgs's `outputHash` in hex0.nix is a NAR-format hash
## (sha256-DCzZduYrix9yOeJoem/Jhz/WDzAss7UWwjZbkXJq6Ms=, hex
## 0c2cd976e62b8b1f7239e2687a6fc9873fd60f302cb3b516c2365b91726ae8cb).
## That's NAR-of-the-output, not the file's raw sha256. Both hashes
## refer to the same 229-byte ELF.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainHex0:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("cd recipes/bootstrap/tcc-chain && " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-hex0.sh " &
                 "vendor build/hex0"),
      actionId = "tccChainHex0.build_hex0",
      extraInputs = @[
        "recipes/bootstrap/tcc-chain/vendor/hex0-seed.AMD64.bin",
        "recipes/bootstrap/tcc-chain/vendor/minimal-bootstrap-sources.tar.gz",
        "recipes/bootstrap/tcc-chain/vendor/SHA256SUMS",
        "recipes/bootstrap/tcc-chain/scripts/build-hex0.sh",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/hex0/hex0",
        "recipes/bootstrap/tcc-chain/build/hex0/hex0.sha256",
      ])
