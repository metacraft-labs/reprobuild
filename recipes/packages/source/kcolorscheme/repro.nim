## Source-from-tarball kcolorscheme recipe — M9.R.15j.4 KF6 cascade
## module. kcolorscheme is a Tier-3 KDE Frameworks module supplying KF6
## color-palette helpers (KColorScheme, KStatefulBrush) that
## kconfigwidgets + kxmlgui + Plasma System Settings consume.
##
## sha256 = f070ed593f1d4010af5a56e247532be96a2c7ca9befc922b084c16215af79bdf
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kcolorscheme-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kcolorschemeSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kcolorscheme-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kcolorscheme"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kcolorscheme-6.10.0.tar.xz"
    sha256: "f070ed593f1d4010af5a56e247532be96a2c7ca9befc922b084c16215af79bdf"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kconfig >=6.0"
    "kguiaddons >=6.0"
    "ki18n >=6.0"

  config:
    discard

  library libKF6ColorScheme:
    discard

  build:
    setCurrentOwningPackageOverride("kcolorschemeSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6ColorScheme")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
