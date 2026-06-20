## Source-from-tarball kbookmarks recipe — M9.R.15h.8 KF6 cascade
## module. kbookmarks is Tier-3 KDE Frameworks: bookmark storage +
## XBEL format parser, consumed by KIO file dialogs + Dolphin /
## Konqueror place panels.
##
## sha256 = 891eb12d2b9a2c3cdfbfdba250599c544d7186ce8d1ef07f4fc4cce1d57a945b
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kbookmarks-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kbookmarksSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kbookmarks-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kbookmarks"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kbookmarks-6.10.0.tar.xz"
    sha256: "891eb12d2b9a2c3cdfbfdba250599c544d7186ce8d1ef07f4fc4cce1d57a945b"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "kcoreaddons >=6.0"
    "kconfig >=6.0"
    "kwidgetsaddons >=6.0"
    # NOTE: kbookmarks's CMakeLists also probes for KF6IconThemes +
    # KF6CodecsView at configure but BUILD_TESTING=OFF skips the
    # consumers; the runtime artifact only needs Config + Widgets +
    # CoreAddons. Avoid declaring kxmlgui here because kxmlgui consumes
    # kio which consumes kbookmarks (cyclic).

  config:
    discard

  library libKF6Bookmarks:
    discard

  build:
    setCurrentOwningPackageOverride("kbookmarksSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Bookmarks")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
