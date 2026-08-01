import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libpslSource:
  versions:
    "0.21.5":
      sourceRevision = "0.21.5"
      sourceUrl = "https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz"
      sourceRepository = "https://github.com/rockdaboot/libpsl"
  fetch:
    url: "https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz"
    sha256: "1dcc9ceae8b128f3c0b3f654decd0e1e891afc6ff81098f227ef260449dae208"
    extractStrip: 1
  nativeBuildDeps:
    "meson >=0.60"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
    "python3"
  config:
    discard
  library libPsl:
    discard
  build:
    setCurrentOwningPackageOverride("libpslSource")
    try:
      let pkg = meson_package(srcDir = "./src", configureOptions = @[
        "runtime=no", "builtin=true", "docs=false", "tests=false",
      ])
      discard pkg.library("libPsl")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
