## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``libgbm``.
##
## libgbm (Generic Buffer Management) is the mesa-shipped userspace
## API for allocating graphics buffers for KMS/DRM (the bare-metal
## Wayland-compositor path).  Pinned by mutter 47.x's
## ``src/meson.build:251`` (gated on the ``native_backend=true``
## option that the v1 recipe ships with).
##
## ## Provisioning channel — nixpkgs#libgbm
##
## In modern nixpkgs (24.11+) ``libgbm`` is split out of the main
## ``mesa`` derivation into its own ``mesa-libgbm`` package so
## consumers that need ONLY GBM (compositors, drm-clients) don't pull
## the full mesa DRI driver closure.  The pc file ships under
## ``lib/pkgconfig/gbm.pc`` in the ``-dev`` output (the resolver's
## multi-output ``^*`` walk picks it up).

import repro_project_dsl

package `libgbm`:
  provisioning:
    nixPackage "nixpkgs#libgbm", executablePath = "lib/pkgconfig/gbm.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
