## R4 Phase 4 (R4c): mescc-tools (C-rewritten utilities).
##
## NOT YET LANDED. Ports nixpkgs's
## pkgs/os-specific/linux/minimal-bootstrap/stage0-posix/mescc-tools/
## {default.nix,build.kaem}. Builds, on top of the Phase 3 stage0-posix
## binaries:
##   * mescc-tools-extra: mkdir, cp, chmod, replace
##   * mescc-tools final: M2-Mesoplanet, blood-elf, get_machine, M2-Planet
##
## The driver script `scripts/build-mescc-tools.sh` is authored but
## untested pending Phase 3 completion (the stage0-posix M1/M2/hex2/
## blood-elf-0 inputs are produced by Phase 3 which takes ~25 min cold).

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainMesccTools:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("cd recipes/bootstrap/tcc-chain && " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-mescc-tools.sh " &
                 "vendor build/stage0-posix build/mescc-tools"),
      actionId = "tccChainMesccTools.build_mescc_tools",
      extraInputs = @[
        "recipes/bootstrap/tcc-chain/vendor/minimal-bootstrap-sources.tar.gz",
        "recipes/bootstrap/tcc-chain/vendor/SHA256SUMS",
        "recipes/bootstrap/tcc-chain/scripts/build-mescc-tools.sh",
        # Phase 3 outputs that this phase consumes:
        "recipes/bootstrap/tcc-chain/build/stage0-posix/M1",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/M2",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/hex2",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/blood-elf-0",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/kaem-unwrapped",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M1",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/hex2",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/mkdir",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/cp",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/chmod",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/replace",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Mesoplanet",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/blood-elf",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/get_machine",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Planet",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/SHA256SUMS",
      ])
