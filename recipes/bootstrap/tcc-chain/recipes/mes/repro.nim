## R4 Phase 5 (R4d): mes — Maxwell Equations of Software (Scheme + minimal C).
##
## NOT YET LANDED. The mes build is the heaviest single step in the
## chain (30+ minutes of CPU per the R4 spec brief). Ports nixpkgs's
## pkgs/os-specific/linux/minimal-bootstrap/mes/default.nix.
##
## Build shape (from nixpkgs mes/default.nix):
##
##   1. fetchurl mes-0.27.1.tar.gz (sha256
##      `sha256-GDpA6kfqSfih470bnRLmdjdNZNY7x557wa59Zz398l0=`).
##   2. Generate `include/mes/config.h` with arch-specific
##      uintptr_t / size_t / ssize_t / intptr_t / ptrdiff_t typedefs.
##   3. Apply ~15 source-text patches via mescc-tools-extra/replace:
##      - lib/linux/x86_64-mes-gcc/_exit.c (clobber list fix)
##      - lib/x86_64-mes-gcc/setjmp.c (replaced with x86_64 asm)
##      - lib/linux/link.c (linkat syscall arg count)
##      - include/linux/x86_64/syscall.h (nanosleep number)
##      - lib/string/strpbrk.c (NULL on no-match)
##      - lib/mes/ntoab.c, lib/linux/ioctl3.c, include/mes/lib.h
##        (size_t -> unsigned long fixes)
##      - lib/stdio/vfprintf.c + vsnprintf.c (long-arg portability fix)
##      - mes/module/mes/{guile-module,guile}.mes + module/mescc/mescc.scm
##        (replace getenv lookups with hardcoded store paths)
##      - src/{mes,gc}.c (env-var lookups -> constants)
##      - scripts/mescc.scm.in (template -> filled values)
##   4. Build `mes-m2` via `kaem --verbose --strict --file kaem.x86_64`
##      using the patched source tree, M2-Mesoplanet, mescc-tools.
##   5. Use mes-m2 + mescc.scm to compile mes proper:
##      - libc-mini.a   (~5 .c files)
##      - libmescc.a    (~3 .c files)
##      - libc.a        (~25 .c files)
##      - libc+tcc.a    (libc + symlink, used by ln-boot)
##      - crt1.o
##      - mes binary    (the final compiler)
##
## External inputs required beyond Phase 3+4:
##   - mes-0.27.1.tar.gz (sha256-pinned)
##   - nyacc (separate fetchurl in nixpkgs `nyacc.nix`)
##   - `sources.json` enumeration of which .c files go in each library
##
## DEFERRED IN R4 SESSION 1 because:
##   1. Phase 3 (stage0-posix) takes ~25 min cold; budget ran out before
##      Phase 4 could be run end-to-end and verified.
##   2. Phase 5 requires a separate vendor effort: tarball + nyacc +
##      sources.json + ~15 source patches.
##   3. The mes-libc + tcc bootstrap path is documented in
##      `live-bootstrap/sysa/mes-0.25/mes-0.25.kaem` upstream; lifting
##      it correctly is a multi-day effort. Possible follow-up scope:
##      use Stagex's published bootstrap-stage1 OCI layer as the floor,
##      then incrementally replace each binary.

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainMes:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("cd recipes/bootstrap/tcc-chain && " &
                 "SOURCE_DATE_EPOCH=1735689600 LC_ALL=C TZ=UTC " &
                 "bash scripts/build-mes.sh " &
                 "vendor build/mescc-tools build/mes"),
      actionId = "tccChainMes.build_mes",
      extraInputs = @[
        "recipes/bootstrap/tcc-chain/vendor/mes-0.27.1.tar.gz",
        "recipes/bootstrap/tcc-chain/vendor/SHA256SUMS",
        "recipes/bootstrap/tcc-chain/scripts/build-mes.sh",
        # Phase 4 outputs:
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M1",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Mesoplanet",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/blood-elf",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/hex2",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/kaem-unwrapped",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/mes/bin/mes",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc-mini.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libmescc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc+tcc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/crt1.o",
        "recipes/bootstrap/tcc-chain/build/mes/SHA256SUMS",
      ])
