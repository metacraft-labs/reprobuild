## Source build for GNU MPFR, GCC's multiple-precision floating-point
## dependency. Version and source hash match the pinned stdlib package.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package mpfrSource:
  versions:
    "4.2.2":
      sourceRevision = "4.2.2"
      sourceUrl = "https://www.mpfr.org/mpfr-4.2.2/mpfr-4.2.2.tar.xz"
      sourceRepository = "https://gitlab.inria.fr/mpfr/mpfr"

  fetch:
    url: "https://www.mpfr.org/mpfr-4.2.2/mpfr-4.2.2.tar.xz"
    sha256: "b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01"
    extractStrip: 1

  nativeBuildDeps:
    "autoconf"
    "automake"
    "libtool"
    "make"
    "gcc >=11"

  buildDeps:
    "gmp"

  config:
    discard

  library libMpfr:
    discard

  build:
    setCurrentOwningPackageOverride("mpfrSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static",
        "--enable-shared",
        "--with-pic",
      ])
      discard pkg.library("libMpfr")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    "gmp"
