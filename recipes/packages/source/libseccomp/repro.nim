import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libseccompSource:
  versions:
    "2.6.0":
      sourceRevision = "v2.6.0"
      sourceUrl = "https://github.com/seccomp/libseccomp/releases/download/v2.6.0/libseccomp-2.6.0.tar.gz"
      sourceRepository = "https://github.com/seccomp/libseccomp"
  fetch:
    url: "https://github.com/seccomp/libseccomp/releases/download/v2.6.0/libseccomp-2.6.0.tar.gz"
    sha256: "83b6085232d1588c379dc9b9cae47bb37407cf262e6e74993c61ba72d2a784dc"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "gperf"
  config:
    discard
  library libseccomp:
    discard
  build:
    setCurrentOwningPackageOverride("libseccompSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "--disable-static", "--enable-shared",
      ])
      discard pkg.library("libseccomp")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
