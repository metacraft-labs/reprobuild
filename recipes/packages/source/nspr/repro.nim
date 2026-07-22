import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package nsprSource:
  versions:
    "4.36":
      sourceRevision = "NSPR_4_36_RTM"
      sourceUrl = "https://archive.mozilla.org/pub/nspr/releases/v4.36/src/nspr-4.36.tar.gz"
      sourceRepository = "https://hg.mozilla.org/projects/nspr"
  fetch:
    url: "https://archive.mozilla.org/pub/nspr/releases/v4.36/src/nspr-4.36.tar.gz"
    sha256: "55dec317f1401cd2e5dba844d340b930ab7547f818179a4002bce62e6f1c6895"
    extractStrip: 1
  nativeBuildDeps:
    "gcc >=11"
    "make"
  config:
    discard
  library libNspr4:
    discard
  library libPlc4:
    discard
  library libPlds4:
    discard
  build:
    setCurrentOwningPackageOverride("nsprSource")
    try:
      let pkg = autotools_package(srcDir = "./src/nspr", configureOptions = @[
        "--enable-64bit", "--with-pthreads", "--enable-optimize=-O2",
      ])
      discard pkg.library("libNspr4")
      discard pkg.library("libPlc4")
      discard pkg.library("libPlds4")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
