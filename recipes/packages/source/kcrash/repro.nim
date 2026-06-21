## Source-from-tarball kcrash recipe — M9.R.15h.6 KF6 cascade
## module. kcrash is Tier-2 KDE Frameworks: application-crash
## analysis + DrKonqi launcher integration, consumed by KIO_KIO
## sessions + every Plasma binary that opts into crash reporting.
##
## sha256 = c0329da6ac28aaac824db235e578999e4a487e5cedbb3cec3a6a39e9ee9b5db4
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kcrash-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kcrashSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kcrash-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kcrash"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kcrash-6.10.0.tar.xz"
    sha256: "c0329da6ac28aaac824db235e578999e4a487e5cedbb3cec3a6a39e9ee9b5db4"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kcoreaddons >=6.0"
    ## M9.R.15n.3 — Qt6Gui's CMake config calls find_dependency(XKB)
    ## via its Qt6GuiDependencies.cmake. The FindXKB.cmake module lives
    ## at qt6-base/.../lib/cmake/Qt6/3rdparty/kwin/FindXKB.cmake and
    ## uses pkg-config to locate libxkbcommon. Without libxkbcommon as
    ## a transitive buildDep the convention's PKG_CONFIG_PATH wiring
    ## doesn't include xkbcommon's pkgconfig dir, so the FindXKB probe
    ## fails and Qt6Gui itself comes back "not found" — even though
    ## Qt6GuiConfig.cmake exists. mesa supplies GLESv2 via the same
    ## channel.
    "libxkbcommon >=1.5"
    "mesa >=23.3"

  config:
    discard

  library libKF6Crash:
    discard

  build:
    setCurrentOwningPackageOverride("kcrashSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # WITH_X11=OFF: kcrash's X11 backend reads the WM SM_CLIENT_ID
        # property to forward the DrKonqi target; v1 is Wayland-only so
        # the X11 path is unused.
        "WITH_X11=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Crash")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
