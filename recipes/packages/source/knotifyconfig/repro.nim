## Source-from-tarball knotifyconfig recipe — M9.R.15q.10.3 KF6 cascade
## module. knotifyconfig is Tier-2 KDE Frameworks: the KCM-style
## notification configuration UI library (``libKF6NotifyConfig.so``).
##
## sha256 = f0ba447a58edefd8302905ed88030291990e273eded97d11d2b7de986a35d05c

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package knotifyconfigSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/knotifyconfig-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/knotifyconfig"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/knotifyconfig-6.10.0.tar.xz"
    sha256: "f0ba447a58edefd8302905ed88030291990e273eded97d11d2b7de986a35d05c"
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
    "kconfig >=6.0"
    "kcompletion >=6.0"
    "kio >=6.0"

  config:
    discard

  library libKF6NotifyConfig:
    discard

  build:
    setCurrentOwningPackageOverride("knotifyconfigSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6NotifyConfig")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
