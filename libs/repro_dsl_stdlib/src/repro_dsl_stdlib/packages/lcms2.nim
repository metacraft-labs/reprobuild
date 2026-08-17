## DSL-port M9.R.15e.4 — stdlib provisioning stub for ``lcms2``.
##
## Little CMS 2 is a small color management library implementing
## ICC v4 + v5 profile parsing and color transforms.  Pinned by
## mutter 47.x's ``src/meson.build:128`` (compositor uses lcms2 to
## transform between display ICC profiles at composition time).
##
## ## Provisioning channel — nixpkgs#lcms2
##
## Standard nixpkgs entry; multi-output package ships ``lcms2.pc``
## under the ``-dev`` output's ``lib/pkgconfig/``.

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `lcms2`:
  provisioning:
    nixPackage "nixpkgs#lcms2", executablePath = "lib/pkgconfig/lcms2.pc",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
