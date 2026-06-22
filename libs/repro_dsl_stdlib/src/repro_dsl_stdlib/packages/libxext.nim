## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxext``.
##
## ``libxext`` ships ``libXext.so`` — the standard X11 extensions
## client library (XShm, XSync, MIT-SHM, DPMS, etc.). Standard
## dependency of every X11 backend.
##
## ## Provisioning channel — nixpkgs#xorg.libXext^*

import repro_project_dsl

package `libxext`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXext^*", executablePath = "lib/libXext.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
