## R4 Phase 6 (R4e): tinycc-bootstrappable -> tcc (the final goal).
##
## NOT YET LANDED. Ports nixpkgs's
## pkgs/os-specific/linux/minimal-bootstrap/tinycc/default.nix.
##
## Build shape (from nixpkgs tinycc/default.nix):
##
##   1. fetchurl tinycc-bootstrappable source tarball (specific commit,
##      not the upstream tinycc; the bootstrappable fork compiles with
##      mes + mes-libc).
##   2. Configure: `tcc -DCONFIG_TCCDIR ... -DCONFIG_TRIPLET=x86_64-mes-linux`.
##   3. Compile each .c file (~30 files) via:
##         mes-m2 -e main mescc.scm -- -c <src.c>
##      then archive into `libtcc1.a` and link the main `tcc` binary
##      against mes-libc + libc+tcc.a + crt1.o.
##   4. Smoke test: tcc -o hello hello.c; ./hello.
##
## External inputs required beyond Phases 4+5:
##   - tcc-bootstrappable source tarball (specific pinned commit per
##     nixpkgs tinycc/default.nix `src = fetchurl`)
##   - patches: tinycc upstream has portability issues mes can't compile;
##     nixpkgs ships ~5 .patch files in tinycc/.
##
## DEFERRED IN R4 SESSION 1 because:
##   - depends on Phase 5 (mes + mes-libc), which is itself deferred.
##   - the tinycc bootstrap variant lives in a non-trivial source tarball
##     that needs separate vendor + sha256 pinning effort.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainTcc:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("cd recipes/bootstrap/tcc-chain && " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-tcc.sh " &
                 "vendor build/mes build/mescc-tools build/tcc"),
      actionId = "tccChainTcc.build_tcc",
      extraInputs = @[
        "recipes/bootstrap/tcc-chain/vendor/tinycc-bootstrappable.tar.gz",
        "recipes/bootstrap/tcc-chain/vendor/SHA256SUMS",
        "recipes/bootstrap/tcc-chain/scripts/build-tcc.sh",
        "recipes/bootstrap/tcc-chain/build/mes/bin/mes",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc+tcc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libmescc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/crt1.o",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Mesoplanet",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/tcc/bin/tcc",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/libtcc1.a",
        "recipes/bootstrap/tcc-chain/build/tcc/SHA256SUMS",
      ])
