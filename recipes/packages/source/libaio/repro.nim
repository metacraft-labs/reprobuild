import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libaioSource:
  versions:
    "0.3.113":
      sourceRevision = "libaio-0.3.113"
      sourceUrl = "https://pagure.io/libaio/archive/libaio-0.3.113/libaio-libaio-0.3.113.tar.gz"
      sourceRepository = "https://pagure.io/libaio"
  fetch:
    url: "https://pagure.io/libaio/archive/libaio-0.3.113/libaio-libaio-0.3.113.tar.gz"
    sha256: "716c7059703247344eb066b54ecbc3ca2134f0103307192e6c2b7dab5f9528ab"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
  config:
    discard
  library libaio:
    discard
  build:
    setCurrentOwningPackageOverride("libaioSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "prefix=/usr", "libdir=/usr/lib",
      ], skipConfigure = true)
      discard pkg.library("libaio")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
