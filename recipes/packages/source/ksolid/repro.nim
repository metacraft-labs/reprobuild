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
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

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
    url: "https://download.kde.org/stable/frameworks/6.10/solid-6.10.0.tar.xz"
    sha256: "24892e81a3047f753519dbd384b47635c5a2543d8ee0bf3c299b0fcfef318e8c"
    extractStrip: 1

  nativeBuildDeps:
    ## cmake is the build-system driver.
    "cmake >=3.16"
    ## ninja is CMake's preferred backend on Linux.
    "ninja >=1.10"
    ## gcc is the host C/C++ toolchain — ksolid is C++17.
    "gcc >=11"
    ## M9.R.15k.4 — ksolid's CMakeLists generates the predicate-parser
    ## lexer/parser through FLEX + BISON (find_package REQUIRED at
    ## line 51). flex / bison are bootstrap tools; carry-on the
    ## nix-shell when invoking ksolid until we have flex / bison
    ## from-source recipes.
    "flex"
    "bison"

  buildDeps:
    "extra-cmake-modules >=6.0"
    ## qt6-base supplies QtCore / QtDBus / QtXml / QtQml ksolid wraps
    ## for the udev / UPower / NetworkManager bridges.
    "qt6-base >=6.6"
    ## qt6-tools supplies ``qhelpgenerator`` for QCH generation.
    "qt6-tools >=6.6"
    ## qt6-declarative supplies QtQml type registration ksolid's
    ## hardware-abstraction QML surface exposes.
    "qt6-declarative >=6.6"
    ## M9.R.15l.2 — ksolid's Linux backend invokes
    ## ``find_package(LibMount)`` (CMakeLists.txt:118-ish via the
    ## Linux/UDev branch) to bind mount/umount system calls. The
    ## FindLibMount ECM find-module probes for ``libmount.so`` + the
    ## ``mount/libmount.h`` header which util-linux's install-mirror
    ## ships under ``.repro/output/install/usr/lib/`` and
    ## ``.repro/output/install/usr/include/libmount/`` respectively.
    "util-linux >=2.40"

  config:
    ## No prefix lifted from `cmakeFlags:`; flags inlined in the `build:` block.
    discard
  library libKF6Solid:
    ## ``libKF6Solid.so`` — hardware-abstraction layer (Device +
    ## Battery + StorageVolume + NetworkInterface + OpticalDrive +
    ## Predicate). v1 records the artifact only; the per-artifact
    ## build body lands in M9.L when the convention's ninja-spawn +
    ## install-glue closes.
    discard

  build:
    ## M9.R.5b — explicit `build:` block constructed from the lifted `config:` values + the inlined verbatim flags. Calls the M9.R.2b high-level `cmake_package(...)` constructor.
    setCurrentOwningPackageOverride("ksolidSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "BUILD_PYTHON_BINDINGS=OFF",
        "CMAKE_BUILD_TYPE=Release",
        # M9.R.15k.4 — disable UDev hardware-detection backend. The
        # Linux UDev REQUIRED find_package (CMakeLists.txt:112) needs
        # libudev headers + .so from systemd / eudev which v1 doesn't
        # carry as a from-source recipe yet. ksolid's predicate / fake-
        # hardware backends remain and are sufficient for v1 KF6 module-
        # graph closure; full hot-plug detection comes when we add eudev
        # / systemd from-source.
        #
        # M9.R.15l.2 follow-up: UDEV_DISABLED=ON only gates the
        # find_package(UDev REQUIRED) call; it does NOT remove the
        # udisks2 / upower backends from the build's
        # ENABLED_DEVICE_BACKENDS list. Both backends include source
        # files that hard-#error out on non-UDev Linux platforms
        # (udisksstoragedrive.cpp:46 ``#error Implement this or stub
        # this out for your platform``). Closing the full ksolid build
        # gate needs either eudev-from-source (so UDev is found and
        # both backends compile) or a backend-list override
        # (``ENABLED_DEVICE_BACKENDS=fakehw;fstab;shared``). Deferred
        # to a follow-up milestone when one of those lands; the
        # ``libmount.so`` discovery via the M9.R.15l.2 util-linux
        # buildDep edge is exercised at the CMake configure stage,
        # which is the M9.R.15l.2 deliverable.
        "UDEV_DISABLED=ON",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKF6Solid")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    ## TODO(M9.R.5b): derive runtime closure from pkg-config /
    ## DT_NEEDED inspection of the linked artifacts. Empty until
    ## the M9.R.5b per-recipe pass populates per-output ELF
    ## interrogation.
    discard
