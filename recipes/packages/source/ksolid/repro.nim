## Source-from-tarball ksolid recipe — the FIFTY-SIXTH real from-source
## production recipe to exercise the M9.H/I/K trio and the SECOND
## recipe in the THIRD KF6 module-sweep batch (ksvg / ksolid / kio /
## kded).
##
## ksolid is the FOURTEENTH CMake-driven recipe and the TENTH KF6
## foundation module after kcoreaddons + kconfig + ki18n +
## kwidgetsaddons + kxmlgui + kservice + kglobalaccel + knotifications
## + ksvg.
##
## NOTE on the upstream vs package naming asymmetry: the canonical
## download.kde.org tarball is published as ``solid-6.10.0.tar.xz``
## (no ``k`` prefix; the project predates the ``KF6*`` naming
## convention). We register the package as ``ksolidSource`` for
## consistency with the rest of the KF6 module-sweep batch — every
## other from-source KF6 recipe uses a ``k<name>Source`` identifier,
## and a bare ``solidSource`` would alphabetise outside the KF6
## cluster in artifact registries. The SONAME / library file the
## CMake build emits is unaffected (``libKF6Solid.so``).
##
## ## Why ksolid matters for the v1 desktop story
##
## ksolid (``libKF6Solid.so``) supplies the hardware-abstraction layer
## KF6 applications consume to enumerate block devices, network
## interfaces, batteries, optical drives, and removable storage. The
## kded ``solidautoeject`` / ``solidnotify`` daemons + plasma-workspace's
## device-notifier applet + Dolphin's mount-point sidebar all pull this
## in for udev/UPower/NetworkManager bridging.
##
## ## sha256 strategy
##
## We vendor the upstream 6.10.0 .tar.xz at
## ``recipes/packages/source/ksolid/vendor/solid-6.10.0.tar.xz`` and
## reference it via a ``file://`` URL. The vendored filename
## preserves the upstream ``solid-6.10.0.tar.xz`` form rather than
## being re-named to ``ksolid-6.10.0.tar.xz`` so a future
## ``repro update-source`` re-fetch byte-compares against the live
## upstream URL without a rename step.
##
## ## Version choice — 6.10.0 (current upstream stable in the 6.x line)
##
## Same lockstep ABI rationale as the sibling KF6 recipes.
##
## sha256 = 24892e81a3047f753519dbd384b47635c5a2543d8ee0bf3c299b0fcfef318e8c
##  (computed locally over the vendored ``solid-6.10.0.tar.xz``,
##  307,236 bytes; downloaded once from the upstream URL recorded in
##  ``versions:`` above).
##
## ## Build shape
##
## c_cpp_cmake convention (M9.K) — same as the sibling KF6 recipes.
##
## ## Library artifact
##
## ksolid's CMake build emits a single shared library
## (``libKF6Solid.so``) bundling the hardware-abstraction surface. We
## register the artifact under ``libKF6Solid`` (camelCased from the
## upstream SONAME ``KF6Solid``).
##
## ## Configurables
##
## v1 ships NO configurables — same modern-desktop baseline as the
## sibling KF6 recipes (``BUILD_TESTING=OFF`` + ``BUILD_QCH=OFF`` +
## ``BUILD_PYTHON_BINDINGS=OFF`` + ``CMAKE_BUILD_TYPE=Release``).

import repro_project_dsl

# ---------------------------------------------------------------------------
# Package declaration
# ---------------------------------------------------------------------------

package ksolidSource:
  ## From-source ksolid — fifty-sixth M9.H/I/K production recipe and
  ## the SECOND recipe in the THIRD KF6 module-sweep batch (ksvg /
  ## ksolid / kio / kded). Fourteenth CMake-driven recipe and the
  ## TENTH KF6 foundation module.
  ##
  ## Tier-2b c_cpp_cmake convention consumer. Single library artifact
  ## recipe.

  versions:
    ## Pinned upstream tag. ``sourceUrl`` records the canonical
    ## download.kde.org release tarball URL (note: published as
    ## ``solid-6.10.0.tar.xz`` upstream, without the ``k`` prefix) so
    ## a future maintainer running ``repro update-source`` can re-
    ## fetch from upstream; the live ``fetch:`` block below points at
    ## the vendored copy for deterministic offline test reproduction.
    "6.10.0":
      sourceRevision = "v6.10.0"
      sourceUrl = "https://download.kde.org/stable/frameworks/6.10/solid-6.10.0.tar.xz"
      sourceRepository = "https://invent.kde.org/frameworks/solid"

  fetch:
    ## Vendored tarball (option 1 per the M9.K acceptance plan).
    ## ``file://`` URL keeps the build deterministic when the network
    ## is unavailable. Filename preserves the upstream ``solid-``
    ## prefix to keep byte-comparison with the live URL clean.
    ##
    ## sha256 was computed over the vendored 307,236-byte tarball
    ## downloaded once from the upstream URL recorded in
    ## ``versions:`` above.
    url: "file:///metacraft/reprobuild/recipes/packages/source/ksolid/vendor/solid-6.10.0.tar.xz"
    sha256: "24892e81a3047f753519dbd384b47635c5a2543d8ee0bf3c299b0fcfef318e8c"
    extractStrip: 1

  uses:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — ksolid is C++17.
    "gcc >=11"
    ## qt6-base supplies QtCore / QtDBus / QtXml / QtQml ksolid wraps
    ## for the udev / UPower / NetworkManager bridges.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## qt6-declarative supplies QtQml type registration ksolid's
    ## hardware-abstraction QML surface exposes.
    "qt6-declarative >=6.6"

  cmakeFlags:
    ## Flag set mirroring the modern-desktop baseline per the task
    ## brief. Order is load-bearing: CMake evaluates ``-D`` overrides
    ## left-to-right.
    "-DBUILD_TESTING=OFF"
    "-DBUILD_QCH=OFF"
    "-DBUILD_PYTHON_BINDINGS=OFF"
    "-DCMAKE_BUILD_TYPE=Release"

  library libKF6Solid:
    ## ``libKF6Solid.so`` — hardware-abstraction layer (Device +
    ## Battery + StorageVolume + NetworkInterface + OpticalDrive +
    ## Predicate). v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard
