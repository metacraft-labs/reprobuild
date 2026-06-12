## R4 Phase 5 (R4d): mes — Maxwell Equations of Software (Scheme + minimal C).
##
## STATUS: LANDED (2026-06-12).  Bootstraps GNU Mes 0.27.1 from the
## stage0-posix + mescc-tools chain (Phases 3+4).
##
## Build shape (per nixpkgs pkgs/os-specific/linux/minimal-bootstrap/
## mes/default.nix):
##
##   1. Untar mes-0.27.1.tar.gz + nyacc-1.09.1.tar.gz (pinned upstream).
##   2. Generate `include/mes/config.h` with x86_64 typedefs
##      (uintptr_t/size_t/ssize_t/intptr_t/ptrdiff_t = unsigned long / long).
##   3. Apply ~15 source-text patches via mescc-tools-extra/replace:
##      - lib/linux/x86_64-mes-gcc/_exit.c     (clobber list)
##      - lib/x86_64-mes-gcc/setjmp.c          (replace with x86_64 asm)
##      - lib/linux/link.c                     (linkat syscall args)
##      - include/linux/x86_64/syscall.h       (SYS_nanosleep number)
##      - lib/string/strpbrk.c                 (NULL on no-match)
##      - lib/mes/ntoab.c, lib/linux/ioctl3.c, include/mes/lib.h
##        (size_t -> unsigned long)
##      - lib/stdio/vfprintf.c + vsnprintf.c   (long-arg portability)
##      - mes/module/mes/{guile-module,guile}.mes + module/mescc/mescc.scm
##        (replace getenv with embedded /repro paths)
##      - src/{mes,gc}.c                       (env-var -> constants)
##      - scripts/mescc.scm.in                 (template -> filled values)
##   4. Run `kaem --verbose --strict --file kaem.run` to bootstrap
##      mes-m2 (the Scheme interpreter built via M2-Planet from kaem.run's
##      ~150-file C-fragment list).
##   5. Use mes-m2 + the patched mescc.scm to compile the C libs:
##      - libc-mini.a   (~10 .c files)
##      - libmescc.a    (2 .c files)
##      - libc.a        (~105 .c files)
##      - libc+tcc.a    (~158 .c files; libc + symlink + extras for tcc)
##      - crt1.o
##   6. Link the final `mes` binary from 20 src/*.c files.
##
## ## Reproducibility hazards caught
##
## The embedded MES_PREFIX path (baked into mes-m2 + mescc.scm bytes by
## the `replace` substitutions in step 3) MUST be a fixed canonical
## path to be reproducible — using `$OUT_ABS` would embed the user's
## build dir.  We use `/repro/mes-0.27.1` (stable per build), with a
## staging symlink to `/tmp/.../staging/repro/mes-0.27.1` during the
## build (tmpfs is ~100x faster than 9p drvfs for mes-m2's 1-byte-at-
## a-time reads).  Phase 6 must restore the symlink before invoking
## mes-m2/mes.
##
## External inputs required:
##   - mes-0.27.1.tar.gz                          (vendor/, sha256 pinned)
##   - nyacc-1.09.1.tar.gz                        (vendor/, sha256 pinned)
##   - minimal-bootstrap-sources.tar.gz           (vendor/, source-only)
##   - Phase 3 outputs (build/stage0-posix/{M1,M2,hex2,blood-elf-0,
##     kaem-unwrapped,catm})
##   - Phase 4 outputs (build/mescc-tools/bin/{M1,M2,hex2,replace,
##     M2-Mesoplanet,blood-elf,M2-Planet,cp,mkdir,chmod,get_machine})

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
        "recipes/bootstrap/tcc-chain/vendor/nyacc-1.09.1.tar.gz",
        "recipes/bootstrap/tcc-chain/vendor/SHA256SUMS",
        "recipes/bootstrap/tcc-chain/scripts/build-mes.sh",
        # Phase 4 outputs:
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M1",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Mesoplanet",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/M2-Planet",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/blood-elf",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/hex2",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/replace",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/cp",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/mkdir",
        "recipes/bootstrap/tcc-chain/build/mescc-tools/bin/chmod",
        # Phase 3 kaem + catm:
        "recipes/bootstrap/tcc-chain/build/stage0-posix/kaem-unwrapped",
        "recipes/bootstrap/tcc-chain/build/stage0-posix/catm",
      ],
      extraOutputs = @[
        "recipes/bootstrap/tcc-chain/build/mes/bin/mes",
        "recipes/bootstrap/tcc-chain/build/mes/bin/mes-m2",
        "recipes/bootstrap/tcc-chain/build/mes/bin/mescc.scm",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc-mini.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libmescc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/libc+tcc.a",
        "recipes/bootstrap/tcc-chain/build/mes/lib/x86_64-mes/crt1.o",
        "recipes/bootstrap/tcc-chain/build/mes/SHA256SUMS",
      ])
