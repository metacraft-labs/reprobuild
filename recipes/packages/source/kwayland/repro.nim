## Source-from-tarball kwayland recipe — M9.R.15q.6.1 KDE Plasma 6.2.x
## Wayland client library kwin's wayland backend depends on.
##
## ## Why kwayland matters for the v1 desktop story
##
## ``libKWaylandClient.so`` is the KDE-specific Wayland client wrapper
## kwin 6.2.x links against to expose Plasma-specific surface roles
## (plasma-shell, app-menu, kde-output-management, kde-screen-edge,
## ...) without each consumer re-implementing the wire protocol. kwin's
## CMakeLists.txt declares ``find_package(KWayland)`` and the build
## fails at configure time when the legacy 6.2.x ABI is missing.
##
## nixpkgs's ``kdePackages.kwayland`` ships a 6.3+ build that requires
## Qt 6.9+, but our from-source qt6-base is 6.8.1. The version skew is
## fatal at the Qt6WaylandClient ``find_package`` step. Pinning the
## 6.2.5 source release (whose ``QT_MIN_VERSION`` is 6.7.0) closes that
## gap — same shape as kdecoration 6.2.5 vs nixpkgs's 6.3+ in M9.R.15q.4.8.
##
## ## sha256 strategy
##
## We fetch the upstream 6.2.5 .tar.xz from download.kde.org/Attic/
## plasma/6.2.5/ at build time (no vendor copy; the tarball is ~131 KB
## so streaming is fine — same pattern as kdecoration).
##
## sha256 = 2a17a8ce5643fd51c3cf787542032c1050da3a1fb00dcc9a32dea288bd38d7d2
##  (computed locally over the upstream tarball, 134,116 bytes).
##
## ## Artifact
##
## kwayland 6.2.5 emits a single shared library:
##
##   * ``libKWaylandClient.so`` — KDE-specific Wayland client wrapper.
##     (Upstream renamed: legacy KWayland 5.x exposed both
##     ``KWaylandClient`` and ``KWaylandServer`` libraries; in 6.x the
##     server-side surface moved into kwin's own tree so only the
##     client library remains here.)

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kwaylandSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/Attic/plasma/6.2.5/kwayland-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kwayland"

  fetch:
    url: "https://download.kde.org/Attic/plasma/6.2.5/kwayland-6.2.5.tar.xz"
    sha256: "2a17a8ce5643fd51c3cf787542032c1050da3a1fb00dcc9a32dea288bd38d7d2"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"
    "ninja >=1.10"
    "gcc >=11"

  buildDeps:
    ## kwayland 6.2.5 CMakeLists.txt:12 declares
    ## ``find_package(ECM ${KF6_MIN_VERSION} REQUIRED NO_MODULE)``.
    "extra-cmake-modules >=6.5"
    ## ``find_package(Qt6Gui REQUIRED COMPONENTS Private)`` +
    ## ``find_package(Qt6 ... Concurrent)``. QT_MIN_VERSION = 6.7.0.
    "qt6-base >=6.7"
    ## ``find_package(Qt6WaylandClient REQUIRED COMPONENTS Private)``.
    "qt6-wayland >=6.7"
    ## ``find_package(Wayland 1.15 COMPONENTS Client)``.
    "wayland >=1.21"
    ## ``find_package(WaylandProtocols 1.15)``.
    "wayland-protocols >=1.30"
    ## ``find_package(PlasmaWaylandProtocols 1.14.0 CONFIG)``.
    "plasma-wayland-protocols >=1.14"

  config:
    discard

  library libKWaylandClient:
    ## ``libKWaylandClient.so`` — KDE Plasma 6.2.x Wayland client
    ## wrapper kwin 6.2.5 links against via
    ## ``find_package(KWayland)``. Upstream CMake namespace is
    ## ``Plasma::KWaylandClient`` (the legacy KDecoration2-shape
    ## namespace where the on-disk SONAME differs from the CMake
    ## target alias).
    discard

  build:
    setCurrentOwningPackageOverride("kwaylandSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "BUILD_QCH=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKWaylandClient")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
