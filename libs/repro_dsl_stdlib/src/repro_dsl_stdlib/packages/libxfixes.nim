## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxfixes``.
##
## ``libxfixes`` ships ``libXfixes.so`` — the X Fixes extension
## client library (cursor visibility, selection-owner notifications,
## region operations). Standard dependency of the X11 backend on
## kwindowsystem + kwin's X11 glue.
##
## ## Provisioning channel — nixpkgs#xorg.libXfixes^*

import repro_project_dsl

package `libxfixes`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXfixes^*", executablePath = "lib/libXfixes.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
