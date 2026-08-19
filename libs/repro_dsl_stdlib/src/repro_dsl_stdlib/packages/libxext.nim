## DSL-port M9.R.15q.4.1 — stdlib provisioning stub for ``libxext``.
##
## ``libxext`` ships ``libXext.so`` — the standard X11 extensions
## client library (XShm, XSync, MIT-SHM, DPMS, etc.). Standard
## dependency of every X11 backend.
##
## ## Provisioning channel — nixpkgs#xorg.libXext^*

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `libxext`:
  provisioning:
    nixPackage "nixpkgs#xorg.libXext^*", executablePath = "lib/libXext.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
