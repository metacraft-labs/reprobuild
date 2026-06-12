## R5 Phase 3: musl-tcc -- build musl 1.2.6 with the tcc shim.
##
## STATUS: BLOCKED on tinycc-mes (R5 session 1, 2026-06-12).
##
## ## What works
##
## scripts/build-musl-tcc.sh:
##   - Stage 1: unpack musl 1.2.6 (1MiB)                     -- OK
##   - Stage 2: apply patches (sigsetjmp, popen, asm strip)  -- OK
##   - Stage 3: ./configure CC=tcc --disable-shared          -- OK
##   - Stage 4: make                                          -- PARTIAL:
##       crt/Scrt1.o, crt/crt1.o, crt/rcrt1.o, crt/x86_64/crti.o,
##       crt/x86_64/crtn.o all build, but
##     - obj/src/aio/aio.o FAILS at src/internal/syscall.h:417
##       "identifier expected" -- tcc cannot parse the C99
##       `char __buf[static 15+3*sizeof(int)]` array-length-with-static
##       function parameter syntax.
##
## ## Why this fails
##
## R4's tcc (janneke bootstrappable, ea3900f6d 2024-07-07) supports a
## limited C dialect: no `[static N]` array parameters, no
## `__builtin_va_list` as a builtin type on x86_64, etc.
##
## Per nixpkgs, downstream packages (binutils, gcc 4.6.4, AND musl
## itself) are NOT built with `tinycc-bootstrappable` -- they're built
## with `tinycc-mes` (an INTERMEDIATE tcc with `CONFIG_TCC_PREDEFS=1` +
## generated `tccdefs_.h`).
##
## SESSION 1 demonstrated the wall WITHOUT silently passing-through:
##
## 1. tcc cannot compile musl alltypes.h (line 326,
##    `typedef __builtin_va_list va_list`).  WORKAROUND attempted:
##    sed-replace with `void *`.  This allowed crt*.o + Scrt1.o to
##    build.
## 2. tcc cannot parse src/internal/syscall.h:417 (`[static N]` array
##    parameter).  No simple sed workaround; would require teaching
##    the bootstrappable tcc this C99 feature, which is exactly what
##    `CONFIG_TCC_PREDEFS=1` + `tccdefs_.h` does in upstream tinycc.
##
## CONCLUSION: must complete tinycc-mes (R5 prerequisite) first.  Then
## re-attempt musl-tcc; expected to succeed because nixpkgs's identical
## musl 1.2.6 + sigsetjmp patch chain works under tinycc-mes.
##
## ## Build shape (per nixpkgs musl/tcc.nix)
##
##   tar xzf musl-1.2.6.tar.gz
##   cd musl-1.2.6
##   patch -Np0 -i sigsetjmp.patch          (vendor/musl-sigsetjmp.patch)
##   rm -rf src/complex                     (tcc has no complex types)
##   sed-strip @PLT from x86_64 .s sources
##   rm src/math/{i386,x86_64}/*.c          (rely on pure-C polyfills)
##   sed-replace /bin/sh with bash in tools/*.sh, popen/system/wordexp
##   ./configure --prefix=$out --disable-shared CC=tcc
##   make AR="tcc -ar" RANLIB=true CFLAGS=-DSYSCALL_NO_TLS
##   make install
##   cp $tinycc.libs/lib/libtcc1.a $out/lib
##
## Expected wall-clock: ~30 minutes (musl is small but tcc compilation
## is slow).
##
## ## External inputs required
##
##   - vendor/musl-1.2.6.tar.gz             (1.0 MiB, fetched by fetch-r5.ps1)
##   - vendor/musl-sigsetjmp.patch          (468 bytes, fetched too)
##   - tinycc-mes outputs                   (NOT yet available; see
##     recipes/tinycc-mes/repro.nim)

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainMuslTcc:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("echo 'musl-tcc blocked on tinycc-mes; see " &
                 "recipes/musl-tcc/repro.nim for status and wall.' " &
                 ">&2 ; exit 78"),
      actionId = "tccChainMuslTcc.build_musl_tcc_blocked",
      extraInputs = @[],
      extraOutputs = @[])
