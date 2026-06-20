## DSL-port M9.R.15e.7 — stdlib provisioning stub for ``cvt``.
##
## ``cvt`` is the VESA Coordinated Video Timings calculator (computes
## modeline timings for a given resolution + refresh rate).  Mutter's
## native KMS/DRM backend invokes it at compile time (via
## ``find_program('cvt')`` in ``src/src/meson.build:1005``) to generate
## the ``meta-default-modes.h`` table of fallback display modes.
##
## ## Provisioning channel — nixpkgs#libxcvt
##
## ``cvt`` historically shipped as part of xorg-server-utils; modern
## nixpkgs has moved it to the standalone ``libxcvt`` package
## (alongside ``libxcvt.so`` and ``libxcvt.pc``).  The binary lives at
## ``bin/cvt`` in the realized store path.

import repro_project_dsl

package `cvt`:
  provisioning:
    nixPackage "nixpkgs#libxcvt", executablePath = "bin/cvt",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
