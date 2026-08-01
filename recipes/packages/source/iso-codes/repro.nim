import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package isoCodesSource:
  versions:
    "4.18.0":
      sourceRevision = "v4.18.0"
      sourceUrl = "https://salsa.debian.org/iso-codes-team/iso-codes/-/archive/v4.18.0/iso-codes-v4.18.0.tar.gz"
      sourceRepository = "https://salsa.debian.org/iso-codes-team/iso-codes"

  fetch:
    url: "https://salsa.debian.org/iso-codes-team/iso-codes/-/archive/v4.18.0/iso-codes-v4.18.0.tar.gz"
    sha256: "511f67bf4b51aa77f17c45adbff533242b50f1e370fe49a5706b6341902fac87"
    extractStrip: 1

  nativeBuildDeps:
    "sh"
    "make"
    "gettext"

  buildDeps:
    discard

  config:
    discard

  build:
    setCurrentOwningPackageOverride("isoCodesSource")
    try:
      let pkg = autotools_package(srcDir = "./src")
      pkg.installTreeMirror()
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
