## Source-from-tarball plasma5support recipe — M9.R.15q.10.8 Plasma
## cascade module. plasma5support is the Plasma 5 -> 6 compatibility
## shim (``libPlasma5Support.so``).
##
## sha256 = cac5244aa2961ad020ed2c43427389e0823482ecb179948b5fd6b221606e8b04

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package plasma5supportSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/plasma5support-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/plasma5support"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/plasma5support-6.2.5.tar.xz"
    sha256: "cac5244aa2961ad020ed2c43427389e0823482ecb179948b5fd6b221606e8b04"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "qt6-declarative >=6.6"
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "ki18n >=6.0"
    "kservice >=6.0"
    "kpackage >=6.0"
    "kio >=6.0"
    "knotifications >=6.0"
    "kxmlgui >=6.0"
    "kguiaddons >=6.0"
    "kwidgetsaddons >=6.0"
    "kwindowsystem >=6.0"
    ## X11 transitives.
    "xorgproto"
    "libx11"
    "libxcb"
    "libxau"
    "libxdmcp"
    "xcb-util-keysyms"
    "xcb-util-wm"
    "libxext"
    "libxfixes"
    "libxrender"

  config:
    discard

  library libPlasma5Support:
    discard

  build:
    setCurrentOwningPackageOverride("plasma5supportSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libPlasma5Support")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
