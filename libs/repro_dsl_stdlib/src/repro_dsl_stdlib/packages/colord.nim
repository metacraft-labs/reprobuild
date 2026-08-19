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
import repro_dsl_stdlib/nixpkgs_pin

package `colord`:
  provisioning:
    nixPackage "nixpkgs#colord", executablePath = "lib/pkgconfig/colord.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
