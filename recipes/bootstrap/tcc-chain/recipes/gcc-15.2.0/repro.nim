## R5 Phase 8: gcc 15.2.0 -- built with gcc 10.4.0 + musl.  The R5 goal.
##
## STATUS: NOT REACHED (2026-06-12, R5 session 1).  Source vendored
## (gcc 15.2.0 96.4 MiB + gmp 6.3.0 + mpfr 4.2.2 reused from gcc 10 +
## mpc 1.3.1 reused + isl 0.24 reused) but build is blocked on gcc
## 10.4.0.
##
## ## Build shape (per nixpkgs gcc/latest.nix)
##
##   tar xf gcc-15.2.0.tar.xz
##   tar xf gmp-6.3.0.tar.xz
##   tar xf mpfr-4.2.2.tar.xz  (REUSED from gcc 10)
##   tar xf mpc-1.3.1.tar.gz   (REUSED from gcc 10)
##   tar xf isl-0.24.tar.bz2   (REUSED from gcc 10)
##   cd gcc-15.2.0
##   ln -s ../gmp-6.3.0  gmp
##   ln -s ../mpfr-4.2.2 mpfr
##   ln -s ../mpc-1.3.1  mpc
##   ln -s ../isl-0.24   isl
##   sed -i 's|"os/gnu-linux"|"os/generic"|' libstdc++-v3/configure.host
##   export CC="gcc -Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export CXX="g++ -Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export CFLAGS_FOR_TARGET="-Wl,-dynamic-linker -Wl,$musl/lib/libc.so"
##   export LIBRARY_PATH=$musl/lib
##   ./configure --prefix=$out
##     --build=$buildPlatform --host=$hostPlatform
##     --with-native-system-header-dir=/include
##     --with-sysroot=$musl
##     --enable-languages=c,c++
##     --enable-checking=release
##     --disable-bootstrap
##     --disable-dependency-tracking
##     --disable-libsanitizer --disable-libssp
##     --disable-libgomp --disable-libquadmath
##     --disable-libitm --disable-libvtv
##     --disable-libatomic --disable-libstdcxx-pch
##     --disable-lto --disable-multilib --disable-nls
##     --disable-plugin
##   make -j N
##   make -j N install-strip
##   rm -rf $out/share/gcc-*/python $out/share/man $out/share/info
##
## ## Acceptance gate (R5 goal)
##
##   echo 'int main(){return 7;}' | $out/bin/gcc -x c -o /tmp/hello -
##   /tmp/hello; echo $?       -- must print 7.
##
## ## DDC gate (R5 Phase 9, optional)
##
##   Build gcc 15.2.0 AGAIN using the Phase 8 gcc 15.2.0.
##   If byte-identical to the Phase 8 binary, the chain is self-consistent.
##
## ## Expected wall-clock: 3-4 hours.
##
## ## External inputs required
##
##   - vendor/gcc-15.2.0.tar.xz   (96.4 MiB)   -- DONE
##   - vendor/gmp-6.3.0.tar.xz                 -- DONE
##   - mpfr/mpc/isl REUSED from gcc 10 vendor  -- DONE
##   - gcc 10.4.0 outputs                      -- BLOCKED

import repro_project_dsl
import repro_dsl_stdlib/packages/sh

package tccChainGcc1520:
  defaultToolProvisioning "path"

  uses:
    "sh"

  build:
    shell(
      command = ("echo 'gcc 15.2.0 blocked on gcc 10.4.0; see " &
                 "recipes/gcc-15.2.0/repro.nim.' >&2 ; exit 78"),
      actionId = "tccChainGcc1520.build_gcc1520_blocked",
      extraInputs = @[],
      extraOutputs = @[])
