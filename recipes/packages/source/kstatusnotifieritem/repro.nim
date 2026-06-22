## Source-from-tarball kstatusnotifieritem recipe — M9.R.15q.10.3 KF6
## cascade module. kstatusnotifieritem is Tier-2 KDE Frameworks: the
## system-tray notifier item D-Bus client / server
## (``libKF6StatusNotifierItem.so``).
##
## sha256 = 4fa19843a737b43674d19b9ad31466c6aa64bbe27709073c3e2c33aa03bfac22

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kstatusnotifieritemSource:
  versions:
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/kstatusnotifieritem-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/kstatusnotifieritem"

  fetch:
    url: "https://download.kde.org/stable/frameworks/6.10/kstatusnotifieritem-6.10.0.tar.xz"
    sha256: "4fa19843a737b43674d19b9ad31466c6aa64bbe27709073c3e2c33aa03bfac22"
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
    "knotifications >=6.0"
    "kwindowsystem >=6.0"

  config:
    discard

  library libKF6StatusNotifierItem:
    discard

  build:
    setCurrentOwningPackageOverride("kstatusnotifieritemSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6StatusNotifierItem")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
