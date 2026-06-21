## Source-from-tarball plasma-wayland-protocols recipe — M9.R.15p.1.4.
## plasma-wayland-protocols ships the Plasma-specific Wayland protocol
## XML descriptions (org_kde_plasma_*, org_kde_kwin_*, …) + a CMake
## ``PlasmaWaylandProtocolsConfig.cmake`` that exposes the protocol
## search path to consumers. kwindowsystem's
## ``find_package(PlasmaWaylandProtocols REQUIRED)`` blocks the
## kwindowsystem → kio → plasma-framework → kwin chain when
## ``KWINDOWSYSTEM_WAYLAND=ON`` (the default we want for v1's
## Wayland-only desktop story).
##
## plasma-wayland-protocols ships NO compiled libraries — same shape as
## extra-cmake-modules (M9.R.15h.14): pure CMake module + XML protocol
## descriptions installed under ``<prefix>/share/plasma-wayland-protocols/``
## + ``<prefix>/share/cmake/``. The "build" reduces to ``cmake --install``
## after a no-op configure.
##
## sha256 = da3fbbe3fa5603f9dc9aabe948a6fc8c3b451edd1958138628e96c83649c1f16
##  (upstream SHA256 from download.kde.org/stable/
##  plasma-wayland-protocols/plasma-wayland-protocols-1.16.0.tar.xz.sha256;
##  cross-checked locally against the vendored 46,904-byte tarball).
##
## ## Version choice — 1.16.0
##
## 1.16.0 is the current upstream stable as of mid-2026. The Plasma
## 6.x lockstep ABI is maintained across the 1.1x.x line.

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package plasmaWaylandProtocolsSource:
  ## From-source plasma-wayland-protocols — M9.R.15p.1.4 KF6 Wayland
  ## blocker. Tier-2b c_cpp_cmake convention consumer. No compiled
  ## artifact — same shape as extra-cmake-modules.

  versions:
    "1.16.0":
      sourceRevision = "v1.16.0"
      sourceUrl = "https://download.kde.org/stable/plasma-wayland-protocols/plasma-wayland-protocols-1.16.0.tar.xz"
      sourceRepository = "https://invent.kde.org/libraries/plasma-wayland-protocols"

  fetch:
    url: "https://download.kde.org/stable/plasma-wayland-protocols/plasma-wayland-protocols-1.16.0.tar.xz"
    sha256: "da3fbbe3fa5603f9dc9aabe948a6fc8c3b451edd1958138628e96c83649c1f16"
    extractStrip: 1

  nativeBuildDeps:
    "cmake >=3.16"

  buildDeps:
    ## extra-cmake-modules supplies KDEInstallDirs the
    ## plasma-wayland-protocols CMake build uses to compute the install
    ## prefix for the protocol XML + CMake config files.
    "extra-cmake-modules >=6.0"

  # plasma-wayland-protocols has no compiled artifact — it's a pure
  # CMake module + XML protocol description collection installed under
  # share/plasma-wayland-protocols/ + share/cmake/. Per the
  # extra-cmake-modules / kded precedent we don't register any library()
  # or executable() artifact; the install-mirror step copies the share/
  # tree into .repro/output/install so consumers' CMAKE_PREFIX_PATH
  # probe finds PlasmaWaylandProtocolsConfig.cmake.

  config:
    discard

  build:
    setCurrentOwningPackageOverride("plasmaWaylandProtocolsSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      discard cmake_package(srcDir = "./src", cacheVars = opts)
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
