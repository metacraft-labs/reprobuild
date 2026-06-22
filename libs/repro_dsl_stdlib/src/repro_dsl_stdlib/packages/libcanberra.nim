## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``libcanberra``.
##
## ``libcanberra`` is the freedesktop event-sound library kwin uses
## to play UI feedback sounds (window minimize/maximize cues, etc.).
## REQUIRED by kwin's CMakeLists.txt (find_package(Canberra REQUIRED)).
##
## ## Provisioning channel — nixpkgs#libcanberra^*

import repro_project_dsl

package `libcanberra`:
  provisioning:
    nixPackage "nixpkgs#libcanberra^*", executablePath = "lib/libcanberra.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
