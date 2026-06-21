## Source-from-tarball kconfigwidgets recipe — M9.R.15j.4 KF6 cascade
## module. kconfigwidgets is a Tier-3 KDE Frameworks module supplying
## KF6 widgets for configuration dialogs (KColorScheme, KConfigDialog,
## KCommandBar) that kxmlgui + Plasma System Settings consume.
##
## sha256 = 5cb17bcafaae3eefc144fb1014f14cb9998c9e13b714808d940ab20d9c0fb51c
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kconfigwidgets-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kconfigwidgetsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kconfigwidgets-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kconfigwidgets"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kconfigwidgets-6.10.0.tar.xz"
    sha256: "5cb17bcafaae3eefc144fb1014f14cb9998c9e13b714808d940ab20d9c0fb51c"
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
    "kcoreaddons >=6.0"
    "kcodecs >=6.0"
    "kguiaddons >=6.0"
    "ki18n >=6.0"
    "kwidgetsaddons >=6.0"
    "kcolorscheme >=6.0"

  config:
    discard

  library libKF6ConfigWidgets:
    discard

  build:
    setCurrentOwningPackageOverride("kconfigwidgetsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6ConfigWidgets")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
