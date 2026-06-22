## Source-from-tarball kscreen recipe — M9.R.15q.11.4 Plasma cascade
## module. We build the lower-level ``libkscreen-6.2.5.tar.xz`` (the
## libKF6Screen.so multi-monitor-config library plasma-workspace +
## kscreenlocker + kwin all link against), NOT the higher-level
## kscreen-6.2.5.tar.xz (the System Settings KCM which needs
## qt6-sensors + Plasma + PlasmaQuick + LayerShellQt + libkscreen). The
## recipe directory keeps the canonical ``kscreen`` name so the dep
## declarations on plasma-workspace (``"kscreen >=6.0"``) match the
## same recipe-dir lookup pattern ksysguard uses (recipe dir named
## ``ksysguard`` while tarball is ``libksysguard-6.2.5.tar.xz``).
##
## sha256 = 5edaf6fa2eed6ddcef4bc479f4bb15d3481acb60adf0150e9f9a1382607bbcb8

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kscreenSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/libkscreen-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/libkscreen"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/libkscreen-6.2.5.tar.xz"
    sha256: "5edaf6fa2eed6ddcef4bc479f4bb15d3481acb60adf0150e9f9a1382607bbcb8"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    "qt6-wayland >=6.6"
    "wayland"
    "wayland-scanner"
    "wayland-protocols"
    "plasma-wayland-protocols >=1.14"
    "libxkbcommon"
    ## X11 + XCB transitives for the X11 backend probe (RANDR + DPMS).
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

  library libKF6Screen:
    discard

  library libKF6ScreenDpms:
    discard

  build:
    setCurrentOwningPackageOverride("kscreenSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Screen")
      discard pkg.library("libKF6ScreenDpms")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
