## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kpipewire``.
##
## ``kpipewire`` is the KDE PipeWire wrapper kwin uses for screen-
## capture + audio routing. OPTIONAL dep in kwin's CMakeLists.txt
## (only needed when ``BUILD_TESTING=ON``).
##
## ## Provisioning channel — nixpkgs#kdePackages.kpipewire

import repro_project_dsl

package `kpipewire`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kpipewire", executablePath = "lib/libKPipeWire.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
