## Source-from-tarball kcodecs recipe — M9.R.15j.2 KF6 cascade module.
## kcodecs is a Tier-3 KDE Frameworks module supplying KF6 text-encoding
## helpers (KCharsets, KCodecs, KEmailAddress) used by kcompletion +
## kdoctools + kio + KMail + plasma-workspace.
##
## sha256 = 96183ffbb18502cd67b6fc78ac286e233ef46ee0d713ee1df2cb4c138f2141a0
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kcodecs-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kcodecsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kcodecs-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kcodecs"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kcodecs-6.10.0.tar.xz"
    sha256: "96183ffbb18502cd67b6fc78ac286e233ef46ee0d713ee1df2cb4c138f2141a0"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"

  config:
    discard

  library libKF6Codecs:
    discard

  build:
    setCurrentOwningPackageOverride("kcodecsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Codecs")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
