import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package icuSource:
  versions:
    "76.1":
      sourceRevision = "release-76-1"
      sourceUrl = "https://github.com/unicode-org/icu/releases/download/release-76-1/icu4c-76_1-src.tgz"
      sourceRepository = "https://github.com/unicode-org/icu"
  fetch:
    url: "https://github.com/unicode-org/icu/releases/download/release-76-1/icu4c-76_1-src.tgz"
    sha256: "dfacb46bfe4747410472ce3e1144bf28a102feeaa4e3875bac9b4c6cf30f4f3e"
    extractStrip: 1
  nativeBuildDeps:
    "gcc >=11"
    "make"
    "pkg-config"
  config:
    discard
  library libIcuUc:
    discard
  library libIcuI18n:
    discard
  library libIcuData:
    discard
  build:
    setCurrentOwningPackageOverride("icuSource")
    try:
      let pkg = autotools_package(srcDir = "./src/source",
        configureOptions = @[
          "--disable-static",
          "--enable-shared",
          "--disable-samples",
          "--disable-tests",
          "--disable-extras",
        ])
      discard pkg.library("libIcuUc")
      discard pkg.library("libIcuI18n")
      discard pkg.library("libIcuData")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
