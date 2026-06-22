## DSL-port M9.R.15q.11.3 — stdlib provisioning stub for ``ffmpeg``.
##
## ``ffmpeg`` is the canonical multimedia codec / mux / filter library
## family (libavcodec, libavutil, libavformat, libavfilter, libswscale).
## REQUIRED by kpipewire 6.2.5 (Plasma screen-record + virtual-camera
## pipeline) via separate
## ``pkg_check_modules(AVCodec libavcodec REQUIRED)`` +
## ``pkg_check_modules(AVUtil libavutil REQUIRED)`` +
## ``pkg_check_modules(AVFormat libavformat REQUIRED)`` +
## ``pkg_check_modules(AVFilter libavfilter REQUIRED)`` +
## ``pkg_check_modules(SWScale libswscale REQUIRED)`` probes.
##
## ## Provisioning channel — nixpkgs#ffmpeg^*
##
## The ``^*`` multi-output realization brings the .pc + headers (dev
## output) AND the runtime ``libav*.so`` + ``libswscale.so`` (lib
## output) per the M9.R.14f.10 pattern.

import repro_project_dsl

package `ffmpeg`:
  provisioning:
    nixPackage "nixpkgs#ffmpeg^*", executablePath = "lib/libavcodec.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
