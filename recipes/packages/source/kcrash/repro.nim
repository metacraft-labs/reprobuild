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
    ## M9.R.15p.0.2 — libxkbcommon + mesa are auto-injected by the
    ## package macro for every qt6-* consumer (see
    ## ``m9r15pAutoInjectQt6Transitive`` in macros_a.nim); the explicit
    ## per-recipe declarations M9.R.15n.3 added are retired.

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
