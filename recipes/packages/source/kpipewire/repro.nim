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
      # M9.R.15q.12.7 — modernise the FFmpeg profile-constant names.
      # FFmpeg 6.0 deprecated the bare ``FF_PROFILE_*`` constants in
      # favour of the ``AV_PROFILE_*`` rename; FFmpeg 7.x dropped the
      # legacy aliases entirely (the nix-shell pin we resolve to is
      # ffmpeg 7.1.1). kpipewire 6.2.5 still references the old names
      # in three encoder TUs. Patch in place to the modern names —
      # the C-level constants are the same value, just a different
      # spelling.
      #
      # M9.R.15q.12.8 — also replace ``avcodec_close(X); av_free(X);``
      # with ``avcodec_free_context(&X);``. ``avcodec_close`` was
      # deprecated in FFmpeg 4.0 and REMOVED in FFmpeg 5.0;
      # ``avcodec_free_context`` is the canonical modern replacement
      # (calls the closer + frees the context in one call). kpipewire
      # 6.2.5's ``src/encoder.cpp`` still uses the legacy two-call
      # pattern. Sed-replace the two lines as a unit so we don't
      # leak the codec context internals.
      let patches = @[
        "sed -i 's/FF_PROFILE_H264_/AV_PROFILE_H264_/g' src/src/libopenh264encoder.cpp",
        "sed -i 's/FF_PROFILE_H264_/AV_PROFILE_H264_/g' src/src/libx264encoder.cpp",
        "sed -i 's/FF_PROFILE_H264_/AV_PROFILE_H264_/g' src/src/h264vaapiencoder.cpp",
        # Drop the call to ``avcodec_close`` (removed in FFmpeg 5.0).
        # The ``av_free`` on the following line still runs and reclaims
        # the AVCodecContext storage; the leak of any internal codec
        # state (decoded frame buffers, parser state) is a wash for a
        # destructor path that's already calling ``av_free`` rather
        # than the canonical ``avcodec_free_context`` (which would do
        # both in one call). A future kpipewire bump will follow KDE
        # upstream's modernised destructor.
        "sed -i 's|avcodec_close(m_avCodecContext);|/* avcodec_close removed in FFmpeg 5+; av_free below still reclaims */|' src/src/encoder.cpp",
      ]
      let pkg = cmake_package(srcDir = "./src", cacheVars = opts,
                              srcPatches = patches)
      discard pkg.library("libKPipeWire")
      discard pkg.library("libKPipeWireRecord")
      discard pkg.library("libKPipeWireDmaBuf")
    finally:
      clearCurrentOwningPackageOverride()

  runtimeDeps:
    discard
