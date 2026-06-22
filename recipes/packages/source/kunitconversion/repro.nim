## Source-from-tarball kunitconversion recipe — M9.R.15q.10.3 KF6
## cascade module. kunitconversion is Tier-1 KDE Frameworks: unit /
## currency conversion (``libKF6UnitConversion.so``).
##
## sha256 = 23c59904d48049deb8f1de8aa56e7b0c10a9fc82808f36a32f4f446433869dbf

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kunitconversionSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kunitconversion-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kunitconversion"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kunitconversion-6.10.0.tar.xz"
    sha256: "23c59904d48049deb8f1de8aa56e7b0c10a9fc82808f36a32f4f446433869dbf"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "ki18n >=6.0"

  config:
    discard

  library libKF6UnitConversion:
    discard

  build:
    setCurrentOwningPackageOverride("kunitconversionSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6UnitConversion")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
