## DSL-port M9.R.15q.11.3 — stdlib provisioning stub for ``libva``.
##
## ``libva`` (Video Acceleration API) is Intel's userspace API for
## VA-enabled video-decoder / encoder hardware on Linux. REQUIRED by
## kpipewire 6.2.5's GPU-accelerated capture / encode path via
## ``pkg_check_modules(LIBVA libva REQUIRED)`` +
## ``pkg_check_modules(LIBVA-drm libva-drm REQUIRED)`` probes.
##
## ## Provisioning channel — nixpkgs#libva^*
##
## The ``^*`` multi-output realization brings the .pc + headers (dev
## output) AND the runtime ``libva.so`` + ``libva-drm.so`` (out
## output) per the M9.R.14f.10 pattern.

import repro_project_dsl

package `libva`:
  provisioning:
    nixPackage "nixpkgs#libva^*", executablePath = "lib/libva.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
