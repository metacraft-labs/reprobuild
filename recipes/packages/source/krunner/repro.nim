## Source-from-tarball krunner recipe — M9.R.15q.10.3 KF6 cascade
## module. krunner is Tier-2 KDE Frameworks: the in-process runner
## framework (``libKF6Runner.so``).
##
## sha256 = 459c97ad510c3565d4547b51c4dbaf19b3834c0afdf77bf6ee4dff346957d62b

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package krunnerSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/krunner-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/krunner"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/krunner-6.10.0.tar.xz"
    sha256: "459c97ad510c3565d4547b51c4dbaf19b3834c0afdf77bf6ee4dff346957d62b"
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
    "ki18n >=6.0"
    "kcoreaddons >=6.0"
    "kconfig >=6.0"
    "kitemmodels >=6.0"
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

  library libKF6Runner:
    discard

  build:
    setCurrentOwningPackageOverride("krunnerSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Runner")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
