## DSL-port M9.R.15q.9.2 — stdlib provisioning stub for ``layer-shell-qt``.
##
## ``layer-shell-qt`` (LayerShellQt in upstream) is the Qt-binding for
## the wlr-layer-shell Wayland protocol (the surface-layering protocol
## that gives panels / docks / lock-screens their reserved screen
## regions).  REQUIRED dep on plasma-workspace's
## ``find_package(LayerShellQt REQUIRED)`` probe; the Plasma shell uses
## layer-shell to anchor its task bar to the bottom edge.
##
## ## Provisioning channel — nixpkgs#kdePackages.layer-shell-qt

import repro_project_dsl

package `layer-shell-qt`:
  provisioning:
    nixPackage "nixpkgs#kdePackages.layer-shell-qt", executablePath = "lib/libLayerShellQtInterface.so",
      nixpkgsRev = "addf7cf5f383a3101ecfba091b98d0a1263dc9b8",
      nixpkgsNarHash = "sha256-hM20uyap1a0M9d344I692r+ik4gTMyj60cQWO+hAYP8="
