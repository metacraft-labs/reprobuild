import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libtiffSource:
  versions:
    "4.7.0":
      sourceRevision = "v4.7.0"
      sourceUrl = "https://gitlab.com/libtiff/libtiff/-/archive/v4.7.0/libtiff-v4.7.0.tar.gz"
      sourceRepository = "https://gitlab.com/libtiff/libtiff"
  fetch:
    url: "https://gitlab.com/libtiff/libtiff/-/archive/v4.7.0/libtiff-v4.7.0.tar.gz"
    sha256: "e1d49a419f812cb81626a0c4b2bf0f13c10710fc329284dc9b6dad75b75764bc"
    extractStrip: 1
  nativeBuildDeps:
    "cmake >=3.9"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"
  buildDeps:
    "libjpeg"
    "xz"
    "zlib"
    "zstd"
  config:
    discard
  library libtiff:
    discard
  build:
    setCurrentOwningPackageOverride("libtiffSource")
    try:
      let pkg = cmake_package(srcDir = "./src", generator = "Ninja",
        cacheVars = @[
          "BUILD_SHARED_LIBS=ON",
          "tiff-tests=OFF",
          "tiff-docs=OFF",
          "lerc=OFF",
          "libdeflate=OFF",
          "webp=OFF",
          "CMAKE_BUILD_TYPE=Release",
        ], allowSourceWrites = true)
      discard pkg.library("libtiff")
    finally:
      clearCurrentOwningPackageOverride()
  runtimeDeps:
    "libjpeg"
    "xz"
    "zlib"
    "zstd"
