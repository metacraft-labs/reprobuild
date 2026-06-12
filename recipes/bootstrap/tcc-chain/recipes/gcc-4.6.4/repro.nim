## R5 Phase 6: gcc 4.6.4 -- the tcc -> gcc bridge.
##
## STATUS: NOT REACHED (2026-06-12, R5 session 1).  Source vendored
## (gcc-core 36.7 MiB + gcc-g++ 8.8 MiB + gmp 4.3.2 + mpfr 2.4.2 +
## mpc 1.0.3) but build is blocked on the tinycc-mes -> musl-tcc ->
## tinycc-musl -> binutils prerequisite chain.
##
## ## Two-stage shape (per nixpkgs gcc/4.6.nix + gcc/4.6.cxx.nix)
##
## ### Stage A: gcc 4.6.4 C-only (tinycc-musl-built, no glibc/musl yet)
##
##   tar xzf gcc-core-4.6.4.tar.gz
##   tar xzf gcc-g++-4.6.4.tar.gz
##   tar xzf gmp-4.3.2.tar.gz
##   tar xzf mpfr-2.4.2.tar.gz
##   tar xzf mpc-1.0.3.tar.gz
##   cd gcc-4.6.4
##   ln -s ../gmp-4.3.2  gmp
##   ln -s ../mpfr-2.4.2 mpfr
##   ln -s ../mpc-1.0.3  mpc
##   patch -Np1 -i no-system-headers.patch   (gcc/Makefile.in)
##   export CC="tcc -B $tinycc.libs/lib"
##   export C_INCLUDE_PATH="$tinycc.libs/include:$(pwd)/mpfr/src"
##   export CPLUS_INCLUDE_PATH="$C_INCLUDE_PATH"
##   export lt_cv_shlibpath_overrides_runpath=yes
##   export ac_cv_func_memcpy=yes
##   export ac_cv_func_strerror=yes
##   ./configure --prefix=$out
##     --build=$buildPlatform (with -musl removed for config.sub)
##     --host=$hostPlatform
##     --with-native-system-header-dir=$tinycc.libs/include
##     --with-build-sysroot=$tinycc.libs/include
##     --enable-checking=release
##     --disable-bootstrap --disable-decimal-float
##     --disable-dependency-tracking --disable-libatomic
##     --disable-libcilkrts --disable-libgomp --disable-libitm
##     --disable-libmudflap --disable-libquadmath
##     --disable-libsanitizer --disable-libssp --disable-libvtv
##     --disable-lto --disable-lto-plugin
##     --disable-multilib --disable-nls
##     --disable-plugin --disable-threads
##     --enable-languages=c
##     --enable-static --disable-shared
##     --enable-threads=single --disable-libstdcxx-pch
##     --disable-build-with-cxx
##   make -j N
##   make -j N install-strip
##
## ### Stage B: gcc 4.6.4 C+C++ rebuilt with the Stage-A gcc + musl
##
## After R5 Phase 4 (musl built with gcc 4.6.4 Stage A), gcc 4.6.4 is
## rebuilt with C++ enabled, this time linking against musl.  This is
## what becomes the bootstrap host for gcc 10.4.0 (R5 Phase 7).
##
##   (same source extraction)
##   sed -i 's|"os/gnu-linux"|"os/generic"|' libstdc++-v3/configure.host
##   export CC="gcc -Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export CFLAGS_FOR_TARGET="-Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export C_INCLUDE_PATH=$musl/include
##   export CPLUS_INCLUDE_PATH=$C_INCLUDE_PATH
##   export LIBRARY_PATH=$musl/lib
##   ./configure --prefix=$out
##     --enable-languages=c,c++
##     --with-native-system-header-dir=$musl/include
##     --with-build-sysroot=$musl
##     --enable-checking=release
##     --disable-bootstrap
##     --disable-dependency-tracking
##     --disable-libgomp --disable-libmudflap
##     --disable-libquadmath --disable-libssp
##     --disable-libstdcxx-pch
##     --disable-lto --disable-multilib --disable-nls
##   make -j N
##   make -j N install-strip
##
## ## Patches required (TO BE VENDORED under recipes/gcc-4.6.4/patches/)
##
##   - no-system-headers.patch: 1-line edit to gcc/Makefile.in
##     commenting out the hardcoded NATIVE_SYSTEM_HEADER_DIR=/usr/include.
##     Source: D:/metacraft/nixpkgs/pkgs/os-specific/linux/minimal-bootstrap/
##     gcc/no-system-headers.patch.
##
## ## Expected wall-clock: Stage A: 60-90 minutes (gcc 4.6.4 cold build,
## tcc-compiled).  Stage B: 30-45 minutes (gcc-built gcc).
##
## ## External inputs required
##
##   - vendor/gcc-core-4.6.4.tar.gz   (36.7 MiB) -- DONE
##   - vendor/gcc-g++-4.6.4.tar.gz    (8.8 MiB)  -- DONE
##   - vendor/gmp-4.3.2.tar.gz        (2.4 MiB)  -- DONE
##   - vendor/mpfr-2.4.2.tar.gz       (1.3 MiB)  -- DONE
##   - vendor/mpc-1.0.3.tar.gz        (0.6 MiB)  -- DONE
##   - no-system-headers.patch        (~700 bytes) -- TODO commit in-tree
##   - tinycc-musl + binutils outputs (blocked)

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainGcc464:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("echo 'gcc 4.6.4 blocked on binutils + musl + " &
                 "tinycc-musl chain; see recipes/gcc-4.6.4/repro.nim.' " &
                 ">&2 ; exit 78"),
      actionId = "tccChainGcc464.build_gcc464_blocked",
      extraInputs = @[],
      extraOutputs = @[])
