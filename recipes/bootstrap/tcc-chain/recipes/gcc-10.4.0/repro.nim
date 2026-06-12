## R5 Phase 7: gcc 10.4.0 -- built with gcc 4.6.4 (cxx) + musl.
##
## STATUS: NOT REACHED (2026-06-12, R5 session 1).  Source vendored
## (gcc 10.4.0 71.5 MiB + gmp 6.2.1 + mpfr 4.2.2 + mpc 1.3.1 + isl 0.24)
## but build is blocked on gcc 4.6.4 Stage B + musl.
##
## ## Build shape (per nixpkgs gcc/10.nix)
##
##   tar xf gcc-10.4.0.tar.xz
##   tar xf gmp-6.2.1.tar.xz
##   tar xf mpfr-4.2.2.tar.xz
##   tar xf mpc-1.3.1.tar.gz
##   tar xf isl-0.24.tar.bz2
##   cd gcc-10.4.0
##   ln -s ../gmp-6.2.1  gmp
##   ln -s ../mpfr-4.2.2 mpfr
##   ln -s ../mpc-1.3.1  mpc
##   ln -s ../isl-0.24   isl
##   sed -i 's|"os/gnu-linux"|"os/generic"|' libstdc++-v3/configure.host
##   export CC="gcc -Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export CXX="g++ -Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export CFLAGS_FOR_TARGET="-Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export C_INCLUDE_PATH=$musl/include
##   export CPLUS_INCLUDE_PATH=$C_INCLUDE_PATH
##   export LIBRARY_PATH=$musl/lib
##   ./configure --prefix=$out
##     --build=$buildPlatform --host=$hostPlatform
##     --with-native-system-header-dir=/include
##     --with-sysroot=$musl
##     --enable-languages=c,c++
##     --enable-checking=release
##     --disable-bootstrap
##     --disable-dependency-tracking
##     --disable-libmpx --disable-libsanitizer
##     --disable-libssp --disable-libgomp
##     --disable-libquadmath --disable-libitm
##     --disable-libvtv --disable-libatomic
##     --disable-libstdcxx-pch
##     --disable-lto --disable-multilib --disable-nls
##     --disable-plugin
##   make -j N
##   make -j N install-strip
##
## ## Note on version: 10.4.0 NOT 10.5.0
##
## Nixpkgs explicitly avoids gcc 10.5 per upstream bug 110716; 10.4.0
## is the LAST 10.x that compiles cleanly with gcc 4.6.  We follow.
##
## ## Expected wall-clock: 2-3 hours.
##
## ## External inputs required
##
##   - vendor/gcc-10.4.0.tar.xz   (71.5 MiB)  -- DONE
##   - vendor/gmp-6.2.1.tar.xz                -- DONE
##   - vendor/mpfr-4.2.2.tar.xz               -- DONE
##   - vendor/mpc-1.3.1.tar.gz                -- DONE
##   - vendor/isl-0.24.tar.bz2                -- DONE
##   - gcc 4.6.4 cxx + musl outputs           -- BLOCKED

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainGcc1040:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("echo 'gcc 10.4.0 blocked on gcc 4.6.4 cxx + musl; " &
                 "see recipes/gcc-10.4.0/repro.nim.' >&2 ; exit 78"),
      actionId = "tccChainGcc1040.build_gcc1040_blocked",
      extraInputs = @[],
      extraOutputs = @[])
