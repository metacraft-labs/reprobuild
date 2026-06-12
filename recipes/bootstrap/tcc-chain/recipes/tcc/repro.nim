## R4 Phase 6 (R4e): tinycc-bootstrappable -> tcc (the R4 acceptance gate).
##
## STATUS: LANDED (2026-06-12).  Builds janneke's bootstrappable tinycc
## fork (commit ea3900f6d5e71776c5cfabcabee317652e3a19ee, nixpkgs
## "unstable-2024-07-07") via the Phase 5 mes-m2 + mescc.scm.  Produces
## a working `tcc` binary that compiles standard C programs against the
## mes-libc.
##
## Build shape (per nixpkgs pkgs/os-specific/linux/minimal-bootstrap/
## tinycc/bootstrappable.nix):
##
##   Stage A: synthesise mes-libc bundle (libc.c + libtcc1.c + crt*.c).
##     Per nixpkgs libc.nix: concat the first-100 libc_gnu_SOURCES +
##     ldexpl.c + the tail (~50 more files) into one libc.c.  The
##     resulting bundle is the "single-file" C library that tcc compiles
##     against itself.
##   Stage B: tinycc-boot-mes (the FIRST tcc binary).
##     mes-m2 + mescc.scm compiles tcc.c -> tcc.s, then links against
##     libc+tcc.a (from Phase 5) into Stage-B's tcc.
##   Stage C: recompile libc/libtcc1/crt with Stage-B tcc.
##     These are the libs the next stage's tcc uses via `-B`.
##   Stage D: iterations tinycc-boot{0,1,2,3,bootstrappable}.
##     Each stage rebuilds tcc using the prev stage's tcc + libs, with
##     progressively more features enabled (HAVE_LONG_LONG / BITFIELD /
##     FLOAT_STUB / FLOAT / SETJMP).  The FINAL `tcc` is the output of
##     the bootstrappable iteration.
##
## R4 acceptance gate: `tcc -o hello hello.c; ./hello; echo $?` -> 42.
##
## ## Patches applied to tinycc source (per nixpkgs bootstrappable.nix):
##   - libtcc.c       (static_link=1 by default)
##   - include/stddef.h (max_align_t typedef for mes-libc)
##   - x86_64-gen.c   (3 mescc-compat patches: VLA, abort, bitfield shift)
##   - tccelf.c       (PLT relocation fix for x86_64)
##
## ## External inputs required:
##   - tinycc-bootstrappable.tar.gz  (vendor/, sha256 pinned)
##   - Phase 5 outputs (mes-m2, mes, mescc.scm, lib/x86_64-mes/*.a, crt1.o,
##     share/mes-0.27.1/{include,lib})
##   - Phase 4 outputs (mescc-tools replace + cp)
##
## ## Reproducibility note: depends on the /repro/mes-0.27.1 symlink
## convention from Phase 5.  Build script restores the symlink if
## missing (points it at $MES_ABS/share/mes-0.27.1).

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
        # Phase 5 outputs:
        "recipes/bootstrap/tcc-chain/build/mes/bin/mes",
        "recipes/bootstrap/tcc-chain/build/mes/bin/mes-m2",
        "recipes/bootstrap/tcc-chain/build/mes/bin/mescc.scm",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc+tcc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libmescc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/crt1.o",
        # Phase 4 outputs:
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Mesoplanet",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/replace",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/tcc/bin/tcc",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/libtcc1.a",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/libc.a",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/crt1.o",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/crtn.o",
        "recipes/bootstrap/tcc-chain/build/tcc/lib/crti.o",
        "recipes/bootstrap/tcc-chain/build/tcc/SHA256SUMS",
      ])
