## R5 Phase 5: binutils 2.46.0 -- built with tinycc-musl.
##
## STATUS: NOT REACHED (2026-06-12, R5 session 1).  Source vendored
## (vendor/binutils-2.46.0.tar.xz, 27.2 MiB, sha256-matches nixpkgs
## pin) but build is blocked on the tinycc-mes -> musl-tcc ->
## tinycc-musl prerequisite chain.
##
## ## Build shape (per nixpkgs binutils/default.nix, mesboot variant)
##
##   tar xJf binutils-2.46.0.tar.xz
##   cd binutils-2.46.0
##   patch -Np1 -i deterministic.patch        (BFD_DETERMINISTIC_OUTPUT)
##   patch -Np1 -i fix-tinycc-attribute.patch (ansidecl.h __TINYC__ guard)
##   sed-replace /bin/sh with bash in missing install-sh mkinstalldirs
##   sed-fix ltmain.sh NL2SP sort order
##   ln -s coreutils/bin/true aliases/makeinfo   (alias makeinfo to true)
##   export CC="tcc -B $tinycc.libs/lib"   <-- this is tinycc-musl's libs
##   export AR="tcc -ar"
##   export lt_cv_sys_max_cmd_len=32768
##   export CFLAGS="-D__LITTLE_ENDIAN__=1"
##   ./configure --prefix=$out
##     --disable-dependency-tracking --disable-nls
##     --enable-deterministic-archives --disable-gprofng
##     --enable-new-dtags --with-lib-path=:
##   make -j N all-libiberty all-gas all-bfd all-libctf all-zlib all-gprof
##   make all-ld        # race condition on ldwrite.Po; serial
##   make -j N          # rest
##   make -j N install
##   rm -f $out/bin/{gprof,addr2line,elfedit}
##   rm -rf $out/share/{info,man}
##
## Expected wall-clock: ~45 minutes (binutils is ~50 KLOC C; tcc is slow).
##
## ## Patches required (TO BE VENDORED under recipes/binutils/patches/)
##
## Both patches were read in nixpkgs at the reference commit and are
## small enough to commit in-tree:
##
##   - deterministic.patch: 1-line addition to ld/ldlang.c setting
##     BFD_DETERMINISTIC_OUTPUT on the output bfd.  Source:
##     D:/metacraft/nixpkgs/pkgs/os-specific/linux/minimal-bootstrap/
##     binutils/deterministic.patch.
##   - fix-tinycc-attribute.patch: 1-line guard in include/ansidecl.h
##     to skip the `__attribute__(x)` no-op define when `__TINYC__` is
##     defined (modern tcc IS attribute-aware).  Source:
##     D:/metacraft/nixpkgs/pkgs/os-specific/linux/minimal-bootstrap/
##     binutils/fix-tinycc-attribute.patch.
##
## ## External inputs required
##
##   - vendor/binutils-2.46.0.tar.xz  (27.2 MiB)  -- DONE
##   - patches above                              -- TODO this session
##   - tinycc-musl outputs (bin/tcc + libs/musl)  -- BLOCKED on R5 Phase 3+

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainBinutils:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("echo 'binutils blocked on musl-tcc; see " &
                 "recipes/binutils/repro.nim for status.' " &
                 ">&2 ; exit 78"),
      actionId = "tccChainBinutils.build_binutils_blocked",
      extraInputs = @[],
      extraOutputs = @[])
