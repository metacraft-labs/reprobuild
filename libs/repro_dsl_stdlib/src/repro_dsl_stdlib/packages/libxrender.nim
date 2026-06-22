## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxrender``.
##
## ``libxrender`` ships ``libXrender.so`` — the X Render extension
## client library (compositing primitives + glyph rendering).
## Standard dependency of every X11 compositor / X11 backend.
##
## ## Provisioning channel — nixpkgs#xorg.libXrender^*

import repro_project_dsl

package `libxrender`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXrender^*", executablePath = "lib/libXrender.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
