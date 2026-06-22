## Source-from-tarball prison recipe — M9.R.15q.10.3 KF6 cascade
## module. prison is Tier-2 KDE Frameworks: the barcode rendering
## library (``libKF6Prison.so``) — used by Plasma's "share via QR
## code" widget.
##
## Note: the upstream tarball is named ``prison-6.10.0.tar.xz`` (no
## ``k`` prefix) but the dep is conventionally spelled ``kprison``
## in our recipe registry (matching the stdlib stub at
## ``libs/repro_dsl_stdlib/.../packages/kprison.nim``); this recipe
## lives under ``recipes/packages/source/kprison/`` so the directory
## name aligns with the dep declarations on plasma-workspace.
##
## sha256 = b4a0f395eca50c818f8e0656b04664783453b1a9a709a4a45a8ae2e273602c7b

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kprisonSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/prison-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/prison"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/prison-6.10.0.tar.xz"
    sha256: "b4a0f395eca50c818f8e0656b04664783453b1a9a709a4a45a8ae2e273602c7b"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-declarative >=6.6"
    ## M9.R.15q.10.7d — kprison's CMakeLists declares
    ## ``find_package(QRencode REQUIRED)`` (QR code generation).
    "qrencode"

  config:
    discard

  library libKF6Prison:
    discard

  build:
    setCurrentOwningPackageOverride("kprisonSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15q.10.7c — disable barcode-scanner (Qt6Multimedia). v1
        # ships the BARCODE GENERATOR side only (which plasma's "share
        # via QR code" widget consumes); the scanner needs camera+
        # multimedia plumbing we don't ship from-source.
        "WITH_MULTIMEDIA=OFF",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Prison")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
