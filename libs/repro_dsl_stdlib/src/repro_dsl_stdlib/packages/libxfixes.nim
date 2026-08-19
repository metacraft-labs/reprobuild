## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxfixes``.
##
## ``libxfixes`` ships ``libXfixes.so`` — the X Fixes extension
## client library (cursor visibility, selection-owner notifications,
## region operations). Standard dependency of the X11 backend on
## kwindowsystem + kwin's X11 glue.
##
## ## Provisioning channel — nixpkgs#xorg.libXfixes^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libxfixes`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXfixes^*", executablePath = "lib/libXfixes.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
