## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``colord``.
##
## colord is the GNOME color management daemon — provides ICC profile
## management + display calibration.  Pinned by mutter 47.x's
## ``src/meson.build:127`` as an unconditional dependency
## (compositor consumes colord to apply per-output ICC profiles).
##
## ## Provisioning channel — nixpkgs#colord
##
## Standard nixpkgs entry; the multi-output package ships ``colord.pc``
## under the ``-dev`` output's ``lib/pkgconfig/``.

import repro_project_dsl

package `colord`:
  provisioning:
    nixPackage "nixpkgs#colord", executablePath = "lib/pkgconfig/colord.pc",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
