## Source-built strace for ReproOS installation diagnostics.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package straceSource:
  versions:
    "6.16":
      sourceRevision = "v6.16"
      sourceUrl = "https://strace.io/files/6.16/strace-6.16.tar.xz"
      sourceRepository = "https://github.com/strace/strace"

  fetch:
    url: "https://strace.io/files/6.16/strace-6.16.tar.xz"
    sha256: "3d7aee7e4f044b2f67f3d51a8a76eda18076e9fb2774de54ac351d777d4ebffa"
    extractStrip: 1

  nativeBuildDeps:
    "make"
    "gcc >=11"

  buildDeps:
    "linux-headers >=4.19"

  config:
    discard

  executable strace:
    discard

  build:
    setCurrentOwningPackageOverride("straceSource")
    try:
      let opts = @[
        "--enable-mpers=no",
        "--disable-gcc-Werror",
      ]
      let pkg = autotools_package(srcDir = "./src", configureOptions = opts)
      discard pkg.executable("strace")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
