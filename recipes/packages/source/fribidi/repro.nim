import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package fribidiSource:
  versions:
    "1.0.16":
      sourceRevision = "v1.0.16"
      sourceUrl = "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz"
      sourceRepository = "https://github.com/fribidi/fribidi"

  fetch:
    url: "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz"
    sha256: "1b1cde5b235d40479e91be2f0e88a309e3214c8ab470ec8a2744d82a5a9ea05c"
    extractStrip: 1

  nativeBuildDeps:
    "meson >=0.64"
    "ninja >=1.10"
    "gcc >=11"
    "python3"

  config:
    discard

  library fribidi:
    discard

  build:
    setCurrentOwningPackageOverride("fribidiSource")
    try:
      let pkg = meson_package(
        srcDir = "./src",
        configureOptions = @[
          "libdir=lib",
          "docs=false",
          "tests=false",
          "bin=true",
        ])
      discard pkg.library("fribidi")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
