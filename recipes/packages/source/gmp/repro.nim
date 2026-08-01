## Source build for GNU MP, the arbitrary-precision arithmetic library
## used by Nettle's public-key implementation and compiler toolchains.
## Version and source hash match the workspace's pinned nixpkgs GMP.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package gmpSource:
  versions:
    "6.3.0":
      sourceRevision = "6.3.0"
      sourceUrl = "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.bz2"
      sourceRepository = "https://gmplib.org/repo/gmp"

  fetch:
    url: "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.bz2"
    sha256: "ac28211a7cfb609bae2e2c8d6058d66c8fe96434f740cf6fe2e47b000d1c20cb"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"
    ## GMP preprocesses architecture-specific assembly with GNU m4.
    "m4"

  config:
    discard

  library libGmp:
    ## libgmp.so provides the integer primitives consumed by Nettle.
    discard

  build:
    setCurrentOwningPackageOverride("gmpSource")
    try:
      let opts = @[
        "--disable-static",
        "--enable-shared",
        "--with-pic",
        "--enable-fat",
        "--build=x86_64-unknown-linux-gnu",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.library("libGmp")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## libgmp has no external runtime library beyond libc.
    discard
