## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``libcanberra``.
##
## ``libcanberra`` is the freedesktop event-sound library kwin uses
## to play UI feedback sounds (window minimize/maximize cues, etc.).
## REQUIRED by kwin's CMakeLists.txt (find_package(Canberra REQUIRED)).
##
## ## Provisioning channel — nixpkgs#libcanberra^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libcanberra`:
  provisioning:
    nixPackage "nixpkgs#libcanberra^*", executablePath = "lib/libcanberra.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
