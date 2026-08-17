## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxrender``.
##
## ``libxrender`` ships ``libXrender.so`` — the X Render extension
## client library (compositing primitives + glyph rendering).
## Standard dependency of every X11 compositor / X11 backend.
##
## ## Provisioning channel — nixpkgs#xorg.libXrender^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libxrender`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXrender^*", executablePath = "lib/libXrender.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
