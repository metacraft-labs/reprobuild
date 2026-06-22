## Source-from-tarball kscreenlocker recipe — M9.R.15q.11.5 Plasma
## cascade module. kscreenlocker is the Plasma lock-screen daemon
## kwin's session-lifecycle hooks invoke at lock time. Ships
## ``libKScreenLocker.so`` (the lock-frame UI + greeter plumbing) +
## ``ksmserver-logout-greeter`` + ``ksmserver-switchuser-greeter`` +
## ``kscreenlocker_greet`` executables.
##
## sha256 = 3a3ed2d040394dc2a80cf25cdd2a6c4022146aca54e72c44af16e8982e8b8e4e

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kscreenlockerSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/kscreenlocker-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kscreenlocker"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/kscreenlocker-6.2.5.tar.xz"
    sha256: "3a3ed2d040394dc2a80cf25cdd2a6c4022146aca54e72c44af16e8982e8b8e4e"
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
    "qt6-wayland >=6.6"
    ## KF6 umbrella components.
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "kcrash >=6.0"
    "kcmutils >=6.0"
    "kio >=6.0"
    "kglobalaccel >=6.0"
    "ki18n >=6.0"
    "kidletime >=6.0"
    "knotifications >=6.0"
    "ksolid >=6.0"
    "kwindowsystem >=6.0"
    "kxmlgui >=6.0"
    "ksvg >=6.0"
    "kdeclarative >=6.0"
    ## Plasma framework + sibling Plasma modules.
    "plasma-framework >=6.0"
    "kscreen >=6.0"
    "layer-shell-qt >=6.0"
    ## Wayland.
    "wayland"
    "wayland-scanner"
    "wayland-protocols"
    "libxkbcommon"
    ## X11 + XCB transitives (Plasma's lock screen probes XCB + XTEST).
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
    ## PAM for authentication.
    "pam"

  config:
    discard

  library libKScreenLocker:
    discard

  executable kscreenlocker_greet:
    discard

  build:
    setCurrentOwningPackageOverride("kscreenlockerSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKScreenLocker")
      discard pkg.executable("kscreenlocker_greet")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
