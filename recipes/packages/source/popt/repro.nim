## From-source recipe for popt, the command-line option parser used by
## sgdisk.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package poptSource:
  versions:
    "1.19":
      sourceRevision = "popt-1.19"
      sourceUrl = "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz"
      sourceRepository = "https://github.com/rpm-software-management/popt"

  fetch:
    url: "https://ftp.osuosl.org/pub/rpm/popt/releases/popt-1.x/popt-1.19.tar.gz"
    sha256: "c25a4838fc8e4c1c8aacb8bd620edb3084a3d63bf8987fdad3ca2758c63240f9"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"
    "pkg-config"

  config:
    discard

  library libPopt:
    discard

  build:
    setCurrentOwningPackageOverride("poptSource")
    try:
      let pkg = autotools_package(
        srcDir = "./src",
        configureOptions = @["--disable-static"],
      )
      discard pkg.library("libPopt")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
