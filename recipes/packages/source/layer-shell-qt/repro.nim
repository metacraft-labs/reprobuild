## Source-from-tarball layer-shell-qt recipe — M9.R.15q.11.4 Plasma
## cascade module. LayerShellQt is the Qt6 binding for the
## ``wlr-layer-shell`` Wayland protocol; Plasma's lock screen +
## panel-OSD widgets use it to layer above / below normal surfaces.
## Ships ``libLayerShellQtInterface.so``.
##
## sha256 = bc09870218df387c377bad2fed4b2a8f39121ddbdc5c6bb28a40be0c1b000c77

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package layerShellQtSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/layer-shell-qt-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/layer-shell-qt"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/layer-shell-qt-6.2.5.tar.xz"
    sha256: "bc09870218df387c377bad2fed4b2a8f39121ddbdc5c6bb28a40be0c1b000c77"
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
    ## Wayland scanner + client + protocol XMLs.
    "wayland"
    "wayland-scanner"
    "wayland-protocols"
    "libxkbcommon"

  config:
    discard

  library libLayerShellQtInterface:
    discard

  build:
    setCurrentOwningPackageOverride("layerShellQtSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libLayerShellQtInterface")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
