## Source-from-tarball karchive recipe — M9.R.15h.2 KF6 cascade
## module. karchive is Tier-1 KDE Frameworks: Qt-based file
## compression / archive (tar / zip / 7z / xz / gzip) classes that
## KIO + Plasma's package loader consume.
##
## sha256 = ac5160c19dd110bbdadeba9c5355cbfd3b5c1bd00ce3dbdc4a085776698c8a48
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  karchive-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package karchiveSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/karchive-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/karchive"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/karchive-6.10.0.tar.xz"
    sha256: "ac5160c19dd110bbdadeba9c5355cbfd3b5c1bd00ce3dbdc4a085776698c8a48"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "zlib >=1.2"

  config:
    discard

  library libKF6Archive:
    discard

  build:
    setCurrentOwningPackageOverride("karchiveSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Archive")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
