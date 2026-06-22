## Source-from-tarball kscreen recipe — M9.R.15q.11.4 Plasma cascade
## module. ``kscreen-6.2.5.tar.xz`` is the upstream tarball for
## ``libkscreen`` (the project + tarball name is ``kscreen`` for the
## main system-settings module; the lower-level multi-monitor config
## library inside ships as ``libKF6Screen.so`` providing
## ``KF6Screen`` cmake-config). kwin, plasma-workspace + kscreenlocker
## all link against libKF6Screen for monitor enumeration + per-output
## config.
##
## sha256 = 6237c47fe70384d10e6f20d7f058c6aacca51a493da928077fcec91b0ef69642

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kscreenSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/kscreen-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/libkscreen"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/kscreen-6.2.5.tar.xz"
    sha256: "6237c47fe70384d10e6f20d7f058c6aacca51a493da928077fcec91b0ef69642"
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
