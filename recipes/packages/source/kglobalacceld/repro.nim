## Source-from-tarball kglobalacceld recipe — M9.R.15q.11.2 Plasma
## cascade module. kglobalacceld is the Plasma global-accelerator
## daemon kwin's global-shortcut surface connects to via D-Bus. It
## ships the standalone ``kglobalacceld`` executable + the
## ``libKF6GlobalAccelD.so`` plugin library; plasma-workspace's
## startplasma session script launches kglobalacceld so user-bound
## Meta / Ctrl-Alt / hardware media keys reach KGlobalAccel clients
## across the desktop.
##
## kglobalacceld lives in the Plasma 6.x release line (not the KF6
## frameworks line — that one is ``kglobalaccel``, the client-side
## library, which already ships as a sibling KF6 from-source recipe).
##
## sha256 = 94b5cc3780ca6b074093c487ec9e6c3460f635ae5145780f87c0fe8484d8c6c9

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kglobalacceldSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/kglobalacceld-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kglobalacceld"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/kglobalacceld-6.2.5.tar.xz"
    sha256: "94b5cc3780ca6b074093c487ec9e6c3460f635ae5145780f87c0fe8484d8c6c9"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    "extra-cmake-modules >=6.0"
    "qt6-base >=6.6"
    "qt6-tools >=6.6"
    ## KF6 modules pulled in by kglobalacceld's
    ## find_package(KF6 ... REQUIRED COMPONENTS ...) probes.
    "kconfig >=6.0"
    "kcoreaddons >=6.0"
    "kcrash >=6.0"
    "kdbusaddons >=6.0"
    "kwindowsystem >=6.0"
    "kglobalaccel >=6.0"
    "kservice >=6.0"
    "kio >=6.0"
    "kjobwidgets >=6.0"
    ## XCB components (XCB, KEYSYMS, XKB, RECORD; optional XTEST).
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

  ## kglobalacceld emits ``libKGlobalAccelD.so`` (note: NO KF6 prefix —
  ## this is the PLASMA-line library, distinct from the KF6 framework
  ## ``libKF6GlobalAccel.so`` shipped by the sibling ``kglobalaccel``
  ## from-source recipe).
  library libKGlobalAccelD:
    discard

  ## ``libexec/kglobalacceld`` (under ``$libdir/libexec/`` — not the
  ## $bindir). The Plasma session script launches it as a long-running
  ## D-Bus service; KDE's CMake glue installs it under the Qt6
  ## INSTALL_LIBEXECDIR rather than INSTALL_BINDIR by convention.
  executable kglobalacceld:
    discard

  build:
    setCurrentOwningPackageOverride("kglobalacceldSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKGlobalAccelD")
      discard pkg.executable("kglobalacceld")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
