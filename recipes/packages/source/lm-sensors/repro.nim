import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package lmSensorsSource:
  versions:
    "3.6.0":
      sourceRevision = "V3-6-0"
      sourceUrl = "https://github.com/lm-sensors/lm-sensors/archive/refs/tags/V3-6-0.tar.gz"
      sourceRepository = "https://github.com/lm-sensors/lm-sensors"
  fetch:
    url: "https://github.com/lm-sensors/lm-sensors/archive/refs/tags/V3-6-0.tar.gz"
    sha256: "0591f9fa0339f0d15e75326d0365871c2d4e2ed8aa1ff759b3a55d3734b7d197"
    extractStrip: 1
  nativeBuildDeps:
    "make"
    "gcc >=11"
    "bison"
    "flex"
    "perl"
  config:
    discard
  library libsensors:
    discard
  executable sensors:
    discard
  build:
    setCurrentOwningPackageOverride("lmSensorsSource")
    try:
      let pkg = autotools_package(srcDir = "./src", configureOptions = @[
        "PREFIX=/usr",
        "BINDIR=/usr/bin",
        "SBINDIR=/usr/bin",
        "LIBDIR=/usr/lib",
        "INCLUDEDIR=/usr/include",
        "MANDIR=/usr/share/man",
        "ETCDIR=/etc",
      ], skipConfigure = true)
      discard pkg.library("libsensors")
      discard pkg.executable("sensors")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
