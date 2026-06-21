## Source-from-tarball kpackage recipe — M9.R.15h.11 KF6 cascade
## module. kpackage is Tier-3 KDE Frameworks: package loader for
## QML / Plasma applets (kpackagetool6, KPackage::Package*),
## consumed by Plasma's wallpaper / applet host + ksvg.
##
## sha256 = 0f49c1cdb49e01c6dce372abbc9814ccbd74b7f2b130c7310674345e3498cec1
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kpackage-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kpackageSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kpackage-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kpackage"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kpackage-6.10.0.tar.xz"
    sha256: "0f49c1cdb49e01c6dce372abbc9814ccbd74b7f2b130c7310674345e3498cec1"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "extra-cmake-modules >=6.0"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kcoreaddons >=6.0"
    "kconfig >=6.0"
    "ki18n >=6.0"
    "karchive >=6.0"

  config:
    discard

  library libKF6Package:
    discard

  build:
    setCurrentOwningPackageOverride("kpackageSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Package")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
