## R5 Phase 3 PREREQUISITE: tinycc-mes -- the "intermediate" tinycc step.
##
## STATUS: NOT REACHED (2026-06-12, R5 session 1).  Identified as the
## missing chain step that prevents R5 Phase 3 (musl-tcc) from
## proceeding.  Next session's first action.
##
## ## Why this exists
##
## Per nixpkgs's pkgs/os-specific/linux/minimal-bootstrap/tinycc/mes.nix,
## the chain to a musl-capable tcc is:
##
##   tinycc-bootstrappable  (R4 done; janneke fork ea3900f6d 2024-07-07)
##      |
##      v
##   tinycc-mes  (THIS STEP; latest tinycc cb41cbfe7 2025-12-03 with
##                CONFIG_TCC_PREDEFS=1 + generated tccdefs_.h)
##      |
##      v
##   musl-tcc-intermediate
##      |
##      v
##   tinycc-musl-intermediate
##      |
##      v
##   musl-tcc           <- nixpkgs's "musl" for downstream binutils + gcc 4.6
##      |
##      v
##   tinycc-musl        <- nixpkgs's "tinycc" for downstream binutils + gcc 4.6
##
## R4 produced ONLY `tinycc-bootstrappable`.  R5 needs ALL of these
## intermediate steps before binutils + gcc are buildable.
##
## ## Why R4's tcc cannot compile musl directly
##
## musl 1.2.6's `include/alltypes.h.in` uses
## `typedef __builtin_va_list va_list;` (and ditto for __isoc_va_list).
## R4's tcc (the bootstrappable / janneke 2024-07-07 fork) does NOT
## recognise `__builtin_va_list` as a builtin type on x86_64; this is
## fixed in the upstream tinycc cb41cbfe7 via `CONFIG_TCC_PREDEFS=1` +
## a generated `tccdefs_.h` that injects:
##
##   typedef __builtin_va_list __va_list_t;
##   ...etc.
##
## Both nixpkgs's `tinycc-mes` and `tinycc-musl-intermediate` are built
## with `-D CONFIG_TCC_PREDEFS=1 -I tccdefs/`.
##
## ## Build shape (per nixpkgs tinycc/mes.nix)
##
## 1. Fetch tinycc source at rev cb41cbfe7 (latest, 2025-12-03).
## 2. Apply three patches:
##    - libtcc.c: static_link=1 by default (already in our R4 sed list).
##    - i386-asm.c: reg-aware size dispatch for r8..r15 (size byte
##      suffix b/w/d/<empty>).
##    - tccgen.c: ptr+(-1) handling cast to ptrdiff_t (signedness fix).
## 3. Generate tccdefs_.h:
##    - tcc -DC2STR -o c2str conftest.c   (uses R4's bootstrappable tcc)
##    - ./c2str include/tccdefs.h tccdefs_.h
##    - catm tccdefs/tccdefs_.h tccdefs_.h <(echo '"#include <mes/config.h>\n"')
## 4. Two-pass build (tinycc-mes-boot + tinycc-mes), each rebuilding
##    libtcc1.a from {lib/libtcc1.c, lib/alloca.S}.  Uses R4's
##    bootstrappable tcc to compile the FIRST pass.
##
## Expected wall-clock: ~10 minutes (small source, single compiler).
##
## ## External inputs required
##
##   - tinycc-mes source (NOT yet vendored; need to add to
##     vendor/fetch-r5.ps1):
##     URL:  https://repo.or.cz/tinycc.git/snapshot/cb41cbfe717e4c00d7bb70035cda5ee5f0ff9341.tar.gz
##     pin:  sha256-MRuqq3TKcfIahtUWdhAcYhqDiGPkAjS8UTMsDE+/jGU= (SRI)
##           hex: TBD (vendor on first run)
##
##   - R4 outputs: bin/tcc (the bootstrappable tcc) + lib/{crt*.o,
##     libc.a, libtcc1.a}, share/mes-0.27.1/include (mes-libc headers).

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainTinyccMes:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("echo 'tinycc-mes recipe is a stub; see comment in " &
                 "repro.nim for build shape and prerequisites.  Next " &
                 "session should author scripts/build-tinycc-mes.sh.' " &
                 ">&2 ; exit 78"),
      actionId = "tccChainTinyccMes.build_tinycc_mes_stub",
      extraInputs = @[],
      extraOutputs = @[])
