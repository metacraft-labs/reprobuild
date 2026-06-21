## Source-from-tarball kguiaddons recipe — M9.R.15h.3 KF6 cascade
## module. kguiaddons is Tier-1 KDE Frameworks: GUI extensions on
## top of QtGui (QColor + QFont + QClipboard helpers, KIconUtils,
## KModifierKeyInfo, KSystemClipboard) every KF6 GUI module needs.
##
## sha256 = b3be04077313e559c5a8f66491d5d286cefe947aaf7c8937544ce85af4853ffa
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kguiaddons-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kguiaddonsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kguiaddons-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kguiaddons"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kguiaddons-6.10.0.tar.xz"
    sha256: "b3be04077313e559c5a8f66491d5d286cefe947aaf7c8937544ce85af4853ffa"
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

  library libKF6GuiAddons:
    discard

  build:
    setCurrentOwningPackageOverride("kguiaddonsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # WITH_WAYLAND=OFF: kguiaddons would link against wayland-client
        # for KWaylandExtras (color-picker + screenshot proxies); v1
        # closure has wayland from-source but enabling here adds a
        # transitive link surface we don't need for the cascade.
        "WITH_WAYLAND=OFF",
        # WITH_X11=OFF: drop XLib dep. KGuiAddons's X11 backend handles
        # legacy WMs; v1 is Wayland-only.
        "WITH_X11=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6GuiAddons")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
