## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kpipewire``.
##
## ``kpipewire`` is the KDE PipeWire wrapper kwin uses for screen-
## capture + audio routing. OPTIONAL dep in kwin's CMakeLists.txt
## (only needed when ``BUILD_TESTING=ON``).
##
## ## Provisioning channel — nixpkgs#kdePackages.kpipewire

import repro_project_dsl
import repro_dsl_stdlib/nixpkgs_pin

package `kpipewire`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kpipewire", executablePath = "lib/libKPipeWireDmaBuf.so",
      nixpkgsRev = CanonicalNixpkgsRev,
      nixpkgsNarHash = CanonicalNixpkgsNarHash
