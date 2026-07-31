## Source build for GNU MPC, GCC's multiple-precision complex-number
## dependency. Version and source hash match the pinned stdlib package.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package mpcSource:
  versions:
    "1.4.0":
      sourceRevision = "1.4.0"
      sourceUrl = "https://ftp.gnu.org/gnu/mpc/mpc-1.4.0.tar.xz"
      sourceRepository = "https://gitlab.inria.fr/mpc/mpc"

  fetch:
    url: "https://ftp.gnu.org/gnu/mpc/mpc-1.4.0.tar.xz"
    sha256: "3210b3a546b1cb00c296ca360891d7740ee6ff06deb02a27a35b20cd3c0bb1a5"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"

  buildDeps:
    "gmp"
    "mpfr"

  config:
    discard

  library libMpc:
    discard

  build:
    setCurrentOwningPackageOverride("mpcSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static",
        "--enable-shared",
        "--with-pic",
      ])
      discard pkg.library("libMpc")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "gmp"
    "mpfr"
