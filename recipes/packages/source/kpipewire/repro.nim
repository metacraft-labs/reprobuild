## Source-from-tarball kpipewire recipe — M9.R.15q.11.3 Plasma
## cascade module. kpipewire is the KDE PipeWire wrapper kwin uses
## for screen-capture, virtual-camera, and screen-record encoding.
## Ships ``libKPipeWire.so`` (the QML wrapper) + ``libKPipeWireRecord.so``
## (the libavcodec-based encoder pipeline) + ``libKPipeWireDmaBuf.so``
## (the DMABuf / GBM buffer surface).
##
## sha256 = db42d581f0ca427bd80ee6a67d1fa9cef01114266c9aee7faa2cecbd973e6319

import repro_project_dsl
import repro_dsl_stdlib/constructors
import repro_dsl_stdlib/types/package_result

package kpipewireSource:
  versions:
    "6.2.5":
      sourceRevision = "v6.2.5"
      sourceUrl = "https://download.kde.org/stable/plasma/6.2.5/kpipewire-6.2.5.tar.xz"
      sourceRepository = "https://invent.kde.org/plasma/kpipewire"

  fetch:
    url: "https://download.kde.org/stable/plasma/6.2.5/kpipewire-6.2.5.tar.xz"
    sha256: "db42d581f0ca427bd80ee6a67d1fa9cef01114266c9aee7faa2cecbd973e6319"
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
    ## KF6 components.
    "kcoreaddons >=6.0"
    "ki18n >=6.0"
    ## EGL + GBM + libdrm for the DMABuf surface.
    "mesa"
    "libgbm"
    "libdrm"
    "libepoxy"
    ## PipeWire + ffmpeg + libva for the encoder pipeline.
    "pipewire >=1.0"
    "ffmpeg"
    "libva"

  config:
    discard

  library libKPipeWire:
    ## QML wrapper surface for the PipeWire graph.
    discard

  library libKPipeWireRecord:
    ## libavcodec-based encoder pipeline (screen-record + capture-encode).
    discard

  library libKPipeWireDmaBuf:
    ## DMABuf / GBM buffer-import surface (zero-copy buffer hand-off).
    discard

  build:
    setCurrentOwningPackageOverride("kpipewireSource")
    try:
      let opts = @[
        "BUILD_TESTING=OFF",
        "CMAKE_BUILD_TYPE=Release",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts)
      discard pkg.library("libKPipeWire")
      discard pkg.library("libKPipeWireRecord")
      discard pkg.library("libKPipeWireDmaBuf")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
