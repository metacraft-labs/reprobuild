import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libjpegSource:
  versions:
    "3.0.4":
      sourceRevision = "3.0.4"
      sourceUrl = "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.0.4.tar.gz"
      sourceRepository = "https://github.com/libjpeg-turbo/libjpeg-turbo"
  fetch:
    url: "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/3.0.4.tar.gz"
    sha256: "0270f9496ad6d69e743f1e7b9e3e9398f5b4d606b6a47744df4b73df50f62e38"
    extractStrip: 1
  nativeBuildDeps:
    "cmake >=3.9"
    "ninja >=1.10"
    "gcc >=11"
    "nasm"
  config:
    discard
  library libjpeg:
    discard
  library libturbojpeg:
    discard
  build:
    setCurrentOwningPackageOverride("libjpegSource")
    try:
      let pkg = cmake_package(srcDir = "./src", generator = "Ninja",
        cacheVars = @[
          "ENABLE_STATIC=OFF",
          "ENABLE_SHARED=ON",
          "WITH_JAVA=OFF",
          "WITH_TURBOJPEG=ON",
          "CMAKE_BUILD_TYPE=Release",
        ], allowSourceWrites = true)
      discard pkg.library("libjpeg")
      discard pkg.library("libturbojpeg")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    discard
