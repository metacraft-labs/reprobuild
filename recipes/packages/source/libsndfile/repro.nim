## Source build for libsndfile, used by the PulseAudio client libraries.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package libsndfileSource:
  versions:
    "1.2.2":
      sourceRevision = "1.2.2"
      sourceUrl = "https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz"
      sourceRepository = "https://github.com/libsndfile/libsndfile.git"

  fetch:
    url: "https://github.com/libsndfile/libsndfile/releases/download/1.2.2/libsndfile-1.2.2.tar.xz"
    sha256: "3799ca9924d3125038880367bf1468e53a1b7e3686a934f098b7e1d286cdb80e"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"
    "pkg-config"

  config:
    discard

  library libSndFile:
    discard

  build:
    setCurrentOwningPackageOverride("libsndfileSource")
    try:
      let opts = @[
        "BUILD_SHARED_LIBS=ON",
        "BUILD_TESTING=OFF",
        "BUILD_PROGRAMS=OFF",
        "BUILD_EXAMPLES=OFF",
        "ENABLE_EXTERNAL_LIBS=OFF",
        "ENABLE_MPEG=OFF",
        "ENABLE_CPACK=OFF",
        "ENABLE_PACKAGE_CONFIG=ON",
        "CMAKE_BUILD_TYPE=Release",
        "CMAKE_POLICY_VERSION_MINIMUM=3.5",
      ]
      let pkg = cmake_package(srcDir = "./src", generator = "Ninja",
        cacheVars = opts, allowSourceWrites = true)
      discard pkg.library("libSndFile")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
