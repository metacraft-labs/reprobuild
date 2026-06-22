## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``qt6-positioning``.
##
## ``qt6-positioning`` supplies QtPositioning (``libQt6Positioning.so``
## + ``libQt6PositioningQuick.so``) which plasma-workspace's
## CMakeLists.txt explicitly demands via
## ``find_package(Qt6 ... COMPONENTS ... Positioning)``.  This stub is
## the prebuilt nixpkgs channel for ``--tool-provisioning=nix`` runs;
## the from-source path is served by the sibling
## ``recipes/packages/source/qt6-positioning`` recipe.
##
## ## Provisioning channel — nixpkgs#qt6.qtpositioning

import repro_project_dsl

package `qt6-positioning`:
  provisioning:
    nixPackage "nixpkgs#qt6.qtpositioning", executablePath = "lib/libQt6Positioning.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
