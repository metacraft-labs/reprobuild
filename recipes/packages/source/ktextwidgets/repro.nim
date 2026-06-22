## Source-from-tarball ktextwidgets recipe — M9.R.15q.10.3 KF6 cascade
## module. ktextwidgets is Tier-2 KDE Frameworks: the
## ``libKF6TextWidgets.so`` widget toolkit text editor extensions
## (rich-text edit + spell-check overlays). Required by
## plasma-workspace's umbrella probe.
##
## sha256 = 4db67be70da68e3fd2c2a9d3359dcfb9b11eb82a34f2b88d3e6ed08e358ab073

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package ktextwidgetsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/ktextwidgets-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/ktextwidgets"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/ktextwidgets-6.10.0.tar.xz"
    sha256: "4db67be70da68e3fd2c2a9d3359dcfb9b11eb82a34f2b88d3e6ed08e358ab073"
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
    "kconfigwidgets >=6.0"
    "kcompletion >=6.0"
    "sonnet >=6.0"
    ## M9.R.15q.10.5 — X11 transitive.
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

  library libKF6TextWidgets:
    discard

  build:
    setCurrentOwningPackageOverride("ktextwidgetsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6TextWidgets")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
