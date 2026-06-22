## DSL-port M9.R.15q.4.5 — stdlib provisioning stub for ``kglobalacceld``.
##
## ``kglobalacceld`` is the Plasma global-accelerator daemon kwin's
## global-shortcut surface connects to. REQUIRED by kwin when
## ``KWIN_BUILD_GLOBALSHORTCUTS=ON`` (default).
##
## ## Provisioning channel — nixpkgs#kdePackages.kglobalacceld

import repro_project_dsl

package `kglobalacceld`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.kglobalacceld", executablePath = "lib/cmake/KGlobalAccelD/KGlobalAccelDConfig.cmake",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
