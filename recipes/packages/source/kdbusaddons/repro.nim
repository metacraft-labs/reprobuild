## Source-from-tarball kdbusaddons recipe — M9.R.15h.7 KF6 cascade
## module. kdbusaddons is Tier-1 KDE Frameworks: addons to QtDBus
## (KDBusService, KSignalHandler-D-Bus bridge) needed by KIO's
## kioworker registry + Plasma's startup orchestrator.
##
## sha256 = e88bfaa6a10f80d9f7b2116281c4485213984caed555ac68557bb53ee88bbb32
## (upstream SHA256 from download.kde.org/stable/frameworks/6.10/
##  kdbusaddons-6.10.0.tar.xz.sha256).

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kdbusaddonsSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kdbusaddons-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kdbusaddons"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kdbusaddons-6.10.0.tar.xz"
    sha256: "e88bfaa6a10f80d9f7b2116281c4485213984caed555ac68557bb53ee88bbb32"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "extra-cmake-modules >=6.0"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "qt6-base >=6.6"
    "qt6-tools >=6.6"

  config:
    discard

  library libKF6DBusAddons:
    discard

  build:
    setCurrentOwningPackageOverride("kdbusaddonsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6DBusAddons")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
