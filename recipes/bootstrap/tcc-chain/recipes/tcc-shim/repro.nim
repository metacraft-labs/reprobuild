## R5 Phase 2: tcc-shim -- stage R4's tcc with stable include + lib paths.
##
## STATUS: LANDED (2026-06-12, R5 session 1).  R4's tcc has temp build
## paths baked into CONFIG_TCC_SYSINCLUDEPATHS (specifically the mktemp
## dir from R4 Phase 6).  Those paths point at a now-deleted location,
## so downstream `#include <stdio.h>` etc. fails out of the box.
##
## This recipe stages the R4 tcc + sysroot under /tmp/tcc-r5-shim/
## (configurable) with three artifacts:
##
##   - $shim/bin/tcc + $shim/lib/{crt*.o, libc.a, libtcc1.a, libgetopt.a}
##     -- the R4 tcc binary + libs, executable from local disk (not
##     drvfs, which blocks `noexec`-equivalent on .exe-suffix-less
##     binaries).
##   - $shim/include/  -- the tinycc-bootstrappable include/* MERGED with
##     mes-libc include/* (mes-libc wins on libc-shaped conflicts;
##     tinycc compiler-intrinsics like stddef.h/stdarg.h/float.h are
##     restored on top).
##   - $shim/wrapper/tcc -- a wrapper script that injects
##     `-I $shim/include -B $shim/lib` so downstream `CC=tcc` works
##     out of the box.
##
## The script ALSO re-materialises the baked-in
## /tmp/reproos-r4e-tcc-61ItS1/* paths as symlinks pointing at the
## persistent shim, so the R4 tcc's default behaviour (no `-I/-B`
## overrides) ALSO finds headers.  This makes the shim resilient
## against `./configure` scripts that strip CC env vars.
##
## ## Smoke tests (all in build-tcc-shim.sh Stage 6, must all pass):
##   - Test A: ret-only via wrapper -> exit 7
##   - Test B: stdio.h hello via wrapper -> exit 11
##   - Test C: ret-only via baked-path symlinks -> exit 13
##   - Test D: stdio.h hello via baked-path symlinks -> exit 17

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainTccShim:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("cd recipes/bootstrap/tcc-chain && " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-tcc-shim.sh " &
                 "vendor build /tmp/tcc-r5-shim"),
      actionId = "tccChainTccShim.build_tcc_shim",
      extraInputs = @[
        "recipes/bootstrap/tcc-chain/vendor/tinycc-bootstrappable.tar.gz",
        "recipes/bootstrap/tcc-chain/scripts/build-tcc-shim.sh",
        # Phase 6 (R4) outputs:
        "recipes/bootstrap/tcc-chain/build/tcc/bin/tcc",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/libc.a",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/libtcc1.a",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/crt1.o",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/crti.o",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/crtn.o",
        # Phase 5 (R4) outputs (mes-libc headers):
        "recipes/bootstrap/tcc-chain/build/mes/share/mes-0.27.1/include/stdio.h",
      ],
      extraOutputs = @[
        # The shim is under /tmp by default and not tracked as a project
        # output for caching; downstream packages refer to it by env
        # path.  If a project wants a persisted shim, run with
        # `... build/tcc-shim` instead.
      ])
